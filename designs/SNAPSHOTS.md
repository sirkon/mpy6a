# Snapshots

Promoted from `.mailbox/snapshots/4.md`; the mailbox directory keeps the thread's full history.

The snapshot mechanism — decoupled from consensus, opportunistic per `(host_idx, index_idx)`. Once every `T` seconds
each index thread looks at the tracked extents of its hosted pairs' WAL files and, for the largest pair over the size
barrier, takes a state snapshot and starts a new WAL file. The procedure runs as a correspondence between the index
thread (the state's owner) and elephant threads (the cold actors): the index clones, adopts and swaps; an elephant
creates files, dumps the clone, rewrites the registry, closes the old fd, and cleans up failures.

This document is a **design prelude** — the specification an implementation plan will be written from. The plan's
dedicated split-into-stages step comes later and is not this design's business (the `wal-impl` → `wal-steps`
precedent: the design is the specification, the steps document is split from it afterwards).

The file split, given by the author: the writers, the composite, the battery windows and the fixed-file helpers are
`lifetime.Controller` resource management (`src/lifetime.zig`); the elephant task handlers are `src/elephant.zig`; the
ticker arm, the dispatch, the freeze and the swap are `src/index.zig` loop wiring. **No new files are created**; adding
fields and variants to existing files (`config.zig`, `messages.zig`, `cross_task.zig`, `cross_task_slots.zig`) is not a
new file.

Companions: `sdks/state-snapshot.md` (the clone/dump/arena SDK this procedure plugs into), `designs/wal-impl.md` (the
landed WAL module), `designs/INDEX-STATE.md` (the state, its dump format, the clone seam), `docs/shard-arch-hld.md`
(threads, rings, the index as execution flow), and the source design `docs/SNAPSHOTS.md` — left untouched, superseded
by this document wherever they differ.

## 1. The trigger

### 1.1 The ticker

Each index thread arms, at startup, a repeating io_uring timeout op on its own ring — `pushTicker(taskIdx, spec, count,
flags)` with count 0 (the repeating shape, the `src/front.zig:221` pattern; count 1 is the one-shot deadline,
`src/main.zig:212`), the period `T` from config, the timespec parked in the ring's own storage (`RingStuff.tick_spec`,
`src/lifetime.zig:1226` — the kernel reads it asynchronously, so it must outlive the arming). The tick is the
timeout CQE itself under a new reserved `taskIdx`: **`maxInt(u64) - 7`**, the only free index near the top (`-2` is
`CrossTaskMessageIdx` and `-3` is `IndexWakeupTaskIdx`, `src/index_inbox.zig:40`, `:44`; `-1`, `-4`, `-5`, `-6`, `-8`,
`-9`, `-10` are taken, `src/messages.zig:39-74`). No new thread, no shared timer service; the timing wheel stays out of
it (it is the session-retry wheel).

### 1.2 The tick pass

