//! Front thread: accepts client connections and routes them to its indexes.
//!
//! A front owns one io_uring ring and is the only producer for the inboxes of
//! its indexes. Its phase A is handled by `resources.Controller.runThread`; this
//! file implements the reaction to `START_WORK`, the input loop and the
//! shutdown choreography from docs/startup-en-reworked.md.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const zigring = @import("zigring");
const resources = @import("resources.zig");
const res_handle = @import("resources_handle.zig");
const messages = @import("messages.zig");
const indexmod = @import("index.zig");
const logging = @import("logging.zig");
const cluster_transport = @import("cluster_transport.zig");
const cross_task = @import("cross_task.zig");

/// Upper bound of indexes a single front may own. The config admits at most
/// one thread per CPU core, so this is comfortably above any legal value.
const max_indexes_per_front = 64;

/// How often the shutdown deadline is policed.
const tick_ns: u64 = 500 * std.time.ns_per_ms;

/// State a front keeps across its service loop.
const Ctx = struct {
    ctrl: *resources.Controller,
    role: resources.Role,
    ring: *resources.RingStuff,
    log: *logging.Logger,

    listening: bool = false,
    /// The client listener's number, borrowed from the process thread that
    /// owns the handle; the front never closes it.
    listen_fd: posix.fd_t = -1,
    accept_task_idx: ?u64 = null,
    cancel_task_idx: ?u64 = null,

    /// The shared peer listener and this front's own arm on it. The client arm
    /// above stays single-purpose, so each pair is matched only by its own
    /// task index. The number is borrowed from the process thread's handle.
    peer_fd: posix.fd_t = -1,
    peer_listening: bool = false,
    peer_accept_task_idx: ?u64 = null,
    peer_cancel_task_idx: ?u64 = null,
    /// The per-front peer-handshake table, one entry per
    /// `cluster.handshake_slots`, empty for a dark transport. Released only
    /// after every completion it armed has been consumed.
    handshakes: []PeerHandshake = &.{},
    /// Every child index has drained; only the handshake cancellations are
    /// still in flight before the front may report.
    stopping: bool = false,
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
        return &self.ctrl.inboxes[self.front().first_index.inbox_idx + k];
    }
};

/// One slot of a front's peer-handshake table (§3.2).
///
/// The entry owns the five greet bytes and the seven reply bytes, so no kernel
/// read or write ever targets a loop frame. It does not return to the table
/// until every completion it armed has been consumed: the completion's
/// `user_data` names the entry, so a reuse before that would misattribute a
/// late completion to the next connection.
const PeerHandshake = struct {
    const Self = @This();

    /// `free` is the only state a table slot rests in between connections;
    /// `done` is a connection on its way out, held until its completions land.
    const State = enum { free, reading, replying, posting, done };

    state: State = .free,
    fd: res_handle.SocketHandle = .{},
    filled: usize = 0,
    host_idx: u8 = 0,
    index_idx: u16 = 0,
    greet: [cluster_transport.GREET_LEN]u8 = @splat(0),
    reply: [cluster_transport.REPLY_LEN]u8 = @splat(0),
    source_ok: bool = false,

    read_idx: ?u64 = null,
    read_cancel_requested: bool = false,
    read_cancel_sent: bool = false,
    deadline_idx: ?u64 = null,
    deadline_cancel_requested: bool = false,
    deadline_cancel_sent: bool = false,
    reply_idx: ?u64 = null,

    /// The one hand-over post the front keeps while its `MSG_RING` is refused;
    /// the cross-task slot travels with it and is released only on abandonment.
    post_slot: ?u32 = null,

    /// The kernel reads the deadline spec asynchronously, so it lives here
    /// rather than on the arming pass's stack.
    deadline_spec: linux.kernel_timespec = .{ .sec = 0, .nsec = 0 },

    /// Whether a completion this entry armed is still outstanding.
    fn busy(self: *const Self) bool {
        return self.read_idx != null or self.deadline_idx != null or self.reply_idx != null;
    }

    /// Whether the slot may go back to the table.
    fn settled(self: *const Self) bool {
        return self.state == .free or
            (self.state == .done and !self.fd.isHeld() and !self.busy() and self.post_slot == null);
    }
};

