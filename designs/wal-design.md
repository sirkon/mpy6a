# WAL design

Promoted from `.mailbox/wal-design/9.md` (history in `.mailbox/wal-design/`).

The buffered battery writer, reader, crash recovery, rotation, and snapshotting for `mpy6a`.
Sources this design was worked from: `designs/WAL.md`, `docs/consensus.md`,
`docs/shard-arch-concept.md`, `docs/shard-arch-hld.md`, `designs/CONSENSUS-PLAN.md` (2.5, 4.4),
`src/wal.zig` (`readAfter`, the scan, `wal_flush`), `src/index.zig` (`openReplicaLog`,
`finishFlush`, `answerSnapshotRequest`), `src/elephant.zig`, `src/slots.zig`, `src/wire.zig`
(`RequestLog` / `RequestSnapshot`), `src/config.zig` (`wal_path`),
`docs/consensus-network-protocol.md` (log transport).

## 1. Decisions

- **Durability contract.** WAL files are opened `O_DIRECT`; there is no page cache anywhere in the
  WAL path and deliberately no fsync/fdatasync/FUA in either mode. Non-PMEM durability covers the
  process crash exactly: a record is durable once its buffer's `O_DIRECT` flush completed, and a
  power cut may lose even completed flushes that still sit in the device's volatile write cache —
  accepted; power-loss durability is what PMEM mode exists for. The un-flushed tail lost to a
  process crash is recovered from the quorum through the background sync (`docs/consensus.md`, the
  `RequestLog` service of stage 7).
- **Flush I/O mode.** `O_DIRECT` in both modes, mode-independent open flags, and buffers laid out
  so the alignment requirement holds by construction (§4).
- **Geometry.** The control line is never written to disk; it is battery metadata only, one
  64-byte cache line so that a barrier write covers it with one CLWB. The data area is one device
  LBA. A flush is always one whole data area at an LBA-multiple file offset, so file-side
  `O_DIRECT` alignment is automatic and the file length is always a multiple of the LBA. Each
  file's buffers form a ring addressed by head and tail — plain fields, no atomics — because every
  write and read task is set up in the index thread that owns the file. The NVDIMM pool is
  partitioned, not searched: with the number of indexes and the replication factor both known at
  startup, the required pool length is known, and the battery of a given index of a given host sits
  at a computed offset (§4).
- **LBA is a runtime parameter.** Read from configuration at startup, not a comptime constant:
  replacing the SSD (4 KiB → 16 KiB LBA) must not require a recompile. The comptime surface of
  `WALFile` is the mode (`pmem` / non-PMEM) and nothing else LBA-dependent; every LBA-dependent
  value is a runtime field or is computed at open. Changing the LBA of an existing deployment goes
  through the migration tool, never through a plain restart (§11).
- **The terminator rule.** An exactly filled buffer is never exposed (control line persisted,
  flush queued) before its successor's control line is initialized to `data_len = 0`, filled flag
  cleared, and persisted — otherwise a restart would see a filled tail whose successor still
  carries a stale line from a previous ring lap and would replay garbage. Generalized, this is the
  battery's core invariant: **a data area only ever receives bytes after its own control line has
  been persisted as a zero-terminator.** Every path that makes a slot current (open-reset,
  exact-fill transition) satisfies it.
- **The open block.** Incomplete blocks have no block CRC, at a crash and at a clean close alike.
  The loosening is a probability tradeoff, accepted: block CRCs reduce the chance of undetected
  bit rot, they never make it zero, and the tail block additionally rides on the per-record
  checksums and the self-delimiting framing, with replay stopping at the first torn record. The
  running CRC of the open block lives in `WALFile` RAM registers and in the current slot's control
  line (`crc_running`), and is restored at open (§9).
- **One type, two initializations.** A single `WALFile` comptime-parametrized by the mode.
  PMEM-only barrier writes; different initialization only: the battery is a computed slice of the
  process-wide DAX-mapped NVDIMM pool in PMEM mode, and one ordinary aligned allocation of the
  whole buffer space otherwise.
- **Exact-fill gate.** Kept, but only in PMEM mode, through the comptime branch of the gate
  (`if (mode == .pmem)`). Non-PMEM accepts the fill: no walk ever consults a RAM battery.
