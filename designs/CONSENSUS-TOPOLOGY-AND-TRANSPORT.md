# Consensus topology and transport

This document is the prelude to the consensus documentation. It fixes the index-to-index topology, the link lifecycle
and the transport framing stub that the consensus driver sits on, so that the consensus document can describe decisions
without re-describing sockets, framing and catch-up requests. It does not define the consensus algorithm, the payload
codecs, the contents of a catch-up transfer or the WAL and state-machine semantics the operations mutate.

The document is normative. Where a code identifier is named, it is the identifier the implementation uses.

## 1. Terminology

| document term        | code fact                                                                                                                          |
| -------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `index_count`        | `cfg.indexes`, the number of index threads **per host**; each index owns one inbox and one ring                                    |
| `replication_factor` | `cfg.wal.hosts()`, `1..=256`, bounded by the `host_idx: u8` of the WAL API (`src/config.zig:175-181`, `:634-635`)                  |
| `host_idx`           | `cfg.host_index`, validated `< hosts`; the only host identity the process has                                                      |
| index number         | `role.index.inbox_idx`, identical to `frame.index_idx` (`src/index.zig:50-51`, `:139`), `0..index_count-1`                         |
| `state`              | `state.IndexState.state` (`src/state.zig:155-163`), a `u128` laid out as `(host_id: u8, index_id: u16, epoch_id: u40, index: u64)` |

The `state` value is not an opaque counter. It is the packed state value the WAL and state design already define, and
`start_state_idx` in the commit envelope is the same type. The consensus driver is its only writer
(`src/state.zig:163`); the transport carries it opaquely.

## 2. Topology

For index thread `i` on host `h`:

- it **dials** every host `j` with `j > h` and owns the resulting socket. The dial is a `pushConnectIp4` on the index's
  own ring, issued from the index's `run` loop (`src/index.zig:73-181`); no front is involved.
- it **accepts** nothing directly. A connection from host `j < h` arrives at the process peer listener, is accepted by
  whichever front wins the listener's multishot, and is handed to index `i` by the slot path of §3.2.
- it never talks to `host_idx == cfg.host_index`: there is no self-link. With `hosts == 1` the transport is dark: the
  `cluster` block is absent, no peer listener is created, and no link is ever installed. With `hosts > 1` the block is
  required.

A link is per `(index thread, peer host)` and is never multiplexed across index numbers. The same index number on both
hosts is the pair, because the WAL battery is indexed by `(host_idx, index_idx)` and the replication group of index `i`
is index `i` on every host. The frame therefore carries no index field, and the receive path needs no demux: the link
table slot it runs in already names the pair.

One socket serves both directions of the pair, and the higher host answers on the same socket. There is no separate
reply socket. The socket count is `index_count * (replication_factor - 1)` per process.

The peer listener is process-wide, created by the process thread, and shared by every front exactly like the client
listener (`src/main.zig:170-173`, `src/lifetime.zig:1191-1219`). It binds `cfg.bind:cluster.peer_port` and exists only
when `hosts > 1`. Each front arms a second multishot accept on it; several rings accepting on one listening socket is
the shape the client path already uses. The descriptor reaches the fronts before `START_WORK` through the slot
vocabulary, because `res` in the broadcast already carries the client descriptor (`src/main.zig:298-314`).

Link storage is allocated lazily, on promotion. Nothing is allocated before a link exists. The memory cost of a promoted
link, with the defaults, is:

| scope     | receive reorder buffer    | send ring                             |
| --------- | ------------------------- | ------------------------------------- |
| each way  | `2 * 16 * 4096` = 128 KiB | `8 * 4096` = 32 KiB                   |
| both ways |                           | 320 KiB per link plus the link tables |

The reorder buffer's backing is `2 * window` slots of `max_item` bytes (§4.4). The operator can size the process from
`indexes * (hosts - 1)` sockets.

## 3. Link establishment and hand-over

The handshake order is fixed:

1. after the connect CQE, the dialer sends exactly the 5-byte greet and nothing else;
2. the front reads exactly 5 bytes with a deadline, validates the greet, and either writes a reject reply itself and
   closes, or hands the socket to index `index_idx`;
3. the hand-over is a `CrossTaskSlots` slot holding a `CrossTask.PeerLink` plus a `MSG_RING` into the target index's
   ring, never an index-inbox message;
4. the owning index re-validates what it was told, checks for an existing link, and answers accept or reject in one
   7-byte reply;
5. the dialer reads exactly 7 bytes, validates the reply and the verdict, and only then starts framing. The index starts
   framing only after its reply's send CQE.

### 3.1 The greet (dialer)

The greet is exactly five bytes, little endian and packed:

| `version: u16` | `host_idx: u8` | `index_idx: u16` |
| -------------- | -------------- | ---------------- |

`version` is a compile-time constant of `src/cluster_transport.zig`, bumped on any incompatible change. `host_idx` and
`index_idx` are the dialer's own. The dialer sends nothing else until it has read the acceptor's reply: not a frame, not
another byte.

The greet is not a frame. It carries no `seq_id`, does not go through the reorder buffer, and is not subject to the
frame layout. Its fixed five bytes are a v1 property; `version` is its first field so an incompatible peer is detected
before any frame is parsed. A failed connect is a retry (§3.6), not a fatality.

### 3.2 Front intake

The front that accepted a peer socket owns it only until the hand-over:

1. The peer accept CQE carries the descriptor in `res`. The front takes a handshake entry, records the fd, and arms a
   one-shot receive for exactly the five greet bytes with `cluster.handshake_timeout` (default 5 s). The table holds at
   most `cluster.handshake_slots` entries (default 64) per front; an accept that finds no entry closes the fd with a
   warn, like the client inbox-full path (`src/front.zig:251-266`). The entry owns the five-byte request buffer and a
   seven-byte reply buffer, so no kernel write targets a loop frame. Partial reads re-arm for the remainder; EOF, a
   short read at the deadline, or an error closes the fd and releases the entry.
2. On five bytes the front checks `version` first, because a foreign version makes the rest of the greet's layout
   unknown. The checks are ordered and each one either rejects or continues:
   - `version != local`: write the 7-byte reply `(local version, local host_idx, 0xFFFF, version_mismatch)` and close
     after that send's CQE;
   - `host_idx >= hosts` or `host_idx == cfg.host_index`: the same reply with `invalid_host`;
   - `index_idx >= cfg.indexes`: the same reply with `unknown_index`, because there is no target ring;
   - otherwise call `std.posix.getpeername`, compute `source_ok` (true only when the four address bytes match the parsed
     `cluster.peers[host_idx]`), and route.

   A reject is logged at warn and closes the connection. It is never a process failure. These three are the only replies
   the front writes, and it writes them only on a connection it will close instead of handing over. The `0xFFFF` index
   is a sentinel: the front has no target index to name.

3. The front acquires a `cross_task_slots` slot, writes `CrossTask.PeerLink`, and posts `MSG_RING` with
   `taskIdx = messages.CrossTaskMessageIdx` and `res = slot_idx` to `ctrl.rings[cfg.fronts + index_idx].ring.fd`, the
   exact shape of `snapshot.dispatch` (`src/snapshot.zig:360-386`). The target ring is the global index number plus
   `cfg.fronts` (`roleOf`, `src/lifetime.zig:1134-1160`), so the hand-over needs no `index_per_front` arithmetic. On
   `error.RingFull` or `error.CrossTaskFull` the entry keeps its payload and retries the post once per loop pass, never
   spinning the accept path (`src/snapshot.zig:390-406`). At most one refused post is pending per entry.
4. The successful post is the ownership transfer: the front never reads, writes, closes or polls that fd again. A
   refused post keeps the fd and the slot in the entry until it lands. A shutdown closes the fd before posting, so a
   closed fd is never handed over.

