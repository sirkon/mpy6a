# Index state snapshot SDK

How to take a consistent snapshot of one index's state: **clone the own data set into an arena, then serialize the
clone**. The live state is never touched by the writer, and a single `arena.reset(.free_all)` releases the clone and the
snapshot bytes together.

Normative sources:

- `designs/INDEX-STATE.md` §5, §6, §8, §12 — the queue, the Controller surface, the byte formats, and the clone/dump
  seam.
- `designs/wal-design.md` §12 — the surrounding snapshot procedure (timer, flag, elephant, registry) that this SDK plugs
  into.
- Implementation: `src/state.zig`, `src/replay_queue.zig`, `src/lifetime.zig` (the index-state banner section,
  `Controller.cloneIndexState`, `Controller.dumpIndexState`, `Controller.loadIndexState`).

## 1. The recipe

```
index thread                                elephant thread
-----------                                 ---------------
1. arena = ArenaAllocator.init(ctrl.allocator)
2. clone = ctrl.cloneIndexState(own, arena.allocator())
3. hand the job to an elephant  ---------> 4. out: ArrayList(u8) = .empty
                                            5. ctrl.dumpIndexState(&clone, &out)
                                            6. write out.items to the snapshot file
                                            7. fdatasync the snapshot file
                                            8. arena.reset(.free_all)
                          <--------------- 9. reply OK / failure
10. on OK: finish the WAL swap
11. append the registry line, fdatasync it   (the commit point)
12. clear the snapshot flag
```

Two rules make the whole thing safe:

- **The clone happens on the index thread**, between service-loop passes, while the data set is quiescent. The data set
  is thread-local (`designs/INDEX-STATE.md` invariant 9): no locks, no atomics, no concurrent mutation.
- **The elephant only ever sees the clone.** It must never receive a pointer to the live `IndexState`.

The clone is the own data set only, the one at `cfg.host_index`. Mirror data sets are other hosts' snapshots and are
never cloned by this path.

## 2. API at a glance

All behavioral functions are methods of `lifetime.Controller`:

```zig
pub fn initIndexState(self: *Self, st: *state.IndexState) !void;
pub fn deinitIndexState(self: *Self, st: *state.IndexState) void;

pub fn cloneIndexState(
    self: *Self,
    st: *const state.IndexState,
    arena: std.mem.Allocator,
) !state.IndexState;

pub fn dumpIndexState(
    self: *Self,
    st: *const state.IndexState,
    out: *std.ArrayList(u8),
) !void;

pub fn loadIndexState(self: *Self, bytes: []const u8) !state.IndexState;
```

| Method            | Thread                  | Allocator of the result                             | Release with                     |
| ----------------- | ----------------------- | --------------------------------------------------- | -------------------------------- |
| `cloneIndexState` | index                   | the caller's `arena`                                | `arena.reset(.free_all)`         |
| `dumpIndexState`  | elephant (over a clone) | `st.replay_queue.allocator` (the arena for a clone) | the same arena reset             |
| `loadIndexState`  | startup thread          | `ctrl.allocator`                                    | `ctrl.deinitIndexState(&loaded)` |

`dumpIndexState` deliberately grows `out` with `st.replay_queue.allocator` (`src/lifetime.zig:619`). For a clone that
allocator **is** the arena, so the clone and the dump bytes have exactly one owner. For a live state it is the live
allocator; tests rely on that when they dump without cloning.

## 3. Step by step

### 3.1 Index thread: create the arena and clone

```zig
const state = @import("state.zig");

/// One in-flight snapshot procedure. The shell is owned by the controller
/// allocator; the arena owns the clone and everything the dump allocates.
pub const SnapshotJob = struct {
    arena: std.heap.ArenaAllocator,
    clone: state.IndexState,
    host_idx: u8,
    index_idx: u16,
    state_tag: u128,
};

pub fn beginSnapshot(
    ctrl: *lifetime.Controller,
    own: *const state.IndexState,
    host_idx: u8,
    index_idx: u16,
) !*SnapshotJob {
    const job = try ctrl.allocator.create(SnapshotJob);
    errdefer ctrl.allocator.destroy(job);

    job.arena = std.heap.ArenaAllocator.init(ctrl.allocator);
    errdefer job.arena.deinit();

    job.clone = try ctrl.cloneIndexState(own, job.arena.allocator());
    job.host_idx = host_idx;
    job.index_idx = index_idx;
    job.state_tag = own.state; // runtime-only; the file name carries it
    return job;
}
```

