# WAL implementation: iterative working plan

Working document split out of [`designs/wal-impl.md`](wal-impl.md) into steps sized for one
sitting each. The design doc is the specification and the authority: when this plan and the
design doc disagree, the design doc wins — stop and reconcile, do not improvise. Line
references are to the tree as of writing (`zigring-0.0.15`, `blog-0.0.18`, `siggy-0.0.1`,
Zig 0.17.1 std) and may drift; re-locate them by symbol name before use.

**The zigring module changes have landed and are consumed.** zigring is pinned at **0.0.15**
(`build.zig.zon:42-44`, commit `60de2ada`, hash
`zigring-0.0.15-Srja3xkvAwCRPqiod2LMZXBPlPPuA7Upu6qe7fwH_nCh`) and mpy6a builds and tests
green against it. §Z at the end of this document is the **landed record**, not work items:
the API inventory and the exact call shapes the later stages rely on (`StreamSQ.hasRoom`
for §C1 step 5, `rw_flags` for §D2).

**blog needs nothing.** The seeded fold already exists as
`blog.crc32c.composedCrc32C(acc: u32, data: []const u8) u32` (blog 0.0.18, `src/crc32c.zig:49`,
re-exported through `src/root.zig:68`), with its property tests already in blog. The design
doc's older name `combinedCrc32C` and its §8.2 blog work items are **done and superseded**:
every use site below says `blog.crc32c.composedCrc32C`, import once as
`const blog = @import("blog");` and call `blog.crc32c.composedCrc32C(...)`.

## How to work these steps (read once, obey always)

1. **No new APIs, no new names, no new files beyond the ones named.** If a step does not name
   a file, symbol, or signature, it is not asking for one. Do not invent helper abstractions,
   interfaces, builder objects, or "future-proofing" parameters.
2. **Verify every symbol before use.** Grep the repo (`rg -n`) for each name a step mentions.
   If a referenced line/symbol does not exist as described, re-read the surrounding code and
   the design doc section it cites — never guess a signature.
3. **One step = one commit-sized change.** After each step: `zig build` clean, `zig build
   test` green. Never start the next step with a red or non-compiling tree.
4. **The design doc's pinned rules are non-negotiable.** Ordering of checks, publish
   sequences, terminator semantics, error sets — copy them literally. If an implementation
   choice seems needed, the design doc already made it; search it again before deciding.
5. **No TODOs, no stubs left behind.** A step's tests are part of the step, not follow-ups.
6. Where a step says "pin", that value is final — do not reinterpret it.

Shared vocabulary (fixed for the whole plan):

- New module: `src/wal.zig` (format, battery, `WalWriteFile`, `WalReadFile`, `FileReadProcess`).
- `BLOCK = 1 MiB` block size; `HEADER = 64` bytes; `CRC_LEN = 4`; CRC seed/XOR `0xFFFFFFFF`.
- `BufferHeader` (extern struct, exactly 64 bytes, one cache line):

  ```zig
  pub const BufferHeader = extern struct {
      data_len: u32,     // valid bytes; LBA when filled, 0 for the zero-terminator
      flags: u32,        // bit 0 = filled
      buffer_seq: u64,   // absolute ordinal: file position / LBA
      crc_running: u32,  // running CRC32C of the open block at this buffer's committed extent
      _pad_align: u32,   // aligns last_state to 16
      last_state: u128,  // state_idx of the last record ending in this committed extent
      _pad_tail: [24]u8, // 64 total; the doc's "reserved" is this padding
      comptime {
          std.debug.assert(@sizeOf(BufferHeader) == 64);
          std.debug.assert(@offsetOf(BufferHeader, "last_state") == 24);
      }
  };
  ```

  (The design doc's table lists `reserved: u32`, which does not add to 64; the layout above is
  the resolution — 64 bytes total, `last_state` 16-aligned. Do not shuffle field order.)
- Pair = `(host_idx: u8, index_idx: u16)`; pair area index `= index_idx × hosts + host_idx`
  (thread-major). Inside an area: data array first (`buffers × lba`), then header array
  (`buffers × 64`). Area stride: `buffers × (lba + 64)` rounded **up** to a multiple of
  `max(lba, page_size)`, so every pair's data array stays LBA-aligned.