The `PeerLink` payload is `{ fd: posix.fd_t, host_idx: u8, index_idx: u16, version: u16, source_ok: bool }`, 12 bytes,
so the union stays at 16 (`src/cross_task.zig:118`). The four-byte peer address does not fit; the front reduces it to
`source_ok` and the index logs a mismatch.

`FrontMessage` (`src/index.zig:21-36`) gains nothing, so the index inbox stays single-producer and carries only client
work. The index's `CrossTaskMessageIdx` arm (`src/index.zig:246-258`) keeps the stream-window `resync` that a direct
`MSG_RING` into the ring requires, and then switches on the payload tag: snapshot replies go to `snap.onReply`,
`PeerLink` goes to the link intake. A peer slot misrouted to the snapshot handler would be read as a snapshot reply and
its fd leaked.

### 3.3 Index intake and the greeting (acceptor)

The owning index re-validates `version`, `host_idx < hosts`, `host_idx != own`, `source_ok`, and that `index_idx` is its
own number (true by construction). Then:

- **No link for that host.** The link entry moves to `greeting`; the index writes one 7-byte reply
  `(its version, its host_idx, its index_idx, verdict)` and, on that send's CQE, the link becomes `up`, the reorder
  buffer starts at absolute zero, and the receive is armed.
- **A link already exists for that host.** The candidate is parked without a receive arm and the predicate of §3.4
  decides.
- **Any check fails.** The index writes the 7-byte reply with the failing verdict and closes after its CQE. The codes it
  can emit here are `version_mismatch`, `invalid_host`, `peer_address_mismatch`, `unknown_index` and `internal_error` (a
  local failure it cannot recover from).

The index is the only writer of the greeting. No frame is submitted until the greeting's send CQE lands, because a frame
submitted earlier could be transmitted first and corrupt the dialer's fixed-length read. The greeting's buffer lives in
the link entry, so the CQE never races a freed buffer; a close after a rejection is deferred to the verdict's send CQE
for the same reason.

A greeting arriving at an index that is already draining is closed at once with the shape of the client refusal
(`src/index.zig:176-188`): the index closes the fd and releases the slot. No verdict is sent; the peer sees EOF.
`not_accepting` is defined but emitted nowhere in v1. The dialer logs that EOF as `not_accepting`.

### 3.4 Duplicate links: the switch predicate

When a greeted candidate finds an existing link for its `(host_idx, index_idx)`, the index trusts neither side and
probes the established link:

1. A `Slots` context holds the host, the candidate's fd, its version, its `source_ok` and a per-link `epoch: u32` bumped
   on every phase change, so a late completion is attributable and ignorable. The timeout is a `TaskCtx` timeout
   carrying `{ host_idx, epoch }`; a stale timeout and a pulse completion that arrives after the timeout are both
   ignored.
2. A pulse frame goes into the existing link with `cluster.pulse_timeout` (default 1 s) around the acknowledgement
   (§4.8).
3. On an error, a missing acknowledgement or the timeout, the old link is dead: install the candidate (7-byte reply with
   `ok`, then `up`), retire the old link with a dedicated `pushClose` context, discard its reorder buffer and any
   partial frame, reset `seq_id` to zero for the new connection, and log the replacement at warn. Nothing is replayed
   frame by frame. Pending requests die with the old link; the transport exposes the link generation, and re-issuing is
   the consensus layer's job.
4. On a successful acknowledgement the candidate is suspicious: send the 7-byte reply with `host_index_squatting`, close
   after that CQE, log at warn, and keep the existing link untouched.

The candidate carries no traffic before promotion, and the dialer sends nothing after its greet until it reads the
reply, so a parked candidate needs no receive arm and "discard" is a plain close. The predicate never blocks the index
loop; only the candidate's promotion waits. The existing link keeps serving consensus traffic throughout.

### 3.5 The dialer's acceptance

The dialer reads exactly seven bytes with a deadline and re-arms partial reads. It then reads the verdict:

- `ok`: validate `version == local`, `host_idx == the host dialed` and `index_idx == its own`; a mismatch is treated as
  a rejection. On success install the link, create the reorder state at absolute zero, arm the receive, and log at info.
  No frame is sent before the reply is fully read.
- any other code: close, log at warn, and re-arm the retry timer with the backoff in force. A non-zero verdict does not
  validate the peer's identity, because a front-side reject carries the `0xFFFF` sentinel, so the log carries the code
  and the configured address, not a claimed identity.
- EOF, a short read at the deadline, or an error: the same as a non-zero verdict, with the cause logged.

### 3.6 Failure, death and retry

A link dies on: a negative or zero completion on its receive or on a send, a greeting timeout, a reorder violation
(`OutdatedFrame`, `FramesAreTooFarAway`), an over-cap or too-short `frame_len`, an unknown op code, a missed keepalive
acknowledgement, or a verdict that rejects it as a candidate.

Death tears the link down: a dedicated close context, a `reset()` of the reorder buffer, buffers returned. The lower
host arms a retry timer with exponential backoff from 100 ms to 5 s, reset on success, logged at warn, never fatal. The
bounds are constants, not configuration. The higher host never dials: it closes and waits for the lower host to redial,
because v1 has no goodbye op. A silent one-sided death on the higher host is detected by the keepalive (§4.8); without
it the link would stay dark until the lower host sent something.

### 3.7 Teardown

`shutdown_soft` keeps the links alive until the index has no sessions left, then closes every one of them with
`pushClose` before `reportDrained`. `shutdown_hard` closes them immediately. The drain reports are the ones at
`src/index.zig:207`, `:213` and `:227`; every one of the three paths closes the links first.

Before reporting, the index does one final full CQ drain to release any `PeerLink` slot that raced the shutdown and to
close its fd: a slot whose CQE arrived after the loop's last pass would otherwise never be released. A peer greeting
that arrives while the index is draining is closed at once (§3.3).

The front, on its own shutdown, stops posting hand-overs, cancels the peer accept arm and the in-flight handshake reads,
and closes their fds. A post that was already submitted is consumed by the index's final drain or, in the last race
before the index's exit, by `Controller.deinit`, which frees the pool after every thread has stopped.

The peer sees EOF, not a goodbye. The lower host redials if it is still running; the higher host's predicate replaces
the stale socket.

## 4. Transport framing

### 4.1 Frame layout

The frame's first 22 bytes are fixed, and the whole frame is at most 4096 bytes:

| `seq_id: u16` | `frame_len: u16` | `vector_clock_frame: (host_idx: u8, state: u128)` | `op_code: u8` | `op_payload: bytes` | `commit_envelope` |
| ------------- | ---------------- | ------------------------------------------------- | ------------- | ------------------- | ----------------- |

- All scalars are little endian and packed; the encoder appends field after field, so there is no alignment padding.
- `frame_len` is the frame's total size in bytes including the four-byte `seq_id` + `frame_len` prefix. It is
  back-patched at offset 2 after the body is written, because the encoder cannot know the size before it has written the
  variable tail. This is one store, not a size-computation pass.
- `op_payload` is a slice written through `blog.append`, so its own `uvarint` length precedes the bytes (`blog`
  `encoding.zig:153-239`). An empty payload is the single byte `0x00`. The length prefix stays even though `frame_len`
  exists: the envelope after the payload is variable, so its start is known only from the payload's own length.
- `commit_envelope` is `(no_of_decisions: uvarint, start_state_idx: u128, decisions: bitmap)`. Bit `i` is LSB-first
  inside a byte, `1` confirmed and `0` not confirmed. Zero decisions is the single byte `0x00`.
- The minimum frame is therefore 24 bytes: 4 prefix + 17 vector clock + 1 op + 1 empty payload + 1 empty envelope. A
  received `frame_len` below 24 or above 4096 is a link failure.
