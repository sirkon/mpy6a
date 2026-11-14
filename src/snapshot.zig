//! Snapshot control plane: the procedure's finite state machine, its tick pass,
//! the dispatch and reply passes, the drain and swap, the failure ladder and the
//! startup recovery (designs/snapshot-refactor.md).
//!
//! This file owns policy only. Every resource it touches — the slot pool, the
//! adoption marks, the descriptors, the registry — stays on `lifetime.Controller`
//! and the job stays a `lifetime.SnapshotJob`. The import rule is one-way:
//! `snapshot.zig` may import `lifetime.zig`; `lifetime.zig` must never import
//! this file.

const std = @import("std");
const posix = std.posix;
const zigring = @import("zigring");
const config = @import("config.zig");
const lifetime = @import("lifetime.zig");
const logging = @import("logging.zig");
const messages = @import("messages.zig");
const state = @import("state.zig");
const wal = @import("wal.zig");
const cross_task = @import("cross_task.zig");

/// How this thread serves its pairs' write side (designs/SNAPSHOTS.md §4).
///
/// The front intake is denied whenever the state is not `serving`; the control
/// plane (reserved `taskIdx` traffic and cross-task slots) always flows.
/// `frozen` is the window's old-side refusal (§5), `stopped` the terminal
/// WAL fault.
pub const Serve = enum { serving, frozen, stopped };

/// One refused index→elephant `MSG_RING`: the slot is already acquired and its
/// payload written, so only the push itself is retried (§4).
pub const PendingPush = struct { slot_idx: u32, target_ring_idx: u16 };

/// What the quiescent drain continues with. `Job.phase` stays `dump_sent`
/// while this is set; the phase names the wire step, not the pump.
pub const Drain = enum { swap, revert };

/// The window's write interface (designs/SNAPSHOTS.md §3.2 step 4, §5).
///
/// Every event is written **new first, then old**, and is complete — durable,
/// replyable — only when both sides' flushes have covered it. `new` is the temp
/// ring `k` writer the procedure adopted; `old` is the pair area's writer,
/// which stays registered for the window's duration.
pub const CompositeWriter = struct {
    new: *wal.WalWriteFile,
    old: *wal.WalWriteFile,
    /// The completion queue: one entry per event both sides accepted, in write
    /// order. Completed events leave from the head, so the list is a FIFO.
    pending: std.ArrayList(PendingEvent) = .empty,
    /// The side the last refused write refused on; `null` when it was
    /// accepted. The index's refusal classifier reads it (§5): the old side's
    /// refusal freezes the front, the new side's is the ordinary stop or a
    /// protocol answer.
    failed_side: ?Side = null,
    /// Owns `pending` — the controller's allocator.
    allocator: std.mem.Allocator,

    const PendingEvent = struct { end_new: u64, end_old: u64 };

    pub const Side = enum { new, old };

    pub const Completed = struct {
        /// Events that left the FIFO head on this call.
        count: usize = 0,
        /// Pair-side (`old`) end offset of the last completed event.
        last_end: ?u64 = null,
    };

    /// Appends one event: new first, then old (§3.2 step 4).
    ///
    /// The order is load-bearing: the new WAL is the committed future and the
    /// old one the pre-commit fallback, so when the old side refuses the event
    /// is already in the new file. Each side chains from its own head — both
    /// sit at the clone state `Y` — and only an event both sides accepted is
    /// queued, because only that event can ever be complete.
    pub fn write(self: *CompositeWriter, new_state_idx: u128, data: []u8) wal.WalError!void {
        self.failed_side = null;

        self.new.write(new_state_idx, self.new.head, data) catch |err| {
            self.failed_side = .new;
            return err;
        };
        const end_new = self.new.trackedExtent();

        self.old.write(new_state_idx, self.old.head, data) catch |err| {
            self.failed_side = .old;
            return err;
        };
        const end_old = self.old.trackedExtent();

        try self.pending.append(self.allocator, .{ .end_new = end_new, .end_old = end_old });
    }

    /// Reports every FIFO-head event both sides' flushes have covered (§5).
    ///
    /// `writer` names the side whose flush just completed; both frontiers are
    /// consulted on every call, because an event is complete — durable,
    /// replyable — only once **both** have reached it. Either single-side rule
    /// would lose durable events in one of the two crash outcomes. `last_end`
    /// is the last completed event's pair-side end offset: the byte after its
    /// last byte in the old file's extent.
    pub fn noteFlush(self: *CompositeWriter, writer: *wal.WalWriteFile) Completed {
        std.debug.assert(writer == self.new or writer == self.old);
        const new_limit = self.new.flushed_upto * self.new.lba;
        const old_limit = self.old.flushed_upto * self.old.lba;

        var completed = Completed{};
        while (completed.count < self.pending.items.len) : (completed.count += 1) {
            const event = self.pending.items[completed.count];
            if (event.end_new > new_limit or event.end_old > old_limit) break;
            completed.last_end = event.end_old;
        }
        if (completed.count == 0) return completed;

        const rest = self.pending.items.len - completed.count;
        std.mem.copyForwards(PendingEvent, self.pending.items[0..rest], self.pending.items[completed.count..]);
        self.pending.shrinkRetainingCapacity(rest);
        return completed;
    }

    /// Both writers quiet: no flush in flight and none parked (§3.4). At most
    /// one flush is ever in flight per writer, so the drain that waits for this
    /// is bounded.
    pub fn quiet(self: *const CompositeWriter) bool {
        return !self.new.flush_in_flight and !self.new.flush_pending and
            !self.old.flush_in_flight and !self.old.flush_pending;
    }
};

/// The resource bundle a driver entry point may touch. It carries no behaviour,
/// no context pointer and no function pointer; it is passed by value everywhere.
pub const Host = struct {
    ctrl: *lifetime.Controller,
    ring: *lifetime.RingStuff,
    log: *logging.Logger,
    ring_idx: u16,
    index_idx: u16,
    data_sets: []state.IndexState,
};

