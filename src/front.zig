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
const config = @import("config.zig");
const messages = @import("messages.zig");
const indexmod = @import("index.zig");
const logging = @import("logging.zig");
const state = @import("state.zig");
const reply = @import("reply.zig");
const cross_task = @import("cross_task.zig");
const wire = @import("wire.zig");

/// Upper bound of indexes a single front may own. The config admits at most
/// one thread per CPU core, so this is comfortably above any legal value. The
/// socket bookkeeping sizes its counter row by the same value (2.3).
const max_indexes_per_front = lifetime.max_indexes_per_front;

/// How often the shutdown deadline is policed.
const shutdown_tick_ns: u64 = 500 * std.time.ns_per_ms;

/// The expiry wheel of a front: the client sockets against their last traffic
/// (2.3). The block shape is the same modest default the index wheel uses.
const Wheel = indexmod.Wheel;

/// One accepted mirror connection whose greeting is still on its way (2.3).
///
/// The descriptor is the front's until the hand-off to an index. The buffer
/// is the greeting the receive fills, a heap allocation that travels with the
/// receive's slot; it is freed at the completion, which is also where the
/// entry leaves the list. An expired entry stays until that completion
/// arrives, so the kernel never writes into freed memory; the `expired` flag
/// tells the completion that the deadline, not the peer, ended the read.
const PendingGreeting = struct {
    fd: posix.fd_t,
    buf: [*]u8,
    /// The slot of the armed receive, the identity of the greeting: a
    /// descriptor value may already belong to a newer connection by the time
    /// an abandoned receive completes.
    task_idx: u64,
    /// The absolute second the greeting must have arrived by.
    deadline_second: u32,
    expired: bool = false,
    /// Whether the descriptor was already closed by a failed cancel, so the
    /// completion must not close it a second time.
    closed: bool = false,
};

/// State a front keeps across its service loop.
const Ctx = struct {
    ctrl: *lifetime.Controller,
    role: lifetime.Role,
    ring: *lifetime.RingStuff,
    log: *logging.Logger,
    log_stuff: *lifetime.LoggerStuff,

    listening: bool = false,
    listen_fd: posix.fd_t = -1,
    accept_task_idx: ?u64 = null,
    cancel_task_idx: ?u64 = null,
    round_robin: u16 = 0,
    /// How many accepts this front has taken. The tag is minted from it (2.3):
    /// `serial * Fno + (front_idx + 1)`, the zero invalid, so the owner sits
    /// in the low bits and the accept generation in the high ones.
    accept_serial: usize = 0,
    draining: bool = false,
    shutdown_start_ns: u64 = 0,
    ticks: u32 = 0,
    escalated: bool = false,
    drained: [max_indexes_per_front]bool = @splat(false),
    // The kernel reads the tick interval asynchronously, so the spec lives in
    // the ring's own storage, which outlives this loop frame.
    tick_spec: *linux.kernel_timespec,

    /// The tick relay's round robin over this front's own indexes (2.3): every
    /// tick makes exactly one index check its sessions.
    tick_round_robin: u16 = 0,
    /// The maximum inactivity interval in whole seconds, converted once at
    /// startup from `session_inactivity_timeout` (2.7).
    inactivity_secs: u32 = 0,
    /// The same interval as wheel ticks, so a socket is scheduled at its own
    /// deadline instead of after a full wheel round (2.7).
    inactivity_ticks: u32 = 0,
    /// The front's own socket wheel: the client sockets against their last
    /// traffic. Allocated at startup; null in tests that do not need it.
    wheel: ?*Wheel = null,
    /// Scratch buffer of the wheel's matured sets, grown by the wheel.
    wheel_scratch: []u64 = &.{},
    /// Descriptors waiting for the deferred close (2.3). A socket enters once,
    /// when its close is prepared, and leaves when the drain condition holds
    /// and the descriptor is closed.
    closing: std.ArrayListUnmanaged(posix.fd_t) = .empty,
    /// The kernel reads these timeout specs asynchronously, so they live in the
    /// context, which outlives every ticker armed with them.
    interval_spec: linux.kernel_timespec = .{ .sec = 0, .nsec = 0 },
    stagger_spec: linux.kernel_timespec = .{ .sec = 0, .nsec = 0 },

    /// The replication listener of `cluster` mode (2.3), owned by the front
    /// like its client listener: negative in single-host mode, where there is
    /// no mirror to accept.
    replication_fd: posix.fd_t = -1,
    replication_listening: bool = false,
    replication_accept_task_idx: ?u64 = null,
    replication_cancel_task_idx: ?u64 = null,
    /// The deadline of one greeting read, in whole seconds, converted once at
    /// startup from `consensus_timeout` (2.3).
    greeting_timeout_secs: u32 = 0,
    /// The mirror connections accepted but not yet behind their greeting: the
    /// front owns their descriptors until the hand-off to an index (2.3).
    pending_greetings: std.ArrayListUnmanaged(PendingGreeting) = .empty,

    fn front(self: *const Ctx) @TypeOf(self.role.front) {
        return self.role.front;
    }

    fn ownInbox(self: *Ctx, k: u16) *indexmod.Inbox {
        return &self.ctrl.inboxes[self.front().first_index.inbox_idx + k];
    }

    /// Allocates the socket wheel and converts the two configured durations
    /// into the kernel forms the tickers and the sweep need (2.3, 2.7). Both
    /// `tick_interval` and `session_inactivity_timeout` are proven positive by
    /// `Config.validate`.
    fn initTiming(self: *Ctx) !void {
        const allocator = self.ctrl.allocator;
        const interval_ns: u64 = @intCast(self.ctrl.cfg.tick_interval.value.nanos);
        const inactivity_ns: u64 = @intCast(self.ctrl.cfg.session_inactivity_timeout.value.nanos);

        self.inactivity_secs = indexmod.durationSeconds(@intCast(inactivity_ns));
        self.greeting_timeout_secs = indexmod.durationSeconds(
            self.ctrl.cfg.consensus_timeout.value.nanos,
        );
        self.inactivity_ticks = indexmod.ticksOf(inactivity_ns, interval_ns);
        self.interval_spec = timespecOf(interval_ns);
        // The stagger of 2.3: front `f` starts `f * (interval / Fno)` after the
        // first, so the socket scans of the fronts never fall on one instant.
        const stagger_ns = interval_ns / @as(u64, self.ctrl.cfg.fronts) * self.front().ring_idx;
        self.stagger_spec = timespecOf(stagger_ns);

        self.wheel = try Wheel.init(allocator, indexmod.wheelTicks(
            @intCast(inactivity_ns),
            @intCast(interval_ns),
        ));
    }

    fn deinitTiming(self: *Ctx) void {
        const allocator = self.ctrl.allocator;
        if (self.wheel_scratch.len != 0) allocator.free(self.wheel_scratch);
        self.wheel_scratch = &.{};
        if (self.wheel) |wheel| wheel.deinit();
        self.wheel = null;
        self.closing.deinit(allocator);
        // A greeting that never completed is released here: its socket was
        // closed when the front began to drain, and only the buffer is left.
        for (self.pending_greetings.items) |entry| {
            allocator.free(entry.buf[0..wire.greeting_len]);
        }
        self.pending_greetings.deinit(allocator);
    }
};

/// The absolute second of the socket clock: the Unix epoch, the base of the
/// `last tick` field and of the tick every front relays (2.3).
fn nowSecond() u32 {
    return @intCast(zigring.nowNs() / std.time.ns_per_s);
}

/// The kernel form of a non-negative nanosecond count.
fn timespecOf(nanos: u64) linux.kernel_timespec {
    return .{
        .sec = @intCast(nanos / std.time.ns_per_s),
        .nsec = @intCast(nanos % std.time.ns_per_s),
    };
}