- **No durability notification.** The consensus tract never gates a client answer on local
  durability: the leader answers on quorum approval (`docs/consensus.md`), and in non-PMEM
  deployments the survival of a host's tail rides on replication and the background sync, not on
  its own disk. The WAL therefore exposes no durability waiters, no FIFOs, and no per-record
  completion events; `write()` returning means the record is buffered, nothing more — §7 states
  what the driver does with that.
- **The name is a full-state tag.** `<state>` is the whole `state: u128` rendered as 32 lowercase
  hex digits; its only semantics is "just some unique tag" (§2). The tag is opaque: never parsed,
  no slice ever derived back from it.
- **No WAL without a pair.** Every `(host, index)` is a **snapshot + WAL file pair, always**. A
  WAL file never exists without its snapshot, and a snapshot always carries its WAL reference. At
  the very first start of an index state the process creates a **pair with no data** — an empty
  snapshot and an empty WAL file — and the registry names it (§12).
- **The registry is the source of truth.** A fixed registry log file, `<wal_path>.log`, holds one
  line per committed pair; **the last valid line for a given `(host_idx, index_idx)`** names that
  index state's snapshot and WAL (§12). A line that does not match the format is a HARD STOP: it
  and every line after it are ignored — a torn tail simply means the transaction it would have
  committed is not committed.
- **Snapshot durability, once.** The elephant fdatasyncs the snapshot file after the dump, before
  replying OK — the one fdatasync on the whole snapshot path. The registry commit is a second,
  distinct fdatasync — the transaction's commit point (§12). Nothing else in the design
  fdatasyncs: the WAL path never does, in either mode.

## 2. File identity, threading, and naming

One file per (index thread, host). The file of `(index_idx, host_idx)` is

```
<wal_path>.<index_idx>.<host_idx>.<state>
```

where `<state>` is the **full `state: u128`** — the whole `(host_id: u8, index_id: u16,
epoch_id: u40, index: u64)` concat of CONSENSUS-PLAN 2.5 — rendered as **32 lowercase hex digits**:
fixed width, so lexicographic order equals numeric order, and no separator hazards. Its **only
semantics is "just some unique tag"**: the name is never parsed, no slice of it is extracted, and
nothing (least of all an epoch) is ever derived back from it.

Tags are minted only at **file creation** — at rotation (§8) and at pair creation / snapshot
finalization (§12) — using the then-current full state; never per write, per open, or per state
advance, so the file count is unchanged. `state` is monotone per `(host, index)` within and across
epochs (the `index: u64` counter advances, the `epoch_id` bumps at rotation), so a minted tag never
collides with an existing name: **uniqueness by construction**. The `host_id`/`index_id` slices
inside `state` are redundant with the explicit `<host_idx>.<index_idx>` components — kept as
explicit components anyway, for ordering and greppability; the tag itself is opaque.

**Order survives opacity.** The semantics freeze is on the _name_, not on the _u128_: the
big-endian concat makes `state` comparison a total order consistent with recency, which is exactly
what retention needs (§12). Retention compares states; it never decodes them.

The own log of index thread `i` is the `(i, own_host)` file under the same scheme — the own host's
slot, skipped by today's `openReplicaLog`, becomes the own log instead of a hole in the array; a
replica log is the `(i, h)` file with `h ≠ own_host`. Today every index thread opens the bare
`wal_path`, which the stub tolerates only because 43-byte `O_APPEND` writes interleave whole; the
battery scheme needs one writer per file, and now every thread has exactly one. An empty
`wal_path` keeps no logs at all (existing semantics). The log of a host is the union of the
per-index files; ordering inside one file is total, and each session lives in exactly one file
(sessions are partitioned across index threads by id).

