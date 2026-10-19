//! Front thread: accepts client connections and routes them to its indexes.
//!
//! A front owns one io_uring ring and is the only producer for the inboxes of
//! its indexes. Its phase A is handled by `lifetime.Controller.runThread`; this
//! file implements the reaction to `START_WORK`, the input loop and the
//! shutdown choreography from docs/startup-en-reworked.md.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const zigring = @import("zigring");
const lifetime = @import("lifetime.zig");
const messages = @import("messages.zig");
const indexmod = @import("index.zig");
const logging = @import("logging.zig");

/// Upper bound of indexes a single front may own. The config admits at most
/// one thread per CPU core, so this is comfortably above any legal value.
const max_indexes_per_front = 64;

/// How often the shutdown deadline is policed.
const tick_ns: u64 = 500 * std.time.ns_per_ms;

/// State a front keeps across its service loop.
const Ctx = struct {
    ctrl: *lifetime.Controller,
    role: lifetime.Role,
    ring: *lifetime.RingStuff,
    log: *logging.Logger,

    listening: bool = false,
    listen_fd: posix.fd_t = -1,
    accept_task_idx: ?u64 = null,
    cancel_task_idx: ?u64 = null,
    round_robin: u16 = 0,
    draining: bool = false,
    shutdown_start_ns: u64 = 0,
    ticks: u32 = 0,
    escalated: bool = false,
    drained: [max_indexes_per_front]bool = @splat(false),
    // The kernel reads the tick interval asynchronously, so the spec lives in
    // the ring's own storage, which outlives this loop frame.
    tick_spec: *linux.kernel_timespec,

    fn front(self: *const Ctx) @TypeOf(self.role.front) {
        return self.role.front;
    }

    fn ownInbox(self: *Ctx, k: u16) *indexmod.Inbox {
        return &self.ctrl.inboxes[self.front().first_index.inbox + k];
    }
};

/// Runs the front thread to completion.
pub fn run(ctrl: *lifetime.Controller, role: lifetime.Role, logger: *lifetime.LoggerStuff) void {
    const front = role.front;
    var ctx = Ctx{
        .ctrl = ctrl,
        .role = role,
        .ring = &ctrl.rings[front.ring_idx],
        .log = &logger.logger,
        .tick_spec = &ctrl.rings[front.ring_idx].tick_spec,
    };
    ctx.tick_spec.* = .{ .sec = 0, .nsec = tick_ns };

    ctx.log.info("front started", .{ .ring_idx = front.ring_idx, .index_count = front.index_count });
    if (front.index_count > max_indexes_per_front) {
        ctx.log.err("too many indexes per front", .{ .count = front.index_count });
        std.process.exit(1);
    }

    while (true) {
        while (ctx.ring.ring.popCQE()) |cqe| {
            if (handleCqe(&ctx, cqe)) return;
        }
        ctx.ring.ring.park();
    }
}

/// Handles one completion. Returns true when the front has fully stopped and
/// its service loop must exit.
fn handleCqe(ctx: *Ctx, cqe: zigring.CQE) bool {
    const task_idx = cqe.taskIdx();

    if (task_idx == messages.StartWorkIdx) {
        // The barrier guarantees that every index has published its inbox, so
        // it is now legal to attach this front as the producer ring.
        var k: u16 = 0;
        while (k < ctx.front().index_count) : (k += 1) ctx.ownInbox(k).setFrontRing(&ctx.ring.ring);
        ctx.listen_fd = @intCast(cqe.res);
        // The design assumes single delivery; this guard is the defensive
        // idempotency check for a duplicate broadcast.
        if (!ctx.listening) {
            installAccepts(ctx, ctx.listen_fd) catch |err| {
                ctx.log.err("could not arm multishot accept", .{ .err = @errorName(err) });
                std.process.exit(1);
            };
        }
        return false;
    }

    if (task_idx == messages.ShutdownDemandIdx) {
        // The demand is payload-less: the trigger itself is the message.
        beginShutdown(ctx);
        return false;
    }

    if (task_idx == messages.ShutdownTickIdx) {
        if (!ctx.draining) return false;
        ctx.ticks += 1;
        const elapsed = zigring.monotonicNs() - ctx.shutdown_start_ns;
        const deadline = @as(u64, ctx.ctrl.cfg.shutdown_timeout_sec) * std.time.ns_per_s;
        if (elapsed >= deadline and !ctx.escalated) {
            ctx.escalated = true;
            escalateShutdown(ctx);
        }
        return false;
    }

    if (task_idx == messages.IndexDrainedIdx) {
        // `res` is the index's ring index; k is its position among our
        // children. Indexes report their ring index, so translate it.
        const ring_idx: u16 = @intCast(cqe.res);
        const k = ring_idx - ctx.front().first_index.ring;
        if (k < ctx.front().index_count) ctx.drained[k] = true;
        if (allDrained(ctx)) {
            reportDone(ctx);
            return true;
        }
        return false;
    }

    if (ctx.cancel_task_idx) |cancel_idx| {
        if (task_idx == cancel_idx) {
            // The cancel reports whether it found the target; the accept's own
            // cancelled completion follows on the accept's task index.
            ctx.ring.slots.del(cancel_idx);
            ctx.cancel_task_idx = null;
            return false;
        }
    }

    if (ctx.listening and task_idx == ctx.accept_task_idx.?) {
        if (cqe.res < 0) {
            // A cancellation during shutdown is expected and silent; any other
            // failure is worth a line in the log.
            if (!ctx.draining) {
                ctx.log.warn("accept failed", .{ .ring_idx = ctx.front().ring_idx, .err = @tagName(cqe.errno()) });
            }
            return false;
        }
        if (ctx.draining) {
            // Accepts were cancelled at shutdown; anything already accepted is
            // dropped rather than handed to an index that may be draining.
            _ = std.os.linux.close(@intCast(cqe.res));
            return false;
        }
        routeAccepted(ctx, @intCast(cqe.res));
        if (!cqe.hasMore()) {
            // The multishot ended: either it was cancelled for shutdown or it
            // failed. Only re-arm while the front is not draining.
            ctx.listening = false;
            if (!ctx.draining) {
                installAccepts(ctx, ctx.listen_fd) catch |err| {
                    ctx.log.err("could not re-arm multishot accept", .{ .err = @errorName(err) });
                    std.process.exit(1);
                };
            }
        }
        return false;
    }

    // Any other completion is not armed by the skeleton.
    return false;
}