/// Runs the front thread to completion. `role` is the role the thread derived
/// from its `ring_idx` before reporting `INITIALIZED`.
pub fn run(ctrl: *lifetime.Controller, role: lifetime.Role, logger: *lifetime.LoggerStuff) void {
    const front = role.front;
    var ctx = Ctx{
        .ctrl = ctrl,
        .role = role,
        .ring = &ctrl.rings[front.ring_idx],
        .log = &logger.logger,
        .log_stuff = logger,
        .tick_spec = &ctrl.rings[front.ring_idx].tick_spec,
    };
    ctx.tick_spec.* = .{ .sec = 0, .nsec = shutdown_tick_ns };
    ctx.initTiming() catch |err| {
        ctx.log.err("front timing initialization failed", .{ .ring_idx = front.ring_idx, .err = @errorName(err) });
        std.process.exit(1);
    };
    defer ctx.deinitTiming();

    ctx.log.info("front started", .{ .ring_idx = front.ring_idx, .index_count = front.index_count });
    if (front.index_count > max_indexes_per_front) {
        ctx.log.err("too many indexes per front", .{ .count = front.index_count });
        std.process.exit(1);
    }

    // The replication endpoint is bound before the barrier, so the mirrors of
    // the other hosts find a listener as early as possible; the accepts are
    // armed at `START_WORK`, together with the rest of the working phase (2.3).
    defer if (ctx.replication_fd >= 0) {
        _ = std.os.linux.close(ctx.replication_fd);
        ctx.replication_fd = -1;
    };
    if (ctrl.cfg.replication.mode == .cluster) {
        ctx.replication_fd = ctrl.createReplicationSocket() catch |err| {
            ctx.log.err("could not bind the replication listener", .{
                .ring_idx = front.ring_idx,
                .err = @errorName(err),
            });
            std.process.exit(1);
        };
        ctx.log.info("replication listener bound", .{
            .ring_idx = front.ring_idx,
            .fd = ctx.replication_fd,
            .greeting_timeout_secs = ctx.greeting_timeout_secs,
        });
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

    if (ctx.log_stuff.completeLogging(task_idx)) return false;

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
        // The replication listener takes its accepts here too: the endpoint is
        // bound before the barrier, and the working phase is when a mirror of
        // another host may be answered (2.3).
        if (ctx.replication_fd >= 0 and !ctx.replication_listening) {
            installReplicationAccepts(ctx) catch |err| {
                ctx.log.err("could not arm the replication accept", .{ .err = @errorName(err) });
                std.process.exit(1);
            };
        }
        // The children can be woken now, so the tick relay has a producer ring
        // to post its wakeups through (2.3).
        armTicker(ctx);
        return false;
    }

    if (task_idx == messages.CrossTaskMessageIdx) {
        handleCrossTask(ctx, @intCast(cqe.res));
        return false;
    }

    if (ctx.ring.slots.get(task_idx)) |task| switch (task) {
        .front_tick => |tick| {
            if (tick.run) {
                // A multishot ticker: the slot stays armed until the thread
                // exits, the completion only drives one round (2.3).
                frontTick(ctx);
            } else {
                // The staggered one-shot is done; the periodic ticker starts.
                ctx.ring.slots.del(task_idx);
                armPeriodicTicker(ctx);
            }
            return false;
        },
        // The front's own reply, written on a complaint or a rogue op (2.3).
        .front_reply => |op| {
            ctx.ring.slots.del(task_idx);
            finishFrontReply(ctx, op.fd, op.buf[0..op.len], cqe.res);
            return false;
        },
        // The greeting of an accepted mirror connection (2.3): the descriptor
        // is routed to the index service the greeting names.
        .replication_greeting => |op| {
            ctx.ring.slots.del(task_idx);
            finishGreeting(ctx, task_idx, op.fd, op.buf, cqe.res);
            return false;
        },
        // A cancelled greeting read: the receive's own completion follows and
        // releases the buffer.
        .greeting_cancel => {
            ctx.ring.slots.del(task_idx);
            return false;
        },
        else => {},
    };

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
        // `res` is the index's ring index, the index's slot in the shared ring
        // array; k is its position among our children, so translate it.
        const ring_idx: u16 = @intCast(cqe.res);
        const k = ring_idx - ctx.front().first_index.ring_idx;
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

    if (ctx.replication_cancel_task_idx) |cancel_idx| {
        if (task_idx == cancel_idx) {
            ctx.ring.slots.del(cancel_idx);
            ctx.replication_cancel_task_idx = null;
            return false;
        }
    }

    // A mirror connection arrived on the replication listener (2.3): its
    // greeting names the index service it serves, so nothing is routed before
    // the greeting has been read.
    if (ctx.replication_listening and task_idx == ctx.replication_accept_task_idx.?) {
        if (cqe.res < 0) {
            if (!ctx.draining) {
                ctx.log.warn("replication accept failed", .{
                    .ring_idx = ctx.front().ring_idx,
                    .err = @tagName(cqe.errno()),
                });
            }
        } else if (ctx.draining) {
            _ = std.os.linux.close(@intCast(cqe.res));
        } else {
            readGreeting(ctx, @intCast(cqe.res));
        }
        if (!cqe.hasMore()) {
            ctx.replication_listening = false;
            if (!ctx.draining) {
                installReplicationAccepts(ctx) catch |err| {
                    ctx.log.err("could not re-arm the replication accept", .{ .err = @errorName(err) });
                    std.process.exit(1);
                };
            }
        }
        return false;
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

/// Arms the front's tick machinery (2.3): a one-shot stagger of
/// `f * (tick_interval / Fno)` and then the periodic ticker. A zero stagger
/// (the first front) starts the periodic ticker straight away.
fn armTicker(ctx: *Ctx) void {
    const stagger_ns: u64 = @as(u64, @intCast(ctx.stagger_spec.sec)) * std.time.ns_per_s +
        @as(u64, @intCast(ctx.stagger_spec.nsec));
    if (stagger_ns == 0) {
        armPeriodicTicker(ctx);
        return;
    }

    const task_idx = ctx.ring.slots.add(.{ .front_tick = .{ .run = false } }) catch |err| {
        ctx.log.err("could not allocate the stagger slot", .{ .err = @errorName(err) });
        armPeriodicTicker(ctx);
        return;
    };
    ctx.ring.ring.pushTicker(task_idx, &ctx.stagger_spec, 1, .{}) catch |err| {
        ctx.ring.slots.del(task_idx);
        ctx.log.err("could not arm the stagger ticker", .{ .err = @errorName(err) });
        armPeriodicTicker(ctx);
    };
}

/// Arms the multishot ticker that drives the tick relay and the socket sweep.
fn armPeriodicTicker(ctx: *Ctx) void {
    const task_idx = ctx.ring.slots.add(.{ .front_tick = .{ .run = true } }) catch |err| {
        ctx.log.err("could not allocate the periodic tick slot", .{ .err = @errorName(err) });
        return;
    };
    ctx.ring.ring.pushTicker(task_idx, &ctx.interval_spec, 0, .{}) catch |err| {
        ctx.ring.slots.del(task_idx);
        ctx.log.err("could not arm the periodic ticker", .{ .err = @errorName(err) });
    };
}

/// One tick of the front's clock (2.3): the current absolute second goes to
/// exactly one child, the socket wheel matures, and the prepared closes whose
/// drain condition holds are executed.
fn frontTick(ctx: *Ctx) void {
    const second = nowSecond();
    relayTick(ctx, second);
    sweepSockets(ctx, second);
    expireGreetings(ctx, second);
    drainClosing(ctx);
}

/// Pushes this tick into the next `IndexInbox`, round robin over the front's
/// own children: one tick, one index checking its sessions (2.3).
fn relayTick(ctx: *Ctx, second: u32) void {
    const count = ctx.front().index_count;
    if (count == 0) return;
    const k = ctx.tick_round_robin % count;
    ctx.tick_round_robin +%= 1;
    ctx.ownInbox(k).push(.{ .tick = second }) catch |err| switch (err) {
        error.InboundFull => ctx.log.warn("index inbox full, tick dropped", .{
            .ring_idx = ctx.front().ring_idx,
            .k = k,
        }),
    };
}

/// The front's own wheel: every matured socket is either re-armed (it moved
/// within the inactivity interval) or marked for the deferred close (2.3).
fn sweepSockets(ctx: *Ctx, second: u32) void {
    const wheel = ctx.wheel orelse return;
    const shifted = wheel.shift(ctx.wheel_scratch) catch |err| {
        ctx.log.err("front socket wheel could not shift", .{
            .ring_idx = ctx.front().ring_idx,
            .err = @errorName(err),
        });
        return;
    };
    ctx.wheel_scratch = shifted.backing;

    for (shifted.backing[0..shifted.size]) |value| {
        const fd: posix.fd_t = @intCast(value);
        const entry = ctx.ctrl.sockets.info(fd) orelse continue;
        if (entry.tag == 0) continue;
        if (lifetime.SocketTable.ownerOf(entry.tag, ctx.ctrl.cfg.fronts) != ctx.front().ring_idx) continue;
        if (second -% entry.last_tick < ctx.inactivity_secs) {
            _ = wheel.add_delay(value, ctx.inactivity_ticks) catch |err| {
                ctx.log.err("could not re-arm a socket deadline", .{
                    .ring_idx = ctx.front().ring_idx,
                    .fd = fd,
                    .err = @errorName(err),
                });
            };
            continue;
        }
        ctx.log.info("client socket outlived its inactivity interval", .{
            .ring_idx = ctx.front().ring_idx,
            .fd = fd,
            .last_tick = entry.last_tick,
        });
        markClosing(ctx, fd);
    }
}

/// Marks a socket for the deferred close (2.3): from now on no op of it is
/// routed, and the ticker closes the descriptor once everything the indexes
/// hold on it is retired and the front's own reply has landed.
fn markClosing(ctx: *Ctx, fd: posix.fd_t) void {
    const entry = ctx.ctrl.sockets.info(fd) orelse return;
    if (entry.tag == 0 or entry.closing) return;

    ctx.closing.append(ctx.ctrl.allocator, fd) catch |err| {
        ctx.log.err("could not record a deferred close", .{
            .ring_idx = ctx.front().ring_idx,
            .fd = fd,
            .err = @errorName(err),
        });
        // The ticker walks only this list; a socket it cannot record is closed
        // right away, but only when no index still holds an op on it.
        if (ctx.ctrl.sockets.drained(fd)) closeSocket(ctx, fd);
        return;
    };
    entry.closing = true;
}

/// Walks the prepared closes and executes the ones whose drain condition holds
/// (2.3). The counters are monotone, so a straggler keeps the sum short and
/// the socket simply waits for the next tick.
fn drainClosing(ctx: *Ctx) void {
    var i: usize = 0;
    while (i < ctx.closing.items.len) {
        const fd = ctx.closing.items[i];
        const entry = ctx.ctrl.sockets.info(fd) orelse {
            _ = ctx.closing.swapRemove(i);
            continue;
        };
        if (entry.tag == 0) {
            _ = ctx.closing.swapRemove(i);
            continue;
        }
        if (entry.reply_pending or !ctx.ctrl.sockets.drained(fd)) {
            i += 1;
            continue;
        }

        ctx.log.info("deferred close drained", .{
            .ring_idx = ctx.front().ring_idx,
            .fd = fd,
        });
        closeSocket(ctx, fd);
        _ = ctx.closing.swapRemove(i);
    }
}

/// Closes one drained socket: the bookkeeping entry is zeroed first, so the
/// descriptor value can never be mistaken for the old client after the kernel
/// hands it out again (2.3).
fn closeSocket(ctx: *Ctx, fd: posix.fd_t) void {
    ctx.ctrl.sockets.clear(fd);
    _ = std.os.linux.close(fd);
}

/// Handles one slot-borne cross-task message. The slot is released before the
/// reaction runs, so a reaction that pushes another message finds room.
fn handleCrossTask(ctx: *Ctx, slot_idx: u32) void {
    const slots = &ctx.ctrl.cross_slots;
    const task = slots.at(slot_idx).*;
    defer slots.release(slot_idx);

    switch (task) {
        .Complaint => |complaint| handleComplaint(ctx, complaint),
        else => ctx.log.warn("front received an unexpected cross-task message", .{
            .ring_idx = ctx.front().ring_idx,
        }),
    }
}

/// Validates a complaint against the front's own bookkeeping (2.3). A tag that
/// does not match the entry, a socket owned by another front, or one already
/// marked for the close is a `Nop`: the client is gone, or the descriptor
/// value belongs to someone else.
fn handleComplaint(ctx: *Ctx, complaint: @FieldType(cross_task.CrossTask, "Complaint")) void {
    const entry = ctx.ctrl.sockets.info(complaint.fd) orelse {
        ctx.log.info("complaint for a descriptor outside the socket table", .{
            .ring_idx = ctx.front().ring_idx,
            .fd = complaint.fd,
        });
        return;
    };
    const owned = entry.tag != 0 and
        entry.tag == complaint.tag and
        lifetime.SocketTable.ownerOf(entry.tag, ctx.ctrl.cfg.fronts) == ctx.front().ring_idx;
    if (!owned or entry.closing) {
        ctx.log.info("complaint did not validate, ignored", .{
            .ring_idx = ctx.front().ring_idx,
            .fd = complaint.fd,
            .tag = complaint.tag,
            .code = @tagName(complaint.code),
        });
        return;
    }

    var text: [reply.max_len]u8 = undefined;
    const body = reply.forComplaint(complaint.code, complaint.session_id, &text);
    answerAndClose(ctx, complaint.fd, body);
}

/// Writes the angry reply the front owes on a validated complaint or a rogue
/// session op, and marks the socket for the deferred close (2.3). The close
/// itself waits for the reply completion, so the descriptor stays open until
/// the client has its answer.
fn answerAndClose(ctx: *Ctx, fd: posix.fd_t, body: []const u8) void {
    markClosing(ctx, fd);
    const entry = ctx.ctrl.sockets.info(fd) orelse return;
    if (entry.tag == 0) return;
    entry.reply_pending = true;
    pushFrontReply(ctx, fd, body);
}

/// The front's own direct write on a client fd: the complaint answer and the
/// rogue op answer. The buffer travels with the slot and is freed on
/// completion.
fn pushFrontReply(ctx: *Ctx, fd: posix.fd_t, body: []const u8) void {
    const allocator = ctx.ctrl.allocator;
    const owned = allocator.dupe(u8, body) catch |err| {
        ctx.log.err("could not allocate a front reply", .{
            .ring_idx = ctx.front().ring_idx,
            .fd = fd,
            .err = @errorName(err),
        });
        clearReplyPending(ctx, fd);
        return;
    };

    const task_idx = ctx.ring.slots.add(.{ .front_reply = .{
        .fd = fd,
        .buf = owned.ptr,
        .len = @intCast(owned.len),
    } }) catch |err| {
        allocator.free(owned);
        ctx.log.err("could not allocate a front reply slot", .{
            .ring_idx = ctx.front().ring_idx,
            .fd = fd,
            .err = @errorName(err),
        });
        clearReplyPending(ctx, fd);
        return;
    };

    ctx.ring.ring.pushWrite(fd, task_idx, owned.ptr, owned.len, .{}) catch |err| {
        ctx.ring.slots.del(task_idx);
        allocator.free(owned);
        ctx.log.err("could not arm a front reply", .{
            .ring_idx = ctx.front().ring_idx,
            .fd = fd,
            .err = @errorName(err),
        });
        clearReplyPending(ctx, fd);
    };
}

/// The completion of the front's own reply: the buffer is released, the reply
/// leaves the drain condition, and the close executes if nothing else is in
/// flight.
fn finishFrontReply(ctx: *Ctx, fd: posix.fd_t, body: []u8, res: i32) void {
    ctx.ctrl.allocator.free(body);
    if (res < 0) {
        ctx.log.warn("the front reply failed", .{
            .ring_idx = ctx.front().ring_idx,
            .fd = fd,
            .err = @tagName(@as(std.os.linux.E, @fromBackingInt(@intCast(-res)))),
        });
    }
    clearReplyPending(ctx, fd);
    drainClosing(ctx);
}

fn clearReplyPending(ctx: *Ctx, fd: posix.fd_t) void {
    const entry = ctx.ctrl.sockets.info(fd) orelse return;
    entry.reply_pending = false;
}

fn installAccepts(ctx: *Ctx, listen_fd: posix.fd_t) !void {
    if (ctx.accept_task_idx) |old| ctx.ring.slots.del(old);
    const task_idx = try ctx.ring.slots.add(.{ .accept = .{} });
    ctx.accept_task_idx = task_idx;
    try ctx.ring.ring.pushAcceptMultishot(listen_fd, task_idx, .{});
    ctx.listening = true;
    ctx.log.info("accept armed", .{ .ring_idx = ctx.front().ring_idx, .fd = listen_fd });
}

/// Arms the multishot accept of this front's replication listener (2.3). The
/// endpoint is shared by every front of the process, so the front that takes a
/// connection is not necessarily the one owning the index service its greeting
/// names; the routing below works on the rings, not on the front's own share.
fn installReplicationAccepts(ctx: *Ctx) !void {
    if (ctx.replication_fd < 0) return;
    if (ctx.replication_accept_task_idx) |old| ctx.ring.slots.del(old);
    const task_idx = try ctx.ring.slots.add(.{ .replication_accept = .{} });
    ctx.replication_accept_task_idx = task_idx;
    try ctx.ring.ring.pushAcceptMultishot(ctx.replication_fd, task_idx, .{});
    ctx.replication_listening = true;
    ctx.log.info("replication accept armed", .{
        .ring_idx = ctx.front().ring_idx,
        .fd = ctx.replication_fd,
    });
}

/// Arms the greeting read of a freshly accepted mirror connection (2.3). The
/// buffer is a heap allocation that travels with the receive's slot, and the
/// deadline is the absolute second the greeting must have arrived by, checked
/// by the tick the front already runs.
fn readGreeting(ctx: *Ctx, fd: posix.fd_t) void {
    const allocator = ctx.ctrl.allocator;
    const buf = allocator.alloc(u8, wire.greeting_len) catch |err| {
        ctx.log.err("could not allocate a greeting buffer", .{
            .ring_idx = ctx.front().ring_idx,
            .fd = fd,
            .err = @errorName(err),
        });
        _ = std.os.linux.close(fd);
        return;
    };

    const task_idx = ctx.ring.slots.add(.{ .replication_greeting = .{
        .fd = fd,
        .buf = buf.ptr,
    } }) catch |err| {
        allocator.free(buf);
        ctx.log.err("could not allocate a greeting slot", .{
            .ring_idx = ctx.front().ring_idx,
            .fd = fd,
            .err = @errorName(err),
        });
        _ = std.os.linux.close(fd);
        return;
    };

    ctx.ring.ring.pushRecv(fd, task_idx, buf, .{}) catch |err| {
        ctx.ring.slots.del(task_idx);
        allocator.free(buf);
        ctx.log.err("could not arm the greeting read", .{
            .ring_idx = ctx.front().ring_idx,
            .fd = fd,
            .err = @errorName(err),
        });
        _ = std.os.linux.close(fd);
        return;
    };

    ctx.pending_greetings.append(allocator, .{
        .fd = fd,
        .buf = buf.ptr,
        .task_idx = task_idx,
        .deadline_second = nowSecond() +% ctx.greeting_timeout_secs,
    }) catch |err| {
        // Without its deadline an unanswered greeting would stall the socket
        // forever, so the connection is dropped instead. The receive is
        // cancelled explicitly, so its completion still releases the buffer.
        ctx.log.err("could not record a pending greeting", .{
            .ring_idx = ctx.front().ring_idx,
            .fd = fd,
            .err = @errorName(err),
        });
        _ = cancelGreetingRead(ctx, fd, task_idx);
        _ = std.os.linux.close(fd);
    };
}

/// The completion of a greeting read (2.3). The bytes are decoded, the peer is
/// validated against the shard, and the descriptor is handed to the index
/// service the greeting names.
fn finishGreeting(ctx: *Ctx, task_idx: u64, fd: posix.fd_t, buf: [*]u8, res: i32) void {
    const allocator = ctx.ctrl.allocator;
    const entry = findGreeting(ctx, task_idx);
    if (entry) |index| {
        const pending = ctx.pending_greetings.swapRemove(index);
        finishGreetingOf(ctx, pending, res);
        allocator.free(buf[0..wire.greeting_len]);
        return;
    }

    // No bookkeeping: the read was abandoned before its entry existed, which
    // only leaves the buffer to release.
    allocator.free(buf[0..wire.greeting_len]);
    ctx.log.warn("greeting completion without its bookkeeping", .{
        .ring_idx = ctx.front().ring_idx,
        .fd = fd,
        .res = res,
    });
}

/// Applies one completed greeting read: the descriptor is the front's until it
/// is handed over, so every failure closes it here.
fn finishGreetingOf(ctx: *Ctx, pending: PendingGreeting, res: i32) void {
    if (pending.expired) {
        // The deadline cancelled the read; the descriptor is the front's and
        // is closed here, once the kernel no longer writes into the buffer.
        if (!pending.closed) _ = std.os.linux.close(pending.fd);
        return;
    }

    if (res != wire.greeting_len) {
        ctx.log.warn("mirror connection did not send its greeting", .{
            .ring_idx = ctx.front().ring_idx,
            .fd = pending.fd,
            .res = res,
        });
        _ = std.os.linux.close(pending.fd);
        return;
    }

    const greeting = wire.decodeGreeting(pending.buf[0..wire.greeting_len]) catch |err| {
        ctx.log.warn("malformed mirror greeting", .{
            .ring_idx = ctx.front().ring_idx,
            .fd = pending.fd,
            .err = @errorName(err),
        });
        _ = std.os.linux.close(pending.fd);
        return;
    };

    const cfg = ctx.ctrl.cfg;
    // Only the lesser host of a pair dials (2.3), so a connection from the own
    // host or from a greater one is not one this shard would open.
    if (greeting.host_idx >= cfg.replication.factor or greeting.host_idx >= cfg.host_index) {
        ctx.log.warn("mirror greeting names a host that does not dial", .{
            .ring_idx = ctx.front().ring_idx,
            .fd = pending.fd,
            .host_idx = greeting.host_idx,
            .factor = cfg.replication.factor,
            .own_host = cfg.host_index,
        });
        _ = std.os.linux.close(pending.fd);
        return;
    }
    if (greeting.index_idx >= cfg.indexes) {
        ctx.log.warn("mirror greeting names an index service outside the shard", .{
            .ring_idx = ctx.front().ring_idx,
            .fd = pending.fd,
            .index_idx = greeting.index_idx,
            .indexes = cfg.indexes,
        });
        _ = std.os.linux.close(pending.fd);
        return;
    }

    handOverMirror(ctx, pending.fd, greeting.host_idx, greeting.index_idx);
}

/// Finds the pending greeting of one receive slot, if it is still in flight.
fn findGreeting(ctx: *Ctx, task_idx: u64) ?usize {
    for (ctx.pending_greetings.items, 0..) |entry, i| {
        if (entry.task_idx == task_idx) return i;
    }
    return null;
}

/// Closes the mirror connections whose greeting did not arrive within
/// `consensus_timeout` (2.3). The receive is cancelled explicitly: closing the
/// descriptor would leave the kernel request holding the file, so the
/// completion that releases the buffer might never come.
fn expireGreetings(ctx: *Ctx, second: u32) void {
    for (ctx.pending_greetings.items) |*entry| {
        if (entry.expired) continue;
        const elapsed = @as(i64, second) - @as(i64, entry.deadline_second);
        if (elapsed < 0) continue;
        ctx.log.warn("mirror connection did not send its greeting in time", .{
            .ring_idx = ctx.front().ring_idx,
            .fd = entry.fd,
            .deadline_second = entry.deadline_second,
        });
        cancelGreeting(ctx, entry);
    }
}

/// Cancels one greeting read and marks the entry expired: the socket is closed
/// and the buffer released at the completion of the cancelled receive.
fn cancelGreeting(ctx: *Ctx, entry: *PendingGreeting) void {
    if (entry.expired) return;
    entry.expired = true;
    if (cancelGreetingRead(ctx, entry.fd, entry.task_idx)) return;

    // Without the cancel the receive may never complete, so the socket is
    // closed directly; the buffer stays with the slot until the ring is torn
    // down.
    entry.closed = true;
    _ = std.os.linux.close(entry.fd);
}

/// Arms the cancellation of one armed greeting receive. Returns whether the
/// cancel was submitted; a caller that gets false must close the socket itself
/// and accept that the receive's buffer outlives it.
fn cancelGreetingRead(ctx: *Ctx, fd: posix.fd_t, target_task_idx: u64) bool {
    const task_idx = ctx.ring.slots.add(.{ .greeting_cancel = .{ .fd = fd } }) catch |err| {
        ctx.log.err("could not allocate a greeting cancel", .{
            .ring_idx = ctx.front().ring_idx,
            .fd = fd,
            .err = @errorName(err),
        });
        return false;
    };
    ctx.ring.ring.pushCancel(task_idx, target_task_idx, .{}) catch |err| {
        ctx.ring.slots.del(task_idx);
        ctx.log.warn("greeting cancel failed", .{
            .ring_idx = ctx.front().ring_idx,
            .fd = fd,
            .err = @errorName(err),
        });
        return false;
    };
    return true;
}

/// Cancels every socket still waiting for its greeting (2.3). The buffers stay
/// with their receives and are released at the completions the cancels
/// trigger.
fn closePendingGreetings(ctx: *Ctx) void {
    for (ctx.pending_greetings.items) |*entry| {
        cancelGreeting(ctx, entry);
    }
}

/// Hands an accepted mirror connection to the index service its greeting names
/// (2.3): a cross-task slot carrying the descriptor and the dialling host, and
/// a `MSG_RING` into that index' ring. The index owns the descriptor from the
/// moment it reads the slot; a front that fails to post it closes the socket
/// itself.
fn handOverMirror(ctx: *Ctx, fd: posix.fd_t, host_idx: u8, index_idx: u16) void {
    const slot_idx = ctx.ctrl.cross_slots.acquire() catch |err| {
        ctx.log.err("could not acquire a mirror socket slot", .{
            .ring_idx = ctx.front().ring_idx,
            .fd = fd,
            .err = @errorName(err),
        });
        _ = std.os.linux.close(fd);
        return;
    };
    ctx.ctrl.cross_slots.at(slot_idx).* = .{ .MirrorSocket = .{ .fd = fd, .host_idx = host_idx } };

    const target = &ctx.ctrl.rings[ctx.ctrl.cfg.fronts + index_idx].ring;
    while (true) {
        if (ctx.ring.ring.pushMsgRing(target, messages.CrossTaskMessageIdx, slot_idx, .{})) |_| {
            ctx.log.info("mirror connection routed", .{
                .ring_idx = ctx.front().ring_idx,
                .fd = fd,
                .host_idx = host_idx,
                .index_idx = index_idx,
            });
            return;
        } else |err| switch (err) {
            error.RingFull => std.atomic.spinLoopHint(),
        }
    }
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

    // The replication listener stops the same way, and the connections still
    // being greeted have no peer to serve any more: the front owns them until
    // the hand-off, so it closes them.
    if (ctx.replication_listening) {
        ctx.replication_listening = false;
        const accept_idx = ctx.replication_accept_task_idx.?;
        if (ctx.ring.slots.add(.{ .timeout = .{} })) |cancel_idx| {
            ctx.replication_cancel_task_idx = cancel_idx;
            ctx.ring.ring.pushCancel(cancel_idx, accept_idx, .{}) catch |err| {
                ctx.log.warn("replication accept cancel failed", .{ .err = @errorName(err) });
                ctx.ring.slots.del(cancel_idx);
                ctx.replication_cancel_task_idx = null;
            };
        } else |err| {
            ctx.log.warn("could not allocate a replication cancel slot", .{ .err = @errorName(err) });
        }
    }
    closePendingGreetings(ctx);

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

/// Takes a freshly accepted client socket: mints its tag, stores it in the
/// shared array and opens the session. The tag is minted here, before anything
/// of the client is read, because the descriptor alone would identify the
/// client only until the front closes it and the kernel hands the same value
/// to a new, valid connection (2.3).
fn routeAccepted(ctx: *Ctx, fd: posix.fd_t) void {
    const tag = lifetime.SocketTable.mintTag(ctx.front().ring_idx, ctx.accept_serial, ctx.ctrl.cfg.fronts);
    ctx.accept_serial += 1;
    ctx.ctrl.sockets.set(fd, tag);
    ctx.ctrl.sockets.bumpTick(fd, nowSecond());

    // The socket joins the front's own wheel: the sweep prices its traffic
    // against `session_inactivity_timeout` (2.3).
    if (ctx.wheel) |wheel| {
        _ = wheel.add_delay(@intCast(fd), ctx.inactivity_ticks) catch |err| {
            ctx.log.err("could not arm a socket deadline", .{
                .ring_idx = ctx.front().ring_idx,
                .fd = fd,
                .err = @errorName(err),
            });
        };
    }

    // Stage 1 opens the session on the accept itself. Once the front reads
    // client frames (stage 2), the create request the client sends is the
    // source of this push, through the same route.
    routeCreate(ctx, fd, tag);
}

/// Passes a create over the front's own indexes by round robin: the operation
/// belongs to no index yet, so nothing else can name one (2.3). The endpoint
/// travels with it, so the index can reply without a session-to-fd map.
fn routeCreate(ctx: *Ctx, fd: posix.fd_t, tag: usize) void {
    if (isClosing(ctx, fd)) return;

    const k = ctx.round_robin % ctx.front().index_count;
    ctx.round_robin +%= 1;

    ctx.ownInbox(k).push(.{ .create = .{ .fd = fd, .tag = tag } }) catch {
        // The HLD failure policy: when the queue is full the front drops the
        // connection immediately instead of keeping a backlog of its own. No
        // op was pushed, so no index holds the socket and the close is sound.
        ctx.ctrl.sockets.clear(fd);
        ctx.log.warn("index inbox full, dropping connection", .{
            .ring_idx = ctx.front().ring_idx,
            .fd = fd,
            .tag = tag,
        });
        _ = std.os.linux.close(fd);
        return;
    };

    // The op is counted at the push, and this socket just showed traffic; the
    // index retires the counter with its reply (2.5).
    ctx.ctrl.sockets.bumpFront(fd);
    ctx.ctrl.sockets.bumpTick(fd, nowSecond());
}

/// The index among the front's own that serves a session: the `index_id` slice
/// of the session id (2.5). A session created within this front's share always
/// resolves; null means a rogue client named an index of another front.
fn indexSlot(first: lifetime.Role.IndexIdx, index_count: u16, session_id: u128) ?u16 {
    const index_id = state.IndexState.indexId(session_id);
    if (index_id < first.inbox_idx) return null;
    const k = index_id - first.inbox_idx;
    if (k >= index_count) return null;
    return k;
}

/// Routes one operation of an established session to the index owning it, not
/// by round robin: the session id itself names the index (2.3). What crosses
/// the boundary is the endpoint, so the session can remember where its reply
/// goes.
fn routeSessionOp(ctx: *Ctx, k: u16, fd: posix.fd_t, tag: usize, session_id: u128, op: state.Op) void {
    if (isClosing(ctx, fd)) return;

    ctx.ownInbox(k).push(.{ .session_op = .{
        .endpoint = .{ .fd = fd, .tag = tag },
        .session_id = session_id,
        .op = op,
    } }) catch |err| switch (err) {
        // The op was not pushed, so its counter is not bumped either: the drain
        // sum stays exact, and a socket marked later cannot be closed under an
        // op no index ever saw.
        error.InboundFull => {
            ctx.log.warn("index inbox full, could not route a session op", .{
                .ring_idx = ctx.front().ring_idx,
                .fd = fd,
                .k = k,
            });
            return;
        },
    };

    ctx.ctrl.sockets.bumpFront(fd);
    ctx.ctrl.sockets.bumpTick(fd, nowSecond());
}

/// Whether the socket is already marked for the deferred close: from the mark
/// on, no op of it is routed, so the front counter stops bumping (2.3).
fn isClosing(ctx: *Ctx, fd: posix.fd_t) bool {
    const entry = ctx.ctrl.sockets.info(fd) orelse return true;
    return entry.closing or entry.tag == 0;
}

/// A pulse is the client's keep-alive of an otherwise quiet connection: the
/// front consumes it, so no pulse ever reaches an `IndexInbox` (2.3). The only
/// thing it touches is the socket's last-tick field, which arrives with the
/// tick machinery of stage 2.
fn consumePulse(ctx: *Ctx, fd: posix.fd_t) void {
    // Per connection, never per session, and no counter moves: a pulse is not
    // an op (2.3).
    ctx.ctrl.sockets.bumpTick(fd, nowSecond());
}

/// What a client frame asks for, already differentiated by the front (2.3).
const Request = union(enum) {
    /// The keep-alive of an otherwise quiet connection. Indexes serve
    /// mutations only, so a pulse never leaves the front and never reaches an
    /// `IndexInbox`.
    pulse,
    /// A new session: dispatched over the front's own indexes by round robin,
    /// since no session exists yet that could name one.
    create,
    /// A mutation of an established session, carrying the session id the
    /// create returned.
    session_op: struct { session_id: u128, op: state.Op },
};

/// Where a differentiated request goes (2.3).
const Destination = union(enum) {
    /// Dies at the front, no index learns of it.
    consumed,
    /// A create: the next index of the front's own, in round-robin order.
    round_robin,
    /// A session op: the front's child owning the session, by ring offset.
    index: u16,
    /// A session id naming an index outside the front's share: a rogue
    /// client's doing, answered and closed by the front itself.
    rogue,
};

/// The dispatch decision of one request, with no ring involved, so the rule of
/// 2.3 is testable on its own.
fn destination(first: lifetime.Role.IndexIdx, index_count: u16, request: Request) Destination {
    return switch (request) {
        .pulse => .consumed,
        .create => .round_robin,
        .session_op => |op| if (indexSlot(first, index_count, op.session_id)) |k| .{ .index = k } else .rogue,
    };
}

/// Splits one client frame into a `Request`. The mirror codec of stage 5
/// (`wire.zig`) covers host-to-host frames only; how a client's request is
/// framed on its own socket has no design yet, so there is nothing to split:
/// the differentiation rule the dispatcher needs already lives in
/// `destination`, and this stub is where the frame is read once the client
/// protocol lands.
fn classify(frame: []const u8) ?Request {
    _ = frame;
    return null;
}

/// Handles one client request the front has already differentiated (2.3). The
/// receive path that produces the frames is stage 2, so nothing calls this
/// yet.
fn dispatchRequest(ctx: *Ctx, fd: posix.fd_t, tag: usize, request: Request) void {
    switch (destination(ctx.front().first_index, ctx.front().index_count, request)) {
        .consumed => consumePulse(ctx, fd),
        .round_robin => routeCreate(ctx, fd, tag),
        .index => |k| switch (request) {
            .session_op => |op| routeSessionOp(ctx, k, fd, tag, op.session_id, op.op),
            else => unreachable,
        },
        .rogue => switch (request) {
            .session_op => |op| {
                // The socket is the front's own, so it gets the angry reply and
                // the deferred close; no index learns of the op (2.3). The tag
                // is checked first: a descriptor that is not this front's live
                // socket has no client to answer.
                ctx.log.warn("session op names a foreign index", .{
                    .ring_idx = ctx.front().ring_idx,
                    .fd = fd,
                    .tag = tag,
                    .session_id_hi = @as(u64, @truncate(op.session_id >> 64)),
                    .session_id_lo = @as(u64, @truncate(op.session_id)),
                });
                if (ctx.ctrl.sockets.get(fd) != tag) return;

                var text: [reply.max_len]u8 = undefined;
                answerAndClose(ctx, fd, reply.encode(.unknown_session, op.session_id, &text));
            },
            else => unreachable,
        },
    }
}

fn reportDone(ctx: *Ctx) void {
    // Every index has drained, so nothing holds an operation on a client
    // socket any more: the front closes what it accepted. The drain condition
    // of 2.3 governs every other close path and arrives with stage 2.
    closeOwnedSockets(ctx);

    while (true) {
        if (ctx.ring.ring.pushMsgRingFd(ctx.ctrl.init_ring.ring.fd, messages.ShutdownDoneIdx, ctx.front().ring_idx, .{})) |_| {
            return;
        } else |err| switch (err) {
            error.RingFull => std.atomic.spinLoopHint(),
        }
    }
}

/// Closes every client socket this front accepted. The tag of the entry tells
/// the owner, so a front never touches a descriptor of another front.
fn closeOwnedSockets(ctx: *Ctx) void {
    const sockets = &ctx.ctrl.sockets;
    const owner: usize = ctx.front().ring_idx;
    for (sockets.entries, 0..) |entry, fd| {
        if (entry.tag == 0) continue;
        if (lifetime.SocketTable.ownerOf(entry.tag, ctx.ctrl.cfg.fronts) != owner) continue;
        sockets.clear(@intCast(fd));
        _ = std.os.linux.close(@intCast(fd));
    }
}

test "children are addressed by ring offset" {
    const role: lifetime.Role = .{ .front = .{
        .ring_idx = 0,
        .first_index = .{ .ring_idx = 2, .inbox_idx = 0 },
        .index_count = 2,
    } };
    try std.testing.expectEqual(@as(u16, 2), role.front.first_index.ring_idx);
    try std.testing.expectEqual(@as(u16, 2), role.front.index_count);
}

/// A session id of the given index service, as a create would return it.
fn sessionIdOf(index_id: u16, index: u64) u128 {
    const value = state.IndexState{ .host_id = 0, .index_id = index_id, .epoch_id = 0, .index = index };
    return value.pack();
}

test "an in-session op is routed by the index id of its session id" {
    const first: lifetime.Role.IndexIdx = .{ .ring_idx = 2, .inbox_idx = 4 };

    try std.testing.expectEqual(@as(?u16, 0), indexSlot(first, 2, sessionIdOf(4, 1)));
    try std.testing.expectEqual(@as(?u16, 1), indexSlot(first, 2, sessionIdOf(5, 9)));
    // Below the share and past its end: both outside, both a rogue client.
    try std.testing.expectEqual(@as(?u16, null), indexSlot(first, 2, sessionIdOf(3, 1)));
    try std.testing.expectEqual(@as(?u16, null), indexSlot(first, 2, sessionIdOf(6, 1)));
}

test "the request differentiation decides where each request goes" {
    const first: lifetime.Role.IndexIdx = .{ .ring_idx = 2, .inbox_idx = 4 };

    try std.testing.expectEqual(Destination.consumed, destination(first, 2, .pulse));
    try std.testing.expectEqual(Destination.round_robin, destination(first, 2, .create));
    try std.testing.expectEqual(
        Destination{ .index = 1 },
        destination(first, 2, .{ .session_op = .{ .session_id = sessionIdOf(5, 0), .op = .append } }),
    );
    try std.testing.expectEqual(
        Destination.rogue,
        destination(first, 2, .{ .session_op = .{ .session_id = sessionIdOf(9, 0), .op = .append } }),
    );
}

test "the accepts of a front take its own tags" {
    const fronts: u16 = 4;
    const front_idx: u16 = 2;
    var serial: usize = 0;
    while (serial < 3) : (serial += 1) {
        const tag = lifetime.SocketTable.mintTag(front_idx, serial, fronts);
        try std.testing.expectEqual(@as(usize, front_idx) + 1 + serial * @as(usize, fronts), tag);
        try std.testing.expectEqual(@as(usize, front_idx), lifetime.SocketTable.ownerOf(tag, fronts));
        try std.testing.expectEqual(serial, lifetime.SocketTable.serialOf(tag, fronts));
    }
}

test "the frame splitter waits for a client protocol" {
    // The split of a frame into a `Request` needs a client-side codec the
    // plan does not design; what the dispatcher needs is `destination`,
    // tested above. Referencing the receive path keeps it analyzed until then.
    _ = &dispatchRequest;
    _ = &classify;
    try std.testing.expectEqual(@as(?Request, null), classify("pulse"));
}

/// The front and its children of one test, with a logger writing to stderr as
/// JSON: the dispatch paths log, and an undefined logger would fault.
const Harness = struct {
    ctrl: lifetime.Controller,
    /// The controller keeps a pointer to this document, so it must outlive it.
    cfg: @import("config.zig").Config = undefined,
    logger: *lifetime.LoggerStuff,
    ctx: Ctx,

    fn init(self: *Harness) !void {
        try self.initWith(.{});
    }

    /// The replication plane of a three-host shard, this host at index 1, with
    /// the listener bound to an ephemeral loopback port (2.7). The host is the
    /// greater side of the pair `(0, 1)` and the lesser side of `(1, 2)`, so a
    /// greeting names it either way.
    fn initCluster(self: *Harness, bind: config.BindType) !void {
        const mirrors = [_]config.BindType{
            .{ .host = "127.0.0.1", .port = 1 },
            .{ .host = "127.0.0.1", .port = 1 },
            .{ .host = "127.0.0.1", .port = 1 },
        };
        try self.initWith(.{
            .replication = .{ .factor = 3, .mode = .{ .cluster = .{
                .bind = bind,
                .mirrors = &mirrors,
            } } },
            .host_index = 1,
        });
    }

    const Options = struct {
        /// The shard of the process (2.7): `local` unless a test asks for a
        /// cluster.
        replication: config.Replication = .{},
        /// This host's index in the shard (2.7).
        host_index: u16 = 0,
    };

    fn initWith(self: *Harness, opts: Options) !void {
        self.cfg = .{};
        self.cfg.host_index = opts.host_index;
        self.cfg.replication = opts.replication;
        self.cfg.fronts = 1;
        self.cfg.indexes = 2;
        self.cfg.elephants = 0;
        self.cfg.queue_depth = 64;
        self.cfg.cross_task_slots = 8;
        self.cfg.sqpoll_threads = 1;
        self.cfg.ring_slots_capacity = 4096;
        self.cfg.index_inbox_capacity = 8;
        self.cfg.logging = .{
            .method = .{ .json = {} },
            .pool_capacity = 64,
            .pool_frame_size = 1024,
        };

        try self.ctrl.init(std.testing.allocator, &self.cfg);
        errdefer self.ctrl.deinit();
        // The front's own ring, so a complaint answer can be armed on it.
        try self.ctrl.initRing(0, 1);
        errdefer self.ctrl.rings[0].deinit();
        // The children of the one front: rings 1 and 2, inboxes 0 and 1. The
        // rings are real, so a hand-off into an index ring can be posted.
        try self.ctrl.initRing(1, 1);
        errdefer self.ctrl.rings[1].deinit();
        try self.ctrl.initRing(2, 1);
        errdefer self.ctrl.rings[2].deinit();
        try self.ctrl.initIndexInbox(0, 1);
        try self.ctrl.initIndexInbox(1, 2);

        self.logger = try self.ctrl.getInitLogger();
        errdefer std.testing.allocator.destroy(self.logger);
        errdefer self.logger.deinit(self.ctrl.allocator);

        self.ctx = .{
            .ctrl = &self.ctrl,
            .role = self.ctrl.roleOf(0),
            .ring = &self.ctrl.rings[0],
            .log = &self.logger.logger,
            .log_stuff = self.logger,
            .tick_spec = &self.ctrl.rings[0].tick_spec,
        };
    }

    fn deinit(self: *Harness) void {
        self.ctx.deinitTiming();
        self.logger.deinit(self.ctrl.allocator);
        std.testing.allocator.destroy(self.logger);
        self.ctrl.rings[2].deinit();
        self.ctrl.rings[1].deinit();
        self.ctrl.rings[0].deinit();
        self.ctrl.deinit();
    }

    /// Drives `completions` completions of the front ring, the same way its
    /// service loop would.
    fn settle(self: *Harness, completions: usize) !void {
        var left = completions;
        while (left > 0) : (left -= 1) {
            const deadline = zigring.monotonicNs() + 5 * std.time.ns_per_s;
            while (!self.ctx.ring.ring.checkCQNotEmpty()) {
                if (zigring.monotonicNs() >= deadline) return error.CqeTimeout;
                std.atomic.spinLoopHint();
            }
            const cqe = self.ctx.ring.ring.popCQE() orelse return error.MissingCqe;
            _ = handleCqe(&self.ctx, cqe);
        }
    }
};

fn expectNoTask(inbox: *indexmod.Inbox) !void {
    if (inbox.pop()) |task| {
        _ = task;
        return error.UnexpectedTask;
    }
}

test "a differentiated request reaches the child the rule names" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    // Start the rotation at the second child, so a pulse below could only be
    // proven to die by both inboxes staying empty.
    h.ctx.round_robin = 1;

    // The endpoint the dispatcher is handed was minted at accept, so the
    // socket carries a tag: a descriptor without one is never routed.
    h.ctx.ctrl.sockets.set(5, 3);

    // A pulse is the front's own: no child learns of it (2.3).
    dispatchRequest(&h.ctx, 5, 3, .pulse);
    try expectNoTask(h.ctx.ownInbox(0));
    try expectNoTask(h.ctx.ownInbox(1));

    // A create takes the rotation and carries the endpoint minted at accept.
    dispatchRequest(&h.ctx, 5, 3, .create);
    switch (h.ctx.ownInbox(1).pop() orelse return error.MissingTask) {
        .create => |endpoint| {
            try std.testing.expectEqual(@as(posix.fd_t, 5), endpoint.fd);
            try std.testing.expectEqual(@as(usize, 3), endpoint.tag);
        },
        else => return error.UnexpectedTask,
    }
    try expectNoTask(h.ctx.ownInbox(0));
    try std.testing.expectEqual(@as(u16, 2), h.ctx.round_robin);

    // An in-session op goes to the child owning the `index_id` slice of its
    // session id, carrying the same endpoint.
    const owned = sessionIdOf(h.ctx.front().first_index.inbox_idx + 1, 4);
    dispatchRequest(&h.ctx, 5, 3, .{ .session_op = .{ .session_id = owned, .op = .append } });
    switch (h.ctx.ownInbox(1).pop() orelse return error.MissingTask) {
        .session_op => |op| {
            try std.testing.expectEqual(owned, op.session_id);
            try std.testing.expectEqual(state.Op.append, op.op);
            try std.testing.expectEqual(@as(posix.fd_t, 5), op.endpoint.fd);
            try std.testing.expectEqual(@as(usize, 3), op.endpoint.tag);
        },
        else => return error.UnexpectedTask,
    }
    try expectNoTask(h.ctx.ownInbox(0));

    // A session id naming an index outside the front's share is a rogue
    // client's: the front handles it itself and no child sees the op. The
    // descriptor below carries no tag, so the angry write is not armed and the
    // test stays off the ring.
    dispatchRequest(&h.ctx, 4, 9, .{ .session_op = .{ .session_id = sessionIdOf(9, 0), .op = .append } });
    try expectNoTask(h.ctx.ownInbox(0));
    try expectNoTask(h.ctx.ownInbox(1));
}

test "a relayed tick visits the front's children in turn" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    relayTick(&h.ctx, 171);
    relayTick(&h.ctx, 172);
    relayTick(&h.ctx, 173);

    // Round robin over the two children: 0, 1, 0 (2.3).
    try std.testing.expectEqual(@as(u16, 3), h.ctx.tick_round_robin);
    for ([_]u32{ 171, 173 }) |second| {
        switch (h.ctx.ownInbox(0).pop() orelse return error.MissingTask) {
            .tick => |carried| try std.testing.expectEqual(second, carried),
            else => return error.UnexpectedTask,
        }
    }
    switch (h.ctx.ownInbox(1).pop() orelse return error.MissingTask) {
        .tick => |carried| try std.testing.expectEqual(@as(u32, 172), carried),
        else => return error.UnexpectedTask,
    }
    try expectNoTask(h.ctx.ownInbox(0));
    try expectNoTask(h.ctx.ownInbox(1));
}

test "the deferred close waits for the counters and the front's own reply" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    var fds: [2]std.os.linux.fd_t = undefined;
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.pipe(&fds)));
    defer _ = std.os.linux.close(fds[0]);

    const fd = fds[1];
    h.ctx.ctrl.sockets.set(fd, 3);
    h.ctx.ctrl.sockets.bumpFront(fd);
    markClosing(&h.ctx, fd);
    try std.testing.expect(h.ctx.ctrl.sockets.info(fd).?.closing);
    try std.testing.expectEqual(@as(usize, 1), h.ctx.closing.items.len);

    // One op is still in flight, so the descriptor stays open.
    drainClosing(&h.ctx);
    try std.testing.expectEqual(@as(usize, 1), h.ctx.closing.items.len);
    try std.testing.expectEqual(
        std.os.linux.E.SUCCESS,
        std.os.linux.errno(std.os.linux.fcntl(fd, std.os.linux.F.GETFD, 0)),
    );

    // The index retired its op, but the front's own reply is still in flight.
    h.ctx.ctrl.sockets.bumpIndex(fd, 0);
    h.ctx.ctrl.sockets.info(fd).?.reply_pending = true;
    drainClosing(&h.ctx);
    try std.testing.expectEqual(@as(usize, 1), h.ctx.closing.items.len);

    // Everything has drained: the descriptor is closed and the entry zeroed.
    h.ctx.ctrl.sockets.info(fd).?.reply_pending = false;
    drainClosing(&h.ctx);
    try std.testing.expectEqual(@as(usize, 0), h.ctx.closing.items.len);
    try std.testing.expectEqual(@as(usize, 0), h.ctx.ctrl.sockets.get(fd));
    try std.testing.expectEqual(
        std.os.linux.E.BADF,
        std.os.linux.errno(std.os.linux.fcntl(fd, std.os.linux.F.GETFD, 0)),
    );
}

