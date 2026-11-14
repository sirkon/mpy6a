<!-- Promoted from .mailbox/snapshot-refactor/3.md; the letters remain on disk as history. -->

# Snapshot refactor

This document is the implementation specification for moving snapshot control out of `src/index.zig` and
`src/elephant.zig` into `src/snapshot.zig`. It is self-contained: every decision it depends on is stated here.

The baseline is commit `e07a889`. At that commit `zig build test --summary all` reports `41/41 steps succeeded` and the
tree contains 232 test blocks under `src/` (33 in `index.zig`, 9 in `elephant.zig`, 49 in `lifetime.zig`). No source
file is changed by this document; it is the specification for the change.

## 1. Scope and boundary

The boundary is control plane versus data plane.

- `src/snapshot.zig` owns the procedure's policy: the finite state machine, the tick pass, dispatch, the reply passes,
  the drain and swap, the failure ladder, startup recovery, and the cold handlers.
- `lifetime.Controller` keeps every resource it owns today: the snapshot slot pool, `walAdoptWrite`, the adoption marks,
  `copyTempIntoPair`, `runAdoptionRule`, `bringTail`, the registry and `nextElephantRing`. No resource operation leaves
  the Controller, and the Controller's resource API is not dismantled.
- `SnapshotJob` and `SnapshotPhase` stay in `lifetime.zig`, together with `mintSnapshotJob`, `releaseSnapshotJob` and
  `nextElephantRing`, because the job is the resource: arena, paths, descriptors and slot. Only `CompositeWriter`
  moves to `snapshot.zig`; the Controller never references it.
- The import rule is a hard invariant: `snapshot.zig` may import `lifetime.zig`; `lifetime.zig` must never import
  `snapshot.zig`.

No vtable, callback or indirect call is introduced for the seam. Production code uses concrete types. `anytype` is a
test seam only, used where a test must substitute a fake, and even then it is monomorphised into a direct call.

No allocator or ownership change is part of this refactor. The job remains heap on the controller's allocator and is
released only by the terminal elephant; `CompositeWriter.pending` remains on the controller's allocator; the temp ring
remains the slot index. The change is a move of code plus the ownership seam, with one deliberate behaviour fix: D1,
section 5.

## 2. Types and signatures

### 2.1 Host

`snapshot.zig` defines the resource bundle a driver entry point may touch. It carries no behaviour, no context pointer
and no function pointer.

```zig
// src/snapshot.zig
const std = @import("std");
const posix = std.posix;
const lifetime = @import("lifetime.zig");
const logging = @import("logging.zig");
const messages = @import("messages.zig");
const state = @import("state.zig");
const wal = @import("wal.zig");
const cross_task = @import("cross_task.zig");

pub const Serve = enum { serving, frozen, stopped };

pub const PendingPush = struct { slot_idx: u32, target_ring_idx: u16 };

/// What the quiescent drain continues with. `Job.phase` stays `dump_sent`
/// while this is set; the phase names the wire step, not the pump.
pub const Drain = enum { swap, revert };

pub const Host = struct {
    ctrl: *lifetime.Controller,
    ring: *lifetime.RingStuff,
    log: *logging.Logger,
    ring_idx: u16,
    index_idx: u16,
    data_sets: []state.IndexState,
};
```

`Host` is passed by value everywhere. It holds only pointers, a slice and two indices, so the copy is cheaper than an
address-of temporary and cannot go stale.

### 2.2 State

```zig
pub const State = struct {
    serve: Serve = .serving,
    procedure: ?*lifetime.SnapshotJob = null,
    pending_push: ?PendingPush = null,
    window: ?CompositeWriter = null,
    ticks: u32 = 0,
    drain: ?Drain = null,

    pub fn onTick(self: *State, host: Host) void;
    pub fn onReply(self: *State, host: Host, task: cross_task.CrossTask) void;
    pub fn onFlush(self: *State, host: Host, writer: *wal.WalWriteFile) void;
    pub fn onWriterFault(self: *State, host: Host, writer: *wal.WalWriteFile) void;
    pub fn onWriteError(self: *State, host: Host, err: wal.WalError) void;
    pub fn onReadFault(self: *State) void;
    pub fn retryPending(self: *State, host: Host) void;

    pub fn drainPending(self: *const State) bool;
    pub fn drainQuiet(self: *State) bool;
    pub fn onDrained(self: *State, host: Host) void;

    fn tickPass(self: *State, host: Host) void;
    fn dispatch(self: *State, host: Host, payload: cross_task.CrossTask, target_ring_idx: u16) void;
    fn resync(self: *State, host: Host) void;
    fn fdPass(self: *State, host: Host, fd: posix.fd_t) void;
    fn beginSwap(self: *State, host: Host) void;
    fn finishSwap(self: *State, host: Host) void;
    fn beginRevert(self: *State, host: Host) void;
    fn finishRevert(self: *State, host: Host) void;
    fn unwindA(self: *State, host: Host, job: *lifetime.SnapshotJob, opts: UnwindOpts) void;
    fn revive(self: *State, host: Host) void;
};

const UnwindOpts = struct {
    mark_published: bool,
    writer_built: ?*wal.WalWriteFile,
};

fn retryParkedFlush(writer: *wal.WalWriteFile) void;
```