/// Runs the front thread to completion. `role` is the role the thread derived
/// from its `ring_idx` before reporting `INITIALIZED`.
pub fn run(ctrl: *resources.Controller, role: resources.Role, logger: *resources.LoggerStuff) void {
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

    // The handshake table exists exactly when the peer listener does. Its
    // buffers and specs live until every completion armed against them has
    // been consumed, which the loop below guarantees before `run` returns.
    if (ctrl.cfg.cluster) |cluster| {
        const handshakes = ctrl.allocator.alloc(PeerHandshake, cluster.handshake_slots) catch |err| {
            ctx.log.err("could not allocate the peer handshake table", .{ .err = @errorName(err) });
            std.process.exit(1);
        };
        for (handshakes) |*entry| entry.* = .{};
        ctx.handshakes = handshakes;
    }
    defer if (ctx.handshakes.len != 0) ctrl.allocator.free(ctx.handshakes);

    while (true) {
        while (ctx.ring.ring.popCQE()) |cqe| handleCqe(&ctx, cqe);
        // A refused cancel or a refused hand-over post never parks: its SQ has
        // room again once the poller drains it, and nothing else may wake us.
        requestHandshakeCancels(&ctx);
        if (ctx.stopping and handshakesQuiescent(&ctx)) {
            reportDone(&ctx);
            return;
        }
        if (!ctx.draining) retryPosts(&ctx);
        if (hasPendingPost(&ctx) or hasUnsentCancel(&ctx)) {
            std.atomic.spinLoopHint();
            continue;
        }
        ctx.ring.ring.park();
    }
}

/// Handles one completion of this front's ring.
fn handleCqe(ctx: *Ctx, cqe: zigring.CQE) void {
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
        // The peer listener arrives in its own slot before this broadcast, and
        // the ring order guarantees it is stored by now. A dark transport
        // (`hosts == 1`) never gets a slot, so no peer arm is taken.
        if (ctx.peer_fd >= 0 and !ctx.peer_listening) {
            installPeerAccept(ctx, ctx.peer_fd) catch |err| {
                ctx.log.err("could not arm the peer multishot accept", .{ .err = @errorName(err) });
                std.process.exit(1);
            };
        }
        return;
    }

    if (task_idx == messages.ShutdownDemandIdx) {
        // The demand is payload-less: the trigger itself is the message.
        beginShutdown(ctx);
        return;
    }

    if (task_idx == messages.ShutdownTickIdx) {
        if (!ctx.draining) return;
        ctx.ticks += 1;
        const elapsed = zigring.monotonicNs() - ctx.shutdown_start_ns;
        const deadline: u64 = @intCast(ctx.ctrl.cfg.shutdown_timeout.value());
        if (elapsed >= deadline and !ctx.escalated) {
            ctx.escalated = true;
            escalateShutdown(ctx);
        }
        return;
    }

    if (task_idx == messages.CrossTaskMessageIdx) {
        // A payload that does not fit the two words a CQE carries travels in a
        // `CrossTaskSlots` slot; the receiver releases it after copying.
        const slot_idx: u32 = @intCast(cqe.res);
        const task = ctx.ctrl.cross_slots.at(slot_idx).*;
        ctx.ctrl.cross_slots.release(slot_idx);
        switch (task) {
            .PeerServerSocket => |peer| ctx.peer_fd = peer.fd,
            else => ctx.log.warn("front dropped an unexpected cross-task payload", .{
                .ring_idx = ctx.front().ring_idx,
                .slot = slot_idx,
            }),
        }
        return;
    }

    if (task_idx == messages.IndexDrainedIdx) {
        // `res` is the index's ring index, the index's slot in the shared ring
        // array; k is its position among our children, so translate it.
        const ring_idx: u16 = @intCast(cqe.res);
        const k = ring_idx - ctx.front().first_index.ring_idx;
        if (k < ctx.front().index_count) ctx.drained[k] = true;
        // The report itself waits for the handshake cancellations of E4; the
        // loop reports once the table is quiet.
        if (allDrained(ctx)) ctx.stopping = true;
        return;
    }

    if (ctx.cancel_task_idx) |cancel_idx| {
        if (task_idx == cancel_idx) {
            // The cancel reports whether it found the target; the accept's own
            // cancelled completion follows on the accept's task index.
            ctx.ring.slots.del(cancel_idx);
            ctx.cancel_task_idx = null;
            return;
        }
    }

    if (ctx.peer_cancel_task_idx) |cancel_idx| {
        if (task_idx == cancel_idx) {
            ctx.ring.slots.del(cancel_idx);
            ctx.peer_cancel_task_idx = null;
            return;
        }
    }

    if (ctx.listening and task_idx == ctx.accept_task_idx.?) {
        if (cqe.res < 0) {
            // A cancellation during shutdown is expected and silent; any other
            // failure is worth a line in the log.
            if (!ctx.draining) {
                ctx.log.warn("accept failed", .{ .ring_idx = ctx.front().ring_idx, .err = @tagName(cqe.errno()) });
            }
            return;
        }
        var accepted = ctx.ctrl.adoptSocket(@intCast(cqe.res));
        if (ctx.draining) {
            // Accepts were cancelled at shutdown; anything already accepted is
            // dropped rather than handed to an index that may be draining.
            ctx.ctrl.closeSocket(&accepted);
            return;
        }
        routeAccepted(ctx, &accepted);
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
        return;
    }

    // The peer arm is matched by its own task index alone: the cancelled
    // completion of a shutdown arrives after `peer_listening` was cleared, and
    // any socket it still carries must be closed, not ignored.
    if (ctx.peer_accept_task_idx) |peer_idx| {
        if (task_idx == peer_idx) {
            handlePeerAccept(ctx, cqe);
            return;
        }
    }

    // The peer intake's tracked work: the greet read, its deadline, a reject
    // reply, the closes and the cancels this file arms.
    if (ctx.ring.slots.get(task_idx)) |task| {
        switch (task) {
            .greet_read => |read| handleGreetRead(ctx, task_idx, read.entry, cqe),
            .greet_deadline => |deadline| handleGreetDeadline(ctx, task_idx, deadline.entry),
            .reply_send => |reply| handleReplySend(ctx, task_idx, reply.entry, cqe),
            .close, .timeout => ctx.ring.slots.del(task_idx),
            else => {},
        }
    }
    return;
}