What the deep copy covers (`src/lifetime.zig:739`):

- every `*state.Session` struct;
- the session-owned compensator name bytes;
- the `Buffer.backing` of `data.data`;
- every replay-queue blob (`push` copies into the clone's queue).

The clone shares no allocation with the live state. Reading the live state from the elephant is therefore impossible by
construction.

### 3.2 Hand off to an elephant

The slot payloads in `src/cross_task.zig` are plain data and never run destructors, so pass the job as an integer handle
(or add a dedicated plain-data variant). The arena must outlive the whole procedure: do not put it on the index thread's
stack if the thread continues working.

```zig
// A plain-data CrossTask variant in src/cross_task.zig:
//     Snapshot: struct { job: usize },

const slot = try ctrl.cross_slots.acquire();
ctrl.cross_slots.at(slot).* = .{ .Snapshot = .{ .job = @intFromPtr(job) } };
// ... push MSG_RING to the chosen elephant ring.
```

The variant carries the job as a `usize`, not as `*SnapshotJob`: `CrossTask` values are stored by copy and never
destroyed, and its comptime check rejects pointer fields and owned memory. The arena must outlive the whole procedure,
so keep the job off the index thread's stack.

### 3.3 Elephant thread: serialize the clone

```zig
pub fn finishSnapshot(
    ctrl: *lifetime.Controller,
    job: *SnapshotJob,
) !void {
    var out: std.ArrayList(u8) = .empty;

    try ctrl.dumpIndexState(&job.clone, &out);
    // out.items is the complete snapshot; see §4.
}
```

Initialize `out` empty and let `dumpIndexState` grow it. Do not deinit it, and do not construct it with a different
allocator: its bytes belong to the arena, and §3.5 releases them.

### 3.4 Make the snapshot durable (elephant)

The snapshot file is created **under its final name**, with no temporary names, no renames (`designs/wal-design.md`
§12):

```
snapshot.<host_idx>.<index_idx>.<state>
```

`<state>` is the whole `state: u128` rendered as **32 lowercase hex digits**, fixed width. It is the tag of the
procedure start, and its only semantics is "just some unique tag"; nothing derives an epoch or a slice back from it. The
tag is what restores `st.state` at load.

Write the dump, then one `fdatasync` of the snapshot file. That is the only durability barrier on the snapshot side; the
WAL path never fdatasyncs.

```zig
pub fn writeSnapshotFile(
    io: std.Io,
    path: []const u8,
    bytes: []const u8,
) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
    try std.posix.fdatasync(file.handle);
}
```

### 3.5 Release: one arena reset (elephant)

After the file write and its `fdatasync`, before replying OK:

```zig
job.arena.reset(.free_all);
ctrl.allocator.destroy(job);
```

`reset(.free_all)` releases the clone and every allocation the dump made, in one act. Nothing on the snapshot path is
freed field by field: no `deinitIndexState` on the clone, no `Session`-by-`Session` walk, no `out.deinit(...)`.

On failure, the same reset/destroy runs; the uncommitted final-named files are junk under the registry's precedence rule
and are removed by retention, not by the failure path.

### 3.6 Commit the registry (index thread)

After the elephant replies OK, the index thread finishes the WAL swap and only then appends one registry line and
fdatasyncs the registry. This append is the transaction's commit point. The registry is `<wal_path>.log`, a sibling of
the WAL family:

```
host_idx:index_idx:snapshot-path:wal-path\n
```

The design commits the line with a single append write (append-atomic-or-torn in practice; a torn line is ignored by the
hard-stop rule). In Zig 0.17 an append is a create-without-truncate followed by a positional write at the current
length:

```zig
pub fn appendRegistryLine(
    io: std.Io,
    registry_path: []const u8,
    line: []const u8,
) !void {
    const reg = try std.Io.Dir.cwd().createFile(io, registry_path, .{ .truncate = false });
    defer reg.close(io);
    const end = try reg.length(io);
    try reg.writePositionalAll(io, line, end);
    try std.posix.fdatasync(reg.handle);
}
```

A failure before this append leaves the pair unreferenced: recovery takes the previous registry line and the new files
are junk. A failure after it is a committed transaction.

## 4. Byte format

The dump is a single byte string. Integers are little-endian; lengths are base-128 `uvarint`s. `SNAPSHOT_VERSION` is
`1`.

### 4.1 Data set

```
version: LE(u16)                         // = 1
uvarint(sessions.count())                // no separate count field
session records, in map iteration order  // order is not part of the format
uvarint(replay_queue.count())
replay blobs, in (retry_time, id) order  // order IS part of the format
```

Per-session record:

| Field                           | Encoding    |
| ------------------------------- | ----------- |
| current session id (map key)    | `LE(u128)`  |
| serialized `SessionData` length | `uvarint`   |
| `SessionData` bytes             | codec below |

`session_id` is the **current** id, not `original_id`: for a re-activated session they differ, and the map cannot be
rebuilt without the key.

Sessions are emitted in map iteration order. The loader is order-agnostic there.

The queue section is ordered by `replay_queue.blobOrder`: numeric `retry_time` first, `session_id` as the tiebreaker. A
`memcmp` over the LE bytes is not that order and is never used. The loader accepts only a nondecreasing sequence and
rejects anything else.

How the dump is produced: `dumpIndexState` writes the version and the session count, walks `st.sessions` calling
`encodeSessionData` per record, then asks the queue for `snapshotHandles`, sorts those handles with `blobOrder`, and
appends the blobs verbatim. It reads nothing else from the data set, and `st.state` is never consulted.

### 4.2 `SessionData`

Exactly the persisted fields; the runtime meta never rides:

| Field                      | Encoding                         |
| -------------------------- | -------------------------------- |
| `original_id`              | `LE(u128)`                       |
| `uvarint(compensator.len)` | `uvarint`                        |
| `compensator`              | bytes                            |
| `retry_count`              | `LE(u32)`                        |
| `uvarint(data.len)`        | `uvarint`                        |
| `data`                     | chunked payload, already encoded |

`data` is the existing chunk stream: one or more of `uvarint(chunk.len) || chunk`. Create writes one chunk (a
payload-free Create writes a single `0` length byte); Append adds one at the tail; Overwrite replaces the whole content
with one.

Minimum `SessionData` is 22 bytes: 16 + 1 + 4 + 1.

### 4.3 Replay blob

| Field                       | Encoding                              |
| --------------------------- | ------------------------------------- |
| `retry_time`                | `LE(u64)`, CLOCK_REALTIME nanoseconds |
| `session_id`                | `LE(u128)`                            |
| `uvarint(session_data.len)` | `uvarint`                             |
| `session_data`              | `SessionData` codec                   |

The fixed head is 24 bytes (`RETRY_TIME_OFF = 0`, `SESSION_ID_OFF = 8`, `BLOB_HEAD = 24`). A blob is at least 25 bytes.
The queue dump writes blobs **verbatim**, so the dump's queue section is a byte-for-byte concatenation of queue entries
in queue order.

### 4.4 Size accounting

```
session_data_len = 16 + varint(comp.len) + comp.len + 4 + varint(data.len) + data.len
blob_len         = 24 + varint(session_data_len) + session_data_len
dump_len         = 2
                 + varint(sessions.count())
                 + sum(16 + varint(session_data_len) + session_data_len)
                 + varint(replay_queue.count())
                 + sum(blob_len)
```

Use this for the dump buffer estimate. The elephant writes with a plain buffered writer, not io_uring: a large
placeholder makes io_uring meaningless here.

### 4.5 What is not in the dump

- `st.state` — runtime-only. The snapshot file's `<state>` name tag carries it.
- `Session` meta: `index_idx`, `upgrade_idx`, `wheel_idx`, `state`, `consensus_progress`. The loader starts them at the
  resting state (`ExpectOp`, zeros, `index_idx = 0`), and the consensus driver / WAL replay moves them afterwards.
- `sessions_count` — implied by `uvarint(sessions.count())`.
- The queue's heap array layout — only the logical queue order is persisted.

## 5. Loading a snapshot

`loadIndexState` is the inverse of `dumpIndexState` and is the first step of the startup sequence: read the snapshot
named by the registry's last valid line, set `st.state` from the file name, then replay the WAL over it.

```zig
var loaded = try ctrl.loadIndexState(bytes);
defer ctrl.deinitIndexState(&loaded);
loaded.state = state_tag; // the u128 decoded from the snapshot file name
```

The loader:

- rejects `bytes.len < 2` with `error.CorruptInput`;
- rejects any version other than `1` with `error.UnsupportedVersion`;
- bounds-checks every length against the remaining bytes;
- rejects a queue section that is not nondecreasing in `blobOrder`;
- rejects trailing bytes (`pos != bytes.len`);
- allocates the returned state and every session with `ctrl.allocator`, so it is released with `deinitIndexState`,
  **not** an arena reset;
- returns `state = 0`; the caller must set it from the name tag before any op is applied. Losing the tag loses mint
  continuity and can duplicate session ids.

Recovery order is fixed: snapshot first, then the WAL over it. Each replayed record moves `st.state` through its
`upgrade`, so the tag is only the starting point.

## 6. Ownership and lifetime rules

1. **Clone on the index thread, dump on the elephant.** The clone is the handoff boundary; the elephant never
   dereferences the live state.
2. **The arena owns the clone and the dump bytes.** Initialize it with `ctrl.allocator`; one `reset(.free_all)` right
   after the snapshot write and its fdatasync releases both. Do not mix in another allocator for `out`, and do not
   `out.deinit(...)`.
3. **Never `deinitIndexState` a clone.** Sessions would be freed with `ctrl.allocator` although they are arena memory,
   and the map/queue would be deinited into the arena. The reset owns all of it.
4. **The job shell is not arena memory.** Allocate `SnapshotJob` with `ctrl.allocator` and destroy it after the arena
   reset; otherwise the reset would free the job mid-function. Keep it at a stable address: `arena.allocator()` captures
   `&job.arena`, so moving or copying the job after the clone invalidates the clone's allocator.
5. **Only the own data set is cloned.** `data_sets[ctrl.cfg.host_index]`; mirrors belong to their hosts' procedures.
6. **At most one snapshot procedure process-wide.** The caller's atomic flag serializes the final names; it is not part
   of the snapshot API.
7. **No time logic in the snapshot path.** Blobs already carry absolute `retry_time`; the dump copies them.
   `nowRealtimeNs()` is for arming replay, not for dumping.

## 7. Correctness checklist

- [ ] The clone was taken on the index thread, not the elephant.
- [ ] `job.clone` is a value; `dumpIndexState` received `&job.clone`.
- [ ] `out` started empty and was never deinited.
- [ ] The snapshot file name contains the full `u128` state tag from the clone's procedure start.
- [ ] The snapshot file was fdatasync'd before the elephant replied OK.
- [ ] `arena.reset(.free_all)` ran once, after the write and its fdatasync.
- [ ] The index thread appended the registry line and fdatasync'd the registry only after the OK reply and the WAL swap,
      before clearing the flag.
- [ ] On load, `st.state` was set from the name tag before the first op.
- [ ] The loaded state is freed with `deinitIndexState`, not an arena.

## 8. Errors

| Error                      | Produced by       | Meaning                                                                |
| -------------------------- | ----------------- | ---------------------------------------------------------------------- |
| `error.OutOfMemory`        | clone, dump, load | allocation or arena exhaustion                                         |
| `error.UnsupportedVersion` | load              | version field is not `SNAPSHOT_VERSION`                                |
| `error.CorruptInput`       | load              | malformed length, truncated record, queue out of order, trailing bytes |

`dumpIndexState` and `loadIndexState` have inferred error sets; treat everything other than the two named load errors as
infrastructure failure and abort the procedure. A failed dump must not gain a registry line.

## 9. Reference integration

The pieces together, with the process `lifetime.Controller` and an elephant thread assumed:

```zig
const SnapshotJob = struct {
    arena: std.heap.ArenaAllocator,
    clone: state.IndexState,
    host_idx: u8,
    index_idx: u16,
    state_tag: u128,
};

/// Index thread, between service-loop passes. Returns the job to hand to an
/// elephant through a cross-task slot.
pub fn beginSnapshot(
    ctrl: *lifetime.Controller,
    own: *const state.IndexState,
    host_idx: u8,
    index_idx: u16,
) !*SnapshotJob {
    const job = try ctrl.allocator.create(SnapshotJob);
    errdefer ctrl.allocator.destroy(job);

    job.arena = std.heap.ArenaAllocator.init(ctrl.allocator);
    errdefer job.arena.deinit();

    job.clone = try ctrl.cloneIndexState(own, job.arena.allocator());
    job.host_idx = host_idx;
    job.index_idx = index_idx;
    job.state_tag = own.state;
    return job;
}

/// Elephant thread. Synchronous and blocking. `snapshot_path` was minted by
/// the index thread at procedure start; the elephant creates and writes it
/// under that final name.
pub fn runSnapshot(
    ctrl: *lifetime.Controller,
    io: std.Io,
    job: *SnapshotJob,
    snapshot_path: []const u8,
) !void {
    defer {
        job.arena.reset(.free_all);
        ctrl.allocator.destroy(job);
    }

    var out: std.ArrayList(u8) = .empty;
    try ctrl.dumpIndexState(&job.clone, &out);
    try writeSnapshotFile(io, snapshot_path, out.items);
}

/// Index thread, after the elephant replied OK and the WAL swap finished.
/// This append is the transaction's commit point.
pub fn commitSnapshot(
    io: std.Io,
    registry_path: []const u8,
    host_idx: u8,
    index_idx: u16,
    snapshot_path: []const u8,
    wal_name: []const u8,
) !void {
    var line_buf: [512]u8 = undefined;
    const line = try std.fmt.bufPrint(
        &line_buf,
        "{d}:{d}:{s}:{s}\n",
        .{ host_idx, index_idx, snapshot_path, wal_name },
    );
    try appendRegistryLine(io, registry_path, line);
}
```

The index thread computes both final names at procedure start (`snapshot.<host_idx>.<index_idx>.<state>` and
`<wal_path>.<index_idx>.<host_idx>.<state>`, with `<state>` as 32 lowercase hex digits) and keeps them in
`snapshot_in_progress`. Carry the snapshot path with the job (arena-dup it if needed) so the elephant writes under the
final name without parsing anything. On the elephant's OK the index thread must also wait out both WAL sides' in-flight
flushes, drop the old side, memcpy the new battery, and swap the interfaces; only then does it append the registry line
(`designs/wal-design.md` §12). This SDK stops at "the clone was serialized and made durable".

## 10. Testing the path

The repository's tests already exercise every seam (`zig build test`):

- `cloneIndexState is a deep copy` — pointers differ, the clone's dump rides the arena (`src/lifetime.zig:1581`).
- `dump and load round trip the whole data set` (`src/lifetime.zig:1468`).
- `an empty data set round trips and a future version is rejected` (`src/lifetime.zig:1509`).
- `the dump never contains the runtime state` (`src/lifetime.zig:1531`).

A snapshot test should at minimum:

1. Build a data set with two active sessions and one queued replay session.
2. Clone it into an arena, dump the clone, drop the live state, then `loadIndexState`.
3. Compare every persisted field and both counts; assert a dump of the clone and a dump of the original load to equal
   states.
4. Corrupt the queue order and assert `error.CorruptInput`.
5. Bump the version byte and assert `error.UnsupportedVersion`.
6. Assert the state tag never appears in the dump.

## 11. Pitfalls

- **Dumping the live state from the elephant.** It is a data race with the index thread, and the clone exists precisely
  to make that impossible.
- **Deiniting `out` on a clone.** `dumpIndexState` grows `out` with the queue's allocator, so its buffer is arena
  memory. `out.deinit(ctrl.allocator)` is a wrong-allocator free; let the arena reset own it.
- **Freeing the clone field by field.** `deinitIndexState` frees sessions with `ctrl.allocator`, while the clone's
  sessions live in the arena: a wrong-allocator free, and the map/queue deinit is at best a no-op before the reset. Use
  the reset only.
- **Forgetting the state tag.** A loaded data set starts at `state = 0`; without the name tag the next mint collides
  with existing ids.
- **Assuming session order.** Map iteration order is not stable; only the queue order is normative. Never compare raw
  dumps for equality unless both came from the same map state and iteration, or compare after load.
- **Treating `retry_time` as monotonic.** It is CLOCK_REALTIME nanoseconds so it survives a reboot; never replace it
  with a monotonic clock.
- **Writing the snapshot before cloning.** The buffer must be the clone's, not a snapshot of a state that continued
  changing while the dump ran.