The public surface is what `index.zig` may call. The private methods are reachable from `State` itself and from
`snapshot.zig`'s tests only.

`onFlush` performs only `CompositeWriter.noteFlush`. `onWriterFault` performs only the fault classification, and
`stepCQE` calls both in that order, exactly as `index.zig:450-457` does today. Merging them would change the
double-classification of a new-side fault and is not part of this refactor.

`onWriteError` keeps the name of the front write path's future entry point; its body is today's
`onCompositeWriteError` unchanged. No production caller exists yet, and none is added.

`State.ticks` is retained: it is the existing routing spy used by the index tests.

### 2.3 Elephant

```zig
pub const Elephant = struct {
    ctrl: *lifetime.Controller,
    log: *logging.Logger,
    ring_idx: u16,

    /// True iff `task` is a snapshot variant handled or deliberately warned
    /// about by this actor; false leaves it to the loop's ordinary arms.
    pub fn handle(self: *Elephant, task: cross_task.CrossTask) bool;

    pub fn createSnapshot(self: *Elephant, job: *lifetime.SnapshotJob) void;
    pub fn dumpSnapshot(self: *Elephant, job: *lifetime.SnapshotJob) void;
    pub fn closeSnapshot(self: *Elephant, job: *lifetime.SnapshotJob) void;
    pub fn cleanupSnapshot(self: *Elephant, job: *lifetime.SnapshotJob) void;

    fn jobOf(handle: usize) *lifetime.SnapshotJob;
    fn writeSnapshotFile(self: *Elephant, job: *lifetime.SnapshotJob) !void;
    fn unlinkBestEffort(self: *Elephant, path: [:0]const u8, job: *lifetime.SnapshotJob, kind: []const u8) void;
    fn requestProcessStop(self: *Elephant) void;
    fn replyTo(self: *Elephant, ring_idx: u16, payload: cross_task.CrossTask) void;
};

fn writeAll(fd: posix.fd_t, bytes: []const u8) !void;
fn syncFd(fd: posix.fd_t) !void;
```

The four handlers stay `pub` because the end-to-end tests drive them directly. `handle` returns `true` for all ten
snapshot variants (four requests, six replies) and `false` for `ShutdownDemand`, `SoftShutdown`, `ServerSocket` and
`IndexDrained`; there is no dispatch table and no indirectly called function.

### 2.4 CompositeWriter

```zig
pub const CompositeWriter = struct {
    new: *wal.WalWriteFile,
    old: *wal.WalWriteFile,
    pending: std.ArrayList(PendingEvent) = .empty,
    failed_side: ?Side = null,
    allocator: std.mem.Allocator,

    const PendingEvent = struct { end_new: u64, end_old: u64 };

    pub const Side = enum { new, old };

    pub const Completed = struct {
        /// Events that left the FIFO head on this call.
        count: usize = 0,
        /// Pair-side (`old`) end offset of the last completed event.
        last_end: ?u64 = null,
    };

    pub fn write(self: *CompositeWriter, new_state_idx: u128, data: []u8) wal.WalError!void;
    pub fn noteFlush(self: *CompositeWriter, writer: *wal.WalWriteFile) Completed;
    pub fn quiet(self: *const CompositeWriter) bool;
};
```

The former `onComplete` callback and its opaque context are deleted. Production calls `noteFlush` for its side effect
and ignores the return; tests assert `count` and `last_end`. `Completed` carries both quantities the callback carried.

### 2.5 Free functions

Two entry points do not read `State` and are therefore file-level functions:

```zig
pub fn armTicker(host: Host) void;

pub fn recoverPair(
    ctrl: *lifetime.Controller,
    ring: *lifetime.RingStuff,
    log: *logging.Logger,
    index_idx: u16,
    host_idx: u8,
    st: *state.IndexState,
) !void;
```