Logs are **rotated**: old log files stay around for a while, and the moment of switching to a new
file is reflected into the new file's name, as a function of `state`. The epoch bump is bound to a
state index threshold: rotation is triggered by the epoch's `index` slice reaching a configured
bound; the new file opens at a fresh index base, so the u64 counter never approaches its ceiling
within one epoch — the wrap-around gap is closed by construction. The §8 close runs at rotation
exactly as at shutdown, so a rotated-out file is a complete, replayable unit. Rotation triggers
beyond the epoch-bump threshold stay where they were (§12's closing note).

```zig
pub const WALController = struct {
    pub fn open(self: *Self, host_idx: u8, index_idx: u16, state: u128) !*WALFile {}
    pub fn delete(self: *Self, host_idx: u8, index_idx: u16, state: u128) !void {}
};
```

Both `host_idx` and `index_idx` are required to name a file, and neither is derivable from the
other: within an index thread, the thread writes its **own** log and replicates the logs of its
mirror indexes living on other hosts. `index_idx` is asserted equal to the caller's thread ordinal
on the own-log path. The controller is a process-wide table over (index, host) → file + battery,
but each entry is touched only by its index thread; nothing WAL-related crosses threads (records
produced elsewhere already arrive through the inbox as this thread's work), so the battery
head/tail and the flush queue are plain fields.

`open` names the file by the **current** tag of the `(index, host)` slot — the tag minted at the
last rotation or pair finalization — not by a slice of the caller's `state`; the caller's state
positions _within_ the file (§9 scan, offset index). The controller holds the current-tag mapping
per `(index, host)`; a restart rebuilds it from **the registry** (§12: the last valid line per
pair), never by parsing names.

**Read cursors** (`read_begin`, `read_seek(state)`) are scoped to **the opened file**: a cursor
never crosses a rotation boundary. `RequestLog` replay of a quorum sync asks for a state at or
above the file's creation tag — the quorum never asks a live file for a state of a previous epoch —
so the scoping needs nothing more; cross-file reads arrive only through recovery, which opens
files explicitly.

## 3. Pinned constants

- **LBA.** The data-area size; a runtime config value, any power of two from 512 to 1 MiB that
  divides the block (1 MiB). Because 1 MiB must be a multiple of the configured LBA, a violating
  config is rejected at startup. The file's `O_DIRECT` geometry is probed once at open; a mismatch
  with the configured LBA is an error **at open**, not deferred to the first flush.
- **Battery.** N buffers per file, the same N for every battery (a config knob). Sizing criterion:
  enough buffers to damp sequential writes — `N × LBA` comfortably above the burst one flush
  round-trip must absorb; N ≥ 2. The slot of logical area position p is `p mod N`.
- **Block.** 1 MiB over the logical stream. Bytes `[0, 1 MiB − 4)` are content; the last 4 bytes
  hold CRC32C (Castagnoli) over the content, zero padding counted. A block boundary always
  coincides with a data-area boundary (the startup check above), so the CRC slot always lands
  inside the last data area of its block, and every block rollover is also a buffer fill.
- **Record.** Unchanged from `src/wal.zig`:
  `magic u16 | len u32 | crc32 u32 | session u128 | op u8 | upgrade u128`, 43 bytes,
  self-delimiting, per-record checksum. One `write()` call is one record. A record that does not
  fit the open block's content remainder zero-pads it — the WAL stores the completed block's CRC
  right then, inside the battery — and starts in the next block; a record larger than a block
  starts at a block boundary and spans blocks. The capacity gate accounts for the pad.

## 4. Battery layout and the pool partition

- **Battery layout.** Columnar: the data array (`N × LBA`) at the battery-area start, aligned by
  construction, so every data area is LBA-aligned and every flush presents an aligned user buffer;
  the control array (`N × u512`) at offset `N × LBA` — a runtime-computed multiple of 64 (every
  legal LBA is a power of two ≥ 512), so every control line is its own aligned CLWB unit. Zero
  slack: the recovery walk reads one linear line per slot from the control array, and `persist()`
  takes one data range plus one control line. The adjacency-keeping alternative (a `2 × LBA`
  stride, doubling the pool) is rejected.
- **Pool partition (PMEM).** The whole NVDIMM area is DAX-mapped once at startup, before threads
  spawn. `battery_area(i, h) = pool_base + (i × R + h) × area_stride`, with
  `area_stride = N × (LBA + 64)` rounded up to **both** an LBA multiple and a page — the LBA
  rounding is required, not chosen: the flush presents `data_area(p)` at
  `battery_base + p × LBA` as the `O_DIRECT` user buffer, and a stride that is not an LBA multiple
  would misalign every area after the first battery. R is the replication factor and i the
  index-thread ordinal — both known at init, so the required pool length is known; a restart
  recomputes the same addresses.
- **Non-PMEM battery.** One `allocAligned` of the whole battery per open file, alignment =
  `max(LBA, 64)` — a runtime alignment argument.
- **Control line.** One cache line per slot: `data_len: u32` (valid bytes in the area; LBA when
  filled), `flags: u32` (bit 0 = filled), `buffer_seq: u64` (the area's file position ÷ LBA — the
  flush offset, and a stale-lap sanity check for the walk), `crc_running: u32` (the running CRC32C
  state of the open block as of `data_len`; meaningful on the current slot, carried to the
  successor's terminator at an exact fill), `reserved: u32`. No `block_crc` — the completed block's
  CRC lives in the block's own last 4 bytes; no closed flag — open resets the ring (§9). The
  control line is never written to disk.

## 5. Write path

`write(record)`, in order, on the owning index thread:

1. **Gate.** `capacity = free_buffers × LBA + (LBA − current.data_len)`, where free counts only
   buffers neither queued nor in flight (a buffer is reusable only after its flush completed).
   `need = record.len + rollover_pad`, where `rollover_pad` is the open block's content remainder
   if the record does not fit it, else 0. `need > capacity` → immediate error, nothing queued,
   battery untouched. PMEM-only (comptime), the exact-fill rule: reject also a write whose
   absorption would end with the last available buffer filled exactly and no free successor.
2. **Rollover.** If the record does not fit the open block's remainder: zero-fill the remainder
   into the battery (zeros into the running CRC), store the block's CRC32C in its last 4 bytes,
   reset the running CRC for the next block. The pad may itself fill areas — run step 4's
   transition for each.
3. **Copy.** Copy the record into the current data area, updating the running CRC incrementally;
   the copy may spill over several areas. `persist()` the freshly written ranges — data first.
4. **Exact-fill transition**, while an area was filled exactly: (a) initialize the successor's
   control line — `data_len = 0`, filled cleared, `buffer_seq = current + 1`, `crc_running` = the
   state the successor's bytes will continue from (a fresh block's state when the fill was also a
   rollover) — and persist it: the terminator first; (b) mark the filled buffer's control line —
   `data_len = LBA`, filled set — and persist; (c) push the filled buffer onto the per-file flush
   queue; (d) the successor becomes current, copying continues.
5. **Tail metadata.** Update the current control line's `data_len` and `crc_running`; persist.
6. **Exit kick.** If the writing flag is clear and the queue is non-empty: register a `wal_flush`
   context in `RingSlots` (the `*WALFile` travels in the `TaskCtx` alongside the existing variants,
   replacing the per-record `flush_op`/`log_command` write path of `src/index.zig`), arm one SQE —
   `write(fd, data_area(queue head), LBA)` at offset `buffer_seq × LBA`, `O_DIRECT` — set the
   flag, return.

`persist(range)` is the single point of divergence: CLWB per line, then one SFENCE, in PMEM mode;
a comptime no-op otherwise. Data is always persisted before any control line that exposes it.

## 6. Flush path

One flush SQE in flight per file, strictly sequential: a failed write N can never be preceded in
the file by N+1's bytes at a known length, so the file length stays a meaningful recovery cursor.
Nothing prevents different files from flushing in parallel — the contexts are per file.

The CQ handler, on a `wal_flush` completion:

1. Return the flushed buffer to the front of the free order (cache warmth).
2. Queue empty → clear the writing flag; otherwise arm the next SQE from the queue head, the flag
   stays.
3. Continue the handler's own work; the WAL never blocks the ring loop.

A completion with `res != LBA` is a failure and stalls the file: keep the queue and the buffer,
report the error once, do not rearm. The file stays failed until the controller decides; the
queue order is intact — nothing past the failure was ever written — so a controller-level retry of
the same head is always safe.

## 7. No durability notification

The consensus tract answers the client on quorum approval and never on local durability; in
non-PMEM deployments a lost host's tail is rebuilt from the mirrors by the background sync
(`docs/consensus.md`). The WAL has no durability surface at all: no waiters, no FIFOs, no
per-record completion events — `write()` returning means the record is buffered, nothing more.
The flush pipeline exists for recovery, not for notification. The own-log flush of CONSENSUS-PLAN
2.5 step 5 becomes the synchronous battery write, and the step that today rides the `flush_op`
completion (`finishFlush` of `src/index.zig`: the session advance to `ExpectReply` and the client
reply of step 6) moves inline into the driver. In PMEM mode, `write()` returning is incidentally
the durability point — data and the exposing control lines already passed CLWB → SFENCE before
any flush; the property stands, unconsumed: no consensus step waits for it.

**Clarification.** The elephant's OK/failure reply in the snapshot procedure (§12) gates a **file
lifecycle transition**, not a client answer and not a record's durability: no consensus step waits
for it, and `write()` returning still means "buffered, nothing more". The notification surface of
this section (no waiters, no FIFOs, no per-record events) is unchanged; the snapshot procedure is
a controller-internal state machine, not a WAL durability surface.

## 8. Close

Pad the current data area with zeros to its end (zeros counted in the running CRC; if the pad
exhausts the open block, the block's CRC is stored as at any rollover, otherwise the block stays
open), set `data_len = LBA`, mark filled, persist, enqueue as the final unit, kick. The caller
then drains its ring — the existing shutdown choreography — until the file's queue is empty and
the flag is clear; close the descriptor. A torn flush of this final unit is ignored by replay
exactly as before: the zeros are not a record. The same close runs at rotation, so a rotated-out
file is a complete, replayable unit.

**The snapshot procedure's closes are descriptor-only.** The §12 procedure closes no stream: at
success the **old** descriptor is closed (the old file is abandoned mid-stream — its flushed
prefix a complete replayable unit by construction of the composite; its final area is **not**
padded to `data_len = LBA`, accepted: the §9 tail crop treats a non-LBA-multiple length as a torn
final flush, which is exactly what an abandoned tail is); at failure the **new** descriptor is
closed (an uncommitted final-named file, junk under §12's junk rule). Neither close runs the
choreography above.

## 9. Open, recovery, and read cursors

**Scan.** The logical stream is the file bytes `[0, L)` plus, in PMEM mode, the ring tail: slot
`(L / LBA) mod N` holds the first unflushed area; filled control lines continue the file (LBA
each, `buffer_seq` checked against the walk position), the first non-filled line ends the walk,
its `data_len` bounding the partial and its `crc_running` the restored running CRC. Termination
is guaranteed by the three pinned invariants: the terminator rule (every current slot was a
persisted zero-terminator before receiving data), slot reuse only after flush completion, and the
PMEM exact-fill error. If L is not an LBA multiple, crop the tail (a torn final flush, or the
abandoned tail of a §12 success) — a legitimate crash artifact, never a supported path for an LBA
change (§11). Complete blocks verify by CRC32C; replay decodes self-delimiting records and stops
at the first torn record or bad block; the restart epoch (`docs/consensus.md`) is computed by this
scan exactly as `src/wal.zig` does today. Non-PMEM: the battery was RAM, the stream is the file
alone, and the open block's running CRC is derived by the same scan — which reads every byte of
the valid stream anyway.

**Selection — the registry, not the tags.** On restart, per `(host, index)`, the recovery reads
the registry (`<wal_path>.log`, §12): the source of truth for which files belong to the pair is
**the last valid line for that pair**, not a greatest-tag comparison over directory contents. A
line that does not match the format is a hard stop: the invalid line and every line after it are
ignored — a torn or corrupt tail simply means the transaction it would have committed is not
committed, and the recovery takes the previous valid line. A **pairless fragment** — a
valid-named WAL file with no snapshot pair, or a snapshot with no WAL — can therefore never arise
as a _referenced_ artifact: an unreferenced pair is uncommitted junk by the junk rule (§12), never
a recovery source. The plain greatest-tag rule is rejected twice over: a fragment can outrank the
real log by tag, and the registry answers the selection by a log lookup anyway.

**Replay.** The recovery replays the snapshot named by the selected line, then the **chain** of
WAL files for that `(host, index)` in state order, up to and including the referenced WAL: a
rotated-out predecessor of the referenced file is a complete replayable unit (§8's own
requirement), the next file's stream abuts it, and a record carries its state (the `upgrade`,
CONSENSUS-PLAN 2.5) — monotone and unique per `(host, index)` — so the composite overlap of the
procedure (both sides receive every record byte-identically) replays harmlessly: chain the files
in state order, skip states already applied.

**Positioning.** Three cases:

- _Normal restart_ — the recovered state is the end of the valid stream: the writer continues in
  place. Current buffer = the walk's terminator slot with its `data_len` and `crc_running`; no
  reset; the committed-but-unflushed tail stays live, the walk rebuilds the flush queue from the
  filled tail buffers in `buffer_seq` order, and the first kick (at open or on the next write,
  whichever comes first) resumes flushing them.
- _State below the stream's end_ — a suffix must be dropped. Trim the ring first (re-zero every
  trimmed control line as a terminator, deepest first, then persist), then truncate the file to
  the state's byte offset. A crash in between replays at worst the not-yet-dropped suffix (the
  caller retries the open at the same state; it converges), never garbage. No writer caller
  positions below the stream's end today; the choreography is dormant, specified for the
  compaction subject.