On the tick CQE the index thread skips the pass when the thread is stopped (the terminal stop — a stopped thread's
files do not grow), a procedure is already in flight for this index (the thread's own flag), or the pending op is
non-null (§4). Otherwise it reads the hosted pairs' tracked write extents and picks the largest pair above the global
size barrier `S`.

Both `T` and `S` are single global config fields, the same for all indexes; names and defaults are the plan's. The
metric is the writer's tracked write extent — buffered tail included (`current`/`cursor`, `src/wal.zig:608-611`):
thread-local, no syscalls, no statx on the hot path. The candidates are **all** pairs the thread hosts — the own data
set and every mirror alike; they are the same `IndexState` values, equally thread-local and equally quiescent, and
`cloneIndexState` (`src/lifetime.zig:969`) deep-copies any of them.

Then `snapshot_slots.acquire()` → `k`, or the tick ends if the process-wide limit is hit — the limit is the design
working, not a failure. The tick never retries.

## 2. The machinery

### 2.1 The snapshot slot pool, the job, the cursor

- `lifetime.Controller` gains `snapshot_slots` — a `CrossTaskSlots` **generalized over its payload type** (today it is
  concrete over `CrossTask`, `src/cross_task_slots.zig:16-25`), `init(allocator, N)` beside `cross_slots` at
  `Controller.init` (`src/lifetime.zig:155`). `N` is the process-wide bound on parallel procedures — several index
  threads may run procedures concurrently, capacity permitting — and config validates `N ≤ 65535` (the mark's
  `new_wal_buffer_idx: u16` bounds it). The source design's per-index one-operation rule holds on top of it, as a
  correctness rule rather than a resource one: one composite per thread, guarded by the thread's in-flight flag (the
  pair's writers belong to it).
- Why slots and not an atomic counter in a critical section: the acquire must hand the procedure a **stable, exclusive
  index for its whole duration**, and that index is exactly the temporary-WAL ring the procedure runs on (§2.2) — a
  counter can neither guarantee exclusivity across the window nor hand the index back exactly once from wherever the
  procedure ends.
- The snapshot slot's payload is a two-word struct `{ status, job }`: `in-flight` at the tick, `rollback` when an
  unwind dispatches cleanup, cleared by the elephant's `release(k)`.
- The job is heap, `ctrl.allocator` — the SDK's integer-handle pattern (`sdks/state-snapshot.md` §3.2). It carries
  `host_idx`, `index_idx`, the tag minted at dispatch, `k`, the phase, the fd, the arena, the clone, the old fd, and
  the paths. Its handle is what travels in messages.
- The elephant selection is plain round-robin over the elephants: one atomic cursor in `lifetime.Controller`, shared
  by all threads (the tasks are rare, so contention is a non-issue). The procedure's three picks naturally land on
  other elephants, which satisfies the source design's "the elephant may be a different one" without load tracking.

### 2.2 The battery: pair areas, control lines, temp rings

Today the battery is purely rings: `pairs × stride`, each pair's area a data array then a header array
(`src/wal.zig:241-249`, `:261-263`), sliced per pair at `i × stride` (`src/lifetime.zig:341-342`), wired by `Area.init`
(`src/wal.zig:351-359`). The per-area granule-rounding tail cannot host anything — it is zero bytes whenever
`buffers × 64` fills the granule exactly. Two changes:

- **The stride grows by one 64-byte control line**, after the header array: data array, header array, **control
  line**, alignment.
- **A temp section of `N` rings is appended** to the mapping — each geometrically identical to a pair area, control
  line included (reserved, zeroed at the mint, unused) so the areas stay uniform. The window's new writer lives on
  temp ring `k`: PMEM-published control lines (`CLWB`+`SFENCE`, `src/wal.zig:925-931`), a crash-durable un-flushed
  tail, `RWF.DSYNC` flushes — the same guarantees as a home writer, which is the whole point: a mid-window power cut
  must leave the new file's tail recoverable exactly as the old file's is. Plain mode keeps the same geometry in
  DRAM, where durability stays file-only (`src/config.zig:89-90`).

`openBattery` maps the larger total; the `WalBatteryTooSmall` check (`src/wal.zig:302`) grows with it. The walk and
`chainLen` never touch the temp section — it is reached only through a writer wired to it or through the adoption mark.

**The control line is the adoption mark's home.** `BufferHeader` today is exactly 64 bytes with 28 bytes of pad:
`data_len: u32` @0, `flags: u32` @4, `buffer_seq: u64` @8, `crc_running: u32` @16, `_pad_align: u32` @20,
`last_state: u128 align(8)` @24, `_pad_tail: [24]u8` @40 (`src/wal.zig:57-79`, size asserted `:76`; the layout pinned
by `wal-impl` §2). The three adoption fields fit without growing the line: `snapshot_in_progress: u8` @20 and
`new_wal_buffer_idx: u16` @22 into the `_pad_align` word, `target_state: u128 align(8)` @40, using 16 of the 24 tail
bytes.

On the ring's own lines those fields are **zeros, forever** — a feature, not a gap: `writeHeader` rewrites whole lines
(`src/wal.zig:889-907`), zeroing both pads ("a stale lap cannot leak a field into the new one", `:886-888` — now
covering adoption state too), so no ring line ever carries migration state and no lap can forge it. The mark lives on
the per-area control line, which no writer touches; the adoption dance rewrites only it. The field matters precisely
where the line persists — PMEM, where the control line and its data survive together.

**The mint.** Temp ring `k` is reused procedure after procedure, and the walk trusts `buffer_seq` (`walkVerdict`,
`src/wal.zig:388-395`; `isFilled`, `:1127-1130`), so a previous procedure's stale lines must never be reachable. The
adopt therefore mints the ring before wiring the writer: clean the header array, one barrier, then publish the
ordinal-0 terminator. A zeroed line classifies as stale at any nonzero ordinal, and the writer's own
terminator-before-bytes invariant (`closeBuffer`, `src/wal.zig:1096-1114`) covers the rest.

### 2.3 The names, the tag, the index directory

- `<wal root>/<indexDirName(index_idx)>/` hosts everything an index controls: the pair's WAL files, the snapshots and
  the registry alike — so whole index directories can be mapped onto different drives at the hardware-setup level.
  The name functions are templates like `index.{index_idx}`; exact spellings are the plan's. `walPath`'s `dir`
  argument becomes the index directory at the three Controller call sites (`src/lifetime.zig:399`, `:480`, `:509`)
  plus the snapshot-path helper; the leaf names keep their globally unique `wal.<host_idx>.<index_idx>.<state>`
  spelling (32 lowercase hex, `walPath`, `src/wal.zig:196`) — the `index_idx` stays in the name for tools and
  retention. Nothing is deployed, so nothing migrates.
- The **tag** is the pair's `state_idx` at the first dispatch, fixed in the job, carried by both names:
  `snapshot.<host_idx>.<index_idx>.<X>` and `wal.<host_idx>.<index_idx>.<X>`. The names are **ordered markers, not
  content bindings**: the pair is not pinned for the window, events keep flowing between dispatch and the handler, so
  the snapshot content sits at a state `Y ≥ X` while both names say `X` — by design, because equal tags make the
  snapshot+WAL pair detectable by name if the registry is ever lost, which is more reliable than reconstructing a
  `W1 < S1 < W2 < S2` ordering.
- **The pairing property:** `snapshot.h.i.X` pairs with `wal.h.i.X`; equal tags, unique among live files (a same-tag
  retry truncates its own orphan). The maintenance tool consumes it (§7.3); startup does not.
- The chain anchor is therefore **the clone state `Y`, never the name**: the adopt publishes the new WAL's ordinal-0
  terminator with `last_state = Y` and sets the writer's head to `Y`, in both modes; the loader takes `st.state` from
  the walked head, never from a name (§7.1).

### 2.4 The registry

One fixed file per index directory — `<indexDir>/registry.<...>`, exact leaf name the plan's — with a **fixed**
pending name `<indexDir>/registry.pending` as the rewrite's staging name, a constant, never a random temporary. The
elephant is the registry's only writer and the commit point. **On every change** — once per successful procedure:

1. Read the current file. An unparseable line met here is the runtime fatality (below).
2. Keep the last `N` lines per hosted `(host_idx, index_idx)` — the compaction knob, applied on every write; there is
   no size threshold.
3. Add the new line `{"host_idx":H,"snapshot_path":"...","wal_path":"...","state":Y}` with its mandatory `\n` —
   `wal_path` names the **new** WAL, and the `"state"` key is the clone state `Y` (plain mode's recovery reads it,
   §7.1).
4. Write the whole result to the pending name, `O_CREAT | O_TRUNC`.
5. One `fdatasync` of the pending file: the commit point, before the completion message.
6. `rename(2)` over the fixed name.

Consequences, normative:

- **No bare appends exist.** Every write is the compaction, transactionally; there is no append that can tear. A
  leftover pending from a crashed procedure is junk for retention; the next rewrite truncates it.
- **No directory fsync is demanded.** The `fdatasync` precedes the rename; after any crash either the old content or
  the new content stands whole under the fixed name. A lost rename is an aborted migration, and an aborted migration
  is recovery-correct (the window's events live in the old pair too, §5) — losing the rename loses the _procedure_,
  never the _data_.
- **The fatality stands for what remains.** An unparseable line is a fatal error of startup and of functioning: at
  startup the process does not come up; at runtime the rewriting elephant makes a **process-stop request** — a
  reserved `taskIdx` message into the init ring, main's park widened from signalfd (`src/main.zig:176-188`) to
  signalfd **and** init-ring CQEs, on which main runs the existing graceful `shutdown()` (`:261-306`), fronts and
  elephants included, with the faulting elephant's log entry as the operator's breadcrumb. With rewrite-always there
  is no torn append that could produce the corruption; an invalid line means the file was corrupted some other way.
- **A failed rewrite at any step is an ordinary failure rung** (§8, rung 6): the old file stands whole, the line never
  lands, the procedure aborts. No truncation rung exists — there is nothing to truncate back.
- **Precedence:** for each hosted pair, the **last** line with that `host_idx` is the pair's committed snapshot; lines
  naming hosts the thread no longer hosts are inert.

## 3. The procedure, end to end

### 3.1 Dispatch: create the new WAL file

The tick pass ends by dispatching: cursor pick 1; a message slot from the ordinary `cross_slots` pool — `acquire()`,
write `{ job }` (well under the 16-byte cap, `src/cross_task.zig:67`), `MSG_RING` the slot id into the elephant's
ring; receiver-released on read, exactly as today (`src/elephant.zig:29-32`). A refused push lands in the pending op
(§4) — never a spin inside the pass.

The elephant creates `wal.<host>.<index>.<X>` under its **final** name, `O_CREAT | O_TRUNC`, then one `fdatasync`
before the reply. The truncate is load-bearing: a same-tag retry (the pair's state may not have advanced after a
failed procedure) reopens a file that may hold the failed attempt's flushed prefix, and a stale flushed prefix would
survive the plain-mode walk as if it were content; truncating and syncing the empty length kills it, and an
unreferenced file is retention's anyway. The elephant replies the fd **alone** (`{ fd }` — `{ job, fd }` measures 24
bytes and breaks the cap; the reply rides the elephant→index direction on the requesting thread's own ring, and the
one-procedure-per-index invariant makes the context unambiguous).

The fd is the only thing that crosses threads; the elephant never touches the battery or the live state
(`designs/wal-impl.md:56`, landed in `src/lifetime.zig:369-371`, `:252-253`). The split of the requested constructor
across the two actors: elephant-side, create under the final name with the truncate and the `fdatasync`;
index-thread-side, the adopt of §3.2.

### 3.2 The handler pass: mark, clone, adopt, composite, re-dispatch

One synchronous pass on the index thread; no front message is processed inside it, so nothing slips between its
steps:

1. **Mark.** With the create reply in hand, barrier-rewrite the pair area's control line with
   `snapshot_in_progress = 1`, `new_wal_buffer_idx = k`, `target_state = X` (the `persistHeader` idiom,
   `src/wal.zig:925-931`; a plain store in plain mode). Publishing at the earliest point — after the create reply,
   before the composite serves — widens the guarded window: every crash from here to the swap lands in one of the two
   restart branches (§3.5), including clone and adopt failures, which is why the unwinds clear the mark.
2. **Clone.** The chosen pair — any hosted pair, own or mirror — is deep-copied into the job's arena
   (`cloneIndexState`, `src/lifetime.zig:969`). Its state is `Y`, at or ahead of the tag `X`: the pair kept serving;
   there is no pin. An allocation failure unwinds (rung 3).
3. **Adopt.** Mint ring `k` (§2.2), open the writer over the transferred fd on ring `k`, publish the ordinal-0
   terminator with `last_state = Y`, set the writer's head to `Y`, attach to the thread's stream window. The old
   writer is **not** closed — the landed close-first contract (`src/lifetime.zig:444-448`, asserted at `:2038-2098`)
   is reshaped: `walAdoptWrite` becomes adopt-without-close, and the old writer's close moves to the final-close
   elephant (§3.4). The temp ring dissolves the structural objection the close-first order leaned on ("two writers
   would share the pair's one ring and collide") — they no longer share one. The `WalOpen` one-writer-per-pair guard
   holds outside a procedure and yields to the procedure's second writer for the window's duration.
4. **Composite.** The pair's write interface becomes the composite: every event is written **new first, then old** —
   the order is load-bearing, because the new WAL is the committed future and the old one is the pre-commit
   fallback; if the old side refuses, the event is already in the new file. Each writer chains independently
   (`floor == head` per side, `src/wal.zig:955`) and both heads sit at `Y`, so the first event is `Y+1` on both
   sides; the old file stays a complete history, the new file accumulates the post-clone tail. Completion is §5's
   rule. A new-side flush fault is the ordinary terminal stop (`src/wal.zig:1196-1223`, `src/index.zig:127-136`); an
   old-side refusal freezes the front (§5).
5. **Re-dispatch.** Cursor pick 2, `{ job }`; a refused push lands in the pending op and the pass ends — no spinning
   inside the pass, the window keeps serving.

### 3.3 The dump elephant

Synchronous, elephant-shaped work, the SDK discipline verbatim (`sdks/state-snapshot.md` §3.3-§3.5):
`dumpIndexState` over the clone (`src/lifetime.zig:842`), write `snapshot.<host>.<index>.<X>` under its final name —
no temporary names, no renames — one `fdatasync` as the only snapshot-side barrier, then the single
`arena.reset(.free_all)` and job-shell destroy. The elephant sees only the clone; it never dereferences the live
state.

On success the registry rewrite runs (§2.4) — the `fdatasync` precedes the completion message — and the elephant
replies completion, spin-retrying a refused push (`src/elephant.zig:67-75`). On failure it replies failure. An
unparseable line met at the rewrite's read is the stop-request (§2.4) — before any abandon.

### 3.4 Completion: the swap and the final close

One synchronous pass on the index thread, on the completion message:

- **The bounded drain.** The copy needs both writers' in-flight flushes landed first: a late `flushComplete` would
  publish a terminator into the pair area after the copy clobbered it (`src/wal.zig:1169-1189`), and a new-side DMA
  still reading ring `k` must be done before `release(k)` is safe from any later acquirer. At most one flush is ever
  in flight per writer (`src/wal.zig:602-603`), so the wait is bounded — but it cannot be `close`'s `awaitFlush`,
  which retires and **drops** foreign completions (`src/wal.zig:1238-1253`): mid-service that would strand another
  pair's writer with `flush_in_flight` stuck. The drain steps every CQE through the thread's ordinary dispatch (the
  `src/index.zig:106-157` arms) until both writers are quiet; control-plane messages that land during it are handled
  by the loop pass that follows.
- **The copy.** The barriered `@memcpy` of ring `k`'s data and header arrays — only those; the copy never crosses a
  control line — into the pair area.
- **The clear.** The barrier-rewrite of the control line with `snapshot_in_progress = 0`.
- **Revival, if frozen** (§5): the front-denial rule becomes "any **live** writer's fault denies the front", the old
  writer is retired from that set, and the frozen window's events were written new-first — the front reopens; a
  relapse re-freezes terminally.
- **The final close.** Cursor pick 3; `{ job }` to the final-close elephant: `close(2)` the old fd **best effort** —
  warn on failure, keep working — then `snapshot_slots.release(k)`, then the terminal `SnapshotDone` reply, on which
  the index's in-flight flag clears. Close is hygiene, not durability: both modes are deliberately buffered
  (`wal-impl` rejects `O_DIRECT` outright, `designs/wal-impl.md:73`), and in PMEM mode each flush is already an
  explicit completed `pwrite` with `RWF.DSYNC` (`src/wal.zig:531-538`), so `close(2)` manages only the OS file
  object's lifetime.

The old WAL is now an unregistered orphan — retention's, never recovery's. The temp ring's contents are dead but
harmless until some later procedure mints ring `k` again.

### 3.5 Restart: the adoption rule, run per hosted pair

**Two branches, run per hosted pair, before any open of the pair.** Startup finds the mark by scanning the hosted
pairs' control lines. Read the control line. `snapshot_in_progress == 0`: the pair is ordinary. Otherwise the winning
registry line decides:

- The current pair **bears `target_state`** — the winning line names the migrating pair — the adoption is needed:
  re-copy ring `k` into the pair area (idempotent; the source is intact until the slot is reused), clear the line.
- The current pair **references another state** — the previous pair won — the migration aborted: clear the line,
  reclaim ring `k`, then check the abandoned pair for a surplus record and bring it home (§3.6).

`new_wal_buffer_idx` is the only pointer anyone needs: the mark itself carries `k` and `X` on the pair's own area;
the temp ring needs no identity tuple of its own. Plain mode's battery is DRAM (`src/config.zig:89-90`): the mark,
the torn mix and the un-flushed tails die with the process, the branches never fire, and the registry line alone
decides — which §3.6 shows loses nothing durable.

**The crash table** (every crash point from create to post-swap):

| crash at            | pair area | fixed file | mark    | restart                                                |
| ------------------- | --------- | ---------- | ------- | ------------------------------------------------------ |
| create reply → mark | old chain | old line   | 0       | the old pair, exactly as today                          |
| mark → line commit  | old chain | old line   | 1, k, X | abort: clear, reclaim, check the abandoned pair (§3.6)   |
| line commit → copy  | old chain | new line   | 1, k, X | adoption: re-copy ring `k`, clear                        |
| mid-copy            | torn mix  | new line   | 1, k, X | adoption: re-copy (idempotent), clear                    |
| copy → mark clear   | new chain | new line   | 1, k, X | adoption: re-copy (no-op data), clear                    |
| post-swap           | new chain | new line   | 0       | the new pair                                            |

Copy-start implies line-committed by construction — the elephant's `fdatasync` precedes the completion message, which
precedes the swap — so a torn pair area always exists after the new line and is always finished forward, never read
as the old pair.

### 3.6 The bring-tail: the abort branch's second act

**Scope: PMEM only.** In plain mode the mark dies with the battery, so the branch cannot fire — and under the
completion rule (§5) there is nothing durable to repair there anyway.

- **The check** reads the abandoned pair the way recovery reads any pair — the new file's flushed bytes merged with a
  ring chain by ordinal (the `beginRead` extent shape, `src/wal.zig:1670-1679`) — except the ring is temp ring `k`
  the mark names, walked directly. Deliver every record at or past the old pair's walked head (`seek_then_read`,
  `src/wal.zig:1303`, the read path's own floor filter). Normally the delivery is empty. The only possible gap is the
  inter-write cut: the composite writes new-first-then-old as two synchronous battery writes, so a power cut between
  them leaves exactly **one** record new-side but not old-side; everything earlier reached both rings, and everything
  the old ring holds is recovered by its own walk.
- **The bring:** flush the old writer's un-flushed tail first — the startup-opened writer drives its filled buffers
  into the file, emptying the chain — then append the delivered record through the ordinary write path, then flush.
- **Room is guaranteed twice over.** Structurally: the record once fit ring `k`'s ordinary path — which keeps a buffer
  free (`src/wal.zig:974-975`) and may carry an un-flushed tail — so it fits the same-sized old ring emptied by the
  flush, a fortiori. And by two constraints, which make the room local and obvious: one record must not exceed `lba`
  (§6), and a file's ring holds at least 4 buffers (§6) — the mandatory 4 CRC bytes per 1 MiB block are honored and
  the buffers are not squeezed to the last drop.

## 4. The message, slot and pending discipline

- **The 16-byte cap is a hard comptime assert** (`src/cross_task.zig:67`), and every shape honors it: `{ job: usize }`
  measures 16 and fits; `{ job: usize, fd: i32 }` measures 24 and breaks the assert. So the fd reply carries the fd
  alone, and every other reply carries the job or a status alone — the one-procedure-per-index invariant makes the
  context unambiguous (the reply arrives on the requesting thread's own ring, and that thread has at most one live
  procedure). Requests (`SnapshotCreate`, `SnapshotDump`, `SnapshotCleanup`, `SnapshotClose`) carry `{ job }`. Exact
  variant naming is the staged plan's.
- **Every release is an elephant's.** Success: the final-close elephant closes the old fd best effort and releases.
  Every failure rung: the cleanup elephant unlinks the procedure's files (best effort — `ENOENT` is fine; the
  create-failure rung has no file), closes any transferred fd, releases. The index thread never calls `release`; it
  only acquires and sets statuses.
- **The last word needs a hearing.** The final-close and cleanup elephants reply one terminal `SnapshotDone` message,
  and the index thread's in-flight flag clears on it — the one-operation invariant is enforced to the true end of
  the procedure, not to its last dispatch. The reply rides the elephant's spin-retry idiom (`src/elephant.zig:67-75`);
  the job carries the requesting ring's identity so the reply lands on the right thread's ring.
- **The pending op.** A failed index→elephant push never drops (the codebase rule for ring pushes) and never spins —
  the index thread serves pairs; a spin stalls the whole thread, which is why the dedicated threads can spin
  (`src/elephant.zig:71-73`, `src/index_inbox.zig:248-262`) and the index cannot. The push's slot is acquired and its
  payload written once; what refuses is the `MSG_RING`. So the pending op holds the acquired slot id and the target
  ring, and the loop retries the `MSG_RING` once per batch pass (a pass = one drained batch, ≤64 CQEs + ≤64 inbox
  tasks, `src/index_inbox.zig:324-336`) until it lands. One pending op per thread suffices — one procedure per
  index, and a procedure's pushes are sequential. It lives in the index loop's frame beside `faulted`
  (`src/index.zig:97`); no per-thread state struct exists today, and the author's split puts loop wiring in
  `index.zig`.
- **The `CrossTaskMessageIdx` arm must exist in the index drain.** Today such a CQE falls into `else` and is dropped
  with its slot never released (`src/index.zig:118-122`) — a leak. Implementing the arm (dispatching by payload
  variant) is part of this design; it is also the elephant→index direction's first real use: the fd reply, the
  abandon message, the completion and the terminal reply all ride it.

## 5. The composite's completion, reply, freeze and revival

**The front never replies; it dispatches; replies are made by indexes.** The landed shape already says so: the front
routes an accepted connection into its index's inbox and never sees it again (`routeAccepted`,
`src/front.zig:251-261`), and "the index becomes the only owner of `fd` from that point on" (`src/index.zig:20-24`);
the flush CQEs die inside the index's own drain (`.wal_flush`, `src/index.zig:127-137` — reclaim the buffer, advance
the writer's queue, nothing else).