- `buffer_idx(o) = o mod buffers` (ring of buffers inside one area).
- File name: `wal.<host_idx>.<index_idx>.<state>` in the configured `dir`, `<state>` as 32
  lowercase hex digits. Nothing ever parses the tag except to hand it to `st.state` at load.

---

## §Z Landed: zigring 0.0.15 (record, not work items)

These edits live(d) in the **zigring repository/module**; mpy6a consumes them through the
fetched dependency (`build.zig.zon:42-44` pins `zigring 0.0.15`, commit `60de2ada`,
extracted under `zig-pkg/zigring-0.0.15-…/`). All line numbers below are that tree's
`src/iouring.zig` (Factory lines are `src/ring_factory.zig`). Verified by inspection of the
fetched tarball; `zig build` + `zig build test` green in mpy6a against it.

### Z1 `rw_flags` on the write family — done

All seven write-push functions take a trailing `rw_flags: u32`, forwarded verbatim into
`sqe.rw_flags`:

- `Ring.pushWrite` (`:493`), `Ring.pushWriteOffset` (`:527`), `Ring.pushWritev` (`:564`) —
  `flags: TaskFlags` then `rw_flags: u32`;
- `BatchSQ.pushWrite` (`:1675`), `BatchSQ.pushWriteOffset` (`:1700`) — same trailing pair;
- `StreamSQ.pushWrite` (`:1946`), `StreamSQ.pushWriteOffset` (`:1971`) — same trailing pair.

Reads have **no** `rw_flags` parameter anywhere (`StreamSQ.pushReadOffset` `:1996` takes
`dst: []u8` + `flags` only) — there is nothing to pass on the read path.

### Z2 `StreamSQ.hasRoom` — done

`StreamSQ` (`:1903`, initialized in place by `Ring.streamedSQ` `:476`) exposes

```zig
pub fn hasRoom(self: *const Self) bool;   // :1937
```

— `self.tail -% self.head < self.ring.sq_mask + 1`, exactly the occupancy test `reserve`
applies against the head captured at open (or by the last `commit`). No side effects.

### Z3 Consumed in mpy6a — done

1. `build.zig.zon` points at the 0.0.15 commit/hash above.
2. The one stream-write call site, `src/logging.zig:162`, passes `0` as `rw_flags`.
3. `zig build` clean, `zig build test` green.

Standing rule for the stages below: WAL flushes pass `std.os.linux.RWF.DSYNC` in PMEM mode
and `0` in plain mode; reads never see a `rw_flags` parameter at all.

### The 0.0.15 rename wave (already migrated in mpy6a)

0.0.15 also renamed/reworked the whole module; every later stage copies these shapes:

- `TaskFlags` fields are lowercase: `.{ .link = true, .skip_success = true, ... }`
  (`iouring.zig:43`);
- every constructor is **in place**: `Ring.init(&ring, depth, fd)` (`:189`),
  `Factory.init(&mgr, allocator, n)` (`ring_factory.zig:33`),
  `Factory.acquireRing(&mgr, &ring, depth, weight)` (`ring_factory.zig:51`),
  `ReorderBuffer.init(&rb, ...)`, `Slots(T).init(&slots, ...)` — declare `undefined`,
  pass the address, never assign the return;
- `Ring.streamedSQ(&stream)` opens a `StreamSQ` in place (`:476`) — mpy6a already keeps one
  per index thread (`src/lifetime.zig:370`, field `sqstream` `src/lifetime.zig:989`);
- `popCQE` (`:1504`) and `park` (`:1569`) keep their names, `pushCancel` is `:1474`.

mpy6a's call sites were already migrated (`src/lifetime.zig:368-370`, `src/slots.zig:88`);
new code in §D/§F must match, not the 0.0.14 spellings this plan originally carried.

**Still not needed:** `Z1 parkFor`, `Z2`, `Z3`–`Z6` of `ZIGRING-FIXES.md` — out of scope here;
the `ZIGRING-FIXES.md:19` hazard (no direct `Ring.push*` on a ring with a live `StreamSQ`)
remains binding for §F2.

---

## Stage A — config block and the `Controller` seam

Design doc: §1, §7. Everything here is synchronous and cold; no ring traffic yet.

### A1 The `wal` config block

Files: `src/config.zig`, `mpy6a.cfg` (already carries the block — keep it parsing).