- _A fresh tag's first file_ (rotation, §12 pair creation), or after `delete` — reset all N
  control lines to terminators (one persist sweep; a memset otherwise), current = slot 0, running
  CRC fresh, L = 0. `open` may name a file that does not yet exist.

`delete(host_idx, index_idx, state)` removes the file of that (index, host); the battery is not
freed — the next `open` resets it (third case above).

**Offset index.** Sparse, one entry per 1 MiB block naming its file offset and its first record's
state; rebuilt by the scan and appended on rollover; `read_seek(state)` lands on the block and
scans at most 1 MiB. RAM cost is one entry per megabyte of log.

**Read cursors.** `read_begin()` positions at stream offset 0; `read_seek(state)` resolves through
the offset index. Both are scoped to the opened file (§2). In PMEM mode the stream includes the
live ring tail, so a cursor may serve `RequestLog` reads of records that have not flushed yet —
same thread, plain reads.

## 10. The complete mode delta

1. Battery backing: a computed slice of the DAX-mapped pool vs one aligned heap allocation.
2. `persist()`: CLWB → SFENCE vs a comptime no-op.
3. The exact-fill gate: present vs absent (comptime branch).
4. Recovery authority: the ring is a persistent tail and the walk consults it, vs scratch memory
   that died with the process.