test "the socket wheel re-arms live sockets and marks quiet ones" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    defer {
        if (h.ctx.wheel) |w| w.deinit();
        h.ctx.wheel = null;
        if (h.ctx.wheel_scratch.len != 0) std.testing.allocator.free(h.ctx.wheel_scratch);
        h.ctx.wheel_scratch = &.{};
    }

    const wheel = try Wheel.init(std.testing.allocator, 4);
    h.ctx.wheel = wheel;
    h.ctx.inactivity_secs = 10;

    const quiet: posix.fd_t = 5;
    const live: posix.fd_t = 7;
    h.ctx.ctrl.sockets.set(quiet, 3);
    h.ctx.ctrl.sockets.bumpTick(quiet, 900);
    _ = try wheel.add_value(@intCast(quiet));
    h.ctx.ctrl.sockets.set(live, 3);
    h.ctx.ctrl.sockets.bumpTick(live, 1004);
    _ = try wheel.add_value(@intCast(live));

    // A full turn of the four-tick wheel matures both entries; the quiet
    // socket is marked, the live one re-armed (2.3).
    for (0..4) |_| sweepSockets(&h.ctx, 1006);

    try std.testing.expect(h.ctx.ctrl.sockets.info(quiet).?.closing);
    try std.testing.expect(!h.ctx.ctrl.sockets.info(live).?.closing);
    try std.testing.expectEqual(@as(usize, 1), h.ctx.closing.items.len);

    h.ctx.closing.clearRetainingCapacity();
    h.ctx.ctrl.sockets.clear(quiet);
    h.ctx.ctrl.sockets.clear(live);
}