1. Add to `Config` (`src/config.zig:34`): `wal: Wal` — **no default, not optional**: a
   required key, a document omitting it fails with `MissingField` (siggy
   `decodeStruct` behavior, siggy 0.0.1 `src/siggy/schema.zig:441`, fill `:478-485`).

2. `Wal` and payloads, exactly this shape (defaults per the design doc §7):

   ```zig
   pub const Wal = union(enum) {
       plain: struct {
           dir: []const u8,          // required, no default
           buffers: u32 = 32,
           hosts: u32 = 1,
           lba: u32 = 4096,
       },
       pmem: struct {
           dir: []const u8,           // required
           device: []const u8,       // required
           buffers: u32 = 32,
           hosts: u32 = 1,
           lba: u32 = 4096,
       },
   };
   ```

   Siggy renders tagged unions as `plain { ... }` / `pmem { ... }` — matches the accepted
   grammar. `buffers`, `hosts`, `lba` are omittable; `dir`/`device` are not.

3. **Comptime-check reanchor.** `Manager()`'s `comptime validate(Config{}, check_cpu_cores)`
   (`src/config.zig:304-308`) cannot validate a struct with a required key. Replace the
   literal with an explicit **canonical literal** — the same values the dev document spells:
   `.{ .wal = .{ .plain = .{ .dir = "wal", .buffers = 32, .hosts = 1, .lba = 4096 } } }`
   on top of the existing defaults. The property "a broken default fails the build" must
   survive: prove it by temporarily breaking one canonical value and watching the build
   fail, then restore.

4. `Manager.default()` (`src/config.zig:380`) stringifies `.{}` — the same required-key
   problem. Reanchor identically: stringify the canonical literal (the full document the
   dev config spells).

5. Runtime validation (`validate`, `src/config.zig:393`), new checks, in this order:
   - `lba` is a power of two, `512 <= lba <= 1 MiB`, and `1 MiB % lba == 0`;
   - `buffers >= 2`;
   - `1 <= hosts <= 256` (`host_idx: u8` bounds it);
   - `host_index < hosts` (this replaces `src/index.zig:70`'s ad-hoc bound — the check moves
     here, the site simplifies);
   - `dir` non-empty; `device` non-empty in PMEM mode.
   New `ParseError` values, one per rule, named clearly (`InvalidLba`, `InvalidBuffers`,
   `InvalidHosts`, `InvalidWalDir`, ...). No allocation inside `validate`.

Tests: omitted `wal` → `MissingField`; omitted `dir` inside `plain` → `MissingField`; omitted
`device` inside `pmem` → `MissingField`; the dev document (`mpy6a.cfg` content) parses;
defaults round-trip; each validation rejection fires its named error; `default()` output
re-parses.

### A2 Paths and `delete`

Files: `src/lifetime.zig` (or `src/wal.zig` — the path builder lives with the WAL; pick
`src/wal.zig` and keep `Controller` a thin caller).

1. `fn walPath(allocator, dir, host_idx: u8, index_idx: u16, state: u128) ![]u8` producing
   `"<dir>/wal.<host>.<index>.<hex32>"`, 32 **lowercase** hex digits of `state`, symmetric
   with the snapshot convention (`sdks/state-snapshot.md` §3.4).
2. `Controller.delete(self, host_idx, index_idx, state) !void`: `unlink`; a missing file
   (`ENOENT`) is success. Idempotent by construction.
3. `walOpenRead`: `open` read-only (`O_RDONLY`); return the fd wrapper. `walOpenWrite`: the
   §A4 skeleton opens an **existing** file only (`open` without `O_CREAT`); a missing file
   surfaces the raw open error — fatal at startup, never repaired.

Tests: path rendering (hex lowercase, zero-padded); delete of a missing file succeeds;
delete of an existing file succeeds; reopen of a missing file errors.

### A3 Battery allocation in the `Controller`

Files: `src/lifetime.zig`.

