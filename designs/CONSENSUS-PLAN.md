# Consensus driver integration plan.

Source of the idea: `designs/CONSENSUS-DRIVER.md` (below: Driver), built on `docs/consensus.md` (below: Proto). The axis
of integration: `src/index.zig`. This document captures the current state of the code, the target structure, and the
order of work. All open questions are resolved and folded into the text.

## 1. Current state of the code (what already exists).

- `src/index.zig`: `pub fn run(ctrl, role, logger)` — the index service loop. No sessions yet: an `fd` accepted from a
  front is closed immediately (the `create` branch), `session_op` is ignored. The CQ is drained before the inbox;
  reserved `taskIdx` values are dispatched through a `switch` (`messages.zig`).
- `src/state.zig`: a draft `Session` (states `ExpectOp`, `ExpectConsensus`, `ExpectAcceptedFlush`, `ConsensusProgress`,
  `wheel_idx`) and `WALOperation`. None of these types are wired anywhere.
- `src/slots.zig`: `RingSlots` on top of `zigring.Slots(TaskCtx)`; so far `TaskCtx` only knows
  `accept/recv/close/timeout/accept_once/logging/idle`.
- `src/timing_wheel.zig`: a ready `TimingWheel(N,L)` — the block shape at comptime, the tick count a runtime parameter
  of `init`; strictly single-threaded.
- `src/lifetime.zig`: `Controller` — shared resources: `rings`, `inboxes`, `cross_slots`, the ring factory.
- `src/config.zig`: `Config` (siggy text, `mpy6a.cfg`): `fronts`, `indexes`, `elephants`, `host_index`, `queue_depth`,
  etc. Neither mirror addresses nor consensus parameters exist yet.
- `src/messages.zig`: the vocabulary of reserved `taskIdx` values with comptime proofs.
- The mirror transport is `docs/consensus-network-protocol.md`: a multiplexed frame — a ring `seq_id`, a vector clock
  frame, an op tag and payload (see 2.6) — carrying the operation vocabulary that the semantics of Proto rides on.

## 2. Target structure.

### 2.1 The controller: `Index` in `src/index.zig`.

`pub fn run(...)` becomes `pub const Index = struct {...}` (the controller of Driver). Fields:

```zig
pub const Index = struct {
    ctrl: *lifetime.Controller,
    role: lifetime.Role,
    ring: *lifetime.RingStuff, // its own ring, as now
    inbox: *Inbox,
    log: *logging.Logger,

    driver: ConsensusDriver, // sliced below
    sessions: SessionTable,  // verztable.HashMap(u128, Session): session_id -> session data; carries the client
                             // endpoint (fd + tag, 2.3) for the op in flight, owns no fd lifecycle
    state: u128,             // the index state: (host_id: u8, index_id: u16, epoch_id: u40, index: u64), see 2.5
    wheel: Wheel,            // a TimingWheel instance for repeat/pulse and violation deadlines; its tick count is a
                             // runtime parameter of init
    slots: RingSlots,        // index-wide, owned and freed by the Index itself

    pub fn run(self: *Index, logger: *lifetime.LoggerStuff) void; // the service loop
};
```

The service loop keeps its current shape: drain CQ -> drain inbox. The big `switch` over `task_idx` grows consensus
branches (see 2.4).

### 2.2 The driver: `ConsensusDriver` in `src/index.zig`.

```zig
pub const ConsensusDriver = enum {
    local,   // single-host mode
    cluster, // combat mode

    pub fn connectHosts(self: ConsensusDriver, idx: *Index) !void;
    pub fn connectionEstablished(self: ConsensusDriver, idx: *Index, host_idx: u8, fd: posix.fd_t) void;
    pub fn expectOp(self: ConsensusDriver, idx: *Index, session_id: u128, op: Op) void;
    pub fn dispatchExpectOp(self: ConsensusDriver, idx: *Index, host_idx: u8, session_id: u128, resp: ConsensusResponse) void;
};
```

The decision from Driver: an `enum` plus a `*Index` parameter, not a `union(enum)` holding a reference — all state lives
on the `Index` controller. It stays inside `src/index.zig`: the driver is tiny and needed nowhere else. `local.expectOp`
immediately calls `idx.updateSessionState(session_id, .{ .op_acknowledged = op })` and proceeds to the flush (skipping
the replica reactions). `local.connectHosts` is a `Nop`.

### 2.3 Sockets and connection.

For `cluster` (the combat mode): the shard consists of `replication.factor` hosts numbered `0 .. factor - 1`
(`cfg.host_index` picks ours, see 2.7). Every index service holds one connection to the same index service of every
other host: a separate connection per (host pair, index pair). For a factor of 3 and two indexes the full map is:

```
type subj = (host_idx: u8, index_idx: u16)

{
    subj(0, 0): [ subj(1, 0), subj(2, 0)],
    subj(0, 1): [ subj(1, 1), subj(2, 1)],
    subj(1, 0): [ subj(0, 0), subj(2, 0)],
    subj(1, 1): [ subj(0, 1), subj(2, 1)],
    subj(2, 0): [ subj(0, 0), subj(1, 0)],
    subj(2, 1): [ subj(0, 1), subj(1, 1)],
}
```

- The rule of Driver: only the host with the lesser `host_idx` dials (from 0 to 2, never from 2 to 1). The greater side
  never connects back: it reuses the reply channel of the socket the lesser side opened, so each pair runs over exactly
  one bidirectional socket.
- On the controller: `mirror_sockets: [factor]posix.fd_t` (indexed by `host_idx`, the own slot invalid) plus
  `connect_state: [factor]ConnectState` — the machine of Driver:
  `waiting_connect -> greeting_sent -> awaiting_accept -> established`.