`armTicker` reads `host.ring` and `host.ctrl.cfg`. `recoverPair` takes `*logging.Logger` rather than the old
`*lifetime.LoggerStuff`; the body only logs, and `run` already holds `&logger.logger`.

### 2.6 Frame

`index.zig` shrinks to transport and front state:

```zig
const Frame = struct {
    ctrl: *lifetime.Controller,
    ring: *lifetime.RingStuff,
    front_ring: *zigring.Ring,
    logger: *lifetime.LoggerStuff,
    ring_idx: u16,
    index_idx: u16,
    data_sets: []state.IndexState,
    stream_io: wal.FileReadProcess.Io,
    soft_draining: bool = false,
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
```

`WalServe` and `PendingPush` are deleted from `index.zig`; they are `snapshot.Serve` and `snapshot.PendingPush`. The
only snapshot-related production symbols left in `index.zig` are `drainPump`, `host()` and the call sites in `run` and
`stepCQE`.

## 3. Control flow

### 3.1 Loop

The frame is built before the ticker is armed, because arming no longer reads `Frame`:

```zig
var frame = Frame{ ... };
snapshot.armTicker(frame.host());

while (true) {
    frame.snap.retryPending(frame.host());

    const batch = inbox.batch(cfg.batch_k, cfg.batch_k) orelse {
        if (frame.snap.pending_push != null) {
            std.atomic.spinLoopHint();
            continue;
        }
        inbox.hang(cfg);
        continue;
    };

    while (batch.ring.popCQE()) |cqe| stepCQE(&frame, cqe);
    batch.ring.commit() catch |err| {
        log.err("index CQ commit failed", .{ .ring_idx = role.index.ring_idx, .err = @errorName(err) });
        std.process.exit(1);
    };

    if (frame.snap.drainPending()) {
        drainPump(&frame);
        continue;
    }

    while (batch.front.next()) |task| switch (task) {
        .create => |create| {
            if (frame.snap.serve != .serving) { /* refuse, as today */ }
            ...
        },
        .session_op => { if (frame.snap.serve != .serving) continue; },
        ...
    };

    drainReplay(ctrl, own_state, logger, role.index.ring_idx);

    if (frame.soft_draining and own_state.sessions.count() == 0) {
        reportDrained(ring, front_ring, role.index.ring_idx);
        return;
    }
}
```

The post-commit pump check and its `continue` are load-bearing (section 5). The `continue` is safe: `IndexInbox.batch`
stores both windows on the inbox itself, and an unconsumed front task stays queued because `front.next()` was never
called (`src/index_inbox.zig:324-345`, `:372-379`).

### 3.2 Pump

```zig
/// The two writers are quiet, or there is no window: the pump may continue.
fn drainQuiet(self: *State) bool {
    const window = if (self.window) |*w| w else return true;
    retryParkedFlush(window.new);
    retryParkedFlush(window.old);
    return window.quiet();
}

fn onDrained(self: *State, host: Host) void {
    const mode = self.drain orelse return;
    self.drain = null;
    switch (mode) {
        .swap => self.finishSwap(host),
        .revert => self.finishRevert(host),
    }
}
```

`index.zig`:

```zig
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
```

At most one flush is ever in flight per writer, so the drain is bounded. A parked submission is retried on every
pass:

```zig
fn retryParkedFlush(writer: *wal.WalWriteFile) void {
    if (writer.flush_pending and !writer.flush_in_flight) writer.driveFlush();
}
```

The call graph is acyclic: `stepCQE -> State.onReply/onFlush`, `drainPump -> stepCQE -> State...`,
`drainPump -> State.onDrained`. `snapshot.zig` never calls `index.zig`. A transition that needs the ring returns a
continuation (`drain`), and the ring's owner continues it; no function pointer and no module cycle exists.

### 3.3 Transition table