fn installAccepts(ctx: *Ctx, listen_fd: posix.fd_t) !void {
    if (ctx.accept_task_idx) |old| ctx.ring.slots.del(old);
    const task_idx = try ctx.ring.slots.add(.{ .accept = .{} });
    ctx.accept_task_idx = task_idx;
    try ctx.ring.ring.pushAcceptMultishot(listen_fd, task_idx, .{});
    ctx.listening = true;
    ctx.log.info("accept armed", .{ .ring_idx = ctx.front().ring_idx, .fd = listen_fd });
}

fn installPeerAccept(ctx: *Ctx, peer_fd: posix.fd_t) !void {
    if (ctx.peer_accept_task_idx) |old| ctx.ring.slots.del(old);
    const task_idx = try ctx.ring.slots.add(.{ .peer_accept = .{} });
    ctx.peer_accept_task_idx = task_idx;
    try ctx.ring.ring.pushAcceptMultishot(peer_fd, task_idx, .{});
    ctx.peer_listening = true;
    ctx.log.info("peer accept armed", .{ .ring_idx = ctx.front().ring_idx, .fd = peer_fd });
}

/// Steps one completion of the peer accept arm. A peer socket the front cannot
/// hand over is closed: the front never keeps one past its own accept.
fn handlePeerAccept(ctx: *Ctx, cqe: zigring.CQE) void {
    if (cqe.res < 0) {
        // A cancellation during shutdown is expected and silent; any other
        // failure is worth a line in the log.
        if (!ctx.draining) {
            ctx.log.warn("peer accept failed", .{
                .ring_idx = ctx.front().ring_idx,
                .err = @tagName(cqe.errno()),
            });
        }
    } else {
        var accepted = ctx.ctrl.adoptSocket(@intCast(cqe.res));
        if (ctx.draining) {
            // Accepts were cancelled at shutdown; anything already accepted is
            // dropped rather than handed to an index that may be draining.
            ctx.ctrl.closeSocket(&accepted);
        } else {
            openHandshake(ctx, &accepted) catch |err| switch (err) {
                // No entry was claimed, so the descriptor is still ours.
                error.NoHandshakeEntry => {
                    ctx.log.warn("peer connection refused: no handshake entry", .{
                        .ring_idx = ctx.front().ring_idx,
                        .fd = ctx.ctrl.borrowSocket(&accepted),
                    });
                    ctx.ctrl.closeSocket(&accepted);
                },
                // The handshake claimed the descriptor and its own cleanup has
                // already closed it.
                else => ctx.log.warn("peer handshake could not be armed", .{
                    .ring_idx = ctx.front().ring_idx,
                    .err = @errorName(err),
                }),
            };
        }
    }

    if (!cqe.hasMore()) {
        // The multishot ended: either it was cancelled for shutdown or it
        // failed. The slot is retired with it and re-armed only while the front
        // is not draining; `installPeerAccept` releases the old slot, so the
        // field is not cleared first (the client arm's shape).
        ctx.peer_listening = false;
        if (!ctx.draining) {
            installPeerAccept(ctx, ctx.peer_fd) catch |err| {
                ctx.log.err("could not re-arm the peer multishot accept", .{ .err = @errorName(err) });
                std.process.exit(1);
            };
        }
    }
}