The rule, normatively:

- An event written through the composite is **complete** — durable, replyable — only when **both** sides' flushes have
  completed. The index thread sends the client's reply, when one exists, only then. Outside a window, the single
  writer's flush completing is the event's completion — the landed durability contract, unchanged.
- **Why both sides:** either single-side rule loses durable events in one of the two outcomes. Old-side-only
  completion would let a durable event be missing from the new file at the swap — plain mode's battery dies with the
  process, so the un-flushed new-side bytes are gone. New-side-only would let one be missing from the old file at an
  abort — plain mode again. Both-sides completion makes durable ⊆ both files, always, which is exactly what the crash
  table (§3.5) and the repair scope (§3.6) assume.
- **Consequences.** A plain-mode aborted migration loses nothing durable, and the bring-tail is PMEM-only — it
  preserves the published-tail property (`CLWB`+`SFENCE`, `src/wal.zig:925-931`), not durability itself. The
  durability contract is unchanged: a record is durable when its flush completes; the overlay adds no barrier and
  removes none.
- The tracking — pairing an event with both sides' flush completions during a window — is staged-plan material. The
  front/consensus material must honor the rule when its delivery channel lands.

**Freeze and revival** (the old side's refusal set): during the window, an old-side flush fault freezes the front
exactly as the landed `faulted` machinery does, and **`WalFull`** freezes too — for the composite, the oversized old
file hitting capacity is exactly the "cannot serve into the fallback" case; the freeze is brief because the swap is
what retires the old file. Pure submission backpressure stays park-and-retry, a non-trigger. The stop is
thread-level: one faulted writer denies the thread's whole front intake, whichever data set the fault came from
(`src/index.zig:127-136`, `src/wal.zig:1196-1223`) — all of a thread's WALs share one directory and device, so one
`EIO` is a suspicion against all of them — while the control plane (reserved `taskIdx` traffic and cross-task slots)
keeps flowing so shutdown choreography completes. The terminal fault is `WalFaulted`; `WalFull` and `RecordTooLarge`
are protocol answers, not triggers. A fault on the **new** side is the ordinary terminal stop — no revival. Revival,
at the swap: the old writer is retired and gone, the surviving writer is healthy, the frozen window's events were
written new-first and the registry line is committed — the front reopens; a relapse re-freezes terminally. A failed
procedure while frozen leaves the stop standing: no swap is coming. Only the front advances a thread's pairs today,
so the frozen thread's state is genuinely quiescent; the consensus design must preserve that — its delivery channel
is control-plane-shaped and must respect the freeze, and must honor the completion rule.

## 6. The record-size contract and the config floors

- **The producer contract:** a record handed to an index thread's write path must not exceed the pair's `lba` (`lba`
  is the buffer size and the flush granularity, a power of two in `[512, 1 MiB]` dividing 1 MiB exactly,
  `src/config.zig:86-87`, `:554`). The enforcement is **on the index side**: the index thread decides whether
  dispatched data is too large and may reply the client with proper diagnostics. The check sits at the index thread's
  intake, where every dispatched event passes, window or not — today the front's dispatch, and whatever channel the
  consensus material lands will land there too — so it covers every event that can become the bring-tail's surplus
  (§3.6). The refusal is a protocol answer with a client-facing diagnostic — not a fault, not a freeze trigger; the
  wire shape is the consensus design's.
- **The WAL's structural cap is unchanged:** `framed > BLOCK_CONTENT` → `RecordTooLarge` (`src/wal.zig:961`), the 1
  MiB block (`src/wal.zig:26-33`). Records stay structurally legal spanning `lba`-sized buffers; the WAL module and
  its spanning tests are untouched.
- **The buffer floor moves:** a file's ring holds **at least 4 buffers** — the validation floor at `src/config.zig:557`
  moves from today's 2, the doc line (`:389`) moving with it. Four keeps a current buffer, a free buffer, and room
  for the bring-tail's flush-then-append (§3.6).
- Config also validates the snapshot pool's `N ≤ 65535`, beside `new_wal_buffer_idx: u16`.

## 7. The recovery contract

### 7.1 Sequencing

At startup an index thread, per hosted pair, in order:

1. Run the adoption rule of §3.5 — before any open of the pair.
2. Read the registry: the **last** line with that `host_idx` wins, naming the snapshot and the WAL. An invalid line
   is fatal (§2.4).
3. Load the snapshot (`loadIndexState`, `src/lifetime.zig:890`; version 1, `src/state.zig:19`).
4. Open the writer (`walOpenWrite`, `src/lifetime.zig:394` — the walk supersedes its head) and set `st.state` from
   the **walked head**, never from a name:
   - **PMEM mode:** the walked head — the persisted ordinal-0 terminator's `last_state`. The registry line's
     `"state"` key is redundant and ignored.
   - **Plain mode:** `st.state = head = max(walked head, the line's "state" key)` — the empty-file walk returns
     `head == tag` and publishes the terminator itself (`walkPlain`, `src/wal.zig:779-782`), so an empty new file
     under a tag `X < Y` walks to `X` and is corrected to `Y`; a non-empty file walks past `Y` and the key is inert.
5. `attachStream`; replay via `walOpenRead` with `seek_then_read(st.state)` (`src/wal.zig:1299-1304`).

The full startup choreography stays with the startup material; this design pins the registry's contract and this
hand-off.

### 7.2 What plain mode loses

Plain mode's close does not flush the live tail (the end-to-end contract, `src/index.zig:271-276`: a record is
durable once its buffer's flush completes, and only filled buffers are flushed), and its battery dies with the
process — the un-flushed tail is lost by contract. The completion rule (§5) is what makes that loss harmless:
durable events live in both files, so whichever pair wins, every durable event is recovered by its own walk.

### 7.3 The registry lost: a tool, not an automatic

When the registry is absent or unreadable, startup does **not** scan. Recovery from a lost registry is a toolchain
QoL command — a maintenance tool (`docs/todo.md` keeps the sketch) that scans an index directory, groups `snapshot.*`
and `wal.*` by equal tag, orders them within the `(host_idx, index_idx)` pair by `state_idx`, and emits the last `N`
complete pairs as JSONL for the engineer. The design's obligation is the property the tool consumes: equal tags pair a
snapshot with its WAL, uniquely among live files (§2.3). Notably the tool can adopt a procedure whose dump and
`fdatasync` succeeded but whose registry rewrite failed — that pair is complete on disk and recovery-correct, so
adopting it loses less than falling back.

## 8. The failure ladder

Every phase, what can fail, who unwinds, and how the thread ends up. Crash (power-cut) cases are not listed per step —
they are §3.5's table, uniformly.

0. **`snapshot_slots.acquire()` fails.** Not a failure: the tick ends. The limit is the design working.
1. **The create dispatch push is refused.** The pending op holds it; the thread keeps serving.
2. **The create fails.** The elephant replies failure. **Unwind A, markless** (the handler pass never ran): status
   `rollback`, dispatch the cleanup task — via the pending op if refused.
3. **The clone cannot be allocated.** **Unwind A**: clear the mark, status `rollback`, dispatch cleanup. Ring `k`
   holds at most a minted header array, referenced by nothing. A quiet unwind with a log line, not the process-fatal
   idiom — the tick retries on its own schedule.
4. **The adopt cannot be allocated.** Memory-only, the clone's twin: **unwind A** (destroy the half-built writer
   object first).