| Current state | Event | Next state | Action |
| --- | --- | --- | --- |
| idle | tick | `create_sent` | Check serve/procedure/pending, pick the pair over the barrier, acquire `k`, mint, dispatch create. |
| `create_sent` | `SnapshotFd` | `dump_sent` | Mark, clone, adopt, install the composite, dispatch dump. |
| `create_sent` | `SnapshotCreateFailed` | `cleanup_sent` | `unwindA` with no mark and no writer. |
| `dump_sent` | `SnapshotDumped` | `dump_sent` + `drain=swap` | `beginSwap`: validate the window; no I/O. |
| `dump_sent` + `drain=swap` | drain quiescent | `close_sent` | `finishSwap`: copy, rewire, clear mark, revive, retire old writer, dispatch close. |
| `dump_sent` | `SnapshotDumpFailed`, `SnapshotAbandon` | `dump_sent` + `drain=revert` | `beginRevert`: validate the window; no I/O. |
| `dump_sent` + `drain=revert` | drain quiescent | `cleanup_sent` | `finishRevert`: close and destroy the new writer, clear the mark, dispatch cleanup. |
| `close_sent` | `SnapshotDone` | idle | Clear `procedure`; the elephant released `k`. |
| `cleanup_sent` | `SnapshotDone` | idle | Clear `procedure`; the elephant released `k`. |
| any | reply while `drain != null` | unchanged | Warn and ignore; no state change, no free. |
| any | illegal reply | unchanged | Warn, no transition, no free. |
| `serving` | old-side fault or `WalFull` | `frozen` | Deny the front; the window keeps serving new-first. |
| `frozen` | successful swap, no live fault | `serving` | Reopen the front. |
| any | new-side fault, or fault outside a window | `stopped` | Terminal for front work; the control plane completes the procedure. |
| any | read walk's terminal `IO` fault | `stopped` | `onReadFault`; the control plane continues. |

`Job.phase` keeps its four values. `drain` is the continuation, not a fifth phase: `Job.phase` still reads `dump_sent`
while a drain is pending, which is the truthful wire state, and the continuation is cleared before the terminal
dispatch.

### 3.4 Response to the tick and to replies

`tickPass` increments `ticks` and returns on each skip guard: `serve != .serving`, `procedure != null`,
`pending_push != null`. It picks the hosted pair with the largest writer extent over the barrier, fixes the tag from
the pair's state, acquires a slot, mints the job, records the slot as in flight, sets `procedure` and dispatches
`SnapshotCreate`. A failed mint releases the slot and ends the pass quietly.

`onReply` dispatches:

- `SnapshotFd` -> `fdPass`.
- `SnapshotDumped` -> `beginSwap`.
- `SnapshotCreateFailed` -> `unwindA` with `{ mark_published = false, writer_built = null }`.
- `SnapshotDumpFailed`, `SnapshotAbandon` -> `beginRevert`.
- `SnapshotDone` -> `procedure = null`.
- anything else -> warn.

While `drain != null`, every reply is ignored with a warning. This closes the duplicate-dispatch class: a second
completion of the same event must not re-enter a half-finished transition.

`fdPass` is one synchronous pass: mark, clone, adopt, install the composite, set `phase = .dump_sent`, dispatch the
dump. `beginSwap` and `beginRevert` only set the continuation; they perform no I/O. `finishSwap` performs the copy, the
rewire, the mark clear, the revival, the retirement and the close dispatch. `finishRevert` closes and destroys the new
writer, returns its descriptor to the job, clears the mark, rolls the slot back and dispatches cleanup.

`unwindA` is memory-only: a half-built writer object is destroyed if present, a published mark is cleared, the slot is
rolled back, the phase becomes `cleanup_sent` and cleanup is dispatched. It is used for create failure, clone
allocation failure and adopt allocation failure.

### 3.5 Serve rules

The front intake guard reads `frame.snap.serve != .serving`. The control plane always flows.

- An old-side fault or an old-side `WalFull` freezes the front. The window keeps writing new-first, so the migration can
  still finish.
- A new-side fault, or a fault outside a window, stops the thread. A relapse after revival finds `window == null` and
  stops terminally.
- A successful swap revives the front if no live writer of the thread's pairs is faulted. The retiring old writer is not
  part of the live set: the window's events were written new-first and the registry line is committed, which is what
  makes serving safe again.
- A read walk's terminal `IO` fault calls `onReadFault`, which sets `stopped`.
- `RecordTooLarge` and `WalGap` are protocol answers, never triggers. Submission backpressure parks in the pending op,
  which the loop retries once per pass.

### 3.6 Elephant loop

```zig
var el = snapshot.Elephant{ .ctrl = ctrl, .log = log, .ring_idx = role.elephant.ring_idx };
...
if (!el.handle(task)) handleOther(ctrl, task, log, role.elephant.ring_idx);
```

`handle` owns `jobOf`, the four request handlers, the "reply it does not handle" warning, `replyTo`,
`requestProcessStop`, `writeSnapshotFile`, `writeAll`, `syncFd` and `unlinkBestEffort`. `handleOther` keeps
`ShutdownDemand`, `SoftShutdown`, `ServerSocket` and `IndexDrained` unchanged. `reportDone` stays in `elephant.zig`: it
is the loop's shutdown report, not a snapshot handler.

### 3.7 Recovery

`index.run` keeps the per-host loop and the fatality policy:

```zig
for (0..ctrl.cfg.wal.hosts()) |host| {
    snapshot.recoverPair(ctrl, ring, log, role.index.inbox_idx, @intCast(host), &data_sets[host]) catch |err| {
        log.err("index recovery failed", .{ .ring_idx = role.index.ring_idx, .host_idx = host, .err = @errorName(err) });
        std.process.exit(1);
    };
}
```

`StartupReplay` and `readWholeFile` are private to `snapshot.zig`. The recovery sequence itself is unchanged: adoption
rule, registry, snapshot, writer, bring-tail, replay.

## 4. Index wiring

`stepCQE` keeps the completion dispatch and loses the procedure bodies:

```zig
messages.CrossTaskMessageIdx => {
    const slot_idx: u32 = @intCast(cqe.res);
    const task = frame.ctrl.cross_slots.at(slot_idx).*;
    frame.ctrl.cross_slots.release(slot_idx);
    frame.snap.resync(frame.host());
    frame.snap.onReply(frame.host(), task);
},
messages.SnapshotTickIdx => frame.snap.onTick(frame.host()),
...
.wal_flush => |flush| {
    flush.writer.flushResult(cqe);
    frame.snap.onFlush(frame.host(), flush.writer);
    frame.snap.onWriterFault(frame.host(), flush.writer);
},
.file_read => |read| {
    read.file_process.onCQE(frame.stream_io, cqe) catch |err| {
        ...
        if (err == error.IO) frame.snap.onReadFault();
    };
},
```

The ticker arm moves out of `run` into `armTicker`; it pushes `SnapshotTickIdx`, stores `tick_spec` in the ring, and
re-captures the stream window with `streamedSQ` after the direct submission, exactly as today.

`dispatch` acquires a cross-task slot, writes the payload and pushes `MSG_RING`. `error.RingFull` parks the pending op
and returns; the loop's `retryPending` repeats only the push. Every direct submission is followed by `resync`, because
the two submission paths share one SQ and the stream's next commit would otherwise rewind it.

`stepCQE`'s read arm keeps the logging and calls `onReadFault` only for `error.IO`.

## 5. D1: the reply-triggered drain

The pre-refactor drain is unsafe inside the loop's batch window.

- `inbox.batch` opens a `BatchCQ` whose `popCQE` advances only the batch cursor; the ring's `cq_head` is not published
  until `commit` (`src/index_inbox.zig:324-345`, `zig-pkg/zigring-0.0.15-*/src/iouring.zig:2189-2220`).
- `stepCQE` is called inside that window (`src/index.zig:352`). A `SnapshotDumped` reply reaches `snapshotDumpedPass`
  (`src/index.zig:649`), which calls `drainUntilQuiet` (`src/index.zig:729`). The drain uses the raw ring
  (`src/index.zig:736`), and raw `popCQE` reads from `ring.cq_head` and advances it immediately
  (`iouring.zig:1504-1521`).
- If the window is not quiet when the reply is handled, the drain's first pop re-reads the completion the batch already
  consumed, because `cq_head` still points at it. The reply is dispatched a second time, re-entrantly, before the first
  pass has finished.
- If the drain pops past the batch cursor (a flush completion behind the reply), the later `batch.ring.commit()` stores
  the batch cursor and rewinds `cq_head` behind completions the drain already consumed and whose slots were already
  released. Those completions can be delivered again.

The suite misses this because the procedure tests call `stepCQE` on raw CQEs (`src/index.zig:3145` and the e2e
drivers), never through `inbox.batch`, and the front write path does not yet keep the window busy under load. The only
production caller of the batch loop is `run`, and the tests do not exercise it.

The pump removes the class: a reply only records a continuation, the batch commits with its cursor untouched, and the
pump runs with no batch open. The reply guard in `onReply` closes the remaining duplicate path.

The regression test:

1. Build a live window and a procedure, as the completion test does.
2. Push a `SnapshotDumped` reply into the index ring, then write one event through the window, so the CQ holds
   `[reply, flush-completion]` in that order and the window is not quiet when the reply is handled.
3. Open `inbox.batch`, pop and step the reply, then `commit`.
4. Assert `cq_head` did not go backwards, `drain == .swap`, the reply was handled once, and no terminal message was
   dispatched yet.
5. Step a second copy of the reply through the reply entry point; assert it is ignored and the state is unchanged.
6. Run `drainPump`; assert the flush was consumed once, `job.phase == .close_sent`, and exactly one `SnapshotClose` was
   sent.

With the pre-refactor code, step 3 re-dispatches the reply and step 4 fails (or the nested pass completes the swap and
the outer pass dispatches cleanup). With the pump, all six hold.

