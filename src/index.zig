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
const config = @import("config.zig");
const idxinbox = @import("index_inbox.zig");
const messages = @import("messages.zig");
const state = @import("state.zig");
const wal = @import("wal.zig");

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

    // The thread's completion dispatch: its own ring's stream window and slot
    // table, where a WAL read arms its block reads (§6).
    const stream_io = wal.FileReadProcess.Io{
        .stream = &ring.sqstream,
        .slots = &ring.slots,
    };

    // One data set per member of the replication group, indexed by host_idx;
    // the own data set sits at the configured host slot. The group is sized by
    // the WAL config, and the own slot is bounds-checked by config validation
    // (§A1), so the thread takes it as given.
    const data_sets = ctrl.allocator.alloc(state.IndexState, ctrl.cfg.wal.hosts()) catch |err| {
        log.err("index state allocation failed", .{
            .ring_idx = role.index.ring_idx,
            .err = @errorName(err),
        });
        std.process.exit(1);
    };
    defer ctrl.allocator.free(data_sets);

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
        for (data_sets) |*st| ctrl.deinitIndexState(st);
    }

    // snapshot design: each data set's WAL writer is opened here, on this
    // thread, once the snapshot loader has set `st.state` from the file-name
    // tag — `ctrl.walOpenWrite(host, idx, tag)`, then
    // `writer.attachStream(&ring.sqstream, &ring.slots)` so its flushes leave
    // through this ring's stream window (§6), then the replay through
    // `ctrl.walOpenRead(host, idx, tag)` into `st`. The sequencing is the
    // snapshot design's (§10); the seam is `lifetime.Controller`'s.
    const own_state = &data_sets[ctrl.cfg.host_index];

    const cfg = LoopConfig{};
    var draining = false;
    // The stop is thread-level (§3.5): one faulted WAL denies this thread's
    // whole front intake, whichever data set the fault came from.
    var faulted = false;

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
                // snapshot design: the fd transfer that ends a snapshot arrives
                // as a cross-task slot message and is dispatched here; its swap
                // step is `ctrl.walAdoptWrite(host, idx, tag, fd)`, synchronous
                // and cold, after which the new writer is attached to this
                // ring's stream window like any other.
                else => {
                    // A tracked operation's completion: the slot says what it
                    // was and what steps it (§6). Reserved control indices and
                    // already-retired slots have no context here.
                    const ctx = ring.slots.get(cqe.taskIdx()) orelse continue;
                    switch (ctx) {
                        // A flush in flight: its completion reclaims the buffer
                        // and advances the writer's queue — or, on a negative
                        // `res`, stops the writer and the thread (§3.5).
                        .wal_flush => |flush| {
                            flush.writer.flushResult(cqe);
                            if (flush.writer.faulted) {
                                faulted = true;
                                log.err("wal flush failed; the thread stops taking front work", .{
                                    .ring_idx = role.index.ring_idx,
                                    .host_idx = flush.writer.host_idx,
                                    .index_idx = flush.writer.index_idx,
                                });
                            }
                        },
                        // One block of a read walk: its completion delivers the
                        // records and arms the next block.
                        .file_read => |read| {
                            read.file_process.onCQE(stream_io, cqe) catch |err| {
                                log.err("wal read failed", .{
                                    .ring_idx = role.index.ring_idx,
                                    .offset = read.offset,
                                    .err = @errorName(err),
                                });
                                // A negative `res` on a WAL read is the stop's
                                // second trigger; backpressure or a refused op
                                // only stops this walk.
                                if (err == error.IO) faulted = true;
                            };
                        },
                        else => {},
                    }
                },
            }
        }
        batch.ring.commit() catch |err| {
            log.err("index CQ commit failed", .{ .ring_idx = role.index.ring_idx, .err = @errorName(err) });
            std.process.exit(1);
        };

        while (batch.front.next()) |task| switch (task) {
            .create => |create| {
                // A stopped thread takes no front work at all: the session is
                // refused by closing its descriptor at once, the skeleton's own
                // shape. The refusal's wire form is the consensus design's.
                if (faulted) {
                    log.warn("index refused a session: the WAL stopped this thread", .{
                        .ring_idx = role.index.ring_idx,
                        .fd = create.fd,
                    });
                    _ = std.os.linux.close(create.fd);
                    continue;
                }
                // The skeleton owns no session state yet: take ownership of the
                // descriptor, log it, and close it again.
                log.info("index received session", .{ .ring_idx = role.index.ring_idx, .fd = create.fd });
                _ = std.os.linux.close(create.fd);
            },
            .session_op => {
                // Refused before a WAL is ever reached (§3.5).
                if (faulted) continue;
            },
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
///
/// The only direct push left on an index ring (`designs/wal-impl.md` §6): a
/// shutdown report has no stream state of its own, and `pushMsgRing` leaves the
/// stream window's cursors alone, so the two submission paths cannot diverge
/// here. The WAL never takes this route.
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

/// The records the end-to-end test writes, each one a `create` op's payload.
///
/// One record per buffer: `framedLen(494) == 16 + 2 + 494 == 512`, so every
/// record ends on a buffer boundary and none is left in the live tail, which a
/// plain-mode close does not flush (§2: a record is durable once its buffer's
/// flush completes, and only filled buffers are flushed).
const e2e_records: usize = 6;
const e2e_op_len: usize = 494;
const e2e_tag: u128 = 0x2000;

/// The readout's sink: the record's state goes into the data set first and the
/// op is applied after — `applyIndexOp`'s contract, and the reason the sink
/// receives the state separately.
const Replay = struct {
    ctrl: *lifetime.Controller,
    st: *state.IndexState,
    applied: usize = 0,

    fn apply(ctx: ?*anyopaque, state_idx: u128, op: []const u8) anyerror!void {
        const self: *Replay = @ptrCast(@alignCast(ctx.?));
        self.st.state = state_idx;
        try self.ctrl.applyIndexOp(self.st, .{ .create = .{ .compensator = "marker", .payload = op } });
        self.applied += 1;
    }
};

/// Creates (or empties) the WAL file a snapshot would have handed over.
/// Creation itself is elephant-side (`designs/wal-impl.md` §1.1), so the test
/// stands in for it.
fn createWalFile(path: [:0]const u8) !posix.fd_t {
    const fd_raw = std.os.linux.open(path, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, 0o644);
    const errno = std.os.linux.errno(fd_raw);
    if (errno != .SUCCESS) return std.posix.unexpectedErrno(errno);
    return @intCast(fd_raw);
}

test "plain-mode records replay into a fresh data set after a reopen" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(
        testing.allocator,
        ".zig-cache/tmp/{s}",
        .{tmp.sub_path[0..]},
    );
    defer testing.allocator.free(dir);

    var cfg: config.Config = .{
        .fronts = 1,
        .indexes = 1,
        .elephants = 1,
        .queue_depth = 64,
        .cross_task_slots = 8,
        .sqpoll_threads = 1,
        .ring_slots_capacity = 4096,
        .index_inbox_capacity = 8,
        .wal = .{ .plain = .{ .dir = dir, .buffers = 32, .lba = 512 } },
        .logging = .{
            .method = .{ .json = {} },
            .pool_capacity = 64,
            .pool_frame_size = 1024,
        },
    };

    var ctrl: lifetime.Controller = undefined;
    try ctrl.init(testing.allocator, &cfg);
    defer ctrl.deinit();
    try ctrl.compensators.put("marker", .{ .bind = "10.0.0.1", .port = 20301 });

    // The index thread's own ring carries both the flushes and the replay's
    // block reads, so the test drives the same two submission paths the
    // service loop does.
    try ctrl.initRing(0, 1);
    defer ctrl.rings[0].deinit();
    const ring = &ctrl.rings[0];
    const stream_io = wal.FileReadProcess.Io{ .stream = &ring.sqstream, .slots = &ring.slots };

    const path = try wal.walPath(testing.allocator, dir, 0, 0, e2e_tag);
    defer testing.allocator.free(path);
    const created = try createWalFile(path);
    _ = std.os.linux.close(created);

    var written: [e2e_records]u128 = undefined;
    var ops: [e2e_records][e2e_op_len]u8 = undefined;
    for (&ops, 0..) |*op, i| {
        for (op, 0..) |*byte, j| byte.* = @truncate(j *% 31 +% i *% 7 +% 1);
    }
    for (&written, 0..) |*state_idx, i| state_idx.* = e2e_tag + 1 + i;

    {
        const writer = try ctrl.walOpenWrite(0, 0, e2e_tag);
        writer.attachStream(&ring.sqstream, &ring.slots);
        for (written, 0..) |state_idx, i| try writer.write(state_idx, writer.head, &ops[i]);
        // `close` retries a parked submission and awaits the flush in flight,
        // so the file holds every record once it returns.
        try writer.close();
        try testing.expect(!writer.faulted);
    }

    var fresh: state.IndexState = undefined;
    try ctrl.initIndexState(&fresh);
    defer ctrl.deinitIndexState(&fresh);

    var reference: state.IndexState = undefined;
    try ctrl.initIndexState(&reference);
    defer ctrl.deinitIndexState(&reference);

    var replay = Replay{ .ctrl = &ctrl, .st = &fresh };
    {
        const reader = try ctrl.walOpenRead(0, 0, e2e_tag);
        defer ctrl.walCloseRead(reader);
        const process = try reader.beginRead(
            testing.allocator,
            .read_all,
            .{ .ctx = &replay, .apply = Replay.apply },
        );
        defer reader.endRead(testing.allocator, process);
        try process.drive(stream_io);
        try testing.expect(process.done);
    }
    try testing.expectEqual(e2e_records, replay.applied);

    // The reference: the same ops applied live, in the order they were written.
    for (written, 0..) |state_idx, i| {
        reference.state = state_idx;
        try ctrl.applyIndexOp(&reference, .{ .create = .{ .compensator = "marker", .payload = &ops[i] } });
    }

    try testing.expectEqual(reference.state, fresh.state);
    try testing.expectEqual(reference.sessions.count(), fresh.sessions.count());
    for (written) |state_idx| {
        const want = reference.sessions.get(state_idx) orelse return error.MissingReferenceSession;
        const got = fresh.sessions.get(state_idx) orelse return error.MissingReplayedSession;
        try testing.expectEqual(want.data.original_id, got.data.original_id);
        try testing.expectEqual(want.data.retry_count, got.data.retry_count);
        try testing.expectEqualStrings(want.data.compensator, got.data.compensator);
        try testing.expectEqualSlices(
            u8,
            want.data.data.backing[0..want.data.data.len],
            got.data.data.backing[0..got.data.data.len],
        );
    }
}
