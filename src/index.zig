//! Index thread: consensus-side worker and child of one front.
//!
//! An index owns one `IndexInbox` (its LLQ) and one io_uring ring. Phase A
//! (ring, inbox, `INITIALIZED`) is handled by `lifetime.Controller.runThread`;
//! this file owns everything after that: the service loop, routing of accepted
//! sessions and the shutdown choreography from docs/startup-en-reworked.md.

const std = @import("std");
const posix = std.posix;
const zigring = @import("zigring");
const lifetime = @import("lifetime.zig");
const idxinbox = @import("index_inbox.zig");
const messages = @import("messages.zig");

/// A message that a front pushes into an index inbox.
pub const FrontMessage = union(enum) {
    /// Hand a freshly accepted client socket to this index. The index becomes
    /// the only owner of `fd` from that point on.
    create: struct {
        fd: posix.fd_t,
    },
    /// An operation on an already established session.
    session_op: struct {},
    /// The parent front is draining: stop taking new sessions and report to
    /// the parent once this index has no sessions left.
    shutdown_soft: void,
    /// Stop now: close everything and report.
    shutdown_hard: void,
};

/// The inbound queue type shared by fronts and indexes.
pub const Inbox = idxinbox.IndexInbox(FrontMessage);

const LoopConfig = idxinbox.LoopConfig;

/// Runs the index thread to completion. Started after the `INITIALIZED`
/// report; the service loop ends when a shutdown demand has been satisfied.
pub fn run(ctrl: *lifetime.Controller, role: lifetime.Role, logger: *lifetime.LoggerStuff) void {
    const ring = &ctrl.rings[role.index.idx.ring];
    const inbox = &ctrl.inboxes[role.index.idx.inbox];
    const front_ring = &ctrl.rings[role.index.front_idx].ring;
    const log = &logger.logger;

    log.info("index started", .{ .ring_idx = role.index.idx.ring, .inbox = role.index.idx.inbox });

    const cfg = LoopConfig{};
    var sessions: usize = 0;
    var draining = false;

    while (true) {
        const batch = inbox.batch(cfg.batch_k, cfg.batch_k) orelse {
            inbox.hang(cfg);
            continue;
        };

        // The CQ is strictly drained before the inbound queue.
        while (batch.ring.popCQE()) |cqe| {
            switch (cqe.taskIdx()) {
                // The launch broadcast is a no-op for an index: it ignores
                // the socket fd and keeps working off its ring and its inbox.
                messages.StartWorkIdx => {},
                // A payload-less wakeup: the inbox drain below delivers.
                messages.IndexWakeupTaskIdx => {},
                else => {
                    // Nothing else is armed on an index ring in the skeleton.
                },
            }
        }
        batch.ring.commit() catch |err| {
            log.err("index CQ commit failed", .{ .ring_idx = role.index.idx.ring, .err = @errorName(err) });
            std.process.exit(1);
        };

        while (batch.front.next()) |task| switch (task) {
            .create => |create| {
                // The skeleton owns no session state yet: take ownership of the
                // descriptor, log it, and close it again.
                sessions += 1;
                log.info("index received session", .{ .ring_idx = role.index.idx.ring, .fd = create.fd });
                _ = std.os.linux.close(create.fd);
                sessions -= 1;
            },
            .session_op => {},
            .shutdown_soft => {
                if (!draining) {
                    draining = true;
                    log.info("index soft shutdown", .{ .ring_idx = role.index.idx.ring });
                }
                if (sessions == 0) {
                    reportDrained(ring, front_ring, role.index.idx.ring);
                    return;
                }
            },
            .shutdown_hard => {
                log.info("index hard shutdown", .{ .ring_idx = role.index.idx.ring });
                reportDrained(ring, front_ring, role.index.idx.ring);
                return;
            },
        };

        // A soft shutdown may have been requested while the last session was
        // still open; once it closes, the index is done.
        if (draining and sessions == 0) {
            reportDrained(ring, front_ring, role.index.idx.ring);
            return;
        }
    }
}

/// Tells the parent front that this index has stopped. The front ignores the
/// payload and reads its own per-index bit set instead.
fn reportDrained(ring: *lifetime.RingStuff, front_ring: *zigring.Ring, thread_idx: u16) void {
    while (true) {
        if (ring.ring.pushMsgRing(front_ring, messages.IndexDrainedIdx, thread_idx, .{})) |_| {
            return;
        } else |err| switch (err) {
            error.RingFull => std.atomic.spinLoopHint(),
        }
    }
}

test "front message carries an owned descriptor" {
    const task: FrontMessage = .{ .create = .{ .fd = 5 } };
    try std.testing.expectEqual(@as(posix.fd_t, 5), task.create.fd);
}