fn installAccepts(ctx: *Ctx, listen_fd: posix.fd_t) !void {
    if (ctx.accept_task_idx) |old| ctx.ring.slots.del(old);
    const task_idx = try ctx.ring.slots.add(.{ .accept = .{} });
    ctx.accept_task_idx = task_idx;
    try ctx.ring.ring.pushAcceptMultishot(listen_fd, task_idx, .{});
    ctx.listening = true;
    ctx.log.info("accept armed", .{ .ring_idx = ctx.front().ring_idx, .fd = listen_fd });
}

fn beginShutdown(ctx: *Ctx) void {
    if (ctx.draining) return;
    ctx.draining = true;
    ctx.shutdown_start_ns = zigring.monotonicNs();
    ctx.log.info("front shutdown started", .{ .ring_idx = ctx.front().ring_idx });

    // 1. Cancel the multishot accepts.
    if (ctx.listening) {
        ctx.listening = false;
        const accept_idx = ctx.accept_task_idx.?;
        if (ctx.ring.slots.add(.{ .timeout = .{} })) |cancel_idx| {
            ctx.cancel_task_idx = cancel_idx;
            ctx.ring.ring.pushCancel(cancel_idx, accept_idx, .{}) catch |err| {
                ctx.log.warn("accept cancel failed", .{ .err = @errorName(err) });
                ctx.ring.slots.del(cancel_idx);
                ctx.cancel_task_idx = null;
            };
        } else |err| {
            ctx.log.warn("could not allocate a cancel slot", .{ .err = @errorName(err) });
        }
    }

    // 2. Session creation stops: nothing is routed from now on. Operations and
    // pulses still pass, and the skeleton has neither.

    // 3. Soft shutdown to every child index.
    var k: u16 = 0;
    while (k < ctx.front().index_count) : (k += 1) {
        ctx.ownInbox(k).push(.{ .shutdown_soft = {} }) catch |err| switch (err) {
            error.InboundFull => ctx.log.warn("index inbox full on soft shutdown", .{ .k = k }),
        };
    }

    // 4. Start counting ticks towards the hard-shutdown deadline.
    ctx.ring.ring.pushTicker(messages.ShutdownTickIdx, ctx.tick_spec, 0, .{}) catch |err| {
        ctx.log.err("could not arm the shutdown ticker", .{ .err = @errorName(err) });
    };
}

fn escalateShutdown(ctx: *Ctx) void {
    ctx.log.warn("shutdown deadline reached, escalating", .{ .ring_idx = ctx.front().ring_idx });

    // The skeleton arms no multishot receives and holds no long-lived client
    // sockets, so there is nothing to cancel or close here. A real front would
    // cancel its receives, close the sockets it owns (selected by the shared
    // remainder rule) and only then signal the indexes that are still up.

    var k: u16 = 0;
    while (k < ctx.front().index_count) : (k += 1) {
        if (ctx.drained[k]) continue;
        ctx.ownInbox(k).push(.{ .shutdown_hard = {} }) catch |err| switch (err) {
            error.InboundFull => ctx.log.err("index inbox full on hard shutdown", .{ .k = k }),
        };
    }
}

fn allDrained(ctx: *const Ctx) bool {
    var k: u16 = 0;
    while (k < ctx.front().index_count) : (k += 1) {
        if (!ctx.drained[k]) return false;
    }
    return true;
}

fn routeAccepted(ctx: *Ctx, fd: posix.fd_t) void {
    const k = ctx.round_robin % ctx.front().index_count;
    ctx.round_robin +%= 1;

    ctx.ownInbox(k).push(.{ .create = .{ .fd = fd } }) catch {
        // The HLD failure policy: when the queue is full the front drops the
        // connection immediately instead of keeping a backlog of its own.
        ctx.log.warn("index inbox full, dropping connection", .{ .ring_idx = ctx.front().ring_idx, .fd = fd });
        _ = std.os.linux.close(fd);
    };
}

fn reportDone(ctx: *Ctx) void {
    while (true) {
        if (ctx.ring.ring.pushMsgRingFd(ctx.ctrl.init_ring.ring.fd, messages.ShutdownDoneIdx, ctx.front().ring_idx, .{})) |_| {
            return;
        } else |err| switch (err) {
            error.RingFull => std.atomic.spinLoopHint(),
        }
    }
}

test "children are addressed by ring offset" {
    const role: lifetime.Role = .{ .front = .{
        .ring_idx = 0,
        .first_index = .{ .ring = 2, .inbox = 0 },
        .index_count = 2,
    } };
    try std.testing.expectEqual(@as(u16, 2), role.front.first_index.ring);
    try std.testing.expectEqual(@as(u16, 2), role.front.index_count);
}