/// The verdicts a greet can earn before any address check. The order is fixed
/// (§3.2): a foreign version makes the rest of the layout unknown, a bad host
/// names no peer, and only then can an index number be judged.
const GreetRoute = union(enum) {
    reject: cluster_transport.Verdict,
    route: struct {
        host_idx: u8,
        index_idx: u16,
    },
};

fn classifyGreet(
    greet: cluster_transport.Greet,
    hosts: u32,
    own_host: u16,
    indexes: u16,
) GreetRoute {
    if (greet.version != cluster_transport.VERSION) {
        return .{ .reject = .version_mismatch };
    }
    if (@as(u32, greet.host_idx) >= hosts or @as(u16, greet.host_idx) == own_host) {
        return .{ .reject = .invalid_host };
    }
    if (greet.index_idx >= indexes) {
        return .{ .reject = .unknown_index };
    }
    return .{ .route = .{ .host_idx = greet.host_idx, .index_idx = greet.index_idx } };
}

/// Claims the first free handshake entry and arms the greet read plus its one
/// deadline. A failure leaves no descriptor open and no completion unowned.
fn openHandshake(ctx: *Ctx, accepted: *res_handle.SocketHandle) !void {
    const cluster = ctx.ctrl.cfg.cluster orelse return error.NoHandshakeEntry;
    const entry_idx = findFreeHandshake(ctx) orelse return error.NoHandshakeEntry;
    const index: u32 = @intCast(entry_idx);

    const entry = &ctx.handshakes[entry_idx];
    entry.* = .{ .state = .reading };
    ctx.ctrl.moveSocket(&entry.fd, accepted);
    const fd = ctx.ctrl.borrowSocket(&entry.fd);
    setDeadlineSpec(&entry.deadline_spec, cluster.handshake_timeout.value());

    const read_idx = ctx.ring.slots.add(.{ .greet_read = .{ .entry = index } }) catch |err| {
        closeEntry(ctx, index);
        return err;
    };
    entry.read_idx = read_idx;
    ctx.ring.ring.pushRecv(fd, read_idx, entry.greet[0..cluster_transport.GREET_LEN], .{}) catch |err| {
        ctx.ring.slots.del(read_idx);
        entry.read_idx = null;
        closeEntry(ctx, index);
        return err;
    };

    const deadline_idx = ctx.ring.slots.add(.{ .greet_deadline = .{ .entry = index } }) catch |err| {
        closeEntry(ctx, index);
        return err;
    };
    entry.deadline_idx = deadline_idx;
    ctx.ring.ring.pushTicker(deadline_idx, &entry.deadline_spec, 1, .{}) catch |err| {
        ctx.ring.slots.del(deadline_idx);
        entry.deadline_idx = null;
        closeEntry(ctx, index);
        return err;
    };

    ctx.log.info("peer handshake started", .{ .ring_idx = ctx.front().ring_idx, .fd = fd });
}

fn setDeadlineSpec(spec: *linux.kernel_timespec, ns: i64) void {
    const total = @max(ns, 0);
    spec.* = .{
        .sec = @intCast(@divTrunc(total, std.time.ns_per_s)),
        .nsec = @intCast(@mod(total, std.time.ns_per_s)),
    };
}

fn findFreeHandshake(ctx: *const Ctx) ?usize {
    for (ctx.handshakes, 0..) |entry, idx| {
        if (entry.state == .free) return idx;
    }
    return null;
}

fn handshakeEntry(ctx: *Ctx, entry_idx: u32) ?*PeerHandshake {
    if (@as(usize, entry_idx) >= ctx.handshakes.len) return null;
    return &ctx.handshakes[entry_idx];
}

/// One completion of the greet read. Partial reads re-arm for the remainder
/// under the same deadline; EOF, an error or the deadline ends the connection.
fn handleGreetRead(ctx: *Ctx, task_idx: u64, entry_idx: u32, cqe: zigring.CQE) void {
    ctx.ring.slots.del(task_idx);
    const entry = handshakeEntry(ctx, entry_idx) orelse return;
    if (entry.read_idx != task_idx) return;
    entry.read_idx = null;
    entry.read_cancel_requested = false;
    entry.read_cancel_sent = false;

    if (entry.state != .reading) {
        // The deadline or shutdown closed the connection first.
        maybeRelease(ctx, entry_idx);
        return;
    }

    if (cqe.res < 0) {
        ctx.log.warn("peer greet read failed", .{
            .ring_idx = ctx.front().ring_idx,
            .fd = ctx.ctrl.borrowSocket(&entry.fd),
            .err = @tagName(cqe.errno()),
        });
        closeEntry(ctx, entry_idx);
        return;
    }
    if (cqe.res == 0) {
        ctx.log.warn("peer closed before the greet landed", .{
            .ring_idx = ctx.front().ring_idx,
            .fd = ctx.ctrl.borrowSocket(&entry.fd),
        });
        closeEntry(ctx, entry_idx);
        return;
    }

    entry.filled += @intCast(cqe.res);
    if (entry.filled >= cluster_transport.GREET_LEN) {
        onGreetComplete(ctx, entry_idx);
        return;
    }
    rearmGreetRead(ctx, entry_idx);
}