- The greet is not a frame. The 7-byte reply is not a frame either.

This document leaves to the transport-format document: the per-op payload codecs, the chunking of a logical transfer
that does not fit 4 KiB, the payload cap for each op, and any future frame field. A future field needs a version bump,
never an implicit extension.

### 4.2 Send path

The send context owns a 4096-byte buffer; its buffer waits for its CQE, and the operation context lives in `Slots`. The
encoder writes `seq_id` at offset 0, leaves offsets 2..4 for the length, writes the vector clock, the op code, the
payload and the envelope from offset 4, and stores `frame_len` at offset 2 from the final tail pointer.

If the tail exceeds 4096, the encoder returns `error.FrameTooLarge` before any SQE. In the stub this is a caller bug;
the format document will replace it with chunking. `seq_id` advances only after the SQE was submitted successfully, so a
local `error.RingFull` never leaves a hole. A link with all `cluster.inflight_frames` buffers busy returns
`error.Backpressure` to the control plane; only a negative CQE or a protocol error fails the link.

The in-flight bound is a fixed ring of 4096-byte buffers, not `blog.BufferPool`: `get` falls back to the heap when the
pool is empty, which defeats the bound.

### 4.3 Receive path

The receive path is a prefix reader plus a direct write into the reorder slot:

1. Each link has a four-byte header buffer and a `filled_hdr` count. Arm `pushRecv` for `4 - filled_hdr`; add `res` on
   each completion. A partial header re-arms for the rest; TCP guarantees the remainder is the next bytes on the stream.
2. On a full header, parse `seq_id` and `frame_len`, validate the length, and lift `seq_id` to an absolute index (§4.5).
   A length outside `24..=4096` is a protocol error and kills the link; no frame is delivered and no bytes are skipped.
3. `reserve(abs)` the reorder slot, copy the four-byte prefix into `slot[0..4]`, and arm `pushRecv` for `frame_len - 4`
   bytes into `slot[4..frame_len]`. Every subsequent short completion continues into `slot[filled..]`. The reservation
   pins the slot, so no other frame can reuse it; there is no assembly buffer and no extra copy of the body. When
   `filled == frame_len`, call `commit(abs, frame_len)`, reset `filled_hdr` and go to 1. The slot therefore holds the
   frame exactly as it was on the wire, and the parser never has to know that the prefix arrived first. At most one
   reservation is open per link.
4. The control plane drains synchronously in the same pass: `peekHeadCond(deliver)` + `dropHead`, or
   `popHeadCond(deliver)`, then `deliver += 1`. A frame the control plane cannot dispatch is peeked and retried on the
   next pass. A reorder violation (`OutdatedFrame`, `FramesAreTooFarAway`) or an unliftable ring number is a link
   failure, never a silent drop. A partial frame at the head is not deliverable, and the delivery cursor never sees it.
5. The receive is armed only while `pushed_absolute - delivered < window`, where `pushed_absolute` is the absolute index
   the next header is expected to lift to. When the window is full the link stops arming, TCP backpressures the peer,
   and no frame is dropped. `FramesAreTooFarAway` therefore means a peer that ignored this backpressure (or a corrupted
   stream), not a slow local consumer.

On a link death or a connection replacement, `reset()` returns the buffer to absolute zero with no reservations and no
partial frame, and `filled_hdr` returns to zero.

The greeting's 5-byte and 7-byte reads are separate from this path: they are exact-length one-shot receives into the
handshake and link buffers, not frames.

### 4.4 The reorder buffer

`src/reorder_buffer.zig` is a copy of `zigring.ReorderBuffer` (`zigring` `iouring.zig:2229-2492`) with the fixed-item
`push` split into a reserve/commit API, because the original `push` cannot take a frame in pieces. `zigring` remains the
dependency for everything else; nothing else is vendored.

What is preserved exactly:

- `init(allocator, size, max_item)` requires `size` a power of two no larger than `0xFFFF`, and allocates `2 * size`
  slots of `max_item` bytes plus the two link arrays;
- an absolute `u64` `wave` starting at zero, `idx < wave` rejected as `OutdatedFrame`, `idx - wave >= size` rejected as
  `FramesAreTooFarAway`, and the wave advances across every consecutive committed item;
- delivery is the caller's cursor (`popHeadCond`, or `peekHeadCond` + `dropHead`); `wave` is not a delivery cursor and
  is never passed to `popHeadCond`.

What changes:

- `reserve(idx: u64) ![]u8` returns the slot's `max_item`-byte view without linking it or advancing the wave, and pins
  the slot until `commit`, `abandon` or `reset`; it applies the same two index checks;
- `commit(idx: u64, len: usize)` links the reserved slot, records `len` in a per-slot `u16` (the frame cap fits) and
  advances the wave;
- `abandon(idx: u64)` frees a reservation whose frame never completed;
- `reset()` clears the wave, the list, the lengths and every reservation in one pass;
- `peekHeadCond` and `popHeadCond` return the committed length, not `max_item`;
- `push(idx, data)` is kept as reserve + memcpy + commit so the original zigring tests port over verbatim and prove the
  copy is not a regression.

The receive path reserves once per frame at the header; the reservation is what makes the direct write safe.

### 4.5 Sequence numbers, the window and the lift

- The sender keeps a `u64` counter per direction per connection, starting at zero, truncates it into the `u16` `seq_id`,
  and increments only after a successful SQE submit.
- The receiver keeps an absolute `u64` cursor `wave` and lifts `seq_id` to the unique absolute index in
  `[wave, wave + 0x10000)` congruent to the ring number. Since the window is a power of two no larger than `0xFFFF`, the
  lift is unambiguous at every wrap; an absolute at or beyond `wave + window` is rejected by `reserve`
  (`FramesAreTooFarAway`) and one below `wave` is `OutdatedFrame`.
- The window is `cluster.reorder_window`, default 16. It bounds both the reorder gap and, by gating the receive arm, the
  undelivered backlog; 16 leaves headroom over the per-link send budget of 8.
- The buffer is reset on a connection replacement: absolute zero, empty, no partial frame, no staged frame.

### 4.6 Encoder rules

All fixed-width fields are little endian and packed, `blog.append` handles scalars and slices, `blog.appendVarint` is
the ULEB128 form, and there is no checksum because TCP covers integrity. The encoder is append-shaped: a tail pointer
starts at the frame's first byte, each field advances it, and the tail pointer is the frame's used length. The protocol
version lives only in the greet and never in a frame.

Three consequences are worth pinning:

- **A `u128` is two `u64` appends.** `blog.append` asserts at most 64 bits and `appendVarint` narrows to `u64`;
  appending the low half then the high half is exactly the 16-byte little-endian form.
- **The bitmap is raw.** `blog.append` on a slice prefixes a length; `decisions` already carries its length in
  `no_of_decisions`, so it is a raw copy.
- **An empty envelope is one zero byte.** `no_of_decisions == 0` writes exactly `0x00` and nothing after it.

An unknown or out-of-range `op_code` closes the link rather than being skipped: a frame we cannot interpret means the
peer speaks another version.

### 4.7 Op codes and verdicts

The op-code number space:

| range        | use                                                              |
| ------------ | ---------------------------------------------------------------- |
| `0x00..0x0F` | link liveness: `0x00` `pulse`, `0x01` `pulse_ack`, rest reserved |
| `0x10..0x1F` | catch-up and snapshot family                                     |
| `0x20..0x7F` | consensus (the consensus document owns the meaning of each op)   |
| `0x80..0xFF` | unused; an op here closes the link                               |

Which consensus op is which, and what its payload is, is the consensus document's business. Snapshot and catch-up
transfers appear here only as a named family ("give me the data for host `h` from state `s`"); their payloads and
chunking are defined later.

