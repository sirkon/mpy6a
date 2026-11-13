# Snapshots implementation: iterative working plan

Working document split out of [`designs/SNAPSHOTS.md`](SNAPSHOTS.md) into steps sized for one sitting each. The design
doc is the specification and the authority: when this plan and the design doc disagree, the design doc wins — stop and
reconcile, do not improvise. Line references are to the tree as of writing (zigring 0.0.15, Zig 0.17.1 std) and may
drift; re-locate them by symbol name before use. Where a step cites `§N` without a file, it means
`designs/SNAPSHOTS.md`.

**Companions.** `sdks/state-snapshot.md` (the clone/dump/arena SDK — §3.1–§3.5 verbatim, with the supersessions below),
`designs/wal-impl.md` (the landed WAL), `designs/INDEX-STATE.md` (the state, the dump format, the clone seam),
`designs/wal-steps.md` (the landed WAL plan — its §B2 CRC reconciliation binds here too: the ordinal-0 terminator's
`crc_running` is `0`, never the register seed, `src/lifetime.zig:462-468`).

**SDK supersessions (§11) — do not follow the SDK where it differs:**

- `sdks/state-snapshot.md` §3.6 (registry: actor, format, ordering) — superseded by §2.4 here: the **elephant** rewrites
  a JSONL registry, whole-file, before the completion message. Not the index thread, not an append, not
  `host_idx:index_idx:...` lines.
- Its §5 "set `st.state` from the file-name tag" — superseded by the walked-head rule (§7.1).
- Its §1 and §6 rule 5 ("the own data set only") — superseded: **any hosted pair** is a snapshot subject (§1.2).

**One reconciliation, recorded once (the wal-steps §B2 precedent).** §3.3 says the dump elephant ends with "the single
`arena.reset(.free_all)` and job-shell destroy". Read literally that would dangle the handle that
`SnapshotClose`/`SnapshotCleanup` carry (§3.4, §4, §8) after the dump. The plan pins: **the arena reset runs at the
dump** (the clone and the dump bytes die there, success or failure — the SDK's release duty), and **the job shell is
destroyed exactly once by the terminal elephant** — the final-close elephant on success, the cleanup elephant on failure
— after `release(k)` and the `SnapshotDone` reply. The index thread stops dereferencing the job at its last dispatch and
nulls the in-flight flag on `SnapshotDone`. Nothing else in §3.3 changes.

**The file split, pinned by the design.** The writers, the composite, the battery windows and the fixed-file helpers are
`lifetime.Controller` resource management (`src/lifetime.zig`); the elephant task handlers are `src/elephant.zig`; the
ticker arm, the dispatch, the freeze and the swap are `src/index.zig` loop wiring. **No new files are created**; adding
fields and variants to existing files (`config.zig`, `messages.zig`, `cross_task.zig`, `cross_task_slots.zig`) is not a
new file. zigring needs nothing new: `Ring.pushTicker` exists (multishot IORING_OP.TIMEOUT, `ticks` in `sqe.off`: 0
repeats, 1 is one-shot, `zig-pkg/zigring-0.0.15-…/src/iouring.zig:1380`).

## How to work these steps (read once, obey always)

1. **No new APIs, no new names, no new files beyond the ones named.** Where the design delegates a name to the plan
   ("names and defaults are the plan's", "exact variant naming is the staged plan's"), the pinned shape in this plan's
   Vocabulary below is the name. Do not invent helper abstractions beyond them.
2. **Verify every symbol before use.** Grep (`rg -n`) for each name a step mentions. If a referenced line/symbol does
   not exist as described, re-read the surrounding code and the design section it cites — never guess a signature.
3. **One step = one commit-sized change.** After each step: `zig build` clean, `zig build test` green. Never start the
   next step with a red tree.
4. **The design doc's pinned rules are non-negotiable.** New-first-then-old; both-sides completion; the mark precedes
   the composite, which precedes every registry line; copy-start implies line-committed; the 16-byte slot cap; every
   `release` is an elephant's. If an implementation choice seems needed, the design already made it; search it again
   before deciding.
5. **No TODOs, no stubs left behind.** A skeleton step names the step that completes it, as in `wal-steps` §A4; the last
   step of a stage leaves nothing behind.
6. Where a step says "pin", that value is final — do not reinterpret it.

**Standing rules for the whole plan:**

- Elephant pushes **spin-retry** on `error.RingFull` (the `reportDone` idiom, `src/elephant.zig:67-75`); index pushes
  **never spin** — a refused push lands in the pending op (§4), retried once per batch pass (`index_inbox.zig:324-336`:
  a pass is ≤64 CQEs
  - ≤64 inbox tasks).
- The index thread only **acquires** and **sets statuses**; every `snapshot_slots.release(k)` is an elephant's (the
  final-close elephant on success, the cleanup elephant on failure).
- The control plane always flows: reserved `taskIdx` traffic and cross-task slots are processed regardless of the
  thread's WAL state; only the **front intake** is denied.
- fds cross threads exactly once: `job.fd` / `job.old_fd` are `-1` when not held; whoever closes one sets it to `-1` (a
  bare second `close(2)` could hit a reused fd number).
- Slot payload fields (`{ status, job }`, §2.1) are plain stores — a slot is exclusive from `acquire` to `release`, and
  the `MSG_RING` pass orders the write before the read, the same discipline the landed `cross_slots` payloads already
  rely on.

## Shared vocabulary (fixed for the whole plan)