fn rearmGreetRead(ctx: *Ctx, entry_idx: u32) void {
    const entry = &ctx.handshakes[entry_idx];
    const read_idx = ctx.ring.slots.add(.{ .greet_read = .{ .entry = entry_idx } }) catch |err| {
        ctx.log.warn("could not re-arm the greet read", .{
            .ring_idx = ctx.front().ring_idx,
            .err = @errorName(err),
        });
        closeEntry(ctx, entry_idx);
        return;
    };
    entry.read_idx = read_idx;
    ctx.ring.ring.pushRecv(ctx.ctrl.borrowSocket(&entry.fd), read_idx, entry.greet[entry.filled..], .{}) catch |err| {
        ctx.ring.slots.del(read_idx);
        entry.read_idx = null;
        ctx.log.warn("could not re-arm the greet read", .{
            .ring_idx = ctx.front().ring_idx,
            .err = @errorName(err),
        });
        closeEntry(ctx, entry_idx);
    };
}

/// The greet's clock. It is one absolute deadline across every re-armed
/// partial read: a guard restarted with each short completion would let a peer
/// drip-feeding a byte at a time hold the entry open indefinitely.
fn handleGreetDeadline(ctx: *Ctx, task_idx: u64, entry_idx: u32) void {
    ctx.ring.slots.del(task_idx);
    const entry = handshakeEntry(ctx, entry_idx) orelse return;
    if (entry.deadline_idx != task_idx) return;
    entry.deadline_idx = null;
    entry.deadline_cancel_requested = false;
    entry.deadline_cancel_sent = false;

    if (entry.state != .reading) {
        // The greet landed first and the cancel raced its own completion.
        maybeRelease(ctx, entry_idx);
        return;
    }

    ctx.log.warn("peer greet deadline", .{
        .ring_idx = ctx.front().ring_idx,
        .fd = ctx.ctrl.borrowSocket(&entry.fd),
    });
    closeEntry(ctx, entry_idx);
}

/// The ordered §3.2 checks on a complete greet.
fn onGreetComplete(ctx: *Ctx, entry_idx: u32) void {
    const entry = &ctx.handshakes[entry_idx];
    const cfg = ctx.ctrl.cfg;
    const greet = cluster_transport.decodeGreet(&entry.greet);

    switch (classifyGreet(greet, cfg.wal.hosts(), cfg.host_index, cfg.indexes)) {
        .reject => |verdict| {
            entry.state = .replying;
            cancelDeadline(ctx, entry);
            beginReject(ctx, entry_idx, verdict);
        },
        .route => |route| {
            entry.host_idx = route.host_idx;
            entry.index_idx = route.index_idx;
            entry.source_ok = peerSourceOk(ctx, ctx.ctrl.borrowSocket(&entry.fd), route.host_idx);
            entry.state = .posting;
            cancelDeadline(ctx, entry);
            tryPost(ctx, entry_idx);
        },
    }
}

/// Writes the seven-byte reject from the entry's own buffer and closes after
/// that send's completion. The front names no target index: `0xFFFF` is the
/// sentinel.
fn beginReject(ctx: *Ctx, entry_idx: u32, verdict: cluster_transport.Verdict) void {
    const entry = &ctx.handshakes[entry_idx];
    const sentinel: u16 = 0xFFFF;

    cluster_transport.encodeReply(.{
        .version = cluster_transport.VERSION,
        .host_idx = @intCast(ctx.ctrl.cfg.host_index),
        .index_idx = sentinel,
        .verdict = verdict,
    }, &entry.reply);

    ctx.log.warn("peer greet rejected", .{
        .ring_idx = ctx.front().ring_idx,
        .fd = ctx.ctrl.borrowSocket(&entry.fd),
        .verdict = @tagName(verdict),
    });

    const reply_idx = ctx.ring.slots.add(.{ .reply_send = .{ .entry = entry_idx } }) catch |err| {
        ctx.log.warn("could not arm the peer reject reply", .{ .err = @errorName(err) });
        closeEntry(ctx, entry_idx);
        return;
    };
    entry.reply_idx = reply_idx;
    ctx.ring.ring.pushSend(ctx.ctrl.borrowSocket(&entry.fd), reply_idx, &entry.reply, cluster_transport.REPLY_LEN, .{}) catch |err| {
        ctx.ring.slots.del(reply_idx);
        entry.reply_idx = null;
        ctx.log.warn("peer reject reply could not be submitted", .{ .err = @errorName(err) });
        closeEntry(ctx, entry_idx);
    };
}