test "a validated complaint answers the client and defers the close" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    var fds: [2]std.os.linux.fd_t = undefined;
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.pipe(&fds)));
    defer _ = std.os.linux.close(fds[0]);

    const fd = fds[1];
    h.ctx.ctrl.sockets.set(fd, 3);
    h.ctx.ctrl.sockets.bumpTick(fd, nowSecond());

    // A tag that does not match the entry is a `Nop`: the client the complaint
    // speaks about is gone.
    handleComplaint(&h.ctx, .{ .code = .protocol_violation, .fd = fd, .tag = 4, .session_id = 9 });
    try std.testing.expectEqual(@as(usize, 0), h.ctx.closing.items.len);
    try std.testing.expect(!h.ctx.ctrl.sockets.info(fd).?.reply_pending);

    // The matching complaint arms the angry reply and marks the socket.
    handleComplaint(&h.ctx, .{ .code = .closed, .fd = fd, .tag = 3, .session_id = 9 });
    try std.testing.expectEqual(@as(usize, 1), h.ctx.closing.items.len);
    try std.testing.expect(h.ctx.ctrl.sockets.info(fd).?.reply_pending);

    // The reply completion releases the buffer, and the close follows because
    // no op is in flight.
    try h.settle(1);
    try std.testing.expectEqual(@as(usize, 0), h.ctx.closing.items.len);
    try std.testing.expectEqual(@as(usize, 0), h.ctx.ctrl.sockets.get(fd));
    try std.testing.expectEqual(
        std.os.linux.E.BADF,
        std.os.linux.errno(std.os.linux.fcntl(fd, std.os.linux.F.GETFD, 0)),
    );
}