The verdict is two bytes, the tail of the 7-byte reply:

| code | name                    | emitted by                                             |
| ---- | ----------------------- | ------------------------------------------------------ |
| 0    | `ok`                    | the owning index on acceptance                         |
| 1    | `host_index_squatting`  | the index when the pulse of the existing link succeeds |
| 2    | `internal_error`        | the index on a local failure it cannot recover         |
| 3    | `version_mismatch`      | the front (unroutable) and the index (defensive)       |
| 4    | `unknown_index`         | the front when `index_idx >= cfg.indexes`              |
| 5    | `not_accepting`         | defined; not emitted in v1 (a drain closes silently)   |
| 6    | `peer_address_mismatch` | the index when `source_ok` is false                    |
| 7    | `invalid_host`          | the front for `host_idx >= hosts` or `host_idx == own` |
| 8..  | reserved                |                                                        |

None of these is fatal to the process. The accepter logs at warn and closes; the dialer logs at warn and keeps retrying
with the backoff. A front-side reject is the same shape: warn, close, let the dialer's backoff run.

### 4.8 Pulse and keepalive

A pulse is a normal frame with the empty payload (`0x00`) and the empty envelope (`0x00`). It is handled on the
transport path and answered with `pulse_ack` without consensus ordering. Because the acknowledgement is a normal frame,
it proves the old link's reorder stream is advancing: a link blocked on a hole fails the probe by design, which is the
outcome the switch predicate wants.

The predicate's probe and the periodic keepalive share the opcode and differ only in which timer is armed. The
acknowledgement is not correlated with a specific pulse: it carries no token, and none is needed, because an
acknowledgement can be delivered only after our receive stream from that peer has advanced past any hole, which is
exactly the property being tested. Any acknowledgement that arrives while a probe is outstanding satisfies every
outstanding probe, whichever timer armed it; both timers may be outstanding at once.

The keepalive is armed on every established link by both sides at `cluster.keepalive_interval` (default 5 s). A missed
acknowledgement, a send error or a timeout kills that link: the lower host redials with backoff, the higher host closes
and waits. This is the only detection of a one-sided silent death, since there is no goodbye op.

## 5. Semantics carried by the stub

### 5.1 The vector clock

Each frame carries one `(host_idx, state_of_host_idx)` entry. The sender rotates over every member of its replication
group, its own host included, in `0..replication_factor-1` order, one entry per frame; the rotation restarts at zero on
a new connection because the connection has no history.

The entry is the **last state the sender has sent** for that host on this link, not what it has applied and not what is
durable. The WAL appends and never overwrites, so within an epoch this frontier only moves forward, and a receiver
behind it may ask the sender for the missing records. The commitment status of any event is resolved within N WAL
records; N is the consensus document's constant, and the transport relies only on its existence: a frontier never has to
be waited on indefinitely.

### 5.2 The commit envelope

The envelope is the leader's aggregated status of approval, produced once the leader has collected enough approvals and
rejections from the receivers. The receivers' approvals and rejections are consensus payloads and travel in order; the
leader's decisions are strictly sequential, one op per quantum, and the reply is pushed back in that order, stamped with
the right `seq_id`, which the receive-side reorder buffer preserves.

The envelope's positions are `state.IndexState.state` values of the leader's log, not frame sequence numbers.
`start_state_idx` is the first and bit `i` (LSB-first inside a byte) is the decision for `start_state_idx + i`; `1` is
confirmed and `0` is not. The bitmap can express holes, but a correct leader's decided prefix is contiguous. The
envelope is on every frame, and a frame with no new decisions carries the zero byte.

Which direction carries a non-empty envelope, and how a lagging leader's stream interacts with a follower's own log, are
consensus-document questions.

## 6. Configuration

The block is optional and absent when `hosts == 1`:

```zig
pub const Cluster = struct {
    peer_port: u16,
    peers: []const []const u8,
    reorder_window: u16 = 16,
    inflight_frames: u16 = 8,
    handshake_slots: u16 = 64,
    handshake_timeout: Seconds = seconds(5),
    pulse_timeout: Seconds = seconds(1),
    keepalive_interval: Seconds = seconds(5),
};
```

`Config` gains `cluster: ?Cluster = null`. The peer listener binds `bind:cluster.peer_port`, and `peers[host_idx]` is
the address of that host, with the own slot empty.

Validation:

- `peer_port > 0` and `peer_port != port` (the client endpoint);
- `peers.len == wal.hosts()`;
- `peers[host_index]` is empty;
- every other entry is non-empty and a parseable IPv4 address (or `localhost`);
- no duplicate peer entries;
- `reorder_window` is a power of two in `2..=0xFFFF`;
- `1 <= inflight_frames <= reorder_window`;
- `handshake_slots >= 1`;
- `cross_task_slots >= fronts * cluster.handshake_slots` when `hosts > 1`;
- `cluster == null` iff `hosts == 1`.

The canonical document keeps `hosts = 1`, so its rendered form does not grow a `cluster` block. The 4096 frame cap and
the two backoff bounds are link constants, not configuration.

An example for a three-host cluster on host 0:

```text
cluster = {
    peer_port = 7001
    peers = { "" "10.0.0.2" "10.0.0.3" }
}
```

## 7. Implementation plan

This section is the staged implementation plan for §1-§6: ordered, commit-sized steps a downstream implementer works
without re-deciding anything. §1-§6 remain the normative authority; no step reopens a design decision, and where a step
seems to need one, the design has already made it.

### 7.0 How to work these steps (read once, obey always)

1. **No new APIs, no new names, no new files beyond the ones named.** The only new files are `src/reorder_buffer.zig`
   and `src/cluster_transport.zig`. `src/messages.zig` is not touched: the shared `cross_task_slots` pool and the
   payload tag are the whole dispatch mechanism. Where a step names a variant or a constant, that name is fixed.
2. **Verify every symbol before use.** Grep (`rg -n`) for each name a step mentions. Line references are to the tree as
   of writing (zigring 0.0.15, Zig 0.17.1 std) and may drift; re-locate them by symbol name before use. If a referenced
   symbol does not exist as described, re-read the surrounding code and the design section it cites; never guess a
   signature.
3. **One step = one commit-sized change.** After each step: `zig build` clean, `zig build test` green. `build.zig`
   walks `src/*.zig` and wires every file into the `check` and `test` steps, so the new files' tests run with no build
   edits. Never start the next step with a red tree.
4. **The design sections' pinned rules are non-negotiable.** The handshake order (§3), the frame layout and the
   24..=4096 bounds (§4.1), reject-and-close-never-fail (§4.7), the reserve/commit receive path (§4.3), the backoff
   bounds (§3.6). If an implementation choice seems needed, the design already made it; search it again before
   deciding.
5. **No TODOs, no stubs left behind.** A step's tests are part of the step, not follow-ups.
6. Where a step says "pin", that value is final: the 4096 cap, the 24 minimum, window 16, inflight 8,
   `handshake_timeout` 5 s, `pulse_timeout` 1 s, `keepalive_interval` 5 s, backoff 100 ms..5 s, verdict codes 0..=7, op
   codes `0x00` pulse / `0x01` `pulse_ack`.

**Standing rules for the whole plan:**

- A front-side reject is a warn and a close; it is never a process failure (§4.7). Same for the index's verdicts and
  the dialer's rejections.
- fds cross threads exactly once. After a successful hand-over post the front never reads, writes, closes or polls that
  fd again; whoever closes one clears the field (`-1`), the snapshot precedent.
- Every kernel write targets a buffer that waits for its CQE: the handshake entry owns its five-byte request and
  seven-byte reply buffers, the link entry owns its greeting and frame buffers. No buffer returns to a pool before its
  completion (the logging audit's lesson). The same holds for timespecs: a spec the kernel reads asynchronously outlives
  its arming and lives in the owner's stable storage (`RingStuff.tick_spec`, `Controller.init_deadline_spec`,
  `src/lifetime.zig:125-126`), never on the arming pass's stack.