fn handleReplySend(ctx: *Ctx, task_idx: u64, entry_idx: u32, cqe: zigring.CQE) void {
    ctx.ring.slots.del(task_idx);
    const entry = handshakeEntry(ctx, entry_idx) orelse return;
    if (entry.reply_idx != task_idx) return;
    entry.reply_idx = null;

    if (cqe.res != cluster_transport.REPLY_LEN) {
        ctx.log.warn("peer reject reply did not leave whole", .{
            .ring_idx = ctx.front().ring_idx,
            .fd = ctx.ctrl.borrowSocket(&entry.fd),
            .sent = cqe.res,
        });
    }
    closeAfterReply(ctx, entry_idx);
}

fn closeAfterReply(ctx: *Ctx, entry_idx: u32) void {
    const entry = &ctx.handshakes[entry_idx];
    const fd = ctx.ctrl.borrowSocket(&entry.fd);
    entry.state = .done;

    ctx.ctrl.closeSocketViaRing(ctx.ring, .{ .close = .{ .fd = fd } }, &entry.fd);
    maybeRelease(ctx, entry_idx);
}

/// The `getpeername` reduction: the four address bytes must match the parsed
/// address of the claimed host.
fn peerSourceOk(ctx: *const Ctx, fd: posix.fd_t, host_idx: u8) bool {
    if (host_idx >= ctx.ctrl.peer_addrs.len) return false;

    var addr: posix.sockaddr = undefined;
    var len: posix.socklen_t = @sizeOf(posix.sockaddr);
    posix.getpeername(fd, &addr, &len) catch return false;

    const in: *const posix.sockaddr.in = @ptrCast(@alignCast(&addr));
    if (in.family != posix.AF.INET) return false;
    const bytes: [4]u8 = @bitCast(in.addr);
    return std.mem.eql(u8, &bytes, &ctx.ctrl.peer_addrs[host_idx]);
}

/// Tries the one hand-over post, keeping the acquired slot and the payload
/// while the `MSG_RING` is refused. A successful post is the ownership
/// transfer: the front never touches the descriptor again.
fn tryPost(ctx: *Ctx, entry_idx: u32) void {
    const entry = &ctx.handshakes[entry_idx];
    if (entry.state != .posting) return;
    if (ctx.draining) {
        closeForShutdown(ctx, entry_idx);
        return;
    }

    if (entry.post_slot == null) {
        const slot_idx = ctx.ctrl.cross_slots.acquire() catch |err| switch (err) {
            // The slot pool refills as receivers release; retry next pass.
            error.CrossTaskFull => return,
        };
        ctx.ctrl.cross_slots.at(slot_idx).* = .{ .PeerLink = .{
            .fd = ctx.ctrl.borrowSocket(&entry.fd),
            .host_idx = entry.host_idx,
            .index_idx = entry.index_idx,
            .version = cluster_transport.VERSION,
            .source_ok = entry.source_ok,
        } };
        entry.post_slot = slot_idx;
    }

    const target_ring: u16 = ctx.ctrl.cfg.fronts + entry.index_idx;
    ctx.ring.ring.pushMsgRingFd(
        ctx.ctrl.rings[target_ring].ring.fd,
        messages.CrossTaskMessageIdx,
        entry.post_slot.?,
        .{},
    ) catch |err| switch (err) {
        error.RingFull => return,
    };

    // A direct submission moves this ring's SQ tail past the stream window's
    // cursors; re-capture them as the ring's own (§4).
    ctx.ring.ring.streamedSQ(&ctx.ring.sqstream);

    entry.post_slot = null;
    ctx.ctrl.disownSocket(&entry.fd);
    entry.state = .done;
    ctx.log.info("peer link handed over", .{
        .ring_idx = ctx.front().ring_idx,
        .host_idx = entry.host_idx,
        .index_idx = entry.index_idx,
    });
    maybeRelease(ctx, entry_idx);
}