/// A pair of connected stream sockets: the two ends of one mirror connection.
fn socketPair() ![2]posix.fd_t {
    var fds: [2]std.os.linux.fd_t = undefined;
    const res = std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(res));
    return .{ fds[0], fds[1] };
}

/// Writes `bytes` in full to a connected socket.
fn writeAll(fd: posix.fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const res = std.os.linux.write(fd, bytes.ptr + written, bytes.len - written);
        if (std.os.linux.errno(res) != .SUCCESS) return error.WriteFailed;
        written += res;
    }
}

/// Waits for the next completion of `ring`, which is not polled by a thread in
/// these tests, and pops it.
fn popRing(ring: *zigring.Ring) !zigring.CQE {
    const deadline = zigring.monotonicNs() + 5 * std.time.ns_per_s;
    while (!ring.checkCQNotEmpty()) {
        if (zigring.monotonicNs() >= deadline) return error.CqeTimeout;
        std.atomic.spinLoopHint();
    }
    return ring.popCQE() orelse error.MissingCqe;
}

test "the replication listener takes a connection and routes it by its greeting" {
    const bind = config.BindType{ .host = "127.0.0.1", .port = 0 };
    var h: Harness = undefined;
    try h.initCluster(bind);
    defer h.deinit();

    h.ctx.replication_fd = try h.ctrl.createReplicationSocket();
    defer if (h.ctx.replication_fd >= 0) {
        _ = std.os.linux.close(h.ctx.replication_fd);
        h.ctx.replication_fd = -1;
    };
    try installReplicationAccepts(&h.ctx);
    try std.testing.expect(h.ctx.replication_listening);

    // The listener picked its own port, so the test asks it where it listens.
    var addr: posix.sockaddr.in = undefined;
    var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    const named = std.os.linux.getsockname(h.ctx.replication_fd, @ptrCast(&addr), &addr_len);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(named));

    const client = try zigring.createTCPClientSocket(null);
    defer _ = std.os.linux.close(client);
    const connected = std.os.linux.connect(client, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(connected));

    // The accept completion is a fresh descriptor: the front owns it until the
    // greeting names the index service, so it arms the greeting read and opens
    // no session (2.3).
    try h.settle(1);
    try std.testing.expectEqual(@as(usize, 1), h.ctx.pending_greetings.items.len);
    const accepted = h.ctx.pending_greetings.items[0].fd;
    defer _ = std.os.linux.close(accepted);

    // The greeting of host 0 names index service 1, the front's second child.
    var bytes: [wire.greeting_len]u8 = undefined;
    wire.encodeGreeting(&bytes, .{ .host_idx = 0, .index_idx = 1 });
    try writeAll(client, &bytes);
    try h.settle(1);

    // The descriptor reached that index through a cross-task slot (2.3).
    const cqe = try popRing(&h.ctrl.rings[2].ring);
    try std.testing.expectEqual(messages.CrossTaskMessageIdx, cqe.taskIdx());
    const slot_idx: u32 = @intCast(cqe.res);
    const carried = h.ctrl.cross_slots.at(slot_idx).*;
    h.ctrl.cross_slots.release(slot_idx);
    try std.testing.expectEqual(accepted, carried.MirrorSocket.fd);
    try std.testing.expectEqual(@as(u8, 0), carried.MirrorSocket.host_idx);
    try std.testing.expectEqual(@as(usize, 0), h.ctx.pending_greetings.items.len);
}