Everything else — API, gate math, copy/transition ordering, flush queue mechanics, sequentiality,
the stall policy, close, block and record formats, control lines, the columnar layout — is one
shared implementation.

**The temporary-file surface is non-PMEM-shaped in both modes** (§12): the procedure's second
WALFile — over the not-yet-committed final-named file — is one ordinary aligned heap battery,
`persist()` a comptime no-op, the exact-fill gate absent. The PMEM pool partition stays sized for
the fixed `(index, host)` slots only; the temporary battery is never carved from it. At the
procedure's commit the whole state is memcpy'd into the fixed battery place and persisted there
with the fixed battery's own mode barriers.

## 11. LBA migration

LBA is deployment-tied and a persistent-layout parameter, so the supported path from one LBA to
another is the offline toolchain command, never a plain restart with a changed config (the
open-time geometry check rejects that):

```shell
mpy6a lba-migrate -f 4096 -t 16384
```

- **Scope.** The command exists for **PMEM** deployments — the pool partition (`area_stride`,
  §4) and the control-array offset are LBA-shaped persistent layout, so an LBA change is a
  re-lay of that layout. Non-PMEM deployments change LBA by draining (§8 close), removing the
  files, and starting fresh: there the battery is RAM and dies with the process, so nothing
  persistent is LBA-shaped except the file-length multiple, which a fresh start satisfies
  trivially.