- `connectHost(host_idx, index_idx)`: a `connect` SQE with a timeout; the greeting pushed right after carries
  `self_host_idx` and `index_idx`, so the accepting side learns which of its index services the connection serves.
- The replication `bind` is served by the fronts: a front accepts the connection, reads the greeting,
  and routes the accepted `fd` to the right index service via io_uring messages (cross-task slots) — the same channel
  the `shard-arch-hld.md` handshake uses to hand `INDEX_REPLICATION` fds over to index rings.
- Mirror sockets clamp the TCP retry window below the default ~15 s (e.g. `TCP_USER_TIMEOUT` derived from
  `consensus_timeout`): a dead peer must surface as an `errno` on the bounded recvs that await acknowledgements, not as
  a silent stall.

The client endpoint (both modes). A session owns no fd lifecycle: the client socket is accepted, read, and closed by the
parent front — the cluster sockets of the index are the mirror sockets above — and no `session_id -> fd` mapping exists
on either side. The front differentiates every incoming client request before anything is pushed, because the dispatch
needs the differentiation anyway: a pulse goes nowhere — indexes serve mutations only, so the front consumes the pulse
itself and no pulse ever reaches an `IndexInbox`; a create is passed via round robin (or an analogue, say the
least-loaded inbox) over the front's own indexes; an in-session op goes to the index owning the session — read straight
from the `index_id` slice of its session id (2.5), always one of the front's own, since the create was dispatched within
the front's share; a session id naming an index outside the share is a rogue client's doing — the front answers with an
angry reply and marks the socket for the deferred close itself, the socket being the front's own. What crosses the
front -> index boundary is the endpoint value: every task the front pushes through the `IndexInbox` (`create` and
`session_op` alike) carries the client's socket descriptor together with its tag (the value is a tag, not a "bound
value"), and the session keeps the pair for the op in flight. Replies go back through the index' ring directly: a
`reply_op` SQE on the client fd, one write per reply, no cross-task message on the path.

The descriptor value alone identifies a client only until the front closes it and the kernel hands the same value to a
new, valid connection — a naive fd-only hand-off would then reply to and close the innocent newcomer — so the
faulty-client hand-off rides the tag check instead, and the index never writes to a client it has declared faulty: the
front does the reply on a validated complaint. The machinery is allowed to cost a bit more: a faulty client is a rare,
development-time thing (client-code-in-the-making), not a horde from the open internet.