test "a greeting from a host that does not dial is refused" {
    const bind = config.BindType{ .host = "127.0.0.1", .port = 0 };
    var h: Harness = undefined;
    try h.initCluster(bind);
    defer h.deinit();

    const pair = try socketPair();
    defer _ = std.os.linux.close(pair[1]);

    // The own host never dials itself, and the greater host of a pair is
    // dialled, never the one dialling (2.3).
    var bytes: [wire.greeting_len]u8 = undefined;
    wire.encodeGreeting(&bytes, .{ .host_idx = 2, .index_idx = 0 });
    try writeAll(pair[1], &bytes);

    readGreeting(&h.ctx, pair[0]);
    try h.settle(1);

    // The front owned the descriptor until the hand-off: it closed it, and no
    // index ever heard of the connection.
    try std.testing.expectEqual(
        std.os.linux.E.BADF,
        std.os.linux.errno(std.os.linux.fcntl(pair[0], std.os.linux.F.GETFD, 0)),
    );
    try std.testing.expectEqual(@as(usize, 0), h.ctx.pending_greetings.items.len);
    try std.testing.expect(!h.ctrl.rings[1].ring.checkCQNotEmpty());
    try std.testing.expect(!h.ctrl.rings[2].ring.checkCQNotEmpty());
}