5. **The dump fails.** The elephant replies failure after the arena reset. **Unwind B**.
6. **The registry rewrite fails at any step** (read, filter, write, `fdatasync`, rename). The elephant sends the
   abandon message; **unwind B**. The old file stands whole; no truncation rung exists (there is no append that
   could tear). If the read itself met an unparseable line, that is the runtime fatality — the stop-request (§2.4) —
   before any abandon.
7. **A reply push is refused.** The elephant spin-retries (`src/elephant.zig:67-75`).
8. **The swap.** Memory only — the drain, the copy, the mark clear — and cannot fail; its crash cases are §3.5's
   table.
9. **The final close fails.** `close(2)` on the old fd: warn, keep working; release and reply `SnapshotDone`
   regardless. The procedure is done.
10. **The thread stops outside or during a window.** Ticks skip a stopped thread; the terminal-stop semantics
    (`src/wal.zig:1196-1223`) are unchanged. The procedure still completes on the control plane — the cleanup and
    final-close tasks are control-plane messages, and the pending op drains through the ordinary loop — with the
    revival rule of §5: an old-side freeze revives at the swap, a new-side fault and a failed-while-frozen leave the
    stop standing. End state: revived, or stopped until restart.

**Unwind A** (index thread, pre-composite): destroy the writer object if the adopt got that far (memory only), clear
the control line if the mark was published, set the slot's status to `rollback`, dispatch the cleanup task. End
state: serving on the old pair; a truncated orphan under a tag no line references — retention's.