/// The procedure's policy state: what the index frame's snapshot side owns.
pub const State = struct {
    serve: Serve = .serving,
    procedure: ?*lifetime.SnapshotJob = null,
    pending_push: ?PendingPush = null,
    window: ?CompositeWriter = null,
    ticks: u32 = 0,
    drain: ?Drain = null,

    /// One tick of the snapshot ticker (§1.2).
    pub fn onTick(self: *State, host: Host) void {
        self.tickPass(host);
    }

    /// Dispatches one elephant→index reply by variant (§3.4).
    ///
    /// `SnapshotDone` is the terminal reply: the in-flight flag clears here,
    /// which enforces the one-operation rule to the true end of the procedure.
    /// The create reply opens the window, the dump's completion arms the swap,
    /// and the two failure replies arm the revert.
    pub fn onReply(self: *State, host: Host, task: cross_task.CrossTask) void {
        const log = host.log;

        // A continuation is already running: a second completion of the same
        // wire event must not re-enter a half-finished transition. The pump is
        // the only reader that finishes it, and it clears the continuation
        // first.
        if (self.drain != null) {
            log.warn("index ignored a snapshot reply while a drain is pending", .{
                .ring_idx = host.ring_idx,
            });
            return;
        }

        switch (task) {
            .SnapshotFd => |reply| self.fdPass(host, reply.fd),
            .SnapshotDumped => self.beginSwap(host),
            .SnapshotCreateFailed => {
                // Rung 2: the handler pass never ran, so the unwind is markless.
                const job = self.procedure orelse {
                    log.warn("snapshot create failure without a procedure", .{ .ring_idx = host.ring_idx });
                    return;
                };
                self.unwindA(host, job, .{ .mark_published = false, .writer_built = null });
            },
            .SnapshotDumpFailed, .SnapshotAbandon => {
                // Rungs 5 and 6: the dump or its registry line failed after the
                // arena reset; the window reverts to the old writer.
                const job = self.procedure orelse {
                    log.warn("snapshot failure reply without a procedure", .{ .ring_idx = host.ring_idx });
                    return;
                };
                self.beginRevert(host, job);
            },
            .SnapshotDone => {
                self.procedure = null;
            },
            else => log.warn("index read a cross-task message it does not handle", .{
                .ring_idx = host.ring_idx,
            }),
        }
    }

    /// The `SnapshotFd` reply's pass: mark, clone, adopt, composite, re-dispatch
    /// (§3.2). One synchronous pass — no front message is processed inside it,
    /// so nothing slips between its steps.
    fn fdPass(self: *State, host: Host, fd: posix.fd_t) void {
        const log = host.log;
        const job = self.procedure orelse {
            // Defensive: the one-procedure invariant makes this unreachable, and
            // the descriptor would leak if it were dropped.
            log.warn("snapshot fd reply without a procedure; closing the descriptor", .{
                .ring_idx = host.ring_idx,
                .fd = fd,
            });
            _ = std.os.linux.close(fd);
            return;
        };

        // The index owns the descriptor from here on; the job is its one owner.
        job.fd = fd;
        const host_idx = job.host_idx;
        const index_idx = job.index_idx;

        // Step 1: the mark. Publishing after the create reply and before the
        // composite serves widens the guarded window — every crash from here to
        // the swap lands in one of the two restart branches (§3.5).
        host.ctrl.publishAdoptionMark(host_idx, index_idx, job.k, job.tag) catch |err| {
            log.err("snapshot mark publish failed; unwinding", .{
                .ring_idx = host.ring_idx,
                .host_idx = host_idx,
                .index_idx = index_idx,
                .err = @errorName(err),
            });
            self.unwindA(host, job, .{ .mark_published = false, .writer_built = null });
            return;
        };

        // Step 2: the clone. Any hosted pair is a snapshot subject, own or
        // mirror (§1.2). Its state is `Y`, at or ahead of the tag `X`: the pair
        // kept serving, so there is no pin. Rung 3 unwinds quietly.
        job.clone = host.ctrl.cloneIndexState(&host.data_sets[host_idx], job.arena.allocator()) catch |err| {
            log.warn("snapshot clone allocation failed; unwinding", .{
                .ring_idx = host.ring_idx,
                .host_idx = host_idx,
                .index_idx = index_idx,
                .err = @errorName(err),
            });
            self.unwindA(host, job, .{ .mark_published = true, .writer_built = null });
            return;
        };

        // Step 3: the adopt. Temp ring `k` is minted, the writer opens over the
        // transferred fd, publishes the ordinal-0 terminator carrying `Y` and
        // chains from it. Rung 4 is memory-only.
        const new_writer = host.ctrl.walAdoptWrite(host_idx, index_idx, job.k, job.clone.state, job.fd) catch |err| {
            // The adopt owns the descriptor from the moment it is called and
            // closes it on every failure path, so the job must not hand a stale
            // number to the cleanup elephant.
            job.fd = -1;
            log.warn("snapshot adopt failed; unwinding", .{
                .ring_idx = host.ring_idx,
                .host_idx = host_idx,
                .index_idx = index_idx,
                .err = @errorName(err),
            });
            self.unwindA(host, job, .{ .mark_published = true, .writer_built = null });
            return;
        };
        // The writer owns the descriptor now.
        job.fd = -1;
        new_writer.attachStream(&host.ring.sqstream, &host.ring.slots);

        // Step 4: the composite. The pair's write interface is new-first, then
        // old, for the window's duration; the old writer stays registered.
        const pair = wal.areaIndex(host_idx, index_idx, host.ctrl.cfg.wal.hosts());
        const old_writer = host.ctrl.wal_writers[pair] orelse {
            // No pair writer to fall back to: a bug, and the only rung the
            // design does not name. Tear the new writer down and unwind quietly.
            log.err("snapshot adopt found no pair writer; unwinding", .{
                .ring_idx = host.ring_idx,
                .host_idx = host_idx,
                .index_idx = index_idx,
            });
            new_writer.close() catch {};
            host.ctrl.allocator.destroy(new_writer);
            self.unwindA(host, job, .{ .mark_published = true, .writer_built = null });
            return;
        };
        self.window = .{
            .new = new_writer,
            .old = old_writer,
            .allocator = host.ctrl.allocator,
        };

        // Step 5: cursor pick 2. A refused push parks in the pending op and the
        // pass ends — the window keeps serving.
        job.phase = .dump_sent;
        self.dispatch(host, .{ .SnapshotDump = .{ .job = @intFromPtr(job) } }, host.ctrl.nextElephantRing());
    }

    /// The tick never queues and never retries: a skip simply ends the pass. The
    /// candidates are every pair this thread hosts — own data set and mirrors
    /// alike — and the metric is the live writer's tracked extent.
    fn tickPass(self: *State, host: Host) void {
        self.ticks +%= 1;

        // Rung 10: a stopped thread's files do not grow, and a window or a
        // pending push is one operation already in flight (§1.2, §4).
        if (self.serve != .serving) return;
        if (self.procedure != null) return;
        if (self.pending_push != null) return;

        const hosts = host.ctrl.cfg.wal.hosts();
        const barrier = host.ctrl.cfg.snapshots.size_barrier.value();
        var best_host: u8 = 0;
        var best_extent: u64 = 0;
        var found = false;
        var host_idx: u32 = 0;
        while (host_idx < hosts) : (host_idx += 1) {
            const idx: u8 = @intCast(host_idx);
            const pair = wal.areaIndex(idx, host.index_idx, hosts);
            const writer = host.ctrl.wal_writers[pair] orelse continue;
            const extent = writer.trackedExtent();
            if (!found or extent > best_extent) {
                found = true;
                best_host = idx;
                best_extent = extent;
            }
        }
        if (!found or best_extent < barrier) return;

        // The tag: the pair's state at this moment, fixed for the procedure (§2.3).
        const tag = host.data_sets[best_host].state;

        // Rung 0: the process-wide limit is the design working, not a failure.
        const k = host.ctrl.snapshot_slots.acquire() catch return;
        const job = host.ctrl.mintSnapshotJob(best_host, host.index_idx, tag, k, host.ring_idx) catch |err| {
            // A quiet unwind-before-start: nothing was dispatched, and the tick
            // retries on its own schedule.
            host.ctrl.snapshot_slots.release(k);
            host.log.warn("snapshot job allocation failed; the tick ends", .{
                .ring_idx = host.ring_idx,
                .host_idx = best_host,
                .err = @errorName(err),
            });
            return;
        };

        host.ctrl.snapshot_slots.at(k).* = .{ .status = .in_flight, .job = @intFromPtr(job) };
        self.procedure = job;
        self.dispatch(host, .{ .SnapshotCreate = .{ .job = @intFromPtr(job) } }, host.ctrl.nextElephantRing());
    }

    /// Sends one snapshot payload to an elephant ring through the ordinary
    /// `cross_slots` pool (§3.1).
    ///
    /// A refused push never drops and never spins: the slot stays acquired with
    /// its payload written and the loop retries the `MSG_RING` once per pass (§4).
    pub fn dispatch(self: *State, host: Host, payload: cross_task.CrossTask, target_ring_idx: u16) void {
        const slot_idx = host.ctrl.cross_slots.acquire() catch |err| {
            host.log.err("snapshot dispatch found no cross-task slot", .{
                .ring_idx = host.ring_idx,
                .target_ring_idx = target_ring_idx,
                .err = @errorName(err),
            });
            return;
        };
        host.ctrl.cross_slots.at(slot_idx).* = payload;
        host.ring.ring.pushMsgRingFd(
            host.ctrl.rings[target_ring_idx].ring.fd,
            messages.CrossTaskMessageIdx,
            slot_idx,
            .{},
        ) catch |err| switch (err) {
            error.RingFull => {
                self.pending_push = .{ .slot_idx = slot_idx, .target_ring_idx = target_ring_idx };
                return;
            },
        };
        self.resync(host);
    }

    /// Re-captures the ring's WAL stream window after a direct submission (§4).
    ///
    /// The two submission paths share one SQ: a direct `MSG_RING` moves the
    /// ring's tail past the stream's cursor, and the stream's next commit would
    /// rewind it. The window's flushes and the procedure's dispatches both run
    /// on this ring, so the cursors are re-captured as the ring's own.
    pub fn resync(_: *State, host: Host) void {
        host.ring.ring.streamedSQ(&host.ring.sqstream);
    }

    /// Retries the pending push, if any. Called once at the top of every loop
    /// pass: the slot is already acquired and written, so only the `MSG_RING`
    /// repeats.
    pub fn retryPending(self: *State, host: Host) void {
        const pending = self.pending_push orelse return;
        host.ring.ring.pushMsgRingFd(
            host.ctrl.rings[pending.target_ring_idx].ring.fd,
            messages.CrossTaskMessageIdx,
            pending.slot_idx,
            .{},
        ) catch return;
        self.pending_push = null;
        self.resync(host);
    }

    /// A continuation is armed: the pump owns the next step.
    pub fn drainPending(self: *const State) bool {
        return self.drain != null;
    }

    /// The `SnapshotDumped` reply's first half: validate the window and arm the
    /// swap continuation (§3.3). No I/O, and no completion is read here.
    fn beginSwap(self: *State, host: Host) void {
        const log = host.log;
        const job = self.procedure orelse {
            log.warn("snapshot completion without a procedure", .{ .ring_idx = host.ring_idx });
            return;
        };
        if (self.window == null) {
            log.err("snapshot completion found no window; cleaning up", .{
                .ring_idx = host.ring_idx,
                .host_idx = job.host_idx,
                .index_idx = job.index_idx,
            });
            host.ctrl.snapshot_slots.at(job.k).status = .rollback;
            job.phase = .cleanup_sent;
            self.dispatch(host, .{ .SnapshotCleanup = .{ .job = @intFromPtr(job) } }, host.ctrl.nextElephantRing());
            return;
        }

        self.drain = .swap;
    }

    /// Unwind B's first half (§8): the composite is installed — the dump failed
    /// or its registry line did.
    ///
    /// Validate the window and arm the revert continuation; no completion is
    /// read here. A frozen thread stays frozen: the failed procedure brings no
    /// swap, so no revival is coming (§5, §8 rung 10).
    fn beginRevert(self: *State, host: Host, job: *lifetime.SnapshotJob) void {
        if (self.window == null) {
            // No window to revert: nothing was installed, but the procedure's
            // files and slot still need their terminal elephant.
            host.ctrl.snapshot_slots.at(job.k).status = .rollback;
            job.phase = .cleanup_sent;
            self.dispatch(host, .{ .SnapshotCleanup = .{ .job = @intFromPtr(job) } }, host.ctrl.nextElephantRing());
            return;
        }

        self.drain = .revert;
    }

    /// The swap's second half, run by the pump once both writers are quiet (§3.4).
    ///
    /// Memory only and unable to fail in its defined steps: the copy, the clear,
    /// the revival and the retirement. Its crash cases are §3.5's table, which
    /// the mark and the copy's idempotence already cover.
    fn finishSwap(self: *State, host: Host) void {
        const log = host.log;
        const job = self.procedure orelse {
            log.warn("snapshot completion without a procedure", .{ .ring_idx = host.ring_idx });
            return;
        };

        const pair = wal.areaIndex(job.host_idx, job.index_idx, host.ctrl.cfg.wal.hosts());
        const window = if (self.window) |*w| w else {
            log.err("snapshot completion found no window; cleaning up", .{
                .ring_idx = host.ring_idx,
                .host_idx = job.host_idx,
                .index_idx = job.index_idx,
            });
            host.ctrl.snapshot_slots.at(job.k).status = .rollback;
            job.phase = .cleanup_sent;
            self.dispatch(host, .{ .SnapshotCleanup = .{ .job = @intFromPtr(job) } }, host.ctrl.nextElephantRing());
            return;
        };

        // Step 1: the copy of temp ring `k`'s data and header arrays, then the
        // rewire. The areas are geometrically identical, so the surviving writer
        // only changes addresses; its ordinals and cursor continue unchanged.
        const area = host.ctrl.copyTempIntoPair(pair, job.k) catch |err| {
            log.err("snapshot swap copy failed; unwinding", .{
                .ring_idx = host.ring_idx,
                .host_idx = job.host_idx,
                .index_idx = job.index_idx,
                .err = @errorName(err),
            });
            self.drain = .revert;
            return;
        };
        window.new.data = area.data;
        window.new.headers = area.headers;

        // Step 2: the clear. The mark is over; the pair area is the new chain.
        host.ctrl.clearAdoptionMark(job.host_idx, job.index_idx) catch |err| {
            log.err("snapshot mark clear failed", .{
                .ring_idx = host.ring_idx,
                .host_idx = job.host_idx,
                .index_idx = job.index_idx,
                .err = @errorName(err),
            });
        };

        // Step 3: revival, if the old side had frozen the front (§5). It is
        // computed from live writers only, and the old one is about to retire.
        self.revive(host);

        // Step 4: the retirement and the final close. The old writer is quiet;
        // its descriptor moves to the terminal elephant and the object dies
        // without a close. The index stops dereferencing the job here; the flag
        // clears on `SnapshotDone`.
        const new_writer = window.new;
        const old_writer = window.old;
        job.old_fd = old_writer.fd;
        host.ctrl.allocator.destroy(old_writer);
        host.ctrl.wal_writers[pair] = new_writer;
        window.pending.deinit(host.ctrl.allocator);
        self.window = null;

        job.phase = .close_sent;
        self.dispatch(host, .{ .SnapshotClose = .{ .job = @intFromPtr(job) } }, host.ctrl.nextElephantRing());
    }

    /// The revert's second half, run by the pump once both writers are quiet
    /// (§3.4). Close the new writer, clear the mark, roll the slot back and
    /// dispatch cleanup.
    fn finishRevert(self: *State, host: Host) void {
        const log = host.log;
        const job = self.procedure orelse {
            log.warn("snapshot failure reply without a procedure", .{ .ring_idx = host.ring_idx });
            return;
        };
        var window = self.window orelse return;
        self.window = null;

        // The close is safe precisely because the drain made the writer quiet.
        // The descriptor comes back through the sentinel: after the close the
        // writer holds `-1`, so the job's field does too.
        window.new.close() catch |err| {
            log.warn("snapshot unwind close failed", .{
                .ring_idx = host.ring_idx,
                .host_idx = job.host_idx,
                .index_idx = job.index_idx,
                .err = @errorName(err),
            });
        };
        job.fd = window.new.fd;
        window.pending.deinit(host.ctrl.allocator);
        host.ctrl.allocator.destroy(window.new);

        host.ctrl.clearAdoptionMark(job.host_idx, job.index_idx) catch |err| {
            log.err("snapshot mark clear failed", .{
                .ring_idx = host.ring_idx,
                .host_idx = job.host_idx,
                .index_idx = job.index_idx,
                .err = @errorName(err),
            });
        };

        host.ctrl.snapshot_slots.at(job.k).status = .rollback;
        job.phase = .cleanup_sent;
        self.dispatch(host, .{ .SnapshotCleanup = .{ .job = @intFromPtr(job) } }, host.ctrl.nextElephantRing());
    }

    /// The two writers are quiet, or there is no window: the pump may continue.
    ///
    /// Not `close`'s `awaitFlush`: that retires and drops foreign completions,
    /// which mid-service would strand another pair's writer with its flush flag
    /// stuck. At most one flush is ever in flight per writer, and a parked
    /// submission is retried on every pass, so the loop terminates.
    pub fn drainQuiet(self: *State) bool {
        const window = if (self.window) |*w| w else return true;
        retryParkedFlush(window.new);
        retryParkedFlush(window.old);
        return window.quiet();
    }

    /// Runs the armed continuation: the pump cleared it before the terminal
    /// step, so a completion arriving during the step cannot re-enter it.
    pub fn onDrained(self: *State, host: Host) void {
        const mode = self.drain orelse return;
        self.drain = null;
        switch (mode) {
            .swap => self.finishSwap(host),
            .revert => self.finishRevert(host),
        }
    }

    /// The swap's revival rule (§5): the front reopens iff no **live** writer of
    /// the thread's pairs is faulted.
    ///
    /// The window's old writer is retiring, so it is not part of the live set:
    /// the frozen window's events were written new-first and the registry line
    /// is committed, which is exactly what makes serving safe again. A relapse
    /// after this finds no window and stops terminally.
    fn revive(self: *State, host: Host) void {
        if (self.serve != .frozen) return;

        const retiring = if (self.window) |*window| window.old else null;
        for (host.ctrl.wal_writers) |maybe_writer| {
            const writer = maybe_writer orelse continue;
            if (writer == retiring) continue;
            if (writer.faulted) return;
        }
        self.serve = .serving;
    }

    /// The `wal_flush` arm's window bookkeeping (§5): deliver every event both
    /// sides' flushes have covered. Production ignores the result; the tests
    /// assert it.
    pub fn onFlush(self: *State, host: Host, writer: *wal.WalWriteFile) void {
        _ = host;
        if (self.window) |*window| _ = window.noteFlush(writer);
    }

    /// The `wal_flush` arm's fault consequence (§5).
    ///
    /// A fault on the window's old side freezes the front: the migration can
    /// still finish on the new file, and the swap revives the thread. Everything
    /// else is the landed rule unchanged — a new-side fault, or any fault
    /// outside a window, stops the thread, and a relapse after revival finds
    /// `window == null` and stops terminally.
    pub fn onWriterFault(self: *State, host: Host, writer: *wal.WalWriteFile) void {
        if (!writer.faulted) return;

        if (self.window) |*window| {
            if (writer == window.old and self.serve != .stopped) {
                self.serve = .frozen;
                host.log.warn("the window's old WAL faulted; the front is frozen", .{
                    .ring_idx = host.ring_idx,
                    .host_idx = writer.host_idx,
                    .index_idx = writer.index_idx,
                });
                return;
            }
        }

        self.serve = .stopped;
        host.log.err("wal flush failed; the thread stops taking front work", .{
            .ring_idx = host.ring_idx,
            .host_idx = writer.host_idx,
            .index_idx = writer.index_idx,
        });
    }

    /// A read walk's terminal `IO` fault: the stop's second trigger (§5).
    pub fn onReadFault(self: *State) void {
        self.serve = .stopped;
    }

    /// Classifies a composite write's refusal (§5, §6).
    ///
    /// In a window, the old side's `WalFull` is exactly "cannot serve into the
    /// fallback" and freezes the front — the swap retires the old file shortly,
    /// so the freeze is brief. A fault on the new side is the ordinary terminal
    /// stop. `RecordTooLarge` and `WalGap` are protocol answers, never triggers,
    /// and pure submission backpressure parks in the pending op instead of
    /// returning.
    pub fn onWriteError(self: *State, host: Host, err: wal.WalError) void {
        if (err != error.WalFull and err != error.WalFaulted) return;

        const window = if (self.window) |*w| w else {
            if (err == error.WalFaulted) self.serve = .stopped;
            return;
        };
        if (self.serve == .stopped) return;

        if (window.failed_side == .old) {
            self.serve = .frozen;
            host.log.warn("the window's old side refused; the front is frozen", .{
                .ring_idx = host.ring_idx,
                .err = @errorName(err),
            });
            return;
        }

        if (err == error.WalFaulted) {
            self.serve = .stopped;
            host.log.err("the window's new side faulted; the thread stops", .{
                .ring_idx = host.ring_idx,
            });
        }
    }

    /// Unwind A (§8): the pre-composite rungs — create failure, clone
    /// allocation, adopt allocation.
    ///
    /// Memory only: a half-built writer object is destroyed (the adopt's failure
    /// path has already closed the descriptor it was handed) and the mark, if it
    /// was published, is cleared. The cleanup elephant owns the files, the
    /// descriptor and the slot from the dispatch on.
    fn unwindA(self: *State, host: Host, job: *lifetime.SnapshotJob, opts: UnwindOpts) void {
        if (opts.writer_built) |writer| host.ctrl.allocator.destroy(writer);

        if (opts.mark_published) {
            host.ctrl.clearAdoptionMark(job.host_idx, job.index_idx) catch |err| {
                host.log.err("snapshot mark clear failed", .{
                    .ring_idx = host.ring_idx,
                    .host_idx = job.host_idx,
                    .index_idx = job.index_idx,
                    .err = @errorName(err),
                });
            };
        }

        host.ctrl.snapshot_slots.at(job.k).status = .rollback;
        job.phase = .cleanup_sent;
        self.dispatch(host, .{ .SnapshotCleanup = .{ .job = @intFromPtr(job) } }, host.ctrl.nextElephantRing());
    }
};

