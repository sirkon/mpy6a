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
const elephant = @import("elephant.zig");

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

/// How this thread serves its pairs' write side (designs/SNAPSHOTS.md §4).
///
/// The front intake is denied whenever the state is not `serving`; the control
/// plane (reserved `taskIdx` traffic and cross-task slots) always flows.
/// `frozen` is the window's old-side refusal (§5), `stopped` the terminal
/// WAL fault.
pub const WalServe = enum { serving, frozen, stopped };

/// One refused index→elephant `MSG_RING`: the slot is already acquired and its
/// payload written, so only the push itself is retried (§4).
pub const PendingPush = struct { slot_idx: u32, target_ring_idx: u16 };

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
    draining: bool = false,
    /// The WAL service state replacing the old `faulted` bool.
    wal_serve: WalServe = .serving,
    /// The one in-flight procedure; null means none (the one-operation rule).
    procedure: ?*lifetime.SnapshotJob = null,
    /// The pending push, when an index→elephant `MSG_RING` was refused.
    pending_push: ?PendingPush = null,
    /// The live window's composite, once a procedure has adopted (§3.2).
    window: ?lifetime.CompositeWriter = null,
    /// Tick CQEs observed; the tests' routing spy.
    snapshot_ticks: u32 = 0,
};

/// The startup replay's sink, the e2e `Replay` shape: the record's state
/// becomes `st.state` before the op is applied — `applyIndexOp`'s contract.
const StartupReplay = struct {
    ctrl: *lifetime.Controller,
    st: *state.IndexState,

    fn apply(ctx: ?*anyopaque, state_idx: u128, op: []const u8) anyerror!void {
        const self: *StartupReplay = @ptrCast(@alignCast(ctx.?));
        self.st.state = state_idx;
        try self.ctrl.applyIndexOp(self.st, .{ .create = .{ .compensator = "marker", .payload = op } });
    }
};

/// One pair's cold startup sequence (designs/SNAPSHOTS.md §7.1), in the
/// pinned order: the adoption rule before any open, the registry's last line,
/// the snapshot, the writer, the bring-tail, the replay.
///
/// The registry's `error.RegistryCorrupt` is returned unchanged so the wiring
/// can turn it into the process fatality and tests can assert the error; a
/// missing or otherwise unreadable registry starts the pair empty (§7.3).
///
/// The replay floor is the snapshot's base state — the registry line's
/// `"state"` key — not the walked head: the walk lands on the *last* record,
/// and the records a restart must apply are exactly the ones between the
/// snapshot and that head. The sink moves `st.state` through each of them, so
/// the pair ends at the walked head.
fn recoverPair(
    ctrl: *lifetime.Controller,
    ring: *lifetime.RingStuff,
    logger: *lifetime.LoggerStuff,
    index_idx: u16,
    host_idx: u8,
    st: *state.IndexState,
) !void {
    const log = &logger.logger;

    // The INITIALIZED report left through a direct submission and moved the
    // ring's tail past the stream window captured at ring creation. Re-capture
    // it before this pair's first flush or read goes through the window.
    ring.ring.streamedSQ(&ring.sqstream);

    const adoption = ctrl.runAdoptionRule(host_idx, index_idx) catch |err| switch (err) {
        error.RegistryCorrupt => return error.RegistryCorrupt,
        else => {
            log.warn("index recovery could not read the registry; starting the pair empty", .{
                .index_idx = index_idx,
                .host_idx = host_idx,
                .err = @errorName(err),
            });
            st.state = 0;
            return;
        },
    };

    const entries = ctrl.loadRegistry(index_idx) catch |err| switch (err) {
        error.RegistryCorrupt => return error.RegistryCorrupt,
        else => {
            log.warn("index recovery could not read the registry; starting the pair empty", .{
                .index_idx = index_idx,
                .host_idx = host_idx,
                .err = @errorName(err),
            });
            st.state = 0;
            return;
        },
    };
    defer if (entries) |list| ctrl.freeRegistry(list);

    const entry = if (entries) |list| lifetime.Controller.lastLineFor(list, host_idx) else null;
    const winning = entry orelse {
        log.warn("no registry line names the pair; starting it empty", .{
            .index_idx = index_idx,
            .host_idx = host_idx,
        });
        st.state = 0;
        return;
    };

    // The snapshot: the whole dump, loaded into a fresh state that replaces
    // the thread's empty placeholder (§7.1 step 3).
    const snapshot_bytes = try readWholeFile(ctrl.allocator, winning.snapshot_path);
    defer ctrl.allocator.free(snapshot_bytes);
    const loaded = try ctrl.loadIndexState(snapshot_bytes);
    ctrl.deinitIndexState(st);
    st.* = loaded;

    // The writer: the walk supersedes the name tag's head (§7.1 step 4).
    const tag = wal.walTagFromPath(winning.wal_path) orelse {
        log.err("registry line names a WAL leaf without a state tag", .{
            .index_idx = index_idx,
            .host_idx = host_idx,
            .wal_path = winning.wal_path,
        });
        return error.RegistryCorrupt;
    };
    const writer = try ctrl.walOpenWrite(host_idx, index_idx, tag);

    switch (ctrl.wal_mode) {
        .pmem => st.state = writer.head,
        .plain => {
            // An empty new file under a tag `X < Y` walks to `X` and is
            // corrected by the line's state; a non-empty file walks past `Y`
            // and the key is inert (§7.1).
            const head = @max(writer.head, winning.state);
            writer.head = head;
            st.state = head;
        },
    }
    writer.attachStream(&ring.sqstream, &ring.slots);

    // The bring-tail after the attach, since it flushes (§7.1 step 5).
    switch (adoption) {
        .aborted => |abort| {
            if (ctrl.cfg.wal.isPmem()) {
                var tail = lifetime.Controller.TailSink.init(ctrl.allocator);
                defer tail.deinit();
                try ctrl.bringTail(host_idx, index_idx, abort.k, abort.tag, writer, writer.head, &tail);
            }
        },
        else => {},
    }
    // The bring may have advanced the writer's head; the pair follows it.
    st.state = writer.head;

    // The replay: the snapshot first, then the WAL over it (§7.1 step 6).
    const reader = try ctrl.walOpenRead(host_idx, index_idx, tag);
    defer ctrl.walCloseRead(reader);

    var replay = StartupReplay{ .ctrl = ctrl, .st = st };
    const process = try reader.beginRead(ctrl.allocator, .{ .seek_then_read = winning.state }, .{
        .ctx = &replay,
        .apply = StartupReplay.apply,
    });
    defer reader.endRead(ctrl.allocator, process);
    try process.drive(.{ .stream = &ring.sqstream, .slots = &ring.slots });
}