- **The procedure**: one snapshot migration of one hosted pair `(host_idx: u8, index_idx: u16)`, a correspondence
  between the index thread (the state's owner) and elephant threads (the cold actors). **The window**: from the create
  dispatch to the swap.
- **The tag `X`**: the pair's `state_idx` at the first dispatch, fixed in the job, carried by both file names. **The
  clone state `Y`**: the cloned pair's `state` at the handler pass; `Y ≥ X` because the pair keeps serving. The chain
  anchor is `Y`, never the name.
- **Slot `k`**: a `snapshot_slots` index, held for the whole procedure; it is also the temp ring index. **Temp ring
  `k`**: battery area number `pairs + k`, geometrically identical to a pair area.
- **The mark**: the pair area's control line, `snapshot_in_progress = 1`, `new_wal_buffer_idx = k`, `target_state = X`.
  On ring lines (per-buffer headers) the three adoption fields are **zeros, forever** (`writeHeader` rewrites whole
  lines, so it zeroes them — now covering adoption state, §2.2).
- **Names** (§2.3): everything an index controls lives under `<wal root>/index.<index_idx>/`; leaves keep the globally
  unique spellings `wal.<host_idx>.<index_idx>.<32 hex>` and `snapshot.<host_idx>.<index_idx>.<32 hex>` (32 lowercase
  hex of the u128 state — `walPath`, `src/wal.zig:196-209`). The registry: fixed leaf `registry.jsonl`, staging leaf
  `registry.pending` (a constant, §2.4).
- **The registry line**: `{"host_idx":H,"snapshot_path":"...","wal_path":"...","state":Y}` plus a mandatory `\n`;
  `wal_path` names the **new** WAL; `"state"` is the clone state `Y` in decimal. Last line per `host_idx` wins (§2.4
  precedence).
- **Config block** (the plan's names and defaults, §1.2 and §2.1):

  ```zig
  pub const Snapshots = struct {
      interval_s: u32 = 60,
      size_barrier: u64 = 268435456,
      slots: u32 = 8,
      registry_keep: u32 = 8,
  };
  // Config gains: snapshots: Snapshots = .{},
  ```

  siggy: `snapshots = { interval_s = 60 size_barrier = 268435456 slots = 8 registry_keep = 8 }`. `interval_s` is the
  tick period `T`; `size_barrier` is the pair-size bar `S`; `slots` is the process-wide procedure bound `N` (≤ 65535,
  bounded by the mark's `new_wal_buffer_idx: u16`); `registry_keep` is the compaction knob of §2.4 (distinct from
  `slots` — the design overloads `N`; this plan does not).

- **Reserved task indices** (§1.1, §2.4), both in `src/messages.zig`:

  ```zig
  pub const SnapshotTickIdx: u64 = std.math.maxInt(u64) - 7;      // index ring; the repeating ticker
  pub const ProcessStopRequestIdx: u64 = std.math.maxInt(u64) - 11; // elephant -> init ring; runtime fatality
  ```

- **`CrossTask` variants** (§4; exact naming is this plan's), all plain data, the comptime `@sizeOf(CrossTask) <= 16`
  assert (`src/cross_task.zig:67`) keeps holding:

  ```zig
  // index -> elephant, each { job }:
  SnapshotCreate: struct { job: usize },   // create the new WAL file
  SnapshotDump: struct { job: usize },     // dump the clone + commit the registry line
  SnapshotCleanup: struct { job: usize },   // unwind cleanup
  SnapshotClose: struct { job: usize },     // final close of the old fd
  // elephant -> index:
  SnapshotFd: struct { fd: posix.fd_t },        // the create reply, fd alone (§3.1)
  SnapshotCreateFailed: struct {},              // rung 2
  SnapshotDumped: struct {},                    // dump + registry committed (§3.3)
  SnapshotDumpFailed: struct {},                 // rung 5
  SnapshotAbandon: struct {},                   // registry rewrite failed (rung 6)
  SnapshotDone: struct {},                      // terminal (§4): the in-flight flag clears on it
  ```

- **The snapshot slot payload** (§2.1), declared beside `CrossTask` in `src/cross_task.zig`:

  ```zig
  pub const SnapshotSlotStatus = enum(u8) { idle, in_flight, rollback };
  pub const SnapshotSlot = struct { status: SnapshotSlotStatus, job: usize };
  ```

  The index sets `in_flight` at the tick, `rollback` when an unwind dispatches cleanup; the releasing elephant clears it
  to `idle` before `release(k)` and warns if a cleanup arrives with a status other than `rollback`.

- **The job** (§2.1), in `src/lifetime.zig` — heap on `ctrl.allocator`, the SDK's integer-handle pattern
  (`sdks/state-snapshot.md` §3.2); its `usize` handle travels in messages:

  ```zig
  pub const SnapshotPhase = enum { create_sent, dump_sent, close_sent, cleanup_sent };
  pub const SnapshotJob = struct {
      arena: std.heap.ArenaAllocator,   // owns the clone + dump bytes until the dump's reset
      clone: state.IndexState,          // valid from the handler pass until the dump
      host_idx: u8,
      index_idx: u16,
      ring_idx: u16,                    // the requesting index ring: replies land there
      tag: u128,                        // X, minted at the first dispatch
      k: u32,                           // the snapshot slot = the temp ring index
      phase: SnapshotPhase,
      fd: posix.fd_t,                   // the new WAL fd; -1 when not held (sentinel rule)
      old_fd: posix.fd_t,               // the old WAL fd from the swap; -1 when not held
      wal_path: [:0]u8,                 // the NEW wal path, heap, ctrl.allocator
      snapshot_path: [:0]u8,            // heap, ctrl.allocator
  };
  ```

- **The index thread's frame state** (§4), in `src/index.zig`'s `run` frame: the in-flight job pointer (null = no
  procedure), the pending push, the live window, and the WAL service state replacing today's `faulted` bool
  (`src/index.zig:97`):

  ```zig
  pub const WalServe = enum { serving, frozen, stopped };
  pub const PendingPush = struct { slot_idx: u32, target_ring_idx: u16 };
  ```

  Front handlers deny when the state is not `serving`; ticks skip unless `serving` (rung 10: a failed-while-frozen
  thread is "stopped until restart" — its files do not grow).

- **The composite** (§3.2 step 4, §5), in `src/lifetime.zig`: writes every event **new first, then old**; an event is
  complete — durable, replyable — only when **both** sides' flushes have covered it; the old side's fault or `WalFull`
  freezes the front, the new side's fault is the ordinary terminal stop.

---

## Stage A — config and message vocabulary

Design doc: §1.2, §2.1, §2.4, §4, §6. Everything here is synchronous and cold.

### A1 The `snapshots` config block and the floors

Files: `src/config.zig`, `mpy6a.cfg`.

1. Add `Snapshots` (Vocabulary shape) and `snapshots: Snapshots = .{}` to `Config` (`src/config.zig:34-73`), beside
   `wal`. All four keys are omittable; defaults are pinned above.
2. Runtime validation, in `validate` (`src/config.zig:491`, the `validateWal` call at `:526`) or a sibling
   `validateSnapshots`: `interval_s >= 1`, `size_barrier >= 1`, `1 <= slots <= 65535` (the mark's
   `new_wal_buffer_idx: u16` bounds it, §2.1), `registry_keep >= 1`. New `ParseError` values (`:321-343`):
   `InvalidSnapshotInterval`, `InvalidSizeBarrier`, `InvalidSnapshotSlots`, `InvalidRegistryKeep`. No allocation inside
   `validate`.
3. **The buffer floor moves from 2 to 4** (§6): `validateWal`'s check at `:557` becomes
   `if (wal.buffers() < 4) return error.InvalidBuffers;` and the doc line at `:389-390` moves with it — four keeps a
   current buffer, a free buffer, and room for the bring-tail's flush-then-append (§3.6). Grep the test fixtures
   (`wal.zig`, `lifetime.zig`, `index.zig`) for `buffers` below 4 and bump them to 4.
4. **The registry embeds paths verbatim in JSONL** (§2.4), so extend the `InvalidWalDir` check to also reject `"` and
   `\` inside `dir` (both modes) — a JSON-hostile directory would make every line unparseable, which is the fatality.
5. `canonical` (`:354-356`) and `Manager()`'s comptime check (`:400-405`) reanchor themselves: `snapshots` has a full
   default, so the canonical literal stays valid unchanged — prove it by temporarily breaking a canonical snapshots
   value (e.g. `slots = 0` in a scratch edit) and watching the build fail, then restore. `default()` (`:471-482`)
   stringifies `canonical`; its output must re-parse and include the block.
6. `mpy6a.cfg` gains the pinned block; keep it in lockstep with the dev-document test literal in `src/config.zig` (`dev`
   test, ~:723-742) so that test keeps parsing.

Tests: each rejection fires its named error; `buffers = 3` → `InvalidBuffers`; defaults round-trip; `default()` output
re-parses and contains the snapshots block; the dev document parses; a `dir` containing `"` fails `InvalidWalDir`.

### A2 Reserved task indices

Files: `src/messages.zig`.

1. Add `SnapshotTickIdx = maxInt(u64) - 7` and `ProcessStopRequestIdx = maxInt(u64) - 11` (Vocabulary). `-7` is the only
   free index near the top: `-2`/`-3` are `index_inbox.zig:40/:44`, and `-1`, `-4`, `-5`, `-6`, `-8`, `-9`, `-10` are
   taken (`messages.zig:39-74`).
2. Extend `reserved_task_indices` (`:78-88`) and the comptime proofs (`:95-114`): pairwise distinct, none a
   `fireAndForgetTaskIdx`, all `>= (1 << 63)`, and still above the slot capacity bound.

Tests: the proofs are the tests — the comptime block fails the build on collision; add an explicit
`SnapshotTickIdx != messages.CrossTaskMessageIdx` sanity assert near the existing ones.

### A3 The `CrossTask` snapshot variants

Files: `src/cross_task.zig`.

1. Add the ten variants (Vocabulary) to `CrossTask` (`:27-54`), each with a one-line direction comment. The comptime
   plain-data check (`:56-68`) passes (all payloads are int/struct/void); the `<= 16` assert (`:67`) keeps holding —
   verify with a `@sizeOf(CrossTask)` test assert if the file has none yet.
2. Add `SnapshotSlotStatus` and `SnapshotSlot` (Vocabulary) beside the union — plain data, two words, the payload of the
   snapshot slot pool (§2.1).

Tests: extend "variants round-trip through a slot" (`:73-95`) with one snapshot request and one reply per direction;
assert `SnapshotFd` carries the fd and the empty variants store by copy; assert `@sizeOf(SnapshotSlot) <= 16`.

---

## Stage B — battery: the control line and the temp rings

Design doc: §2.2, §11 (the `wal-impl` §2 amendment). Files: `src/wal.zig`, `src/lifetime.zig`. Plain-mode logic tests
run the whole stage; PMEM shape reuses the landed barrier seam (`src/barrier.zig`, `persistHeader`,
`src/wal.zig:925-931`).

### B1 `BufferHeader` adoption fields

Files: `src/wal.zig`.

1. `BufferHeader` (`:57-79`) gains the three adoption fields into today's pads, no growth:

   ```zig
   data_len: u32,                       // @0
   flags: u32,                          // @4
   buffer_seq: u64,                     // @8
   crc_running: u32,                    // @16
   snapshot_in_progress: u8,            // @20  (was _pad_align)
   new_wal_buffer_idx: u16,             // @22
   last_state: u128 align(8),           // @24  (unchanged)
   target_state: u128 align(8),         // @40  (was _pad_tail, 16 of its 24 bytes)
   _pad_tail: [8]u8,                    // @56  (the remaining 8)
   ```

   The comptime asserts grow: `@sizeOf == 64`, `last_state @24`, plus `@offsetOf(..., "snapshot_in_progress") == 20`,
   `"new_wal_buffer_idx" == 22`, `"target_state" == 40`.

2. `writeHeader` (`:889-907`) rewrites whole lines and zeroes both pads today (`._pad_align = 0` `:902`,
   `._pad_tail = @splat(0)` `:904`); it now also zeroes `snapshot_in_progress`, `new_wal_buffer_idx`, `target_state` —
   "no ring line ever carries migration state and no lap can forge it" (§2.2).

Tests: extend "a header publish overwrites the whole control line" (`:1965`) to assert the three adoption fields are
zero after a publish over a line pre-filled with nonzero mark values; a layout test asserts the four offsets and the
64-byte size.

### B2 The control line, the temp section, the mint

Files: `src/wal.zig`, `src/lifetime.zig`.

1. **Geometry** (§2.2): the area stride grows one 64-byte control line after the header array — data array, header
   array, control line, alignment:

   - `areaStride` (`:233`): `alignForward(buffers * (lba + HEADER) + HEADER, granule)`.
   - `controlLineOffsetInArea(buffers, lba) = buffers * (lba + HEADER)`.
   - `batterySize` (`:261-263`) stays `areas * stride`; the **area count** grows.
   - `pub fn controlLineOf(area: []u8, buffers: u32, lba: u32) *BufferHeader` — a view of the 64-byte line at the area's
     end; no writer touches it (§2.2).
   - `pub fn tempAreaIdx(k: u32, pairs: usize) usize { return pairs + k; }`.

2. **The temp section**: `openBattery` (`:273-314`) parameter becomes the area count — the caller passes
   `pairs + cfg.snapshots.slots`; the `WalBatteryTooSmall` check (`:302`) grows with the total automatically. Plain
   mode's zeroing-at-allocation covers the temp rings and their control lines; PMEM uses them as found (the mint cleans
   what it must). `acquireWalBattery` (`src/lifetime.zig:348`) passes the grown count.
3. **The walk never touches the temp section** (§2.2): unchanged by construction — writers are wired to pair areas only,
   `chainLen` is bounded by the reader's own area (`:1591-1610`), and `walArea(pair)` (`lifetime.zig:339-343`) slices
   only pair areas. Add the negative test proving it.
4. **The mint** (§2.2, the last paragraph): a temp ring is reused procedure after procedure and the walk trusts
   `buffer_seq` (`walkVerdict` `:388-395`, `isFilled` `:1127-1130`), so the adopt mints before wiring a writer:

   ```zig
   pub fn mintArea(area: []u8, buffers: u32, lba: u32, head_state: u128, pmem: bool) void
   ```

   Zero the whole header array; **one barrier** (CLWB over the array + SFENCE in PMEM, a plain memset in plain mode);
   zero the area's control line (reserved, unused — §2.2); then publish the ordinal-0 terminator: `buffer_seq = 0`,
   `data_len = 0`, `filled` clear, `crc_running = 0` (the wal-steps §B2 reconciliation), `last_state = head_state`, and
   persist that line the `persistHeader` way (`:925-931`). A zeroed line classifies as stale at any nonzero ordinal; the
   writer's terminator-before-bytes invariant (`closeBuffer`, `:1096-1114`) covers the rest. The **data array is not
   zeroed** — stale data bytes are unreachable behind stale headers.

Tests: stride math over the legal `(buffers, lba)` grid (control line fully inside the area, data LBA-aligned, total =
`(pairs + slots) × stride`); mint over a garbage-filled temp ring → `walkVerdict` on every ordinal sees
stale-or-terminator and the ordinal-0 line reads `last_state = head_state`, `crc_running = 0`; a second mint over a used
ring re-kills stale lines; `walArea(pair)` cannot reach a temp ring (index bounds).

### B3 `walAdoptWrite` reshaped: adopt-without-close, on the temp ring

Design doc: §3.2 step 3, §11 (close-first contract reshaped). Files: `src/lifetime.zig`, `src/wal.zig` (nothing), tests
in both.

1. New shape (replacing `lifetime.zig:434-472`):

   ```zig
   pub fn walAdoptWrite(
       self: *Self,
       host_idx: u8,
       index_idx: u16,
       slot_k: u32,
       head_state: u128,   // the clone state Y — never the name tag (§2.3)
       fd: posix.fd_t,
   ) !*wal.WalWriteFile
   ```

   - **No close of the old writer** — delete the `:444-448` block and reshape the doc comment: the temp ring dissolves
     the structural objection ("two writers would share the pair's one ring and collide") — they no longer share one.
     The old writer's close moves to the final-close elephant (§3.4).
   - Area = `walArea(tempAreaIdx(slot_k, wal_pairs))`; `wal.mintArea(area, buffers, lba, head_state, is_pmem)`; wire
     `WalWriteFile.init(fd, Area.init(area, ...), ...)` over the temp ring; the writer's `head = head_state`; **do not**
     store it in `wal_writers[pair]` — the pair's entry keeps the old writer for the window's duration and the caller
     (the composite, §G) owns the new one. `walOpenWrite`'s one-writer guard (`:396`) is untouched: it holds outside a
     procedure and the adopt is the procedure's deliberate second writer (§3.2 step 3).
   - Keep `errdefer _ = std.os.linux.close(fd)`.

2. Reshape the landed tests (`:2038-2098`, per §11): "the swap closes the old writer before it takes the pair" becomes
   "adoption leaves the old writer open" — the old fd stays valid (`fcntl` `GETFD` == 0), `wal_writers[pair]` still
   names the old writer, the new writer's `head == head_state`, and its headers are the temp ring's. "adoption publishes
   the pair's ordinal-0 terminator" now reads the **temp ring's** header 0 and asserts `last_state == head_state` (the
   anchor is `Y`, not the tag — the `:2081`/`:2097` assertions keep their shape with the new meaning); its
   fake-registry-append block keeps proving "registry-visible implies the ordinal-0 terminator was persisted", which now
   holds because the publish happens at the adopt, still before the line (§9).

Tests: the reshaped pair above, plus: two adopts on the same `slot_k` while the first writer is alive is a caller bug —
assert via the composite's ownership instead (no new guard; document in the doc comment); `walOpenWrite` still refuses a
pair whose entry is live.

---

## Stage C — names, the index directory, the registry

Design doc: §2.3, §2.4. Files: `src/wal.zig`, `src/lifetime.zig`. Cold, synchronous.

### C1 The index directory and the path helpers

1. `src/wal.zig`: `snapshotPath(allocator, dir, host_idx, index_idx, state) ![:0]u8` —
   `"{s}/snapshot.{d}.{d}.{x:0>32}"`, mirroring `walPath` (`:196-209`) exactly. Add `walTagFromPath(path) ?u128` — the
   reverse of the leaf template: the 32-hex suffix of the basename, `std.fmt.parseInt(u128, .., 16)`, `null` on any
   mismatch (used only by the adoption rule's comparison and the future tool — startup never sets `st.state` from it).
2. `src/lifetime.zig`:
   - `indexDirPath(self, index_idx) ![]u8` — `"{dir}/index.{index_idx}"` from `cfg.wal.dir()`; the name template is
     **pinned**: `index.<index_idx>`, plain decimal.
   - `registryPath(self, index_idx) ![:0]u8` — `<indexDir>/registry.jsonl`;
     `registryPendingPath(self, index_idx) ![:0]u8` — `<indexDir>/registry.pending`, a constant staging name, never
     random (§2.4).
   - `ensureIndexDir(self, index_idx) !void` — `std.os.linux.mkdir` raw-errno idiom (the `delete` pattern, `:508-515`);
     `EEXIST` is success.
   - The three `wal.walPath(self.cfg.wal.dir(), ...)` call sites — `:399` (`walOpenWrite`), `:480` (`walOpenRead`),
     `:509` (`delete`) — now pass the **index directory** (`try self.indexDirPath(index_idx)`, `defer free`); leaf
     spellings are untouched, so tools and retention keep their globally unique names (§2.3).
3. Update the e2e test's stand-in create (`src/index.zig:300-305`, `:349-352`) to build its path the same way (the test
   stands in for the elephant, which also lives under the index dir after F1).

Tests: rendering of all four helpers (index dir, wal leaf, snapshot leaf, registry leaves); `walTagFromPath` round-trips
`walPath` and rejects non-hex/truncated suffixes; the pairing property (§2.3): equal tags pair `snapshot.h.i.X` with
`wal.h.i.X`, and a same-tag retry produces byte-equal names (the truncate-its-own-orphan property); `ensureIndexDir` is
idempotent.

### C2 The registry: read, rewrite, precedence

Files: `src/lifetime.zig` (fixed-file helpers are Controller resource management, § file split). Raw posix throughout,
the `walOpenFile`/`delete` errno idioms (`:372-383`, `:508-515`); no io_uring, no std.Io.

1. The entry type:

   ```zig
   pub const RegistryEntry = struct {
       host_idx: u8,
       snapshot_path: []u8,   // heap, ctrl.allocator; caller frees
       wal_path: []u8,
       state: u128,
   };
   ```

2. `loadRegistry(self, index_idx) !?[]RegistryEntry` — the fixed file, whole: absent (`NOENT`) → `null`; split on `\n`
   (a trailing empty line dropped); **every** line parses — `std.json.parseFromSlice` over
   `struct { host_idx: u8, snapshot_path: []const u8, wal_path: []const u8, state: u128 }` (strings dupe'd into
   `ctrl.allocator`); any unparseable line → `error.RegistryCorrupt` (the distinct fatality, §2.4); other I/O errors
   propagate. If the 0.17 std.json shape differs, hand-roll the parser for this pinned four-key format — do not widen
   the format. Read errors other than `NOENT` are the caller's policy: startup treats them as "no registry" with a
   `log.warn` (§7.3 "absent or unreadable"); the rewrite treats them as ordinary failures (rung 6).
3. `lastLineFor(entries, host_idx) ?*RegistryEntry` — the precedence rule: the **last** line with that `host_idx` wins
   (§2.4); lines naming other hosts are inert.
4. `rewriteRegistry(self, index_idx, entry: RegistryEntry) !void` — the elephant's whole rewrite (§2.4, numbered there
   1–6):
   1. `loadRegistry` — `RegistryCorrupt` propagates to the caller (the stop-request); absent starts empty; other errors
      → ordinary failure.
   2. Compaction on **every** write: keep the last `cfg.snapshots.registry_keep` entries per
      `host_idx < cfg.wal.hosts()`; drop inert lines (hosts the config no longer hosts). Kept lines are re-emitted
      **verbatim** — no re-render drift.
   3. Append the new line rendered from the pinned template —

      ```
      {"host_idx":<H>,"snapshot_path":"<p>","wal_path":"<p>","state":<Y>}\n
      ```

      — via `std.fmt.bufPrint`-style rendering into an output buffer (`{s}` for paths, `{d}` for `Y` in decimal); A1's
      dir validation is what makes the raw embedding safe. `entry.wal_path` names the **new** WAL; `entry.state` is the
      clone state `Y`. The entry's paths are **borrowed** for rendering (the elephant's call in F2 passes the job's
      paths, which the job teardown frees); only `loadRegistry` allocates entries, and its caller frees them.

   4. Write the whole result to `registryPendingPath`, `O_CREAT | O_TRUNC` (`ACCMODE = .RDWR`), a write-all loop.
   5. One `fdatasync` of the pending file — **the commit point**; it precedes the completion message and the rename.
   6. `rename(2)` over the fixed name. **No directory fsync** (§2.4: after any crash either the old or the new content
      stands whole; a lost rename loses the procedure, never the data). A leftover pending from a crashed procedure is
      junk the next rewrite truncates.