- A refused cross-task post keeps its payload in the owner's entry and retries once per loop pass; it never spins the
  loop and never stacks a second post. This is the `snapshot.dispatch` retry shape (`src/snapshot.zig:390-406`).
- Index pushes never spin; front and main pushes spin-retry on `error.RingFull` (the `reportDone` idiom). Existing
  house rule, unchanged.
- A link's `epoch: u32` bumps on every phase change, and every TaskCtx a link arms carries it; a late completion with
  a stale epoch is logged at debug and ignored, never misattributed (§3.4).
- Slot payloads and TaskCtx variants are plain data: a pointer or an index into stable storage, never an inline buffer
  (`src/slots.zig:42-83` keeps its shape).

### 7.1 Shared vocabulary (fixed for the whole plan)

**`src/cluster_transport.zig` (new).** `VERSION: u16 = 1`, bumped on any incompatible change. `GREET_LEN = 5`,
`REPLY_LEN = 7`, `FRAME_MIN = 24`, `FRAME_CAP = 4096`. `Verdict = enum(u8)` with the §4.7 table verbatim (`ok=0`,
`host_index_squatting=1`, `internal_error=2`, `version_mismatch=3`, `unknown_index=4`, `not_accepting=5`,
`peer_address_mismatch=6`, `invalid_host=7`). Op constants `OP_PULSE = 0x00`, `OP_PULSE_ACK = 0x01`. Backoff bounds as
link constants: `RETRY_MIN = 100 ms`, `RETRY_MAX = 5 s`, exponential, reset on success. Codecs: `encodeGreet` /
`decodeGreet` over the packed `{ version: u16, host_idx: u8, index_idx: u16 }`; `encodeReply` / `decodeReply` over
`{ version: u16, host_idx: u8, index_idx: u16, verdict: Verdict }` (seven bytes; the front's rejects carry `0xFFFF` as
`index_idx`). The frame encoder appends through `blog.append` / `blog.appendVarint` exactly per §4.1/§4.6 (a `u128` as
two `u64` appends, the decisions bitmap as a raw copy, an empty envelope as `0x00`), back-patches `frame_len` at offset
2, and returns `error.FrameTooLarge` past 4096 before any SQE. The lift:
`lift(wave: u64, seq_id: u16, window: u16) ?u64`, the unique absolute in `[wave, wave + 0x10000)` congruent to `seq_id`,
rejected by the reorder checks that follow. The link FSM lives here:
`LinkState = enum(u8) { none, greeting, parked, up }`, the epoch, and the per-link invariants (one open reservation,
one pending post, `pushed_absolute`, `delivered`, the ack flag).

**`src/reorder_buffer.zig` (new).** The copy of `zigring.ReorderBuffer` (zigring `src/iouring.zig:2229-2492`) with the
§4.4 API: `init(allocator, size, max_item)` unchanged in its requirements (`size` a power of two ≤ `0xFFFF`, `2 * size`
slots of `max_item` bytes, the same init error set), `reserve(idx: u64) ![]u8`, `commit(idx: u64, len: usize)`,
`abandon(idx: u64)`, `reset()`, `push(idx, data)` kept as the reserve + memcpy + commit shim, and `peekHeadCond` /
`popHeadCond` returning the committed length. No zigring import; the file owns the algorithm.

**`src/config.zig`.** The `Cluster` struct exactly as §6, `cluster: ?Cluster = null` on `Config`, the `ParseError`
additions, and the §6 validation list, including the parse-time `cross_task_slots >= fronts * cluster.handshake_slots`
when `hosts > 1` and `cluster == null iff hosts == 1`. The canonical config does not grow a cluster block.

**`src/cross_task.zig`.** Two variants:
`PeerLink: struct { fd: posix.fd_t, host_idx: u8, index_idx: u16, version: u16, source_ok: bool }` (12 bytes) and
`PeerServerSocket: struct { fd: posix.fd_t }`. The comptime plain-data and `@sizeOf(CrossTask) <= 16` asserts
(`src/cross_task.zig:107-120`) keep holding; the round-trip test grows both.

