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
const state = @import("state.zig");

/// The replication factor of an index's data set group: the own data set plus
/// one mirror per remote host.
pub const replication_factor: usize = 3;

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

/// Runs the index thread to completion. `role` is the role the thread derived
/// from its `ring_idx` before reporting `INITIALIZED`; the service loop ends
/// when a shutdown demand has been satisfied.
pub fn run(ctrl: *lifetime.Controller, role: lifetime.Role, logger: *lifetime.LoggerStuff) void {
    const ring = &ctrl.rings[role.index.ring_idx];
    const inbox = &ctrl.inboxes[role.index.inbox_idx];
    const front_ring = &ctrl.rings[role.index.front_idx].ring;
    const log = &logger.logger;

    log.info("index started", .{ .ring_idx = role.index.ring_idx, .inbox = role.index.inbox_idx });

    // One data set per member of the replication group, indexed by host_idx;
    // the own data set sits at the configured host slot.
    var data_sets: [replication_factor]state.IndexState = undefined;
    var initialized: usize = 0;
    while (initialized < data_sets.len) : (initialized += 1) {
        ctrl.initIndexState(&data_sets[initialized]) catch |err| {
            log.err("index state initialization failed", .{
                .ring_idx = role.index.ring_idx,
                .err = @errorName(err),
            });
            std.process.exit(1);
        };
    }
    defer {
        for (&data_sets) |*st| ctrl.deinitIndexState(st);
    }

    const own_host: usize = @intCast(ctrl.cfg.host_index);
    if (own_host >= data_sets.len) {
        log.err("host_index is outside the replication group", .{
            .ring_idx = role.index.ring_idx,
            .host_index = ctrl.cfg.host_index,
        });
        std.process.exit(1);
    }
    const own_state = &data_sets[own_host];

    const cfg = LoopConfig{};
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
            log.err("index CQ commit failed", .{ .ring_idx = role.index.ring_idx, .err = @errorName(err) });
            std.process.exit(1);
        };

        while (batch.front.next()) |task| switch (task) {
            .create => |create| {
                // The skeleton owns no session state yet: take ownership of the
                // descriptor, log it, and close it again.
                log.info("index received session", .{ .ring_idx = role.index.ring_idx, .fd = create.fd });
                _ = std.os.linux.close(create.fd);
            },
            .session_op => {},
            .shutdown_soft => {
                if (!draining) {
                    draining = true;
                    log.info("index soft shutdown", .{ .ring_idx = role.index.ring_idx });
                }
                if (own_state.sessions.count() == 0) {
                    reportDrained(ring, front_ring, role.index.ring_idx);
                    return;
                }
            },
            .shutdown_hard => {
                log.info("index hard shutdown", .{ .ring_idx = role.index.ring_idx });
                reportDrained(ring, front_ring, role.index.ring_idx);
                return;
            },
        };

        // The queue entry itself carries the future due time; checking it
        // against the clock is the loop's outer logic, not the drain's.
        drainReplay(ctrl, own_state, logger, role.index.ring_idx);

        // A soft shutdown may have been requested while the last session was
        // still open; once it closes, the index is done. The replay queue does
        // not gate shutdown: its contents are dump-persistent state that
        // survives the restart.
        if (draining and own_state.sessions.count() == 0) {
            reportDrained(ring, front_ring, role.index.ring_idx);
            return;
        }
    }
}

/// Drains every replay-queue head whose recorded retry time is already due.
/// The due-ness check is the caller's job; `popReplayHead` itself does no time
/// math.
fn drainReplay(
    ctrl: *lifetime.Controller,
    st: *state.IndexState,
    logger: *lifetime.LoggerStuff,
    ring_idx: u16,
) void {
    const log = &logger.logger;

    while (true) {
        const retry_time = (st.replay_queue.peekRetryTime() catch |err| {
            log.err("index replay queue peek failed", .{ .ring_idx = ring_idx, .err = @errorName(err) });
            return;
        }) orelse return;

        if (retry_time > lifetime.nowRealtimeNs()) return;

        const reactivated = ctrl.popReplayHead(st) catch |err| {
            log.err("index replay drain failed", .{ .ring_idx = ring_idx, .err = @errorName(err) });
            return;
        };
        const session = reactivated orelse return;

        log.info("session reactivated for replay", .{
            .ring_idx = ring_idx,
            .new_id = @as(u64, @truncate(session.new_id)),
        });
    }
}

/// Tells the parent front that this index has stopped. The front ignores the
/// payload and reads its own per-index bit set instead.
fn reportDrained(ring: *lifetime.RingStuff, front_ring: *zigring.Ring, ring_idx: u16) void {
    while (true) {
        if (ring.ring.pushMsgRing(front_ring, messages.IndexDrainedIdx, ring_idx, .{})) |_| {
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
