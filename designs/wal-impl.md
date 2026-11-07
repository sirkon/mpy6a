# WAL implementation plan

Promoted from `.mailbox/wal-impl/3.md` (iterations 1–3, all questions resolved).

Line references verified against the tree as of promotion: `zigring-0.0.14`, `blog-0.0.17`, `siggy-0.0.1`, Zig 0.17.1
std.

## 1. Scope and the `Controller` seam

One index — including a mirror index — has its own WAL file. An index is the triple
`(host_idx, index_idx, self_index_state)`; the file holds the data of exactly that data set (every accepted op of it,
whichever replica's index thread writes it, and nothing else; consensus artifacts never touch the WAL), and juggling
several data sets is the index thread's business as an execution flow, each data set with its own file and its own
battery.

The `Controller` seam:

```zig
// lifetime.Controller, src/lifetime.zig
pub fn walOpenWrite(self: *Self, host_idx: u8, index_idx: u16, state: u128) !*WalWriteFile;
pub fn walAdoptWrite(self: *Self, host_idx: u8, index_idx: u16, state: u128, fd: std.posix.fd_t) !*WalWriteFile;
pub fn walOpenRead(self: *Self, host_idx: u8, index_idx: u16, state: u128) !*WalReadFile;
pub fn delete(self: *Self, host_idx: u8, index_idx: u16, state: u128) !void;
```

On-disk name: `wal.<host_idx>.<index_idx>.<state>` in the configured directory, `<state>` rendered as 32 lowercase hex
digits — symmetric with the snapshot convention (`sdks/state-snapshot.md` §3.4). The tag is opaque: nothing derives an
epoch or a slice back from it, and nothing parses it except to hand it to `st.state` at load (`sdks/state-snapshot.md`
§5: the caller sets the state from the name tag **before any op is applied**).

The `state` argument is (a) the file name tag and (b) the file's **base state** — the state the file's _first_ record
must chain from. On a reopen the walk supersedes it: the effective head is the last committed record's state (§3.4).

### 1.1 The elephant flow

`walOpenWrite`/`walOpenRead`/`delete` stay synchronous and cold (the `std.os.linux.open` idiom of `createLogFile`,
`src/lifetime.zig:267`; the ring carries only flushes and reads, keeping the SQPOLL hot path syscall-free,
`docs/shard-arch-hld.md` §1). But **creation leaves the module**: new WAL files are created within elephant threads —
the skeleton's heavy-work thread already exists (`src/elephant.zig`, the `elephants` config knob at
`src/config.zig:51`), reached only through `CrossTaskSlots`, whose payloads are plain data capped at 16 bytes
(`src/cross_task.zig:56-68`; descriptors already travel that way, `src/cross_task.zig:45-47`) — alongside the snapshot
they pair with, and ownership of the new WAL's fd transfers to the index thread once the snapshot has been created
successfully. Snapshots are voluntary, independent per `(host_idx, index_idx)` pair, not bound to a consensus. The
procedure already has a shape (`sdks/state-snapshot.md` §1): clone on the index thread → the elephant dumps, writes and
`fdatasync`s the snapshot → reply OK → **the index thread finishes the WAL swap → appends the registry line, the commit
point (§3.6 there)**. Three consequences, pinned:

- `walOpenWrite` no longer creates. It opens an existing file (the recovery/reopen entry); a missing file surfaces the
  raw open error, fatal at startup. All creation is elephant-side.
- The fresh-file terminator ordering anchors to **"before the registry append"**. The elephant may create the empty file
  at any point of its procedure; a crash in that window leaves an unregistered 0-length orphan, and recovery opens only
  what the registry names (`sdks/state-snapshot.md` §3.6) — orphans are retention's. The invariant in its final form:
  **a registry-visible file implies its ordinal-0 terminator was persisted**. The publish happens at adoption, on the
  index thread, before the append; publishing after the append would leave a crash window with a registered 0-length
  file whose slot 0 still holds the _previous_ file's committed header — the false positive the ordering exists to kill.
- The elephant never touches the battery. The pair's area belongs to its index thread (the G1 discipline of
  `src/state.zig:8-11`), so the terminator publish — a battery write — is the index thread's act by construction. The fd
  is the only thing that crosses.

`close(self: *Self) !void` drains the flush queue — retries a pending submission if one is parked (§3.3), then waits for
the in-flight completion on the caller's ring, releases the battery slice and the fd. `delete` unlinks and is
idempotent: a missing file is success.

The delivery of the new fd is a message into the index thread's ring, a context in `CrossTaskSlots` — descriptors
already travel that way (`src/cross_task.zig:45-47`). What it tells: a new snapshot was taken and the thread must switch
to the new fd. The switch itself — old and new WALs written in overlay during the snapshot procedure, then the exclusive
switch to the new one — is controller logic, and its choreography (the clone-to-swap op window, freeze or
hold-at-adoption, the registry sequencing) belongs to the snapshot design, not here. The WAL supplies what either
resolution needs; the floor protocol makes the new file's base explicit either way (§3.4).