/// The pre-composite unwind's inputs: whether the mark was already published
/// and whether a writer object was built before the failure.
const UnwindOpts = struct {
    mark_published: bool,
    writer_built: ?*wal.WalWriteFile,
};

/// The elephant-side half of the snapshot procedure: the file work behind the
/// four requests and the terminal replies. It owns no resource; every field is
/// borrowed from the controller that the elephant thread was started with.
pub const Elephant = struct {
    ctrl: *lifetime.Controller,
    log: *logging.Logger,
    ring_idx: u16,

    /// True iff `task` is a snapshot variant handled or deliberately warned
    /// about by this actor; false leaves it to the loop's ordinary arms.
    pub fn handle(self: *Elephant, task: cross_task.CrossTask) bool {
        switch (task) {
            .SnapshotCreate => |request| self.createSnapshot(jobOf(request.job)),
            .SnapshotDump => |request| self.dumpSnapshot(jobOf(request.job)),
            .SnapshotCleanup => |request| self.cleanupSnapshot(jobOf(request.job)),
            .SnapshotClose => |request| self.closeSnapshot(jobOf(request.job)),
            .SnapshotFd, .SnapshotCreateFailed, .SnapshotDumped, .SnapshotDumpFailed, .SnapshotAbandon, .SnapshotDone => {
                self.log.warn("elephant read a snapshot reply it does not handle", .{ .ring_idx = self.ring_idx });
            },
            .ShutdownDemand, .SoftShutdown, .ServerSocket, .IndexDrained => return false,
        }
        return true;
    }

    /// F1: creates the new WAL file under its final name.
    ///
    /// The truncate is load-bearing: a same-tag retry would otherwise reopen a
    /// file holding the failed attempt's flushed prefix, and that stale prefix
    /// would survive the plain-mode walk as if it were content. One
    /// `fdatasync` before the reply makes the empty length durable.
    pub fn createSnapshot(self: *Elephant, job: *lifetime.SnapshotJob) void {
        const ctrl = self.ctrl;
        const log = self.log;

        ctrl.ensureIndexDir(job.index_idx) catch |err| {
            log.err("snapshot create failed: the index directory is unavailable", .{
                .ring_idx = job.ring_idx,
                .index_idx = job.index_idx,
                .err = @errorName(err),
            });
            self.replyTo(job.ring_idx, .{ .SnapshotCreateFailed = .{} });
            return;
        };

        const fd_raw = std.os.linux.open(job.wal_path, .{
            .ACCMODE = .RDWR,
            .CREAT = true,
            .TRUNC = true,
        }, 0o644);
        const errno = std.os.linux.errno(fd_raw);
        if (errno != .SUCCESS) {
            log.err("snapshot create failed", .{
                .ring_idx = job.ring_idx,
                .host_idx = job.host_idx,
                .index_idx = job.index_idx,
                .err = @tagName(errno),
            });
            self.replyTo(job.ring_idx, .{ .SnapshotCreateFailed = .{} });
            return;
        }
        const fd: posix.fd_t = @intCast(fd_raw);

        const synced = std.os.linux.errno(std.os.linux.fdatasync(fd));
        if (synced != .SUCCESS) {
            _ = std.os.linux.close(fd);
            log.err("snapshot create sync failed", .{
                .ring_idx = job.ring_idx,
                .host_idx = job.host_idx,
                .index_idx = job.index_idx,
                .err = @tagName(synced),
            });
            self.replyTo(job.ring_idx, .{ .SnapshotCreateFailed = .{} });
            return;
        }

        job.fd = fd;
        self.replyTo(job.ring_idx, .{ .SnapshotFd = .{ .fd = fd } });
    }

    /// F2: dumps the clone, commits the registry line, and answers.
    ///
    /// The clone's arena reset releases the clone and the dump bytes on every
    /// path. A dump failure answers `SnapshotDumpFailed`; a registry failure
    /// answers `SnapshotAbandon`; a corrupt registry is the runtime fatality,
    /// requested before any abandon, and gets no reply because the process is
    /// coming down.
    pub fn dumpSnapshot(self: *Elephant, job: *lifetime.SnapshotJob) void {
        const ctrl = self.ctrl;
        const log = self.log;

        const state_y = job.clone.state;

        const written = self.writeSnapshotFile(job);
        _ = job.arena.reset(.free_all);

        written catch |err| {
            log.err("snapshot dump failed", .{
                .ring_idx = job.ring_idx,
                .host_idx = job.host_idx,
                .index_idx = job.index_idx,
                .err = @errorName(err),
            });
            self.replyTo(job.ring_idx, .{ .SnapshotDumpFailed = .{} });
            return;
        };

        ctrl.rewriteRegistry(job.index_idx, .{
            .host_idx = job.host_idx,
            .snapshot_path = job.snapshot_path,
            .wal_path = job.wal_path,
            .state = state_y,
        }) catch |err| switch (err) {
            error.RegistryCorrupt => {
                const rendered = ctrl.registryPath(job.index_idx) catch null;
                defer if (rendered) |path| ctrl.allocator.free(path);
                const registry_path: []const u8 = rendered orelse "<unavailable>";
                log.err("snapshot registry is corrupt; requesting a process stop", .{
                    .ring_idx = self.ring_idx,
                    .index_idx = job.index_idx,
                    .registry_path = registry_path,
                });
                self.requestProcessStop();
                return;
            },
            else => {
                log.err("snapshot registry rewrite failed; abandoning", .{
                    .ring_idx = job.ring_idx,
                    .host_idx = job.host_idx,
                    .index_idx = job.index_idx,
                    .err = @errorName(err),
                });
                self.replyTo(job.ring_idx, .{ .SnapshotAbandon = .{} });
                return;
            },
        };

        self.replyTo(job.ring_idx, .{ .SnapshotDumped = .{} });
    }

    /// F3: the success path's terminal elephant.
    ///
    /// The old descriptor's close is hygiene, not durability: both modes are
    /// deliberately buffered, so a refused close is a warning and the
    /// procedure still finishes. The slot returns to the pool and the job shell
    /// dies here; the index clears its in-flight flag on the `SnapshotDone`
    /// reply.
    pub fn closeSnapshot(self: *Elephant, job: *lifetime.SnapshotJob) void {
        const ctrl = self.ctrl;
        const log = self.log;
        const ring_idx = job.ring_idx;
        const k = job.k;

        if (job.old_fd != -1) {
            const errno = std.os.linux.errno(std.os.linux.close(job.old_fd));
            if (errno != .SUCCESS) {
                log.warn("snapshot final close failed", .{
                    .ring_idx = ring_idx,
                    .host_idx = job.host_idx,
                    .index_idx = job.index_idx,
                    .err = @tagName(errno),
                });
            }
            job.old_fd = -1;
        }

        ctrl.snapshot_slots.at(k).status = .idle;
        ctrl.snapshot_slots.release(k);
        ctrl.releaseSnapshotJob(job);
        self.replyTo(ring_idx, .{ .SnapshotDone = .{} });
    }

    /// F3: the failure path's terminal elephant (design §8).
    ///
    /// Unlinks both files best effort, closes any descriptor still held, clears
    /// the slot and releases it, then destroys the job shell and answers
    /// `SnapshotDone`. Absent files are success: the create-failure rung has
    /// none.
    pub fn cleanupSnapshot(self: *Elephant, job: *lifetime.SnapshotJob) void {
        const ctrl = self.ctrl;
        const log = self.log;
        const ring_idx = job.ring_idx;
        const k = job.k;

        self.unlinkBestEffort(job.wal_path, job, "wal");
        self.unlinkBestEffort(job.snapshot_path, job, "snapshot");

        if (job.fd != -1) {
            _ = std.os.linux.close(job.fd);
            job.fd = -1;
        }
        if (job.old_fd != -1) {
            _ = std.os.linux.close(job.old_fd);
            job.old_fd = -1;
        }

        if (ctrl.snapshot_slots.at(k).status != .rollback) {
            log.warn("snapshot cleanup arrived with a non-rollback slot status", .{
                .ring_idx = ring_idx,
                .host_idx = job.host_idx,
                .index_idx = job.index_idx,
                .status = @tagName(ctrl.snapshot_slots.at(k).status),
            });
        }
        ctrl.snapshot_slots.at(k).status = .idle;
        ctrl.snapshot_slots.release(k);
        ctrl.releaseSnapshotJob(job);
        self.replyTo(ring_idx, .{ .SnapshotDone = .{} });
    }

    fn jobOf(ptr: usize) *lifetime.SnapshotJob {
        return @ptrFromInt(ptr);
    }

    fn writeSnapshotFile(self: *Elephant, job: *lifetime.SnapshotJob) !void {
        var out: std.ArrayList(u8) = .empty;
        try self.ctrl.dumpIndexState(&job.clone, &out);

        const fd_raw = std.os.linux.open(job.snapshot_path, .{
            .ACCMODE = .RDWR,
            .CREAT = true,
            .TRUNC = true,
        }, 0o644);
        const errno = std.os.linux.errno(fd_raw);
        if (errno != .SUCCESS) return std.posix.unexpectedErrno(errno);
        const fd: posix.fd_t = @intCast(fd_raw);

        writeAll(fd, out.items) catch |err| {
            _ = std.os.linux.close(fd);
            return err;
        };
        syncFd(fd) catch |err| {
            _ = std.os.linux.close(fd);
            return err;
        };
        const closed = std.os.linux.errno(std.os.linux.close(fd));
        if (closed != .SUCCESS) return std.posix.unexpectedErrno(closed);
    }

    fn unlinkBestEffort(
        self: *Elephant,
        path: [:0]const u8,
        job: *lifetime.SnapshotJob,
        kind: []const u8,
    ) void {
        const errno = std.os.linux.errno(std.os.linux.unlink(path));
        if (errno == .SUCCESS or errno == .NOENT) return;
        self.log.warn("snapshot cleanup could not unlink a file", .{
            .ring_idx = job.ring_idx,
            .host_idx = job.host_idx,
            .index_idx = job.index_idx,
            .leaf = kind,
            .err = @tagName(errno),
        });
    }

    /// The runtime fatality of a corrupt registry (design §2.4, §8 rung 6). The
    /// request rides the init ring; with an invalid line there is no torn
    /// append that could have produced it, so no reply to the index follows.
    fn requestProcessStop(self: *Elephant) void {
        self.log.err("snapshot procedure requests a process stop", .{ .ring_idx = self.ring_idx });
        while (true) {
            if (self.ctrl.init_ring.ring.pushMsgRingFd(
                self.ctrl.init_ring.ring.fd,
                messages.ProcessStopRequestIdx,
                self.ring_idx,
                .{},
            )) |_| {
                return;
            } else |err| switch (err) {
                error.RingFull => std.atomic.spinLoopHint(),
            }
        }
    }

    /// One reply on the requesting index thread's ring. The slot is acquired
    /// once and its payload written once; only a refused `MSG_RING` spins
    /// (elephants may spin, `index_inbox.zig:248-262`).
    fn replyTo(self: *Elephant, ring_idx: u16, payload: cross_task.CrossTask) void {
        const ctrl = self.ctrl;

        var slot_idx: u32 = undefined;
        while (true) {
            slot_idx = ctrl.cross_slots.acquire() catch {
                std.atomic.spinLoopHint();
                continue;
            };
            break;
        }
        ctrl.cross_slots.at(slot_idx).* = payload;

        while (true) {
            if (ctrl.rings[ring_idx].ring.pushMsgRingFd(
                ctrl.rings[ring_idx].ring.fd,
                messages.CrossTaskMessageIdx,
                slot_idx,
                .{},
            )) |_| {
                return;
            } else |err| switch (err) {
                error.RingFull => std.atomic.spinLoopHint(),
            }
        }
    }
};