Tests: rewrite on an absent registry creates the fixed file with one line; compaction keeps the last `registry_keep` per
host and drops inert-host lines; `lastLineFor` precedence; `RegistryCorrupt` on a malformed line; a pre-existing
`registry.pending` with junk is truncated by the next rewrite; round-trip: what `rewriteRegistry` writes, `loadRegistry`
reads back (including a `state` above `maxInt(u64)`).

---

## Stage D — the snapshot slot pool and the job

Design doc: §2.1. Files: `src/cross_task_slots.zig`, `src/cross_task.zig`, `src/lifetime.zig`.

### D1 `CrossTaskSlots` generalized; `snapshot_slots`

1. `src/cross_task_slots.zig`: the pool (struct `:16-123`, fields `:23-33`) is concrete over `CrossTask` today —
   generalize it:

   ```zig
   pub fn SlotPool(comptime Payload: type) type { /* the existing body, parametrized */ }
   pub const CrossTaskSlots = SlotPool(cross_task.CrossTask);
   ```

   `tasks: []Payload`, `at(i) *Payload`; `init/deinit/acquire/release/freeCount` signatures unchanged. Every existing
   use site keeps compiling through the alias.

2. `src/lifetime.zig`: `Controller` gains `snapshot_slots: cross_task_slots.SlotPool(cross_task.SnapshotSlot)`,
   initialized beside `cross_slots` at `Controller.init` (`:155`) with `cfg.snapshots.slots`, and released in `deinit`.
   Why slots and not a counter (§2.1): the acquire must hand the procedure a stable, exclusive index for its whole
   duration, and that index is exactly the temp ring the procedure runs on — a counter can neither guarantee exclusivity
   nor hand the index back exactly once.