- **Shape of the rebuild.** Offline: quiesce the deployment, then per file — open under the old
  LBA, scan the valid stream (§9), and re-emit it under the new LBA: pad the open tail to the new
  geometry, re-flush every area so the file length is a multiple of the new LBA, re-lay the PMEM
  pool with the new `area_stride`, and rewrite every control line (`buffer_seq`, terminator
  positions, and any position-carrying `crc_running` move). The record and block formats are
  LBA-independent (blocks are 1 MiB over the logical stream; a record that does not fit the open
  block's remainder zero-pads it), so the re-emit is a re-chunk of the same byte stream, verified
  by the same CRC32Cs — a migration that fails its own verification aborts without consuming the
  old files.
- **What the tool is not.** It is not part of the WAL library and not reachable from the consensus
  tract; it is a toolchain command over closed files. The full-state tag in the name is opaque and
  migrates verbatim; the tool must not interpret the tag, the registry, or the snapshot names — it
  operates per file, and junk/retention is the runtime's business (§12).

## 12. Snapshots: the transactional registry log

Snapshotting is a **WAL/index lifecycle procedure**, driven by a timer inside each index thread and
executed by an elephant thread — the consensus tract is never a party to it. Front-truncation
beyond what retention does stays a separate subject.

### Prerequisites

- An **index** is an execution entity holding an **own index state** (with timing-wheel machinery)
  and **mirror states** of other indexes, commanded through cluster connections, with **no**
  timing-wheel machinery over them. The index state
  (`active sessions, sessions ordered by replay/compensation order, ...`) is dumpable through its
  public interface:

```zig
const IndexState = struct {
    // ...
    pub fn clone(self: *Self, dst_allocator: *std.heap.Arena) !*Self {}
    pub fn dumper(self: *Self) !IndexState.Dumper {}  // on a cloned entity
    const Dumper = struct {
        // Synchronous on purpose: a large placeholder buffer (512 KiB or more) makes io_uring
        // meaningless for the task.
        pub fn dump(self: *Self, placeholder: []u8, dst: std.Io.Writer) !void {}
    };
};
```

- **Elephants** are execution entities on their own threads, receiving orders through cross-task
  slots / io_uring messages carrying slot references, executing **heavy blocking logic
  synchronously**. Round-robin task distribution.
- `WALController` marks a fixed battery area per `(host_idx, index_idx)` file and gains the
  temporary-file surface:

```zig
pub const WALController = struct {
    pub fn open(self: *Self, host_idx: u8, index_idx: u16, state: u128) !*WALFile {}
    // A wrapper over the given RW descriptor plus a buffer for the procedure's second WALFile.
    pub fn tmp(self: *Self, tmp_fd: std.posix.fd_t) *WALFile {}
};
```

### The invariant

**At most one snapshot procedure at a time, process-wide.** A single atomically accessible flag
(boolean or integer — whichever is cheaper) serializes all of it; there is no parallel snapshot
creation, own or mirrored, ever. The invariant guards the **final names themselves**: a same-tag
collision is impossible while the flag is held, so no temporary names exist anywhere in the design —
no in-progress directory, no `wal.tmp`/`snapshot.tmp`, no renames.

### The registry

A fixed log file, **`<wal_path>.log`** — a sibling of the WAL family under the same `wal_path`
prefix, discoverable from config alone — holds one line per committed pair:

```
host_idx:index_idx:snapshot-path:wal-path\n
```

- **Selection.** The **last valid line for a given `(host_idx, index_idx)`** names the snapshot and
  WAL for that index state (§9). New files are created **right under their final names** —
  `<wal_path>.<index_idx>.<host_idx>.<state>` and
  `snapshot.<host_idx>.<index_idx>.<state>`, with `<state>` the full-state tag minted at procedure
  start. Once the snapshot is ready — and the WAL file exists because the same procedure created
  it — a new line is appended to the registry; **that append finalizes the transaction**.
- **Commit.** The append is followed by an **fdatasync of the registry file** — the transaction's
  commit point: a power cut after the procedure reports success never loses the line; a cut before
  it loses only an uncommitted pair, which the junk rule already treats as junk. The append itself
  needs no atomic-write machinery beyond the hard-stop rule: one line smaller than a page, written
  in a single `write(2)`, is append-atomic-or-torn in practice, and torn is safe.
- **Hard stop.** A line that does not match the format is a HARD STOP: the invalid line and every
  line after it are ignored — a torn or corrupt tail simply means the transaction it would have
  committed is not committed.
- **Junk.** Files that match the snapshot and WAL name formats (so their `host_idx` and
  `index_idx` are computable) and **precede the oldest live reference of that pair in the registry**
  are removed. The "remove anything not listed in the log" idea is rejected: candidate
  (uncommitted) snapshot and WAL files are not listed and are removed by this precedence rule, not
  by listing.
- **Compaction.** At the end of the snapshot routine, the procedure checks whether the registry
  grew too large; if it did, compaction leaves **no more than N newest records per
  `(host, index)`** — matching the retention grouping and the selection rule: older lines for the
  _same_ pair are dead weight, older lines for _other_ indexes under the same host are not.

### The choreography

**Index thread:**

1. A **multishot timer** in each index thread (tick on the order of 1–10 minutes) wakes the review;
   the thread reviews its states' WAL sizes.
2. A state's WAL grew past the configured bound → it deserves a snapshot (`host_idx` may name a
   mirror).