## 2. The battery

Two operating modes, both buffered. Per-record `O_DIRECT` is rejected outright.

- **Plain mode.** The battery is ordinary allocated memory; a crash loses the un-flushed tail; durability of a record
  begins when its buffer's flush completes.
- **PMEM mode.** The battery is a computed region of an mmap'd NVDIMM; every publish is `CLWB` → `SFENCE`, so the
  un-flushed tail survives a power cut; the file flush exists to recycle ring slots, not to establish durability. The
  headers are **never zeroed** in this mode — their whole point is to survive. Plain mode zeroes its DRAM headers at
  allocation.

Memory decomposition, both modes, per pair `(host_idx, index_idx)` — two columnar arrays inside the pair's area: the
data array first (`buffers_count ×` the LBA size, LBA-aligned by construction), then the header array
(`buffers_count × 64`). Area stride: `buffers_count × (LBA + 64)` rounded up to a multiple of `max(LBA, page)` so every
pair's data array stays LBA-aligned. Pair → area index `index_idx × hosts + host_idx` (the doc's "index_count" in its
formulas is the **pair count** `indexes × hosts`; thread-major, stable across restarts, movable only by the migration
toolchain).

A pair's area is owned by its index thread and **lives as long as that thread**: WAL files open and close over the same
area epoch after epoch; the battery is not per-file. In plain mode the thread's slices are allocated at thread start
with zeroed headers; in PMEM mode the stick is mapped once (`lifetime.Controller`, the resource owner) and the areas are
used as found. Inside one area, the headers and buffers form a ring: `buffer_idx(o) = o mod buffers_count`, the doc's
`buffer_idx(N + k) = (N mod 32 + k) mod 32`.

`BufferHeader`, one per slot, exactly 64 bytes — one cache line, so **one publish is one `CLWB` and is atomic in
practice**:

| field              | meaning                                                                                                           |
| ------------------ | ----------------------------------------------------------------------------------------------------------------- |
| `data_len: u32`    | valid bytes in this buffer; the full LBA size when filled, `0` for the zero-terminator                            |
| `flags: u32`       | bit 0 = filled                                                                                                    |
| `buffer_seq: u64`  | the buffer's **absolute ordinal** (file position ÷ LBA): the flush offset and the stale-lap check                 |
| `crc_running: u32` | the running CRC32C of the open block as of this buffer's committed extent; makes reopen trivial                   |
| `last_state: u128` | the `state_idx` of the last record ending within this buffer's committed extent — the writer's head after restart |
| `reserved: u32`    | padding to 64                                                                                                     |

**The uniform publish rule**, sharpened at block boundaries: every header publish — commit, terminator, post-flush
reclamation — writes `buffer_seq` as the absolute ordinal being published. A zero-terminator publish for ordinal `o`
writes `data_len = 0`, `filled` clear, `buffer_seq = o`, and carries the values a resume from an empty buffer `o`
continues from: `last_state` = the last record ending at or before `o`'s extent-0 (in practice the preceding committed
buffer's `last_state`; the file's base tag for a fresh file's ordinal-0 terminator, `0` for a brand-new data set), and
`crc_running` = the fold state of the block **containing `o`** at extent 0: the seed `0xFFFFFFFF` when `o` opens a
block, else the open block's running value after the preceding buffer's committed bytes. (A block start is the
exception: the next block's CRC begins at the seed, not at the preceding buffer's end.) A commit publish for ordinal `o`
covers the bytes committed _in_ `o`. Result: whatever state a walk finds, `crc_running`/`last_state` are the correct
fold-back point for that buffer's committed extent.

Flushes carry `RWF.DSYNC` in PMEM mode only, per `docs/todo.md`: the SSD controller must drop its volatile cache too,
else the file — which in PMEM mode exists only to recycle slots — can silently lose a flushed buffer the battery has
already forgotten. The flag rides the SQE (`sqe.rw_flags = std.os.linux.RWF.DSYNC`, `std/os/linux.zig:4974`, value
`0x2`), not a separate `fdatasync`; the snapshot doc's "the WAL path never fdatasyncs" (`sdks/state-snapshot.md` §3.4)
stays true. What zigring lacks for this is §8.1; the todo item is absorbed at stage G.

## 3. The write path

The writer API:

```zig
pub fn write(self: *Self, new_state_idx: u128, floor_state_idx: u128, data: []u8) !void
```

The caller (the consensus driver, which owns state minting — `st.state` is "moved only by the consensus driver",
`src/state.zig:161`, and `applyIndexOp`'s contract has the caller set the state before applying,
`src/lifetime.zig:465-467`) passes the raw op bytes plus the record's state and its explicit predecessor state; the
writer frames the record (`state_idx` as 16 LE bytes, then `uvarint(len(data))`, then `data` — the same uvarint scheme
as `lifetime.putUvarint`/`readUvarint`, `src/lifetime.zig:774`/`:790`) and copies it into a battery buffer
synchronously; the caller may reuse `data` the moment `write` returns. The record's bytes then live in the battery for
as long as the index thread does.