/// Reads `path` whole, raw: the snapshot's bytes before `loadIndexState`.
fn readWholeFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(path_z);

    const fd_raw = std.os.linux.open(path_z, .{ .ACCMODE = .RDONLY }, 0);
    const errno = std.os.linux.errno(fd_raw);
    if (errno != .SUCCESS) return switch (errno) {
        .NOENT => error.FileNotFound,
        else => std.posix.unexpectedErrno(errno),
    };
    const fd: posix.fd_t = @intCast(fd_raw);
    defer _ = std.os.linux.close(fd);

    const size = try wal.fileSize(fd);
    const bytes = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(bytes);

    var got: usize = 0;
    while (got < bytes.len) {
        const at: posix.off_t = @intCast(got);
        const res = std.os.linux.pread(fd, bytes[got..].ptr, bytes.len - got, at);
        const read_errno = std.os.linux.errno(res);
        if (read_errno != .SUCCESS) return std.posix.unexpectedErrno(read_errno);
        if (res == 0) return error.EndOfStream;
        got += res;
    }
    return bytes;
}

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
        recoverPair(ctrl, ring, logger, role.index.inbox_idx, @intCast(host), &data_sets[host]) catch |err| {
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

    // The repeating snapshot ticker (§1.1): one timeout CQE per period, armed
    // once here. The kernel reads the spec asynchronously, so it lives in the
    // ring's own storage; a failed arm disables snapshots on this thread only,
    // and the thread keeps serving.
    ring.tick_spec = .{ .sec = ctrl.cfg.snapshots.interval_s, .nsec = 0 };
    ring.ring.pushTicker(messages.SnapshotTickIdx, &ring.tick_spec, 0, .{}) catch |err| {
        log.err("snapshot ticker arm failed; snapshots disabled on this thread", .{
            .ring_idx = role.index.ring_idx,
            .err = @errorName(err),
        });
    };
    // The arm is a direct submission like the INITIALIZED report: re-capture
    // the stream window before the loop's first flush uses it.
    ring.ring.streamedSQ(&ring.sqstream);

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

    while (true) {
        // One pending push per pass: a procedure's pushes are sequential, so a
        // single op suffices (§4).
        retryPendingPush(&frame);

        const batch = inbox.batch(cfg.batch_k, cfg.batch_k) orelse {
            // A pending push must not park: the loop keeps passing until the
            // `MSG_RING` lands.
            if (frame.pending_push != null) {
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

        while (batch.front.next()) |task| switch (task) {
            .create => |create| {
                // A stopped thread takes no front work at all: the session is
                // refused by closing its descriptor at once, the skeleton's own
                // shape. The refusal's wire form is the consensus design's.
                if (frame.wal_serve != .serving) {
                    log.warn("index refused a session: the WAL stopped this thread", .{
                        .ring_idx = role.index.ring_idx,
                        .fd = create.fd,
                        .wal_serve = @tagName(frame.wal_serve),
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
                if (frame.wal_serve != .serving) continue;
            },
            .shutdown_soft => {
                if (!frame.draining) {
                    frame.draining = true;
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
        if (frame.draining and own_state.sessions.count() == 0) {
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
            resyncStream(frame);
            dispatchSnapshotReply(frame, task);
        },
        // The repeating snapshot ticker's own timeout completion (§1.1).
        messages.SnapshotTickIdx => tickPass(frame),
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
                    if (frame.window) |*window| window.noteFlush(flush.writer);
                    onWriterFault(flush.writer, frame);
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
                        if (err == error.IO) frame.wal_serve = .stopped;
                    };
                },
                else => {},
            }
        },
    }
}

/// The `wal_flush` arm's fault consequence (§5).
///
/// A fault on the window's old side freezes the front: the migration can still
/// finish on the new file, and the swap revives the thread. Everything else is
/// the landed rule unchanged — a new-side fault, or any fault outside a window,
/// stops the thread, and a relapse after revival finds `window == null` and
/// stops terminally.
fn onWriterFault(writer: *wal.WalWriteFile, frame: *Frame) void {
    if (!writer.faulted) return;

    if (frame.window) |*window| {
        if (writer == window.old and frame.wal_serve != .stopped) {
            frame.wal_serve = .frozen;
            frame.logger.logger.warn("the window's old WAL faulted; the front is frozen", .{
                .ring_idx = frame.ring_idx,
                .host_idx = writer.host_idx,
                .index_idx = writer.index_idx,
            });
            return;
        }
    }

    frame.wal_serve = .stopped;
    frame.logger.logger.err("wal flush failed; the thread stops taking front work", .{
        .ring_idx = frame.ring_idx,
        .host_idx = writer.host_idx,
        .index_idx = writer.index_idx,
    });
}

/// Dispatches one elephant→index reply by variant.
///
/// `SnapshotDone` is the terminal reply: the in-flight flag clears here, which
/// enforces the one-operation rule to the true end of the procedure (§4). The
/// create reply opens the window (G3), the dump's completion closes it (G4),
/// and the two failure replies are §8's rungs 2, 5 and 6.
fn dispatchSnapshotReply(frame: *Frame, task: cross_task.CrossTask) void {
    const log = &frame.logger.logger;
    switch (task) {
        .SnapshotFd => |reply| snapshotFdPass(frame, reply.fd),
        .SnapshotDumped => snapshotDumpedPass(frame),
        .SnapshotCreateFailed => {
            // Rung 2: the handler pass never ran, so the unwind is markless.
            const job = frame.procedure orelse {
                log.warn("snapshot create failure without a procedure", .{ .ring_idx = frame.ring_idx });
                return;
            };
            unwindA(frame, job, .{ .mark_published = false, .writer_built = null });
        },
        .SnapshotDumpFailed, .SnapshotAbandon => {
            // Rungs 5 and 6: the dump or its registry line failed after the
            // arena reset; the window reverts to the old writer.
            const job = frame.procedure orelse {
                log.warn("snapshot failure reply without a procedure", .{ .ring_idx = frame.ring_idx });
                return;
            };
            unwindB(frame, job);
        },
        .SnapshotDone => {
            frame.procedure = null;
        },
        else => log.warn("index read a cross-task message it does not handle", .{
            .ring_idx = frame.ring_idx,
        }),
    }
}

/// The `SnapshotFd` reply's pass: mark, clone, adopt, composite, re-dispatch
/// (§3.2). One synchronous pass — no front message is processed inside it, so
/// nothing slips between its steps.
fn snapshotFdPass(frame: *Frame, fd: posix.fd_t) void {
    const log = &frame.logger.logger;
    const job = frame.procedure orelse {
        // Defensive: the one-procedure invariant makes this unreachable, and the
        // descriptor would leak if it were dropped.
        log.warn("snapshot fd reply without a procedure; closing the descriptor", .{
            .ring_idx = frame.ring_idx,
            .fd = fd,
        });
        _ = std.os.linux.close(fd);
        return;
    };

    // The index owns the descriptor from here on; the job is its one owner.
    job.fd = fd;
    const host = job.host_idx;
    const index = job.index_idx;

    // Step 1: the mark. Publishing after the create reply and before the
    // composite serves widens the guarded window — every crash from here to the
    // swap lands in one of the two restart branches (§3.5).
    frame.ctrl.publishAdoptionMark(host, index, job.k, job.tag) catch |err| {
        log.err("snapshot mark publish failed; unwinding", .{
            .ring_idx = frame.ring_idx,
            .host_idx = host,
            .index_idx = index,
            .err = @errorName(err),
        });
        unwindA(frame, job, .{ .mark_published = false, .writer_built = null });
        return;
    };

    // Step 2: the clone. Any hosted pair is a snapshot subject, own or mirror
    // (§1.2). Its state is `Y`, at or ahead of the tag `X`: the pair kept
    // serving, so there is no pin. Rung 3 unwinds quietly.
    job.clone = frame.ctrl.cloneIndexState(&frame.data_sets[host], job.arena.allocator()) catch |err| {
        log.warn("snapshot clone allocation failed; unwinding", .{
            .ring_idx = frame.ring_idx,
            .host_idx = host,
            .index_idx = index,
            .err = @errorName(err),
        });
        unwindA(frame, job, .{ .mark_published = true, .writer_built = null });
        return;
    };

    // Step 3: the adopt. Temp ring `k` is minted, the writer opens over the
    // transferred fd, publishes the ordinal-0 terminator carrying `Y` and
    // chains from it. Rung 4 is memory-only.
    const new_writer = frame.ctrl.walAdoptWrite(host, index, job.k, job.clone.state, job.fd) catch |err| {
        // The adopt owns the descriptor from the moment it is called and
        // closes it on every failure path, so the job must not hand a stale
        // number to the cleanup elephant.
        job.fd = -1;
        log.warn("snapshot adopt failed; unwinding", .{
            .ring_idx = frame.ring_idx,
            .host_idx = host,
            .index_idx = index,
            .err = @errorName(err),
        });
        unwindA(frame, job, .{ .mark_published = true, .writer_built = null });
        return;
    };
    // The writer owns the descriptor now.
    job.fd = -1;
    new_writer.attachStream(&frame.ring.sqstream, &frame.ring.slots);

    // Step 4: the composite. The pair's write interface is new-first, then
    // old, for the window's duration; the old writer stays registered.
    const pair = wal.areaIndex(host, index, frame.ctrl.cfg.wal.hosts());
    const old_writer = frame.ctrl.wal_writers[pair] orelse {
        // No pair writer to fall back to: a bug, and the only rung the design
        // does not name. Tear the new writer down and unwind quietly.
        log.err("snapshot adopt found no pair writer; unwinding", .{
            .ring_idx = frame.ring_idx,
            .host_idx = host,
            .index_idx = index,
        });
        new_writer.close() catch {};
        frame.ctrl.allocator.destroy(new_writer);
        unwindA(frame, job, .{ .mark_published = true, .writer_built = null });
        return;
    };
    frame.window = .{
        .new = new_writer,
        .old = old_writer,
        .allocator = frame.ctrl.allocator,
    };

    // Step 5: cursor pick 2. A refused push parks in the pending op and the
    // pass ends — the window keeps serving.
    job.phase = .dump_sent;
    dispatchSnapshot(.{ .SnapshotDump = .{ .job = @intFromPtr(job) } }, frame.ctrl.nextElephantRing(), frame);
}

/// The `SnapshotDumped` reply's pass: the swap and the final close (§3.4).
///
/// Memory only and unable to fail in its defined steps: the drain, the copy,
/// the clear, the revival and the retirement. Its crash cases are §3.5's table,
/// which the mark and the copy's idempotence already cover.
fn snapshotDumpedPass(frame: *Frame) void {
    const log = &frame.logger.logger;
    const job = frame.procedure orelse {
        log.warn("snapshot completion without a procedure", .{ .ring_idx = frame.ring_idx });
        return;
    };

    // Step 1: the bounded drain. Both writers' in-flight flushes land before
    // the copy — a late completion would publish a terminator into the pair
    // area after the copy clobbered it — and a new-side DMA finishes before
    // temp ring `k` can be reused.
    drainUntilQuiet(frame);

    const pair = wal.areaIndex(job.host_idx, job.index_idx, frame.ctrl.cfg.wal.hosts());
    const window = if (frame.window) |*w| w else {
        log.err("snapshot completion found no window; cleaning up", .{
            .ring_idx = frame.ring_idx,
            .host_idx = job.host_idx,
            .index_idx = job.index_idx,
        });
        frame.ctrl.snapshot_slots.at(job.k).status = .rollback;
        job.phase = .cleanup_sent;
        dispatchSnapshot(.{ .SnapshotCleanup = .{ .job = @intFromPtr(job) } }, frame.ctrl.nextElephantRing(), frame);
        return;
    };

    // Step 2: the copy of temp ring `k`'s data and header arrays, then the
    // rewire. The areas are geometrically identical, so the surviving writer
    // only changes addresses; its ordinals and cursor continue unchanged.
    const area = frame.ctrl.copyTempIntoPair(pair, job.k) catch |err| {
        log.err("snapshot swap copy failed; unwinding", .{
            .ring_idx = frame.ring_idx,
            .host_idx = job.host_idx,
            .index_idx = job.index_idx,
            .err = @errorName(err),
        });
        unwindB(frame, job);
        return;
    };
    window.new.data = area.data;
    window.new.headers = area.headers;

    // Step 3: the clear. The mark is over; the pair area is the new chain.
    frame.ctrl.clearAdoptionMark(job.host_idx, job.index_idx) catch |err| {
        log.err("snapshot mark clear failed", .{
            .ring_idx = frame.ring_idx,
            .host_idx = job.host_idx,
            .index_idx = job.index_idx,
            .err = @errorName(err),
        });
    };

    // Step 4: revival, if the old side had frozen the front (§5). It is
    // computed from live writers only, and the old one is about to retire.
    reviveIfHealthy(frame);

    // Step 5: the retirement and the final close. The old writer is quiet; its
    // descriptor moves to the terminal elephant and the object dies without a
    // close. The index stops dereferencing the job here; the flag clears on
    // `SnapshotDone`.
    const new_writer = window.new;
    const old_writer = window.old;
    job.old_fd = old_writer.fd;
    frame.ctrl.allocator.destroy(old_writer);
    frame.ctrl.wal_writers[pair] = new_writer;
    window.pending.deinit(frame.ctrl.allocator);
    frame.window = null;

    job.phase = .close_sent;
    dispatchSnapshot(.{ .SnapshotClose = .{ .job = @intFromPtr(job) } }, frame.ctrl.nextElephantRing(), frame);
}

/// The bounded drain of §3.4: step the thread's ordinary completions until both
/// window writers are quiet.
///
/// Not `close`'s `awaitFlush`: that retires and drops foreign completions,
/// which mid-service would strand another pair's writer with its flush flag
/// stuck. At most one flush is ever in flight per writer, and a parked
/// submission is retried as the drain's own completions reopen the window, so
/// the loop terminates.
fn drainUntilQuiet(frame: *Frame) void {
    while (true) {
        const window = if (frame.window) |*w| w else return;
        retryParkedFlush(window.new);
        retryParkedFlush(window.old);
        if (window.quiet()) return;

        if (frame.ring.ring.popCQE()) |cqe| {
            stepCQE(frame, cqe);
            continue;
        }
        frame.ring.ring.park();
    }
}

/// Retries a submission backpressure parked: its own writer cannot re-drive it
/// without a write, and no completion is owed for it.
fn retryParkedFlush(writer: *wal.WalWriteFile) void {
    if (writer.flush_pending and !writer.flush_in_flight) writer.driveFlush();
}

/// Unwind A (§8): the pre-composite rungs — create failure, clone allocation,
/// adopt allocation.
///
/// Memory only: a half-built writer object is destroyed (the adopt's failure
/// path has already closed the descriptor it was handed) and the mark, if it
/// was published, is cleared. The cleanup elephant owns the files, the
/// descriptor and the slot from the dispatch on.
fn unwindA(
    frame: *Frame,
    job: *lifetime.SnapshotJob,
    opts: struct { mark_published: bool, writer_built: ?*wal.WalWriteFile },
) void {
    if (opts.writer_built) |writer| frame.ctrl.allocator.destroy(writer);

    if (opts.mark_published) {
        frame.ctrl.clearAdoptionMark(job.host_idx, job.index_idx) catch |err| {
            frame.logger.logger.err("snapshot mark clear failed", .{
                .ring_idx = frame.ring_idx,
                .host_idx = job.host_idx,
                .index_idx = job.index_idx,
                .err = @errorName(err),
            });
        };
    }

    frame.ctrl.snapshot_slots.at(job.k).status = .rollback;
    job.phase = .cleanup_sent;
    dispatchSnapshot(.{ .SnapshotCleanup = .{ .job = @intFromPtr(job) } }, frame.ctrl.nextElephantRing(), frame);
}

/// Unwind B (§8): the composite is installed — the dump failed or its registry
/// line did.
///
/// Revert to the old single writer, drain both, close the new writer, clear the
/// mark, dispatch cleanup. A frozen thread stays frozen: the failed procedure
/// brings no swap, so no revival is coming (§5, §8 rung 10).
fn unwindB(frame: *Frame, job: *lifetime.SnapshotJob) void {
    const log = &frame.logger.logger;
    var window = frame.window orelse {
        // No window to revert: nothing was installed, but the procedure's files
        // and slot still need their terminal elephant.
        frame.ctrl.snapshot_slots.at(job.k).status = .rollback;
        job.phase = .cleanup_sent;
        dispatchSnapshot(.{ .SnapshotCleanup = .{ .job = @intFromPtr(job) } }, frame.ctrl.nextElephantRing(), frame);
        return;
    };

    // The drain runs before the window is torn down: it is what makes the close
    // safe, both writers quiet (§3.4).
    drainUntilQuiet(frame);
    frame.window = null;

    // The close is safe precisely because the drain made the writer quiet. The
    // descriptor comes back through the sentinel: after the close the writer
    // holds `-1`, so the job's field does too.
    window.new.close() catch |err| {
        log.warn("snapshot unwind close failed", .{
            .ring_idx = frame.ring_idx,
            .host_idx = job.host_idx,
            .index_idx = job.index_idx,
            .err = @errorName(err),
        });
    };
    job.fd = window.new.fd;
    window.pending.deinit(frame.ctrl.allocator);
    frame.ctrl.allocator.destroy(window.new);

    frame.ctrl.clearAdoptionMark(job.host_idx, job.index_idx) catch |err| {
        log.err("snapshot mark clear failed", .{
            .ring_idx = frame.ring_idx,
            .host_idx = job.host_idx,
            .index_idx = job.index_idx,
            .err = @errorName(err),
        });
    };

    frame.ctrl.snapshot_slots.at(job.k).status = .rollback;
    job.phase = .cleanup_sent;
    dispatchSnapshot(.{ .SnapshotCleanup = .{ .job = @intFromPtr(job) } }, frame.ctrl.nextElephantRing(), frame);
}

/// The swap's revival rule (§5): the front reopens iff no **live** writer of
/// the thread's pairs is faulted.
///
/// The window's old writer is retiring, so it is not part of the live set: the
/// frozen window's events were written new-first and the registry line is
/// committed, which is exactly what makes serving safe again. A relapse after
/// this finds no window and stops terminally.
fn reviveIfHealthy(frame: *Frame) void {
    if (frame.wal_serve != .frozen) return;

    const retiring = if (frame.window) |*window| window.old else null;
    for (frame.ctrl.wal_writers) |maybe_writer| {
        const writer = maybe_writer orelse continue;
        if (writer == retiring) continue;
        if (writer.faulted) return;
    }
    frame.wal_serve = .serving;
}

/// Classifies a composite write's refusal (§5, §6).
///
/// In a window, the old side's `WalFull` is exactly "cannot serve into the
/// fallback" and freezes the front — the swap retires the old file shortly, so
/// the freeze is brief. A fault on the new side is the ordinary terminal stop.
/// `RecordTooLarge` and `WalGap` are protocol answers, never triggers, and pure
/// submission backpressure parks in the pending op instead of returning.
fn onCompositeWriteError(frame: *Frame, err: wal.WalError) void {
    if (err != error.WalFull and err != error.WalFaulted) return;

    const window = if (frame.window) |*w| w else {
        if (err == error.WalFaulted) frame.wal_serve = .stopped;
        return;
    };
    if (frame.wal_serve == .stopped) return;

    if (window.failed_side == .old) {
        frame.wal_serve = .frozen;
        frame.logger.logger.warn("the window's old side refused; the front is frozen", .{
            .ring_idx = frame.ring_idx,
            .err = @errorName(err),
        });
        return;
    }

    if (err == error.WalFaulted) {
        frame.wal_serve = .stopped;
        frame.logger.logger.err("the window's new side faulted; the thread stops", .{
            .ring_idx = frame.ring_idx,
        });
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

/// One tick of the snapshot ticker (§1.2).
///
/// The tick never queues and never retries: a skip simply ends the pass. The
/// candidates are every pair this thread hosts — own data set and mirrors
/// alike — and the metric is the live writer's tracked extent.
fn tickPass(frame: *Frame) void {
    frame.snapshot_ticks +%= 1;

    // Rung 10: a stopped thread's files do not grow, and a window or a pending
    // push is one operation already in flight (§1.2, §4).
    if (frame.wal_serve != .serving) return;
    if (frame.procedure != null) return;
    if (frame.pending_push != null) return;

    const hosts = frame.ctrl.cfg.wal.hosts();
    const barrier = frame.ctrl.cfg.snapshots.size_barrier;
    var best_host: u8 = 0;
    var best_extent: u64 = 0;
    var found = false;
    var host: u32 = 0;
    while (host < hosts) : (host += 1) {
        const host_idx: u8 = @intCast(host);
        const pair = wal.areaIndex(host_idx, frame.index_idx, hosts);
        const writer = frame.ctrl.wal_writers[pair] orelse continue;
        const extent = writer.trackedExtent();
        if (!found or extent > best_extent) {
            found = true;
            best_host = host_idx;
            best_extent = extent;
        }
    }
    if (!found or best_extent < barrier) return;

    // The tag: the pair's state at this moment, fixed for the procedure (§2.3).
    const tag = frame.data_sets[best_host].state;

    // Rung 0: the process-wide limit is the design working, not a failure.
    const k = frame.ctrl.snapshot_slots.acquire() catch return;
    const job = frame.ctrl.mintSnapshotJob(best_host, frame.index_idx, tag, k, frame.ring_idx) catch |err| {
        // A quiet unwind-before-start: nothing was dispatched, and the tick
        // retries on its own schedule.
        frame.ctrl.snapshot_slots.release(k);
        frame.logger.logger.warn("snapshot job allocation failed; the tick ends", .{
            .ring_idx = frame.ring_idx,
            .host_idx = best_host,
            .err = @errorName(err),
        });
        return;
    };

    frame.ctrl.snapshot_slots.at(k).* = .{ .status = .in_flight, .job = @intFromPtr(job) };
    frame.procedure = job;
    dispatchSnapshot(.{ .SnapshotCreate = .{ .job = @intFromPtr(job) } }, frame.ctrl.nextElephantRing(), frame);
}

/// Sends one snapshot payload to an elephant ring through the ordinary
/// `cross_slots` pool (§3.1).
///
/// A refused push never drops and never spins: the slot stays acquired with
/// its payload written and the loop retries the `MSG_RING` once per pass (§4).
fn dispatchSnapshot(payload: cross_task.CrossTask, target_ring_idx: u16, frame: *Frame) void {
    const slot_idx = frame.ctrl.cross_slots.acquire() catch |err| {
        frame.logger.logger.err("snapshot dispatch found no cross-task slot", .{
            .ring_idx = frame.ring_idx,
            .target_ring_idx = target_ring_idx,
            .err = @errorName(err),
        });
        return;
    };
    frame.ctrl.cross_slots.at(slot_idx).* = payload;
    frame.ring.ring.pushMsgRingFd(
        frame.ctrl.rings[target_ring_idx].ring.fd,
        messages.CrossTaskMessageIdx,
        slot_idx,
        .{},
    ) catch |err| switch (err) {
        error.RingFull => {
            frame.pending_push = .{ .slot_idx = slot_idx, .target_ring_idx = target_ring_idx };
            return;
        },
    };
    resyncStream(frame);
}

/// Re-captures the ring's WAL stream window after a direct submission (§4).
///
/// The two submission paths share one SQ: a direct `MSG_RING` moves the ring's
/// tail past the stream's cursor, and the stream's next commit would rewind it.
/// The window's flushes and the procedure's dispatches both run on this ring,
/// so the cursors are re-captured as the ring's own.
fn resyncStream(frame: *Frame) void {
    frame.ring.ring.streamedSQ(&frame.ring.sqstream);
}

/// Retries the pending push, if any. Called once at the top of every loop pass:
/// the slot is already acquired and written, so only the `MSG_RING` repeats.
fn retryPendingPush(frame: *Frame) void {
    const pending = frame.pending_push orelse return;
    frame.ring.ring.pushMsgRingFd(
        frame.ctrl.rings[pending.target_ring_idx].ring.fd,
        messages.CrossTaskMessageIdx,
        pending.slot_idx,
        .{},
    ) catch return;
    frame.pending_push = null;
    resyncStream(frame);
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
        .wal = .{ .plain = .{ .dir = dir, .buffers = 8, .lba = 512, .hosts = hosts } },
        .snapshots = snapshots,
        .logging = .{
            .method = .{ .json = {} },
            .pool_capacity = 64,
            .pool_frame_size = 1024,
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
    frame.procedure = &job;

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
    try testing.expect(frame.procedure == null);
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
    frame.wal_serve = .stopped;

    stepCQE(&frame, .{ .user_data = messages.SnapshotTickIdx, .res = 0, .flags = 0 });

    try testing.expectEqual(@as(u32, 1), frame.snapshot_ticks);
    try testing.expect(frame.procedure == null);
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

test "the tick pass ends on each skip guard" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(dir);

    var cfg = testConfig(dir, 1, 0, .{ .size_barrier = 1, .interval_s = 1, .slots = 2, .registry_keep = 8 });
    var ctrl: lifetime.Controller = undefined;
    try ctrl.init(testing.allocator, &cfg);
    defer ctrl.deinit();
    try ctrl.initRing(1, 1);
    defer ctrl.rings[1].deinit();

    const logger = try ctrl.getLogger(1);
    defer dropTestLogger(&ctrl, logger);

    try ctrl.ensureIndexDir(0);
    try testWriter(&ctrl, 0, 0x300, 1, 100);

    var sets = [_]state.IndexState{undefined};
    try ctrl.initIndexState(&sets[0]);
    defer ctrl.deinitIndexState(&sets[0]);
    sets[0].state = 0x301;

    var frame = testFrame(&ctrl, 1, logger, &sets);
    const slots_full = ctrl.snapshot_slots.freeCount();

    // A stopped thread's files do not grow.
    frame.wal_serve = .stopped;
    tickPass(&frame);
    try testing.expectEqual(@as(u32, 1), frame.snapshot_ticks);
    try testing.expectEqual(slots_full, ctrl.snapshot_slots.freeCount());
    try testing.expect(frame.procedure == null);

    // A frozen window denies the tick just the same.
    frame.wal_serve = .frozen;
    tickPass(&frame);
    try testing.expectEqual(@as(u32, 2), frame.snapshot_ticks);
    try testing.expectEqual(slots_full, ctrl.snapshot_slots.freeCount());
    try testing.expect(frame.procedure == null);

    // One procedure per index: its own flag ends the pass.
    var job: lifetime.SnapshotJob = undefined;
    frame.wal_serve = .serving;
    frame.procedure = &job;
    tickPass(&frame);
    try testing.expectEqual(@as(u32, 3), frame.snapshot_ticks);
    try testing.expectEqual(slots_full, ctrl.snapshot_slots.freeCount());
    try testing.expect(frame.procedure == &job);

    // A pending push ends the pass too; the tick never queues.
    frame.procedure = null;
    frame.pending_push = .{ .slot_idx = 0, .target_ring_idx = 2 };
    tickPass(&frame);
    try testing.expectEqual(@as(u32, 4), frame.snapshot_ticks);
    try testing.expectEqual(slots_full, ctrl.snapshot_slots.freeCount());
    try testing.expect(frame.procedure == null);
    frame.pending_push = null;
}

test "the tick picks the largest pair and dispatches the create" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(dir);

    var cfg = testConfig(dir, 2, 1, .{ .size_barrier = 1, .interval_s = 1, .slots = 2, .registry_keep = 8 });
    var ctrl: lifetime.Controller = undefined;
    try ctrl.init(testing.allocator, &cfg);
    defer ctrl.deinit();
    try ctrl.initRing(1, 1);
    defer ctrl.rings[1].deinit();
    // The elephant's ring: the dispatch lands there.
    try ctrl.initRing(2, 1);
    defer ctrl.rings[2].deinit();

    const logger = try ctrl.getLogger(1);
    defer dropTestLogger(&ctrl, logger);

    try ctrl.ensureIndexDir(0);
    try testWriter(&ctrl, 0, 0x300, 1, 100);
    try testWriter(&ctrl, 1, 0x400, 2, 100);

    var sets = [_]state.IndexState{ undefined, undefined };
    for (&sets) |*st| try ctrl.initIndexState(st);
    defer for (&sets) |*st| ctrl.deinitIndexState(st);
    sets[0].state = 0x301;
    sets[1].state = 0x402;

    var frame = testFrame(&ctrl, 1, logger, &sets);
    tickPass(&frame);

    const job = frame.procedure orelse return error.SnapshotNotStarted;
    defer {
        frame.ctrl.snapshot_slots.at(job.k).* = .{ .status = .idle, .job = 0 };
        frame.ctrl.snapshot_slots.release(job.k);
        frame.ctrl.releaseSnapshotJob(job);
        frame.procedure = null;
    }

    // Host 1 wrote more, so it wins; the tag is its state at the tick.
    try testing.expectEqual(@as(u8, 1), job.host_idx);
    try testing.expectEqual(@as(u128, 0x402), job.tag);
    try testing.expectEqual(@as(u32, 0), job.k);
    try testing.expectEqual(@as(u16, 1), job.ring_idx);

    // The create request rides an ordinary cross-task slot into the elephant's
    // ring, carrying the job handle.
    const cqe = cqeBefore(&ctrl.rings[2].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
        return error.SnapshotDispatchTimeout;
    try testing.expectEqual(messages.CrossTaskMessageIdx, cqe.taskIdx());
    const slot_idx: u32 = @intCast(cqe.res);
    try testing.expectEqual(@intFromPtr(job), ctrl.cross_slots.at(slot_idx).SnapshotCreate.job);
    ctrl.cross_slots.release(slot_idx);
}

test "an exhausted snapshot pool ends the tick quietly" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(dir);

    var cfg = testConfig(dir, 1, 0, .{ .size_barrier = 1, .interval_s = 1, .slots = 1, .registry_keep = 8 });
    var ctrl: lifetime.Controller = undefined;
    try ctrl.init(testing.allocator, &cfg);
    defer ctrl.deinit();
    try ctrl.initRing(1, 1);
    defer ctrl.rings[1].deinit();

    const logger = try ctrl.getLogger(1);
    defer dropTestLogger(&ctrl, logger);

    try ctrl.ensureIndexDir(0);
    try testWriter(&ctrl, 0, 0x300, 1, 100);

    var sets = [_]state.IndexState{undefined};
    try ctrl.initIndexState(&sets[0]);
    defer ctrl.deinitIndexState(&sets[0]);
    sets[0].state = 0x301;

    var frame = testFrame(&ctrl, 1, logger, &sets);

    // Rung 0: the process-wide limit is the design working, not a failure.
    const held = try ctrl.snapshot_slots.acquire();
    defer ctrl.snapshot_slots.release(held);

    tickPass(&frame);

    try testing.expectEqual(@as(usize, 0), ctrl.snapshot_slots.freeCount());
    try testing.expect(frame.procedure == null);
}

test "a refused dispatch parks in the pending op and the retry lands it" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(dir);

    var cfg = testConfig(dir, 1, 1, .{});
    var ctrl: lifetime.Controller = undefined;
    try ctrl.init(testing.allocator, &cfg);
    defer ctrl.deinit();
    try ctrl.initRing(1, 1);
    defer ctrl.rings[1].deinit();
    try ctrl.initRing(2, 1);
    defer ctrl.rings[2].deinit();

    const logger = try ctrl.getLogger(1);
    defer dropTestLogger(&ctrl, logger);

    var frame = testFrame(&ctrl, 1, logger, &.{});
    const cross_full = ctrl.cross_slots.freeCount();
    const fake_job: usize = 0x5a5a;

    // A refused push is a race with the kernel's SQPOLL thread: the producer
    // outruns it in a tight run, but the poller may drain an entry before the
    // dispatch. Retry the run until the dispatch observes the full queue, and
    // consume the messages of the attempts that won the race.
    const spec = std.os.linux.kernel_timespec{ .sec = 0, .nsec = 0 };
    var parked = false;
    var attempt: u32 = 0;
    while (!parked and attempt < 2048) : (attempt += 1) {
        const base: u32 = @truncate(attempt *% cfg.queue_depth);
        var i: u32 = 0;
        var sq_full = false;
        while (i < 4 * cfg.queue_depth) : (i += 1) {
            ctrl.rings[1].ring.pushTimeout(base +% i, &spec, .{}) catch |err| {
                if (err != error.RingFull) return err;
                sq_full = true;
                break;
            };
        }
        try testing.expect(sq_full);

        dispatchSnapshot(.{ .SnapshotCreate = .{ .job = fake_job } }, 2, &frame);
        if (frame.pending_push != null) {
            parked = true;
            break;
        }

        // The push won: consume its message and slot before trying again.
        const sent = cqeBefore(&ctrl.rings[2].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
            return error.SnapshotDispatchTimeout;
        try testing.expectEqual(messages.CrossTaskMessageIdx, sent.taskIdx());
        ctrl.cross_slots.release(@intCast(sent.res));
        while (ctrl.rings[1].ring.popCQE()) |_| {}
    }
    try testing.expect(parked);

    // The push was refused: the slot stayed acquired with its payload written,
    // and the op waits for the next pass.
    try testing.expectEqual(cross_full - 1, ctrl.cross_slots.freeCount());

    // The loop is not parked: draining the completed timeouts frees the SQ and
    // the next pass retries the same slot.
    const deadline = zigring.monotonicNs() + 5 * std.time.ns_per_s;
    while (frame.pending_push != null) {
        if (zigring.monotonicNs() >= deadline) return error.PendingPushTimeout;
        while (ctrl.rings[1].ring.popCQE()) |_| {}
        retryPendingPush(&frame);
        std.atomic.spinLoopHint();
    }
    try testing.expectEqual(cross_full - 1, ctrl.cross_slots.freeCount());

    const cqe = cqeBefore(&ctrl.rings[2].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
        return error.SnapshotDispatchTimeout;
    try testing.expectEqual(messages.CrossTaskMessageIdx, cqe.taskIdx());
    const slot_idx: u32 = @intCast(cqe.res);
    try testing.expectEqual(fake_job, ctrl.cross_slots.at(slot_idx).SnapshotCreate.job);
    ctrl.cross_slots.release(slot_idx);
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
    if (frame.window) |*window| {
        _ = std.os.linux.close(window.new.fd);
        frame.ctrl.allocator.destroy(window.new);
        window.pending.deinit(frame.ctrl.allocator);
        frame.window = null;
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

test "unwind A clears a published mark, rolls the slot back and dispatches cleanup" {
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

    _ = try openPairWriter(&ctrl, 0, 0, 0x100);

    const k = try ctrl.snapshot_slots.acquire();
    const job = try ctrl.mintSnapshotJob(0, 0, 0x100, k, 1);
    defer dropTestJob(&ctrl, job);
    ctrl.snapshot_slots.at(k).* = .{ .status = .in_flight, .job = @intFromPtr(job) };

    var frame = testFrame(&ctrl, 1, logger, &sets);
    frame.procedure = job;

    try ctrl.publishAdoptionMark(0, 0, k, 0x100);
    try testing.expectEqual(@as(u8, 1), pairControlLine(&ctrl).snapshot_in_progress);

    unwindA(&frame, job, .{ .mark_published = true, .writer_built = null });

    // The line is clear again: the old pair is the one serving.
    const line = pairControlLine(&ctrl);
    try testing.expectEqual(@as(u8, 0), line.snapshot_in_progress);
    try testing.expectEqual(@as(u16, 0), line.new_wal_buffer_idx);
    try testing.expectEqual(@as(u128, 0), line.target_state);

    // The slot rolls back and the procedure's phase names its dispatch.
    try testing.expectEqual(cross_task.SnapshotSlotStatus.rollback, ctrl.snapshot_slots.at(k).status);
    try testing.expectEqual(lifetime.SnapshotPhase.cleanup_sent, job.phase);

    // The flag stays until the terminal `SnapshotDone` (§4).
    try testing.expectEqual(job, frame.procedure.?);

    const cqe = cqeBefore(&ctrl.rings[2].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
        return error.SnapshotDispatchTimeout;
    try testing.expectEqual(messages.CrossTaskMessageIdx, cqe.taskIdx());
    const slot_idx: u32 = @intCast(cqe.res);
    try testing.expectEqual(@intFromPtr(job), ctrl.cross_slots.at(slot_idx).SnapshotCleanup.job);
    ctrl.cross_slots.release(slot_idx);
}

test "unwind B reverts to the old writer, closes the new one and dispatches cleanup" {
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
    const new_fd = new.fd;

    const job = try ctrl.mintSnapshotJob(0, 0, 0x100, k, 1);
    defer dropTestJob(&ctrl, job);
    job.fd = -1;
    ctrl.snapshot_slots.at(k).* = .{ .status = .in_flight, .job = @intFromPtr(job) };

    var frame = testFrame(&ctrl, 1, logger, &sets);
    frame.procedure = job;
    frame.window = .{ .new = new, .old = old, .allocator = ctrl.allocator };
    try ctrl.publishAdoptionMark(0, 0, k, 0x100);

    unwindB(&frame, job);

    // The pair serves through the old writer again: no window, and a write
    // lands on the old side only.
    try testing.expect(frame.window == null);
    try testing.expectEqual(old, ctrl.wal_writers[0].?);
    var op: [494]u8 = undefined;
    @memset(&op, 0x11);
    try old.write(0x101, 0x100, &op);
    try testing.expectEqual(@as(u128, 0x101), old.head);

    // The new writer is closed and gone; its descriptor went back through the
    // sentinel, so the job holds nothing.
    try testing.expectEqual(std.os.linux.E.BADF, std.os.linux.errno(
        std.os.linux.fcntl(new_fd, std.os.linux.F.GETFD, 0),
    ));
    try testing.expectEqual(@as(posix.fd_t, -1), job.fd);

    const line = pairControlLine(&ctrl);
    try testing.expectEqual(@as(u8, 0), line.snapshot_in_progress);
    try testing.expectEqual(cross_task.SnapshotSlotStatus.rollback, ctrl.snapshot_slots.at(k).status);
    try testing.expectEqual(lifetime.SnapshotPhase.cleanup_sent, job.phase);

    const cqe = cqeBefore(&ctrl.rings[2].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
        return error.SnapshotDispatchTimeout;
    try testing.expectEqual(messages.CrossTaskMessageIdx, cqe.taskIdx());
    const slot_idx: u32 = @intCast(cqe.res);
    try testing.expectEqual(@intFromPtr(job), ctrl.cross_slots.at(slot_idx).SnapshotCleanup.job);
    ctrl.cross_slots.release(slot_idx);
}

test "the handler pass marks, clones, adopts, composites and re-dispatches the dump" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(dir);

    var cfg = testConfig(dir, 1, 1, .{ .slots = 2, .size_barrier = 1, .interval_s = 1, .registry_keep = 8 });
    var ctrl: lifetime.Controller = undefined;
    try ctrl.init(testing.allocator, &cfg);
    defer ctrl.deinit();
    try ctrl.initRing(1, 1);
    defer ctrl.rings[1].deinit();
    try ctrl.initRing(2, 1);
    defer ctrl.rings[2].deinit();
    try ctrl.compensators.put("marker", .{ .bind = "10.0.0.1", .port = 20301 });

    const logger = try ctrl.getLogger(1);
    defer dropTestLogger(&ctrl, logger);

    var sets = [_]state.IndexState{undefined};
    try ctrl.initIndexState(&sets[0]);
    defer ctrl.deinitIndexState(&sets[0]);

    // The pair has history: its writer chains from the file's tag, with one
    // record that ends on a buffer boundary so the window's own flush is the
    // one that reaches the file.
    try ctrl.ensureIndexDir(0);
    try testWriter(&ctrl, 0, 0x100, 1, 494);
    sets[0].state = 0x101;

    var frame = testFrame(&ctrl, 1, logger, &sets);
    tickPass(&frame);

    const job = frame.procedure orelse return error.SnapshotNotStarted;
    defer {
        if (frame.window != null) dropWindow(&frame);
        dropTestJob(&ctrl, job);
        frame.procedure = null;
    }
    try testing.expectEqual(@as(u128, 0x101), job.tag);

    // The elephant's create task, and F1's stand-in: create the file and hand
    // its descriptor back.
    const create_cqe = cqeBefore(&ctrl.rings[2].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
        return error.SnapshotDispatchTimeout;
    const create_slot: u32 = @intCast(create_cqe.res);
    try testing.expectEqual(@intFromPtr(job), ctrl.cross_slots.at(create_slot).SnapshotCreate.job);
    ctrl.cross_slots.release(create_slot);
    const fd = try createWalFile(job.wal_path);

    // The pair kept serving between the tick and the reply: Y is ahead of X.
    sets[0].state = 0x102;
    try ctrl.applyIndexOp(&sets[0], .{ .create = .{ .compensator = "marker", .payload = "served" } });
    try testing.expectEqual(@as(u128, 0x102), frame.data_sets[0].state);

    dispatchSnapshotReply(&frame, .{ .SnapshotFd = .{ .fd = fd } });

    // The mark carries (1, k, X) on the pair's control line.
    const line = pairControlLine(&ctrl);
    try testing.expectEqual(@as(u8, 1), line.snapshot_in_progress);
    try testing.expectEqual(@as(u16, @intCast(job.k)), line.new_wal_buffer_idx);
    try testing.expectEqual(@as(u128, 0x101), line.target_state);

    // The clone is a deep copy taken at the pair's state; the adopt chained the
    // new writer from Y and put it on temp ring k.
    try testing.expectEqual(@as(u128, 0x102), job.clone.state);
    try testing.expectEqual(@as(u128, 0x102), job.clone.sessions.get(0x102).?.id);
    try testing.expectEqual(@as(posix.fd_t, -1), job.fd);

    const window = &frame.window.?;
    try testing.expectEqual(@as(u128, 0x102), window.new.head);
    try testing.expectEqual(ctrl.wal_writers[0].?, window.old);
    // Both sides flush through the thread's ring, so the assertion below reads
    // what the composite's flushes actually committed.
    window.old.attachStream(&ctrl.rings[1].sqstream, &ctrl.rings[1].slots);
    const temp_start = wal.tempAreaIdx(job.k, ctrl.wal_pairs) * ctrl.wal_area_stride;
    const temp = wal.Area.init(
        ctrl.wal_battery.?[temp_start..][0..ctrl.wal_area_stride],
        cfg.wal.buffers(),
        cfg.wal.lba(),
    );
    try testing.expectEqual(@intFromPtr(temp.data.ptr), @intFromPtr(window.new.data.ptr));
    try testing.expectEqual(@intFromPtr(temp.headers.ptr), @intFromPtr(window.new.headers.ptr));

    // A write through the composite lands on both sides, new first.
    var op: [494]u8 = undefined;
    for (&op, 0..) |*byte, i| byte.* = @truncate(i *% 17 +% 3);
    try window.write(0x103, &op);
    const deadline = zigring.monotonicNs() + 5 * std.time.ns_per_s;
    while (!window.quiet()) {
        if (zigring.monotonicNs() >= deadline) return error.SnapshotFlushTimeout;
        if (frame.ring.ring.popCQE()) |cqe| {
            stepCQE(&frame, cqe);
        } else {
            std.atomic.spinLoopHint();
        }
    }
    try testing.expectEqual(@as(u128, 0x103), window.new.head);
    try testing.expectEqual(@as(u128, 0x103), window.old.head);

    const old_dir = try ctrl.indexDirPath(0);
    defer testing.allocator.free(old_dir);
    const old_path = try wal.walPath(testing.allocator, old_dir, 0, 0, 0x100);
    defer testing.allocator.free(old_path);
    const old_bytes = try readFileBytes(testing.allocator, old_path);
    defer testing.allocator.free(old_bytes);
    const new_bytes = try readFileBytes(testing.allocator, job.wal_path);
    defer testing.allocator.free(new_bytes);
    try testing.expect(std.mem.indexOf(u8, old_bytes, &op) != null);
    try testing.expect(std.mem.indexOf(u8, new_bytes, &op) != null);

    // The dump is re-dispatched, cursor pick 2.
    try testing.expectEqual(lifetime.SnapshotPhase.dump_sent, job.phase);
    const dump_cqe = cqeBefore(&ctrl.rings[2].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
        return error.SnapshotDispatchTimeout;
    const dump_slot: u32 = @intCast(dump_cqe.res);
    try testing.expectEqual(@intFromPtr(job), ctrl.cross_slots.at(dump_slot).SnapshotDump.job);
    ctrl.cross_slots.release(dump_slot);
}

test "a clone allocation failure unwinds A, clears the mark and dispatches cleanup" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(dir);

    var cfg = testConfig(dir, 1, 1, .{ .slots = 2, .size_barrier = 1, .interval_s = 1, .registry_keep = 8 });
    var ctrl: lifetime.Controller = undefined;
    try ctrl.init(testing.allocator, &cfg);
    defer ctrl.deinit();
    try ctrl.initRing(1, 1);
    defer ctrl.rings[1].deinit();
    try ctrl.initRing(2, 1);
    defer ctrl.rings[2].deinit();
    try ctrl.compensators.put("marker", .{ .bind = "10.0.0.1", .port = 20301 });

    const logger = try ctrl.getLogger(1);
    defer dropTestLogger(&ctrl, logger);

    var sets = [_]state.IndexState{undefined};
    try ctrl.initIndexState(&sets[0]);
    defer ctrl.deinitIndexState(&sets[0]);

    try ctrl.ensureIndexDir(0);
    try testWriter(&ctrl, 0, 0x100, 1, 100);
    sets[0].state = 0x101;

    var frame = testFrame(&ctrl, 1, logger, &sets);
    tickPass(&frame);

    const job = frame.procedure orelse return error.SnapshotNotStarted;
    defer {
        if (frame.window != null) dropWindow(&frame);
        dropTestJob(&ctrl, job);
        frame.procedure = null;
    }

    const create_cqe = cqeBefore(&ctrl.rings[2].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
        return error.SnapshotDispatchTimeout;
    ctrl.cross_slots.release(@intCast(create_cqe.res));
    const fd = try createWalFile(job.wal_path);

    // A served session makes the clone allocate; the poisoned arena refuses it.
    sets[0].state = 0x102;
    try ctrl.applyIndexOp(&sets[0], .{ .create = .{ .compensator = "marker", .payload = "served" } });
    job.arena.deinit();
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    job.arena = std.heap.ArenaAllocator.init(failing.allocator());

    dispatchSnapshotReply(&frame, .{ .SnapshotFd = .{ .fd = fd } });

    // Rung 3: the mark was published and is cleared again, the descriptor
    // stays with the job for the cleanup elephant, and no window opens.
    const line = pairControlLine(&ctrl);
    try testing.expectEqual(@as(u8, 0), line.snapshot_in_progress);
    try testing.expect(frame.window == null);
    try testing.expectEqual(fd, job.fd);
    try testing.expectEqual(cross_task.SnapshotSlotStatus.rollback, ctrl.snapshot_slots.at(job.k).status);
    try testing.expectEqual(lifetime.SnapshotPhase.cleanup_sent, job.phase);

    const cleanup_cqe = cqeBefore(&ctrl.rings[2].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
        return error.SnapshotDispatchTimeout;
    const cleanup_slot: u32 = @intCast(cleanup_cqe.res);
    try testing.expectEqual(@intFromPtr(job), ctrl.cross_slots.at(cleanup_slot).SnapshotCleanup.job);
    ctrl.cross_slots.release(cleanup_slot);
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
    frame.window = .{ .new = new, .old = old, .allocator = ctrl.allocator };
    defer {
        dropWindow(&frame);
        ctrl.snapshot_slots.release(k);
    }

    var op: [494]u8 = undefined;
    @memset(&op, 0x22);
    try frame.window.?.write(0x101, &op);
    try testing.expect(!frame.window.?.quiet());
    try testing.expect(old.flush_in_flight and new.flush_in_flight);

    drainUntilQuiet(&frame);

    // Both completions were stepped through the ordinary dispatch; the writers
    // are quiet and the events they carried are complete.
    try testing.expect(frame.window.?.quiet());
    try testing.expect(!old.flush_in_flight and !old.flush_pending);
    try testing.expect(!new.flush_in_flight and !new.flush_pending);
    try testing.expectEqual(@as(u64, 1), old.flushed_upto);
    try testing.expectEqual(@as(u64, 1), new.flushed_upto);
    try testing.expectEqual(@as(usize, 0), frame.window.?.pending.items.len);
}

/// A sink that holds every submission: the test decides when a flush completes.
const HoldFlush = struct {
    fn room(ctx: ?*anyopaque, writer: *wal.WalWriteFile) wal.WalError!void {
        _ = ctx;
        _ = writer;
    }

    fn submit(ctx: ?*anyopaque, writer: *wal.WalWriteFile, ordinal: u64) void {
        _ = ctx;
        _ = writer;
        _ = ordinal;
    }

    fn install(writer: *wal.WalWriteFile) void {
        writer.sink = .{ .room = room, .submit = submit };
    }
};

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
    frame.procedure = job;
    frame.window = .{ .new = new, .old = old, .allocator = ctrl.allocator };
    try ctrl.publishAdoptionMark(0, 0, k, 0x100);

    // A window event: both sides' synchronous sinks make it durable at once.
    var op: [494]u8 = undefined;
    for (&op, 0..) |*byte, i| byte.* = @truncate(i *% 13 +% 5);
    try frame.window.?.write(0x101, &op);

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
    frame.wal_serve = .frozen;
    const old_fd = old.fd;

    snapshotDumpedPass(&frame);

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
    try testing.expect(frame.window == null);

    const close_cqe = cqeBefore(&ctrl.rings[2].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
        return error.SnapshotDispatchTimeout;
    try testing.expectEqual(messages.CrossTaskMessageIdx, close_cqe.taskIdx());
    const close_slot: u32 = @intCast(close_cqe.res);
    try testing.expectEqual(@intFromPtr(job), ctrl.cross_slots.at(close_slot).SnapshotClose.job);
    ctrl.cross_slots.release(close_slot);

    // The swap revived the frozen front: the old writer is retired from the
    // live set, and the surviving one is healthy.
    try testing.expectEqual(WalServe.serving, frame.wal_serve);

    // A relapse after the swap finds no window and stops terminally.
    registered.faulted = true;
    onWriterFault(registered, &frame);
    try testing.expectEqual(WalServe.stopped, frame.wal_serve);

    // The terminal reply clears the in-flight flag.
    dispatchSnapshotReply(&frame, .{ .SnapshotDone = .{} });
    try testing.expect(frame.procedure == null);
}

test "an old-side flush fault freezes the front and a new-side fault stops it" {
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
    frame.window = .{ .new = new, .old = old, .allocator = ctrl.allocator };
    defer {
        dropWindow(&frame);
        ctrl.snapshot_slots.release(k);
    }

    // Rung: an old-side flush fault mid-window freezes; the front guard is the
    // state itself, and the control plane keeps flowing regardless (§5).
    old.faulted = true;
    onWriterFault(old, &frame);
    try testing.expectEqual(WalServe.frozen, frame.wal_serve);
    try testing.expect(frame.wal_serve != .serving);

    // A new-side fault is the ordinary terminal stop.
    new.faulted = true;
    onWriterFault(new, &frame);
    try testing.expectEqual(WalServe.stopped, frame.wal_serve);
}

test "the window's old side hitting capacity freezes the front" {
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

    // Fill the old pair up to its one-free-buffer floor: held completions keep
    // the ring the file's.
    const old = try openPairWriter(&ctrl, 0, 0, 0x100);
    HoldFlush.install(old);
    var op: [494]u8 = undefined;
    @memset(&op, 0x33);
    var pair_state: u128 = 0x100;
    var written: u32 = 0;
    while (written < cfg.wal.buffers() - 1) : (written += 1) {
        try old.write(pair_state + 1, pair_state, &op);
        pair_state += 1;
    }
    try testing.expectError(error.WalFull, old.write(pair_state + 1, pair_state, &op));

    // The new side is empty, so the same event is accepted there first and
    // refused by the old side: exactly "cannot serve into the fallback".
    const k = try ctrl.snapshot_slots.acquire();
    const new = try adoptWindowWriter(&ctrl, 0, 0, k, 0x200, pair_state);

    var frame = testFrame(&ctrl, 1, logger, &sets);
    frame.window = .{ .new = new, .old = old, .allocator = ctrl.allocator };
    defer {
        dropWindow(&frame);
        ctrl.snapshot_slots.release(k);
    }

    try testing.expectError(error.WalFull, frame.window.?.write(pair_state + 1, &op));
    try testing.expectEqual(lifetime.CompositeWriter.Side.old, frame.window.?.failed_side.?);
    try testing.expectEqual(pair_state + 1, frame.window.?.new.head);
    try testing.expectEqual(pair_state, frame.window.?.old.head);

    onCompositeWriteError(&frame, error.WalFull);
    try testing.expectEqual(WalServe.frozen, frame.wal_serve);

    // A protocol answer is never a trigger, and outside a window a fault stops.
    frame.wal_serve = .serving;
    onCompositeWriteError(&frame, error.RecordTooLarge);
    try testing.expectEqual(WalServe.serving, frame.wal_serve);
    onCompositeWriteError(&frame, error.WalGap);
    try testing.expectEqual(WalServe.serving, frame.wal_serve);
}

test "a failed procedure while frozen leaves the stop standing" {
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
    frame.procedure = job;
    frame.window = .{ .new = new, .old = old, .allocator = ctrl.allocator };
    try ctrl.publishAdoptionMark(0, 0, k, 0x100);

    // The old side froze the front; the dump then failed. No swap is coming,
    // so the freeze stands (§8 rung 10).
    old.faulted = true;
    frame.wal_serve = .frozen;
    unwindB(&frame, job);

    try testing.expectEqual(WalServe.frozen, frame.wal_serve);
    try testing.expect(frame.window == null);
    try testing.expectEqual(lifetime.SnapshotPhase.cleanup_sent, job.phase);
    try testing.expectEqual(cross_task.SnapshotSlotStatus.rollback, ctrl.snapshot_slots.at(k).status);

    const cleanup_cqe = cqeBefore(&ctrl.rings[2].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
        return error.SnapshotDispatchTimeout;
    const cleanup_slot: u32 = @intCast(cleanup_cqe.res);
    try testing.expectEqual(@intFromPtr(job), ctrl.cross_slots.at(cleanup_slot).SnapshotCleanup.job);
    ctrl.cross_slots.release(cleanup_slot);
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

test "an adopt allocation failure unwinds A and the descriptor is already closed" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(dir);

    // The controller's own allocator is the poisoned one: the adopt's writer
    // object is its next allocation.
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    var cfg = testConfig(dir, 1, 1, .{ .slots = 2, .size_barrier = 1, .interval_s = 1, .registry_keep = 8 });
    var ctrl: lifetime.Controller = undefined;
    try ctrl.init(failing.allocator(), &cfg);
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

    try ctrl.ensureIndexDir(0);
    try testWriter(&ctrl, 0, 0x100, 1, 494);
    sets[0].state = 0x101;

    var frame = testFrame(&ctrl, 1, logger, &sets);
    tickPass(&frame);

    const job = frame.procedure orelse return error.SnapshotNotStarted;
    defer {
        if (frame.window != null) dropWindow(&frame);
        dropTestJob(&ctrl, job);
        frame.procedure = null;
    }

    const create_cqe = cqeBefore(&ctrl.rings[2].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
        return error.SnapshotDispatchTimeout;
    ctrl.cross_slots.release(@intCast(create_cqe.res));
    const fd = try createWalFile(job.wal_path);

    // The clone of an empty data set allocates nothing; the adopt's writer
    // object is the next allocation and the one refused.
    failing.fail_index = failing.alloc_index;
    dispatchSnapshotReply(&frame, .{ .SnapshotFd = .{ .fd = fd } });
    failing.fail_index = std.math.maxInt(usize);

    // Rung 4: no window opened, the mark is cleared, and the descriptor the
    // adopt closed is not left in the job for a second close.
    try testing.expect(frame.window == null);
    try testing.expectEqual(@as(posix.fd_t, -1), job.fd);
    try testing.expectEqual(std.os.linux.E.BADF, std.os.linux.errno(
        std.os.linux.fcntl(fd, std.os.linux.F.GETFD, 0),
    ));
    try testing.expectEqual(@as(u8, 0), pairControlLine(&ctrl).snapshot_in_progress);
    try testing.expectEqual(cross_task.SnapshotSlotStatus.rollback, ctrl.snapshot_slots.at(job.k).status);
    try testing.expectEqual(lifetime.SnapshotPhase.cleanup_sent, job.phase);

    const cleanup_cqe = cqeBefore(&ctrl.rings[2].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
        return error.SnapshotDispatchTimeout;
    const cleanup_slot: u32 = @intCast(cleanup_cqe.res);
    try testing.expectEqual(@intFromPtr(job), ctrl.cross_slots.at(cleanup_slot).SnapshotCleanup.job);
    ctrl.cross_slots.release(cleanup_slot);
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
    frame.window = .{ .new = new, .old = old, .allocator = ctrl.allocator };
    defer {
        dropWindow(&frame);
        ctrl.snapshot_slots.release(k);
    }

    // The old side's admission pre-check passes, its submission is parked.
    ParkOnceSink.reset();
    ParkOnceSink.install(old);

    var op: [494]u8 = undefined;
    @memset(&op, 0x44);
    try frame.window.?.write(0x101, &op);
    try testing.expect(old.flush_pending);
    try testing.expect(!old.flush_in_flight);
    try testing.expect(!frame.window.?.quiet());

    drainUntilQuiet(&frame);

    // The retry took the parked submission, which completed synchronously: no
    // completion was owed to the drain.
    try testing.expectEqual(@as(u32, 3), ParkOnceSink.calls);
    try testing.expect(!old.flush_pending);
    try testing.expectEqual(@as(u64, 1), old.flushed_upto);
    try testing.expect(frame.window.?.quiet());
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
            .lba = 512,
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

const StartupPlain = struct {
    tmp: std.testing.TmpDir,
    dir: []u8,
    cfg: config.Config,
    ctrl: lifetime.Controller,

    fn init(self: *StartupPlain) !void {
        const allocator = std.testing.allocator;
        self.tmp = std.testing.tmpDir(.{});
        self.dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{self.tmp.sub_path[0..]});
        errdefer allocator.free(self.dir);
        self.cfg = testConfig(self.dir, 1, 0, .{ .registry_keep = 2 });
        try self.ctrl.init(allocator, &self.cfg);
        try self.ctrl.compensators.put("marker", .{ .bind = "10.0.0.1", .port = 20301 });
    }

    fn deinit(self: *StartupPlain) void {
        self.ctrl.deinit();
        std.testing.allocator.free(self.dir);
        self.tmp.cleanup();
    }
};

/// A small op: a handful of records fit one buffer's live tail, so a PMEM
/// restart recovers them from the battery chain without a file flush.
const post_op_len: usize = 6;

fn postOp(byte: u8) [post_op_len]u8 {
    return @splat(byte);
}

test "startup recovers a snapshotted pair: snapshot, walked head and replay" {
    const allocator = std.testing.allocator;

    var f: StartupPmem = undefined;
    try f.init(1);
    defer f.deinit();

    const host: u8 = 0;
    const index: u16 = 0;
    const x: u128 = 0x10;
    const y: u128 = 0x12;

    // The clone at the handler pass: two pre-snapshot sessions, state Y.
    var live: state.IndexState = undefined;
    try f.ctrl.initIndexState(&live);
    defer f.ctrl.deinitIndexState(&live);
    live.state = 0x10;
    try f.ctrl.applyIndexOp(&live, .{ .create = .{ .compensator = "marker", .payload = "pre-a" } });
    live.state = 0x11;
    try f.ctrl.applyIndexOp(&live, .{ .create = .{ .compensator = "marker", .payload = "pre-b" } });
    live.state = y;

    try f.ctrl.ensureIndexDir(index);
    const dir = try f.ctrl.indexDirPath(index);
    defer allocator.free(dir);

    // The elephant's snapshot file, named with the minted tag X.
    const snapshot_path = try wal.snapshotPath(allocator, dir, host, index, x);
    defer allocator.free(snapshot_path);
    var dump: std.ArrayList(u8) = .empty;
    defer dump.deinit(allocator);
    try f.ctrl.dumpIndexState(&live, &dump);
    try writeFileBytes(snapshot_path, dump.items);

    // The window's new writer: temp ring `k` over the new WAL file, named X
    // and chained from Y. Two post-snapshot records land there, and the mark
    // still stands at the crash — the crash table's adoption row.
    const wal_path = try wal.walPath(allocator, dir, host, index, x);
    defer allocator.free(wal_path);
    const created = try createWalFile(wal_path);
    _ = std.os.linux.close(created);
    const writer = try f.ctrl.walAdoptWrite(host, index, 0, y, try createWalFile(wal_path));
    var op_a = postOp(0x41);
    var op_b = postOp(0x42);
    try writer.write(y + 1, y, &op_a);
    try writer.write(y + 2, y + 1, &op_b);
    try f.ctrl.publishAdoptionMark(host, index, 0, x);
    _ = std.os.linux.close(writer.fd);
    f.ctrl.allocator.destroy(writer);

    // The registry: two compacted predecessors and the winning line. With
    // `registry_keep = 2` the file holds keep + 1 lines, last one wins.
    const snap_prev = try wal.snapshotPath(allocator, dir, host, index, 0x1);
    defer allocator.free(snap_prev);
    const wal_prev = try wal.walPath(allocator, dir, host, index, 0x1);
    defer allocator.free(wal_prev);
    try f.ctrl.rewriteRegistry(index, .{
        .host_idx = host,
        .snapshot_path = snap_prev,
        .wal_path = wal_prev,
        .state = 1,
    });
    try f.ctrl.rewriteRegistry(index, .{
        .host_idx = host,
        .snapshot_path = snap_prev,
        .wal_path = wal_prev,
        .state = 2,
    });
    try f.ctrl.rewriteRegistry(index, .{
        .host_idx = host,
        .snapshot_path = snapshot_path,
        .wal_path = wal_path,
        .state = y,
    });

    const registry_path = try f.ctrl.registryPath(index);
    defer allocator.free(registry_path);
    const before_registry = try readWholeFile(allocator, registry_path);
    defer allocator.free(before_registry);

    // The crash-and-restart.
    try f.reopen();

    const ring_idx: u16 = f.cfg.fronts;
    try f.ctrl.initRing(ring_idx, 1);
    defer f.ctrl.rings[ring_idx].deinit();
    const logger = try f.ctrl.getLogger(ring_idx);
    defer {
        logger.deinit(f.ctrl.allocator);
        f.ctrl.allocator.destroy(logger);
    }

    var st: state.IndexState = undefined;
    try f.ctrl.initIndexState(&st);
    defer f.ctrl.deinitIndexState(&st);

    try recoverPair(&f.ctrl, &f.ctrl.rings[ring_idx], logger, index, host, &st);

    // The walked head is the pair's state, and both post-snapshot records
    // were replayed over the snapshot.
    try std.testing.expectEqual(@as(u128, y + 2), st.state);
    try std.testing.expectEqual(@as(usize, 4), st.sessions.count());
    try std.testing.expect(st.sessions.get(0x10) != null);
    try std.testing.expect(st.sessions.get(0x11) != null);
    try std.testing.expect(st.sessions.get(y + 1) != null);
    try std.testing.expect(st.sessions.get(y + 2) != null);

    // The adoption on restart finished the migration: the pair area is the
    // temp ring's chain and the mark is gone.
    const pair = wal.areaIndex(host, index, f.cfg.wal.hosts());
    try std.testing.expectEqual(@as(u128, y + 2), f.ctrl.wal_writers[pair].?.head);
    const stride = f.ctrl.wal_area_stride;
    const pair_bytes = f.ctrl.wal_battery.?[pair * stride ..][0..stride];
    const temp_bytes = f.ctrl.wal_battery.?[wal.tempAreaIdx(0, f.ctrl.wal_pairs) * stride ..][0..stride];
    try std.testing.expectEqualSlices(u8, temp_bytes, pair_bytes);
    try std.testing.expectEqual(
        @as(u8, 0),
        wal.controlLineOf(pair_bytes, f.cfg.wal.buffers(), f.cfg.wal.lba()).snapshot_in_progress,
    );

    // The registry's compaction holds and recovery leaves it whole.
    const entries = (try f.ctrl.loadRegistry(index)).?;
    defer f.ctrl.freeRegistry(entries);
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqual(y, lifetime.Controller.lastLineFor(entries, host).?.state);

    const after_registry = try readWholeFile(allocator, registry_path);
    defer allocator.free(after_registry);
    try std.testing.expectEqualSlices(u8, before_registry, after_registry);
}

test "plain mode corrects an empty new WAL's tag with the registry's state" {
    const allocator = std.testing.allocator;

    var f: StartupPlain = undefined;
    try f.init();
    defer f.deinit();

    const host: u8 = 0;
    const index: u16 = 0;
    const x: u128 = 0x10;
    const y: u128 = 0x20;

    try f.ctrl.ensureIndexDir(index);
    const dir = try f.ctrl.indexDirPath(index);
    defer allocator.free(dir);

    // An empty snapshot, and the empty new WAL named `X`: the walk returns
    // `X`, and the line's state `Y` corrects it.
    var empty: state.IndexState = undefined;
    try f.ctrl.initIndexState(&empty);
    defer f.ctrl.deinitIndexState(&empty);
    var dump: std.ArrayList(u8) = .empty;
    defer dump.deinit(allocator);
    try f.ctrl.dumpIndexState(&empty, &dump);

    const snapshot_path = try wal.snapshotPath(allocator, dir, host, index, x);
    defer allocator.free(snapshot_path);
    try writeFileBytes(snapshot_path, dump.items);

    const wal_path = try wal.walPath(allocator, dir, host, index, x);
    defer allocator.free(wal_path);
    const created = try createWalFile(wal_path);
    _ = std.os.linux.close(created);

    try f.ctrl.rewriteRegistry(index, .{
        .host_idx = host,
        .snapshot_path = snapshot_path,
        .wal_path = wal_path,
        .state = y,
    });

    const ring_idx: u16 = f.cfg.fronts;
    try f.ctrl.initRing(ring_idx, 1);
    defer f.ctrl.rings[ring_idx].deinit();
    const logger = try f.ctrl.getLogger(ring_idx);
    defer {
        logger.deinit(f.ctrl.allocator);
        f.ctrl.allocator.destroy(logger);
    }

    var st: state.IndexState = undefined;
    try f.ctrl.initIndexState(&st);
    defer f.ctrl.deinitIndexState(&st);

    try recoverPair(&f.ctrl, &f.ctrl.rings[ring_idx], logger, index, host, &st);

    try std.testing.expectEqual(y, st.state);
    try std.testing.expectEqual(@as(usize, 0), st.sessions.count());
    const pair = wal.areaIndex(host, index, f.cfg.wal.hosts());
    try std.testing.expectEqual(y, f.ctrl.wal_writers[pair].?.head);
}

test "startup recovery re-captures the stream window after the landing handshake" {
    var f: StartupPlain = undefined;
    try f.init();
    defer f.deinit();

    const ring_idx: u16 = f.cfg.fronts;
    try f.ctrl.initRing(ring_idx, 1);
    defer f.ctrl.rings[ring_idx].deinit();
    const ring = &f.ctrl.rings[ring_idx];

    try std.testing.expectEqual(ring.ring.sq_tail.*, ring.sqstream.tail);

    // The INITIALIZED report: a direct submission that moves the ring's tail
    // past the window captured at ring creation.
    try ring.ring.pushMsgRingFd(ring.ring.fd, messages.StartWorkIdx, 0, .{});
    try std.testing.expect(ring.sqstream.tail != ring.ring.sq_tail.*);

    var st: state.IndexState = undefined;
    try f.ctrl.initIndexState(&st);
    defer f.ctrl.deinitIndexState(&st);

    const logger = try f.ctrl.getLogger(ring_idx);
    defer {
        logger.deinit(f.ctrl.allocator);
        f.ctrl.allocator.destroy(logger);
    }

    // No registry: the pair starts empty, and the recovery's first act is the
    // re-capture the later replay and the loop's flushes rely on.
    try recoverPair(&f.ctrl, ring, logger, 0, 0, &st);

    try std.testing.expectEqual(ring.ring.sq_tail.*, ring.sqstream.tail);
}

test "startup with an absent registry starts the pair empty" {
    var f: StartupPlain = undefined;
    try f.init();
    defer f.deinit();

    var st: state.IndexState = undefined;
    try f.ctrl.initIndexState(&st);
    defer f.ctrl.deinitIndexState(&st);
    st.state = 0x55;

    const ring_idx: u16 = f.cfg.fronts;
    try f.ctrl.initRing(ring_idx, 1);
    defer f.ctrl.rings[ring_idx].deinit();
    const logger = try f.ctrl.getLogger(ring_idx);
    defer {
        logger.deinit(f.ctrl.allocator);
        f.ctrl.allocator.destroy(logger);
    }

    try recoverPair(&f.ctrl, &f.ctrl.rings[ring_idx], logger, 0, 0, &st);

    // State 0, no writer: startup does not scan (§7.3).
    try std.testing.expectEqual(@as(u128, 0), st.state);
    try std.testing.expectEqual(@as(usize, 0), st.sessions.count());
    try std.testing.expect(f.ctrl.wal_writers[0] == null);
}

test "startup's corrupt registry line is a returned fatality" {
    var f: StartupPlain = undefined;
    try f.init();
    defer f.deinit();

    try f.ctrl.ensureIndexDir(0);
    const registry_path = try f.ctrl.registryPath(0);
    defer std.testing.allocator.free(registry_path);
    try writeFileBytes(registry_path, "not json at all\n");

    var st: state.IndexState = undefined;
    try f.ctrl.initIndexState(&st);
    defer f.ctrl.deinitIndexState(&st);

    const ring_idx: u16 = f.cfg.fronts;
    try f.ctrl.initRing(ring_idx, 1);
    defer f.ctrl.rings[ring_idx].deinit();
    const logger = try f.ctrl.getLogger(ring_idx);
    defer {
        logger.deinit(f.ctrl.allocator);
        f.ctrl.allocator.destroy(logger);
    }

    try std.testing.expectError(
        error.RegistryCorrupt,
        recoverPair(&f.ctrl, &f.ctrl.rings[ring_idx], logger, 0, 0, &st),
    );
}

test "startup surfaces a missing WAL file raw" {
    var f: StartupPlain = undefined;
    try f.init();
    defer f.deinit();

    const host: u8 = 0;
    const index: u16 = 0;
    try f.ctrl.ensureIndexDir(index);
    const dir = try f.ctrl.indexDirPath(index);
    defer std.testing.allocator.free(dir);

    var empty: state.IndexState = undefined;
    try f.ctrl.initIndexState(&empty);
    defer f.ctrl.deinitIndexState(&empty);
    var dump: std.ArrayList(u8) = .empty;
    defer dump.deinit(std.testing.allocator);
    try f.ctrl.dumpIndexState(&empty, &dump);

    const snapshot_path = try wal.snapshotPath(std.testing.allocator, dir, host, index, 0x10);
    defer std.testing.allocator.free(snapshot_path);
    try writeFileBytes(snapshot_path, dump.items);

    // The line names a WAL that was never created: the raw open error is the
    // startup fatality, never a repair.
    const wal_path = try wal.walPath(std.testing.allocator, dir, host, index, 0x10);
    defer std.testing.allocator.free(wal_path);
    try f.ctrl.rewriteRegistry(index, .{
        .host_idx = host,
        .snapshot_path = snapshot_path,
        .wal_path = wal_path,
        .state = 0x20,
    });

    var st: state.IndexState = undefined;
    try f.ctrl.initIndexState(&st);
    defer f.ctrl.deinitIndexState(&st);

    const ring_idx: u16 = f.cfg.fronts;
    try f.ctrl.initRing(ring_idx, 1);
    defer f.ctrl.rings[ring_idx].deinit();
    const logger = try f.ctrl.getLogger(ring_idx);
    defer {
        logger.deinit(f.ctrl.allocator);
        f.ctrl.allocator.destroy(logger);
    }

    try std.testing.expectError(
        error.FileNotFound,
        recoverPair(&f.ctrl, &f.ctrl.rings[ring_idx], logger, index, host, &st),
    );
}

// ============================================================================
// Stage J: the end-to-end gate and the PMEM-shape crash matrix
// ============================================================================

/// Steps the thread's own completions until `writer` has no flush in flight and
/// none parked: the standalone pair writer's version of the window drain.
fn drainWriterQuiet(frame: *Frame, writer: *wal.WalWriteFile) void {
    while (writer.flush_in_flight or writer.flush_pending) {
        retryParkedFlush(writer);
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

    // The barrier is tiny, so the first records fire the tick; the interval is
    // irrelevant because the test calls `tickPass` directly.
    var cfg = testConfig(dir, 1, 1, .{ .size_barrier = 1, .interval_s = 3600, .slots = 2, .registry_keep = 8 });
    const states = [_]u128{ 0x101, 0x102, 0x103, 0x104, 0x105 };
    const old_tag: u128 = 0x100;
    const elephant_ring: u16 = cfg.fronts + cfg.indexes;

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

        var sets = [_]state.IndexState{undefined};
        try ctrl.initIndexState(&sets[0]);
        defer ctrl.deinitIndexState(&sets[0]);

        // The pre-procedure pair: a WAL under an earlier tag, serving through
        // the index's own ring, exactly as the loop wires it.
        const pair = try openPairWriter(&ctrl, 0, 0, old_tag);
        pair.attachStream(&ctrl.rings[1].sqstream, &ctrl.rings[1].slots);

        var frame = testFrame(&ctrl, 1, logger, &sets);
        const slots_full = ctrl.snapshot_slots.freeCount();

        var ops: [states.len][e2e_op_len]u8 = undefined;
        for (&ops, 0..) |*op, i| {
            for (op, 0..) |*byte, j| byte.* = @truncate(j *% 17 +% i *% 11 +% 1);
        }

        // Two records before the tick.
        var i: usize = 0;
        while (i < 2) : (i += 1) {
            try pair.write(states[i], pair.head, &ops[i]);
            sets[0].state = states[i];
            try ctrl.applyIndexOp(&sets[0], .{ .create = .{ .compensator = "marker", .payload = &ops[i] } });
        }
        drainWriterQuiet(&frame, pair);
        try testing.expectEqual(@as(u128, states[1]), sets[0].state);

        // The tick: the pair is over the barrier and its state is the tag X.
        tickPass(&frame);
        const job = frame.procedure orelse return error.SnapshotNotStarted;
        var job_live = true;
        defer if (job_live) dropTestJob(&ctrl, job);
        try testing.expectEqual(@as(u128, states[1]), job.tag);

        // The pair keeps serving between the tick and the create reply: the
        // clone state Y is ahead of the name tag X.
        try pair.write(states[2], pair.head, &ops[2]);
        sets[0].state = states[2];
        try ctrl.applyIndexOp(&sets[0], .{ .create = .{ .compensator = "marker", .payload = &ops[2] } });
        drainWriterQuiet(&frame, pair);

        // F1, the real handler: the create request's slot is released on read.
        const create_cqe = cqeBefore(&ctrl.rings[elephant_ring].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
            return error.SnapshotDispatchTimeout;
        try testing.expectEqual(messages.CrossTaskMessageIdx, create_cqe.taskIdx());
        const create_slot: u32 = @intCast(create_cqe.res);
        try testing.expectEqual(@intFromPtr(job), ctrl.cross_slots.at(create_slot).SnapshotCreate.job);
        ctrl.cross_slots.release(create_slot);
        elephant.createSnapshot(&ctrl, job, &logger.logger);
        saved_wal = try allocator.dupeSentinel(u8, job.wal_path, 0);
        saved_snapshot = try allocator.dupeSentinel(u8, job.snapshot_path, 0);
        saved_k = job.k;

        // The fd reply lands on the index ring; the ordinary dispatch runs the
        // handler pass: mark, clone, adopt, composite, dump dispatch.
        const fd_cqe = cqeBefore(&ctrl.rings[1].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
            return error.SnapshotReplyTimeout;
        stepCQE(&frame, fd_cqe);
        const window = &(frame.window orelse return error.SnapshotWindowMissing);
        try testing.expectEqual(@as(u128, states[2]), job.clone.state);

        // One window event: new first, then old, both through the ring.
        try window.write(states[3], &ops[3]);
        drainUntilQuiet(&frame);
        try testing.expect(window.quiet());
        try testing.expectEqual(@as(u128, states[3]), window.new.head);
        try testing.expectEqual(@as(u128, states[3]), window.old.head);

        // F2, the real handler: the dump, the registry commit and the reply.
        const dump_cqe = cqeBefore(&ctrl.rings[elephant_ring].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
            return error.SnapshotDispatchTimeout;
        const dump_slot: u32 = @intCast(dump_cqe.res);
        try testing.expectEqual(@intFromPtr(job), ctrl.cross_slots.at(dump_slot).SnapshotDump.job);
        ctrl.cross_slots.release(dump_slot);
        elephant.dumpSnapshot(&ctrl, job, &logger.logger, elephant_ring);

        // The completion: the drain, the copy, the clear, the revival and the
        // close dispatch.
        const dumped_cqe = cqeBefore(&ctrl.rings[1].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
            return error.SnapshotReplyTimeout;
        stepCQE(&frame, dumped_cqe);
        try testing.expect(frame.window == null);
        try testing.expectEqual(lifetime.SnapshotPhase.close_sent, job.phase);

        // F3, the real handler: the old fd's close and the terminal reply.
        const close_cqe = cqeBefore(&ctrl.rings[elephant_ring].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
            return error.SnapshotDispatchTimeout;
        const close_slot: u32 = @intCast(close_cqe.res);
        try testing.expectEqual(@intFromPtr(job), ctrl.cross_slots.at(close_slot).SnapshotClose.job);
        ctrl.cross_slots.release(close_slot);
        elephant.closeSnapshot(&ctrl, job, &logger.logger);
        job_live = false;

        const done_cqe = cqeBefore(&ctrl.rings[1].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
            return error.SnapshotReplyTimeout;
        stepCQE(&frame, done_cqe);
        try testing.expect(frame.procedure == null);

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
        const snapshot_bytes = try readWholeFile(allocator, saved_snapshot.?);
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
        try registered.write(states[4], registered.head, &ops[4]);
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

        try recoverPair(&ctrl, &ctrl.rings[1], logger, 0, 0, &st);

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

    try recoverPair(&f.ctrl, &f.ctrl.rings[ring_idx], logger, index, host, &st);

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

    try recoverPair(&f.ctrl, &f.ctrl.rings[ring_idx], logger, index, host, &st);

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
    frame.procedure = job;
    frame.window = .{ .new = new, .old = old, .allocator = ctrl.allocator };
    try ctrl.publishAdoptionMark(0, 0, k, 0x100);

    var op = j2Op(0x101);
    try frame.window.?.write(0x101, &op);
    try testing.expect(old.flush_in_flight and new.flush_in_flight);

    // The old side faults mid-window: the front freezes, the window serves on.
    old.faulted = true;
    onWriterFault(old, &frame);
    try testing.expectEqual(WalServe.frozen, frame.wal_serve);

    // The completion pass's bounded drain steps the real flushes before the
    // copy; the swap retires the faulted writer and revives the front.
    snapshotDumpedPass(&frame);
    try testing.expect(frame.window == null);
    try testing.expectEqual(WalServe.serving, frame.wal_serve);
    try testing.expectEqual(lifetime.SnapshotPhase.close_sent, job.phase);

    const close_cqe = cqeBefore(&ctrl.rings[2].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
        return error.SnapshotDispatchTimeout;
    const close_slot: u32 = @intCast(close_cqe.res);
    try testing.expectEqual(@intFromPtr(job), ctrl.cross_slots.at(close_slot).SnapshotClose.job);
    ctrl.cross_slots.release(close_slot);
    elephant.closeSnapshot(&ctrl, job, &logger.logger);
    job_live = false;

    const done_cqe = cqeBefore(&ctrl.rings[1].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
        return error.SnapshotReplyTimeout;
    stepCQE(&frame, done_cqe);
    try testing.expect(frame.procedure == null);

    // A relapse after the swap finds no window and stops terminally.
    const live = ctrl.wal_writers[0].?;
    live.faulted = true;
    onWriterFault(live, &frame);
    try testing.expectEqual(WalServe.stopped, frame.wal_serve);
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
    frame.procedure = job;
    frame.window = .{ .new = new, .old = old, .allocator = ctrl.allocator };
    try ctrl.publishAdoptionMark(0, 0, k, 0x100);

    var op = j2Op(0x101);
    try frame.window.?.write(0x101, &op);

    // A new-side flush fault is the ordinary terminal stop; ticks skip the
    // thread, but the procedure still completes on the control plane (rung 10).
    new.faulted = true;
    onWriterFault(new, &frame);
    try testing.expectEqual(WalServe.stopped, frame.wal_serve);

    snapshotDumpedPass(&frame);
    try testing.expect(frame.window == null);
    try testing.expectEqual(lifetime.SnapshotPhase.close_sent, job.phase);

    // The final close lands and the terminal reply clears the flag. The stop
    // stands: no swap revives a stopped thread.
    const close_cqe = cqeBefore(&ctrl.rings[2].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
        return error.SnapshotDispatchTimeout;
    ctrl.cross_slots.release(@intCast(close_cqe.res));
    elephant.closeSnapshot(&ctrl, job, &logger.logger);
    job_live = false;

    const done_cqe = cqeBefore(&ctrl.rings[1].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
        return error.SnapshotReplyTimeout;
    stepCQE(&frame, done_cqe);
    try testing.expect(frame.procedure == null);
    try testing.expectEqual(WalServe.stopped, frame.wal_serve);
}

test "a failed registry rename leaves the old line winning and recovery-correct" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(dir);

    var cfg = testConfig(dir, 1, 1, .{ .size_barrier = 1, .interval_s = 3600, .slots = 2, .registry_keep = 8 });
    const old_tag: u128 = 0x100;
    const states = [_]u128{ 0x101, 0x102, 0x103, 0x104 };
    const elephant_ring: u16 = cfg.fronts + cfg.indexes;

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
        fixed_registry = try readWholeFile(allocator, registry_path);

        var frame = testFrame(&ctrl, 1, logger, &sets);
        var ops: [states.len][j2_op_len]u8 = undefined;
        for (&ops, 0..) |*op, i| op.* = j2Op(states[i]);

        var i: usize = 0;
        while (i < 2) : (i += 1) {
            try pair.write(states[i], pair.head, &ops[i]);
            sets[0].state = states[i];
            try ctrl.applyIndexOp(&sets[0], .{ .create = .{ .compensator = "marker", .payload = &ops[i] } });
        }
        drainWriterQuiet(&frame, pair);

        tickPass(&frame);
        const job = frame.procedure orelse return error.SnapshotNotStarted;
        var job_live = true;
        defer if (job_live) dropTestJob(&ctrl, job);

        try pair.write(states[2], pair.head, &ops[2]);
        sets[0].state = states[2];
        try ctrl.applyIndexOp(&sets[0], .{ .create = .{ .compensator = "marker", .payload = &ops[2] } });
        drainWriterQuiet(&frame, pair);

        const create_cqe = cqeBefore(&ctrl.rings[elephant_ring].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
            return error.SnapshotDispatchTimeout;
        ctrl.cross_slots.release(@intCast(create_cqe.res));
        elephant.createSnapshot(&ctrl, job, &logger.logger);

        const fd_cqe = cqeBefore(&ctrl.rings[1].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
            return error.SnapshotReplyTimeout;
        stepCQE(&frame, fd_cqe);

        try frame.window.?.write(states[3], &ops[3]);
        drainUntilQuiet(&frame);

        // The rewrite's pending write succeeds; the rename is where it fails.
        ctrl.test_fail_registry_rename = true;
        const dump_cqe = cqeBefore(&ctrl.rings[elephant_ring].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
            return error.SnapshotDispatchTimeout;
        ctrl.cross_slots.release(@intCast(dump_cqe.res));
        elephant.dumpSnapshot(&ctrl, job, &logger.logger, elephant_ring);
        ctrl.test_fail_registry_rename = false;

        const abandon_cqe = cqeBefore(&ctrl.rings[1].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
            return error.SnapshotReplyTimeout;
        stepCQE(&frame, abandon_cqe);

        // Unwind B: the window reverts, the new writer closes and cleanup is
        // dispatched. The committed line never changed.
        try testing.expect(frame.window == null);
        try testing.expectEqual(lifetime.SnapshotPhase.cleanup_sent, job.phase);
        try testing.expect(pairControlLine(&ctrl).snapshot_in_progress == 0);

        const cleanup_cqe = cqeBefore(&ctrl.rings[elephant_ring].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
            return error.SnapshotDispatchTimeout;
        ctrl.cross_slots.release(@intCast(cleanup_cqe.res));
        elephant.cleanupSnapshot(&ctrl, job, &logger.logger);
        job_live = false;

        const done_cqe = cqeBefore(&ctrl.rings[1].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
            return error.SnapshotReplyTimeout;
        stepCQE(&frame, done_cqe);
        try testing.expect(frame.procedure == null);

        // The pending staging file is junk; the fixed registry still carries
        // the old line, byte for byte.
        const pending = try ctrl.registryPendingPath(0);
        defer allocator.free(pending);
        try testing.expect(fileExists(pending));
        const after_registry_path = try ctrl.registryPath(0);
        defer allocator.free(after_registry_path);
        const after = try readWholeFile(allocator, after_registry_path);
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

        try recoverPair(&ctrl, &ctrl.rings[1], logger, 0, 0, &st);

        try testing.expectEqual(@as(u128, states[3]), st.state);
        try testing.expectEqual(states.len, st.sessions.count());
        var reference = try j2State(&ctrl, &states);
        defer ctrl.deinitIndexState(&reference);
        try expectSameSessions(&reference, &st);
    }
}