## 6. Implementation order

Each stage is one commit and ends with `zig build test` and `zig build check` green. A stage that cannot keep the suite
green is split, not forced. Current line spans refer to `e07a889`.

### Stage 1: D1, index-local

The only stage that is not a move.

- Delete `drainUntilQuiet` (`index.zig:729-744`).
- Add the index-local `Drain` enum, `Frame.pending_drain`, `drainQuiet`, `drainPump`, `onDrained`, `beginSwap`,
  `beginRevert`, and the test helper `pumpWindow`.
- Split `snapshotDumpedPass` (`:649-727`) into `beginSwap` + `finishSwap`; split `unwindB` (`:786-836`) into
  `beginRevert` + `finishRevert`, dropping the synchronous drain from both halves.
- Change the two completion arms of `dispatchSnapshotReply` (`:515-547`) to the begin functions, and add the
  drain-pending reply guard.
- Add the post-commit pump check and `continue` to the loop (`:352-360`).
- Replace the four surviving direct `drainUntilQuiet` calls (`:2107`, `:2566`, `:3182`, `:3868`) with `pumpWindow`;
  the calls inside the old passes (`:660`, `:799`) disappear with them. Make `drainWriterQuiet` (`:3041-3050`) inline
  the one-line retry.
- Add the six-step regression test from section 5.

Gate: the regression test fails on the pre-stage tree and passes here; suite green at 233 blocks.

### Stage 2: shell

- New `src/snapshot.zig`: imports, `Serve`, `PendingPush`, `Drain`, `Host`, and the `State` fields only.
  `State.window` is typed `?lifetime.CompositeWriter` at this stage.
- `index.zig` imports `snapshot.zig`, adds `Frame.snap: snapshot.State = .{}` and `fn host()`. No call sites change.

Gate: `zig build check` compiles the new file; suite green.

### Stage 3: trigger and its state

- Move `tickPass` (`:901-954`) to `State.tickPass`; `dispatchSnapshot` (`:956-984`) to `State.dispatch`;
  `resyncStream` (`:986-990`) to `State.resync`; `retryPendingPush` (`:992-1005`) to `State.retryPending`; the ticker
  arm (`:308-322`) to `snapshot.armTicker`.
- Remove `wal_serve`, `procedure`, `pending_push` and `snapshot_ticks` from `Frame`; delete `WalServe` and
  `PendingPush` from `index.zig`.
- Retarget `run`'s guards and loop top, and `stepCQE`'s tick arm. `dispatchSnapshotReply` still lives in `index.zig` and
  reads `frame.snap.procedure`.
- Move the four tick/dispatch tests to `snapshot.zig`: `:1421`, `:1483`, `:1541`, `:1579`. The routing test `:1364`
  stays and reads `frame.snap.ticks`.
- Retarget every remaining `frame.wal_serve`, `frame.procedure`, `frame.pending_push` and `frame.snapshot_ticks`
  spelling in the staying tests and the e2e; only `frame.window` remains on `Frame`.

Gate: green; `rg 'frame\.(wal_serve|procedure|pending_push|snapshot_ticks)' src/index.zig` is empty.

### Stage 4: the window and the replies

- Move `dispatchSnapshotReply` (`:515-547`) to `State.onReply`, `snapshotFdPass` (`:549-647`) to `State.fdPass`,
  `unwindA` (`:757-784`), and the Stage 1 `beginSwap`/`beginRevert` into `State`.
- Remove `window` and `pending_drain` from `Frame`; `State.window` and `State.drain` take over. `fdPass` is the first
  writer of `self.window`, which is why the field becomes live here.
- `finishSwap`, `finishRevert`, `onDrained`, `drainQuiet` and `drainPump` stay in `index.zig` until Stage 5 and read
  `frame.snap.*`.
- Move the handler and unwind-A tests to `snapshot.zig`: `:1745`, `:1875`, `:1997`, `:2426`.
- Retarget every remaining `frame.window` spelling; the mechanical ranges are `:1946`, `:2029-2054`, `:2171-2240`,
  `:2270`, `:2331-2350`, `:2387-2398`, `:2460-2480`, `:2549-2573`, `:3148-3215`, `:3663-3701`, `:3741-3770`,
  `:3849-3897`. No assertion changes.

Gate: green; `rg 'frame\.window' src/index.zig` is empty.

### Stage 5: completion, serve and the composite