- The tag comes from `socket_counter: usize` in the front's context, initialized to `front_idx + 1` (the tag `0` is
  invalid): every accept stores the current counter value together with the socket and bumps the counter by `Fno` (the
  number of fronts — a power of two by the config's own proof) immediately after.
- The socket bookkeeping — the tags and the in-flight counters below — lives in arrays shared by all the fronts and the
  indexes, indexed by the fd value directly — no `HashMap` on this hot path — so open client sockets carry a hard cap
  (the 64Ki..128Ki scale), pinned through the process `rlimit` before the workers spawn: every fd value is a valid array
  index. The layout is columnar: the tag stands on its own, and the counters are one plain allocation
  of `socket_limit * indexes_per_front` `u32`s — one row per (fd, index service), the real dimension being the index
  count of the front (`max_indexes_per_front`, `src/front.zig`), not the replication factor; each counter is a single
  4-byte word, naturally aligned, and only the allocation itself needs an alignment guarantee. The entries start zeroed;
  the deferred close zeroes the entry — the tag and the counters together — and only then closes the socket.
- The complaint is a `CrossTask` slot plus a `MSG_RING` into the parent front's ring — the ring every task of this index
  arrived through — carrying a complaint code, the client fd, and the tag the op arrived with. The front validates: the
  entry exists and equals the carried tag. A tag that currently belongs to another front never matches this front's
  valid form — `n*Fno + (front_idx + 1)`: the owner sits in the low bits (`(tag - 1) & (Fno - 1)`), the generation in
  the high bits (`(tag - 1) >> log2(Fno)`; masks and shifts only, never `%` and `/`: `Fno` is not a comptime value, and
  the compiler cannot strength-reduce the division). A missing entry or a mismatch — the client is already gone, or the
  fd value was reused by this or another front — is a `Nop`; a full match makes the front reply to the client, mark the
  socket for the deferred close, and stop observing it once the close lands.
- No locks and no atomics: every field has exactly one writer — the tag and the front counter by the owning front alone,
  each index counter by its index alone — and every field is a single aligned word, so a concurrent read sees either the
  old or the new value, never a torn one. With the columnar split the drain sums single words, no coherence snapshot is
  needed.

The counters are monotone: there is no -1 and no mid-life zeroing anywhere. Each socket carries one front counter —
bumped by the owning front alone, +1 for every op the front pushes into an `IndexInbox`, every operation counted, not
just mutations — and one `u32` per index service, bumped by that index alone, +1 for every op the index retires (the
`reply_op` write done, 2.5 step 6; the complaint pushed, a protocol violation or a `Close`; the unknown-session
handling done, 2.5). The socket is drained exactly when the sum of the index counters matches the front counter:
everything pushed has been retired. The equality is modulo `2^32` — a wrap means nothing — and the dequeue race is
closed by construction: the front bumps at push time, so a straggler still sitting in an inbox keeps the sum short of
the front counter, and nothing is ever subtracted, so no underflow and no zeroing race exist — the entry is zeroed only
at the drained close itself.

The deferred close. The front never closes a client socket in an instant: a close is prepared and waited for. Every
close path — a validated complaint, the `Close` op, a disconnect the front sees on its own socket — marks the socket:
incoming data stops flowing through the `IndexInbox` (so the front counter stops bumping), and a ticker raised on the
front's ring tells the front to re-check the drain condition — the sum of the index counters against the front counter;
while the sum falls short a new tick is set (or a multishot ticker keeps running), and when it matches the socket is
finally closed: the entry is zeroed, the fd dropped from the observable set. The kernel can never hand the fd value to a
new connection while an index still holds an op on it, so an in-flight `reply_op` cannot land on a reused fd (an SQE
write cannot generation-check), no one-op-deep window remains to accept, and the symmetric "client gone" notification is
not needed for fd safety. No atomics are involved: the counters are single-writer and aligned, the front only polls.

```zig
const SocketInfo = struct {
    tag: usize,
    front_counter: u32,
    // ... the index counters live in the columnar allocation:
    // [socket_limit * indexes_per_front]u32, one row per (fd, index service)
};
```

The orphaned session entry. No word crosses back to the index when the deferred close executes — the index never learns
that a client vanished, and none is needed: the expiry is a standard timing wheel over the client sessions. A session
that sits too long without any activity over it goes into the replay. The refresh mechanics are the pulse design: there
is no process-wide tick — every front runs its own ticker, and a tick is not a private counter the front bumps but the
absolute monotonic time in whole seconds since the Unix epoch (the read is `zigring.nowNs()`, CLOCK_REALTIME), so no
front's tick epoch exists anywhere — and the tickers are deliberately made with a shift against each other — the front
`f` arms its ticker `f * (tick_interval / Fno)` after the 1st (a 50 ms interval and two fronts start the 2nd ticker 25 ms
after the 1st; the `Duration` divided by the scalar `Fno`, plain arithmetic over the leaf's `nanos`) — because that scan
against the socket tick may cause hikes, and we do not want the whole system to hike: spread the tickers a bit in time
and the scans fall on different instants. The socket data carries a `last tick` field, bumped by the front on every
client traffic it sees — the pulse above all: per-connection, not per-session (session-agnostic, to avoid pulse-spam),
and going nowhere, the pulse being the explicit keep-alive of an otherwise-quiet connection. The coarseness is the
design of the base: the field is used for ordering almost exclusively anyway, and the one value that flows onward — the
replay start — is itself not fine grained, a whole second with `do not start before this second hits` semantics. The
clock behind the base is `zigring.nowNs()` (CLOCK_REALTIME, the Unix epoch): the replay-start second travels across
hosts, because a host never controls the sessions of another host it has replicated — a host can only isolate them once
the cluster decided the owner lost — so the shared Unix epoch is the base, and the cross-host comparison rides the
invariants of the time-sync design: the hosts' times are kept synced, and the timeout before a host is considered lost
sits way above the precision of that time-sync interaction. A session is moved on the wheel whenever it is mutated, and
when the wheel asks whether a session outlives its maximum inactivity interval, the answer is read from its socket's
`last tick`: a tick within the interval — the field moved since the deadline was armed — moves the session on (the
deadline refreshed), otherwise the session expires into the replay. The session garbage is thereby bounded; the replay
itself is the stage-6 compensation process (3) — a plain synchronous method call (`Index` with the `session_id` and the
time: no machinery beyond memory juggling, the implementation deliberately un-designed while the consensus is the point)
— and the socket of a vanished client is closed by the front alone (the client socket is always the front's job) — the
front's own wheel checks its sockets against their `last tick`, the drain and the deferred close doing the closing. The
tick the index's wheel rides is the front's own tick relayed into the `IndexInbox`: every front pushes its ticks through
the inboxes in turn — one tick into `IndexInbox[0]`, the next into `IndexInbox[1]`, the next into `IndexInbox[2]`, and
so on — so every tick makes exactly one index check its stuff, and the checks rotate over the indexes. The relayed tick
is an op carrying a time, its payload being the front's current absolute second, the same base the `last tick` field
holds, so the index compares directly — the carried second against the field — and no epoch of any front travels
anywhere; the `tick_interval` cadence decides only when the checks run, never how precise they are, the same second
riding every tick of a 50 ms stretch. The maximum inactivity interval is `session_inactivity_timeout` (2.7), `30s` by
default: both the wheel deadlines and the front's socket sweep price against it. The value is a `Duration` — the siggy
leaf `SiggyDuration` of `src/config.zig:437` — written in the Go `time.Duration` text format ("30s"; a bare number reads
as seconds), the leaf's decoder owning the parse.

### 2.4 `TaskCtx` extension (`src/slots.zig`).

New branches, as the tract of Proto requires:

```zig
pub const TaskCtx = union(enum) {
    ...,
    /// Sending one consensus request to one mirror.
    replicate_op: struct { session_id: u128, host_idx: u8 },
    /// Writing the operation to the WAL (own log).
    flush_op: struct { session_id: u128 },
    /// Writing the reply to the client fd: the direct write.
    reply_op: struct { session_id: u128 },
    /// A reply from a mirror: recv on a mirror socket.
    mirror_recv: struct { host_idx: u8 },
    /// Connect/timeout steps of the connection machine.
    connect_op: struct { host_idx: u8, stage: ConnectStage },
};
```

Every consensus task pushed into the SQ needs its completion context (the `session_id` it refers to), so everything goes
through the slotter: no new reserved `taskIdx` values are needed and `messages.zig` keeps its vocabulary. The invariants
of `slots.zig` (`max_capacity < messages.max_slot_capacity`, reserved indices) stay untouched.

### 2.5 The operation tract (combat mode), following Proto.

Preliminaries. Each index holds `state: u128` — the concat `(host_id: u8, index_id: u16, epoch_id: u40, index: u64)` of
`docs/shard-arch-hld.md`: the leading `index_id` lets the front extract the index service number straight from the id
(no side table) when routing `session_op`s. The state `index` takes its post-bump value — the easiest, equal to
`Session.upgrade_idx` — after a mutation of any session within this `(host_idx, index_idx)` is acked. A Create travels
through the consensus WITHOUT its id: after the op is acknowledged, the current (post-bump) state becomes the session's
`session_id`, and the fan-out slots plus the mirrors' bookkeeping are keyed by that future id (`Session.upgrade_idx`).
Consensuses pipeline freely — there is no cross-session serialization and no cap on in-flight consensuses per index: the
order the `IndexInbox` hands the ops in is canonical, they fan out through the SQ in that order, and the `seq_id` +
`ReorderBuffer` pair (2.6) delivers them to every mirror in exactly that order, so all mirrors decide the same sequence
without any per-index turn-taking. Within one session ops never overlap by contract: the client-server protocol is
half-duplex — a client waits for the explicit reply to its mutation before pushing the next one on the same session,
and distinct sessions are wholly independent of one another — so the `Session` state machine
(`ExpectOp -> ExpectConsensus -> ExpectAcceptedFlush -> ExpectReply`, one op in flight at a time — the reply-wait tail
growing out of the direct client write, the fourth state of the `shard-arch-hld.md` machine) mirrors exactly what the
wire contract already serializes: nothing needs to queue inside a session, and no locking is needed anywhere in the
tract.

1. The index received a `session_op` (or `create`): the `op` is applied to the session,
   `Session.state = .expect_consensus`, `prepareForNewConsensus()`, `Session.index_idx := idx.state` (the state at the
   moment the operation began); the op message carries the client endpoint — the fd and its tag (2.3) — which the
   session keeps for the reply.
2. `driver.expectOp(...)`: a `replicate_op` slot per mirror is taken from the slotter, an SQE send with
   `user_data = task_idx`. The session gets the "awaiting consensus" status.
3. CQ, `replicate_op`: success — just delete the slot; failure — `ConsensusProgress.rejected += 1`.
4. Mirror replies (the `mirror_recv` CQE): frame parsing (2.6) -> `dispatchExpectOp(host_idx, session_id, resp)` ->
   `updateSessionState`. Stale replies (the session's `index_idx` against the state at the time of the fan-out — "the
   lateness of replicas") are ignored; the epoch barrier of Proto is enforced here (a lesser epoch — a hard `Nack`, a
   greater one — abstention).
5. The quorum — the minimal majority of the replication factor, the own vote counted (2 for F = 3, 3 for F = 5, the
   single own vote for the local F = 1) — is reached: `Session.state = .expect_accepted_flush`, a `flush_op` slot is
   taken, an SQE write to the WAL.
6. CQ, `flush_op`: success/failure -> the reply goes out directly: a `reply_op` slot is taken, an SQE write lands on
   the client fd — the endpoint carried by the op message (2.3) — through the index's own ring, and
   `Session.state = .expect_reply`; on the `reply_op` completion `Session.state = .expect_op` (or, on `Close`, the index
   drops the session entry and pushes the front a complaint with the close code — so the front validates, marks the
   socket for the deferred close, and stops observing the client).

The monotone counters ride the same tract: the front +1 at the push of the op message (step 1 — every operation counted,
not just mutations), the owning index +1 wherever the op retires — the `reply_op` completion above, the complaint push
of a violation or a `Close`, the unknown-session handling below — never a -1, so the front's drain (2.3), the sum of
index counters against the front counter, never closes a socket under an op an index still holds.

`local` mode: steps 2-4 are skipped; `expectOp` moves the session straight to `expect_accepted_flush` + `flush_op`.

`Session.index_idx` is the index state at the moment the operation began: mirrors echo it back, and replies against an
outdated value are the "lateness of replicas" to ignore. `Session.upgrade_idx` is the future `index_idx`: the state
value the index takes once this operation is acked.

A protocol violation — a `session_op` arriving for a session that is not in `ExpectOp` — is handled with the same
hand-off: the index never writes to the faulty client itself. It logs right in the index,

```zig
logger.error("faulty client: protocol violation with mutation sent before the previous mutation resolved", .{
    .@"session-id": session.id,
    .@"session-details": session.diag(),
    .@"unexpected-mutation": op.string(),
});
```

pushes the complaint at once through a cross-task slot into the parent front's ring (2.3) — the complaint code, the
client fd, and the tag the op arrived with — and keeps processing incoming data: the flood stops by itself once the
front has marked the faulty client (the deferred close of 2.3). A validated complaint makes the front write the angry
error reply and mark the socket for the deferred close; an invalid one is a `Nop` (2.3). The session is parked in a
`violated` state carrying a wheel deadline (`wheel_idx`; T is `protocol_violation_replay`, 2.7 — `15s` by default):
everything arriving for it before the deadline meets the same log entry and one more complaint — the repeats are
idempotent, the front `Nop`s them once the socket is marked or gone — and on expiry the entry is dropped: a violator
whose socket still validates was closed by the front long before, and the expiry is the point where the stage-6 replay
(the compensation process) will take the session over once it exists.

A `session_op` naming an unknown `session_id` is its own cheaper case: there is no session to park and nothing to
compensate. The reaction is drawn by the config flag `unknown_session_is_fatal` (2.7), default `true`, its scope being
the unknown session alone: the protocol violation above is fatal for the connection unconditionally, no flag involved.
Fatal: the client is declared faulty and rides the complaint of 2.3 — the complaint carries the code and the offending
`session_id`, the front writes the angry reply `unknown session <session_id>` on validation, and the socket takes the
deferred close; the index writes nothing itself, so "the index never writes to a client it has declared faulty" holds
unconditionally. Not fatal: the connection survives, and the index makes the non-fatal reply itself — the cheap direct
angry write, the same `unknown session <session_id>` text, one `reply_op` SQE on the client fd, the message-deep reuse
window accepted on the grounds that the op message just delivered this very fd. The reply belongs to the index by the
dispatch rule of 2.3: a mistaken op is still a mutation the index serves, the pulse being the only request kind the
front keeps to itself, and the complaint channel stays reserved for the clients the index refuses to write to — so the
op retires through the ordinary reply path, the in-flight +1 landing with the `reply_op` completion like any other.

### 2.6 The wire frame (`docs/consensus-network-protocol.md`).

Canonical for the first codec: the multiplexed frame of the transport doc, with no immediate reply ever expected:

| `seq_id: u16` | `vector clock frame: (host_idx: u8, host_state: u128)` | `op tag` | `op payload` |
| ------------- | ------------------------------------------------------ | -------- | ------------ |

- `seq_id` is bound to a connection: a ring number (0..65535, wrapping) bumped by one per send. The kernel gives no
  cheap guarantee that the SQ order is the wire order (worker races), so the receiver re-orders through `ReorderBuffer`
  (`zigring/iouring.zig`); an actual reorder is about one event per hundreds of sends. A gap (`N+1` arrived, `N` did
  not) is a TCP connection error reported by the kernel; the bounded recvs on the mirror sockets surface it as an
  `errno` rather than a silent stall.
- The vector clock frame is a ringed delivery: each frame reports one host `idx` and the sender's known state for it,
  looping over the list of hosts — the vector clocks piggyback on regular traffic.
- The op vocabulary is the `Operation oneof` of the transport doc: `Create/Append/Overwrite/Repeat/Close`, `Ack/Nack`
  (their `Epoch u128` carries the responder's own epoch — the `epoch_id: u40` slice extracted from its `state: u128`,
  so an acknowledgement from a host the cluster decided is gone is discounted; the comparison implements the epoch
  barrier of 2.5 step 4: a lesser epoch — a hard `Nack`, a greater one — abstention), `Pulse` (the mirror-liveness op
  of the stage-6 background sync — not the client pulse of 2.3, which the front consumes), and the stage-6
  `Isolate/Compensate` plus the log/snapshot requests. `CommitResponse = Commited | Outdated SequenceID` of Proto rides
  as `Ack`/`Nack` on top of this frame.

### 2.7 Configuration (`src/config.zig`, `mpy6a.cfg`).

```zig
pub const BindType = struct {
    host: []const u8,
    port: u16,
};

replication: struct {
    /// The number of hosts in the shard. Must be a 2n + 1.
    factor: u8,
    mode: union(enum) {
        /// Single-host mode. The factor must be 1.
        local: void,
        cluster: struct {
            /// Other hosts' indexes connect via this port here: not a "user" port.
            bind: BindType,
            /// The length must match the factor.
            mirrors: []const BindType,
        },
    },
} = .{ .factor = 1, .mode = .local },

/// The time knobs are `Duration` values: no unit suffixes in the names,
/// the unit living in the value. The leaf lives in this module and carries
/// the arithmetic over its `nanos`; the positivity of the four values is
/// proven by `Config.validate`.
consensus_timeout: SiggyDuration = ...,
protocol_violation_replay: SiggyDuration = ...,
unknown_session_is_fatal: bool = true,
tick_interval: SiggyDuration = ...,
session_inactivity_timeout: SiggyDuration = ...,
```

In siggy text:

```text
host_index = 0
replication = {
    factor = 3
    mode = cluster {
        bind = { host = "10.0.0.1" port = 7001 }
        mirrors = {
            { host = "10.0.0.1" port = 7001 }
            { host = "10.0.0.2" port = 7001 }
            { host = "10.0.0.3" port = 7001 }
        }
    }
}
consensus_timeout = 3s
protocol_violation_replay = 15s
unknown_session_is_fatal = true
tick_interval = 50ms
session_inactivity_timeout = 30s
```

Notes: `host_index` must be smaller than the factor; `local` requires `factor = 1`; the quorum is not a knob — it is
the majority of the factor counting the own vote (2.5, step 5); `mirrors` lists one entry per host index (the own slot
is ignored), so a host dials only the entries with a greater index (2.3); `protocol_violation_replay` (default `15s`)
is the T of the `violated`-parking deadline of 2.5; `unknown_session_is_fatal` (default `true`) is the flag deciding
whether an unknown session is fatal for the client (the complaint path: the front replies, the socket takes the
deferred close) or not, the non-fatal pole being the index's own direct angry write, the protocol violation being fatal
for the connection unconditionally; `tick_interval` (default `50ms`) is the interval of the per-front tickers — the
front `f` arms its ticker `f * (tick_interval / Fno)` after the 1st, `Fno` a power of two by the config's own proof, so
the tick-driven scans against the socket entries never coincide (2.3); `consensus_timeout` (default `3s`) is the
acknowledgement deadline of a consensus round, feeding the TCP retry window clamp of 2.3; `session_inactivity_timeout`
(default `30s`) is the maximum inactivity interval of 2.3 — the deadline of both the index session wheels and the
front's socket sweep.

Every one of the four time knobs is a `Duration`: the unit lives in the value alone, so no `_sec`/`_ms` suffix
survives in any of the names, and the example writes the units out explicitly even where the bare number would read as
seconds. The leaf is `SiggyDuration` (`src/config.zig:437`, the siggy decoder owning the parse), its text the Go
`time.Duration` format ("30s", "50ms", "1m30s"; a bare number reading as seconds). The leaf lives in `config.zig` along
with `Duration`. The arithmetic the tract needs is the type's own: `Duration` is a struct over `nanos: i64`
(`src/config.zig:244`), so the scalar `*` and `/` of the stagger above and the deadline comparisons are plain
operations on that field, and every consumer converts to its integer unit (`nanos / unit.nanos`) once at startup. The
wheel's own tick unit is one `tick_interval`, and its tick count is no longer compiled in: `TimingWheel` now takes its
block shape — `N`, the payload slots per block, and `L`, the inline pool depth — at comptime and its tick count as a
runtime parameter of `init` (`error.InvalidTicks` unless a power of two in `1..2^20`), so the instantiator sizes the
ring at startup from the knobs: the largest deadline the wheel serves over `tick_interval` —
`session_inactivity_timeout` at the defaults, the violated-parking and consensus deadlines riding the same index wheel
— the quotient (`600` at the defaults) rounded up to a power of two (`1024`, the `init` validation demanding it) and
the nanos conversion rounded up (`(nanos + tick - 1) / tick`) so a deadline that is not a multiple of `tick_interval`
never expires early. The positivity of the four values is proven by `Config.validate` (`src/config.zig:620`): plain
checks in the house style of the `port`/`fronts` proofs around them, a named error each — a zero `tick_interval` would
divide by zero in the conversions above, a negative `session_inactivity_timeout` would arm a deadline in the past, a
negative `consensus_timeout` would feed a negative `TCP_USER_TIMEOUT`. Both wheels compile with modest, reasonable
defaults for their block shape `(N, L)`: the concrete figures are an implementation choice, likely to be revisited when
the socket scale or the deadline traffic demands it.

### 2.8 Files and modules touched by the integration.

| File                   | Action                                                                                                                                                                                                                                                                                                                                                                                        |
| ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `src/index.zig`        | `run` -> `Index` (controller), service loop, driver, CQ branches (`reply_op`), the complaint push, the non-fatal angry write, the monotone in-flight +1; the wheel instantiation, its tick count derived at startup                                                                                                                                                                            |
| `src/slots.zig`        | new `TaskCtx` branches (`reply_op` included)                                                                                                                                                                                                                                                                                                                                                  |
| `src/state.zig`        | bring `Session`/`WALOperation`/`Op`/`ConsensusResponse` to working: the `ExpectReply` phase, the client endpoint fields                                                                                                                                                                                                                                                                       |
| `src/wire.zig`         | new: the frame codec of 2.6                                                                                                                                                                                                                                                                                                                                                                   |
| `src/config.zig`       | `BindType`, `replication` (`factor`, `mode`, `bind`, `mirrors`), `consensus_timeout`, `protocol_violation_replay`, `unknown_session_is_fatal`, `tick_interval`, `session_inactivity_timeout` — the four time knobs `Duration`-valued (the leaf and its arithmetic live here; `Config.validate` proves the four values positive)                                                               |
| `src/messages.zig`     | no changes (consensus tasks are slotter-driven; the complaint rides `CrossTaskMessageIdx`)                                                                                                                                                                                                                                                                                                    |
| `src/cross_task.zig`   | the complaint variant of `CrossTask`: a code, the fd, the tag                                                                                                                                                                                                                                                                                                                                 |
| `src/lifetime.zig`     | handing `Index` into the index role; the shared socket bookkeeping arrays of 2.3 (the tags, the front counters, the columnar index counters)                                                                                                                                                                                                                                                  |
| `src/timing_wheel.zig` | the tick count moves from comptime to a runtime parameter of `init`, `error.InvalidTicks` the validation (already in the tree); the two instantiations of 2.3 derive their tick counts at startup, their block shape modest defaults                                                                                                                                                            |
| `src/front.zig`        | the replication listener: accept + greeting + cross-task fd routing to indexes; the request differentiation (the pulse consumed locally, the create by round robin, the session op by the id's `index_id` slice); the tag and front-counter bookkeeping, the mark/ticker/drain deferred close, the staggered per-front ticker with the `last tick` bumping, and the complaint reaction of 2.3    |

## 3. Order of execution (stages).

1. **Stage 0, skeleton**: the `Index` struct, moving the current loop into methods, `zig build test` green. No behavior
   change.
2. **Stage 1, sessions**: wiring the `state.zig` types (`ExpectReply` and the client endpoint fields included, 2.5),
   `verztable.HashMap`, the `create` branch stops closing the `fd` — the endpoint (fd + tag) lands in the session table
   of 2.1, the fd itself stays with the front — and the front grows the tag bookkeeping of 2.3 (the mint and the array;
   the in-flight counters arrive with the deferred close of stage 2) and the request differentiation: the pulse consumed
   at the front, the create passed via round robin, the in-session op routed by the `index_id` slice of its session id.
   `session_op` -> `Session.state` transitions.
3. **Stage 2, local mode**: the `flush_op` slot, a stub WAL (a plain append-only file; the real WAL design arrives as
   its own material — the restart epoch mechanics included — and is deferred), the `reply_op` slot and the direct client
   reply. The full tract in single-host mode. The complaint machinery of 2.5 lands here too; the compensation proper
   waits for stage 6. The deferred close lands here as well — the columnar counters (the tag and front-counter arrays,
   the per-index rows) with the monotone counting and the drain condition, the mark/ticker/drain — and the
   unknown-session reaction takes the `unknown_session_is_fatal` flag: the fatal pole rides the complaint path, the
   non-fatal pole is the index's own direct angry write. The tick machinery lands with the deferred close — the
   staggered per-front tickers, the `last tick` bumping (the absolute monotonic seconds), the tick relayed into the
   `IndexInbox` round-robin (one tick after another into `IndexInbox[0]`, `IndexInbox[1]`, ..., each carrying the front's
   current second) driving the index session wheels, and the front's own wheel sweeping its sockets — the
   maximum-inactivity knob being `session_inactivity_timeout` of 2.7, its value a `Duration` (the `SiggyDuration` leaf,
   now in `src/config.zig`) — the wheel and the sweep converting it to their integer tick units at startup over
   `nanos`, the wheels sized at runtime and the four values proven positive by `Config.validate`.
4. **Stage 3, driver interface**: the `ConsensusDriver` enum, the `local` implementation over stage 2 (verifying that
   "do not touch the reaction" holds).
5. **Stage 4, cluster**: `connectHosts`/the connection machine (2.3), `replicate_op`, `mirror_recv`,
   `dispatchExpectOp`, quorum counting, timeouts via the timing wheel, the TCP retry window clamp.
6. **Stage 5, protocol**: the wire codec of 2.6 — the frame (`seq_id`, the vector clock frame), the op vocabulary, the
   `ReorderBuffer` integration, `Ack`/`Nack` handling per the epoch barrier of Proto.
7. **Stage 6, the lost owner**: isolation/`Isolate`/`Compensate` (the compensation process the violated sessions of
   2.5 are handed to, and the replay the idle-expired sessions of 2.3 go into), leadership takeover, background
   vector-clock synchronization (the mirror `Pulse` exchange of 2.6, `RequestLog`/`RequestSnapshot`),
   `Restart/RestartIn`, and the log with its restart epoch. See 4 for what landed and what is stubbed.
8. **Stage 7, the logs of the shard**: the per-host replica logs (`docs/consensus.md`, "one host, one log"), the
   `Isolate` log command written to the own log, the real `RequestLog`/`RequestedLog` service over those logs, the
   restart recovery of the own log (its orphans to the replay, its commands re-applied), and the cluster-wide
   isolation decision as a quorum vote rather than one host's silence. See 5 for what landed and what is still
   stubbed.

Tests after each stage: `zig build test` (unit tests of the slots and the tract) plus a manual `local` run.

## 4. Stage 6 as implemented.

The stages above were executed in order against the code of this tree; this section records what stage 6 landed and
where the design of the deferred pieces is still open. Everything below is wired into the service loop and covered by
`zig build test`, with the honest stubs carrying the boundary of what exists.

### 4.1 The replay (`src/replay.zig`).

The compensation process of 2.3 and 2.5 is a plain synchronous call, `Index.replaySession(session id, second,
reason)`: the session leaves the live table (its wheel deadline is withdrawn) and one debt is recorded in a bounded
FIFO queue of the index — the session, the second it may start at, why it is owed (`violated`, `idle`, `restart_in`,
`restart`, `isolated`, `takeover`) and, for an adopted session, the successor id it continues under. A full queue drops
its oldest entry and counts the loss, the freshest evidence being the more useful one. The consumer that would play
the accumulated data does not exist: the sessions store no data yet, and the queue is the boundary of the stub.

### 4.2 The replicated state of a peer (`src/mirror.zig`).

`MirrorState` is the `MirrorState` record of docs/consensus.md, per host of the shard: `expected_epoch`, the log
pointer `current_idx`, the `active_map` of replicated sessions, the `isolated_fifo` of the batches an isolation pushed
out of the live set, and the `deferred_hooks` of the isolations whose boundary the replica has not reached. A hook
fires the moment a replicated operation advances the pointer past its boundary, so the batches land in the FIFO in the
order the isolations were decided. `captureHead(offset, head)` implements `Capture`: the head batch only, the offset
compared against the sessions already taken. Without replicated log records the pointer is the newest leader state seen
on the wire, not a byte offset of a log.

### 4.3 Isolation, compensation, takeover, restart.

- `Index.isolateHost(hostStateIdx)` raises the expected epoch of the carried host and moves its sessions at or below
  the boundary into the isolated FIFO (or defers the hook). It serves the own decision and an inbound `Isolate` alike;
  the own state is never isolated (a restarted host does that itself, docs/consensus.md).
- A peer that stays silent beyond `host_silence_timeout` is maintained on every relayed tick: when this index is
  current on the peer's state its sessions are adopted (leadership takeover) — renumbered into the own state, handed
  to the replay and the peer fenced in its next epoch — and when it is not, the peer is isolated at the newest state
  heard about it and the decision is replicated to the shard.
- `Compensate`/`Capture`: `Index.captureIsolated` takes up to `count` sessions off a host's head batch and records
  their replay debt with the carried delay. Nothing isolated yet and an outdated offset are refusals, never empty
  answers.
- `RestartIn(session, seconds)` records the debt with the delayed second; `Restart(minHostStateIdx)` runs the first
  session of the addressed host's list when the carried state was reached and is refused otherwise. Both pass the
  epoch barrier and are answered with `Ack`/`Nack`.
- The isolation as a *log command* is applied and replicated but not written to the own log: the log record of this
  build carries session mutations only, and the log command layout belongs to the WAL design that is still open.
  Stage 7 (5.2) defined the first command record and writes the decision to the own log.

### 4.4 The background synchronization (`Pulse`, `RequestLog`, `RequestSnapshot`).

Every relayed tick sends one `Pulse` frame per established mirror, carrying the vector clock pair of one host of the
shard and moving that host on with each tick, so the clocks of the whole shard ride the regular traffic. The pair of
*every* incoming frame is recorded. A peer reporting a third host ahead of what this index holds makes it ask that peer
for the missing log (`RequestLog`, one request per host and peer until the answer arrives, `RequestedLog` or
`RequestedLogNotAvailable` retiring it). A lagging index never takes a leader over: the takeover requires the two
states of the host to agree.

The stubs: the replicated logs are not kept, so `RequestLog` is answered with `RequestedLogNotAvailable(.out_of_date)`
and a received chunk advances nothing; there is no snapshot store, so `RequestSnapshot` is answered with an empty final
chunk naming the own state.

### 4.5 The log (`src/wal.zig`).

The flush of 2.5 step 5 writes a framed record — magic, length, CRC32, the session, the operation and the packed state
the operation upgrades to — to the own append-only log. On open, the log is scanned: the trustworthy prefix ends at the
first record that does not hold together, the rest is a torn tail and is truncated, and the restart epoch of
docs/consensus.md is the last recorded epoch plus one, zero for a log with no record (`Config.wal_path` keeps naming
the file, `""` disables it). The rest of the WAL design stayed open here: per-host replica logs, the log commands,
snapshots, compaction. Stage 7 (5.1, 5.2) landed the first two; snapshots and compaction remain.

### 4.6 Configuration.

`host_silence_timeout` (`Duration`, `10s` by default) joins the knobs of 2.7: the silence after which a mirror
connection is considered lost, which the takeover and the isolation both hang off. `Config.validate` proves it
positive along with the other time knobs.

### 4.7 What stage 6 leaves to its own material.

The compensation of data (there is none stored), the per-host replica logs, the log commands, snapshots, an actual
`RequestLog`/`RequestSnapshot` service, and the cluster-wide `Isolate` decision (a quorum vote rather than the local
silence heuristic used here). Stage 7 took the replica logs, the log commands, the real `RequestLog` service and the
quorum vote; the snapshots and the compensation consumer remain the open ones (5.6).

## 5. Stage 7 as implemented.

Stage 7 took the material 4.7 left behind: the logs of the shard are now kept, served and read back, and the
isolation is a decision of the shard rather than of one host. Everything below is wired into the service loop and
covered by `zig build test`, with the honest stubs marking where a design of its own is still missing.

### 5.1 The replica logs (`src/wal.zig`).

`wal.ReplicaLog` is the per-host log of docs/consensus.md: one framed append-only file per host index, opened at
`<wal_path>.<index>.<host>` (`""` keeps none, the own host's slot is unused). It shares the record layout, the
checksum and the torn-tail scan of the own log; `append` writes one entry synchronously (a replica record is not on
a client's path, and the asynchronous completion path of these logs belongs to the rest of the WAL design) and keeps
`last_state`, the pointer of the replica.

`applyMirrorRequest` writes every replicated mutation into the log of its leading host before the in-memory
`MirrorState` takes it, so the log is the durable copy of what the replica holds. `readAfter(state, buffer)` walks
a log from a state and fills whole records only, `final` saying whether the trustworthy prefix ended or the buffer
filled first; the order across an epoch change is `(epoch, index)`, a restarted host continuing its log in the next
epoch at index zero.

### 5.2 The log commands.

The record's op byte now has two namespaces: a session mutation of `state.Op` and a command from `command_base`
(`0x80`). The first command is `Isolate`, carrying the boundary of the lost host's log and the state the decision was
taken at. The decision of 5.5 writes it through the ring (`log_command` in `TaskCtx`) into the own log, so the
isolation survives a restart with the log that produced it.

`Isolate` is the first command of the log; `Restart`, `RestartIn` and the vector-clock requests still travel as
commands of the wire only, and their log record layout waits for whatever the WAL design decides a command needs.

### 5.3 The log service (`RequestLog`/`RequestedLog`).

`answerLogRequest` answers the requested position from this index' own log when the host is this one and from the
replica log of that host otherwise. The chunk is bounded by `wire.max_data`, carries whole records, and is `final`
when the end of the trustworthy prefix was reached. A log this build does not keep is answered with
`RequestedLogNotAvailable(.out_of_date)`, never with invented data; a log that exists but holds nothing after the
position is an empty final chunk, which is the truthful answer.

`applyRequestedLog` does the other half: every record of a chunk is appended to the local replica log of its host
and applied to that host's replica state (a mutation advances a session, an `Isolate` applies the isolation), the
vector clock moves to the last record, and a non-final chunk asks the same peer for the next one. A chunk that does
not hold together retires the request instead of applying half of it.

The service walks a log per request: there is no offset index over the files yet, and no compaction, so
`out_of_date` only names a log this build does not keep at all. Both are the WAL design's own material.

### 5.4 The restart recovery.

`Index.recover` reads the own log of the previous runs at startup. Every mutation of this host in an epoch older
than the recovered one is an orphan: the session lands in the replay queue with `reason = .restart`, one entry per
session whatever number of records it left. Every `Isolate` command is applied again, which restores the fence of
the host it named, so the shard's past decisions are not forgotten by a reboot. The replay consumer that would
actually play the data still does not exist, the sessions storing none: the debt is the boundary of this stub, as in
4.1.

### 5.5 The cluster-wide isolation vote.

`initiateIsolate` no longer isolates on its own silence heuristic. It opens a vote at the newest state heard about
the peer, counts the own vote, and sends `IsolateProposal` to every established mirror; a proposal needs the quorum
of `quorumOf` (2 of 3, 3 of 5) to survive, and a vote that cannot reach it at send time is refused outright, exactly
like a takeover without the current state. The answer rides the ordinary `Ack`/`Nack` through the epoch barrier,
with the boundary in place of the session; when the quorum approves, `decideIsolate` fences the peer, hands its
sessions to the isolated FIFO, replicates the `Isolate` command and writes it to the own log. A vote no one answers
is withdrawn by `consensus_timeout` on the index wheel, and a refused or unanswered vote keeps the host out of the
vote for one more window (`vote_backoff`), so a shard that cannot decide is asked once per window rather than on
every tick; the next silent tick past the window starts a fresh one.

The receiving side of a proposal only votes, and only when it knows the boundary state and the boundary is not its
own state; the decision itself arrives as the `Isolate` command of 4.3, so no single viewpoint can fence a healthy
host. The vote is not written to a log before its outcome: a proposal is a transient of the wheel, only the decision
is durable.

### 5.6 What stage 7 leaves to its own material.

The compensation of data (still none stored), the snapshot store (`RequestedSnapshot` remains the empty final chunk
naming the own state), compaction and an offset index over the logs, the `Restart`/`RestartIn` log records, and a
proposal's own persistence (a crash mid-vote forgets the vote, not the decision).
