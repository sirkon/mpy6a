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
const cross_task = @import("cross_task.zig");
const snapshot = @import("snapshot.zig");

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

/// The index service loop's frame: the state the per-CQE drain, the tick pass
/// and the snapshot dispatch share. It lives in `run`'s frame; tests drive the
/// same functions with synthetic states.
const Frame = struct {
    ctrl: *lifetime.Controller,
    ring: *lifetime.RingStuff,
    front_ring: *zigring.Ring,
    logger: *lifetime.LoggerStuff,
    ring_idx: u16,
    /// The index's own number: the `index_idx` of every pair it hosts.
    index_idx: u16,
    data_sets: []state.IndexState,
    stream_io: wal.FileReadProcess.Io,
    soft_draining: bool = false,
    /// The snapshot procedure's policy state.
    snap: snapshot.State = .{},

    fn host(self: *Frame) snapshot.Host {
        return .{
            .ctrl = self.ctrl,
            .ring = self.ring,
            .log = &self.logger.logger,
            .ring_idx = self.ring_idx,
            .index_idx = self.index_idx,
            .data_sets = self.data_sets,
        };
    }
};

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

    // The cold per-pair startup sequence (§7.1): adoption rule, registry,
    // snapshot, writer, bring-tail and replay. It runs before the service loop
    // and before any open of a pair; a failed pair is a startup fatality.
    for (0..ctrl.cfg.wal.hosts()) |host| {
        snapshot.recoverPair(ctrl, ring, log, role.index.inbox_idx, @intCast(host), &data_sets[host]) catch |err| {
            log.err("index recovery failed", .{
                .ring_idx = role.index.ring_idx,
                .host_idx = host,
                .err = @errorName(err),
            });
            std.process.exit(1);
        };
    }

    const own_state = &data_sets[ctrl.cfg.host_index];

    const cfg = LoopConfig{};

    var frame = Frame{
        .ctrl = ctrl,
        .ring = ring,
        .front_ring = front_ring,
        .logger = logger,
        .ring_idx = role.index.ring_idx,
        .index_idx = role.index.inbox_idx,
        .data_sets = data_sets,
        .stream_io = stream_io,
    };
    snapshot.armTicker(frame.host());

    while (true) {
        // One pending push per pass: a procedure's pushes are sequential, so a
        // single op suffices (§4).
        frame.snap.retryPending(frame.host());

        const batch = inbox.batch(cfg.batch_k, cfg.batch_k) orelse {
            // A pending push must not park: the loop keeps passing until the
            // `MSG_RING` lands.
            if (frame.snap.pending_push != null) {
                std.atomic.spinLoopHint();
                continue;
            }
            inbox.hang(cfg);
            continue;
        };

        // The CQ is strictly drained before the inbound queue.
        while (batch.ring.popCQE()) |cqe| stepCQE(&frame, cqe);
        batch.ring.commit() catch |err| {
            log.err("index CQ commit failed", .{ .ring_idx = role.index.ring_idx, .err = @errorName(err) });
            std.process.exit(1);
        };

        // A reply armed a continuation: finish it now that the batch cursor is
        // published, and before any front task. The pump's raw `popCQE` must
        // never run inside the batch window (§5, D1).
        if (frame.snap.drainPending()) {
            drainPump(&frame);
            continue;
        }

        while (batch.front.next()) |task| switch (task) {
            .create => |create| {
                // A stopped thread takes no front work at all: the session is
                // refused by closing its descriptor at once, the skeleton's own
                // shape. The refusal's wire form is the consensus design's.
                if (frame.snap.serve != .serving) {
                    log.warn("index refused a session: the WAL stopped this thread", .{
                        .ring_idx = role.index.ring_idx,
                        .fd = create.fd,
                        .wal_serve = @tagName(frame.snap.serve),
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
                // Refused before a WAL is ever reached (§3.5). A frozen window
                // denies the front exactly like a stop; only the front intake
                // is denied.
                if (frame.snap.serve != .serving) continue;
            },
            .shutdown_soft => {
                if (!frame.soft_draining) {
                    frame.soft_draining = true;
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
        if (frame.soft_draining and own_state.sessions.count() == 0) {
            reportDrained(ring, front_ring, role.index.ring_idx);
            return;
        }
    }
}

/// Steps one completion of the thread's own ring: the reserved control arms,
/// the snapshot tick and the tracked operations. Named so the bounded drain of
/// the swap (§3.4) reuses exactly this dispatch.
fn stepCQE(frame: *Frame, cqe: zigring.CQE) void {
    switch (cqe.taskIdx()) {
        // The launch broadcast is a no-op for an index: it ignores the socket
        // fd and keeps working off its ring and its inbox.
        messages.StartWorkIdx => {},
        // A payload-less wakeup: the inbox drain below delivers.
        messages.IndexWakeupTaskIdx => {},
        // A cross-task slot message, receiver-released on read exactly like the
        // elephant's arm. This is the elephant→index direction: the fd reply,
        // the abandon, the completion and the terminal reply all ride it (§4).
        messages.CrossTaskMessageIdx => {
            const slot_idx: u32 = @intCast(cqe.res);
            const task = frame.ctrl.cross_slots.at(slot_idx).*;
            frame.ctrl.cross_slots.release(slot_idx);
            // The reply's `MSG_RING` was a direct push into this ring from the
            // elephant's thread, so it moved the SQ tail past the stream
            // window's cursors. Re-capture them before the pass (and any WAL
            // flush it triggers) submits through the same window (§4).
            frame.snap.resync(frame.host());
            frame.snap.onReply(frame.host(), task);
        },
        // The repeating snapshot ticker's own timeout completion (§1.1).
        messages.SnapshotTickIdx => frame.snap.onTick(frame.host()),
        else => {
            // A tracked operation's completion: the slot says what it was and
            // what steps it (§6). Reserved control indices and already-retired
            // slots have no context here.
            const ctx = frame.ring.slots.get(cqe.taskIdx()) orelse return;
            switch (ctx) {
                // A flush in flight: its completion reclaims the buffer and
                // advances the writer's queue — or, on a negative `res`, stops
                // the writer and the thread (§3.5).
                .wal_flush => |flush| {
                    flush.writer.flushResult(cqe);
                    // The window's completions follow both sides' frontiers:
                    // an event is durable only once the last of the two has
                    // covered it (§5).
                    frame.snap.onFlush(frame.host(), flush.writer);
                    frame.snap.onWriterFault(frame.host(), flush.writer);
                },
                // One block of a read walk: its completion delivers the records
                // and arms the next block.
                .file_read => |read| {
                    read.file_process.onCQE(frame.stream_io, cqe) catch |err| {
                        frame.logger.logger.err("wal read failed", .{
                            .ring_idx = frame.ring_idx,
                            .offset = read.offset,
                            .err = @errorName(err),
                        });
                        // A negative `res` on a WAL read is the stop's second
                        // trigger; backpressure or a refused op only stops this
                        // walk.
                        if (err == error.IO) frame.snap.onReadFault();
                    };
                },
                else => {},
            }
        },
    }
}

/// Steps the armed continuation outside the batch window (§5, D1). A reply
/// only records the continuation; the pump is the sole reader that finishes
/// it, and it never runs while `inbox.batch` holds an uncommitted cursor.
fn drainPump(frame: *Frame) void {
    while (frame.snap.drainPending()) {
        if (frame.snap.drainQuiet()) {
            frame.snap.onDrained(frame.host());
            continue;
        }
        if (frame.ring.ring.popCQE()) |cqe| {
            stepCQE(frame, cqe);
            continue;
        }
        frame.ring.ring.park();
    }
}

/// Test helper: drain the window and any continuation a completion arms.
fn pumpWindow(frame: *Frame) void {
    while (true) {
        if (frame.snap.drainPending()) {
            drainPump(frame);
            continue;
        }
        if (frame.snap.drainQuiet()) return;
        if (frame.ring.ring.popCQE()) |cqe| {
            stepCQE(frame, cqe);
            continue;
        }
        frame.ring.ring.park();
    }
}

/// The producer contract of §6: a record handed to an index thread's write path
/// must frame into the pair's `lba`, the buffer size and flush granularity.
///
/// The check belongs at the thread's intake, where every dispatched event
/// passes, window or not; the skeleton's front message does not carry an op
/// payload yet, so the byte length arrives with the consensus channel and its
/// refusal's wire shape is that design's. The 1 MiB structural cap stays the
/// WAL's own (`RecordTooLarge`), and records still legally span `lba`-sized
/// buffers.
fn recordFits(lba: u32, op_len: usize) bool {
    return wal.framedLen(op_len) <= lba;
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
        .wal = .{ .plain = .{ .dir = dir, .buffers = 32, .lba = config.kib(1) } },
        .logging = .{
            .method = .{ .json = {} },
            .pool_capacity = 64,
            .pool_frame_size = config.bytes(1024),
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

    // The elephant creates the file under the index directory the pair lives
    // in; the test stands in for it (designs/SNAPSHOTS.md §2.3).
    try ctrl.ensureIndexDir(0);
    const index_dir = try ctrl.indexDirPath(0);
    defer testing.allocator.free(index_dir);

    const path = try wal.walPath(testing.allocator, index_dir, 0, 0, e2e_tag);
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

/// The config every Stage E test starts from: one front, one index, a plain
/// battery, and an explicit elephant count and snapshot block.
fn testConfig(dir: []const u8, hosts: u32, elephants: u16, snapshots: config.Snapshots) config.Config {
    return .{
        .fronts = 1,
        .indexes = 1,
        .elephants = elephants,
        .queue_depth = 64,
        .cross_task_slots = 8,
        .sqpoll_threads = 1,
        .ring_slots_capacity = 4096,
        .index_inbox_capacity = 8,
        .wal = .{ .plain = .{ .dir = dir, .buffers = 8, .lba = config.kib(1), .hosts = hosts } },
        .snapshots = snapshots,
        .logging = .{
            .method = .{ .json = {} },
            .pool_capacity = 64,
            .pool_frame_size = config.bytes(1024),
        },
    };
}

fn testFrame(
    ctrl: *lifetime.Controller,
    ring_idx: u16,
    logger: *lifetime.LoggerStuff,
    data_sets: []state.IndexState,
) Frame {
    return .{
        .ctrl = ctrl,
        .ring = &ctrl.rings[ring_idx],
        .front_ring = &ctrl.rings[0].ring,
        .logger = logger,
        .ring_idx = ring_idx,
        .index_idx = 0,
        .data_sets = data_sets,
        .stream_io = .{
            .stream = &ctrl.rings[ring_idx].sqstream,
            .slots = &ctrl.rings[ring_idx].slots,
        },
    };
}

fn dropTestLogger(ctrl: *lifetime.Controller, logger: *lifetime.LoggerStuff) void {
    logger.deinit(ctrl.allocator);
    ctrl.allocator.destroy(logger);
}

/// Spins until the ring yields one completion or the deadline passes.
fn cqeBefore(ring: *zigring.Ring, deadline_ns: u64) ?zigring.CQE {
    while (zigring.monotonicNs() < deadline_ns) {
        if (ring.popCQE()) |cqe| return cqe;
        std.atomic.spinLoopHint();
    }
    return null;
}

test "the cross-task arm releases the slot it read" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(dir);

    var cfg = testConfig(dir, 1, 0, .{});
    var ctrl: lifetime.Controller = undefined;
    try ctrl.init(testing.allocator, &cfg);
    defer ctrl.deinit();

    // Ring 0 sends, ring 1 is the index's own.
    try ctrl.initRing(0, 1);
    defer ctrl.rings[0].deinit();
    try ctrl.initRing(1, 1);
    defer ctrl.rings[1].deinit();

    const logger = try ctrl.getLogger(1);
    defer dropTestLogger(&ctrl, logger);

    var frame = testFrame(&ctrl, 1, logger, &.{});

    // A synthetic in-flight procedure: `SnapshotDone` is its terminal reply.
    var job: lifetime.SnapshotJob = undefined;
    frame.snap.procedure = &job;

    const full = ctrl.cross_slots.freeCount();
    const slot_idx = try ctrl.cross_slots.acquire();
    ctrl.cross_slots.at(slot_idx).* = .{ .SnapshotDone = .{} };

    try ctrl.rings[0].ring.pushMsgRingFd(
        ctrl.rings[1].ring.fd,
        messages.CrossTaskMessageIdx,
        slot_idx,
        .{},
    );

    const cqe = cqeBefore(&ctrl.rings[1].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
        return error.CrossTaskCqeTimeout;
    try testing.expectEqual(messages.CrossTaskMessageIdx, cqe.taskIdx());
    try testing.expectEqual(slot_idx, @as(u32, @intCast(cqe.res)));

    stepCQE(&frame, cqe);

    // The arm released the slot on read and the terminal reply cleared the
    // procedure.
    try testing.expectEqual(full, ctrl.cross_slots.freeCount());
    try testing.expect(frame.snap.procedure == null);
}

test "the repeating ticker produces SnapshotTickIdx completions" {
    const testing = std.testing;

    var ring: zigring.Ring = undefined;
    try ring.init(64, null);
    defer ring.deinit();

    var spec = std.os.linux.kernel_timespec{ .sec = 0, .nsec = 20 * std.time.ns_per_ms };
    try ring.pushTicker(messages.SnapshotTickIdx, &spec, 0, .{});

    var fired: u32 = 0;
    const deadline = zigring.monotonicNs() + 5 * std.time.ns_per_s;
    while (fired < 2) {
        const cqe = cqeBefore(&ring, deadline) orelse return error.SnapshotTickTimeout;
        if (cqe.taskIdx() != messages.SnapshotTickIdx) continue;
        try testing.expectEqual(std.os.linux.E.TIME, cqe.errno());
        try testing.expect(cqe.hasMore());
        fired += 1;
    }

    const cancel_idx: u64 = 0x1000;
    try ring.pushCancel(cancel_idx, messages.SnapshotTickIdx, .{});

    var saw_cancel = false;
    var saw_end = false;
    const cancel_deadline = zigring.monotonicNs() + 5 * std.time.ns_per_s;
    while (!saw_cancel or !saw_end) {
        const cqe = cqeBefore(&ring, cancel_deadline) orelse return error.SnapshotCancelTimeout;
        if (cqe.taskIdx() == cancel_idx) {
            if (cqe.res == 0) {
                saw_cancel = true;
            } else {
                // A shot raced the request's re-arm and the cancel matched
                // nothing: ask again. The ticker is unlimited, so it is still
                // there to find.
                try ring.pushCancel(cancel_idx, messages.SnapshotTickIdx, .{});
            }
        } else if (cqe.taskIdx() == messages.SnapshotTickIdx) {
            // The final completion of the canceled ticker.
            try testing.expect(!cqe.hasMore());
            try testing.expectEqual(std.os.linux.E.CANCELED, cqe.errno());
            saw_end = true;
        }
    }
}

test "the drain routes the snapshot tick to the tick pass" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(dir);

    var cfg = testConfig(dir, 1, 0, .{});
    var ctrl: lifetime.Controller = undefined;
    try ctrl.init(testing.allocator, &cfg);
    defer ctrl.deinit();
    try ctrl.initRing(1, 1);
    defer ctrl.rings[1].deinit();

    const logger = try ctrl.getLogger(1);
    defer dropTestLogger(&ctrl, logger);

    var frame = testFrame(&ctrl, 1, logger, &.{});
    // A stopped thread makes the pass end after its skip guard: the counter is
    // the routing spy.
    frame.snap.serve = .stopped;

    stepCQE(&frame, .{ .user_data = messages.SnapshotTickIdx, .res = 0, .flags = 0 });

    try testing.expectEqual(@as(u32, 1), frame.snap.ticks);
    try testing.expect(frame.snap.procedure == null);
}

/// Opens the pair at `host` with the given tag and writes `records` one after
/// another, creating the WAL file the elephant normally creates.
fn testWriter(
    ctrl: *lifetime.Controller,
    host: u8,
    tag: u128,
    records: u32,
    record_len: usize,
) !void {
    const dir = try ctrl.indexDirPath(0);
    defer ctrl.allocator.free(dir);
    const path = try wal.walPath(ctrl.allocator, dir, host, 0, tag);
    defer ctrl.allocator.free(path);

    const created = try createWalFile(path);
    _ = std.os.linux.close(created);

    const writer = try ctrl.walOpenWrite(host, 0, tag);
    const data = try ctrl.allocator.alloc(u8, record_len);
    defer ctrl.allocator.free(data);
    @memset(data, 0x5a);

    var i: u32 = 0;
    while (i < records) : (i += 1) {
        try writer.write(tag + 1 + i, tag + i, data);
    }
}

/// Creates the WAL file the elephant would have created and opens its writer:
/// the window's old side, registered on its pair.
fn openPairWriter(ctrl: *lifetime.Controller, host: u8, index: u16, tag: u128) !*wal.WalWriteFile {
    try ctrl.ensureIndexDir(index);
    const dir = try ctrl.indexDirPath(index);
    defer ctrl.allocator.free(dir);
    const path = try wal.walPath(ctrl.allocator, dir, host, index, tag);
    defer ctrl.allocator.free(path);
    const fd = try createWalFile(path);
    _ = std.os.linux.close(fd);
    return ctrl.walOpenWrite(host, index, tag);
}

/// The window's new side: the file created the elephant's way, then adopted on
/// temp ring `k`, chained from the clone state.
fn adoptWindowWriter(
    ctrl: *lifetime.Controller,
    host: u8,
    index: u16,
    k: u32,
    tag: u128,
    clone_state: u128,
) !*wal.WalWriteFile {
    try ctrl.ensureIndexDir(index);
    const dir = try ctrl.indexDirPath(index);
    defer ctrl.allocator.free(dir);
    const path = try wal.walPath(ctrl.allocator, dir, host, index, tag);
    defer ctrl.allocator.free(path);
    const fd = try createWalFile(path);
    return ctrl.walAdoptWrite(host, index, k, clone_state, fd);
}

/// Tears a synthetic window down without an elephant: the new writer is the
/// caller's, the pair's writer stays registered.
fn dropWindow(frame: *Frame) void {
    if (frame.snap.window) |*window| {
        _ = std.os.linux.close(window.new.fd);
        frame.ctrl.allocator.destroy(window.new);
        window.pending.deinit(frame.ctrl.allocator);
        frame.snap.window = null;
    }
}

/// Releases a test's job the way its terminal elephant would.
fn dropTestJob(ctrl: *lifetime.Controller, job: *lifetime.SnapshotJob) void {
    ctrl.snapshot_slots.at(job.k).status = .idle;
    ctrl.snapshot_slots.release(job.k);
    if (job.fd != -1) _ = std.os.linux.close(job.fd);
    if (job.old_fd != -1) _ = std.os.linux.close(job.old_fd);
    ctrl.releaseSnapshotJob(job);
}

/// The pair's control line, as the restart rule reads it.
fn pairControlLine(ctrl: *lifetime.Controller) *wal.BufferHeader {
    return wal.controlLineOf(
        ctrl.wal_battery.?[0..ctrl.wal_area_stride],
        ctrl.cfg.wal.buffers(),
        ctrl.cfg.wal.lba(),
    );
}

/// The bytes of one file, read back whole.
fn readFileBytes(allocator: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    const fd_raw = std.os.linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    const errno = std.os.linux.errno(fd_raw);
    if (errno != .SUCCESS) return std.posix.unexpectedErrno(errno);
    const fd: posix.fd_t = @intCast(fd_raw);
    defer _ = std.os.linux.close(fd);

    const size = try wal.fileSize(fd);
    const bytes = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(bytes);

    var got: usize = 0;
    while (got < bytes.len) {
        const res = std.os.linux.pread(fd, bytes[got..].ptr, bytes.len - got, @intCast(got));
        const read_errno = std.os.linux.errno(res);
        if (read_errno != .SUCCESS) return std.posix.unexpectedErrno(read_errno);
        if (res == 0) break;
        got += res;
    }
    return bytes[0..got];
}

test "the bounded drain waits for both writers' in-flight flushes" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(dir);

    var cfg = testConfig(dir, 1, 1, .{ .slots = 2 });
    var ctrl: lifetime.Controller = undefined;
    try ctrl.init(testing.allocator, &cfg);
    defer ctrl.deinit();
    try ctrl.initRing(1, 1);
    defer ctrl.rings[1].deinit();

    const logger = try ctrl.getLogger(1);
    defer dropTestLogger(&ctrl, logger);

    var sets = [_]state.IndexState{undefined};
    try ctrl.initIndexState(&sets[0]);
    defer ctrl.deinitIndexState(&sets[0]);

    const old = try openPairWriter(&ctrl, 0, 0, 0x100);
    const k = try ctrl.snapshot_slots.acquire();
    const new = try adoptWindowWriter(&ctrl, 0, 0, k, 0x100, 0x100);
    old.attachStream(&ctrl.rings[1].sqstream, &ctrl.rings[1].slots);
    new.attachStream(&ctrl.rings[1].sqstream, &ctrl.rings[1].slots);

    var frame = testFrame(&ctrl, 1, logger, &sets);
    frame.snap.window = .{ .new = new, .old = old, .allocator = ctrl.allocator };
    defer {
        dropWindow(&frame);
        ctrl.snapshot_slots.release(k);
    }

    var op: [1006]u8 = undefined;
    @memset(&op, 0x22);
    try frame.snap.window.?.write(0x101, &op);
    try testing.expect(!frame.snap.window.?.quiet());
    try testing.expect(old.flush_in_flight and new.flush_in_flight);

    pumpWindow(&frame);

    // Both completions were stepped through the ordinary dispatch; the writers
    // are quiet and the events they carried are complete.
    try testing.expect(frame.snap.window.?.quiet());
    try testing.expect(!old.flush_in_flight and !old.flush_pending);
    try testing.expect(!new.flush_in_flight and !new.flush_pending);
    try testing.expectEqual(@as(u64, 1), old.flushed_upto);
    try testing.expectEqual(@as(u64, 1), new.flushed_upto);
    try testing.expectEqual(@as(usize, 0), frame.snap.window.?.pending.items.len);
}

test "the completion pass drains, copies, rewires, clears, revives and closes" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(dir);

    var cfg = testConfig(dir, 1, 1, .{ .slots = 2 });
    var ctrl: lifetime.Controller = undefined;
    try ctrl.init(testing.allocator, &cfg);
    defer ctrl.deinit();
    try ctrl.initRing(1, 1);
    defer ctrl.rings[1].deinit();
    try ctrl.initRing(2, 1);
    defer ctrl.rings[2].deinit();

    const logger = try ctrl.getLogger(1);
    defer dropTestLogger(&ctrl, logger);

    var sets = [_]state.IndexState{undefined};
    try ctrl.initIndexState(&sets[0]);
    defer ctrl.deinitIndexState(&sets[0]);

    const old = try openPairWriter(&ctrl, 0, 0, 0x100);
    const k = try ctrl.snapshot_slots.acquire();
    const new = try adoptWindowWriter(&ctrl, 0, 0, k, 0x100, 0x100);

    const job = try ctrl.mintSnapshotJob(0, 0, 0x100, k, 1);
    defer dropTestJob(&ctrl, job);
    job.fd = -1;
    ctrl.snapshot_slots.at(k).* = .{ .status = .in_flight, .job = @intFromPtr(job) };

    var frame = testFrame(&ctrl, 1, logger, &sets);
    frame.snap.procedure = job;
    frame.snap.window = .{ .new = new, .old = old, .allocator = ctrl.allocator };
    try ctrl.publishAdoptionMark(0, 0, k, 0x100);

    // A window event: both sides' synchronous sinks make it durable at once.
    var op: [494]u8 = undefined;
    for (&op, 0..) |*byte, i| byte.* = @truncate(i *% 13 +% 5);
    try frame.snap.window.?.write(0x101, &op);

    // The pair area's arrays before the copy: what the swap must reproduce.
    const buffers = cfg.wal.buffers();
    const arrays_len = buffers * cfg.wal.lba() + buffers * @sizeOf(wal.BufferHeader);
    const temp_start = wal.tempAreaIdx(k, ctrl.wal_pairs) * ctrl.wal_area_stride;
    const expected = try testing.allocator.dupe(
        u8,
        ctrl.wal_battery.?[temp_start..][0..arrays_len],
    );
    defer testing.allocator.free(expected);

    // An old-side fault had frozen the front before the completion arrived.
    old.faulted = true;
    frame.snap.serve = .frozen;
    const old_fd = old.fd;

    frame.snap.onReply(frame.host(), .{ .SnapshotDumped = .{} });
    pumpWindow(&frame);

    // The pair area is temp ring k's data and header arrays, byte for byte.
    const pair_bytes = ctrl.wal_battery.?[0..ctrl.wal_area_stride];
    try testing.expectEqualSlices(u8, expected, pair_bytes[0..arrays_len]);

    // The new writer is rewired onto the pair area and registered as its
    // writer; a further write lands there.
    const registered = ctrl.wal_writers[0].?;
    try testing.expectEqual(new, registered);
    try testing.expectEqual(@intFromPtr(pair_bytes.ptr), @intFromPtr(registered.data.ptr));
    var small: [10]u8 = undefined;
    @memset(&small, 0x77);
    try registered.write(0x102, 0x101, &small);
    try testing.expect(std.mem.indexOf(u8, pair_bytes, &small) != null);

    // The mark is gone, the old descriptor moved to the job and is still open,
    // and the final close is dispatched.
    const line = pairControlLine(&ctrl);
    try testing.expectEqual(@as(u8, 0), line.snapshot_in_progress);
    try testing.expectEqual(old_fd, job.old_fd);
    try testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(
        std.os.linux.fcntl(old_fd, std.os.linux.F.GETFD, 0),
    ));
    try testing.expectEqual(lifetime.SnapshotPhase.close_sent, job.phase);
    try testing.expect(frame.snap.window == null);

    const close_cqe = cqeBefore(&ctrl.rings[2].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
        return error.SnapshotDispatchTimeout;
    try testing.expectEqual(messages.CrossTaskMessageIdx, close_cqe.taskIdx());
    const close_slot: u32 = @intCast(close_cqe.res);
    try testing.expectEqual(@intFromPtr(job), ctrl.cross_slots.at(close_slot).SnapshotClose.job);
    ctrl.cross_slots.release(close_slot);

    // The swap revived the frozen front: the old writer is retired from the
    // live set, and the surviving one is healthy.
    try testing.expectEqual(snapshot.Serve.serving, frame.snap.serve);

    // A relapse after the swap finds no window and stops terminally.
    registered.faulted = true;
    frame.snap.onWriterFault(frame.host(), registered);
    try testing.expectEqual(snapshot.Serve.stopped, frame.snap.serve);

    // The terminal reply clears the in-flight flag.
    frame.snap.onReply(frame.host(), .{ .SnapshotDone = .{} });
    try testing.expect(frame.snap.procedure == null);
}

test "recordFits is the pair's lba boundary" {
    const testing = std.testing;

    // 494 op bytes frame to exactly one 512-byte buffer; one more does not.
    try testing.expect(recordFits(512, 494));
    try testing.expect(!recordFits(512, 495));
    try testing.expect(recordFits(512, 0));

    // The 1 MiB structural cap is a separate, unchanged refusal: this record
    // passes the lba check and the WAL itself answers `RecordTooLarge` for it.
    const lba: u32 = 1 << 20;
    const fits_op = lba - 16 - 3;
    try testing.expect(recordFits(lba, fits_op));
    try testing.expect(!recordFits(lba, fits_op + 1));
    try testing.expect(wal.framedLen(fits_op) > wal.BLOCK_CONTENT);
}

/// A sink whose admission pre-check passes once and then refuses once: the
/// write is accepted, its submission parks, and the drain's retry takes it.
const ParkOnceSink = struct {
    var calls: u32 = 0;

    fn reset() void {
        calls = 0;
    }

    fn room(ctx: ?*anyopaque, writer: *wal.WalWriteFile) wal.WalError!void {
        _ = ctx;
        _ = writer;
        calls += 1;
        if (calls == 2) return error.NoFreeSlots;
    }

    fn submit(ctx: ?*anyopaque, writer: *wal.WalWriteFile, ordinal: u64) void {
        _ = ctx;
        writer.flushComplete(ordinal);
    }

    fn install(writer: *wal.WalWriteFile) void {
        writer.sink = .{ .room = room, .submit = submit };
    }
};

test "the drain retries a flush backpressure parked" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(dir);

    var cfg = testConfig(dir, 1, 1, .{ .slots = 2 });
    var ctrl: lifetime.Controller = undefined;
    try ctrl.init(testing.allocator, &cfg);
    defer ctrl.deinit();
    try ctrl.initRing(1, 1);
    defer ctrl.rings[1].deinit();

    const logger = try ctrl.getLogger(1);
    defer dropTestLogger(&ctrl, logger);

    var sets = [_]state.IndexState{undefined};
    try ctrl.initIndexState(&sets[0]);
    defer ctrl.deinitIndexState(&sets[0]);

    const old = try openPairWriter(&ctrl, 0, 0, 0x100);
    const k = try ctrl.snapshot_slots.acquire();
    const new = try adoptWindowWriter(&ctrl, 0, 0, k, 0x100, 0x100);

    var frame = testFrame(&ctrl, 1, logger, &sets);
    frame.snap.window = .{ .new = new, .old = old, .allocator = ctrl.allocator };
    defer {
        dropWindow(&frame);
        ctrl.snapshot_slots.release(k);
    }

    // The old side's admission pre-check passes, its submission is parked.
    ParkOnceSink.reset();
    ParkOnceSink.install(old);

    var op: [1006]u8 = undefined;
    @memset(&op, 0x44);
    try frame.snap.window.?.write(0x101, &op);
    try testing.expect(old.flush_pending);
    try testing.expect(!old.flush_in_flight);
    try testing.expect(!frame.snap.window.?.quiet());

    pumpWindow(&frame);

    // The retry took the parked submission, which completed synchronously: no
    // completion was owed to the drain.
    try testing.expectEqual(@as(u32, 3), ParkOnceSink.calls);
    try testing.expect(!old.flush_pending);
    try testing.expectEqual(@as(u64, 1), old.flushed_upto);
    try testing.expect(frame.snap.window.?.quiet());
}

test "a reply-triggered drain waits for the committed batch cursor" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(dir);

    var cfg = testConfig(dir, 1, 1, .{ .slots = 2 });
    var ctrl: lifetime.Controller = undefined;
    try ctrl.init(testing.allocator, &cfg);
    defer ctrl.deinit();
    try ctrl.initRing(1, 1);
    defer ctrl.rings[1].deinit();
    try ctrl.initRing(2, 1);
    defer ctrl.rings[2].deinit();

    const logger = try ctrl.getLogger(1);
    defer dropTestLogger(&ctrl, logger);

    var sets = [_]state.IndexState{undefined};
    try ctrl.initIndexState(&sets[0]);
    defer ctrl.deinitIndexState(&sets[0]);

    // A live window and a procedure, exactly as the completion test builds
    // them, but on the real ring so the batch window is exercised.
    const old = try openPairWriter(&ctrl, 0, 0, 0x100);
    old.attachStream(&ctrl.rings[1].sqstream, &ctrl.rings[1].slots);
    const k = try ctrl.snapshot_slots.acquire();
    const new = try adoptWindowWriter(&ctrl, 0, 0, k, 0x100, 0x100);
    new.attachStream(&ctrl.rings[1].sqstream, &ctrl.rings[1].slots);

    const job = try ctrl.mintSnapshotJob(0, 0, 0x100, k, 1);
    defer dropTestJob(&ctrl, job);
    job.fd = -1;
    job.phase = .dump_sent;
    ctrl.snapshot_slots.at(k).* = .{ .status = .in_flight, .job = @intFromPtr(job) };

    var frame = testFrame(&ctrl, 1, logger, &sets);
    frame.snap.procedure = job;
    frame.snap.window = .{ .new = new, .old = old, .allocator = ctrl.allocator };
    try ctrl.publishAdoptionMark(0, 0, k, 0x100);

    // The dump reply lands first: wait for its completion before the window
    // submits anything, so the CQ order is deterministic.
    const slot_idx = try ctrl.cross_slots.acquire();
    ctrl.cross_slots.at(slot_idx).* = .{ .SnapshotDumped = .{} };
    try ctrl.rings[2].ring.pushMsgRingFd(
        ctrl.rings[1].ring.fd,
        messages.CrossTaskMessageIdx,
        slot_idx,
        .{},
    );
    const reply_deadline = zigring.monotonicNs() + 5 * std.time.ns_per_s;
    while (ctrl.rings[1].ring.cq_tail.* -% ctrl.rings[1].ring.cq_head.* == 0) {
        if (zigring.monotonicNs() >= reply_deadline) return error.SnapshotReplyTimeout;
        std.atomic.spinLoopHint();
    }

    // One event through the window, so the CQ now holds
    // [reply, flush-completion].
    var op: [1006]u8 = undefined;
    @memset(&op, 0x66);
    try frame.snap.window.?.write(0x101, &op);
    try testing.expect(old.flush_in_flight and new.flush_in_flight);
    const flush_deadline = zigring.monotonicNs() + 5 * std.time.ns_per_s;
    while (ctrl.rings[1].ring.cq_tail.* -% ctrl.rings[1].ring.cq_head.* < 3) {
        if (zigring.monotonicNs() >= flush_deadline) return error.SnapshotFlushTimeout;
        std.atomic.spinLoopHint();
    }

    var inbox: Inbox = undefined;
    try inbox.init(testing.allocator, 8, &ctrl.rings[1].ring);
    defer inbox.deinit();

    // The batch window consumes the reply but does not publish its cursor yet.
    const before = ctrl.rings[1].ring.cq_head.*;
    const batch = inbox.batch(64, 0) orelse return error.MissingBatch;
    const reply = batch.ring.popCQE() orelse return error.MissingCqe;
    try testing.expectEqual(messages.CrossTaskMessageIdx, reply.taskIdx());
    stepCQE(&frame, reply);
    try batch.ring.commit();

    // The reply armed the continuation and was handled once: the head moved
    // exactly one completion forward, and the swap waits for the pump.
    try testing.expectEqual(before + 1, ctrl.rings[1].ring.cq_head.*);
    try testing.expectEqual(snapshot.Drain.swap, frame.snap.drain.?);
    try testing.expectEqual(lifetime.SnapshotPhase.dump_sent, job.phase);
    try testing.expectEqual(cross_task.SnapshotSlotStatus.in_flight, ctrl.snapshot_slots.at(k).status);
    try testing.expect(!ctrl.rings[2].ring.checkCQNotEmpty());

    // A duplicate completion of the same event is ignored, never re-entered.
    frame.snap.onReply(frame.host(), .{ .SnapshotDumped = .{} });
    try testing.expectEqual(snapshot.Drain.swap, frame.snap.drain.?);
    try testing.expectEqual(lifetime.SnapshotPhase.dump_sent, job.phase);

    // The pump finishes the swap outside the batch: each flush is consumed
    // once and exactly one final close is sent.
    drainPump(&frame);
    try testing.expect(frame.snap.drain == null);
    try testing.expect(frame.snap.window == null);
    try testing.expectEqual(lifetime.SnapshotPhase.close_sent, job.phase);
    // The retired old writer is gone; the surviving one carries the event and
    // the single flush the pump consumed.
    try testing.expectEqual(new, ctrl.wal_writers[0].?);
    try testing.expectEqual(@as(u64, 1), new.flushed_upto);
    try testing.expectEqual(@as(u128, 0x101), new.head);

    const close_cqe = cqeBefore(&ctrl.rings[2].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
        return error.SnapshotDispatchTimeout;
    const close_slot: u32 = @intCast(close_cqe.res);
    try testing.expectEqual(@intFromPtr(job), ctrl.cross_slots.at(close_slot).SnapshotClose.job);
    ctrl.cross_slots.release(close_slot);
    try testing.expect(ctrl.rings[2].ring.popCQE() == null);
}

// ============================================================================
// Startup recovery (§7.1)
// ============================================================================

/// Writes `bytes` into `path`, creating or truncating it.
fn writeFileBytes(path: []const u8, bytes: []const u8) !void {
    const path_z = try std.testing.allocator.dupeSentinel(u8, path, 0);
    defer std.testing.allocator.free(path_z);

    const fd_raw = std.os.linux.open(path_z, .{
        .ACCMODE = .RDWR,
        .CREAT = true,
        .TRUNC = true,
    }, 0o644);
    const errno = std.os.linux.errno(fd_raw);
    if (errno != .SUCCESS) return std.posix.unexpectedErrno(errno);
    const fd: posix.fd_t = @intCast(fd_raw);
    defer _ = std.os.linux.close(fd);

    var done: usize = 0;
    while (done < bytes.len) {
        const res = std.os.linux.write(fd, bytes[done..].ptr, bytes.len - done);
        const write_errno = std.os.linux.errno(res);
        if (write_errno != .SUCCESS) return std.posix.unexpectedErrno(write_errno);
        done += res;
    }
}

/// A controller over a throwaway WAL root and a plain file standing in for the
/// NVDIMM, for the PMEM-shape startup tests.
const StartupPmem = struct {
    tmp: std.testing.TmpDir,
    dir: []u8,
    device: []u8,
    cfg: config.Config,
    ctrl: lifetime.Controller,
    live: bool = false,

    fn init(self: *StartupPmem, hosts: u32) !void {
        const allocator = std.testing.allocator;
        self.tmp = std.testing.tmpDir(.{});
        self.dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{self.tmp.sub_path[0..]});
        errdefer allocator.free(self.dir);
        self.device = try std.fmt.allocPrint(allocator, "{s}/pmem0", .{self.dir});
        errdefer allocator.free(self.device);

        self.cfg = testConfig(self.dir, hosts, 1, .{ .registry_keep = 2 });
        self.cfg.wal = .{ .pmem = .{
            .dir = self.dir,
            .device = self.device,
            .buffers = 8,
            .lba = config.kib(1),
            .hosts = hosts,
        } };

        const pairs = @as(usize, self.cfg.indexes) * self.cfg.wal.hosts();
        const areas = pairs + self.cfg.snapshots.slots;
        const stride = wal.areaStride(self.cfg.wal.buffers(), self.cfg.wal.lba(), std.heap.pageSize());
        const needed = areas * stride;

        const path = try allocator.dupeSentinel(u8, self.device, 0);
        defer allocator.free(path);
        const fd_raw = std.os.linux.open(path, .{ .ACCMODE = .RDWR, .CREAT = true }, 0o644);
        if (std.os.linux.errno(fd_raw) != .SUCCESS) return error.TestUnexpectedResult;
        const fd: posix.fd_t = @intCast(fd_raw);
        defer _ = std.os.linux.close(fd);
        if (std.os.linux.errno(std.os.linux.ftruncate(fd, @intCast(needed))) != .SUCCESS) {
            return error.TestUnexpectedResult;
        }

        try self.openCtrl();
    }

    fn openCtrl(self: *StartupPmem) !void {
        try self.ctrl.init(std.testing.allocator, &self.cfg);
        try self.ctrl.compensators.put("marker", .{ .bind = "10.0.0.1", .port = 20301 });
        self.live = true;
    }

    fn reopen(self: *StartupPmem) !void {
        self.ctrl.deinit();
        self.live = false;
        try self.openCtrl();
    }

    fn deinit(self: *StartupPmem) void {
        if (self.live) self.ctrl.deinit();
        std.testing.allocator.free(self.dir);
        std.testing.allocator.free(self.device);
        self.tmp.cleanup();
    }
};

// ============================================================================
// Stage J: the end-to-end gate and the PMEM-shape crash matrix
// ============================================================================

/// Steps the thread's own completions until `writer` has no flush in flight and
/// none parked: the standalone pair writer's version of the window drain.
fn drainWriterQuiet(frame: *Frame, writer: *wal.WalWriteFile) void {
    while (writer.flush_in_flight or writer.flush_pending) {
        if (writer.flush_pending and !writer.flush_in_flight) writer.driveFlush();
        if (frame.ring.ring.popCQE()) |cqe| {
            stepCQE(frame, cqe);
            continue;
        }
        frame.ring.ring.park();
    }
}

fn fileExists(path: [:0]const u8) bool {
    const fd_raw = std.os.linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (std.os.linux.errno(fd_raw) != .SUCCESS) return false;
    _ = std.os.linux.close(@intCast(fd_raw));
    return true;
}

/// Asserts `actual` carries exactly the sessions `expected` does, field by
/// field: the shape the snapshot-equality assertion needs.
fn expectSameSessions(expected: *state.IndexState, actual: *state.IndexState) !void {
    try std.testing.expectEqual(expected.sessions.count(), actual.sessions.count());
    var it = expected.sessions.iterator();
    while (it.next()) |bucket| {
        const want = bucket.val;
        const got = actual.sessions.get(bucket.key) orelse return error.MissingSession;
        try std.testing.expectEqual(want.data.original_id, got.data.original_id);
        try std.testing.expectEqual(want.data.retry_count, got.data.retry_count);
        try std.testing.expectEqualStrings(want.data.compensator, got.data.compensator);
        try std.testing.expectEqualSlices(
            u8,
            want.data.data.backing[0..want.data.data.len],
            got.data.data.backing[0..got.data.data.len],
        );
    }
}

test "the end-to-end plain-mode procedure commits, swaps and replays" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(dir);

    // The barrier is 1 MiB, so the two large records below fire the tick; the
    // interval is irrelevant because the test calls `tickPass` directly.
    var cfg = testConfig(dir, 1, 1, .{ .size_barrier = config.mib(1), .interval = config.seconds(3600), .slots = 2, .registry_keep = 8 });
    cfg.wal = .{ .plain = .{ .dir = dir, .buffers = 2048, .hosts = 1, .lba = config.kib(1) } };
    const states = [_]u128{ 0x101, 0x102, 0x103, 0x104, 0x105 };
    const old_tag: u128 = 0x100;
    const elephant_ring: u16 = cfg.fronts + cfg.indexes;

    // 19 framing bytes plus a 600 KiB payload fills exactly 600 one-KiB
    // buffers, so the record ends on a buffer boundary and is durable at once.
    const big_op_len: usize = 600 * 1024 - 19;
    const op = try allocator.alloc(u8, big_op_len);
    defer allocator.free(op);
    for (op, 0..) |*byte, i| byte.* = @truncate(i *% 17 +% 1);

    var saved_wal: ?[:0]u8 = null;
    var saved_snapshot: ?[:0]u8 = null;
    var saved_old: ?[:0]u8 = null;
    defer if (saved_wal) |path| allocator.free(path);
    defer if (saved_snapshot) |path| allocator.free(path);
    defer if (saved_old) |path| allocator.free(path);
    var saved_k: u32 = 0;

    {
        var ctrl: lifetime.Controller = undefined;
        try ctrl.init(allocator, &cfg);
        defer ctrl.deinit();
        try ctrl.compensators.put("marker", .{ .bind = "10.0.0.1", .port = 20301 });

        try ctrl.initRing(1, 1);
        defer ctrl.rings[1].deinit();
        try ctrl.initRing(elephant_ring, 1);
        defer ctrl.rings[elephant_ring].deinit();

        const logger = try ctrl.getLogger(1);
        defer dropTestLogger(&ctrl, logger);

        var el = snapshot.Elephant{ .ctrl = &ctrl, .log = &logger.logger, .ring_idx = elephant_ring };

        var sets = [_]state.IndexState{undefined};
        try ctrl.initIndexState(&sets[0]);
        defer ctrl.deinitIndexState(&sets[0]);

        // The pre-procedure pair: a WAL under an earlier tag, serving through
        // the index's own ring, exactly as the loop wires it.
        const pair = try openPairWriter(&ctrl, 0, 0, old_tag);
        pair.attachStream(&ctrl.rings[1].sqstream, &ctrl.rings[1].slots);

        var frame = testFrame(&ctrl, 1, logger, &sets);
        const slots_full = ctrl.snapshot_slots.freeCount();

        // Two records before the tick; drain each so the next one has buffers.
        var i: usize = 0;
        while (i < 2) : (i += 1) {
            try pair.write(states[i], pair.head, op);
            sets[0].state = states[i];
            try ctrl.applyIndexOp(&sets[0], .{ .create = .{ .compensator = "marker", .payload = op } });
            drainWriterQuiet(&frame, pair);
        }
        try testing.expectEqual(@as(u128, states[1]), sets[0].state);

        // The tick: the pair is over the barrier and its state is the tag X.
        frame.snap.onTick(frame.host());
        const job = frame.snap.procedure orelse return error.SnapshotNotStarted;
        var job_live = true;
        defer if (job_live) dropTestJob(&ctrl, job);
        try testing.expectEqual(@as(u128, states[1]), job.tag);

        // The pair keeps serving between the tick and the create reply: the
        // clone state Y is ahead of the name tag X.
        try pair.write(states[2], pair.head, op);
        sets[0].state = states[2];
        try ctrl.applyIndexOp(&sets[0], .{ .create = .{ .compensator = "marker", .payload = op } });
        drainWriterQuiet(&frame, pair);

        // F1, the real handler: the create request's slot is released on read.
        const create_cqe = cqeBefore(&ctrl.rings[elephant_ring].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
            return error.SnapshotDispatchTimeout;
        try testing.expectEqual(messages.CrossTaskMessageIdx, create_cqe.taskIdx());
        const create_slot: u32 = @intCast(create_cqe.res);
        try testing.expectEqual(@intFromPtr(job), ctrl.cross_slots.at(create_slot).SnapshotCreate.job);
        ctrl.cross_slots.release(create_slot);
        el.createSnapshot(job);
        saved_wal = try allocator.dupeSentinel(u8, job.wal_path, 0);
        saved_snapshot = try allocator.dupeSentinel(u8, job.snapshot_path, 0);
        saved_k = job.k;

        // The fd reply lands on the index ring; the ordinary dispatch runs the
        // handler pass: mark, clone, adopt, composite, dump dispatch.
        const fd_cqe = cqeBefore(&ctrl.rings[1].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
            return error.SnapshotReplyTimeout;
        stepCQE(&frame, fd_cqe);
        const window = &(frame.snap.window orelse return error.SnapshotWindowMissing);
        try testing.expectEqual(@as(u128, states[2]), job.clone.state);

        // One window event: new first, then old, both through the ring.
        try window.write(states[3], op);
        pumpWindow(&frame);
        try testing.expect(window.quiet());
        try testing.expectEqual(@as(u128, states[3]), window.new.head);
        try testing.expectEqual(@as(u128, states[3]), window.old.head);

        // F2, the real handler: the dump, the registry commit and the reply.
        const dump_cqe = cqeBefore(&ctrl.rings[elephant_ring].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
            return error.SnapshotDispatchTimeout;
        const dump_slot: u32 = @intCast(dump_cqe.res);
        try testing.expectEqual(@intFromPtr(job), ctrl.cross_slots.at(dump_slot).SnapshotDump.job);
        ctrl.cross_slots.release(dump_slot);
        el.dumpSnapshot(job);

        // The completion: the drain, the copy, the clear, the revival and the
        // close dispatch.
        const dumped_cqe = cqeBefore(&ctrl.rings[1].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
            return error.SnapshotReplyTimeout;
        stepCQE(&frame, dumped_cqe);
        pumpWindow(&frame);
        try testing.expect(frame.snap.window == null);
        try testing.expectEqual(lifetime.SnapshotPhase.close_sent, job.phase);

        // F3, the real handler: the old fd's close and the terminal reply.
        const close_cqe = cqeBefore(&ctrl.rings[elephant_ring].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
            return error.SnapshotDispatchTimeout;
        const close_slot: u32 = @intCast(close_cqe.res);
        try testing.expectEqual(@intFromPtr(job), ctrl.cross_slots.at(close_slot).SnapshotClose.job);
        ctrl.cross_slots.release(close_slot);
        el.closeSnapshot(job);
        job_live = false;

        const done_cqe = cqeBefore(&ctrl.rings[1].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
            return error.SnapshotReplyTimeout;
        stepCQE(&frame, done_cqe);
        try testing.expect(frame.snap.procedure == null);

        // The registry holds exactly one line: the new WAL and snapshot, with
        // the clone state Y.
        const entries = (try ctrl.loadRegistry(0)) orelse return error.RegistryMissing;
        defer ctrl.freeRegistry(entries);
        try testing.expectEqual(@as(usize, 1), entries.len);
        try testing.expectEqual(@as(u128, states[2]), entries[0].state);
        try testing.expectEqualStrings(saved_wal.?, entries[0].wal_path);
        try testing.expectEqualStrings(saved_snapshot.?, entries[0].snapshot_path);

        // The old WAL still exists on disk, but no line names it.
        const index_dir = try ctrl.indexDirPath(0);
        defer allocator.free(index_dir);
        saved_old = try wal.walPath(allocator, index_dir, 0, 0, old_tag);
        try testing.expect(fileExists(saved_old.?));
        try testing.expect(!std.mem.eql(u8, saved_old.?, entries[0].wal_path));

        // The snapshot loads and equals the pair at clone time: the three
        // sessions written before the window's event.
        const snapshot_bytes = try readFileBytes(allocator, saved_snapshot.?);
        defer allocator.free(snapshot_bytes);
        var loaded = try ctrl.loadIndexState(snapshot_bytes);
        defer ctrl.deinitIndexState(&loaded);
        try testing.expectEqual(@as(u128, 0), loaded.state);
        try expectSameSessions(&sets[0], &loaded);

        // The surviving writer is the pair area's, not temp ring k's: the ring
        // is dead to the thread.
        const pair_idx = wal.areaIndex(0, 0, cfg.wal.hosts());
        const pair_bytes = ctrl.wal_battery.?[pair_idx * ctrl.wal_area_stride ..][0..ctrl.wal_area_stride];
        const temp_start = wal.tempAreaIdx(saved_k, ctrl.wal_pairs) * ctrl.wal_area_stride;
        const temp_bytes = ctrl.wal_battery.?[temp_start..][0..ctrl.wal_area_stride];
        const registered = ctrl.wal_writers[pair_idx].?;
        try testing.expectEqual(@intFromPtr(pair_bytes.ptr), @intFromPtr(registered.data.ptr));
        try testing.expect(@intFromPtr(registered.data.ptr) != @intFromPtr(temp_bytes.ptr));

        // The new writer serves further writes: the floor chains from the
        // window's head.
        try registered.write(states[4], registered.head, op);
        drainWriterQuiet(&frame, registered);
        try testing.expectEqual(@as(u128, states[4]), registered.head);

        // The procedure is over to its true end: the flag is clear and the
        // slot is back in the pool.
        try testing.expectEqual(slots_full, ctrl.snapshot_slots.freeCount());
    }

    // The restart: a fresh Controller over the same files replays the WAL over
    // the snapshot and reconstructs every session the procedure wrote.
    {
        var ctrl: lifetime.Controller = undefined;
        try ctrl.init(allocator, &cfg);
        defer ctrl.deinit();
        try ctrl.compensators.put("marker", .{ .bind = "10.0.0.1", .port = 20301 });

        try ctrl.initRing(1, 1);
        defer ctrl.rings[1].deinit();
        const logger = try ctrl.getLogger(1);
        defer dropTestLogger(&ctrl, logger);

        var st: state.IndexState = undefined;
        try ctrl.initIndexState(&st);
        defer ctrl.deinitIndexState(&st);

        try snapshot.recoverPair(&ctrl, &ctrl.rings[1], &logger.logger, 0, 0, &st);

        try testing.expectEqual(@as(u128, states[4]), st.state);
        try testing.expectEqual(@as(usize, 5), st.sessions.count());
        for (states) |state_idx| {
            try testing.expect(st.sessions.get(state_idx) != null);
        }
    }
}

/// One 494-byte op frames to exactly one 512-byte buffer, so every record the
/// J2 chains write fills and flushes immediately.
const j2_op_len: usize = 494;

fn j2Op(state_idx: u128) [j2_op_len]u8 {
    var op: [j2_op_len]u8 = undefined;
    const seed: usize = @truncate(state_idx);
    for (&op, 0..) |*byte, i| byte.* = @truncate(i *% 13 +% seed *% 7 +% 3);
    return op;
}

/// A synchronous sink that also writes the buffer into the file, the way a
/// PMEM flush's `RWF.DSYNC` `pwrite` does; `flushComplete` then publishes the
/// resume terminator into the battery.
const J2FileSink = struct {
    fn room(ctx: ?*anyopaque, writer: *wal.WalWriteFile) wal.WalError!void {
        _ = ctx;
        _ = writer;
    }

    fn submit(ctx: ?*anyopaque, writer: *wal.WalWriteFile, ordinal: u64) void {
        _ = ctx;
        const data = writer.bufferData(ordinal);
        const base: posix.off_t = @intCast(ordinal * @as(u64, writer.lba));
        var done: usize = 0;
        while (done < data.len) {
            const res = std.os.linux.pwrite(writer.fd, data[done..].ptr, data.len - done, base + @as(posix.off_t, @intCast(done)));
            const errno = std.os.linux.errno(res);
            if (errno != .SUCCESS) {
                writer.fault(errno);
                return;
            }
            done += res;
        }
        writer.flushComplete(ordinal);
    }

    fn install(writer: *wal.WalWriteFile) void {
        writer.sink = .{ .room = room, .submit = submit };
    }
};

fn j2Area(ctrl: *lifetime.Controller, area_idx: usize) wal.Area {
    const start = area_idx * ctrl.wal_area_stride;
    return wal.Area.init(
        ctrl.wal_battery.?[start..][0..ctrl.wal_area_stride],
        ctrl.cfg.wal.buffers(),
        ctrl.cfg.wal.lba(),
    );
}

/// Writes a chain into battery area `area_idx` and into the WAL file named
/// `file_tag`: records `from..=to`, chained from `start_floor`. The writer is
/// a plain local, never registered on the controller.
fn writeJ2Chain(
    ctrl: *lifetime.Controller,
    host: u8,
    index: u16,
    area_idx: usize,
    file_tag: u128,
    start_floor: u128,
    from: u128,
    to: u128,
) !u128 {
    try ctrl.ensureIndexDir(index);
    const dir = try ctrl.indexDirPath(index);
    defer ctrl.allocator.free(dir);
    const path = try wal.walPath(ctrl.allocator, dir, host, index, file_tag);
    defer ctrl.allocator.free(path);

    const fd = try createWalFile(path);
    var writer = wal.WalWriteFile.init(fd, j2Area(ctrl, area_idx), ctrl.cfg.wal, host, index, start_floor);
    J2FileSink.install(&writer);

    var s = from;
    while (s <= to) : (s += 1) {
        var op = j2Op(s);
        try writer.write(s, writer.head, &op);
    }
    const head = writer.head;
    _ = std.os.linux.close(fd);
    return head;
}

/// Builds a data set by applying one `create` per state, in order.
fn j2State(ctrl: *lifetime.Controller, states: []const u128) !state.IndexState {
    var st: state.IndexState = undefined;
    try ctrl.initIndexState(&st);
    errdefer ctrl.deinitIndexState(&st);
    for (states) |s| {
        st.state = s;
        var op = j2Op(s);
        try ctrl.applyIndexOp(&st, .{ .create = .{ .compensator = "marker", .payload = &op } });
    }
    return st;
}

/// Dumps the sessions of `states` under `snapshot.<host>.<index>.<tag>`.
fn writeJ2Snapshot(
    ctrl: *lifetime.Controller,
    host: u8,
    index: u16,
    tag: u128,
    states: []const u128,
) !void {
    var st = try j2State(ctrl, states);
    defer ctrl.deinitIndexState(&st);

    var dump: std.ArrayList(u8) = .empty;
    defer dump.deinit(ctrl.allocator);
    try ctrl.dumpIndexState(&st, &dump);

    const dir = try ctrl.indexDirPath(index);
    defer ctrl.allocator.free(dir);
    const path = try wal.snapshotPath(ctrl.allocator, dir, host, index, tag);
    defer ctrl.allocator.free(path);
    try writeFileBytes(path, dump.items);
}

const J2Row = enum { create_to_mark, mark_to_commit, commit_to_copy, mid_copy, copy_to_clear, post_swap };

/// One crash-table row, built as files plus battery state and then driven
/// through the **full** startup sequence, not only the adoption rule.
fn runJ2Row(row: J2Row) !void {
    const allocator = std.testing.allocator;

    var f: StartupPmem = undefined;
    try f.init(1);
    defer f.deinit();

    const host: u8 = 0;
    const index: u16 = 0;
    const k: u32 = 0;
    const old_tag: u128 = 0x10;
    const x: u128 = 0x14;
    const all_states = [_]u128{ 0x11, 0x12, 0x13, 0x14, 0x15, 0x16 };
    const clone_states = [_]u128{ 0x11, 0x12, 0x13, 0x14 };
    const tail_states = [_]u128{ 0x15, 0x16 };
    const pair_idx = wal.areaIndex(host, index, 1);

    try f.ctrl.ensureIndexDir(index);
    try f.ctrl.acquireWalBattery();

    // The old pair: an empty snapshot at its own tag and a WAL that holds the
    // whole history. The registry state is the snapshot's state, the tag.
    try writeJ2Snapshot(&f.ctrl, host, index, old_tag, &.{});
    _ = try writeJ2Chain(&f.ctrl, host, index, pair_idx, old_tag, old_tag, all_states[0], all_states[all_states.len - 1]);

    if (row == .create_to_mark) {
        // The create reply arrived; the handler pass never did, so there is no
        // temp chain: only the empty new file.
        const dir = try f.ctrl.indexDirPath(index);
        defer allocator.free(dir);
        const path = try wal.walPath(allocator, dir, host, index, x);
        defer allocator.free(path);
        const created = try createWalFile(path);
        _ = std.os.linux.close(created);
    } else {
        // The clone's snapshot and the window's chain on temp ring k.
        try writeJ2Snapshot(&f.ctrl, host, index, x, &clone_states);
        const temp_idx = wal.tempAreaIdx(k, f.ctrl.wal_pairs);
        _ = try writeJ2Chain(&f.ctrl, host, index, temp_idx, x, x, tail_states[0], tail_states[1]);
    }

    // The pair area's state at the crash.
    const pair = j2Area(&f.ctrl, pair_idx);
    const temp = j2Area(&f.ctrl, wal.tempAreaIdx(k, f.ctrl.wal_pairs));
    switch (row) {
        // The old chain is the pair area's from the chain write above.
        .create_to_mark, .mark_to_commit, .commit_to_copy => {},
        .mid_copy => {
            // The copy started and tore: half of the data array and the first
            // two header lines.
            const half = pair.data.len / 2;
            @memcpy(pair.data[0..half], temp.data[0..half]);
            @memcpy(
                std.mem.sliceAsBytes(pair.headers[0..2]),
                std.mem.sliceAsBytes(temp.headers[0..2]),
            );
        },
        .copy_to_clear, .post_swap => {
            @memcpy(pair.data, temp.data);
            @memcpy(std.mem.sliceAsBytes(pair.headers), std.mem.sliceAsBytes(temp.headers));
        },
    }

    // The mark, when the handler pass had published it.
    switch (row) {
        .create_to_mark, .post_swap => {},
        else => try f.ctrl.publishAdoptionMark(host, index, k, x),
    }

    // The registry: the old line wins until the dump's rewrite commits.
    const old_dir = try f.ctrl.indexDirPath(index);
    defer allocator.free(old_dir);
    const old_snapshot = try wal.snapshotPath(allocator, old_dir, host, index, old_tag);
    defer allocator.free(old_snapshot);
    const old_wal = try wal.walPath(allocator, old_dir, host, index, old_tag);
    defer allocator.free(old_wal);
    const new_snapshot = try wal.snapshotPath(allocator, old_dir, host, index, x);
    defer allocator.free(new_snapshot);
    const new_wal = try wal.walPath(allocator, old_dir, host, index, x);
    defer allocator.free(new_wal);
    switch (row) {
        .create_to_mark, .mark_to_commit => try f.ctrl.rewriteRegistry(index, .{
            .host_idx = host,
            .snapshot_path = old_snapshot,
            .wal_path = old_wal,
            .state = old_tag,
        }),
        else => try f.ctrl.rewriteRegistry(index, .{
            .host_idx = host,
            .snapshot_path = new_snapshot,
            .wal_path = new_wal,
            .state = x,
        }),
    }

    // The crash and the full startup sequence: adoption rule, registry,
    // snapshot, writer, (bring-tail) and replay.
    try f.reopen();

    const ring_idx: u16 = f.cfg.fronts;
    try f.ctrl.initRing(ring_idx, 1);
    defer f.ctrl.rings[ring_idx].deinit();
    const logger = try f.ctrl.getLogger(ring_idx);
    defer dropTestLogger(&f.ctrl, logger);

    var st: state.IndexState = undefined;
    try f.ctrl.initIndexState(&st);
    defer f.ctrl.deinitIndexState(&st);

    try snapshot.recoverPair(&f.ctrl, &f.ctrl.rings[ring_idx], &logger.logger, index, host, &st);

    // Every row converges on the same recovered state: the same sessions and
    // the same walked head, by whichever branch.
    try std.testing.expectEqual(@as(u128, all_states[all_states.len - 1]), st.state);
    try std.testing.expectEqual(all_states.len, st.sessions.count());
    var reference = try j2State(&f.ctrl, &all_states);
    defer f.ctrl.deinitIndexState(&reference);
    try expectSameSessions(&reference, &st);

    // The mark is gone and the pair's writer resumes from the recovered head.
    try std.testing.expectEqual(@as(u8, 0), pairControlLine(&f.ctrl).snapshot_in_progress);
    try std.testing.expectEqual(@as(u128, all_states[all_states.len - 1]), f.ctrl.wal_writers[pair_idx].?.head);

    // The winning line is the old one before the commit and the new one after.
    const entries = (try f.ctrl.loadRegistry(index)).?;
    defer f.ctrl.freeRegistry(entries);
    const winner = lifetime.Controller.lastLineFor(entries, host).?;
    const expected_tag: u128 = switch (row) {
        .create_to_mark, .mark_to_commit => old_tag,
        else => x,
    };
    try std.testing.expectEqual(expected_tag, wal.walTagFromPath(winner.wal_path).?);
    try std.testing.expectEqual(expected_tag, winner.state);
}

test "the six crash-table rows all recover through the full startup sequence" {
    const rows = [_]J2Row{
        .create_to_mark,
        .mark_to_commit,
        .commit_to_copy,
        .mid_copy,
        .copy_to_clear,
        .post_swap,
    };
    for (rows) |row| try runJ2Row(row);
}

test "startup's bring-tail recovers the inter-write cut's surplus record" {
    const allocator = std.testing.allocator;

    var f: StartupPmem = undefined;
    try f.init(1);
    defer f.deinit();

    const host: u8 = 0;
    const index: u16 = 0;
    const k: u32 = 0;
    const old_tag: u128 = 0x10;
    const x: u128 = 0x14;
    const old_states = [_]u128{ 0x11, 0x12, 0x13, 0x14, 0x15, 0x16 };
    const clone_states = [_]u128{ 0x11, 0x12, 0x13, 0x14 };
    const pair_idx = wal.areaIndex(host, index, 1);

    try f.ctrl.ensureIndexDir(index);
    try f.ctrl.acquireWalBattery();

    try writeJ2Snapshot(&f.ctrl, host, index, old_tag, &.{});
    _ = try writeJ2Chain(&f.ctrl, host, index, pair_idx, old_tag, old_tag, old_states[0], old_states[old_states.len - 1]);
    try writeJ2Snapshot(&f.ctrl, host, index, x, &clone_states);

    // The cut: the new side holds one record the old side never got.
    const temp_idx = wal.tempAreaIdx(k, f.ctrl.wal_pairs);
    _ = try writeJ2Chain(&f.ctrl, host, index, temp_idx, x, x, 0x15, 0x17);
    try f.ctrl.publishAdoptionMark(host, index, k, x);

    const dir = try f.ctrl.indexDirPath(index);
    defer allocator.free(dir);
    const old_snapshot = try wal.snapshotPath(allocator, dir, host, index, old_tag);
    defer allocator.free(old_snapshot);
    const old_wal = try wal.walPath(allocator, dir, host, index, old_tag);
    defer allocator.free(old_wal);
    try f.ctrl.rewriteRegistry(index, .{
        .host_idx = host,
        .snapshot_path = old_snapshot,
        .wal_path = old_wal,
        .state = old_tag,
    });

    try f.reopen();

    const ring_idx: u16 = f.cfg.fronts;
    try f.ctrl.initRing(ring_idx, 1);
    defer f.ctrl.rings[ring_idx].deinit();
    const logger = try f.ctrl.getLogger(ring_idx);
    defer dropTestLogger(&f.ctrl, logger);

    var st: state.IndexState = undefined;
    try f.ctrl.initIndexState(&st);
    defer f.ctrl.deinitIndexState(&st);

    try snapshot.recoverPair(&f.ctrl, &f.ctrl.rings[ring_idx], &logger.logger, index, host, &st);

    // The surplus is home: the old chain replays it, once, after the abort.
    try std.testing.expectEqual(@as(u128, 0x17), st.state);
    try std.testing.expectEqual(@as(usize, 7), st.sessions.count());
    var reference = try j2State(&f.ctrl, &.{ 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17 });
    defer f.ctrl.deinitIndexState(&reference);
    try expectSameSessions(&reference, &st);
    try std.testing.expectEqual(@as(u128, 0x17), f.ctrl.wal_writers[pair_idx].?.head);
}

test "the freeze ladder drains the window, revives at the swap and stops on relapse" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(dir);

    var cfg = testConfig(dir, 1, 1, .{ .slots = 2 });
    var ctrl: lifetime.Controller = undefined;
    try ctrl.init(testing.allocator, &cfg);
    defer ctrl.deinit();
    try ctrl.initRing(1, 1);
    defer ctrl.rings[1].deinit();
    try ctrl.initRing(2, 1);
    defer ctrl.rings[2].deinit();

    const logger = try ctrl.getLogger(1);
    defer dropTestLogger(&ctrl, logger);

    var sets = [_]state.IndexState{undefined};
    try ctrl.initIndexState(&sets[0]);
    defer ctrl.deinitIndexState(&sets[0]);

    // Both sides flush through the real ring: the drain has real completions
    // to step, not synchronous no-ops.
    const old = try openPairWriter(&ctrl, 0, 0, 0x100);
    old.attachStream(&ctrl.rings[1].sqstream, &ctrl.rings[1].slots);
    const k = try ctrl.snapshot_slots.acquire();
    const new = try adoptWindowWriter(&ctrl, 0, 0, k, 0x100, 0x100);
    new.attachStream(&ctrl.rings[1].sqstream, &ctrl.rings[1].slots);

    const job = try ctrl.mintSnapshotJob(0, 0, 0x100, k, 1);
    var job_live = true;
    defer if (job_live) dropTestJob(&ctrl, job);
    job.fd = -1;
    ctrl.snapshot_slots.at(k).* = .{ .status = .in_flight, .job = @intFromPtr(job) };

    var frame = testFrame(&ctrl, 1, logger, &sets);
    frame.snap.procedure = job;
    frame.snap.window = .{ .new = new, .old = old, .allocator = ctrl.allocator };
    try ctrl.publishAdoptionMark(0, 0, k, 0x100);

    var op: [1006]u8 = undefined;
    for (&op, 0..) |*byte, i| byte.* = @truncate(i *% 17 +% 1);
    try frame.snap.window.?.write(0x101, &op);
    try testing.expect(old.flush_in_flight and new.flush_in_flight);

    // The old side faults mid-window: the front freezes, the window serves on.
    old.faulted = true;
    frame.snap.onWriterFault(frame.host(), old);
    try testing.expectEqual(snapshot.Serve.frozen, frame.snap.serve);

    // The completion pass's bounded drain steps the real flushes before the
    // copy; the swap retires the faulted writer and revives the front.
    frame.snap.onReply(frame.host(), .{ .SnapshotDumped = .{} });
    pumpWindow(&frame);
    try testing.expect(frame.snap.window == null);
    try testing.expectEqual(snapshot.Serve.serving, frame.snap.serve);
    try testing.expectEqual(lifetime.SnapshotPhase.close_sent, job.phase);

    var el = snapshot.Elephant{ .ctrl = &ctrl, .log = &logger.logger, .ring_idx = 2 };
    const close_cqe = cqeBefore(&ctrl.rings[2].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
        return error.SnapshotDispatchTimeout;
    const close_slot: u32 = @intCast(close_cqe.res);
    try testing.expectEqual(@intFromPtr(job), ctrl.cross_slots.at(close_slot).SnapshotClose.job);
    ctrl.cross_slots.release(close_slot);
    el.closeSnapshot(job);
    job_live = false;

    const done_cqe = cqeBefore(&ctrl.rings[1].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
        return error.SnapshotReplyTimeout;
    stepCQE(&frame, done_cqe);
    try testing.expect(frame.snap.procedure == null);

    // A relapse after the swap finds no window and stops terminally.
    const live = ctrl.wal_writers[0].?;
    live.faulted = true;
    frame.snap.onWriterFault(frame.host(), live);
    try testing.expectEqual(snapshot.Serve.stopped, frame.snap.serve);
}

test "a stop mid-window completes the procedure on the control plane" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(dir);

    var cfg = testConfig(dir, 1, 1, .{ .slots = 2 });
    var ctrl: lifetime.Controller = undefined;
    try ctrl.init(testing.allocator, &cfg);
    defer ctrl.deinit();
    try ctrl.initRing(1, 1);
    defer ctrl.rings[1].deinit();
    try ctrl.initRing(2, 1);
    defer ctrl.rings[2].deinit();

    const logger = try ctrl.getLogger(1);
    defer dropTestLogger(&ctrl, logger);

    var sets = [_]state.IndexState{undefined};
    try ctrl.initIndexState(&sets[0]);
    defer ctrl.deinitIndexState(&sets[0]);

    const old = try openPairWriter(&ctrl, 0, 0, 0x100);
    old.attachStream(&ctrl.rings[1].sqstream, &ctrl.rings[1].slots);
    const k = try ctrl.snapshot_slots.acquire();
    const new = try adoptWindowWriter(&ctrl, 0, 0, k, 0x100, 0x100);
    new.attachStream(&ctrl.rings[1].sqstream, &ctrl.rings[1].slots);

    const job = try ctrl.mintSnapshotJob(0, 0, 0x100, k, 1);
    var job_live = true;
    defer if (job_live) dropTestJob(&ctrl, job);
    job.fd = -1;
    ctrl.snapshot_slots.at(k).* = .{ .status = .in_flight, .job = @intFromPtr(job) };

    var frame = testFrame(&ctrl, 1, logger, &sets);
    frame.snap.procedure = job;
    frame.snap.window = .{ .new = new, .old = old, .allocator = ctrl.allocator };
    try ctrl.publishAdoptionMark(0, 0, k, 0x100);

    var op = j2Op(0x101);
    try frame.snap.window.?.write(0x101, &op);

    // A new-side flush fault is the ordinary terminal stop; ticks skip the
    // thread, but the procedure still completes on the control plane (rung 10).
    new.faulted = true;
    frame.snap.onWriterFault(frame.host(), new);
    try testing.expectEqual(snapshot.Serve.stopped, frame.snap.serve);

    frame.snap.onReply(frame.host(), .{ .SnapshotDumped = .{} });
    pumpWindow(&frame);
    try testing.expect(frame.snap.window == null);
    try testing.expectEqual(lifetime.SnapshotPhase.close_sent, job.phase);

    // The final close lands and the terminal reply clears the flag. The stop
    // stands: no swap revives a stopped thread.
    var el = snapshot.Elephant{ .ctrl = &ctrl, .log = &logger.logger, .ring_idx = 2 };
    const close_cqe = cqeBefore(&ctrl.rings[2].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
        return error.SnapshotDispatchTimeout;
    ctrl.cross_slots.release(@intCast(close_cqe.res));
    el.closeSnapshot(job);
    job_live = false;

    const done_cqe = cqeBefore(&ctrl.rings[1].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
        return error.SnapshotReplyTimeout;
    stepCQE(&frame, done_cqe);
    try testing.expect(frame.snap.procedure == null);
    try testing.expectEqual(snapshot.Serve.stopped, frame.snap.serve);
}

test "a failed registry rename leaves the old line winning and recovery-correct" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(dir);

    var cfg = testConfig(dir, 1, 1, .{ .size_barrier = config.mib(1), .interval = config.seconds(3600), .slots = 2, .registry_keep = 8 });
    cfg.wal = .{ .plain = .{ .dir = dir, .buffers = 2048, .hosts = 1, .lba = config.kib(1) } };
    const old_tag: u128 = 0x100;
    const states = [_]u128{ 0x101, 0x102, 0x103, 0x104 };
    const elephant_ring: u16 = cfg.fronts + cfg.indexes;

    // 19 framing bytes plus a 600 KiB payload fills exactly 600 one-KiB
    // buffers, so the record ends on a buffer boundary and is durable at once.
    const big_op_len: usize = 600 * 1024 - 19;
    const op = try allocator.alloc(u8, big_op_len);
    defer allocator.free(op);
    for (op, 0..) |*byte, i| byte.* = @truncate(i *% 13 +% 3);

    var old_wal_path: ?[:0]u8 = null;
    var fixed_registry: ?[]u8 = null;
    defer if (old_wal_path) |path| allocator.free(path);
    defer if (fixed_registry) |bytes| allocator.free(bytes);

    {
        var ctrl: lifetime.Controller = undefined;
        try ctrl.init(allocator, &cfg);
        defer ctrl.deinit();
        try ctrl.compensators.put("marker", .{ .bind = "10.0.0.1", .port = 20301 });

        try ctrl.initRing(1, 1);
        defer ctrl.rings[1].deinit();
        try ctrl.initRing(elephant_ring, 1);
        defer ctrl.rings[elephant_ring].deinit();

        const logger = try ctrl.getLogger(1);
        defer dropTestLogger(&ctrl, logger);

        var el = snapshot.Elephant{ .ctrl = &ctrl, .log = &logger.logger, .ring_idx = elephant_ring };

        var sets = [_]state.IndexState{undefined};
        try ctrl.initIndexState(&sets[0]);
        defer ctrl.deinitIndexState(&sets[0]);

        const pair = try openPairWriter(&ctrl, 0, 0, old_tag);
        pair.attachStream(&ctrl.rings[1].sqstream, &ctrl.rings[1].slots);

        // A prior committed line names the old pair.
        const index_dir = try ctrl.indexDirPath(0);
        defer allocator.free(index_dir);
        const old_snapshot = try wal.snapshotPath(allocator, index_dir, 0, 0, old_tag);
        defer allocator.free(old_snapshot);
        old_wal_path = try wal.walPath(allocator, index_dir, 0, 0, old_tag);
        try writeJ2Snapshot(&ctrl, 0, 0, old_tag, &.{});
        try ctrl.rewriteRegistry(0, .{
            .host_idx = 0,
            .snapshot_path = old_snapshot,
            .wal_path = old_wal_path.?,
            .state = old_tag,
        });
        const registry_path = try ctrl.registryPath(0);
        defer allocator.free(registry_path);
        fixed_registry = try readFileBytes(allocator, registry_path);

        var frame = testFrame(&ctrl, 1, logger, &sets);

        var i: usize = 0;
        while (i < 2) : (i += 1) {
            try pair.write(states[i], pair.head, op);
            sets[0].state = states[i];
            try ctrl.applyIndexOp(&sets[0], .{ .create = .{ .compensator = "marker", .payload = op } });
            drainWriterQuiet(&frame, pair);
        }

        frame.snap.onTick(frame.host());
        const job = frame.snap.procedure orelse return error.SnapshotNotStarted;
        var job_live = true;
        defer if (job_live) dropTestJob(&ctrl, job);

        try pair.write(states[2], pair.head, op);
        sets[0].state = states[2];
        try ctrl.applyIndexOp(&sets[0], .{ .create = .{ .compensator = "marker", .payload = op } });
        drainWriterQuiet(&frame, pair);

        const create_cqe = cqeBefore(&ctrl.rings[elephant_ring].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
            return error.SnapshotDispatchTimeout;
        ctrl.cross_slots.release(@intCast(create_cqe.res));
        el.createSnapshot(job);

        const fd_cqe = cqeBefore(&ctrl.rings[1].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
            return error.SnapshotReplyTimeout;
        stepCQE(&frame, fd_cqe);

        try frame.snap.window.?.write(states[3], op);
        pumpWindow(&frame);

        // The rewrite's pending write succeeds; the rename is where it fails.
        ctrl.test_fail_registry_rename = true;
        const dump_cqe = cqeBefore(&ctrl.rings[elephant_ring].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
            return error.SnapshotDispatchTimeout;
        ctrl.cross_slots.release(@intCast(dump_cqe.res));
        el.dumpSnapshot(job);
        ctrl.test_fail_registry_rename = false;

        const abandon_cqe = cqeBefore(&ctrl.rings[1].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
            return error.SnapshotReplyTimeout;
        stepCQE(&frame, abandon_cqe);
        pumpWindow(&frame);

        // Unwind B: the window reverts, the new writer closes and cleanup is
        // dispatched. The committed line never changed.
        try testing.expect(frame.snap.window == null);
        try testing.expectEqual(lifetime.SnapshotPhase.cleanup_sent, job.phase);
        try testing.expect(pairControlLine(&ctrl).snapshot_in_progress == 0);

        const cleanup_cqe = cqeBefore(&ctrl.rings[elephant_ring].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
            return error.SnapshotDispatchTimeout;
        ctrl.cross_slots.release(@intCast(cleanup_cqe.res));
        el.cleanupSnapshot(job);
        job_live = false;

        const done_cqe = cqeBefore(&ctrl.rings[1].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
            return error.SnapshotReplyTimeout;
        stepCQE(&frame, done_cqe);
        try testing.expect(frame.snap.procedure == null);

        // The pending staging file is junk; the fixed registry still carries
        // the old line, byte for byte.
        const pending = try ctrl.registryPendingPath(0);
        defer allocator.free(pending);
        try testing.expect(fileExists(pending));
        const after_registry_path = try ctrl.registryPath(0);
        defer allocator.free(after_registry_path);
        const after = try readFileBytes(allocator, after_registry_path);
        defer allocator.free(after);
        try testing.expectEqualSlices(u8, fixed_registry.?, after);
        try testing.expect(fileExists(old_wal_path.?));
    }

    // Recovery is correct on the previous pair: every durable event was
    // written to it too (new first, then old), so nothing is lost.
    {
        var ctrl: lifetime.Controller = undefined;
        try ctrl.init(allocator, &cfg);
        defer ctrl.deinit();
        try ctrl.compensators.put("marker", .{ .bind = "10.0.0.1", .port = 20301 });

        try ctrl.initRing(1, 1);
        defer ctrl.rings[1].deinit();
        const logger = try ctrl.getLogger(1);
        defer dropTestLogger(&ctrl, logger);

        var st: state.IndexState = undefined;
        try ctrl.initIndexState(&st);
        defer ctrl.deinitIndexState(&st);

        try snapshot.recoverPair(&ctrl, &ctrl.rings[1], &logger.logger, 0, 0, &st);

        try testing.expectEqual(@as(u128, states[3]), st.state);
        try testing.expectEqual(states.len, st.sessions.count());
        var reference: state.IndexState = undefined;
        try ctrl.initIndexState(&reference);
        defer ctrl.deinitIndexState(&reference);
        for (states) |s| {
            reference.state = s;
            try ctrl.applyIndexOp(&reference, .{ .create = .{ .compensator = "marker", .payload = op } });
        }
        try expectSameSessions(&reference, &st);
    }
}