**The state discipline:**

- The writer keeps **`head: u128`** — the state the next record must chain from. At open it is the file's base: the tag.
  After each accepted record it is that record's state. At a reopen it is the walk's (plain mode: the parse's) recovered
  last committed state (§3.4).
- Every write must satisfy **`floor_state_idx == head`**. The floor is the `state_idx` of the last event in the WAL —
  validation input only; it is computed, never stored in the record. A mismatch means the two logs diverge — we are
  missing something from their log — the caller must catch up before retrying; the refusal moves nothing.
- **`floor_state_idx == 0` means the record is the first ever**: the file is empty and its base is the empty state
  (`head == 0`), which happens exactly once in a data set's life. Every rotated file — a snapshot taken mid-life, tag ≠
  0 — receives its first record with `floor == tag`.
- **`new_state_idx` is never 0**: state 0 is the empty state (a freshly loaded snapshot starts at `state = 0`,
  `sdks/state-snapshot.md` §5) and is reserved by the zero-floor convention. The **epoch slice starts at 1, never 0** —
  in the layout `host_id: u8, index_id: u16, epoch_id: u40, index: u64` (`src/state.zig:156-159`) — so no real record's
  state can be 0 regardless of the lower slices. No minting code exists yet; the constraint is recorded for the
  consensus design, and the writer guards it regardless (`error.InvalidStateIdx`).
- Nothing else is checked. No arithmetic between `new` and `floor` is expressible — the host slice dominates the layout,
  so a leader change or a replica's restart jumps the state arbitrarily within one file — and `new != floor` is
  minting's uniqueness business, not the op-agnostic WAL's.

The error set of `write`:

| error                   | when                                                                                                       |
| ----------------------- | ---------------------------------------------------------------------------------------------------------- |
| `error.WalFull`         | the fundamental rule: after this write, no buffer would remain free                                        |
| `error.RecordTooLarge`  | the framed record cannot fit a fresh block's content (`1 MiB - 4`)                                         |
| `error.WalGap`          | `floor_state_idx != head`: the caller is missing records — a catch-up signal; nothing moved                |
| `error.InvalidStateIdx` | `new_state_idx == 0` (the state-0 reservation violated)                                                    |
| `error.NoFreeSlots`     | a flush submission would be needed and the slot table is depleted (`zigring.Slots.add`, `slotter.zig:111`) |
| `error.RingFull`        | a flush submission would be needed and the SQ window is full (`getOpSlot`, `iouring.zig:404`)              |
| `error.WalFaulted`      | the writer is stopped: a WAL OS error tripped the thread (§3.5)                                            |
| `error.WalOpen`         | this triple already has a live writer (both open entries)                                                  |

Errors 1–6 are **admission refusals**: they run before any byte or header moves and leave the writer untouched — head,
buffers, headers, queue all as they were. `WalGap` is the protocol signal the consensus design reacts to (fetch the
missing span via a serve request, or take a snapshot); it is not a fault and does not stop the thread.

### 3.1 Admission

On the owning index thread, before any byte moves, in order:

1. The faulted guard: a stopped writer refuses everything with `error.WalFaulted`.
2. The chain checks: `floor == head` (else `WalGap`); `new != 0` (else `InvalidStateIdx`).
3. Compute the cost: the framed record, plus — if it does not fit the current block's content remainder — the zero
   padding of the whole remainder plus the 4 CRC bytes. Padding can span several buffers; every padded buffer becomes
   filled and joins the flush queue. A record that cannot fit a fresh block is `error.RecordTooLarge` (the consensus ops
   are session-sized; a guard, not a biting limit).
4. The fundamental rule: after the write there must remain at least one free buffer (`data_len = 0`, `filled` clear) —
   an exact fill of the last free buffer is `error.WalFull`.
5. The flush pre-check: if this write will submit a flush at its end (it fills ≥ 1 buffer ∧ no flush is in flight ∧ none
   is pending), check now that a slot is available and the stream window has room; a refusal (`NoFreeSlots`/`RingFull`)
   leaves the writer untouched. The check and the submission happen inside one `write` call on one thread — nothing
   interleaves them, so the pre-checked submission cannot fail.

### 3.2 Copy, spill, terminator, commit-last

4. Bytes go into the current buffer; the record never crosses a block boundary: if it does not fit the block's content
   remainder, the remainder is zero-padded (zeros counted in the hash), the block's CRC is written into its last 4 bytes
   (inside the block's last buffer, since `1 MiB % lba == 0` by the validated config), and the record starts in the next
   block. PMEM: `CLWB` → `SFENCE` of the touched data.
5. When the current buffer is exhausted, grab the successor and continue there.
6. An exactly filled buffer's successor gets the zero-terminator publish (§2's uniform rule), persisted `CLWB` →
   `SFENCE`. This is the battery's core invariant: **a data area only ever receives bytes after its control line has
   been persisted as a zero-terminator for its ordinal**. Every path that makes a buffer current satisfies it: adoption
   (§3.4), exact-fill transition, post-flush reuse.
7. **Commit-last.** The grabbed successors' headers are persisted first, in chain order; the metadata of the buffer that
   was current at op start — `data_len`, `filled`, `crc_running`, `last_state` — is persisted **last**. That publish is
   the write's commit point: a torn crash between the successor publishes and the old buffer's publish leaves a chain
   the walk refuses to trust past the last fully committed buffer.

### 3.3 The flush choreography

Exactly one flush in flight, ever, per the doc's step 6 — two could persist N+1 while N is lost to kernel scheduling and
leave the file non-contiguous:

- Submit one flush per SQE: `StreamSQ.pushWriteOffset(fd, task_idx, buffer_ptr, LBA, ordinal × LBA, flags)` from ordinal
  `flushed_upto`'s slot, then `StreamSQ.commit()` (§6 explains why the stream path). `rw_flags` = `RWF.DSYNC` in PMEM
  mode, `0` otherwise.
- On the completion (the index thread's CQ drain, `src/index.zig:89`): the flushed buffer's header becomes the
  zero-terminator for its ordinal (persisted in PMEM mode), `flushed_upto` advances, the slot retires, and the next
  buffer submits if it is marked filled.
- **The failure split.** A submission that cannot be made because the stream window is momentarily full is not an OS
  error: the writer parks `flush_pending` and the drain retries it every loop pass — nothing is lost, the flush is
  merely delayed, and the window drains as other ops complete. A flush CQE carrying a **negative `res`** — an actual OS
  error: `EIO`, `ENOSPC`, … — has no caller to error into and is not retried: it trips the thread's stop (§3.5).

### 3.4 Open: recovery, adoption, and the plain-mode head

**Recovery/reopen** (`walOpenWrite`, on the index thread at startup). Effective file length is `len & ~(LBA - 1)` (the
torn-tail rule); `N = len / LBA` flushed buffers.

- PMEM: the committed chain is walked from ordinal `N` (§5's walk, in "where do I continue" mode): the resume point is
  the chain's end — the current buffer, its `data_len`, `crc_running`, `last_state`. **`head` = that `last_state`.** An
  empty file stops at the ordinal-0 terminator and resumes with `head` = the tag it carries.
- Plain: the battery is DRAM and gone after a restart — there is no chain to walk, the file itself is the only source.
  The open block's flushed extent is parsed once, cold, with the reader's own framing logic (§5's tail rule). Records
  parse while they fit the extent; **`head` = the last complete record's state** (the tag if the file is empty); the
  write offset = that record's end, or the block end when the parse stopped at a padding run (the block is closed; the
  writer opens the next one); `crc_running` is reseeded by folding the open block's flushed bytes with `combinedCrc32C`
  — skipped when the file end is on a block boundary, the next block starting empty; a torn record at the extent end is
  dropped exactly as the reader drops it.

**Adoption** (the rotation entry, §1.1's flow). On the index thread, after the elephant's OK and the fd transfer:
**close the old writer first** — `close` drains, so every buffer of the pair is reclaimed and the ring is idle; the
battery handover is clean only in this order, and the per-pair battery also structurally excludes ever dual-writing one
op into both files (the two writers would share the pair's one ring and collide). Then adopt: persist the ordinal-0
zero-terminator of the pair's area (§2's uniform rule: `buffer_seq = 0`, `data_len = 0`, `filled` clear, `last_state` =
the new tag — `0` for a brand-new data set — `crc_running = 0xFFFFFFFF`, ordinal 0 always opening block 0), open the
writer over the transferred fd, `head` = the tag. The registry append (the snapshot design's §3.6 step) happens only
after this publish — that ordering is what keeps "a registry-visible file implies its ordinal-0 terminator was
persisted" true.

What happens to ops accepted between the clone and the swap — they sit in the old file, which the append is about to
orphan — is the snapshot design's sequencing; the WAL supplies what either resolution needs: freeze the front for the
window, or hold the window's ops and write them at adoption, each with its own floor chaining from the tag. The floor
protocol makes the new file's base explicit either way.

### 3.5 The stop

Once an OS error is hit, ops stop at the current index thread: every incoming request from the front is denied, and only
the control plane is listened to from then on. Mapping to the code: the index thread's front is its inbox —
`FrontMessage` from the parent front (`src/index.zig:21-34`), drained at `:106`; the control plane is the reserved
`taskIdx` traffic and cross-task slots (`src/messages.zig:15-25`, `src/cross_task.zig`) — shutdown demands, wakeups and
snapshot replies keep flowing, so the shutdown choreography still completes (`close` drains best-effort).

The stop is thread-level: one faulted writer denies the thread's front intake outright — all WALs of a thread's pairs
share one directory and device, so one `EIO` is a suspicion against all of them. The trigger set, pinned: a negative
`res` on a `wal_flush` CQE, and a negative `res` on a WAL `file_read` CQE (the remote-serve path). Non-triggers:
slot/window backpressure (park-and-retry per §3.3), `WalFull`/`RecordTooLarge` (protocol refusals), `WalGap` (a catch-up
signal), `WalOpen` (a guard), and cold-op errnos outside a live writer — a startup failure aborts Phase A (the thread
never came up), and a failed adoption fails the snapshot procedure with the old writer untouched.

The diagnostic is a `log.err` in the existing pattern (`src/index.zig:58`) plus the `faulted` flag on the writer; the
wrapper denies front work instead of calling `write` (a denied `.create` closes the fd at once, the skeleton's own
pattern at `src/index.zig:110-111`; a denied op's refusal shape is the consensus design's wire), and the writer itself
refuses with `error.WalFaulted` if reached anyway. There is no recovery in process: the stop is terminal for the writer
until the process restarts; the control plane keeps working, and in PMEM mode the un-flushed tail stays durable in the
battery for the restart's walk.

## 4. Format and checksums

- Record: `state_idx` (16 LE bytes), `uvarint(len(op))`, `op`. The floor is **not** stored — it is validation input
  computed as the previous event's state, not content. The WAL is op-agnostic: it never encodes or decodes ops;
  `encodeRecord` and the framing validation are small helpers in `wal.zig`. The doc's `TaskCtx.FileRead.buf: []u64` is a
  typo for `[]u8`.
- Block: 1 MiB, last 4 bytes the CRC32C of the block's content (zero padding counted). Blocks align to buffer boundaries
  by the validated config, so the CRC slot always lands inside the block's last buffer and every block close is also a
  buffer fill.
- CRC32C via `@import("blog").crc32c.hardwareCrc32C` (blog 0.0.17 `src/crc32c.zig:5`; `blog/src/root.zig:68` re-exports
  the module).

The combinator is the seeded fold:

```zig
pub fn combinedCrc32C(prev: u32, data: []const u8) u32
```

and not the three-argument `crc1/crc2/len` combine, and not a `std.hash.Crc32.init()` builder. Why this form: blog's
convention is `~fold(~0, data)` (init `0xFFFFFFFF`, final XOR), and CRC composition under that convention is just a
**seeded fold**: `crc(A || B) = ~fold(~crc(A), B)`. Every use site holds the bytes — the writer folds each appended
piece into the open block's running CRC (`crc_running = combinedCrc32C(crc_running, piece)`, no re-read ever), the
plain-mode reopen reseeds by folding the flushed extent (§3.4), and the reader verifies a closed block with one
whole-block `hardwareCrc32C`. The GF(2)-matrix `crc32_combine` buys nothing any of those sites needs and costs ~30 lines
of matrix math. No builder object anywhere.

What blog is missing for this is small and listed in §8.2; the property test proving the algebra
(`combinedCrc32C(hardwareCrc32C(A), B) == hardwareCrc32C(A ++ B)` over random splits and lengths) runs in Debug too,
where blog's x86_64 path is the std `CRC-32/ISCSI` fallback (the asm is gated on `mode == .fast`, `crc32c.zig:8`) — same
convention, so the test proves the same algebra on both paths.

## 5. The read path

`WalReadFile` owns the fd (read-only, from `walOpenRead`) and mints one `FileReadProcess` per read operation: the
`Seek | Read` state, a block-sized buffer, the task description — `read_all` (the no-alternative readout from the start)
or `seek_then_read(target_state)` — the sink, and the walk cursor. Delivery contract: a caller sink
`fn (ctx, state_idx: u128, op: []const u8) !void`; startup replay applies through the existing `applyIndexOp`
(`src/lifetime.zig:467`, whose contract — caller sets `st.state` before applying — is exactly why the sink passes
`state_idx` separately from `data`); the remote-serve path streams the same records, wired by the consensus design. One
state machine, two drivers; the startup driver pumps `popCQE`/`park` synchronously during Phase A on the index thread
that owns the ring.

**The merged stream.** The logical stream is the file bytes `[0, N × LBA)` (tail shorter than a buffer ignored) followed
by the PMEM chain (PMEM mode only): from ordinal `N`, slot `o mod buffers_count`, take buffers while the header checks
out. The walk predicate, pinned:

| header at ordinal `o`                                         | verdict                                          |
| ------------------------------------------------------------- | ------------------------------------------------ |
| `buffer_seq != o`                                             | stale (previous lap or previous file) → **stop** |
| `buffer_seq == o` ∧ `data_len == 0` ∧ ¬filled                 | zero-terminator → **stop**                       |
| `buffer_seq == o` ∧ `data_len == LBA` ∧ filled                | committed full buffer → take all, **continue**   |
| `buffer_seq == o` ∧ `0 < data_len < LBA` ∧ ¬filled            | the live tail → take `data_len`, **stop**        |
| anything else (`data_len == LBA` ∧ ¬filled, `filled` ∧ short) | torn metadata → **stop**, never deliver          |

The writer's resume point is wherever the walk stops: the next ordinal to write into, with `crc_running`/`last_state`
taken from that buffer's header (§2's uniform rule makes them correct in every row — including the post-flush
terminator, whose carried pair is exactly the resume). Mid-chain stale false-positives are unreachable by construction:
commit-last persists a successor's terminator _before_ the predecessor's commit, and §3.4's adoption ordering closes the
only remaining window.

**The tail block rule.** The last block of the merged stream is open — it has a CRC only if the writer padded and closed
it. A closed block's CRC match ends parsing at the padding (a padding run parses as `state_idx == 0` with `len == 0`,
and state 0 is the empty state — a reserved value, so no real record ever carries it); a mismatch, or the open tail
block, is read by framing alone: records parse while they fit the merged extent; a record running past the extent is
torn, dropped — replay stops there, never repairs. The fuzz gate must hold: random truncations and byte flips never
panic, the stream stops at the first inconsistency.

**The continuity rule.** The reader enforces **no arithmetic on delivered states** — gaps are legitimate inside one file
(a leader change or a replica's restart jumps the state). The chain's guarantee is the writer's floor check (§3); the
reader's nets are framing, the block CRCs, the merged-extent bounds, and `state != 0` on every delivered record (which
keeps the padding sentinel meaningful). Delivered records are exactly the committed records, in order.

**The seek.** `seek_then_read(T)` binary-searches the block index: read a block, take its first record's `state_idx` — a
mebibyte boundary is always a record start, so this is one parse — and if it exceeds `T` the target lies before the
block. Converge on the last block whose first record is `≤ T`, then scan forward, delivering every record with
`state_idx ≥ T`. Edges: `T` below the file's first record → deliver from the first record; `T` past the last → an empty
delivery (the sink is never called). States are u128s and totally ordered (the epoch slice sits above the op-ordinal
slice, the host slice above both), so the compare is plain integer math and host/epoch jumps inside one file search
correctly.

**Driving.** A read task is armed as the doc shows: `state = .Seek` (or `.Read` for `read_all`), a slot from the
thread's `RingSlots`, the `TaskCtx` variant stored, `StreamSQ.pushReadOffset(fd, task_idx, offset, dst, flags)` at
LBA-aligned boundaries, `StreamSQ.commit()`, and each CQE dispatched by `FileReadProcess.state` — continue seeking,
start the readout, assemble the merged block, verify, deliver. PMEM tail bytes are plain `memcpy` — no ring traffic;
only file slabs go through the ring.

**Concurrency.** Everything of a pair is touched only by its index thread (the `state.zig` G1 discipline), so a
`WalReadFile` open alongside a live writer — the remote-serve case — interleaves safely with no atomics and no locks;
the reader sees the chain as of its own position in the thread's loop. A second _writer_ on a live triple is
`error.WalOpen` on both open entries; `walOpenRead` stays unrestricted.

## 6. Ring integration

- `TaskCtx` (`src/slots.zig:41`) gains `file_read: struct { file_process: *FileReadProcess, offset: u64, buf: []u8 }`
  and `wal_flush: struct { writer: *WalWriteFile }` — plain data, one pointer plus scalars, destructor-free by the
  existing comptime rules of the slot store (`src/slots.zig:78`); slot ids stay below `slots.max_capacity` by
  construction.
- **The submission path is `StreamSQ`, not the direct `Ring.push*`.** Every ring arms a stream window at init
  (`src/lifetime.zig:370`), file logging already submits through it (`src/logging.zig:162`), and mixing direct pushes
  with a live `StreamSQ` on one ring is the Z2 hazard (`ZIGRING-FIXES.md:19`) — the direct/stream cursor bookkeepings
  diverge. The WAL adds no new mixing: its flushes and reads go through `pushWriteOffset` (`iouring.zig:1940`) /
  `pushReadOffset` (`:1963`) + `commit` (`:2110`). The only direct push left on an index ring is `reportDrained`'s
  `pushMsgRing` at shutdown (`src/index.zig:182`), which Z2's resolution will make safe. Window-full surfaces as a
  `null` push — that is `error.RingFull`'s stream-side face.
- The index thread's CQ drain (`src/index.zig:89`) gains the two dispatches: a `wal_flush` completion advances the
  writer's queue (§3.3) or trips the stop (§3.5); a `file_read` completion steps its process. Reserved control indices
  (`src/messages.zig`) stay untouched. The inbox batch's `BatchCQ` commit (`src/index.zig:101`, `zigring.BatchCQ` via
  `src/index_inbox.zig:156`) stays as is — it releases consumed completions only and does not publish SQEs; the WAL
  always publishes through `StreamSQ.commit()` itself.

## 7. Config

The block:

```text
wal = plain { dir = "..." buffers = 32 hosts = 1 lba = 4096 }
wal = pmem  { dir = "..." device = "..." buffers = 32 hosts = 1 lba = 4096 }
```

Siggy's field taxonomy, pinned from the parser itself (`decodeStruct`, siggy 0.0.1 `src/siggy/schema.zig:441`, the fill
at `:478-485`): a field absent from the document takes its declared Zig default; if there is none, it takes `null` when
its type is optional; **otherwise the parse fails with `MissingField`**. That makes both requirements mechanical:

- **`dir: []const u8` — no default, not optional: a required key.** A document omitting it does not parse. The same for
  **`device: []const u8`** inside the `pmem` variant.
- **`buffers = 32`, `hosts = 1`, `lba = 4096`** — the defaults; defaulted fields, omittable.
- **The `wal` field itself — `wal: Wal` on `Config`, no default: a required key.** No valid document leaves the WAL
  module unopened. The module is always on with a runnable dev environment: the dev config sets the block explicitly —
  plain mode, `hosts = 1`, single host, no replication.
- One forced reconciliation: `Manager()`'s comptime check validates `Config{}` (`src/config.zig:304-308`), and a Config
  with a required key has no `{}` value. The check reanchors: it validates an explicit **canonical literal** — the same
  values the dev document spells (plain, `buffers = 32`, `hosts = 1`, `lba = 4096`, the dev dir) — keeping the
  broken-default-fails-the-build property. `Manager.default()` (a stringify of `.{}`, `src/config.zig:380`) reanchors
  the same way: it renders the canonical document.

Validation at startup: `lba` a power of two in `[512, 1 MiB]` dividing 1 MiB exactly; `buffers >= 2`; `hosts >= 1` and
`<= 256` (the API's `host_idx: u8` bounds it); `host_index < hosts` (the check replaces `src/index.zig:70`'s ad-hoc
bound and `src/index.zig:18`'s `replication_factor` constant — `data_sets` sizes off `cfg.wal.hosts`); `dir` non-empty;
in PMEM mode, the mapping must cover `pairs × area_stride` bytes. The directory is created at startup if missing.

## 8. What the upstream modules are missing

### 8.1 zigring

**Write pushes cannot carry `rw_flags`.**

- **Where:** `StreamSQ.pushWrite` (`iouring.zig:1919`) and `StreamSQ.pushWriteOffset` (`:1940`) — the WAL's actual path;
  symmetric gaps in `Ring.pushWrite` (`:491`), `Ring.pushWriteOffset` (`:522`), `Ring.pushWritev` (`:556`). All of them
  zero the SQE (`StreamSQ.reserve` `:1898` / `getOpSlot` `:404` memset) and never touch `sqe.rw_flags`; the only
  functions that set `rw_flags` today are the socket sends (`pushSendZC` `:618`/`:2005`, `MSG_*` flags) and `pushCancel`
  (`:1464`, zeroing it explicitly).
- **Why it matters:** PMEM-mode WAL flushes need `sqe.rw_flags = std.os.linux.RWF.DSYNC` (`std/os/linux.zig:4974`, value
  `0x2`) so each `O_DIRECT` write also drains the SSD controller's volatile cache (`docs/todo.md`). Reads need nothing —
  `RWF_HIPRI` and friends are irrelevant here.
- **Fix:** add an `rw_flags: u32` parameter to the write family. zigring has no external users, and mpy6a's only stream
  write call site is `src/logging.zig:162`, which passes `0` — so extending the existing signatures is free and
  preferable to parallel `*Rw` variants. Minimum set: the two `pushWriteOffset`s (stream first).
- **Not needed for the WAL:** Z1's `parkFor` (close's drain uses plain `park` today), Z2 (avoided by going stream-only,
  §6), Z3–Z6 (unrelated).

### 8.2 blog

`crc32c.zig` needs the seeded fold behind `combinedCrc32C(prev: u32, data: []const u8) u32`. Three paths in that file,
each a few lines:

- x86_64/ReleaseFast (the `crc32q`/`crc32b` asm at `:18`, the path gated on `mode == .fast` at `:8`): the running
  register started at `~prev` (zero-extended into the u64), final `^ 0xFFFFFFFF` — the existing `hardwareCrc32C` body
  with a different seed.
- aarch64 (`:38`): same change with `crc32cx`/`crc32cb`.
- fallback (`:53`): `std.hash.crc.@"CRC-32/ISCSI"` has no seeded `init` — so this path needs its own small fold, a
  256-entry reflected table (`0x82F63B78`) or a bitwise fold, started at `~prev`, final `^ 0xFFFFFFFF`. Slow is fine; it
  is the non-server path.

## 9. Implementation stages and test gates

Each stage lands compiling and tested; `zig build test` stays green after every one.

- **A. Config + seam.** The `wal` block with the required-key shape; the canonical-literal reanchor of the comptime
  check and `default()`; the validation list; the `Controller` grows the battery fields and partition math (plain
  allocation at thread start; the PMEM mapping behind the mode flag); the four methods as thin, correct skeletons; the
  `replication_factor` constant replaced by `cfg.wal.hosts`. Tests: config round-trips and rejections (`MissingField` on
  an omitted `dir` and on an omitted block; the dev document parses; the canonical literal passes comptime validation);
  path construction; open/adopt/delete idempotence; the adoption terminator ordering (§3.4).
- **B. Format core.** `encodeRecord`, block framing (fit, pad, close), `combinedCrc32C` proven against `hardwareCrc32C`
  of the concatenation over random splits and lengths (property test; the Debug fallback convention verified equal).
  Pure, no I/O. Written floor-free (§4); the floor is computed from the previous event's state, never stored.
- **C. Battery + write path, plain mode.** Ring algebra; admission in the full check order (faulted guard, floor,
  zero-state, cost with pad accounting, the never-full rule, the flush pre-check) against a memory battery with a
  synchronous flush sink; the copy/spill/terminator/commit-last sequence; admission atomicity — every refusal leaves
  `head` and the battery untouched (named tests: a `WalGap` after N writes changes nothing; the exact-fill refusal).
  Tests: header chains after arbitrary write sequences; the terminator invariant holds on every path, `buffer_seq` in
  every publish; head recovery through the headers.
- **D. Stream-driven flush, the stop, close.** The one-at-a-time choreography through `sqstream` with a fake CQ pump;
  the parked pending on window-full at completion time; **the stop: a negative-`res` flush CQE marks the writer faulted
  and further writes refuse with `WalFaulted`**; `close` drains (including a parked pending). Tests: interleavings;
  exactly one flush in flight at all times; the floor discipline (the tag-base first record, the zero-floor brand-new
  case, `WalGap`).
- **E. PMEM mode.** The pair→area partition; the barrier module (x86_64 asm, CPUID-gated `clflushopt`/`clflush`
  fallback, a no-op barrier build flag so every logic test runs against an ordinary-memory "PMEM" battery); reopen via
  the walk; **the swap handover: close-old-then-adopt over one battery — file B's ordinal-0 publish over file A's
  reclaimed ring, two generations in one area**. Tests: resume position, `crc_running`/`last_state` recovery, stale-lap
  and torn-commit chains (successor published, predecessor not — the walk must stop before), terminator stops, the walk
  predicate table row by row, the adoption ordering against a faked registry append.
- **F. Read path.** `WalReadFile`, `FileReadProcess`, the merged stream, the seek, the tail rule, the sink, the
  synchronous startup driver. Tests: round-trips of synthetic files (`O_DIRECT` where the filesystem supports it — tmpfs
  does not, so the fixture detects `EINVAL` at open and falls back to buffered for logic tests; a manual checklist
  covers a real filesystem); binary search over many blocks and across state jumps; seek edges (before-first,
  past-last); the fuzz gate (truncations and flips never panic, stop at first inconsistency); the `state != 0` delivery
  check; plain-mode reopen head recovery (§3.4's parse).
- **G. Wiring.** `src/index.zig` owns one wrapper per data set, dispatches the two CQE kinds, and consults the faulted
  flag before taking front work (§3.5); the recovery invocation point is documented for the snapshot design, the
  adoption invocation point likewise; `docs/WAL.md` gains a pointer to the promoted plan; `docs/todo.md` loses the
  `RWF.DSYNC` item (absorbed by §2).

## 10. What the later designs own

The snapshot design (the next material, on the elephant threads): the procedure's details (the `SnapshotJob`/`CrossTask`
wiring — `sdks/state-snapshot.md` §3.2 sketches it), the fd transfer mechanism, the clone-to-swap op window (freeze or
hold-at-adoption; dual-write is structurally excluded by the per-pair battery, §3.4), the WAL→overlay→switch
choreography the fd-transfer message triggers, the registry and its precedence, the recovery sequencing (load snapshot →
set `st.state` from the tag → `walOpenWrite` → replay), retention and orphan cleanup (when `delete` is called), and the
post-restart epoch bump's sequencing (the epoch moves up on self-data after a restart; the WAL sees it as just another
rotation: tag = the recovery head, first floor = the tag).

The consensus driver: what is written and when, state minting above the writer's head (the epoch-starts-at-1 reservation
and state uniqueness among its rules), the `WalGap` catch-up reaction, the remote-serve request handling, and the
front-denial wire shape.

The toolchain: `pmem-migrate` (`docs/todo.md` keeps the commands).