fn retryPosts(ctx: *Ctx) void {
    var idx: u32 = 0;
    while (idx < ctx.handshakes.len) : (idx += 1) {
        if (ctx.handshakes[idx].state == .posting) tryPost(ctx, idx);
    }
}

fn hasPendingPost(ctx: *const Ctx) bool {
    for (ctx.handshakes) |entry| {
        if (entry.state == .posting) return true;
    }
    return false;
}

/// Drops a handshake the front cannot finish before it stops. A reply already
/// in flight keeps the descriptor until its own completion closes it; closing
/// the number underneath the send would risk closing a reused descriptor.
fn closeForShutdown(ctx: *Ctx, entry_idx: u32) void {
    const entry = &ctx.handshakes[entry_idx];
    if (entry.state == .free or entry.state == .done) {
        cancelRead(ctx, entry);
        cancelDeadline(ctx, entry);
        maybeRelease(ctx, entry_idx);
        return;
    }
    if (entry.state == .replying and entry.reply_idx != null) {
        cancelRead(ctx, entry);
        cancelDeadline(ctx, entry);
        return;
    }
    if (entry.post_slot) |slot| {
        ctx.ctrl.cross_slots.release(slot);
        entry.post_slot = null;
    }
    closeEntry(ctx, entry_idx);
}

/// Closes the descriptor and marks the entry done. The entry stays reserved
/// until its outstanding completions land, so their `user_data` still names a
/// live slot.
fn closeEntry(ctx: *Ctx, entry_idx: u32) void {
    const entry = &ctx.handshakes[entry_idx];
    cancelRead(ctx, entry);
    cancelDeadline(ctx, entry);
    ctx.ctrl.closeSocket(&entry.fd);
    entry.state = .done;
    maybeRelease(ctx, entry_idx);
}

fn maybeRelease(ctx: *Ctx, entry_idx: u32) void {
    const entry = &ctx.handshakes[entry_idx];
    if (!entry.settled()) return;
    entry.* = .{};
}

fn cancelRead(ctx: *Ctx, entry: *PeerHandshake) void {
    if (entry.read_idx == null) return;
    entry.read_cancel_requested = true;
    tryCancelRead(ctx, entry);
}

fn cancelDeadline(ctx: *Ctx, entry: *PeerHandshake) void {
    if (entry.deadline_idx == null) return;
    entry.deadline_cancel_requested = true;
    tryCancelDeadline(ctx, entry);
}

fn tryCancelRead(ctx: *Ctx, entry: *PeerHandshake) void {
    if (!entry.read_cancel_requested or entry.read_cancel_sent) return;
    const target = entry.read_idx orelse return;
    entry.read_cancel_sent = pushCancelRequest(ctx, target);
}

fn tryCancelDeadline(ctx: *Ctx, entry: *PeerHandshake) void {
    if (!entry.deadline_cancel_requested or entry.deadline_cancel_sent) return;
    const target = entry.deadline_idx orelse return;
    entry.deadline_cancel_sent = pushCancelRequest(ctx, target);
}

fn pushCancelRequest(ctx: *Ctx, target: u64) bool {
    const cancel_idx = ctx.ring.slots.add(.{ .timeout = .{} }) catch return false;
    ctx.ring.ring.pushCancel(cancel_idx, target, .{}) catch {
        ctx.ring.slots.del(cancel_idx);
        return false;
    };
    return true;
}

/// Submits every cancel the intake has decided on but not yet landed. The
/// loop calls it once per pass; a refused push is retried on the next one.
fn requestHandshakeCancels(ctx: *Ctx) void {
    for (ctx.handshakes) |*entry| {
        tryCancelRead(ctx, entry);
        tryCancelDeadline(ctx, entry);
    }
}

fn hasUnsentCancel(ctx: *const Ctx) bool {
    for (ctx.handshakes) |entry| {
        if (entry.read_cancel_requested and !entry.read_cancel_sent and entry.read_idx != null) return true;
        if (entry.deadline_cancel_requested and !entry.deadline_cancel_sent and entry.deadline_idx != null) return true;
    }
    return false;
}