3. The index-thread acquire writes the payload: `status = .in_flight`, `job = @intFromPtr(job)`; the status flips to
   `.rollback` on unwinds; elephants clear to `.idle` before `release(k)`.

Tests: the existing stress test (`:237-264`) still passes through the alias; a `SlotPool(SnapshotSlot)` round-trips and
enforces the same `CrossTaskFull` bound; the two pools on one Controller are independent (exhausting one leaves the
other).

### D2 The job, the mint-at-tick, the elephant cursor

Files: `src/lifetime.zig`.

1. `SnapshotJob` and `SnapshotPhase` (Vocabulary). fds start `-1`; `clone` is `undefined` until the handler pass —
   document that reading it before the clone or after the dump's arena reset is a bug.
2. `Controller.mintSnapshotJob(self, host_idx, index_idx, tag: u128, k: u32, ring_idx: u16) !*SnapshotJob` — create the
   shell (`errdefer destroy`), init the arena (`errdefer deinit`), render `wal_path`/`snapshot_path` under the **index
   directory** (C1 helpers; heap, freed by the terminal elephant), fill the identity fields, `phase = .create_sent`.
   This mirrors `beginSnapshot` (`sdks/state-snapshot.md` §3.1) with the job extended to the whole procedure (see the
   reconciliation in the preamble).
3. `Controller.nextElephantRing(self) u16` — plain round-robin over the elephants (§2.1): one
   `elephant_cursor: std.atomic.Value(u32)` on `Controller`, shared by all threads (tasks are rare, contention a
   non-issue); `fetchAdd(1, .monotonic) % elephants + fronts + indexes` (the ring layout of `roleOf`,
   `lifetime.zig:551-589`). The procedure's successive picks naturally land on other elephants; with `elephants = 1`
   there is no choice, which the design allows.
4. `Controller.releaseSnapshotJob(self, job) void` — the terminal elephant's teardown: `arena.deinit()` (frees the clone
   and any dump bytes on paths where the reset never ran), free both paths, destroy the shell.

Tests: mint renders the pinned names with the tag and identity; the arena is live (allocate through it) and the teardown
frees everything under `std.testing.allocator`; `nextElephantRing` round-robins across elephants in ring-index order
under two racing threads (the sum of picks is a permutation).

---

## Stage E — the index loop: arms, ticker, dispatch

Design doc: §1.1, §1.2, §3.1, §4. Files: `src/index.zig`, `src/wal.zig` (one method).

### E1 The `CrossTaskMessageIdx` arm and the frame state

1. The thread's frame state (Vocabulary): replace the `faulted` bool (`src/index.zig:97`) with
   `wal_serve: WalServe = .serving`, and add `procedure: ?*lifetime.SnapshotJob = null`,
   `pending_push: ?PendingPush = null`, `window: ?lifetime.CompositeWriter = null`. The front guards at `:168` and
   `:183` become `if (wal_serve != .serving)` — the same close-at-once refusal; the control plane (reserved `taskIdx`,
   cross-task slots) keeps flowing (§5).
2. **The arm that fixes the leak** (§4): today a `CrossTaskMessageIdx` CQE falls into the drain's `else` (`:118-155`),
   `ring.slots.get` returns null, and the slot is **never released**. Add an explicit arm beside
   `StartWorkIdx`/`IndexWakeupTaskIdx` (`:107-112`):

   ```zig
   messages.CrossTaskMessageIdx => {
       const slot_idx: u32 = @intCast(cqe.res);
       const task = ctrl.cross_slots.at(slot_idx).*;
       ctrl.cross_slots.release(slot_idx);
       dispatchSnapshotReply(ctrl, task, <frame>, ...);
   },
   ```

   — receiver-released on read, exactly the elephant's shape (`src/elephant.zig:28-33`).

3. `dispatchSnapshotReply` switches on the variant. This step lands the arm and the `SnapshotDone` case (clears
   `procedure = null` — the flag is enforced to the true end of the procedure, §4); the create/dump/abandon cases are
   `log.warn`-and-ignore markers whose real bodies land in G3/G4/H per the design's failure ladder. Factor the per-CQE
   dispatch of the drain into `fn stepCQE(...)` now — the bounded drain of G2 reuses it.
4. The `wal_flush` arm's fault consequence (`:127-137`) moves into `fn onWriterFault(writer, frame)`: this step's rule
   is the landed one (any fault → `.stopped`); the window's old-side carve-out lands in G5.

Tests: the leak fix — acquire a slot, write a payload, `MSG_RING` it into a test index ring, run one drain pass, assert
`cross_slots.freeCount` is back to full and the payload was read; `SnapshotDone` clears a synthetic in-flight procedure;
the existing e2e test stays green with the frame reshape.

### E2 The repeating ticker

1. Arm once at index startup, after the `data_sets` init loop and before the service loop (`src/index.zig:70-99`):

   ```zig
   ring.tick_spec = .{ .sec = ctrl.cfg.snapshots.interval_s, .nsec = 0 };
   ring.ring.pushTicker(messages.SnapshotTickIdx, &ring.tick_spec, 0, .{}) catch |err| {
       log.err("snapshot ticker arm failed; snapshots disabled on this thread", ...);
   };
   ```

   — the repeating shape (`ticks = 0`, the `front.zig:221` pattern; `ticks = 1` is the one-shot deadline,
   `main.zig:212`); the timespec lives in the ring's own storage (`RingStuff.tick_spec`, `lifetime.zig:1226`) because
   the kernel reads it asynchronously. A failed arm disables snapshots on this thread only; the thread keeps serving.

2. The drain arm: `messages.SnapshotTickIdx => tickPass(...)`. `tickPass` is a named frame function so tests can drive
   it directly without waiting on a real timeout.