fn writeAll(fd: posix.fd_t, bytes: []const u8) !void {
    var done: usize = 0;
    while (done < bytes.len) {
        const res = std.os.linux.write(fd, bytes[done..].ptr, bytes.len - done);
        const errno = std.os.linux.errno(res);
        if (errno != .SUCCESS) return std.posix.unexpectedErrno(errno);
        if (res == 0) return error.WriteZero;
        done += res;
    }
}

fn syncFd(fd: posix.fd_t) !void {
    const errno = std.os.linux.errno(std.os.linux.fdatasync(fd));
    if (errno != .SUCCESS) return std.posix.unexpectedErrno(errno);
}

/// Retries a submission backpressure parked: its own writer cannot re-drive it
/// without a write, and no completion is owed for it.
fn retryParkedFlush(writer: *wal.WalWriteFile) void {
    if (writer.flush_pending and !writer.flush_in_flight) writer.driveFlush();
}

/// Arms the repeating snapshot ticker (§1.1): one timeout CQE per period,
/// armed once. The kernel reads the spec asynchronously, so it lives in the
/// ring's own storage; a failed arm disables snapshots on this thread only, and
/// the thread keeps serving.
pub fn armTicker(host: Host) void {
    const ring = host.ring;
    ring.tick_spec = .{
        .sec = @intCast(@divExact(host.ctrl.cfg.snapshots.interval.value(), std.time.ns_per_s)),
        .nsec = 0,
    };
    ring.ring.pushTicker(messages.SnapshotTickIdx, &ring.tick_spec, 0, .{}) catch |err| {
        host.log.err("snapshot ticker arm failed; snapshots disabled on this thread", .{
            .ring_idx = host.ring_idx,
            .err = @errorName(err),
        });
    };
    // The arm is a direct submission like the INITIALIZED report: re-capture
    // the stream window before the loop's first flush uses it.
    ring.ring.streamedSQ(&ring.sqstream);
}