fn handshakesQuiescent(ctx: *const Ctx) bool {
    for (ctx.handshakes) |entry| {
        if (entry.state != .free) return false;
    }
    return true;
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

    // 1b. Cancel the peer accept arm the same way. Its completions are matched
    // by their own task index, so the two cancels never collide.
    if (ctx.peer_listening) {
        ctx.peer_listening = false;
        const peer_idx = ctx.peer_accept_task_idx.?;
        if (ctx.ring.slots.add(.{ .timeout = .{} })) |cancel_idx| {
            ctx.peer_cancel_task_idx = cancel_idx;
            ctx.ring.ring.pushCancel(cancel_idx, peer_idx, .{}) catch |err| {
                ctx.log.warn("peer accept cancel failed", .{ .err = @errorName(err) });
                ctx.ring.slots.del(cancel_idx);
                ctx.peer_cancel_task_idx = null;
            };
        } else |err| {
            ctx.log.warn("could not allocate a peer cancel slot", .{ .err = @errorName(err) });
        }
    }

    // 1c. Stop posting peer hand-overs and retire the connections this front
    // still owns. Their reads and deadlines are cancelled and the entries stay
    // reserved until those completions land.
    var handshake_idx: u32 = 0;
    while (handshake_idx < ctx.handshakes.len) : (handshake_idx += 1) {
        closeForShutdown(ctx, handshake_idx);
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

fn routeAccepted(ctx: *Ctx, accepted: *res_handle.SocketHandle) void {
    const k = ctx.round_robin % ctx.front().index_count;
    ctx.round_robin +%= 1;

    const fd = ctx.ctrl.borrowSocket(accepted);
    ctx.ownInbox(k).push(.{ .create = .{ .fd = fd } }) catch {
        // The HLD failure policy: when the queue is full the front drops the
        // connection immediately instead of keeping a backlog of its own.
        ctx.log.warn("index inbox full, dropping connection", .{ .ring_idx = ctx.front().ring_idx, .fd = fd });
        ctx.ctrl.closeSocket(accepted);
        return;
    };
    ctx.ctrl.disownSocket(accepted);
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
    const role: resources.Role = .{ .front = .{
        .ring_idx = 0,
        .first_index = .{ .ring_idx = 2, .inbox_idx = 0 },
        .index_count = 2,
    } };
    try std.testing.expectEqual(@as(u16, 2), role.front.first_index.ring_idx);
    try std.testing.expectEqual(@as(u16, 2), role.front.index_count);
}

test "the greet checks run version, host and index in that order" {
    // A foreign version makes the rest of the layout unknown, so it wins even
    // when the host and index are also illegal.
    try std.testing.expectEqual(cluster_transport.Verdict.version_mismatch, switch (classifyGreet(
        .{ .version = cluster_transport.VERSION + 1, .host_idx = 9, .index_idx = 9 },
        2,
        0,
        4,
    )) {
        .reject => |verdict| verdict,
        .route => return error.TestUnexpectedResult,
    });

    // `host_idx >= hosts` and the own host are both invalid hosts.
    try std.testing.expectEqual(cluster_transport.Verdict.invalid_host, switch (classifyGreet(
        .{ .version = cluster_transport.VERSION, .host_idx = 2, .index_idx = 0 },
        2,
        0,
        4,
    )) {
        .reject => |verdict| verdict,
        .route => return error.TestUnexpectedResult,
    });
    try std.testing.expectEqual(cluster_transport.Verdict.invalid_host, switch (classifyGreet(
        .{ .version = cluster_transport.VERSION, .host_idx = 1, .index_idx = 0 },
        2,
        1,
        4,
    )) {
        .reject => |verdict| verdict,
        .route => return error.TestUnexpectedResult,
    });

    // A host that names no target ring is the front's `unknown_index`.
    try std.testing.expectEqual(cluster_transport.Verdict.unknown_index, switch (classifyGreet(
        .{ .version = cluster_transport.VERSION, .host_idx = 1, .index_idx = 4 },
        2,
        0,
        4,
    )) {
        .reject => |verdict| verdict,
        .route => return error.TestUnexpectedResult,
    });

    const route = switch (classifyGreet(
        .{ .version = cluster_transport.VERSION, .host_idx = 1, .index_idx = 3 },
        2,
        0,
        4,
    )) {
        .route => |route| route,
        .reject => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(u8, 1), route.host_idx);
    try std.testing.expectEqual(@as(u16, 3), route.index_idx);
}

test "a handshake entry is settled only after its completions land" {
    var entry = PeerHandshake{ .state = .done };
    try std.testing.expect(entry.settled());

    // A read still in flight keeps the slot reserved for its CQE.
    entry.read_idx = 7;
    entry.state = .done;
    try std.testing.expect(!entry.settled());
    entry.read_idx = null;
    try std.testing.expect(entry.settled());

    // An unposted hand-over still owns both its descriptor and its slot.
    entry.state = .posting;
    entry.fd = res_handle.adopt(3);
    entry.post_slot = 4;
    try std.testing.expect(!entry.settled());
}