**`src/slots.zig`.** TaskCtx variants, each plain data, each a pointer or index into stable storage:
`peer_accept { generation }` (the front's second multishot), `greet_read { entry }` and `greet_deadline { entry }` (the
front's handshake), `reply_send { entry }` (a front reject; close after its CQE), `connect { host_idx }`,
`connect_deadline { host_idx }` (the dialer's connect bound), `greet_send { host_idx }`, `verdict_read { host_idx }`
and `reply_deadline { host_idx }` (the dialer), `greeting_send { host_idx }` (the acceptor's 7-byte reply),
`frame_send { host_idx }`, `frame_recv { host_idx }`, `peer_close { host_idx, epoch }` (a dedicated close),
`pulse { host_idx, epoch }`, `predicate_timeout { host_idx, epoch }`, `keepalive_tick { host_idx, epoch }`,
`retry_timer { host_idx }`.

**Timer mechanisms.** Every deadline and interval the design pins names its zigring call, and every ticker's timespec
lives in its owner's stable storage (the standing rule above). The one-shot deadlines — the front's greet-read
deadline (`greet_deadline`), the dialer's connect and reply-read deadlines (`connect_deadline`, `reply_deadline`), the
predicate's pulse timeout (`predicate_timeout`) and the dial retry (`retry_timer`, re-armed with the current backoff) —
are a one-shot `pushTicker` (ticks = 1, zigring `src/iouring.zig:1380`) with their TaskCtx slot, `pushCancel`ed
(`:1474`) when the guarded phase completes first, the `beginShutdown` cancel idiom (`src/front.zig:187-224`). The
keepalive (`keepalive_tick`) is a repeating `pushTicker` at ticks = 0, the `snapshot.armTicker` precedent
(`src/index.zig:143`). A linked timeout (`pushTimeoutForOp`, `iouring.zig:1428`) is used nowhere, for two reasons.
Semantic: a `LINK_TIMEOUT` guards exactly one SQE, and none of these deadlines is the completion of one SQE — the greet
and reply reads are re-arming phase reads where a per-read clock would let a slow-drip peer hold the deadline open
forever, the predicate times the arrival of a later inbound frame on the standing receive arm, and the keepalive and
the retry are intervals with no guarded SQE at all. Practical: `pushTimeout` with a zero `len` is rejected by this
kernel (`src/main.zig:260-262`), so the one-shot ticker is the SDK's only usable one-shot timer. The connect is the one
SQE-shaped bound among them, and it is a ticker too, for an SDK reason rather than a semantic one: the reliable
linked-timeout shape requires the guard to ride in the same `batchedSQ` batch as the guarded SQE
(`iouring.zig:1415-1427`), and `BatchSQ` (`:1638`) exposes no connect push, while two bare ring pushes publish the SQ
tail between them and the SQPOLL thread can consume the connect alone, cutting the `IOSQE_IO_LINK` chain and rejecting
the guard with `-EINVAL`.

**`src/lifetime.zig`.** `createPeerServerSocket` beside `createServerSocket` (`src/lifetime.zig:1191-1217`), binding
`bind:cluster.peer_port`, existing only when `hosts > 1`, sharing the listener lifetime of the client socket. The
parsed peer addresses, derived once at init: `[hosts][4]u8`, `localhost` folded to loopback exactly as
`createServerSocket` does. Per-index link tables: `indexes x hosts` entries, the own slot unused, one `LinkEntry` each
(the FSM, the fd, the `ReorderBuffer`, the send buffers, the counters), allocated lazily on the first promotion through
the controller allocator (`src/index.zig:92` precedent) and freed in `deinit` only if allocated.

**`src/front.zig`.** A `PeerHandshake` entry: the fd, the filled count, the five-byte greet buffer, the seven-byte
reply buffer, `source_ok`, the read and deadline slots, the pending post, a small state (`reading`, `replying`,
`posting`, `done`). The per-front table holds `cluster.handshake_slots` entries; an accept that finds none closes the
fd with a warn, the client inbox-full shape (`src/front.zig:251-266`). New Ctx fields: the peer listener fd, its accept
slot, and the table; `listening` and `accept_task_idx` stay single-purpose for the client arm (the R7 lesson), the
peer arm gets its own pair.

### 7.2 Stages and steps

Each stage lands green. Steps inside a stage are ordered; stages are ordered by dependency.

**Stage A — the two new files, pure and testable.** No wiring, no behavior change yet.

- **A1. `src/reorder_buffer.zig`.** Copy `zigring.ReorderBuffer`; add `reserve`/`commit`/`abandon`/`reset` and the
  per-slot `u16` committed length; keep `push` as the shim. Port zigring's own reorder test verbatim through the shim
  (the copy is proven not a regression), then add: the three-piece test (a frame delivered through `reserve` + two
  partial body commits delivers exactly once, and `peekHeadCond` returns `frame_len`, not `max_item`);
  `OutdatedFrame` below the wave; `FramesAreTooFarAway` at `wave + size`; `abandon` frees the slot for reuse; `reset()`
  clears the wave, the lengths and every reservation.
- **A2. `src/cluster_transport.zig` codecs.** Constants, greet and reply codecs, the verdict and op maps, the length
  check as one comparison, the encoder with the back-patch, the lift. Tests: the codec test feeds frames at absolute 0,
  2 and 1 through a `ReorderBuffer` and asserts delivery 0, 1, 2; the length test, 23 and 4097 rejected, 24 and 4096
  valid; the back-patch equals the validated length on every encode; a `u128` appends as the two-`u64` little-endian
  form; the bitmap is a raw copy (no varint prefix — `blog.append` prefixes slices and fixed arrays alike, so the
  envelope's bitmap is a `@memcpy`); an empty envelope is the single byte `0x00`; greet and reply round-trip; a reply
  with `index_idx = 0xFFFF` decodes as the front sentinel.

**Stage B — configuration.**

- **B1. `src/config.zig`.** The `Cluster` struct, the optional field, the parse (siggy's `x = { }` renders an absent
  optional as null; the block is absent when `hosts == 1`), the `ParseError` additions, and the §6 validation inside
  the existing single `validate` path (`src/config.zig:634-642` precedent): `peer_port > 0` and `!= port`;
  `peers.len == wal.hosts()`; the own slot empty; every other entry non-empty, a parseable IPv4 or `localhost`, no
  duplicates; `reorder_window` a power of two in `2..=0xFFFF`; `1 <= inflight_frames <= reorder_window`;
  `handshake_slots >= 1`; the cross-task pool minimum; `cluster == null iff hosts == 1`. Tests: one accept case (the
  §6 three-host example) and one rejection per rule. Deeper cross-host misconfiguration checks are deferred, not
  dropped: v1 validates statically (§6) and detects duplicates at runtime (§3.4); anything beyond that belongs to the
  consensus or transport-format document.

**Stage C — cross-task vocabulary.**

- **C1. `src/cross_task.zig`.** `PeerLink` and `PeerServerSocket`; the comptime asserts hold; the round-trip test
  grows both, and the 16-byte proof stays a comptime assertion. `src/messages.zig` is not touched.

**Stage D — process resources.**

- **D1. `src/lifetime.zig`.** The parsed peer addresses at init; `createPeerServerSocket` (bind + listen through the
  same shapes as `createServerSocket`); the per-index link table storage and its lazy allocation; `deinit` frees what
  was allocated, after the threads have joined, before the rings go (the R1 ordering).
- **D2. `src/main.zig` and the front's receive arm.** The process thread creates the peer listener beside the client
  one (only `hosts > 1`), posts one `PeerServerSocket` slot per front with `taskIdx = messages.CrossTaskMessageIdx`
  and `res = slot_idx` through the `snapshot.dispatch` shape, **before** `broadcastStartWork` (`src/main.zig:301-312`):
  same-source-ring ordering is the guarantee the design cites. The front's `CrossTaskMessageIdx` arm (add the
  payload-tag switch if the arm is new; keep it if it exists) stores the fd. The START_WORK arm arms both accepts: the
  client fd from `res`, the peer fd from the stored slot; if `hosts == 1` no post ever arrives and no peer arm is
  taken. The process exit path closes the peer listener after the fronts have stopped. Tests: slot round-trip (C1),
  listener create/close as a lifetime test; the arrival ordering is asserted by the Stage K harness.

**Stage E — front intake (§3.2).**

- **E1. The arm.** The front's second multishot accept on the shared peer listener, its own Ctx fields and its own
  `peer_accept` slot; the handshake table; the empty-table close path (warn + close, the `src/front.zig:251-266`
  shape).
- **E2. The greet read and the rejects.** On an accept CQE the entry takes the fd and arms a one-shot `pushRecv`
  (`zigring` `iouring.zig:821`) for `5 - filled` bytes, and with it the greet deadline: a one-shot `pushTicker`
  (ticks = 1) in the entry's `greet_deadline` slot, armed at the accept with `cluster.handshake_timeout` and
  `pushCancel`ed when the fifth byte lands — one absolute clock across the re-armed partial reads, because a guard
  that restarted with every short completion would let a peer drip-feeding a byte every few seconds hold the entry
  open indefinitely. Partial reads re-arm for the remainder; EOF, deadline or error closes the fd and releases the
  entry. On five bytes the ordered checks run exactly as §3.2: `version` first, then `invalid_host` (`host_idx >=
  hosts` or own), then `unknown_index`, then `std.posix.getpeername` and `source_ok` against the parsed
  `peers[host_idx]`. A reject writes its 7-byte reply from the entry's buffer and closes after that send's CQE; the
  reply and the close both carry `reply_send` / `close` slots. Tests: greet decode and reply encode are unit-tested
  through the A2 codecs; the state machine (E1-E4) is exercised by Stage K.
- **E3. The hand-over.** Acquire a `cross_task_slots` slot, write `PeerLink`, post `MSG_RING` with
  `taskIdx = messages.CrossTaskMessageIdx`, `res = slot_idx` to `ctrl.rings[cfg.fronts + index_idx].ring.fd`
  (`roleOf`, `src/lifetime.zig:1129-1166`); the `resync` of the stream window first, the `snapshot.dispatch` retry on
  `RingFull` / `CrossTaskFull` with one pending post per entry. The successful post is the ownership transfer
  (standing rule).
- **E4. Front shutdown.** Stop posting; cancel the peer accept arm and the in-flight handshake reads and deadlines;
  close their fds; release the pool slots. Match completions by task_idx alone and keep the draining-close branch
  (the R3 shape).

**Stage F — the index acceptor (§3.3, §4.3, §4.2).**

- **F1. The tag switch and the greeting.** The `CrossTaskMessageIdx` arm keeps its `resync` (`src/index.zig:246-258`)
  and switches on the payload tag: the snapshot replies go where they go today, `PeerLink` goes to the link intake.
  The intake re-validates (`version`, `host_idx < hosts`, not own, `source_ok`, the index number is its own), checks
  the link table, and answers: no link, the entry moves to `greeting`, one 7-byte reply from the link entry's buffer,
  and on that `greeting_send` CQE the link is `up`, the reorder buffer starts at absolute zero, the first receive is
  armed; a duplicate, Stage H decides; any failure, the reply with the failing verdict and a close after its CQE. A
  greeting at a draining index closes at once, no verdict (`src/index.zig:203-227` shape); the dialer logs that EOF
  as `not_accepting`.
- **F2. The receive path.** Per §4.3, exactly: the four-byte header buffer and `filled_hdr`; `lift` and the
  one-comparison length check (`24 <= frame_len <= 4096`, outside is a link death, no bytes skipped); `reserve(abs)`,
  the prefix copied to `slot[0..4]`, `pushRecv` for `frame_len - 4` into `slot[4..frame_len]`, short completions
  continuing at `slot[filled..]`, `commit(abs, frame_len)` when full, at most one open reservation per link; the
  synchronous drain (`popHeadCond` with the dispatcher as the condition, or `peekHeadCond` + `dropHead`, then
  `delivered += 1`), a frame the dispatcher cannot hold is peeked and retried next pass; the arm is gated by
  `pushed_absolute - delivered < window`; `OutdatedFrame`, `FramesAreTooFarAway`, an unliftable ring number and an
  unknown op code are link deaths. `pulse` answers `pulse_ack` on the transport path; `pulse_ack` sets the link's ack
  flag (Stage I); both timers may be outstanding at once, and any ack satisfies every outstanding probe — the
  uncorrelated acknowledgement of §4.8, as a test assertion in Stage K.
- **F3. The send path.** Per link: a fixed array of `inflight_frames` 4096-byte buffers in the link entry (not
  `blog.BufferPool`, §4.2), a busy mask, `seq_abs: u64` advanced only after a successful submit, the back-patched
  encoder, `error.Backpressure` when all buffers are busy. The send context waits for its CQE (standing rule). Every
  frame carries the rotating vector-clock entry of §5.1: the vector clock exists because each host carries only its
  own data, so every member's frontier must travel on every frame rather than arriving as gossip.

**Stage G — the index dialer (§3.1, §3.5, §3.6).**

- **G1. Dial and greet.** The first dial is issued once the index has finished recovery and before the service loop:
  after `snapshot.armTicker` (`src/index.zig:143`), before the `while (true)` at `:145`, for every host > own:
  `pushConnectIp4` (`zigring` `iouring.zig:1174`) on the index's own ring with a `connect` slot, the configured
  `peers[host]` address. The connect is inside `cluster.handshake_timeout` from the moment it is submitted: a
  one-shot `pushTicker` (ticks = 1) in a `connect_deadline { host_idx }` slot armed with the dial, `pushCancel`ed on
  the connect CQE; on its tick the connect is `pushCancel`ed, and the canceled dial is a failed connect — warn, close,
  arm the retry (§3.6). On the connect CQE, the 5-byte greet from the link entry's buffer; nothing else until the
  reply. The reply: a one-shot `pushRecv` for exactly seven bytes, partial reads re-armed for the remainder under one
  absolute deadline — a one-shot `pushTicker` (ticks = 1) in a `reply_deadline { host_idx }` slot, `pushCancel`ed on
  the seventh byte. Only an `ok` verdict is validated (`version == local`, `host_idx == the host dialed`,
  `index_idx == its own`; the `0xFFFF` sentinel is never validated as an identity — a non-zero verdict does not
  validate the peer's identity, §3.5 — asserted by the Stage K tests), then the link is installed, the reorder state
  created at absolute zero, the receive armed, an info log. Any other code, EOF, a short read at the deadline or an
  error: warn, close, arm the retry.
- **G2. Retry.** The backoff is a one-shot `pushTicker` (ticks = 1) in a `retry_timer { host_idx }` slot, re-armed
  with the current backoff after every failure: `RETRY_MIN` doubling to `RETRY_MAX`, reset on success, never fatal,
  logged at warn. The higher host never dials; its side waits (§3.6).

**Stage H — duplicate links: the predicate (§3.4).**

- **H1.** A duplicate link means the peer restarted or reconnected while the local end of the old socket was still
  open. The candidate parks without a receive arm. The existing link's entry bumps its epoch; a `pulse` frame goes
  out through the send path with a one-shot `pushTicker` (ticks = 1) in a `predicate_timeout { host_idx, epoch }`
  slot at `cluster.pulse_timeout`, `pushCancel`ed when the ack flag lands — the timeout times the arrival of a later
  inbound frame, not any single completion, and a stale timeout and a pulse completion after the timeout are both
  ignored by epoch. On an error, a missing ack or the timeout: the old link is dead, the candidate is installed (the
  7-byte `ok` reply, then `up`), the old fd retired with a dedicated `peer_close`, the reorder buffer `reset()`,
  `seq_abs` to zero, the replacement logged at warn, nothing replayed — the old host cannot send anything more
  (§3.4). On an ack: the `host_index_squatting` reply, a close after its CQE, the existing link untouched. The
  predicate never blocks the index loop; the existing link keeps serving.

**Stage I — liveness (§4.8).**

- **I1.** `pulse` and `pulse_ack` as F2 handles them; the keepalive is a repeating `pushTicker` (ticks = 0) in a
  `keepalive_tick { host_idx, epoch }` slot, armed on `up` by both sides at `cluster.keepalive_interval`. A pulse
  needs an acknowledgement because a send CQE proves only that the kernel accepted the buffer; only the peer's
  inbound `pulse_ack` proves it is alive. On each tick, if the ack flag is set, clear it and send a pulse; if not,
  the link is dead, §3.6's teardown runs. A send error or a timeout kills the link the same way. On a link death the
  ticker is canceled (the `beginShutdown` cancel idiom, `src/front.zig:187-224`).

**Stage J — teardown (§3.7).**

- **J1. Index.** Every drain path (`src/index.zig:203-227`, the three `reportDrained` callers) closes the links
  first: `shutdown_soft` keeps them until the sessions are gone then closes each with `pushClose`; `shutdown_hard`
  closes immediately; before reporting, one final full CQ drain releases any `PeerLink` slot that raced the shutdown
  and closes its fd.
- **J2. Front.** E4's path stands; a post already submitted is consumed by the index's final drain or, in the last
  race, by `Controller.deinit`, which frees the pool after every thread has stopped (the R1 ordering).

**Stage K — end-to-end tests and the landed record.**

Status: landed. The harness and its seven scenarios live in `src/main.zig:577-1219`; the as-built anchors are §8.

- **K1. The harness.** Two independent `Controller`s in one process, `host_index` 0 and 1, one-core masks, four
  distinct loopback ports (client and peer per controller), `peers` empty at the own slot, one index thread each,
  `hosts = 2`. The harness waits on the in-process link tables (both sides to `up`) with a generous deadline; the
  dial lands inside the backoff bounds.
- **K2. The scenarios, each a test:** greeting and link-up both sides; a pulse round-trip with the keepalive at a
  tiny configured interval; the squat, a second greet injected from a raw test socket while the link is up,
  answered `host_index_squatting` with the existing link untouched; the replacement, the same injection after the
  test shuts the live socket down from the dialer's side, so the probe times out, the candidate is promoted, the
  test's raw socket reads `ok`, and the entry's epoch and zeroed sequence are asserted; the silent death, the
  keepalive misses, the higher host closes and waits, the lower redials and the link re-establishes at absolute
  zero; soft teardown with links up closes them before the drain report; hard teardown closes immediately; both
  exit clean.
- **K3. The landed record.** After Stages A-K land: record the as-built anchors into this document (each design
  section gains its landed file:line references), the shape `wal-steps` §Z set. This is the table the consensus
  document cites.

## 8. Landed record: as-built anchors

Stages A-K are landed and `zig build` / `zig build test` are green. This section is the record, not work items: every
design section above gains the file:line anchors of its implementation, so the consensus document can cite the landed
transport instead of the plan. Line numbers are the tree as landed; when code moves, re-locate the named symbol rather
than trusting the number (the §7.0 rule 2 discipline, applied to readers).

| Design section | As built |
| -------------- | -------- |
| §2 topology and the per-index link table | `src/lifetime.zig:89-165` (`LinkTable`, lazy `acquire`), `:171-182` (parsed peer addresses), `:262` (`peer_addrs`), `:267` (`link_tables`) |
| §3.1 dial and greet | `src/index.zig:409-416` (`dialPeers`), `:418-483` (`startDial`: connect, its ticker, the greet), `:565-604` (`onConnect`), `:623-672` (`onGreetSend`), `:674-716` (`onVerdictRead`) |
| §3.2 front intake | `src/front.zig:78-125` (`PeerHandshake`), `:329-336` (`installPeerAccept`), `:340-389` (`handlePeerAccept`), `:402-418` (`classifyGreet`), `:422-456` (`openHandshake`), `:480-518` (greet read), `:520-540` (partial re-arm), `:545-564` (deadline), `:567-587` (ordered checks), `:592-621` (reject reply), `:660-671` (`peerSourceOk`), `:676-722` (`tryPost`) |
| §3.3 index intake and greeting | `src/index.zig:797-860` (`onPeerLink`, re-validation), `:865-899` (`rejectLink`), `:904-929` (`acceptLink`), `:1252-1266` (`armGreetingSend`), `:1268-1303` (`onGreetingSend`) |
| §3.4 duplicate links: the predicate | `src/index.zig:935-964` (`parkCandidate`), `:969-1000` (`probeCandidate`), `:1024-1074` (`resolveProbe`), `:1099-1117` (`onPredicateTimeout`), `:1216-1250` (`promoteCandidate`) |
| §3.5 the dialer's acceptance | `src/index.zig:718-762` (`onVerdictComplete`: only `ok` is identity-checked) |
| §3.6 failure, death and retry | `src/index.zig:506-538` (`armRetry`), `:396-399` (`nextBackoff`, 100 ms..5 s), `:541-548` (`pumpRetries`), `:552-563` (`failDial`), `:1593-1611` (`killLink`, which now arms the lower host's retry on every death, §8.1), `:1168-1191` (the keepalive miss) |
| §3.7 teardown | `src/index.zig:1546-1587` (`teardownLinks`, `closeLinks`, `drainFinalCQ`), `:1621-1640` (`closePeerFd`, `onPeerClose`), `src/front.zig:741-759` (`closeForShutdown`), `:839-901` (`beginShutdown`), `src/main.zig:360-406` (the process demand and its ticker) |
| §4.1 frame layout and the length bound | `src/cluster_transport.zig:15-38` (constants), `:443-457` (`CommitEnvelope`, `Frame`), `:465-524` (`encodeFrame` with the offset-2 back-patch), `:526-534` (`frameLenValid`) |
| §4.2 the send path | `src/cluster_transport.zig:102-346` (`LinkEntry`: `send_buffers`, `send_busy`, `send_task`, `inflight`), `src/index.zig:1460-1514` (`sendFrame`, `onFrameSend`) |
| §4.3 the receive path | `src/index.zig:1307-1335` (`armReceive`), `:1337-1383` (`onFrameRecv`), `:1387-1410` (`onFrameHeader`: `lift` + reserve + prefix copy), `:1416-1431` (`drainFrames`) |
| §4.4 the reorder buffer | `src/reorder_buffer.zig:16-320` (`reserve` `:109`, `commit` `:131`, `abandon` `:201`, `reset` `:208`, shim `push` `:222`, `popHeadCond` `:268`, `peekHeadCond` `:293`, `dropHead` `:306`) |
| §4.5 sequence numbers, window and lift | `src/cluster_transport.zig:537-549` (`lift`), `src/index.zig:1317` (the backlog gate), `:1490-1493` (the post-submit `seq_abs` advance) |
| §4.6 encoder rules | `src/cluster_transport.zig:465-524` (field-order appends, `u128` as two `u64`s, raw bitmap copy, `0x00` empty envelope); asserted at `:666-698` |
| §4.7 op codes and verdicts | `src/cluster_transport.zig:32-33` (`OP_PULSE`, `OP_PULSE_ACK`), `:80-90` (`Verdict`), `src/index.zig:1433-1456` (`dispatchFrame`) |
| §4.8 pulse and keepalive | `src/index.zig:1124-1154` (`armKeepalive`, repeating ticker), `:1159-1164` (`cancelKeepalive`), `:1168-1191` (`onKeepaliveTick`), `:1196-1210` (`sendKeepalivePulse`), `:1440-1450` (pulse/ack dispatch) |
| §5.1 the vector clock | `src/cluster_transport.zig:436-441` (`VectorClockFrame`), `src/index.zig:1470-1476` and `:1493` (the rotating `vc_cursor`) |
| §5.2 the commit envelope | `src/cluster_transport.zig:443-448` |
| §6 configuration and validation | `src/config.zig:141-152` (`Cluster`), `:711-755` (`validateCluster`), `:504-513` (the rule list) |
| §7.1 shared vocabulary | `src/slots.zig:50-142` (every `TaskCtx` variant), `src/cross_task.zig:98-113` (`PeerLink`, `PeerServerSocket`) |
| §7.2 D2 wiring | `src/main.zig:317-340` (`postPeerListener`), `:345-355` (`broadcastStartWork`) |
| K1 the harness | `src/main.zig:577-616` (`ClusterOptions`, helpers), `:619-755` (`HarnessNode`), `:757-792` (`ClusterPair`), `:788-941` (link-table reads and socket helpers) |
| K2 the scenarios | `src/main.zig:943-1219`: greet and link-up, keepalive round trip, squat, replacement, silent death and redial, soft teardown, hard teardown |

### 8.1 Notes taken while landing

- **The lower host's retry after a death.** K2.5 pinned a gap: the dial failures armed the retry, but a link that died
  after it was up (EOF, a send/receive error, a keepalive miss) only reset the entry and left the lower host dark.
  `killLink` (`src/index.zig:1593-1611`) now arms the retry for the lower host, exactly as §3.6 states; the higher host
  still closes and waits. The as-built anchors above include that line.
- **The harness's endpoint model.** §6 pins one `peer_port` for the whole group, so two shards in one process cannot
  both bind it on one loopback address. The K1 harness therefore gives the shards `127.0.0.1` and `127.0.0.2` and
  shares the group's single peer port; the client listeners take ephemeral ports (`port = 0`). The
  "four distinct loopback ports" phrasing of K1 assumed a per-host peer port that §6 does not define.
- **The replacement scenario's dialer.** A silent probe timeout needs a dialer the test can silence without a FIN.
  K2.4 is therefore a single acceptor shard (host 1) with the test as host 0: it dials with a raw socket, completes a
  greet, injects the candidate, and calls `SHUT_RD` on its live socket. The index's recv never sees EOF, the pulse goes
  unanswered, and the predicate timeout promotes the candidate, which is the exact §3.4 path.
- **Hard teardown trigger.** A session-free skeleton cannot keep a soft drain open, so the front's escalation deadline
  has nothing to escalate against. K2.7 drives `shutdown_hard` into each index inbox directly, the same value
  `escalateShutdown` (`src/front.zig:903-918`) sends, and asserts the links are closed by the drain report.

## 9. Out of scope

- The consensus algorithm: quorum, terms and epochs, leader election and the decision rules.
- Payload codecs for consensus ops; the contents and chunking of catch-up and snapshot transfers.
- The WAL and state-machine semantics the ops mutate.
- The client-facing protocol and the client path, which are data plane.
- Fencing and epoch advancement, except that the transport carries the packed state value opaquely.
- The chunking rules for a logical transfer above 4 KiB, the per-op payload caps, and any future frame field.