Tests: arming once and driving the ring yields `SnapshotTickIdx` CQEs with the right `res` cadence (drive with a
1-second spec in a test ring, consume two ticks, `pushCancel` to stop — the zigring doc's cancel path); the drain arm
routes to `tickPass` (spy via a frame counter).

### E3 The tick pass, the dispatch, the pending op

Design doc: §1.2, §3.1, §4 (the pending op).

1. `WalWriteFile.trackedExtent(self) u64` in `src/wal.zig` — `self.current * self.lba + self.cursor` (the fields at
   `:609`/`:611`): the writer's tracked write extent, buffered tail included, thread-local, no syscalls, no statx
   (§1.2).
2. `fn tickPass(...)`, on every tick CQE:
   - **Skips**: `wal_serve != .serving` (rung 10 — a stopped or frozen thread's files do not grow; a failed-while-frozen
     thread is stopped-until-restart), `procedure != null` (the thread's own flag), `pending_push != null` (§4). The
     tick never queues and never retries (§1.2).
   - Candidates are **all** hosted pairs (§1.2): for `host` in `0..hosts`, the live writer `ctrl.wal_writers[pair]` — a
     pair without a writer is not a candidate; the metric is `trackedExtent()`; pick the largest.
   - Below `cfg.snapshots.size_barrier` → return.
   - The tag: `X = data_sets[host].state` at this moment (§2.3).
   - `k = ctrl.snapshot_slots.acquire() catch return` — rung 0: the limit is the design working, not a failure; no
     retry, no log-abort (an `info` line at most).
   - `job = try ctrl.mintSnapshotJob(host, index_idx, X, k, role.index.ring_idx)` — an allocation failure here is a
     quiet unwind-before-start: destroy the job, release the slot, return (the tick retries on its own schedule).
   - Write the slot payload (`.{ .status = .in_flight, .job = @intFromPtr(job) }`), `procedure = job`.
   - Dispatch (§3.1): cursor pick 1 —
     `dispatchSnapshot(.{ .SnapshotCreate = .{ .job = @intFromPtr(job) } }, ctrl.nextElephantRing(), ...)`.
3. `fn dispatchSnapshot(payload, target_ring_idx, frame) void` — the ordinary `cross_slots` pool: acquire a slot, write
   the payload, then `pushMsgRingFd(ctrl.rings[target].ring.fd, messages.CrossTaskMessageIdx, slot_idx, .{})`. The
   push's refusal never drops and never spins (§4): on `error.RingFull` set
   `pending_push = .{ .slot_idx, .target_ring_idx }` — the slot is already acquired and its payload written; only the
   `MSG_RING` is retried.
4. `fn retryPendingPush(frame) void` — called once at the **top of every loop pass**: when `pending_push != null`, retry
   the `MSG_RING`; on success clear it. One pending op per thread suffices — one procedure per index, and a procedure's
   pushes are sequential (§4). While it is non-null the loop must not park: the `orelse` branch at `:100-103` becomes
   `if (pending_push != null) { std.atomic.spinLoopHint(); continue; }` before `inbox.hang(cfg)`.

Tests: each skip guard fires (synthetic frame states); the largest-over-`S` pick with two writers of known extents
(drive real `write`s); rung 0 ends the pass with the pool exhausted and `procedure == null`; a successful dispatch lands
the payload in a test elephant ring (read it back through `cross_slots`); a refused push (fill the target ring first)
parks in `pending_push` with the slot still held, and the next `retryPendingPush` completes it; the loop does not hang
while a push is pending.

---

## Stage F — the elephant handlers

Design doc: §3.1, §3.3, §3.4 (final close), §4, §8 (the cleanup elephant). Files: `src/elephant.zig`. `handleTask` gains
the controller — its signature becomes `fn handleTask(ctrl: *lifetime.Controller, task: CrossTask, log, own_ring_idx)`;
the existing variants keep their bodies.

**The reply idiom, one helper for the whole stage:** `fn replyTo(ctrl, ring_idx: u16, payload: CrossTask) void` —
acquire a `cross_slots` slot, write the payload,
`pushMsgRingFd(ctrl.rings[ring_idx].ring.fd, messages.CrossTaskMessageIdx, slot_idx, .{})` with the **spin-retry**
(`error.RingFull → spinLoopHint`, the `reportDone` idiom `:67-75`; elephants may spin, `index_inbox.zig:248-262`). The
job carries `ring_idx` so the reply lands on the requesting thread's ring (§4).

### F1 Create: the new WAL file

1. `.SnapshotCreate => |t|`: `j = @ptrFromPtr(t.job)` — `ctrl.ensureIndexDir(j.index_idx)` (best-effort: at runtime the
   dir exists; failure → reply failure), create `j.wal_path` under its **final** name, `O_CREAT | O_TRUNC`,
   `ACCMODE = .RDWR`, mode `0o644` (the raw-errno idiom); on failure, close the fd if one was made and reply
   `SnapshotCreateFailed`.
2. **One `fdatasync` before the reply** (§3.1). The truncate is load-bearing: a same-tag retry reopens a file that may
   hold the failed attempt's flushed prefix, and a stale prefix would survive the plain-mode walk as if it were content
   — truncate + sync the empty length kills it; an unreferenced file is retention's anyway.
3. Reply `SnapshotFd{ .fd }` — the fd **alone** (`{ job, fd }` measures 24 and breaks the cap; the
   one-procedure-per-index invariant makes the context unambiguous, §3.1). The fd is the only thing that crosses
   threads; the elephant never touches the battery or the live state (`wal-impl` §1.1, landed at
   `lifetime.zig:369-371`).

Tests: the file appears under the final name with length 0 even when pre-seeded with a garbage prefix; the reply's slot
payload carries the fd and the requesting `ring_idx` is honored (land the reply in a test ring); a create under an
unwritable path replies `SnapshotCreateFailed` and leaks nothing (fd asserted closed).

### F2 Dump: the snapshot, the registry commit, the abandon and stop-request seams

Design doc: §3.3, §2.4. The SDK discipline verbatim for the dump itself (`sdks/state-snapshot.md` §3.3–§3.5), with the
preamble's shell reconciliation.

1. `.SnapshotDump => |t|`: `j = ...`;
   1. `const state_y = j.clone.state;` — read before anything frees (§2.3: the chain anchor is `Y`).
   2. `var out: std.ArrayList(u8) = .empty; try ctrl.dumpIndexState(&j.clone, &out);` (`lifetime.zig:842`; `out` rides
      the clone's queue allocator — the arena).
   3. Write `j.snapshot_path` under its final name — no temporary names, no renames (§3.3): `O_CREAT | O_TRUNC`,
      write-all, then **one `fdatasync`** — the only snapshot-side barrier.
   4. `j.arena.reset(.free_all)` — the single reset releases the clone and the dump bytes (SDK §3.5; on failure the same
      reset runs — try/errdefer shape).
   5. The registry rewrite — the elephant is the registry's **only writer and the commit point** (§2.4):
      `ctrl.rewriteRegistry(index_idx, .{ .host_idx = j.host_idx, .snapshot_path = j.snapshot_path, .wal_path = j.wal_path, .state = state_y })`.
      The rewrite's own `fdatasync` precedes the completion message.
   6. Reply `SnapshotDumped` (spin-retry).
2. **Failure splits** (§8): a dump/write/fdatasync failure → the reset still runs, reply `SnapshotDumpFailed`. A rewrite
   failure that is **not** `RegistryCorrupt` → reply `SnapshotAbandon` (rung 6 — no truncation rung exists; the old file
   stands whole). `error.RegistryCorrupt` → **the stop-request**, before any abandon (§2.4, §8 rung 6):
   `fn requestProcessStop(ctrl, own_ring_idx, log)` — `log.err` the breadcrumb (the faulting elephant and the registry
   path), then `pushMsgRingFd(ctrl.init_ring.ring.fd, messages.ProcessStopRequestIdx, own_ring_idx, .{})` with the
   spin-retry. No reply to the index follows; the process is coming down (main's side is I1; with an invalid line there
   is no torn append that could have produced it — the file was corrupted some other way).

Tests: a synthetic clone (build a live state, `cloneIndexState` into a job arena) dumps to the pinned name, the registry
line lands with `state = Y` and the new `wal_path`, and the reply arrives; a pre-existing multi-line registry compacts;
an induced rewrite failure (the fixed path occupied by a directory → open fails) replies `SnapshotAbandon` and the old
registry stands whole; a garbage line in the registry sends `ProcessStopRequestIdx` into the init ring (test ring) with
**no** abandon; a dump failure replies `SnapshotDumpFailed` and the arena is freed (leak checker).

### F3 Final close and cleanup: the terminal elephants

Design doc: §3.4 (final close), §4, §8 (cleanup elephant, rung 9).

1. `.SnapshotClose => |t|`: `j = ...`; `close(2)` the `j.old_fd` **best effort** — warn on a nonzero errno, keep working
   (rung 9; close is hygiene, not durability: both modes are deliberately buffered and PMEM flushes are completed
   `RWF.DSYNC` `pwrite`s, `src/wal.zig:531-538`); set `j.old_fd = -1`;
   `ctrl.snapshot_slots.at(j.k).status = .idle; ctrl.snapshot_slots.release(j.k)`; `ctrl.releaseSnapshotJob(j)`; reply
   `SnapshotDone`.
2. `.SnapshotCleanup => |t|`: `j = ...`; unlink `j.wal_path` and `j.snapshot_path` best effort (`ENOENT` is fine; the
   create-failure rung has no file, §8); close `j.fd` and `j.old_fd` if `!= -1` (the sentinel rule), setting both to
   `-1`; warn if the slot status is not `.rollback` (defensive — the design's status field consumed where it lives);
   clear status, `release(k)`, `releaseSnapshotJob(j)`, reply `SnapshotDone`.

Both elephants reply one terminal `SnapshotDone` — the index's in-flight flag clears on it (§4), enforcing the
one-operation invariant to the true end.

Tests: close path — the old fd is closed (`E.BADF` via `fcntl`), the slot returns to the pool, `SnapshotDone` lands, the
job's paths are freed; cleanup unlinks both files, closes a live `j.fd`, tolerates absent files, releases, replies;
neither path leaves an allocation behind (`std.testing.allocator`).

---

## Stage G — the window

Design doc: §3.2, §3.4, §5, §6, §8. Files: `src/lifetime.zig` (the composite), `src/index.zig` (the passes, the freeze),
`src/wal.zig` (one pub).

### G1 The composite writer and both-sides completion

1. `src/lifetime.zig`:

   ```zig
   pub const CompositeWriter = struct {
       new: *wal.WalWriteFile,   // the temp ring k writer
       old: *wal.WalWriteFile,   // the pair area writer
       pending: std.ArrayList(PendingEvent),
       onComplete: ?*const fn (ctx: ?*anyopaque, end: u64) void,
       on_complete_ctx: ?*anyopaque,
       const PendingEvent = struct { end_new: u64, end_old: u64 };
   };
   ```

2. `write(self, new_state_idx: u128, data: []u8) !void` — **new first, then old** (§3.2 step 4: the order is
   load-bearing — the new WAL is the committed future, the old one the pre-commit fallback; if the old side refuses, the
   event is already in the new file). Floors are each side's own `head` — both sit at `Y`, so the first event is `Y+1`
   on both sides and each writer chains independently (`floor == head`, `src/wal.zig:955`). Record `PendingEvent` after
   both sides accept: `end_side = writer.current * writer.lba + writer.cursor` — the byte offset of the event's last
   byte (0 when the event filled a buffer exactly, which is the flushed extent once that buffer flushes).
3. `noteFlush(self, side) void` — called by the index drain after each side's `flushResult`: complete every FIFO-head
   event whose `end_new <= new.flushed_upto * new.lba` **and** `end_old <= old.flushed_upto * old.lba` (§5: complete —
   durable, replyable — only when **both** sides' flushes have covered it; either single-side rule loses durable events
   in one of the two crash outcomes). Deliver each completion through `onComplete`. The front never replies; indexes do,
   and only for complete events — the callback is the seam the consensus material will honor (§5).
4. `quiet(self) bool` — `!flush_in_flight and !flush_pending` on both sides (the fields at `src/wal.zig:603/:605`; at
   most one flush is ever in flight per writer).

Tests (pump-driven, the wal tests' `TestSink` shape, `src/wal.zig:2106`): an event completes only after both sides'
covering flushes — new-only and old-only flushes leave it pending, both complete it, and completions emerge FIFO; a
mid-buffer tail event completes only once its buffer fills and flushes; the callback order matches the write order.

### G2 The bounded drain and the unwinds A and B

Design doc: §3.4 (the bounded drain), §8 (Unwind A, Unwind B). Files: `src/index.zig`.

1. `fn drainUntilQuiet(frame) void` — the bounded drain (§3.4): loop `ring.ring.popCQE()` through `stepCQE` (E1's
   factored dispatch) until `window.quiet()`. Bounded: at most one flush is in flight per writer. **Not** `close`'s
   `awaitFlush` (`src/wal.zig:1238-1253`) — it retires and **drops foreign completions**, which mid-service would strand
   another pair's writer with `flush_in_flight` stuck. Control-plane messages that land during the drain are handled by
   the loop pass that follows (the drain runs the ordinary arms, and the one-procedure invariant means no second
   procedure message can arrive).
2. `fn unwindA(frame, job, opts: struct { mark_published: bool, writer_built: ?*... }) void` (§8): destroy a half-built
   writer object if the adopt got that far (memory only); clear the control line if the mark was published
   (`ctrl.clearAdoptionMark(host, index)`); set the slot status `.rollback`; `procedure.phase = .cleanup_sent`; dispatch
   `.SnapshotCleanup` via `dispatchSnapshot` (the pending op takes a refused push). End state: serving on the old pair;
   a truncated orphan under a tag no line references — retention's.
3. `fn unwindB(frame, job) void` (§8): revert to the old single writer (`frame.window = null`); `drainUntilQuiet` (both
   writers quiet); close the new writer — `close` is safe here precisely because the drain made it quiet — take its fd
   back through the sentinel: after the close set `job.fd = -1`; clear the control line; status `.rollback`; dispatch
   `.SnapshotCleanup`. If the thread was frozen, the stop stands (§5: no swap is coming). End state: serving on the old
   pair, or frozen until restart.

Tests: unwind A on a synthetic mark+slot clears the line (read back the control line), flips the status, and dispatches
cleanup into a test ring; unwind B over a live synthetic window reverts to the old writer (a subsequent write goes to
the old side only), closes the new writer's fd (BADF), clears the line, dispatches cleanup; a parked flush in either
writer is drained (pump a completion mid-drain and assert quiet reached).

### G3 The handler pass: mark, clone, adopt, composite, re-dispatch

Design doc: §3.2. The `SnapshotFd` case of `dispatchSnapshotReply` (E1's arm). One synchronous pass — no front message
is processed inside it, so nothing slips between its steps.

1. `job.fd = reply.fd` (the sentinel discipline — the index now owns it).
2. **Mark** (§3.2 step 1): `ctrl.publishAdoptionMark(host, index, k, X)` — barrier-rewrite the **pair area's** control
   line with `snapshot_in_progress = 1`, `new_wal_buffer_idx = k`, `target_state = X` (the `persistHeader` idiom —
   CLWB+SFENCE / plain store; a small `Controller` helper in `lifetime.zig` over `wal.controlLineOf`). Publishing after
   the create reply and before the composite serves widens the guarded window: every crash from here to the swap lands
   in one of the two restart branches — which is why the unwinds clear the mark.
3. **Clone** (step 2): `job.clone = ctrl.cloneIndexState(&data_sets[host], job.arena.allocator())` (`lifetime.zig:969`)
   — any hosted pair, own or mirror (§1.2); its state is `Y`, at or ahead of `X`: the pair kept serving, there is no
   pin. An allocation failure → `unwindA` (rung 3 — a quiet unwind with a log line, not the process-fatal idiom; the
   tick retries on its own schedule).
4. **Adopt** (step 3): `new_writer = ctrl.walAdoptWrite(host, index, k, job.clone.state, job.fd)` (B3's seam: mint ring
   k, open over the transferred fd on ring k, ordinal-0 terminator `last_state = Y`, head `Y`); `errdefer`-shaped
   failure → destroy the half-built object first, then `unwindA` (rung 4, memory-only, the clone's twin); `job.fd = -1`
   — the writer owns it now. Attach: `new_writer.attachStream(&ring.sqstream, &ring.slots)` (`src/wal.zig:668`).
5. **Composite** (step 4): `frame.window = .{ .new = new_writer, .old = old_writer }` with
   `old_writer = ctrl.wal_writers[pair]`. From here the pair's write interface is the composite; a new-side flush fault
   is the ordinary terminal stop, an old-side refusal freezes (G5).
6. **Re-dispatch** (step 5): cursor pick 2 —
   `dispatchSnapshot(.{ .SnapshotDump = .{ .job } }, ctrl.nextElephantRing(), ...)`; `procedure.phase = .dump_sent`. A
   refused push parks in the pending op and the pass ends — no spinning inside the pass; the window keeps serving.

Tests: the pass over a synthetic pair — after it: the control line reads `(1, k, X)`; the clone is a deep copy of the
pair (`cloneIndexState`'s tests prove the seam; here assert `job.clone.state >= X` after a served event); the new
writer's head is `Y` and its area is temp ring `k`; the composite is installed and a write lands new-first-then-old
(assert both files' contents after flushes); the re-dispatch lands `SnapshotDump` in a test ring; clone-failure and
adopt-failure rungs dispatch cleanup (drive with a poisoned arena / poisoned allocator).

### G4 The completion pass: drain, copy, clear, revival, the final close

Design doc: §3.4. The `SnapshotDumped` case of the arm.

1. **The bounded drain** — `drainUntilQuiet` (G2): both writers' in-flight flushes must land before the copy (a late
   `flushComplete` would publish a terminator into the pair area after the copy clobbered it, `src/wal.zig:1169-1189`; a
   new-side DMA still reading ring `k` must be done before `release(k)` is safe from any later acquirer).
2. **The copy** (§3.4): `ctrl.copyTempIntoPair(pair, k)` — the barriered `@memcpy` of ring `k`'s **data and header
   arrays only** (the copy never crosses a control line) into the pair area, then CLWB+SFENCE over both copied extents
   in PMEM / nothing in plain mode. Then **rewire**: `new_writer.data`/`new_writer.headers` are re-sliced to the pair
   area (`wal.Area.init` of the pair's bytes) — the temp ring's contents are dead but harmless until some later
   procedure mints ring `k` again (§3.4). The rewire is pointer-only: areas are geometrically identical by construction
   (§2.2), and ordinals/cursor continue unchanged.
3. **The clear**: `ctrl.clearAdoptionMark(host, index)` — barrier-rewrite the pair's control line with
   `snapshot_in_progress = 0` (zero the whole line).
4. **Revival, if frozen** (§5, G5's rule): compute from live writers only.
5. **Retire + final close**: the old writer is quiet; `job.old_fd = old_writer.fd`; destroy the old writer object
   **without** `close` (memory only — the fd moves to the elephant); `ctrl.wal_writers[pair] = new_writer`;
   `frame.window = null`; cursor pick 3 — `dispatchSnapshot(.{ .SnapshotClose = .{ .job } }, ...)`;
   `phase = .close_sent`. The index stops dereferencing the job here (the preamble's reconciliation); the flag clears on
   the terminal `SnapshotDone` (E1's arm).
6. The old WAL is now an unregistered orphan — retention's, never recovery's (§3.4).

Tests: drive a synthetic window with events in flight on both sides; run the completion pass; assert: the pair area
equals temp ring `k`'s data+headers byte-for-byte; the new writer's slices point at the pair area and a further write
lands in the pair area; the control line is clear; the old fd moved to `job.old_fd` (still open — the elephant closes
it) and `wal_writers[pair]` is the new writer; `SnapshotClose` landed in a test ring; after a fake `SnapshotDone`,
`procedure == null`.

### G5 Freeze, revival, and the record-size contract

Design doc: §5, §6.

1. `onWriterFault(writer, frame)` completes (E1's rule): if `frame.window != null` and the faulting writer is
   `window.old` and `wal_serve != .stopped` → `wal_serve = .frozen`; otherwise → `wal_serve = .stopped` (a new-side
   fault is the ordinary terminal stop; a relapse after revival finds `window == null` and stops terminally, §5). The
   stop is thread-level (the landed rule, `wal-impl` §3.5): one faulted writer denies the thread's whole front intake —
   all of a thread's WALs share one directory and device — while the control plane keeps flowing so the shutdown
   choreography completes.
2. Old-side **`WalFull` freezes too** (§5): for the composite, the oversized old file hitting capacity is exactly
   "cannot serve into the fallback"; the freeze is brief because the swap retires the old file. Classify the composite's
   write outcome — a small frame fn: old-side `WalFull` → freeze; new-side fault or any fault outside a window → stop;
   `RecordTooLarge`/`WalGap` are protocol answers, never triggers (the landed non-trigger set). Pure submission
   backpressure stays park-and-retry.
3. **Revival** at the swap (G4 step 4): `wal_serve = serving` iff no **live** writer of the thread's pairs is faulted
   (the old writer is retired from that set; the frozen window's events were written new-first and the registry line is
   committed — the front reopens; a relapse re-freezes terminally). A failed procedure while frozen leaves the stop
   standing: no swap is coming (§8 rung 10). Only the front advances a thread's pairs today, so a frozen thread is
   genuinely quiescent; the consensus design must preserve that (out of scope, §10).
4. **The record-size contract** (§6): `pub fn framedLen(data_len) usize` is private in `src/wal.zig` (`:959`) — make it
   pub. The intake check is **on the index side**:
   `fn recordFits(lba: u32, op_len: usize) bool { return wal.framedLen(op_len) <= lba; }` in `src/index.zig`, sitting at
   the thread's intake where every dispatched event passes — window or not (today the front's dispatch; the consensus
   channel lands there too). The refusal is a protocol answer with a client-facing diagnostic, not a fault, not a freeze
   trigger; the wire shape is the consensus design's. The WAL's structural cap (framed > `BLOCK_CONTENT` →
   `RecordTooLarge`, `:961`) is **unchanged** — records stay structurally legal spanning `lba`-sized buffers, and the
   WAL module and its spanning tests are untouched (§6).

Tests: freeze matrix — an old-side flush fault mid-window freezes (front guards deny, control plane arms still run); a
new-side fault stops; old-side `WalFull` freezes; revival at the swap reopens the front; a post-revival fault stops
terminally; a failed procedure while frozen keeps the freeze; `recordFits` boundary (`framedLen(op) == lba` fits,
`lba + 1` refuses; the 1 MiB structural cap is a separate, unchanged refusal).

---

## Stage H — startup recovery

Design doc: §3.5, §3.6, §7. Files: `src/lifetime.zig` (the rule, the bring-tail), `src/index.zig` (the wiring).
PMEM-shape tests run the battery in ordinary memory through the landed barrier seam (`wal-steps` §E1's flag).

### H1 The adoption rule

Design doc: §3.5. Run **per hosted pair, before any open of the pair** (§7.1 step 1).

```zig
pub const AdoptionResult = union(enum) {
    ordinary,
    adopted,                                    // the new pair won: the copy is done
    aborted: struct { k: u32, tag: u128 },      // the previous pair won: bring-tail pending
};
pub fn runAdoptionRule(self: *Self, host_idx: u8, index_idx: u16) !AdoptionResult
```

1. Read the pair area's control line (`wal.controlLineOf` over `walArea(pair)`). `snapshot_in_progress == 0` →
   `.ordinary`. Plain mode lands here always: its DRAM battery is zeroed at allocation, so the mark, the torn mix and
   the un-flushed tails die with the process and the branches never fire (§3.5) — no `isPmem` branch needed.
2. Otherwise read `(k, X)` from the line and consult the registry (the rule reads it ahead of §7.1's step 2 — the
   winning line decides, §3.5): `loadRegistry` → `lastLineFor(host_idx)`; absent line → the abort branch (no new line
   landed).
3. `wal.walTagFromPath(line.wal_path) == X` → **the adoption is needed** (the current pair bears `target_state` — the
   winning line names the migrating pair, §3.5): `copyTempIntoPair(pair, k)` — the same copy as the swap's, idempotent
   (the source is intact until the slot is reused); then `clearAdoptionMark`. → `.adopted`.
4. Otherwise → **the migration aborted** (the previous pair won): clear the line, "reclaim ring `k`" (no act — the pool
   is process-global and fresh at startup; the temp ring is dead but harmless until re-minted, §3.4), and flag the
   bring-tail `(k, X)` — its check runs after the writer open (H3). → `.aborted`.
5. `new_wal_buffer_idx` is the only pointer anyone needs (§3.5): the mark itself carries `k` and `X` on the pair's own
   area; the temp ring needs no identity tuple of its own.

**The crash table** (§3.5) is the test matrix — every row from create to post-swap:

| crash at            | pair area | fixed file | mark    | restart                                  |
| ------------------- | --------- | ---------- | ------- | ---------------------------------------- |
| create reply → mark | old chain | old line   | 0       | the old pair, exactly as today           |
| mark → line commit  | old chain | old line   | 1, k, X | abort: clear, reclaim, bring-tail (§3.6) |
| line commit → copy  | old chain | new line   | 1, k, X | adoption: re-copy ring `k`, clear        |
| mid-copy            | torn mix  | new line   | 1, k, X | adoption: re-copy (idempotent), clear    |
| copy → mark clear   | new chain | new line   | 1, k, X | adoption: re-copy (no-op data), clear    |
| post-swap           | new chain | new line   | 0       | the new pair                             |

Copy-start implies line-committed by construction (the elephant's `fdatasync` precedes the completion message, which
precedes the copy), so a torn pair area always exists **after** the new line and is always finished forward, never read
as the old pair — assert this ordering in the tests, not just the rows.

Tests: one test per row (PMEM-shape battery, real files, real registry via C2 helpers); each row constructs the exact
pre-crash state (area contents, control line, registry), runs `runAdoptionRule`, and asserts the branch, the resulting
pair area, and the cleared mark; the idempotence of a repeated copy (run `.adopted` twice); plain mode always
`.ordinary` (battery zeroed).

### H2 The bring-tail

Design doc: §3.6. **Scope: PMEM only** — in plain mode the mark dies with the battery so the branch cannot fire, and
under the completion rule there is nothing durable to repair there anyway (§7.2). Runs after the old writer is open (the
"startup-opened writer", §3.6).

```zig
pub fn bringTail(self: *Self, host_idx: u8, index_idx: u16, k: u32, tag: u128,
    old_writer: *wal.WalWriteFile, head_before: u128, sink) !void
```

1. **The check** reads the abandoned pair the way recovery reads any pair — the new file's flushed bytes merged with a
   ring chain by ordinal (the `beginRead` extent shape, `src/wal.zig:1670-1679`) — except the ring is temp ring `k`,
   walked directly: `WalReadFile.init(fd_of(wal.h.i.X), cfg.wal, Area.init(temp_area, ...), host, index, X)` and
   `beginRead(.{ .seek_then_read = head_before })` (the read path's own floor filter, `:1303`). Drive it synchronously
   (`process.drive(null)` — the sync `pread` arm) into a collecting sink. Normally the delivery is empty. The only
   possible gap is the inter-write cut: the composite writes new-first-then-old as two synchronous battery writes, so a
   power cut between them leaves exactly **one** record new-side but not old-side (§3.6) — everything earlier reached
   both rings, and everything the old ring holds is recovered by its own walk. The abandoned file may be absent entirely
   (retention or a failed create never reached it): absent → empty delivery.
2. **The bring**: flush the old writer's un-flushed tail first — the startup-opened writer drives its filled buffers
   into the file, emptying the chain — then append each delivered record through the ordinary write path
   (`writer.write(state, writer.head, op)`), then flush again. For the flush-and-wait use a startup-safe drive: the
   `awaitFlush` idiom (`:1238-1253`) is safe **here** (startup is single-writer on the ring; the foreign-completion
   hazard is a mid-service one, §3.4) — expose it as `WalWriteFile.flushAndWait()` or drive `popCQE`/`park` inline; the
   appended record's partially-filled buffer stays as the live tail (ring-durable in PMEM, recovered by the old ring's
   own walk — do not invent a pad-flush).
3. **Room is guaranteed twice over** (§3.6): structurally, the record once fit ring `k`'s ordinary path — which keeps a
   buffer free (`:974-975`) and may carry an un-flushed tail — so it fits the same-sized old ring emptied by the flush,
   a fortiori; and by the two constraints of §6 — a record ≤ `lba` (G5's intake contract) and a file's ring of at least
   4 buffers (A1's floor).

Tests (PMEM-shape): the inter-write cut — construct a window, write events, simulate the cut (new side holds one record
the old side lacks: write to the temp writer only), crash "restart", open the old pair, run the abort branch +
bring-tail, and assert the old file now replays every record the new side had, with the chain intact (`floor == head`
holds afterwards); an empty delivery is a no-op; the bring respects `seek_then_read`'s floor (records below the old head
are not re-delivered).

### H3 The per-pair startup sequence

Design doc: §7.1. Files: `src/index.zig` (replacing the "snapshot design:" comment block at `:84-90` with the real
wiring, cold, before the service loop), `src/lifetime.zig`.

Per hosted pair, in order (§7.1):

1. `runAdoptionRule` (H1) — before any open of the pair.
2. `loadRegistry` → `lastLineFor(host_idx)`. `error.RegistryCorrupt` is the startup fatality: `log.err` and
   `std.process.exit(1)` — the process does not come up (§2.4). Absent, or unreadable for other reasons → the pair
   starts **empty**: state 0, no writer, a `log.warn` (§7.3: startup does not scan; recovery from a lost registry is a
   toolchain QoL command, out of scope — the design's obligation is only the pairing property the tool consumes, already
   asserted in C1).
3. Load the snapshot: read the entry's `snapshot_path` whole (raw posix), `ctrl .loadIndexState(bytes)`
   (`lifetime.zig:890`, version 1, `src/state.zig:19`); the loaded state replaces the thread's empty `data_sets[host]`
   (deinit the placeholder, move in, `deinitIndexState` on the thread's exit path stays).
4. Open the writer: `writer = ctrl.walOpenWrite(host, index, walTagFromPath(entry .wal_path).?)` — the walk supersedes
   its head — then set `st.state` **from the walked head, never from a name** (§2.3, §7.1):
   - **PMEM**: `st.state = writer.head` (the persisted ordinal-0 terminator's `last_state` walked forward); the line's
     `"state"` key is redundant and ignored.
   - **Plain**: `st.state = writer.head = max(writer.head, entry.state)` — the empty-file walk returns `head == tag` and
     publishes the terminator itself (`walkPlain`, `src/wal.zig:779-782`), so an empty new file under a tag `X < Y`
     walks to `X` and is corrected to `Y`; a non-empty file walks past `Y` and the key is inert. A missing WAL file
     surfaces the raw open error — fatal at startup, never repaired (wal-impl §1.1).
     `writer.attachStream(&ring.sqstream, &ring.slots)`.
5. The bring-tail if H1 returned `.aborted` (H2 — after the attach, since it flushes).
6. Replay: `walOpenRead` + `beginRead(.{ .seek_then_read = st.state })` into a sink that applies through
   `ctrl.applyIndexOp` with `st.state` set per record (the e2e test's `Replay` shape, `src/index.zig:284-295`), driven
   on the owning index thread (wal-steps §F2).

The full startup choreography (init handshake, `INITIALIZED` reports) is untouched — this step only fills the seam the
landed comment block reserved.

Tests: a full synthetic lifecycle — snapshot a pair (drive G3–G4 or the C2/J1 helpers), restart into a fresh
`Controller` over the same files, and assert the sequence recovers: the adopted pair serves from the new WAL with
`st.state` from the walked head, the replay applies exactly the post-snapshot records, and the registry's compaction
holds; plain mode's empty-new-file-under-`X<Y` correction (assert `st.state == Y`); absent registry → empty pair; a
corrupt line → the process-exit path (assert via the fn's error return in tests rather than a real `exit` — factor the
fatality as a returned error the wiring turns into `exit`).

---

## Stage I — the runtime fatality

Design doc: §2.4 (the fatality's runtime arm), §8. Files: `src/main.zig`, `src/elephant.zig` (already landed in F2:
`requestProcessStop`).

### I1 The process-stop request and main's widened park

1. `src/main.zig`'s process wait (`:176-188`) today blocks reading the signalfd. Widen it to **signalfd and init-ring
   CQEs** (§2.4): factor `fn awaitStopCause(ctrl, signal_fd) StopCause` where
   `StopCause = union(enum) { signal: u32, process_stop: u16 }` — `posix.poll` over
   `{signal_fd, ctrl.init_ring.ring.fd}`; signalfd readable → read the `signalfd_siginfo` and return `.signal`; the ring
   readable → `popCQE` until `ProcessStopRequestIdx` (other CQEs cannot arrive here — the init ring is idle after
   `waitForInitialized` — log and drop defensively) and return `.process_stop` with the sender's `ring_idx` (the
   operator's breadcrumb pairs with the elephant's `log.err`).
2. On either cause, run the existing graceful `shutdown(&ctrl, total)` (`:261-307`) — fronts and elephants included
   (indexes stop via their fronts, the landed shape) — then `joinThreads` as today. The park must not spin: `poll`
   blocks on both fds; the init ring's fd is pollable (its CQ makes it readable).

Tests: `awaitStopCause` with a test init ring — push `ProcessStopRequestIdx` and assert `.process_stop` with the sender
idx; the signalfd arm with a real blocked signal (`SIGTERM` raised by the test) returns `.signal`; a stray foreign CQE
is dropped without hanging.

---

## Stage J — gates and landed-material amendments

### J1 The end-to-end plain-mode procedure

Files: `src/index.zig` (test), fixtures from the landed e2e (`:307-414`).

One test driving the whole procedure with the real handler functions and the real drain, no real timers: config with a
tiny `size_barrier`; write records into a pair until the tick would fire; call `tickPass` directly (E2's named fn); run
F1's create inline (or the test's stand-in — prefer the real handler with a test elephant ring); step the index drain
(E1's `stepCQE`) to process the `SnapshotFd` reply → G3's handler pass; run F2's dump inline; step the drain → G4's
completion pass; run F3's close inline; step the drain → `SnapshotDone`. Assert: the registry holds exactly one line
naming the **new** WAL with `state = Y`; the old WAL file still exists on disk but no line names it; the snapshot loads
(`loadIndexState`) and equals the pair at clone time; the new writer serves further writes (floor chains); the temp ring
is dead; `procedure == null` and the snapshot slot is back in the pool; then restart (H3) into a fresh `Controller` and
assert the replay reconstructs every session the pre-procedure e2e wrote. `zig build test` green is the gate.

### J2 The PMEM-shape crash-table and freeze gates

Files: tests beside H1/H2/G5.

Consolidated gates over the barrier-seam "PMEM" battery: all six crash-table rows through the full startup sequence (not
just `runAdoptionRule`); the inter-write-cut bring-tail recovery (H2); the freeze ladder (G5's matrix through the real
drain: old-side fault mid-window → frozen front, procedure completes, revival at the swap, relapse stops); rung 10 — a
stop mid-window completes the procedure on the control plane (the final close lands, the flag clears) and the end state
is revived-or-stopped. This is the stage where "copy-start implies line-committed" is asserted end-to-end: a procedure
whose registry rewrite is induced to fail after the pending-write but before the rename leaves the old line winning and
recovery-correct.

### J3 The design amendments of the landed material

Files: `designs/INDEX-STATE.md`, `designs/wal-impl.md`, `docs/todo.md`. Editorial only.

1. `designs/INDEX-STATE.md` §12's own-scope bullet (`:607-608`, "The clone covers the **own** data set only (just
   index); mirror data sets are never cloned by this path.") gains its one-line amendment pointing at
   `designs/SNAPSHOTS.md` §1.2/§11: any hosted pair is a snapshot subject.
2. `designs/wal-impl.md` §2 gains the amendment (SNAPSHOTS §11): `BufferHeader` carries `snapshot_in_progress: u8` @20
   and `new_wal_buffer_idx: u16` @22 in the former `_pad_align` word and `target_state: u128 align(8)` @40 in the former
   `_pad_tail`, fitting the pinned 64-byte line without growth; the area stride grows one 64-byte control line after the
   header array; the battery gains the `N`-ring temp section. A pointer back to `designs/SNAPSHOTS.md` suffices — do not
   rewrite §2 wholesale. `wal-impl` §3 is **not** amended (the record cap stays at the 1 MiB block; the `lba` bound is a
   producer contract enforced at the index thread, §6 here).
3. `docs/todo.md` keeps its sketches untouched (the registry-rebuild utility at `:42-46` is the §7.3 tool — out of
   scope; retention and orphan cleanup stay §10 exclusions; the `RWF.DSYNC` entry was already absorbed by wal-steps
   §Z/§D2 — leave it).
4. `sdks/state-snapshot.md` is left untouched — its supersessions are recorded here and in the design's §11, the
   `docs/SNAPSHOTS.md` precedent.

Final gate: `zig build` clean, `zig build test` green, including every earlier stage's tests; `mpy6a.cfg` parses and
`show-dev-config` renders the snapshots block.

---

## Step order and dependencies

```
A1 -> A2 -> A3 ──┬─> B1 -> B2 -> B3 ─────────────┐
                 ├─> C1 -> C2 ───────────────────┤
                 └─> D1 ─────> D2 (needs C1) ────┤
                                                 v
      E1 -> E2 -> E3 -> F1 -> F2 -> F3
                       └> G1 -> G2 -> G3 -> G4 -> G5
                                        └> H1 -> H2 -> H3 -> I1
                                                            └> J1 -> J2 -> J3
```

- A is pure vocabulary; B (battery), C (names/registry) and D (pool/job) are cold and independent of each other except
  D2→C1; the linear order above is one valid topological order.
- E needs A (indices, variants) and D (slots, job); E1's `stepCQE` factor is reused by G2's bounded drain.
- F needs C (paths, registry) and D (job); F2 lands `requestProcessStop`, consumed by I1.
- G needs B3 (the adopt seam), E (arms, dispatch), F (handlers) and G2's unwinds are what G3's failure rungs call.
- H needs G4's copy helper and C2's registry; the crash-table rows are H1's tests, the bring-tail H2's.
- I needs A2 and F2. J last: J1 is the end-to-end gate, J2 the PMEM-shape matrix, J3 the editorial amendments.