1. `Controller` gains: `wal_mode` (from `cfg.wal`), `wal_pairs: usize`
   (`= indexes × hosts` — the **pair count**), `wal_area_stride: usize`, plus, per mode:
   - plain: `wal_data: []u8` (all pairs' data arrays) and `wal_headers: []BufferHeader` —
     or one `u8` slab per pair carved by stride; either way **zeroed headers at allocation**
     (the design doc's plain-mode rule). Allocate at the first index-thread start (cold).
   - pmem: mmap the `device` once, size `>= pairs × area_stride` (validated), areas used as
     found; **headers never zeroed** in this mode. Behind the mode flag; logic tests run
     plain-mode.
2. Partition math helpers (pure, testable): `areaIndex(host_idx, index_idx)`,
   `areaStride(buffers, lba)`, `dataOffsetInArea`, `headerOffsetInArea`, and
   `bufferIdx(o) = o mod buffers`. Rounding **up** to `max(lba, page)` multiple.
3. The pair area **outlives every WAL file**: allocation/deallocation is per index thread,
   never per open/close. Files rotate over the same area epoch after epoch.

Tests: partition math over a grid of `(buffers, lba)` legal values — alignment of every
pair's data array (`offset % lba == 0`), stride multiple of `max(lba, 4096)`, header array
fully inside its area; plain allocation zeroed headers; `bufferIdx` wraps.

### A4 `WalWriteFile` skeleton and the error set

Files: `src/wal.zig`, `src/lifetime.zig`.

1. `WalWriteFile` struct: `fd`, `head: u128` (file's base tag at open), the pair's battery
   slice view (data + headers), `flushed_upto: u64` (ordinal), flush queue state
   (`flush_in_flight: bool`, `flush_pending: bool`), `faulted: bool`, mode flag, lba/buffers
   consts, `current` ordinal + in-buffer cursor. All fields live in the struct; no global
   state.
2. The full `write` error set, exactly the design doc §3 table:
   `WalFull`, `RecordTooLarge`, `WalGap`, `InvalidStateIdx`, `NoFreeSlots`, `RingFull`,
   `WalFaulted`, `WalOpen` — plus `OutOfMemory` where allocation happens. One `pub const
   WalError = error{ ... }` used by all entry points.
3. `Controller.walOpenWrite`: **open** (§A2) → walk/recovery is §C/§E; here: open, wire the
   battery view, `head = tag`, done. `Controller.walAdoptWrite(host_idx, index_idx, state,
   fd)`: the adoption entry — validate the triple has no live writer (`WalOpen`), persist
   the ordinal-0 zero-terminator of the pair's area (§E1 semantics, noop-persist in plain
   mode), open over the transferred fd, `head = tag`.
4. `close(self: *Self) !void` — **body comes in §D**; here only the signature and the
   skeleton: mark closed, release nothing yet. Do not call it from tests until §D.

Tests: two writers on one triple → `WalOpen` (both open entries); writer with
`new_state_idx == 0` → `InvalidStateIdx`; `floor != head` → `WalGap` (head unchanged after
each refusal — assert `head` and one probed header byte-identical before/after).

---

## Stage B — format core (pure, no I/O)

Design doc: §4. Files: `src/wal.zig` and tests next to it. No ring, no battery.

### B1 Record framing

1. `encodeRecord(allocator, state_idx: u128, data: []const u8) ![]u8`:
   16 LE bytes of `state_idx`, `uvarint(len(data))`, `data` — the same uvarint scheme as
   `lifetime.putUvarint`/`readUvarint` (`src/lifetime.zig:774`/`:790`). Reuse those, do not
   re-implement: the encoding helper can be a free function if `Controller`-method shape is
   awkward, but **one** uvarint implementation in the tree.
2. `decodeRecord(bytes) !struct { state_idx: u128, op: []const u8, len: usize }` — framing
   only; rejects `state_idx == 0` (the padding sentinel / empty-state reservation),
   `op.len` running past the given extent (`CorruptInput`-family errors, own names:
   `error.CorruptInput`, `error.TornRecord` is **not** an error — the caller drops torn
   tails; return what fits and a flag if you need it, but prefer: the parse function takes
   the extent and stops cleanly).
3. `framedLen(data_len) usize` = `16 + uvarintLen(len) + len`.

Tests: encode/decode round-trip including 0-length op, op lengths crossing uvarint byte
counts (1, 127, 128, 16383, 16384); decode of a truncated tail; `state_idx == 0` rejection;
framedLen arithmetic.

### B2 Block framing and CRC

1. `BLOCK = 1 << 20`, `CRC_LEN = 4`, `BLOCK_CONTENT = BLOCK - CRC_LEN` (so `1 MiB - 4`, the
   `RecordTooLarge` bound).
2. Helpers: `blockOf(offset) = offset / BLOCK`, `inBlockOffset`, `blockRemain(offset)` (the
   content remainder), `closesBlock(offset)` (`1 MiB % lba == 0` by validation, so a block
   close is always a buffer fill — assert it in tests instead of handling it).
3. CRC: `blog.crc32c.hardwareCrc32C(block_bytes)` for a whole closed block;
   `crc_running = blog.crc32c.composedCrc32C(crc_running, piece)` for each appended piece.
   **No** three-argument combine, **no** builder object, **no** re-read of already-folded
   bytes — design doc §4 pins all three refusals.
4. Keep one local property test mirroring blog's:
   `composedCrc32C(hardwareCrc32C(A), B) == hardwareCrc32C(A ++ B)` over random splits and
   lengths (runs in Debug, where the fallback table path proves the same algebra).

Tests: pad-and-close arithmetic; CRC composition over random splits (property test, seeded
PRNG); `RecordTooLarge` bound exactness (a record framing to exactly `1 MiB - 4` fits, +1
byte does not).

**Reconciled while landing §B2.** The "seed `0xFFFFFFFF`" spelling the design doc uses for a
block-opening `crc_running` (wal-impl §2, §3.4) is the RFC register init and final XOR, not a
fold value. `blog.crc32c.composedCrc32C(acc, data)` takes a **finalized** CRC and treats
`acc == 0` as the empty prefix, so a block's fold starts at `0`; handing it `0xFFFFFFFF`
cancels the register init and stores a block CRC that fails the reader's whole-block
`hardwareCrc32C` check. `crc_seed` stays in `src/wal.zig` as the named init/XOR constant.
§C2/§E1/§E2 read this paragraph, not the literal.

---

## Stage C — battery and the write path, plain mode

Design doc: §3.1, §3.2, §3.3 (logic; ring comes in §D). Files: `src/wal.zig`.

**The flush sink stays an interface seam this stage**: the writer calls a function pointer
(or a small vtable struct) `submitFlush(writer, ordinal)` / the writer's queue is driven by
a test pump that calls the completion handler synchronously. Stage D replaces the seam's
implementation with `StreamSQ`, not its shape.

### C1 Admission, in the exact pinned order

`write(self, new_state_idx: u128, floor_state_idx: u128, data: []u8) !void` starts with:

1. faulted guard → `WalFaulted`;
2. `floor_state_idx == head` else `WalGap`; `new_state_idx != 0` else `InvalidStateIdx`;
3. cost: framed length; if it does not fit the current block's content remainder, add the
   zero-padding of the whole remainder + 4 CRC bytes, spanning as many buffers as it takes
   — each padded buffer becomes filled and joins the flush queue; a record not fitting a
   fresh block's content → `RecordTooLarge`;
4. **the fundamental rule**: after this write at least one buffer must remain free
   (`data_len == 0`, `filled` clear); an exact fill of the last free buffer → `WalFull`;
5. flush pre-check: this write will submit ≥ 1 filled buffer ∧ no flush in flight ∧ none
   pending → check now (slot table has a slot; `StreamSQ.hasRoom()` — or its seam) —
   `NoFreeSlots`/`RingFull` leave the writer untouched.

**Admission atomicity is absolute**: errors 1–6 run before any byte or header moves;
`head`, buffers, headers, queue all unchanged on refusal. Write the named tests:
`WalGap` after N accepted writes changes nothing (compare every header + `head`);
exact-fill `WalFull` changes nothing; each admission error leaves `flushed_upto` alone.

### C2 Copy, spill, terminator, commit-last

In `write`, after admission passes:

1. Copy framed bytes into the current buffer at the in-buffer cursor; fold each appended
   piece into the block's running CRC (`crc_running = composedCrc32C(crc_running, piece)`).
   A record never crosses a block boundary: on a content-remainder overrun, zero-pad the
   remainder (zeros counted into the hash), write the block's CRC into the block's last 4
   bytes (inside the block's last buffer — guaranteed by `1 MiB % lba == 0`), mark the
   padded buffers filled + queued, and start the record at the next block's first buffer.
2. Buffer exhausted → grab the successor (`buffer_idx + 1` semantics), continue there.
   The **uniform publish rule** (§2): a successor is made current only after its
   zero-terminator is persisted — `buffer_seq = successor_ordinal`, `data_len = 0`,
   `filled` clear, `last_state` = the preceding committed buffer's `last_state` (or the file
   tag / `0` for a brand-new data set at ordinal 0), `crc_running` = the fold state of the
   block containing that ordinal at extent 0 (seed `0xFFFFFFFF` when the ordinal opens a
   block, else the open block's running value after the preceding committed bytes).
   Persistence is a **seam** this stage (`persistHeader(header*)` — plain mode: no-op;
   PMEM in §E: `CLWB` → `SFENCE`).
3. **Commit-last**: successors' headers persist first, in chain order; the buffer that was
   current at op start persists **last** with `data_len`, `filled`, `crc_running`,
   `last_state` as of the write's end. That publish is the commit point. A torn crash
   between the two leaves a chain the walk (§E) refuses to trust past the last committed
   buffer — the tests assert exactly that shape.
4. Accept: `head = new_state_idx`.

Tests (plain mode, synchronous flush sink): header chains after arbitrary write sequences —
`buffer_seq` in every publish, terminator invariant on every path (exact fill, spill,
post-flush reuse, block close); `head` recovery through the headers; the commit-last shape
(successor's terminator present, predecessor's commit absent → walk must stop there, tested
again in §E with the real walk).

---

## Stage D — stream-driven flush, the stop, `close`

Design doc: §3.3, §3.5, §1.1's close. Files: `src/wal.zig`, `src/slots.zig`, `src/index.zig`
(dispatch comes in §G — here only the writer-side handlers).

### D1 `TaskCtx` variants

`src/slots.zig:41` gains, per the design doc §6 (plain data, comptime rules of the slot
store at `:78` hold automatically):

```zig
file_read: struct { file_process: *FileReadProcess, offset: u64, buf: []u8 }, // §F
wal_flush: struct { writer: *WalWriteFile },
```

(`buf: []u8` — the doc's `[]u64` in docs/WAL.md is a recorded typo.)

### D2 The flush choreography through `StreamSQ`

1. Submission: one flush per SQE — `StreamSQ.pushWriteOffset(fd, task_idx, ordinal × lba,
   buffer_ptr, lba, .{}, rw_flags)` (offset before pointer, `TaskFlags` before `rw_flags` —
   zigring-0.0.15 `iouring.zig:1971`) from `flushed_upto`'s slot, then `StreamSQ.commit()`.
   `rw_flags = RWF.DSYNC` in PMEM mode, `0` in plain. The buffer is the pair's data array
   slot — `O_DIRECT` alignment holds by construction (§A3).
2. **Never two flushes in flight.** The writer's queue: on completion, the flushed buffer's
   header becomes the zero-terminator for its ordinal (persist in PMEM), `flushed_upto`
   advances, the slot retires, and the next buffer submits **if it is marked filled**.
3. The failure split: window momentarily full at completion time → park `flush_pending`,
   the CQ drain retries every loop pass (nothing lost, nothing errored); a **negative `res`**
   CQE (real OS error) → no retry, trip the stop.
4. The flush pre-check (§C1 step 5) uses `Slots.add` + `StreamSQ.hasRoom()` — same call,
   same thread, inside one `write`: the pre-checked submission cannot fail.

Tests with a fake CQ pump driving the writer's completion handler: exactly one flush in
flight at all times (instrument the seam); park-and-retry on window-full; floor discipline —
the tag-base first record (`floor == tag`), the brand-new `floor == 0` case, `WalGap`.

### D3 The stop, `close`

1. `faulted` trip: `log.err` in the existing pattern (`src/index.zig:58`) + the writer's
   flag. A faulted writer refuses with `WalFaulted`. Thread-level consequence (deny the
   whole front intake) lands in §G — here the writer side only.
   Non-triggers, pinned: window backpressure, `WalFull`, `RecordTooLarge`, `WalGap`,
   `WalOpen`, cold-op errnos outside a live writer.
2. `close`: retry a parked pending submission once (§3.3), wait for the in-flight completion
   on the caller's ring (`popCQE`/`park` loop, best-effort under a fault), release the slot
   table entry and the fd. Drains the queue, leaves the battery (battery is per-thread,
   not per-file — §A3).

Tests: faulted trip by a fake negative-`res` CQE → subsequent writes `WalFaulted`; `close`
drains with and without a parked pending; `close` after a fault is best-effort and does not
hang.

---

## Stage E — PMEM mode

Design doc: §2 (PMEM), §3.4, §5's walk predicate. Files: `src/wal.zig` (+ `src/barrier.zig`
— the one new file the plan allows).

### E1 The barrier module

`src/barrier.zig`: `pub fn clwb(addr: *const anyopaque, len: usize) void` +
`pub fn sfence() void` — x86_64 asm (`clwb`/`sfence`), CPUID-gated `clflushopt`/`clflush`
fallback. **Build flag seam**: a comptime constant switches the whole module to a no-op so
every logic test runs against an ordinary-memory "PMEM" battery. No inline asm gymnastics
beyond these three ops; no fences anywhere else.

Tests: flag on/off builds compile; the no-op build runs the whole stage C/D suite against a
"PMEM"-shaped battery.

### E2 Reopen via the walk

The merged-stream walk (§F2 implements the predicate; here the **writer resume** use):
effective file length `len & ~(lba - 1)`, `N = len / lba` flushed buffers; from ordinal `N`,
slot `o mod buffers`, take buffers while the header checks out. **`head` = the walk's end
`last_state`.** Empty file: resume at the ordinal-0 terminator, `head` = the tag it carries.

The walk predicate, row by row (§5's table): stale `buffer_seq != o` → stop;
zero-terminator → stop; committed full → take, continue; live tail (`0 < data_len < lba`,
¬filled) → take, stop; anything else → stop, never deliver.

### E3 The swap handover

`walAdoptWrite` (§A4) completes here: **close the old writer first** (`close` drains; the
per-pair battery structurally excludes dual-writing one op into both files — two writers
would share the pair's one ring and collide), then persist the ordinal-0 zero-terminator of
the pair's area (`buffer_seq = 0`, `data_len = 0`, `filled` clear, `last_state` = the new
tag, `0` for a brand-new data set, `crc_running = 0xFFFFFFFF` — ordinal 0 always opens
block 0), open over the transferred fd, `head` = the tag. The registry append of the
snapshot design happens **after** this publish — the ordering "registry-visible implies
ordinal-0 terminator persisted" is the adoption test's assertion (faked registry append).

Tests: resume position and `crc_running`/`last_state` recovery through the walk; stale-lap
chains (`buffer_seq` from a previous lap stops); torn-commit chains (successor published,
predecessor not — walk stops before); two generations in one area (file B's ordinal-0 over
file A's reclaimed ring).

---

## Stage F — the read path

Design doc: §5. Files: `src/wal.zig`.

### F1 `WalReadFile` and the merged stream

1. `walOpenRead` (§A2) → `WalReadFile` owning the fd. One `FileReadProcess` per read
   operation: `state: enum { Seek, Read }`, a block-sized buffer, the task description —
   `read_all` or `seek_then_read(target_state)` — the sink, and the walk cursor.
2. Sink contract: `fn (ctx, state_idx: u128, op: []const u8) !void`. Startup replay applies
   through `Controller.applyIndexOp` (`src/lifetime.zig:467`) with `st.state` set by the
   caller before applying — the reason the sink passes `state_idx` separately.
3. Merged stream: file bytes `[0, N × lba)` (tail shorter than a buffer ignored), then the
   PMEM chain (PMEM mode only, §E2 predicate). PMEM tail bytes are plain `memcpy` — no ring
   traffic; only file slabs go through the ring.
4. The tail rule: a closed block's CRC match ends parsing at the padding (padding parses
   as `state == 0`, `len == 0` — reserved, never a real record); mismatch or an open tail →
   framing alone within the merged extent; a record past the extent is torn, dropped;
   replay stops, never repairs.
   The continuity rule: **no arithmetic on delivered states**; nets are framing, block
   CRCs, extent bounds, `state != 0` per delivered record.

### F2 Driving and the seek

1. Arm as docs/WAL.md §"Как это предлагается реализовывать" shows: `state = .Seek`
   (or `.Read` for `read_all`), a slot from the thread's `RingSlots` (`src/slots.zig`),
   `TaskCtx` variant stored, `StreamSQ.pushReadOffset(fd, task_idx, offset, dst, .{})` at
   LBA-aligned boundaries (`dst: []u8` carries the length; no `rw_flags` on reads —
   zigring-0.0.15 `iouring.zig:1996`), `StreamSQ.commit()`, each CQE stepped by
   `FileReadProcess.state` (`TaskCtx.file_read` from §D1).
   **Stream path only** — the Z2 hazard (`ZIGRING-FIXES.md:19`) forbids direct `Ring.push*`
   on a ring with a live `StreamSQ`.
2. The seek: binary-search the block index — read a block, take its first record's
   `state_idx` (a mebibyte boundary is always a record start), compare against `T`,
   converge on the last block whose first record is `<= T`, scan forward, deliver every
   record with `state_idx >= T`. Edges: `T` below the first record → deliver from the
   first; `T` past the last → empty delivery (sink never called). States are u128s, plain
   integer compare — host/epoch jumps inside one file search correctly.
3. The startup driver pumps `popCQE`/`park` synchronously during Phase A on the owning index
   thread.

Tests: round-trips of synthetic files (tmpfs lacks `O_DIRECT` — the fixture detects
`EINVAL` at open and falls back to buffered for logic tests; a manual checklist covers a
real filesystem); binary search over many blocks and across state jumps; seek edges;
**the fuzz gate** — random truncations and byte flips never panic, stop at the first
inconsistency; `state != 0` delivery check; plain-mode reopen head recovery (§3.4's parse:
records parse while they fit the flushed extent, `head` = last complete record's state,
write offset = that record's end or the block end on a padding run, `crc_running` reseeded
by `composedCrc32C` over the open block's flushed bytes, skipped when the file end is on a
block boundary).

---

## Stage G — wiring

Design doc: §3.5, §6, §9-G. Files: `src/index.zig`, `src/messages.zig` untouched, docs.

1. `src/index.zig` owns one wrapper per data set: `replication_factor`
   (`src/index.zig:18`) is **deleted**; `data_sets` sizes off `cfg.wal.hosts`, the own-data
   bound check moves to config validation (§A1).
2. CQ drain (`src/index.zig:89`) gains the two dispatches: `wal_flush` completion advances
   the writer's queue (§D2) or trips the stop (§D3); `file_read` completion steps its
   `FileReadProcess`. Reserved indices (`src/messages.zig`) untouched; the inbox `BatchCQ`
   commit (`src/index.zig:101`) untouched — the WAL always publishes through
   `StreamSQ.commit()` itself.
3. The stop, thread-level: the faulted flag denies the thread's whole front intake —
   `FrontMessage` (`src/index.zig:21-34`) handlers refuse before calling `write` (a denied
   `.create` closes the fd at once, `src/index.zig:110-111`'s pattern); control-plane traffic
   (reserved `taskIdx`, cross-task slots) keeps flowing so shutdown completes.
4. The submission path is `StreamSQ`, never direct `Ring.push*` (§6). The only direct push
   left on an index ring is `reportDrained`'s `pushMsgRing` (`src/index.zig:182`) — Z2's
   resolution makes it safe; not this plan's work.
5. `walOpenWrite`/`walOpenRead`/`delete`/`walAdoptWrite` stay synchronous and cold
   (`createLogFile`'s `std.os.linux.open` idiom, `src/lifetime.zig:267`); creation is
   elephant-side per the snapshot design — out of scope here (§10 of the design doc), but
   the invocation points get a `// snapshot design: ...` pointer comment each.
6. Docs: `docs/WAL.md` gains a pointer to this plan and `designs/wal-impl.md`;
   `docs/todo.md` loses the `RWF.DSYNC` item (absorbed by §Z/§D2).

Final gate: `zig build test` green; one end-to-end plain-mode test — write a sequence of
records, close, reopen, replay through the sink into a fresh `IndexState`, compare states.

---

## Step order and dependencies

```
A1 -> A2 -> A3 -> A4 -> B1 -> B2 -> C1 -> C2 -> D1 -> D2 -> D3
                                             -> E1 -> E2 -> E3
                                             -> F1 -> F2 -> G
```

§Z has landed (zigring 0.0.15 consumed; `StreamSQ.hasRoom` and the write family's `rw_flags`
are available as recorded at the end of this document), so the main plan starts at A1. A and
B are pure-local and may interleave; C needs the `hasRoom` seam (available); D needs nothing
further from zigring; E and F need D's handlers; G last.