- Move `onWriterFault` (`:486-513`) to private `State.onWriterFault`, `reviveIfHealthy` (`:838-855`) to `State.revive`,
  `onCompositeWriteError` (`:857-890`) to `State.onWriteError`, `retryParkedFlush` (`:746-755`), plus `finishSwap`,
  `finishRevert`, `onDrained` and `drainQuiet` from `index.zig`. The flush and read arms (`:450-472`) become
  `State.onFlush` and `State.onReadFault`.
- Move `CompositeWriter` (`lifetime.zig:86-164`) to `snapshot.zig` in its section 2.4 shape. `State.window` becomes
  `?CompositeWriter`; `lifetime.CompositeWriter` disappears from the tree.
- Move the revert-completion test `:1805`, the fault tests `:2243`, `:2289`, `:2353`, and the composite test
  `lifetime.zig:3533`. The drain tests (`:2066`, `:2522`, `:3868`) call `pumpWindow` on `frame.snap.window`; the
  completion test (`:2137`) drives `onReply` + `onDrained` through `stepCQE`; the freeze ladder (`:3624`) and e2e
  (`:3182`) use the State surface. `lifetime.CompositeWriter.Side` at `:2338` becomes
  `snapshot.CompositeWriter.Side`.

Gate: green; `rg 'lifetime\.CompositeWriter|onComplete|on_complete_ctx' src/` is empty.

### Stage 6: recovery

- Move `StartupReplay` (`:81-93`), `recoverPair` (`:105-214`) and `readWholeFile` (`:217-247`).
- Retarget the call site (`:294-303`); the error policy stays in `run`.
- Move the six recovery tests: `:2700`, `:2831`, `:2893`, `:2927`, `:2954`, `:2983`.

Gate: green; `rg 'StartupReplay|readWholeFile|recoverPair' src/index.zig` is empty.

### Stage 7: the elephant

- Move `handleTask` (`:53-80`, replaced by `handle`), `jobOf` (`:82-90`), `createSnapshot` (`:92-142`),
  `dumpSnapshot` (`:144-197`), `writeSnapshotFile` (`:199-228`), `closeSnapshot` (`:230-256`), `cleanupSnapshot`
  (`:258-286`), `unlinkBestEffort` (`:288-306`), `requestProcessStop` (`:308-325`), `replyTo` (`:327-350`),
  `writeAll` (`:352-361`) and `syncFd` (`:363-366`). `reportDone` (`:368-379`) stays.
- `elephant.zig` keeps `run`, `handleOther` and `reportDone`. `run` constructs one `snapshot.Elephant` and delegates.
- Move all nine handler tests (`elephant.zig:534-800`) and their fixture and helpers: `ElephantFixture`, `dropLogger`,
  `recvReply`, `deadline`, `cqeWithin`, `mintJob`, `writeRawFile`, `readRawFile`, `fdIsClosed`, `pathExists`, `openRaw`,
  `makeClone`. The fixture gains `fn elephant(self: *ElephantFixture) snapshot.Elephant`.
- The e2e handler calls (`index.zig:3167`, `:3193`, `:3209`, `:3689`, `:3763`, `:3861`, `:3875`, `:3891`) construct one
  `snapshot.Elephant` from the controller, logger and elephant ring, then call the methods. The `elephant.zig` import
  leaves `index.zig`.

Gate: green; `rg -c '^test ' src/elephant.zig` is 0.

### Stage 8: cleanup

- Remove dead imports left by the moves: `elephant` from `index.zig`; `wal`, `config`, `state`, and `posix`/`zigring`
  from `elephant.zig` if the remaining body no longer names them.
- Rename `Frame.draining` to `soft_draining` at `:384`, `:385` and `:408`.
- Do not edit `designs/` and do not change a comment that names a section of `designs/SNAPSHOTS.md`.

Gate: the invariants below; `git diff --stat` shows `index.zig` and `elephant.zig` smaller, `snapshot.zig` growing,
and `lifetime.zig` smaller by the composite.

## 7. Tests

Unit tests travel with the code they test. E2E and pump/wiring tests stay in `index.zig`. No assertion is rewritten
while moving; retargets are compile-time renames of fields and function names.

| Group | From | To | Stage |
| --- | --- | --- | --- |
| Tick guards, candidate pick, pool exhaustion, dispatch park and retry | `index.zig` | `snapshot.zig` | 3 |
| Handler pass, create failure, clone/adopt unwind A | `index.zig` | `snapshot.zig` | 4 |
| Revert completion, fault classification, failed-while-frozen | `index.zig` | `snapshot.zig` | 5 |
| Startup recovery | `index.zig` | `snapshot.zig` | 6 |
| Nine elephant handlers and fixture | `elephant.zig` | `snapshot.zig` | 7 |
| Composite completion | `lifetime.zig` | `snapshot.zig` | 5 |
| Mint/teardown of the job | `lifetime.zig` | `lifetime.zig` | none |
| Drain/completion/batch-cursor and e2e wiring | `index.zig` | `index.zig` | 1-5 |
| Controller resources (slots, registry, adoption, copy, bring-tail) | `lifetime.zig` | `lifetime.zig` | none |