/// The startup replay's sink: the record's state becomes `st.state` before the
/// op is applied, which is `applyIndexOp`'s contract.
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
pub fn recoverPair(
    ctrl: *lifetime.Controller,
    ring: *lifetime.RingStuff,
    log: *logging.Logger,
    index_idx: u16,
    host_idx: u8,
    st: *state.IndexState,
) !void {
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

/// The config every moved tick test starts from: one front, one index, a plain
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

fn testHost(
    ctrl: *lifetime.Controller,
    ring_idx: u16,
    logger: *lifetime.LoggerStuff,
    data_sets: []state.IndexState,
) Host {
    return .{
        .ctrl = ctrl,
        .ring = &ctrl.rings[ring_idx],
        .log = &logger.logger,
        .ring_idx = ring_idx,
        .index_idx = 0,
        .data_sets = data_sets,
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

/// Creates (or empties) the WAL file a snapshot would have handed over.
/// Creation itself is elephant-side (`designs/wal-impl.md` §1.1), so the test
/// stands in for it.
fn createWalFile(path: [:0]const u8) !posix.fd_t {
    const fd_raw = std.os.linux.open(path, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, 0o644);
    const errno = std.os.linux.errno(fd_raw);
    if (errno != .SUCCESS) return std.posix.unexpectedErrno(errno);
    return @intCast(fd_raw);
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

    var cfg = testConfig(dir, 1, 0, .{ .size_barrier = config.mib(1), .interval = config.seconds(1), .slots = 2, .registry_keep = 8 });
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

    const host = testHost(&ctrl, 1, logger, &sets);
    var st: State = .{};
    const slots_full = ctrl.snapshot_slots.freeCount();

    // A stopped thread's files do not grow.
    st.serve = .stopped;
    st.tickPass(host);
    try testing.expectEqual(@as(u32, 1), st.ticks);
    try testing.expectEqual(slots_full, ctrl.snapshot_slots.freeCount());
    try testing.expect(st.procedure == null);

    // A frozen window denies the tick just the same.
    st.serve = .frozen;
    st.tickPass(host);
    try testing.expectEqual(@as(u32, 2), st.ticks);
    try testing.expectEqual(slots_full, ctrl.snapshot_slots.freeCount());
    try testing.expect(st.procedure == null);

    // One procedure per index: its own flag ends the pass.
    var job: lifetime.SnapshotJob = undefined;
    st.serve = .serving;
    st.procedure = &job;
    st.tickPass(host);
    try testing.expectEqual(@as(u32, 3), st.ticks);
    try testing.expectEqual(slots_full, ctrl.snapshot_slots.freeCount());
    try testing.expect(st.procedure == &job);

    // A pending push ends the pass too; the tick never queues.
    st.procedure = null;
    st.pending_push = .{ .slot_idx = 0, .target_ring_idx = 2 };
    st.tickPass(host);
    try testing.expectEqual(@as(u32, 4), st.ticks);
    try testing.expectEqual(slots_full, ctrl.snapshot_slots.freeCount());
    try testing.expect(st.procedure == null);
    st.pending_push = null;
}

test "the tick picks the largest pair and dispatches the create" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(dir);

    var cfg = testConfig(dir, 2, 1, .{ .size_barrier = config.mib(1), .interval = config.seconds(1), .slots = 2, .registry_keep = 8 });
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
    try testWriter(&ctrl, 1, 0x400, 1300, 1000);

    var sets = [_]state.IndexState{ undefined, undefined };
    for (&sets) |*st| try ctrl.initIndexState(st);
    defer for (&sets) |*st| ctrl.deinitIndexState(st);
    sets[0].state = 0x301;
    sets[1].state = 0x402;

    const host = testHost(&ctrl, 1, logger, &sets);
    var st: State = .{};
    st.tickPass(host);

    const job = st.procedure orelse return error.SnapshotNotStarted;
    defer {
        ctrl.snapshot_slots.at(job.k).* = .{ .status = .idle, .job = 0 };
        ctrl.snapshot_slots.release(job.k);
        ctrl.releaseSnapshotJob(job);
        st.procedure = null;
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

    var cfg = testConfig(dir, 1, 0, .{ .size_barrier = config.mib(1), .interval = config.seconds(1), .slots = 1, .registry_keep = 8 });
    var ctrl: lifetime.Controller = undefined;
    try ctrl.init(testing.allocator, &cfg);
    defer ctrl.deinit();
    try ctrl.initRing(1, 1);
    defer ctrl.rings[1].deinit();

    const logger = try ctrl.getLogger(1);
    defer dropTestLogger(&ctrl, logger);

    try ctrl.ensureIndexDir(0);
    try testWriter(&ctrl, 0, 0x300, 1300, 1000);

    var sets = [_]state.IndexState{undefined};
    try ctrl.initIndexState(&sets[0]);
    defer ctrl.deinitIndexState(&sets[0]);
    sets[0].state = 0x301;

    const host = testHost(&ctrl, 1, logger, &sets);
    var st: State = .{};

    // Rung 0: the process-wide limit is the design working, not a failure.
    const held = try ctrl.snapshot_slots.acquire();
    defer ctrl.snapshot_slots.release(held);

    st.tickPass(host);

    try testing.expectEqual(@as(usize, 0), ctrl.snapshot_slots.freeCount());
    try testing.expect(st.procedure == null);
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

    const host = testHost(&ctrl, 1, logger, &.{});
    var st: State = .{};
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

        st.dispatch(host, .{ .SnapshotCreate = .{ .job = fake_job } }, 2);
        if (st.pending_push != null) {
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
    while (st.pending_push != null) {
        if (zigring.monotonicNs() >= deadline) return error.PendingPushTimeout;
        while (ctrl.rings[1].ring.popCQE()) |_| {}
        st.retryPending(host);
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
fn dropWindow(ctrl: *lifetime.Controller, st: *State) void {
    if (st.window) |*window| {
        _ = std.os.linux.close(window.new.fd);
        ctrl.allocator.destroy(window.new);
        window.pending.deinit(ctrl.allocator);
        st.window = null;
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

/// Steps one ring completion the way the index's flush arm does, keeping a
/// synthetic window's flushes flowing without importing the index.
fn stepWindowCQE(ctrl: *lifetime.Controller, host: Host, st: *State, cqe: zigring.CQE) void {
    const ctx = ctrl.rings[host.ring_idx].slots.get(cqe.taskIdx()) orelse return;
    switch (ctx) {
        .wal_flush => |flush| {
            flush.writer.flushResult(cqe);
            st.onFlush(host, flush.writer);
            st.onWriterFault(host, flush.writer);
        },
        else => {},
    }
}

/// Runs the pump's continuation to quiescence without the index's loop.
fn drainToQuiet(ctrl: *lifetime.Controller, host: Host, st: *State) void {
    while (st.drainPending()) {
        if (st.drainQuiet()) {
            st.onDrained(host);
            continue;
        }
        if (ctrl.rings[host.ring_idx].ring.popCQE()) |cqe| {
            stepWindowCQE(ctrl, host, st, cqe);
            continue;
        }
        ctrl.rings[host.ring_idx].ring.park();
    }
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

    const host = testHost(&ctrl, 1, logger, &sets);
    var st: State = .{};
    st.procedure = job;

    try ctrl.publishAdoptionMark(0, 0, k, 0x100);
    try testing.expectEqual(@as(u8, 1), pairControlLine(&ctrl).snapshot_in_progress);

    st.unwindA(host, job, .{ .mark_published = true, .writer_built = null });

    // The line is clear again: the old pair is the one serving.
    const line = pairControlLine(&ctrl);
    try testing.expectEqual(@as(u8, 0), line.snapshot_in_progress);
    try testing.expectEqual(@as(u16, 0), line.new_wal_buffer_idx);
    try testing.expectEqual(@as(u128, 0), line.target_state);

    // The slot rolls back and the procedure's phase names its dispatch.
    try testing.expectEqual(cross_task.SnapshotSlotStatus.rollback, ctrl.snapshot_slots.at(job.k).status);
    try testing.expectEqual(lifetime.SnapshotPhase.cleanup_sent, job.phase);

    // The flag stays until the terminal `SnapshotDone` (§4).
    try testing.expectEqual(job, st.procedure.?);

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

    var cfg = testConfig(dir, 1, 1, .{ .slots = 2, .size_barrier = config.mib(1), .interval = config.seconds(1), .registry_keep = 8 });
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

    // The pair has history: its writer chains from the file's tag, with records
    // that end on a buffer boundary so the window's own flush is the one that
    // reaches the file.
    try ctrl.ensureIndexDir(0);
    try testWriter(&ctrl, 0, 0x100, 1100, 1006);
    sets[0].state = 0x101;

    const host = testHost(&ctrl, 1, logger, &sets);
    var st: State = .{};
    st.onTick(host);

    const job = st.procedure orelse return error.SnapshotNotStarted;
    defer {
        if (st.window != null) dropWindow(&ctrl, &st);
        dropTestJob(&ctrl, job);
        st.procedure = null;
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
    try testing.expectEqual(@as(u128, 0x102), sets[0].state);

    st.onReply(host, .{ .SnapshotFd = .{ .fd = fd } });

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

    const window = &st.window.?;
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
    var op: [1006]u8 = undefined;
    for (&op, 0..) |*byte, i| byte.* = @truncate(i *% 17 +% 3);
    try window.write(0x103, &op);
    const deadline = zigring.monotonicNs() + 5 * std.time.ns_per_s;
    while (!window.quiet()) {
        if (zigring.monotonicNs() >= deadline) return error.SnapshotFlushTimeout;
        if (ctrl.rings[1].ring.popCQE()) |cqe| {
            stepWindowCQE(&ctrl, host, &st, cqe);
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

    var cfg = testConfig(dir, 1, 1, .{ .slots = 2, .size_barrier = config.mib(1), .interval = config.seconds(1), .registry_keep = 8 });
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
    try testWriter(&ctrl, 0, 0x100, 1300, 1000);
    sets[0].state = 0x101;

    const host = testHost(&ctrl, 1, logger, &sets);
    var st: State = .{};
    st.onTick(host);

    const job = st.procedure orelse return error.SnapshotNotStarted;
    defer {
        if (st.window != null) dropWindow(&ctrl, &st);
        dropTestJob(&ctrl, job);
        st.procedure = null;
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

    st.onReply(host, .{ .SnapshotFd = .{ .fd = fd } });

    // Rung 3: the mark was published and is cleared again, the descriptor
    // stays with the job for the cleanup elephant, and no window opens.
    const line = pairControlLine(&ctrl);
    try testing.expectEqual(@as(u8, 0), line.snapshot_in_progress);
    try testing.expect(st.window == null);
    try testing.expectEqual(fd, job.fd);
    try testing.expectEqual(cross_task.SnapshotSlotStatus.rollback, ctrl.snapshot_slots.at(job.k).status);
    try testing.expectEqual(lifetime.SnapshotPhase.cleanup_sent, job.phase);

    const cleanup_cqe = cqeBefore(&ctrl.rings[2].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
        return error.SnapshotDispatchTimeout;
    const cleanup_slot: u32 = @intCast(cleanup_cqe.res);
    try testing.expectEqual(@intFromPtr(job), ctrl.cross_slots.at(cleanup_slot).SnapshotCleanup.job);
    ctrl.cross_slots.release(cleanup_slot);
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
    var cfg = testConfig(dir, 1, 1, .{ .slots = 2, .size_barrier = config.mib(1), .interval = config.seconds(1), .registry_keep = 8 });
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
    try testWriter(&ctrl, 0, 0x100, 1100, 1006);
    sets[0].state = 0x101;

    const host = testHost(&ctrl, 1, logger, &sets);
    var st: State = .{};
    st.onTick(host);

    const job = st.procedure orelse return error.SnapshotNotStarted;
    defer {
        if (st.window != null) dropWindow(&ctrl, &st);
        dropTestJob(&ctrl, job);
        st.procedure = null;
    }

    const create_cqe = cqeBefore(&ctrl.rings[2].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
        return error.SnapshotDispatchTimeout;
    ctrl.cross_slots.release(@intCast(create_cqe.res));
    const fd = try createWalFile(job.wal_path);

    // The clone of an empty data set allocates nothing; the adopt's writer
    // object is the next allocation and the one refused.
    failing.fail_index = failing.alloc_index;
    st.onReply(host, .{ .SnapshotFd = .{ .fd = fd } });
    failing.fail_index = std.math.maxInt(usize);

    // Rung 4: no window opened, the mark is cleared, and the descriptor the
    // adopt closed is not left in the job for a second close.
    try testing.expect(st.window == null);
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

/// A sink that holds every submission: the test decides when a flush completes
/// and observes the both-sides rule one frontier at a time.
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

test "a composite event completes only when both sides' flushes cover it" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(dir);

    var cfg = testConfig(dir, 1, 1, .{});
    var ctrl: lifetime.Controller = undefined;
    try ctrl.init(testing.allocator, &cfg);
    defer ctrl.deinit();

    // The pair has history: the old writer chains from the file's tag.
    const old = try openPairWriter(&ctrl, 0, 0, 0x100);

    // The window's writer runs on temp ring 0, chained from the clone state Y.
    const k = try ctrl.snapshot_slots.acquire();
    const new = try adoptWindowWriter(&ctrl, 0, 0, k, 0x101, 0x100);
    defer {
        _ = std.os.linux.close(new.fd);
        ctrl.allocator.destroy(new);
        ctrl.snapshot_slots.release(k);
    }

    HoldFlush.install(old);
    HoldFlush.install(new);

    var composite = CompositeWriter{
        .new = new,
        .old = old,
        .allocator = std.testing.allocator,
    };
    defer composite.pending.deinit(std.testing.allocator);

    // 1006 op bytes frame to exactly one 1 KiB buffer on both sides.
    var op: [1006]u8 = undefined;
    for (&op, 0..) |*byte, i| byte.* = @truncate(i *% 31 +% 1);

    try composite.write(0x101, &op);
    try testing.expectEqual(@as(usize, 1), composite.pending.items.len);
    try testing.expect(old.flush_in_flight and new.flush_in_flight);
    try testing.expect(!composite.quiet());

    // Old-side coverage alone completes nothing: the event must be durable in
    // both files or either crash outcome loses it.
    old.flushResult(.{ .user_data = 0, .res = 1024, .flags = 0 });
    const old_only = composite.noteFlush(old);
    try testing.expectEqual(@as(usize, 0), old_only.count);
    try testing.expect(old_only.last_end == null);
    try testing.expectEqual(@as(usize, 1), composite.pending.items.len);

    // The new side's flush lands on the same buffer: now it is complete.
    new.flushResult(.{ .user_data = 0, .res = 1024, .flags = 0 });
    const both = composite.noteFlush(new);
    try testing.expectEqual(@as(usize, 1), both.count);
    try testing.expectEqual(@as(u64, 1024), both.last_end.?);
    try testing.expectEqual(@as(usize, 0), composite.pending.items.len);
    try testing.expect(composite.quiet());

    // A mid-buffer tail event has no flush of its own; it completes when the
    // buffer it ends in fills and both sides flush it.
    var tail: [100]u8 = undefined;
    @memset(&tail, 0x5a);
    try composite.write(0x102, &tail);
    try testing.expectEqual(@as(usize, 1), composite.pending.items.len);
    try testing.expect(composite.quiet());

    // 889 op bytes frame to 907: 117 + 907 fills the open buffer exactly.
    var filler: [889]u8 = undefined;
    @memset(&filler, 0xa5);
    try composite.write(0x103, &filler);
    try testing.expectEqual(@as(usize, 2), composite.pending.items.len);
    try testing.expect(old.flush_in_flight and new.flush_in_flight);

    // New-side coverage alone still completes nothing.
    new.flushResult(.{ .user_data = 0, .res = 1024, .flags = 0 });
    const new_only = composite.noteFlush(new);
    try testing.expectEqual(@as(usize, 0), new_only.count);

    // The old side's covering flush completes both, in write order; the last
    // completed event's pair-side end is the filler's.
    old.flushResult(.{ .user_data = 0, .res = 1024, .flags = 0 });
    const rest = composite.noteFlush(old);
    try testing.expectEqual(@as(usize, 2), rest.count);
    try testing.expectEqual(@as(u64, 2048), rest.last_end.?);
    try testing.expectEqual(@as(usize, 0), composite.pending.items.len);
    try testing.expect(composite.quiet());
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

    const host = testHost(&ctrl, 1, logger, &sets);
    var st: State = .{};
    st.procedure = job;
    st.window = .{ .new = new, .old = old, .allocator = ctrl.allocator };
    try ctrl.publishAdoptionMark(0, 0, k, 0x100);

    st.onReply(host, .{ .SnapshotDumpFailed = .{} });
    drainToQuiet(&ctrl, host, &st);

    // The pair serves through the old writer again: no window, and a write
    // lands on the old side only.
    try testing.expect(st.window == null);
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

    const host = testHost(&ctrl, 1, logger, &sets);
    var st: State = .{};
    st.window = .{ .new = new, .old = old, .allocator = ctrl.allocator };
    defer {
        dropWindow(&ctrl, &st);
        ctrl.snapshot_slots.release(k);
    }

    // Rung: an old-side flush fault mid-window freezes; the front guard is the
    // state itself, and the control plane keeps flowing regardless (§5).
    old.faulted = true;
    st.onWriterFault(host, old);
    try testing.expectEqual(Serve.frozen, st.serve);
    try testing.expect(st.serve != .serving);

    // A new-side fault is the ordinary terminal stop.
    new.faulted = true;
    st.onWriterFault(host, new);
    try testing.expectEqual(Serve.stopped, st.serve);
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
    var op: [1006]u8 = undefined;
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

    const host = testHost(&ctrl, 1, logger, &sets);
    var st: State = .{};
    st.window = .{ .new = new, .old = old, .allocator = ctrl.allocator };
    defer {
        dropWindow(&ctrl, &st);
        ctrl.snapshot_slots.release(k);
    }

    try testing.expectError(error.WalFull, st.window.?.write(pair_state + 1, &op));
    try testing.expectEqual(CompositeWriter.Side.old, st.window.?.failed_side.?);
    try testing.expectEqual(pair_state + 1, st.window.?.new.head);
    try testing.expectEqual(pair_state, st.window.?.old.head);

    st.onWriteError(host, error.WalFull);
    try testing.expectEqual(Serve.frozen, st.serve);

    // A protocol answer is never a trigger, and outside a window a fault stops.
    st.serve = .serving;
    st.onWriteError(host, error.RecordTooLarge);
    try testing.expectEqual(Serve.serving, st.serve);
    st.onWriteError(host, error.WalGap);
    try testing.expectEqual(Serve.serving, st.serve);
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

    const host = testHost(&ctrl, 1, logger, &sets);
    var st: State = .{};
    st.procedure = job;
    st.window = .{ .new = new, .old = old, .allocator = ctrl.allocator };
    try ctrl.publishAdoptionMark(0, 0, k, 0x100);

    // The old side froze the front; the dump then failed. No swap is coming,
    // so the freeze stands (§8 rung 10).
    old.faulted = true;
    st.serve = .frozen;
    st.onReply(host, .{ .SnapshotDumpFailed = .{} });
    drainToQuiet(&ctrl, host, &st);

    try testing.expectEqual(Serve.frozen, st.serve);
    try testing.expect(st.window == null);
    try testing.expectEqual(lifetime.SnapshotPhase.cleanup_sent, job.phase);
    try testing.expectEqual(cross_task.SnapshotSlotStatus.rollback, ctrl.snapshot_slots.at(k).status);

    const cleanup_cqe = cqeBefore(&ctrl.rings[2].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
        return error.SnapshotDispatchTimeout;
    const cleanup_slot: u32 = @intCast(cleanup_cqe.res);
    try testing.expectEqual(@intFromPtr(job), ctrl.cross_slots.at(cleanup_slot).SnapshotCleanup.job);
    ctrl.cross_slots.release(cleanup_slot);
}

// ============================================================================
// Startup recovery (§7.1)
// ============================================================================

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

    try recoverPair(&f.ctrl, &f.ctrl.rings[ring_idx], &logger.logger, index, host, &st);

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

    try recoverPair(&f.ctrl, &f.ctrl.rings[ring_idx], &logger.logger, index, host, &st);

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
    try recoverPair(&f.ctrl, ring, &logger.logger, 0, 0, &st);

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

    try recoverPair(&f.ctrl, &f.ctrl.rings[ring_idx], &logger.logger, 0, 0, &st);

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
        recoverPair(&f.ctrl, &f.ctrl.rings[ring_idx], &logger.logger, 0, 0, &st),
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
        recoverPair(&f.ctrl, &f.ctrl.rings[ring_idx], &logger.logger, index, host, &st),
    );
}

const ElephantFixture = struct {
    tmp: std.testing.TmpDir,
    dir: []u8,
    cfg: config.Config,
    ctrl: lifetime.Controller,
    logger: *lifetime.LoggerStuff = undefined,

    fn init(self: *ElephantFixture) !void {
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.dir = try std.fmt.allocPrint(
            std.testing.allocator,
            ".zig-cache/tmp/{s}",
            .{self.tmp.sub_path[0..]},
        );
        self.cfg = testConfig(self.dir, 1, 1, .{ .registry_keep = 2 });
        try self.ctrl.init(std.testing.allocator, &self.cfg);
        errdefer self.ctrl.deinit();
        try self.ctrl.compensators.put("marker", .{ .bind = "10.0.0.1", .port = 20301 });
        try self.ctrl.initRing(1, 1);
        self.logger = try self.ctrl.getInitLogger();
    }

    fn deinit(self: *ElephantFixture) void {
        self.logger.deinit(self.ctrl.allocator);
        self.ctrl.allocator.destroy(self.logger);
        self.ctrl.rings[1].deinit();
        self.ctrl.deinit();
        std.testing.allocator.free(self.dir);
        self.tmp.cleanup();
    }

    fn elephant(self: *ElephantFixture) Elephant {
        return .{
            .ctrl = &self.ctrl,
            .log = &self.logger.logger,
            .ring_idx = elephant_ring_idx,
        };
    }
};

const index_ring_idx: u16 = 1;
const elephant_ring_idx: u16 = 2;

fn dropLogger(ctrl: *lifetime.Controller, logger: *lifetime.LoggerStuff) void {
    logger.deinit(ctrl.allocator);
    ctrl.allocator.destroy(logger);
}

fn recvReply(ctrl: *lifetime.Controller, deadline_ns: u64) !cross_task.CrossTask {
    while (zigring.monotonicNs() < deadline_ns) {
        if (ctrl.rings[index_ring_idx].ring.popCQE()) |cqe| {
            try std.testing.expectEqual(messages.CrossTaskMessageIdx, cqe.taskIdx());
            const slot_idx: u32 = @intCast(cqe.res);
            const task = ctrl.cross_slots.at(slot_idx).*;
            ctrl.cross_slots.release(slot_idx);
            return task;
        }
        std.atomic.spinLoopHint();
    }
    return error.ReplyTimeout;
}

fn replyDeadline() u64 {
    return zigring.monotonicNs() + 2 * std.time.ns_per_s;
}

/// Spins until `ring` yields one completion or the deadline passes. The
/// `MSG_RING` a terminal elephant posts lands on the target ring's CQ a moment
/// after the push returns, so a test must not demand it synchronously.
fn cqeWithin(ring: *zigring.Ring, deadline_ns: u64) ?zigring.CQE {
    while (zigring.monotonicNs() < deadline_ns) {
        if (ring.popCQE()) |cqe| return cqe;
        std.atomic.spinLoopHint();
    }
    return null;
}

fn mintJob(f: *ElephantFixture, tag: u128) !*lifetime.SnapshotJob {
    const k = try f.ctrl.snapshot_slots.acquire();
    return f.ctrl.mintSnapshotJob(0, 0, tag, k, index_ring_idx);
}

fn writeRawFile(path: []const u8, bytes: []const u8) !void {
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
    try writeAll(fd, bytes);
}

fn readRawFile(path: []const u8) ![]u8 {
    const path_z = try std.testing.allocator.dupeSentinel(u8, path, 0);
    defer std.testing.allocator.free(path_z);

    const fd_raw = std.os.linux.open(path_z, .{ .ACCMODE = .RDONLY }, 0);
    const errno = std.os.linux.errno(fd_raw);
    if (errno != .SUCCESS) return std.posix.unexpectedErrno(errno);
    const fd: posix.fd_t = @intCast(fd_raw);
    defer _ = std.os.linux.close(fd);

    const size = try wal.fileSize(fd);
    const bytes = try std.testing.allocator.alloc(u8, @intCast(size));
    errdefer std.testing.allocator.free(bytes);

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

fn fdIsClosed(fd: posix.fd_t) bool {
    const res = std.os.linux.fcntl(fd, std.os.linux.F.GETFD, 0);
    return std.os.linux.errno(res) == .BADF;
}

fn pathExists(path: [:0]const u8) bool {
    const fd_raw = std.os.linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    const errno = std.os.linux.errno(fd_raw);
    if (errno != .SUCCESS) return false;
    _ = std.os.linux.close(@intCast(fd_raw));
    return true;
}

fn openRaw(path: [:0]const u8, flags: std.os.linux.O) !posix.fd_t {
    const fd_raw = std.os.linux.open(path, flags, 0);
    const errno = std.os.linux.errno(fd_raw);
    if (errno != .SUCCESS) return std.posix.unexpectedErrno(errno);
    return @intCast(fd_raw);
}

test "create truncates a stale prefix and replies the descriptor" {
    var f: ElephantFixture = undefined;
    try f.init();
    defer f.deinit();

    const job = try mintJob(&f, 0x2a);
    defer f.ctrl.releaseSnapshotJob(job);

    try f.ctrl.ensureIndexDir(0);
    try writeRawFile(job.wal_path, "garbage prefix that must not survive");

    var el = f.elephant();
    el.createSnapshot(job);

    const reply = try recvReply(&f.ctrl, replyDeadline());
    const fd = switch (reply) {
        .SnapshotFd => |r| r.fd,
        else => return error.UnexpectedReply,
    };
    try std.testing.expectEqual(fd, job.fd);
    try std.testing.expectEqual(@as(u64, 0), try wal.fileSize(fd));

    const on_disk = try readRawFile(job.wal_path);
    defer std.testing.allocator.free(on_disk);
    try std.testing.expectEqual(@as(usize, 0), on_disk.len);

    _ = std.os.linux.close(fd);
    job.fd = -1;
}

test "create failure replies SnapshotCreateFailed and holds no descriptor" {
    var f: ElephantFixture = undefined;
    try f.init();
    defer f.deinit();

    const job = try mintJob(&f, 0x2b);
    defer f.ctrl.releaseSnapshotJob(job);

    // A directory where the file belongs makes the open fail.
    try f.ctrl.ensureIndexDir(0);
    const made = std.os.linux.errno(std.os.linux.mkdir(job.wal_path, 0o755));
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, made);

    var el = f.elephant();
    el.createSnapshot(job);

    const reply = try recvReply(&f.ctrl, replyDeadline());
    try std.testing.expectEqual(cross_task.CrossTask.SnapshotCreateFailed, std.meta.activeTag(reply));
    try std.testing.expectEqual(@as(posix.fd_t, -1), job.fd);
    try std.testing.expectEqual(f.ctrl.snapshot_slots.freeCount(), f.ctrl.snapshot_slots.tasks.len - 1);
}

fn makeClone(f: *ElephantFixture, job: *lifetime.SnapshotJob, state_y: u128) !void {
    var live: state.IndexState = undefined;
    try f.ctrl.initIndexState(&live);
    defer f.ctrl.deinitIndexState(&live);

    live.state = state_y;
    try f.ctrl.applyIndexOp(&live, .{ .create = .{ .compensator = "marker", .payload = "snapshotted" } });

    job.clone = try f.ctrl.cloneIndexState(&live, job.arena.allocator());
}

test "dump writes the final name, commits the registry line and replies" {
    var f: ElephantFixture = undefined;
    try f.init();
    defer f.deinit();

    const tag: u128 = 0x2c;
    const state_y: u128 = tag + 5;
    const job = try mintJob(&f, tag);
    defer f.ctrl.releaseSnapshotJob(job);
    try makeClone(&f, job, state_y);
    try f.ctrl.ensureIndexDir(0);

    var el = f.elephant();
    el.dumpSnapshot(job);

    const reply = try recvReply(&f.ctrl, replyDeadline());
    try std.testing.expectEqual(cross_task.CrossTask.SnapshotDumped, std.meta.activeTag(reply));

    const bytes = try readRawFile(job.snapshot_path);
    defer std.testing.allocator.free(bytes);
    var loaded = try f.ctrl.loadIndexState(bytes);
    defer f.ctrl.deinitIndexState(&loaded);
    try std.testing.expectEqual(@as(usize, 1), loaded.sessions.count());
    try std.testing.expect(loaded.sessions.get(state_y) != null);

    const entries = (try f.ctrl.loadRegistry(0)).?;
    defer f.ctrl.freeRegistry(entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqual(@as(u8, 0), entries[0].host_idx);
    try std.testing.expectEqual(state_y, entries[0].state);
    try std.testing.expectEqualStrings(job.snapshot_path, entries[0].snapshot_path);
    try std.testing.expectEqualStrings(job.wal_path, entries[0].wal_path);
}

test "a dump compacts a pre-existing multi-line registry" {
    var f: ElephantFixture = undefined;
    try f.init();
    defer f.deinit();

    var line: usize = 0;
    while (line < 5) : (line += 1) {
        try f.ctrl.rewriteRegistry(0, .{
            .host_idx = 0,
            .snapshot_path = @constCast("old-snapshot"),
            .wal_path = @constCast("old-wal"),
            .state = @intCast(line),
        });
    }

    const tag: u128 = 0x2d;
    const job = try mintJob(&f, tag);
    defer f.ctrl.releaseSnapshotJob(job);
    try makeClone(&f, job, tag);

    var el = f.elephant();
    el.dumpSnapshot(job);
    try std.testing.expectEqual(cross_task.CrossTask.SnapshotDumped, std.meta.activeTag(try recvReply(&f.ctrl, replyDeadline())));

    const entries = (try f.ctrl.loadRegistry(0)).?;
    defer f.ctrl.freeRegistry(entries);
    // `registry_keep` retained lines plus the new one.
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqual(tag, entries[entries.len - 1].state);
}

test "a registry rewrite failure replies SnapshotAbandon and keeps the old file" {
    var f: ElephantFixture = undefined;
    try f.init();
    defer f.deinit();

    try f.ctrl.rewriteRegistry(0, .{
        .host_idx = 0,
        .snapshot_path = @constCast("kept-snapshot"),
        .wal_path = @constCast("kept-wal"),
        .state = 7,
    });
    const registry = try f.ctrl.registryPath(0);
    defer std.testing.allocator.free(registry);
    const before = try readRawFile(registry);
    defer std.testing.allocator.free(before);

    // The staging leaf occupied by a directory refuses the rewrite's open.
    const pending = try f.ctrl.registryPendingPath(0);
    defer std.testing.allocator.free(pending);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.mkdir(pending, 0o755)));

    const job = try mintJob(&f, 0x2e);
    defer f.ctrl.releaseSnapshotJob(job);
    try makeClone(&f, job, 0x2e);

    var el = f.elephant();
    el.dumpSnapshot(job);
    try std.testing.expectEqual(cross_task.CrossTask.SnapshotAbandon, std.meta.activeTag(try recvReply(&f.ctrl, replyDeadline())));

    const after = try readRawFile(registry);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "a corrupt registry requests a process stop and sends no reply" {
    var f: ElephantFixture = undefined;
    try f.init();
    defer f.deinit();

    try f.ctrl.ensureIndexDir(0);
    const registry = try f.ctrl.registryPath(0);
    defer std.testing.allocator.free(registry);
    try writeRawFile(registry, "not a registry line\n");

    const job = try mintJob(&f, 0x2f);
    defer f.ctrl.releaseSnapshotJob(job);
    try makeClone(&f, job, 0x2f);

    var el = f.elephant();
    el.dumpSnapshot(job);

    const cqe = cqeWithin(&f.ctrl.init_ring.ring, replyDeadline()) orelse return error.MissingStopRequest;
    try std.testing.expectEqual(messages.ProcessStopRequestIdx, cqe.taskIdx());
    try std.testing.expectEqual(@as(i32, elephant_ring_idx), @as(i32, @intCast(cqe.res)));
    try std.testing.expect(f.ctrl.rings[index_ring_idx].ring.popCQE() == null);
}

test "a dump failure replies SnapshotDumpFailed and frees the arena" {
    var f: ElephantFixture = undefined;
    try f.init();
    defer f.deinit();

    const job = try mintJob(&f, 0x30);
    defer f.ctrl.releaseSnapshotJob(job);
    try makeClone(&f, job, 0x30);

    // A directory at the snapshot leaf makes the write fail.
    try f.ctrl.ensureIndexDir(0);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.mkdir(job.snapshot_path, 0o755)));

    var el = f.elephant();
    el.dumpSnapshot(job);
    try std.testing.expectEqual(cross_task.CrossTask.SnapshotDumpFailed, std.meta.activeTag(try recvReply(&f.ctrl, replyDeadline())));
    try std.testing.expectEqual(
        @as(?[]lifetime.Controller.RegistryEntry, null),
        try f.ctrl.loadRegistry(0),
    );
}

test "close is terminal: the old fd dies, the slot returns, the job is gone" {
    var f: ElephantFixture = undefined;
    try f.init();
    defer f.deinit();

    const job = try mintJob(&f, 0x31);
    const k = job.k;
    const old_fd = try openRaw("/dev/null", .{ .ACCMODE = .RDONLY });
    job.old_fd = old_fd;
    f.ctrl.snapshot_slots.at(k).* = .{ .status = .in_flight, .job = @intFromPtr(job) };

    var el = f.elephant();
    el.closeSnapshot(job);

    try std.testing.expect(fdIsClosed(old_fd));
    try std.testing.expectEqual(f.ctrl.snapshot_slots.tasks.len, f.ctrl.snapshot_slots.freeCount());
    try std.testing.expectEqual(cross_task.CrossTask.SnapshotDone, std.meta.activeTag(try recvReply(&f.ctrl, replyDeadline())));
}

test "cleanup unlinks both files, closes the live fd and tolerates absences" {
    var f: ElephantFixture = undefined;
    try f.init();
    defer f.deinit();

    try f.ctrl.ensureIndexDir(0);

    // First: files and descriptors present.
    const job = try mintJob(&f, 0x32);
    const k = job.k;
    const wal_path = try std.testing.allocator.dupeSentinel(u8, job.wal_path, 0);
    defer std.testing.allocator.free(wal_path);
    const snapshot_path = try std.testing.allocator.dupeSentinel(u8, job.snapshot_path, 0);
    defer std.testing.allocator.free(snapshot_path);
    try writeRawFile(wal_path, "wal");
    try writeRawFile(snapshot_path, "snapshot");
    const live_fd = try openRaw(wal_path, .{ .ACCMODE = .RDONLY });
    job.fd = live_fd;
    f.ctrl.snapshot_slots.at(k).* = .{ .status = .rollback, .job = @intFromPtr(job) };

    var el = f.elephant();
    el.cleanupSnapshot(job);

    try std.testing.expect(!pathExists(wal_path));
    try std.testing.expect(!pathExists(snapshot_path));
    try std.testing.expect(fdIsClosed(live_fd));
    try std.testing.expectEqual(cross_task.CrossTask.SnapshotDone, std.meta.activeTag(try recvReply(&f.ctrl, replyDeadline())));
    try std.testing.expectEqual(f.ctrl.snapshot_slots.tasks.len, f.ctrl.snapshot_slots.freeCount());

    // Second: nothing on disk, no descriptors held: still a clean unwind.
    const bare = try mintJob(&f, 0x33);
    f.ctrl.snapshot_slots.at(bare.k).* = .{ .status = .rollback, .job = @intFromPtr(bare) };
    el.cleanupSnapshot(bare);
    try std.testing.expectEqual(cross_task.CrossTask.SnapshotDone, std.meta.activeTag(try recvReply(&f.ctrl, replyDeadline())));
    try std.testing.expectEqual(f.ctrl.snapshot_slots.tasks.len, f.ctrl.snapshot_slots.freeCount());
}