**Unwind B** (index thread, composite installed): revert to the old single writer; run the bounded drain of §3.4
(both writers quiet, stepped through the thread's ordinary dispatch); close the new writer; clear the control line;
status `rollback`; dispatch the cleanup task. If the thread was frozen, the stop stands. End state: serving on the
old pair, or frozen until restart. The snapshot and new WAL files, if they got that far, are unreferenced junk — a
failed dump never gains a registry line.

**The cleanup elephant:** unlink the new WAL and the snapshot best effort, close any transferred fd,
`snapshot_slots.release(k)`, reply `SnapshotDone`.

## 9. Invariants

- At most one procedure per index thread, enforced to the terminal `SnapshotDone`; at most `N` process-wide (the
  slot pool); a tick that hits either bound is skipped, not queued.
- The slot `k` is occupied for the whole procedure, regardless of outcome; an elephant releases it on every path —
  the final-close elephant on success, the cleanup elephant on failure. The index thread never releases.
- The tag is minted at the first dispatch, fixed in the job, carried by both names; the snapshot content may run
  ahead of it; the chain anchor is the clone state `Y`, persisted in the new WAL's ordinal-0 terminator and in the
  registry line's `"state"` key for plain mode.
- `snapshot_in_progress == 0` on every control line outside a procedure; the mark's publish precedes the composite,
  hence every registry line; copy-start implies line-committed.
- The registry is rewritten whole on every change: read, keep the last `N` per hosted pair, add, pending file,
  `fdatasync`, rename. The last line per `host_idx` is the pair's committed snapshot; an invalid line is fatal at
  startup and at runtime — and no append exists that could tear one.
- The pairing property: `snapshot.h.i.X` pairs with `wal.h.i.X`; equal tags, unique among live files (a same-tag
  retry truncates its own orphan). The maintenance tool consumes it; startup does not.
- The composite writes new-first-then-old; an event is complete — durable, replyable — only when both sides' flushes
  have completed; the front never replies, the index thread does, and only for a complete event. The old side's
  refusals freeze the front, never the control plane; the new side's fault is the ordinary terminal stop.
- Records handed to an index thread must not exceed the pair's `lba`; the index enforces it at intake and refuses
  with client diagnostics. The WAL's structural cap (the 1 MiB block) is unchanged.
- A file's ring holds at least 4 buffers.
- A registry-visible file implies its ordinal-0 terminator was persisted (the publish moves to the adopt, still
  before the append).
- The elephant sees only the clone; the fd is the only thing that crosses threads; the battery is never touched by
  the elephant — the mint, the terminator and the control line are index-thread acts.
- The snapshot file is final-named, `fdatasync`'d once, and released with one arena reset before the reply.
- The durability contract is unchanged: a record is durable when its flush completes; the overlay adds no barrier
  and removes none.

## 10. What stays out of scope

- The staged implementation plan and its split into stages (a dedicated later step; the `wal-impl` → `wal-steps`
  precedent).
- The consensus driver: what is written and when, how mirror data sets receive their events, the refusal and
  diagnostic wire shapes. Its delivery channel must respect the freeze and the completion rule (§5), and its writes
  must enter through the index thread's intake (§6).
- Retention and orphan cleanup (when `delete` is called), and the post-restart epoch bump's sequencing (`wal-impl`
  §10 handed them over; this design only guarantees orphans are never registry-referenced).