3. **CAS the flag** false → true; failure means another procedure is in flight — drop the idea
   this tick.
4. On success, set the meta-state and arm io_uring to create the **empty WAL file and the snapshot
   file under their final names directly** — no temporary names, no renames:

```zig
snapshot_in_progress: ?struct {
    host_idx: u8,
    state: *IndexState,
    current_wal_len: usize,
},
```

5. On the CQ replies carrying the FDs (`snapshot_in_progress` must be non-null then — otherwise the
   procedure is already failed):
   1. **Clone** the given state (arena).
   2. Switch the file's write interface to a **composite WAL file**: every `write()` fans out into
      the **old** WAL file and the **new** one. The new side is an ordinary O_DIRECT-disciplined
      WALFile over its final-name descriptor — whole-area `O_DIRECT` writes over the LBA-aligned
      RAM battery, sequential per file — with the **stall inverted**: a new-side flush failure
      fails the **procedure**, never the log; an old-side flush failure still stalls the old file
      exactly as before (§6).
   3. Send the "create snapshot" task to a round-robin-chosen elephant.
   4. Keep working — the composite writes keep flowing; nothing blocks the ring loop.

**Rotation defers while the procedure is in flight.** The composite owns the old file's descriptor,
and the §8 close cannot run under it; the epoch-bump threshold check resumes when the flag clears.
A constraint, not a choice — a mid-composite rotation would tear the composite apart.