Counts: 18 index tests move, 9 elephant tests move, 1 lifetime test moves; 15 index tests stay, 0 elephant tests stay,
48 lifetime tests stay. Final distribution: `snapshot.zig` 28, `index.zig` 15, `elephant.zig` 0, `lifetime.zig` 48,
plus the Stage 1 regression test: 233 blocks overall.

Shared test helpers are copied, not shared across files: `snapshot.zig` gets copies of `testConfig`, `testHost`,
`dropTestLogger`, `testWriter`, `openPairWriter`, `adoptWindowWriter`, `dropWindow(state: *snapshot.State)`,
`dropTestJob`, `pairControlLine`, `readFileBytes`, `writeFileBytes`, `fileExists`, `expectSameSessions`, `cqeBefore`,
`createWalFile` and the `HoldFlush` sink, each only if a moved test uses it. Duplicating a small fixture is cheaper
than a test-only module and keeps the two test files independently readable. Assertions are never copied.

## 8. Invariants and verification

The repository's commands are the gate:

```sh
zig build test
zig build check
```

`zig build check` compiles every file under `src/`, including files nothing imports (`build.zig:200-240`), so
`snapshot.zig` is compiled from its first line.

After Stage 8 these greps are empty (or at their stated value):

```sh
rg -n '@import\("snapshot.zig"\)' src/lifetime.zig
rg -n '@import\("index.zig"\)|@import\("elephant.zig"\)' src/snapshot.zig
rg -n 'drainUntilQuiet|unwindB|snapshotDumpedPass|dispatchSnapshotReply' src/
rg -n 'frame\.(wal_serve|procedure|window|pending_push|snapshot_ticks)' src/index.zig
rg -n 'lifetime\.CompositeWriter|WalServe|PendingPush|onComplete|on_complete_ctx' src/
rg -n '^(pub )?fn (tickPass|fdPass|beginSwap|finishSwap|beginRevert|finishRevert|unwindA|onReply|onFlush|onWriterFault|onWriteError|onReadFault|revive|drainQuiet|onDrained|retryPending)\b' src/
rg -n 'anytype' src/snapshot.zig
```

The symbol-ownership grep must list only `src/snapshot.zig`. The `anytype` grep must list only test-driven seams, each
documented at its entry point; zero is the steady state. `snapshot.zig` never names `index.zig` or `elephant.zig`, and
`index.zig` drives `State` through `Host` values only.

Behavioural invariants:

- The e2e procedure writes the same files in the same order.
- The registry line is unchanged.
- The path, tag, final-state and slot-release assertions are untouched.
- The six crash-table rows recover through the same startup sequence.
- The D1 regression test asserts `cq_head` is monotonic across a reply-triggered drain, the reply is handled once, and
  a duplicate reply is ignored.

## 9. Risks

| Risk | Mitigation |
| --- | --- |
| The import cycle `snapshot -> lifetime -> index -> snapshot` is resolved lazily. | The tree already has `lifetime <-> index` (`lifetime.zig:27`, `:419`); Stage 2 proves the added edge with `zig build check` before any logic moves. |
| The e2e retargets are broad (about forty field spellings). | Every retarget is a compile-time rename; a missed site fails a stage gate, not the behaviour. |
| The pump spins when the window is not quiet and no completion arrives. | It parks on the ring exactly as the old drain did; a flush in flight is the event that wakes it, and at most one flush per writer is in flight. |
| The reply guard hides a protocol bug. | It warns with the ring and leaves all state untouched; legal replies still arrive after the pump commits, and the regression test covers the legal path. |
| Test fixtures duplicate across files. | Bounded to setup helpers; assertions never duplicate. A helper that outgrows its call sites moves to the file owning the majority of its callers. |
| The drain continuation changes when the swap happens (one committed batch later). | The pump runs immediately after the commit, before any front task, so the only difference is that the reply pass no longer re-enters the CQ. The ordering is deterministic and the regression test pins it. |

## 10. Non-goals

- `designs/SNAPSHOTS.md` is not amended and does not become the current document. It stays as the implementation
  prelude that produced the code.
- No documentation stage is part of this refactor; the current design document is written after the code lands.
- No allocator or ownership change.
- No wire-format change.
- No behaviour change other than D1's fix.