- The network transport, `pmem-migrate` (`docs/todo.md`), log rotation (`designs/LOG_ROTATION.md`).
- The registry-lost recovery command is a toolchain QoL item (§7.3), not a startup automatic.

## 11. Supersessions and amendments of the landed material

- `sdks/state-snapshot.md` §3.6 — the registry's actor (the elephant, not the index thread), format (JSONL with
  `host_idx`/`snapshot_path`/`wal_path`/`state`), and ordering (the rewrite before the completion message) —
  superseded. Its §5 "set `st.state` from the file-name tag" — superseded by the walked-head rule (§7.1); the tag's
  mint-continuity duty moves to the ordinal-0 terminator and the `"state"` key. Its §1 and §6 rule 5 ("the own data
  set only") — superseded: any hosted pair is a snapshot subject.
- `designs/INDEX-STATE.md` §12's own-scope bullet ("the clone covers the own data set only; mirror data sets are
  never cloned by this path") — superseded; the bullet gains a one-line amendment pointing here.
- `designs/wal-impl.md` §2 — amended: `BufferHeader` gains `snapshot_in_progress: u8` @20 and `new_wal_buffer_idx:
  u16` @22 in the `_pad_align` word and `target_state: u128 align(8)` @40 in `_pad_tail`, fitting the pinned 64-byte
  line without growth; the area stride grows one 64-byte control line after the header array; the battery gains the
  `N`-ring temp section.
- `designs/wal-impl.md` §3 — **not** amended: the record cap stays at the 1 MiB block; the `lba` bound is a producer
  contract enforced at the index thread (§6).
- The close-first adoption contract (`designs/wal-impl.md` §3.4, landed at `src/lifetime.zig:444-448` with its tests
  at `:2038-2098`) — reshaped: `walAdoptWrite` becomes the adopt without the close (mint, open over the fd, terminator
  with `last_state = Y`, head `Y`), the old writer's close moves to the final-close elephant, and the landed tests
  asserting `last_state == tag` (`src/lifetime.zig:2081`, `:2097`) reshape with the seam. The structural objection
  the close-first order leaned on ("two writers would share the pair's one ring and collide") is dissolved by the
  temp ring.
- `docs/SNAPSHOTS.md` — superseded wherever it differs from this document; the file is left untouched as the source.