**Elephant thread — all synchronous, all blocking:**

1. Create the snapshot file (final name). Dump is the cloned state's `Dumper.dump` with a
   ≥ 512 KiB placeholder into a plain buffered writer — no io_uring.
2. **Make the snapshot durable**: one fdatasync of the snapshot file, after the dump, before the
   reply — a power cut between the registry commit and the snapshot's writeback would otherwise
   leave a torn authoritative snapshot with no fallback pair to mask it (the pair _is_ the last
   line).
3. No WAL rename — the WAL file already lives under its final name. No snapshot rename. No
   symlink step.
4. Reply OK or failure to the index through the slot, **carrying how far the procedure got**.

**Index thread, on the reply — either way the last io_uring close CQE finishes the procedure and
clears the flag:**

- **OK:**
  1. **Wait out both sides' in-flight flush SQEs** — a live SQE reading the battery must not race
     the memcpy's overwrite, and the WALFile state must outlive its CQE. A constraint, not a
     choice.
  2. **Drop the old side's flush queue.** The old file needs no §8 close at all: it is abandoned
     mid-stream, its flushed prefix a clean byte-identical prefix of the same stream — a complete
     replayable unit in exactly the sense the §9 replay rule leans on — and junk for retention.
     Nothing logical is lost: the composite wrote every record into both sides, so the suffix
     beyond the frontier lives on in the new file's stream.
  3. **Memcpy the new WALFile's whole state** — battery arrays, current slot, running CRC, flush
     queue, flags — into the fixed battery place. The new-side queue entries ride along: their
     `buffer_seq` are the new file's own stream positions, so the flushes continue from the fixed
     battery against the new descriptor without a seam.
  4. **Persist it** — the mode barriers over the memcpy'd battery: one sweep of CLWB → SFENCE under
     PMEM; a comptime no-op under non-PMEM, the flush frontier carrying the ordinary contract. No
     fdatasync anywhere on the WAL path.
  5. **Swap in the direct interface** on the new descriptor — the same inode, now the authoritative
     file.
  6. **Append the registry line, then fdatasync the registry** — the transaction's commit point.
  7. Clear the flag; arm io_uring to **close the old descriptor**; its CQ completion ends the
     procedure.

- **Failure:** swap back to the direct interface over the **old** file — its stream is complete:
  the `current_wal_len` prefix plus the composite suffix under its own ordinary discipline. The new
  pair (both final-named files, however far they got) is uncommitted junk under the registry rule —
  removal is the junk rule's business, not the failure path's. Arm io_uring to close the new
  descriptor; its CQ completion ends the procedure.

**Crash windows.** Before the registry commit, the new pair is unreferenced — recovery takes the
previous line, and the pair is junk by precedence. After the commit, the pair is authoritative and
the §1 tail contract covers a battery mid-memcpy. The registry append itself is
atomic-or-torn under the hard-stop rule: a torn line is ignored, and the transaction it names
simply never happened.

**First start.** At the very first start of an index state, the procedure creates a **pair with no
data** — an empty snapshot and an empty WAL file — and the registry line commits it: a WAL file
never exists without its snapshot, a snapshot always carries its WAL reference.

### The wire note

`src/wire.zig`'s `RequestSnapshot` and `src/index.zig`'s `answerSnapshotRequest` stub ("the
snapshot store does not exist yet") predate this design; the snapshot store built here is the
natural future backend of that service. The integration is the consensus tract's business and
stays out of scope.

---

Front-truncation beyond what retention and the registry compaction do stays a separate subject;
rotation triggers beyond the epoch-bump threshold stay as they were; this design covers the
buffered battery writer, reader, crash recovery, the migration contract, rotation, snapshotting,
and the registry.