test "a greeting naming an index service outside the shard is refused" {
    const bind = config.BindType{ .host = "127.0.0.1", .port = 0 };
    var h: Harness = undefined;
    try h.initCluster(bind);
    defer h.deinit();

    const pair = try socketPair();
    defer _ = std.os.linux.close(pair[1]);

    // This process serves two index services; a greeting naming a third is a
    // peer this shard cannot answer.
    var bytes: [wire.greeting_len]u8 = undefined;
    wire.encodeGreeting(&bytes, .{ .host_idx = 0, .index_idx = 2 });
    try writeAll(pair[1], &bytes);

    readGreeting(&h.ctx, pair[0]);
    try h.settle(1);

    try std.testing.expectEqual(
        std.os.linux.E.BADF,
        std.os.linux.errno(std.os.linux.fcntl(pair[0], std.os.linux.F.GETFD, 0)),
    );
    try std.testing.expectEqual(@as(usize, 0), h.ctx.pending_greetings.items.len);
    try std.testing.expect(!h.ctrl.rings[1].ring.checkCQNotEmpty());
    try std.testing.expect(!h.ctrl.rings[2].ring.checkCQNotEmpty());
}

test "a greeting that does not arrive in time is closed by the tick" {
    const bind = config.BindType{ .host = "127.0.0.1", .port = 0 };
    var h: Harness = undefined;
    try h.initCluster(bind);
    defer h.deinit();

    const pair = try socketPair();
    defer _ = std.os.linux.close(pair[1]);

    // Nothing is written, so the receive stays armed and the deadline is what
    // ends the connection (2.3).
    h.ctx.greeting_timeout_secs = 3;
    readGreeting(&h.ctx, pair[0]);
    try std.testing.expectEqual(@as(usize, 1), h.ctx.pending_greetings.items.len);
    const deadline = h.ctx.pending_greetings.items[0].deadline_second;

    // A tick before the deadline leaves the connection alone.
    expireGreetings(&h.ctx, deadline -% 1);
    try std.testing.expect(!h.ctx.pending_greetings.items[0].expired);
    try std.testing.expectEqual(
        std.os.linux.E.SUCCESS,
        std.os.linux.errno(std.os.linux.fcntl(pair[0], std.os.linux.F.GETFD, 0)),
    );

    // At the deadline the read is cancelled; the entry stays until that
    // completion arrives, so the kernel writes into no released buffer.
    expireGreetings(&h.ctx, deadline);
    try std.testing.expect(h.ctx.pending_greetings.items[0].expired);
    try std.testing.expectEqual(@as(usize, 1), h.ctx.pending_greetings.items.len);

    // The cancel's own completion and the cancelled receive: the buffer is
    // released, the descriptor closed and the bookkeeping dropped.
    try h.settle(2);
    try std.testing.expectEqual(@as(usize, 0), h.ctx.pending_greetings.items.len);
    try std.testing.expectEqual(
        std.os.linux.E.BADF,
        std.os.linux.errno(std.os.linux.fcntl(pair[0], std.os.linux.F.GETFD, 0)),
    );
}
