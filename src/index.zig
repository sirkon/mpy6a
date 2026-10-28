//! Index thread: consensus-side worker and child of one front.
//!
//! An index owns one `IndexInbox` (its LLQ) and one io_uring ring. Phase A
//! (ring, inbox, `INITIALIZED`) is handled by `lifetime.Controller.runThread`;
//! this file owns everything after that: the service loop, routing of accepted
//! sessions and the shutdown choreography from docs/startup-en-reworked.md.
//!
//! The service loop lives on the `Index` controller of
//! designs/CONSENSUS-PLAN.md: it carries the consensus driver, the session
//! table, the index state and the timing wheel. The `local` driver completes
//! the stage-2 tract; the `cluster` one drives the stage-4 connection machine
//! over the stage-5 codec of `wire.zig`: the ring-numbered frames are put back
//! in order by a `ReorderBuffer` per mirror (2.6), and every answer passes the
//! epoch barrier of docs/consensus.md before it counts.

const std = @import("std");
const posix = std.posix;
const zigring = @import("zigring");
const verztable = @import("verztable");
const config = @import("config.zig");
const lifetime = @import("lifetime.zig");
const idxinbox = @import("index_inbox.zig");
const messages = @import("messages.zig");
const logging = @import("logging.zig");
const slots = @import("slots.zig");
const state = @import("state.zig");
const cross_task = @import("cross_task.zig");
const reply = @import("reply.zig");
const timing_wheel = @import("timing_wheel.zig");
const wire = @import("wire.zig");
const mirror = @import("mirror.zig");
const replay = @import("replay.zig");
const wal = @import("wal.zig");

/// The client endpoint every session-bearing message carries: the descriptor
/// value and the tag the front minted for it (2.3). The session keeps the
/// pair for the operation in flight; the descriptor itself stays with the
/// front, which owns the socket's lifecycle.
pub const Endpoint = struct {
    fd: posix.fd_t,
    tag: usize,
};

/// One operation on an already established session.
pub const SessionOp = struct {
    endpoint: Endpoint,
    session_id: u128,
    op: state.Op,
};

/// A message that a front pushes into an index inbox.
pub const FrontMessage = union(enum) {
    /// Open a session for a freshly accepted client socket. The create is the
    /// first operation of the session, so its id is the post-bump index state.
    create: Endpoint,
    /// An operation on an already established session.
    session_op: SessionOp,
    /// The parent front is draining: stop taking new sessions and report to
    /// the parent once this index has no sessions left.
    shutdown_soft: void,
    /// Stop now: close everything and report.
    shutdown_hard: void,
    /// A tick relayed by the parent front (2.3): the front's current absolute
    /// second, the same base the socket `last tick` fields hold. It is the
    /// index' own clock, so no epoch of any front travels anywhere.
    tick: u32,
};

/// The inbound queue type shared by fronts and indexes.
pub const Inbox = idxinbox.IndexInbox(FrontMessage);

const LoopConfig = idxinbox.LoopConfig;

/// Session data of one index, keyed by the session id.
///
/// The key is a `u128` and verztable's automatic integer hash cuts it to 64
/// bits (it panics rather than truncate), so the id is folded by hand
/// (`state.hashSession`): both halves carry identity, the `index_id` slice in
/// the high one above all.
pub const SessionTable = verztable.HashMapWithFns(u128, state.Session, state.hashSession, state.eqlSession);

/// Expiry wheel of the index: repeat and pulse deadlines, the consensus round
/// deadline and the parked-violation deadline.
pub const Wheel = timing_wheel.TimingWheel(8, 4);

/// The wheel ticks a duration spans, rounded up so a deadline that is not a
/// multiple of `tick_interval` never expires early (2.7).
pub fn ticksOf(nanos: u64, tick_ns: u64) u32 {
    std.debug.assert(tick_ns > 0);
    return @intCast((nanos + tick_ns - 1) / tick_ns);
}

/// The tick count of an index wheel: the largest deadline it serves over the
/// tick interval, rounded up to a power of two (2.7). Both values are proven
/// positive by `Config.validate`.
pub fn wheelTicks(deadline_ns: i64, tick_ns: i64) u32 {
    std.debug.assert(deadline_ns > 0 and tick_ns > 0);
    const quotient = ticksOf(@intCast(deadline_ns), @intCast(tick_ns));
    const rounded = std.math.ceilPowerOfTwo(u64, @max(quotient, 1)) catch Wheel.MAX_TICKS;
    return @intCast(@min(rounded, Wheel.MAX_TICKS));
}

/// The configured duration in whole seconds, rounded up so a deadline never
/// expires early. Shared with the front, whose socket sweep prices against the
/// same knob (2.3).
pub fn durationSeconds(nanos: i64) u32 {
    const ns: u64 = @intCast(nanos);
    const per_s: u64 = std.time.ns_per_s;
    return @intCast((ns + per_s - 1) / per_s);
}

/// The wheel ticks from this instant to the absolute second `due`, at least
/// one so an overdue entry still matures on the next turn and never early.
/// The wheel is sized by the longest deadline it serves, so a deadline placed
/// this way lands in its own stripe instead of waiting out a full round (2.7).
fn ticksUntil(due: u32, ticks_per_second: u32) u32 {
    const seconds: i64 = @as(i64, due) - @as(i64, currentSecond());
    const positive: u64 = @intCast(@max(seconds, 1));
    return @intCast(@min(positive * ticks_per_second, Wheel.MAX_TICKS));
}

/// The absolute monotonic second of this instant: the base of every deadline
/// and of the `last tick` a socket carries (2.3). The same clock the front
/// relays, so an index never converts between epochs.
fn currentSecond() u32 {
    return @intCast(zigring.nowNs() / std.time.ns_per_s);
}

/// Opens the replica log of one host index: `<wal_path>.<index>.<host>`, the
/// per-host log of stage 7. The own host's slot and an empty `wal_path` keep no
/// log, and a file that cannot be opened is reported and left disabled.
fn openReplicaLog(
    allocator: std.mem.Allocator,
    log: *logging.Logger,
    wal_path: []const u8,
    index_id: u16,
    host: u8,
    own: u8,
) wal.ReplicaLog {
    if (wal_path.len == 0 or host == own) return .{};

    const path = std.fmt.allocPrint(allocator, "{s}.{d}.{d}", .{ wal_path, index_id, host }) catch |err| {
        log.warn("could not name a replica log", .{ .host_idx = host, .err = @errorName(err) });
        return .{};
    };
    defer allocator.free(path);

    return wal.ReplicaLog.open(allocator, path) catch |err| {
        log.warn("could not open a replica log, mirroring it in memory", .{
            .host_idx = host,
            .path = path,
            .err = @errorName(err),
        });
        return .{};
    };
}

/// The largest shard the connection machine serves: `replication.factor` is a
/// `u8` (2.7), so one fixed array per host index covers every configuration.
pub const max_hosts = 256;

/// Bytes a mirror receive accumulates before a whole record is available: room
/// for a few frames of the codec of `wire.zig` (2.6), so a burst of small ops
/// and one full-size frame both complete.
pub const mirror_recv_capacity = 4 * wire.max_frame_len;

/// The reorder window of one mirror connection, a power of two far below the
/// 2^16 ring span (2.6). A frame that arrives more than this ahead of the
/// missing one is not a reorder anymore: the connection is dropped.
pub const reorder_window = 64;

/// The quorum of a shard: the minimal majority of the replication factor, the
/// own vote counted (2.5 step 5): 2 for 3, 3 for 5, the single own vote for 1.
pub fn quorumOf(factor: u8) u32 {
    return @as(u32, factor) / 2 + 1;
}

/// One deadline entry of the index wheel (2.3). The value stored in the wheel
/// is the `token` this entry is keyed by; the handle is kept here so an armed
/// deadline can be withdrawn when the session or the connection moves on, and
/// the due second so a deadline shorter than one wheel round never expires
/// early.
const Deadline = struct {
    handle: u64,
    due_second: u32,
    /// What the deadline is about: a session's inactivity or parked violation,
    /// the retry of a mirror connection, or a connect that is in flight.
    target: union(enum) {
        session: u128,
        mirror: u8,
        dial: u8,
        /// An isolation vote waiting for the shard's answers (stage 7).
        proposal: u8,
    },
};

/// One isolation vote this index initiated (stage 7): the boundary of a lost
/// host's log waiting for the shard's approval, the answers so far and the
/// second the vote opened. The own vote is counted from the start.
const Proposal = struct {
    boundary: u128,
    accepted: u16,
    rejected: u16,
    /// The peers that were asked and have not answered yet.
    outstanding: u16,
    /// The peers the vote was sent to: an answer from anyone else is not part
    /// of this vote and cannot move it.
    asked: std.StaticBitSet(max_hosts) = std.StaticBitSet(max_hosts).empty,
    second: u32,
};

/// How many sessions of one isolated batch a capture hands to the replay in
/// one go. The batch itself is bounded by the isolation window of the peer.
const capture_batch = 64;

/// How many replicated sessions a leadership takeover adopts in one pass.
const takeover_batch = 64;

/// What this index knows about one host of the shard (stage 6): the newest
/// state it heard of and the state it actually holds. A takeover requires the
/// two to agree, so a lagging replica never claims a lost leader's sessions.
const HostSync = struct {
    /// The newest state of that host heard on the wire.
    known: u128 = 0,
    /// The state of that host this index holds.
    applied: u128 = 0,
    /// Whether a log request for the missing state is in flight.
    pending: bool = false,
};

/// The consensus driver: the decision procedure between the single-host
/// `local` mode and the combat `cluster` mode. All state lives on `Index`; the
/// driver only decides, the reaction stays in `Index.updateSessionState` (2.2).
pub const ConsensusDriver = enum {
    /// Single-host mode: the own vote is the whole quorum.
    local,
    /// Combat mode: mutations are replicated to the shard's mirrors.
    cluster,

    /// The driver of the configured shard (2.7).
    pub fn fromConfig(cfg: *const config.Config) ConsensusDriver {
        return switch (cfg.replication.mode) {
            .local => .local,
            .cluster => .cluster,
        };
    }

    /// Establishes the mirror connections of `cluster` mode (2.3): every host
    /// index of the shard the own host dials, that is every greater index.
    /// The greater side never connects back; it reuses the socket of the pair.
    pub fn connectHosts(self: ConsensusDriver, idx: *Index) !void {
        switch (self) {
            // There are no mirrors to connect to in single-host mode.
            .local => {},
            .cluster => {
                const cfg = idx.ctrl.cfg;
                const mirrors = cfg.replication.mode.cluster.mirrors;
                const own = idx.ownHost();
                var host: u8 = 0;
                while (host < cfg.replication.factor) : (host += 1) {
                    if (!Index.dialsMirror(own, host)) continue;
                    try idx.dialMirror(host, mirrors[host]);
                }
            },
        }
    }

    /// Records a mirror connection whose greeting has been validated: the
    /// accepting side learns the socket from the front, the dialling side from
    /// its own greeting exchange (2.3).
    pub fn connectionEstablished(self: ConsensusDriver, idx: *Index, host_idx: u8, fd: posix.fd_t) void {
        switch (self) {
            // Single-host mode has no mirror sockets. A descriptor handed over
            // anyway serves no peer, and the hand-off made it the index' own,
            // so the stub releases it instead of leaking it.
            .local => {
                idx.log.warn("mirror connection handed to a local index", .{
                    .ring_idx = idx.indexIdx().ring_idx,
                    .host_idx = host_idx,
                    .fd = fd,
                });
                _ = std.os.linux.close(fd);
            },
            .cluster => idx.establishMirror(host_idx, fd),
        }
    }

    /// Starts the consensus round of `op` for one session (2.5 step 2).
    pub fn expectOp(self: ConsensusDriver, idx: *Index, session_id: u128, op: state.Op) void {
        switch (self) {
            // The own vote is the whole quorum, so the round is over the
            // moment it starts: the session skips the replica reactions and
            // goes straight to the flush of 2.5 step 5.
            .local => idx.updateSessionState(session_id, .{ .op_acknowledged = op }),
            // One `replicate_op` per mirror; the own vote needs no message.
            .cluster => idx.startReplication(session_id, op),
        }
    }

    /// Feeds one mirror's answer back into the session's consensus progress
    /// (2.5 step 4).
    pub fn dispatchExpectOp(self: ConsensusDriver, idx: *Index, host_idx: u8, session_id: u128, resp: state.ConsensusResponse) void {
        switch (self) {
            // Single-host mode has no mirror answers.
            .local => {},
            .cluster => idx.applyMirrorAnswer(host_idx, session_id, resp),
        }
    }
};

/// The session reactions a driver can trigger (2.2). The driver owns the
/// decision, the reaction lives on the controller, so the `local` driver drives
/// exactly the stage-2 tract.
pub const SessionUpdate = union(enum) {
    /// The quorum acknowledged the operation in flight (2.5 step 5).
    op_acknowledged: state.Op,
};

/// The index controller: its ring, its inbox and everything the consensus
/// tract will need.
pub const Index = struct {
    const Self = @This();

    /// Process-wide shared state: rings, inboxes and cross-task slots.
    ctrl: *lifetime.Controller,
    /// The role this thread derived from its `ring_idx`; always `.index`.
    role: lifetime.Role,
    /// The index' own ring.
    ring: *lifetime.RingStuff,
    /// The inbound queue shared with the parent front.
    inbox: *Inbox,
    /// The thread's logger.
    log: *logging.Logger,

    /// The consensus mode of this index.
    driver: ConsensusDriver,
    /// Session data, keyed by the session id.
    sessions: SessionTable,
    /// The index state `(host_id, index_id, epoch_id, index)` as a `u128`.
    state: u128,
    /// Deadlines: repeat and pulse, consensus rounds, parked violations.
    wheel: *Wheel,
    /// Scratch buffer of the wheel's matured sets. The wheel grows it as the
    /// block shape demands; the index keeps the last allocation.
    wheel_scratch: []u64,
    /// The absolute second of the inactivity deadline, converted once at
    /// startup from `session_inactivity_timeout`.
    inactivity_secs: u32,
    /// The tick interval of this index' wheel, in nanoseconds, converted once
    /// at startup (2.7).
    tick_ns: u64,
    /// How many wheel ticks one second spans, rounded up. A deadline of D
    /// seconds is scheduled D of these ahead of the cursor, so it matures at
    /// its own second rather than after a full wheel round (2.7).
    ticks_per_second: u32,
    /// The armed session deadlines of the wheel, keyed by their token. The
    /// wheel carries the token as its value, this table the session it names.
    deadlines: verztable.HashMap(u64, Deadline),
    /// Monotone source of deadline tokens: a token is never reused, so a
    /// matured value cannot name a younger deadline.
    deadline_serial: u64,
    /// The log of this host (stage 6): the framed append-only file every flush
    /// writes to, and the restart epoch read back from it.
    wal: wal.Wal,
    /// The replica logs of the shard (stage 7): one framed file per host index,
    /// keyed like `mirrors`. The own slot and the logs this build does not keep
    /// stay disabled.
    replica_logs: []wal.ReplicaLog,
    /// The isolation votes of this index (stage 7), one per target host.
    proposals: [max_hosts]?Proposal,
    /// The wheel tokens of the vote deadlines.
    proposal_tokens: [max_hosts]?u64,
    /// The second before which no new isolation vote is opened for a host: a
    /// shard that cannot decide is not asked on every tick (stage 7).
    vote_backoff: [max_hosts]u32,
    /// Completions the index tracks on its own ring.
    slots: slots.RingSlots,

    /// The mirror sockets of `cluster` mode, indexed by host index (2.3). The
    /// own slot and every host this index does not talk to stay `-1`.
    mirror_fds: [max_hosts]posix.fd_t,
    /// Where each host index is in the connection machine of 2.3.
    connect_state: [max_hosts]slots.ConnectStage,
    /// The wheel token of a parked mirror retry, null when none is armed.
    connect_tokens: [max_hosts]?u64,
    /// The wheel token of a connect in flight (2.3), null when none is armed.
    /// A connect that neither succeeds nor fails within `consensus_timeout` is
    /// abandoned by the wheel and the machine starts over at the retry.
    dial_tokens: [max_hosts]?u64,
    /// Whether a receive is currently armed on the mirror socket, so a second
    /// one is never pushed on the same descriptor.
    recv_armed: [max_hosts]bool,
    /// The `seq_id` of the next frame sent to each mirror (2.6).
    send_seq: [max_hosts]u16,
    /// The absolute sequence index of the next frame expected from each mirror
    /// (2.6): the ring number of the frame maps onto it through
    /// `wire.absoluteSeq`, the wrap included.
    recv_seq: [max_hosts]u64,
    /// The reorder window of each established mirror (2.6), null while no
    /// connection runs.
    reorder: [max_hosts]?zigring.ReorderBuffer,
    /// The epoch each host is expected to speak in, the baseline of the epoch
    /// barrier of docs/consensus.md. Only an isolation or a takeover raises
    /// one, so every entry starts at zero.
    expected_epoch: [max_hosts]state.EpochId,
    /// Bytes accumulated in front of the armed receive of each mirror: a
    /// record split over two completions is completed here.
    recv_len: [max_hosts]u32,
    /// The greeting of each mirror connection, kept alive for as long as the
    /// kernel reads it from the send.
    greetings: [max_hosts][wire.greeting_len]u8,
    /// The receive buffers: one per mirror, borrowed by its armed receive.
    recv_bufs: [max_hosts][mirror_recv_capacity]u8,

    /// The replicated state of every host of the shard, the `MirrorState` of
    /// docs/consensus.md, one entry per host index. The own entry exists so a
    /// host number is never translated, and stays unused.
    mirrors: []mirror.MirrorState,
    /// The vector clock of the shard (stage 6): what this index heard about
    /// each host and what it holds, one entry per host index.
    sync: []HostSync,
    /// The host index the next background pulse reports (2.6): the vector
    /// clock pair loops over the shard with every tick.
    pulse_turn: u8,
    /// The silence after which a peer is considered lost, converted once at
    /// startup from `host_silence_timeout` (stage 6).
    silence_secs: u32,
    /// What is owed to the replay: the sessions that lost their owner and the
    /// second each may start at (stage 6).
    replay: replay.Queue,

    /// Service-loop bookkeeping; it does not outlive one pass of the loop. The
    /// session table itself is the count of live sessions.
    const LoopState = struct {
        draining: bool = false,
    };

    /// Allocates the per-index resources in place. The caller must not copy the
    /// initialized controller.
    pub fn init(self: *Self, ctrl: *lifetime.Controller, role: lifetime.Role, log: *logging.Logger) !void {
        const allocator = ctrl.allocator;

        // The log comes first: the restart epoch of docs/consensus.md is the
        // last epoch written to it plus one, and this run works in that epoch.
        // A log that cannot be opened records no flush and keeps the epoch at
        // zero, exactly as the stage-2 stub did.
        var host_wal = wal.Wal.open(allocator, ctrl.cfg.wal_path) catch |err| failed: {
            log.warn("could not open the log, flushes will not be recorded", .{
                .ring_idx = role.ringIdx(),
                .path = ctrl.cfg.wal_path,
                .err = @errorName(err),
            });
            break :failed wal.Wal{};
        };
        errdefer host_wal.close();

        const shard_size: usize = @max(@as(usize, ctrl.cfg.replication.factor), 1);
        const mirrors = try allocator.alloc(mirror.MirrorState, shard_size);
        errdefer allocator.free(mirrors);
        var opened: usize = 0;
        errdefer for (mirrors[0..opened]) |*peer| peer.deinit();
        while (opened < shard_size) : (opened += 1) {
            mirrors[opened] = mirror.MirrorState.init(allocator);
        }

        const sync = try allocator.alloc(HostSync, shard_size);
        errdefer allocator.free(sync);
        @memset(sync, .{});

        // The replica logs of the shard (stage 7): the operations of every
        // other leader this index mirrors, one file per host index. An empty
        // `wal_path` keeps none, and a log that cannot be opened is reported
        // and left disabled.
        const own = @as(u8, @truncate(ctrl.cfg.host_index));
        const replica_logs = try allocator.alloc(wal.ReplicaLog, shard_size);
        errdefer allocator.free(replica_logs);
        var opened_logs: usize = 0;
        errdefer for (replica_logs[0..opened_logs]) |*replica| replica.close();
        while (opened_logs < shard_size) : (opened_logs += 1) {
            replica_logs[opened_logs] = openReplicaLog(
                allocator,
                log,
                ctrl.cfg.wal_path,
                role.index.inbox_idx,
                @intCast(opened_logs),
                own,
            );
        }

        // The state a session id is cut from: this index service of this host,
        // in the epoch this run recovered from the log, with an empty op
        // counter (2.5).
        const initial = state.IndexState{
            .host_id = own,
            .index_id = role.index.inbox_idx,
            .epoch_id = host_wal.epoch,
            .index = 0,
        };
        const initial_state = initial.pack();

        self.* = .{
            .ctrl = ctrl,
            .role = role,
            .ring = &ctrl.rings[role.index.ring_idx],
            .inbox = &ctrl.inboxes[role.index.inbox_idx],
            .log = log,
            .driver = ConsensusDriver.fromConfig(ctrl.cfg),
            .sessions = SessionTable.init(allocator),
            .state = initial_state,
            .wheel = undefined,
            .wheel_scratch = &.{},
            .inactivity_secs = durationSeconds(ctrl.cfg.session_inactivity_timeout.value.nanos),
            .tick_ns = @intCast(ctrl.cfg.tick_interval.value.nanos),
            .ticks_per_second = ticksOf(std.time.ns_per_s, @intCast(ctrl.cfg.tick_interval.value.nanos)),
            .deadlines = verztable.HashMap(u64, Deadline).init(allocator),
            .deadline_serial = 0,
            .wal = host_wal,
            .replica_logs = replica_logs,
            .proposals = @splat(null),
            .proposal_tokens = @splat(null),
            .vote_backoff = @splat(0),
            .slots = undefined,
            // No mirror is connected until the connection machine of 2.3
            // dials one or a front hands one over.
            .mirror_fds = @splat(-1),
            .connect_state = @splat(.waiting_connect),
            .connect_tokens = @splat(null),
            .dial_tokens = @splat(null),
            .recv_armed = @splat(false),
            .send_seq = @splat(0),
            .recv_seq = @splat(0),
            .reorder = @splat(null),
            .expected_epoch = @splat(0),
            .recv_len = @splat(0),
            .greetings = undefined,
            .recv_bufs = undefined,
            .mirrors = mirrors,
            .sync = sync,
            .pulse_turn = 0,
            .silence_secs = durationSeconds(ctrl.cfg.host_silence_timeout.value.nanos),
            .replay = .{},
        };

        // The own host of the vector clock starts at the state of this run. A
        // host index outside the shard is a configuration the validator
        // refuses; the guard only keeps the array sound.
        if (own < self.sync.len) {
            self.sync[own].known = initial_state;
            self.sync[own].applied = initial_state;
        }

        errdefer self.sessions.deinit();
        errdefer self.deadlines.deinit();
        try self.slots.init(allocator, ctrl.cfg.ring_slots_capacity);
        errdefer self.slots.deinit();
        self.wheel = try Wheel.init(allocator, wheelTicks(
            ctrl.cfg.session_inactivity_timeout.value.nanos,
            ctrl.cfg.tick_interval.value.nanos,
        ));
        errdefer self.wheel.deinit();

        if (self.wal.truncated != 0) {
            self.log.warn("the log had a torn tail, it was dropped", .{
                .ring_idx = role.ringIdx(),
                .dropped = self.wal.truncated,
                .epoch = @as(u64, self.wal.epoch),
            });
        }
        for (self.replica_logs, 0..) |replica, host| {
            if (replica.truncated == 0) continue;
            self.log.warn("a replica log had a torn tail, it was dropped", .{
                .ring_idx = role.ringIdx(),
                .host_idx = host,
                .dropped = replica.truncated,
            });
        }

        // The own log of the previous runs is read back: its orphans and its
        // isolation decisions are the state this run starts from (stage 7).
        self.recover();
    }

    /// Releases the resources `init` allocated. The ring and the inbox stay
    /// with the controller, which owns them independently of this object.
    pub fn deinit(self: *Self) void {
        self.closeMirrors();
        var host: u16 = 0;
        while (host < max_hosts) : (host += 1) self.closeReorder(@intCast(host));
        self.wal.close();
        for (self.replica_logs) |*replica| replica.close();
        self.ctrl.allocator.free(self.replica_logs);
        for (self.mirrors) |*peer| peer.deinit();
        self.ctrl.allocator.free(self.mirrors);
        self.ctrl.allocator.free(self.sync);
        if (self.wheel_scratch.len != 0) self.ctrl.allocator.free(self.wheel_scratch);
        self.wheel.deinit();
        self.slots.deinit();
        self.deadlines.deinit();
        self.sessions.deinit();
    }

    /// Reads the own log of the previous runs back (stage 7, docs/consensus.md):
    /// the sessions of an older epoch are this host's orphans and go to the
    /// replay, and every `Isolate` command fences the host it names again. The
    /// consumer that plays the data does not exist yet, so a recovered session
    /// is a debt in the replay queue, exactly like a violated one (2.5).
    fn recover(self: *Self) void {
        if (!self.wal.enabled()) return;

        var seen = verztable.HashMapWithFns(u128, u128, state.hashSession, state.eqlSession)
            .init(self.ctrl.allocator);
        defer seen.deinit();

        const own = self.ownHost();
        var offset: u64 = 0;
        var commands: u32 = 0;
        while (wal.entryAt(self.wal.fd, offset) catch null) |entry| {
            offset += wal.record_len;
            switch (entry) {
                .mutation => |record| {
                    // Only this host's own mutations are its orphans, and only
                    // an older epoch's: the epoch the log carries tells them
                    // apart from the run that is starting.
                    const leader = state.IndexState.unpack(record.session_id);
                    if (leader.host_id != own or leader.epoch_id >= self.wal.epoch) continue;
                    seen.put(record.session_id, record.upgrade_idx) catch continue;
                },
                .isolate => |command| {
                    commands += 1;
                    _ = self.isolateHost(command.host_state);
                },
            }
        }

        var it = seen.iterator();
        while (it.next()) |bucket| {
            self.replay.push(.{
                .session_id = bucket.key,
                .at = currentSecond(),
                .reason = .restart,
                .host_idx = own,
                .successor = 0,
            });
        }

        if (seen.count() != 0 or commands != 0) {
            self.log.warn("the own log of a previous run was read back", .{
                .ring_idx = self.indexIdx().ring_idx,
                .sessions = seen.count(),
                .commands = commands,
                .epoch = @as(u64, self.wal.epoch),
            });
        }
    }

    /// Runs the service loop to completion. It ends when a shutdown demand has
    /// been satisfied.
    pub fn run(self: *Self, logger: *lifetime.LoggerStuff) void {
        const id = self.indexIdx();
        self.log.info("index started", .{ .ring_idx = id.ring_idx, .inbox = id.inbox_idx });

        if (self.driver == .cluster) {
            // Stage 4: the mirrors are dialled here, the accepting side having
            // handed its sockets over already (2.3).
            self.log.info("cluster consensus driver: dialling the shard", .{
                .ring_idx = id.ring_idx,
                .factor = self.ctrl.cfg.replication.factor,
                .own_host = self.ownHost(),
            });
        }
        self.driver.connectHosts(self) catch |err| {
            self.log.err("index could not connect to its mirrors", .{
                .ring_idx = id.ring_idx,
                .err = @errorName(err),
            });
            std.process.exit(1);
        };

        const cfg = LoopConfig{};
        var loop = LoopState{};

        while (true) {
            const batch = self.inbox.batch(cfg.batch_k, cfg.batch_k) orelse {
                self.inbox.hang(cfg);
                continue;
            };

            // The CQ is strictly drained before the inbound queue.
            while (batch.ring.popCQE()) |cqe| self.handleCqe(logger, cqe);
            batch.ring.commit() catch |err| {
                self.log.err("index CQ commit failed", .{ .ring_idx = id.ring_idx, .err = @errorName(err) });
                std.process.exit(1);
            };

            while (batch.front.next()) |task| {
                if (self.handleTask(&loop, task)) return;
            }

            // A soft shutdown may have been requested while the last session
            // was still open; once it closes, the index is done.
            if (loop.draining and self.sessions.count() == 0) {
                self.reportDrained();
                return;
            }
        }
    }

    /// The reaction door of the driver (2.2): the decision arrives here and
    /// moves the session, the driver itself never touches the tract.
    pub fn updateSessionState(self: *Self, session_id: u128, update: SessionUpdate) void {
        const session = self.sessions.getPtr(session_id) orelse return;
        switch (update) {
            .op_acknowledged => |op| {
                // A reaction for an operation that is no longer in flight is
                // a straggler and is ignored (2.5 step 4).
                if (session.state != .ExpectConsensus or session.op != op) return;
                // Step 5 of 2.5: the quorum is reached, the operation goes to
                // the log.
                self.beginFlush(session_id);
            },
        }
    }

    /// The host index of this process (2.7).
    fn ownHost(self: *const Self) u8 {
        return @truncate(self.ctrl.cfg.host_index);
    }

    /// The epoch this host works in: the `epoch_id` slice of its state, widened
    /// for the `Epoch u128` field of an answer (2.6).
    fn epochId(self: *const Self) u128 {
        return state.IndexState.unpack(self.state).epoch_id;
    }

    /// Whether this host dials `host` (2.3): only the lesser index of a pair
    /// dials, so every pair runs over exactly one bidirectional socket. The
    /// greater side reuses that socket's reply channel.
    fn dialsMirror(own: u8, host: u8) bool {
        return host > own;
    }

    /// Where the index service of `host` listens for its mirrors (2.7).
    fn mirrorEndpoint(self: *const Self, host: u8) config.BindType {
        return switch (self.ctrl.cfg.replication.mode) {
            // Single-host mode has no mirror endpoint.
            .local => .{ .host = "127.0.0.1", .port = 0 },
            .cluster => |cluster| cluster.mirrors[host],
        };
    }

    /// Clamps the TCP retry window of a mirror socket below the ~15 minute
    /// kernel default (2.3): a dead peer must surface as an `errno` on the
    /// bounded receives that await acknowledgements, not as a silent stall.
    /// The window is derived from `consensus_timeout`, converted to the whole
    /// milliseconds the option takes.
    fn clampRetryWindow(self: *Self, fd: posix.fd_t, nanos: i64) void {
        const ns: u64 = @intCast(@max(nanos, 1));
        const ms: u32 = @intCast(@min((ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms, std.math.maxInt(u32)));
        const res = std.os.linux.setsockopt(
            fd,
            std.os.linux.IPPROTO.TCP,
            std.os.linux.TCP.USER_TIMEOUT,
            @ptrCast(&ms),
            @sizeOf(u32),
        );
        if (std.os.linux.errno(res) != .SUCCESS) {
            self.log.warn("could not clamp the mirror retry window", .{
                .ring_idx = self.indexIdx().ring_idx,
                .fd = fd,
                .err = @tagName(std.os.linux.errno(res)),
            });
        }
    }

    /// Step 1 of the connection machine (2.3): a client socket and a connect
    /// SQE. The socket is remembered right away, so a hand-off of the peer
    /// side cannot dial the same host twice.
    fn dialMirror(self: *Self, host: u8, endpoint: config.BindType) !void {
        if (self.connect_state[host] == .established) return;

        const fd = try zigring.createTCPClientSocket(null);
        errdefer _ = std.os.linux.close(fd);
        self.clampRetryWindow(fd, self.ctrl.cfg.consensus_timeout.value.nanos);

        const task_idx = try self.slots.add(.{ .connect_op = .{
            .host_idx = host,
            .stage = .waiting_connect,
        } });
        errdefer self.slots.del(task_idx);

        self.mirror_fds[host] = fd;
        self.recv_armed[host] = false;
        self.recv_len[host] = 0;
        self.ring.ring.pushConnectIp4(fd, task_idx, endpoint.host, endpoint.port, .{}) catch |err| {
            self.slots.del(task_idx);
            return err;
        };
        // A connect that never completes would keep the pair unreachable
        // without a trace; the wheel abandons it after `consensus_timeout`
        // (2.3) and the machine starts over at the parked retry.
        self.armDialDeadline(host, self.ctrl.cfg.consensus_timeout.value.nanos);

        self.log.info("mirror dial started", .{
            .ring_idx = self.indexIdx().ring_idx,
            .host_idx = host,
            .fd = fd,
            .host = endpoint.host,
            .port = endpoint.port,
        });
    }

    /// Parks the retry of one mirror on the timing wheel (2.3): the machine
    /// starts over at `waiting_connect` once the window elapses.
    fn parkMirrorRetry(self: *Self, host: u8) void {
        if (self.connect_tokens[host] != null) return;
        const due = currentSecond() +% durationSeconds(self.ctrl.cfg.consensus_timeout.value.nanos);
        self.armMirrorDeadline(host, due);
    }

    /// Arms one mirror retry for the absolute second `due`.
    fn armMirrorDeadline(self: *Self, host: u8, due: u32) void {
        self.deadline_serial +%= 1;
        const token = self.deadline_serial;
        const handle = self.wheel.add_delay(token, ticksUntil(due, self.ticks_per_second)) catch |err| {
            self.log.err("could not arm a mirror retry", .{
                .ring_idx = self.indexIdx().ring_idx,
                .host_idx = host,
                .err = @errorName(err),
            });
            return;
        };
        self.deadlines.put(token, .{
            .handle = handle,
            .due_second = due,
            .target = .{ .mirror = host },
        }) catch |err| {
            self.wheel.delete_by_index(handle);
            self.log.err("could not record a mirror retry", .{
                .ring_idx = self.indexIdx().ring_idx,
                .host_idx = host,
                .err = @errorName(err),
            });
            return;
        };
        self.connect_tokens[host] = token;
    }

    /// Arms the deadline of a connect in flight (2.3) `nanos` from now.
    fn armDialDeadline(self: *Self, host: u8, nanos: i64) void {
        self.armDialDeadlineAt(host, currentSecond() +% durationSeconds(nanos));
    }

    /// Arms the deadline of a connect in flight for the absolute second `due`.
    fn armDialDeadlineAt(self: *Self, host: u8, due: u32) void {
        self.disarmDialDeadline(host);

        self.deadline_serial +%= 1;
        const token = self.deadline_serial;
        const handle = self.wheel.add_delay(token, ticksUntil(due, self.ticks_per_second)) catch |err| {
            self.log.err("could not arm a mirror connect deadline", .{
                .ring_idx = self.indexIdx().ring_idx,
                .host_idx = host,
                .err = @errorName(err),
            });
            return;
        };
        self.deadlines.put(token, .{
            .handle = handle,
            .due_second = due,
            .target = .{ .dial = host },
        }) catch |err| {
            self.wheel.delete_by_index(handle);
            self.log.err("could not record a mirror connect deadline", .{
                .ring_idx = self.indexIdx().ring_idx,
                .host_idx = host,
                .err = @errorName(err),
            });
            return;
        };
        self.dial_tokens[host] = token;
    }

    /// Withdraws the deadline of a connect in flight, if any.
    fn disarmDialDeadline(self: *Self, host: u8) void {
        const token = self.dial_tokens[host] orelse return;
        self.dial_tokens[host] = null;

        const deadline = self.deadlines.get(token) orelse return;
        self.wheel.delete_by_index(deadline.handle);
        _ = self.deadlines.remove(token);
    }

    /// Records a mirror connection that is up and behind its greeting (2.3).
    /// The descriptor changes hands here: from now on the index owns it, and
    /// the front that accepted it never touches it again.
    fn establishMirror(self: *Self, host: u8, fd: posix.fd_t) void {
        if (host >= self.ctrl.cfg.replication.factor or host == self.ownHost()) {
            // Not a member of this shard, or the own slot: the connection has
            // no peer to serve.
            self.log.warn("mirror connection for a host outside the shard", .{
                .ring_idx = self.indexIdx().ring_idx,
                .host_idx = host,
                .factor = self.ctrl.cfg.replication.factor,
            });
            _ = std.os.linux.close(fd);
            return;
        }

        const previous = self.mirror_fds[host];
        if (previous >= 0 and previous != fd) _ = std.os.linux.close(previous);
        if (previous >= 0 and previous != fd) self.recv_armed[host] = false;

        // A retry that is still parked belongs to the connection that just
        // arrived.
        if (self.connect_tokens[host]) |token| {
            self.connect_tokens[host] = null;
            if (self.deadlines.get(token)) |deadline| {
                self.wheel.delete_by_index(deadline.handle);
                _ = self.deadlines.remove(token);
            }
        }

        self.clampRetryWindow(fd, self.ctrl.cfg.consensus_timeout.value.nanos);
        self.mirror_fds[host] = fd;
        self.connect_state[host] = .established;
        self.startMirrorStream(host);

        self.log.info("mirror established", .{
            .ring_idx = self.indexIdx().ring_idx,
            .host_idx = host,
            .fd = fd,
        });
        self.armMirrorRecv(host);
    }

    /// Arms the receive that awaits the frames of one mirror (2.4). The
    /// buffer stays on the controller, one per host, so a record split over
    /// two completions is completed at the front of it.
    fn armMirrorRecv(self: *Self, host: u8) void {
        if (self.recv_armed[host]) return;
        const fd = self.mirror_fds[host];
        if (fd < 0 or self.connect_state[host] != .established) return;

        const used: usize = self.recv_len[host];
        const buf = self.recv_bufs[host][used..];
        const task_idx = self.slots.add(.{ .mirror_recv = .{ .host_idx = host } }) catch |err| {
            self.log.err("could not allocate a mirror receive", .{
                .ring_idx = self.indexIdx().ring_idx,
                .host_idx = host,
                .err = @errorName(err),
            });
            return;
        };
        self.ring.ring.pushRecv(fd, task_idx, buf, .{}) catch |err| {
            self.slots.del(task_idx);
            self.log.err("could not arm a mirror receive", .{
                .ring_idx = self.indexIdx().ring_idx,
                .host_idx = host,
                .err = @errorName(err),
            });
            self.dropMirror(host, -1);
            return;
        };
        self.recv_armed[host] = true;
    }

    /// Applies the completion of a mirror receive: the bytes are folded into
    /// the buffer, every whole frame is handed to the reorder window, and the
    /// next receive is armed (2.4). A closed or failed socket parks the
    /// connection.
    fn finishMirrorRecv(self: *Self, host: u8, res: i32) void {
        self.recv_armed[host] = false;
        if (res <= 0) {
            self.dropMirror(host, res);
            return;
        }

        self.recv_len[host] += @intCast(res);
        self.consumeMirrorFrames(host);
        if (self.connect_state[host] == .established) self.armMirrorRecv(host);
    }

    /// Opens the frame stream of a fresh connection: a zeroed reorder window
    /// and the first sequence index both sides start from (2.6).
    fn startMirrorStream(self: *Self, host: u8) void {
        self.closeReorder(host);
        var buffer: zigring.ReorderBuffer = undefined;
        buffer.init(self.ctrl.allocator, reorder_window, wire.max_frame_len) catch |err| {
            self.log.err("could not allocate a mirror reorder window", .{
                .ring_idx = self.indexIdx().ring_idx,
                .host_idx = host,
                .err = @errorName(err),
            });
            return;
        };
        self.reorder[host] = buffer;
        self.recv_seq[host] = 0;
        self.recv_len[host] = 0;
    }

    /// Releases the reorder window of one mirror, if it has one.
    fn closeReorder(self: *Self, host: u8) void {
        if (self.reorder[host]) |*buffer| {
            buffer.deinit();
            self.reorder[host] = null;
        }
    }

    /// Moves every whole frame out of the mirror buffer of `host` into the
    /// reorder window, keeping the bytes of an incomplete one at the front for
    /// the next completion (2.6).
    fn consumeMirrorFrames(self: *Self, host: u8) void {
        const buffer = if (self.reorder[host]) |*b| b else return;

        var consumed: usize = 0;
        const total: usize = self.recv_len[host];
        while (true) {
            const decoded = wire.decode(self.recv_bufs[host][consumed..total]) catch |err| switch (err) {
                // The frame is not whole yet; the next completion brings the
                // rest of it.
                error.Truncated => break,
                // A peer this transport cannot talk to: the connection is
                // dropped, the session in flight falls to its own deadline.
                else => {
                    self.log.err("malformed mirror frame", .{
                        .ring_idx = self.indexIdx().ring_idx,
                        .host_idx = host,
                        .err = @errorName(err),
                    });
                    self.dropMirror(host, -1);
                    return;
                },
            };

            const raw = self.recv_bufs[host][consumed..][0..decoded.len];
            consumed += decoded.len;

            // The window wants equal-size items, so the frame is copied into a
            // zero-padded one; the decoder reads no further than its own
            // payload.
            var padded: [wire.max_frame_len]u8 = undefined;
            @memset(&padded, 0);
            @memcpy(padded[0..raw.len], raw);

            const seq = wire.absoluteSeq(self.recv_seq[host], decoded.frame.seq_id);
            buffer.push(seq, &padded) catch |err| switch (err) {
                // A frame already applied: nothing to do, the peer just
                // repeated itself.
                error.OutdatedFrame => continue,
                // A gap wider than the window is not a reorder anymore: the
                // connection is dropped and the peer starts over (2.6).
                else => {
                    self.log.err("mirror frame out of the reorder window", .{
                        .ring_idx = self.indexIdx().ring_idx,
                        .host_idx = host,
                        .expected = self.recv_seq[host],
                        .got = decoded.frame.seq_id,
                        .err = @errorName(err),
                    });
                    self.dropMirror(host, -1);
                    return;
                },
            };
        }

        if (consumed != 0) {
            const left: usize = self.recv_len[host] - consumed;
            if (left != 0) std.mem.copyForwards(u8, self.recv_bufs[host][0..left], self.recv_bufs[host][consumed..][0..left]);
            self.recv_len[host] = @intCast(left);
        }

        self.drainReorder(host);
    }

    /// Applies every frame the reorder window can release in order, bumping the
    /// expected sequence index as each one goes (2.6).
    fn drainReorder(self: *Self, host: u8) void {
        const buffer = if (self.reorder[host]) |*b| b else return;

        while (true) {
            const bytes = buffer.popHeadCond(self.recv_seq[host]) orelse break;
            const decoded = wire.decode(bytes) catch |err| {
                self.log.err("malformed mirror frame", .{
                    .ring_idx = self.indexIdx().ring_idx,
                    .host_idx = host,
                    .err = @errorName(err),
                });
                self.dropMirror(host, -1);
                return;
            };
            self.recv_seq[host] +%= 1;
            self.applyMirrorFrame(host, decoded.frame);
            // The frame may have retired the connection under us.
            if (self.connect_state[host] != .established) return;
        }
    }

    /// Routes one frame that came out of the reorder window (2.6): a mutation
    /// to the replication handler, an answer through the epoch barrier, the
    /// liveness pulse to the vector clock, the stage-6 commands to the
    /// isolation, the replay and the background synchronization, and the
    /// stage-7 isolation vote and log chunks to their own handlers.
    fn applyMirrorFrame(self: *Self, host: u8, frame: wire.Frame) void {
        // Every frame of a connection is traffic on it: the silence the
        // leadership takeover and the isolation ride on is measured here.
        if (host < self.mirrors.len) self.mirrors[host].sawTraffic(currentSecond());

        switch (frame.op) {
            .create, .append, .overwrite, .repeat, .close => self.applyMirrorRequest(host, frame),
            .ack => |answer| self.dispatchMirrorAnswer(host, .ack, answer),
            .nack => |answer| self.dispatchMirrorAnswer(host, .nack, answer),
            // The mirror liveness pulse of the background sync: it keeps the
            // connection observable and is answered by nothing.
            .pulse => {},
            .isolate => |isolate| self.applyMirrorIsolate(host, frame, isolate),
            .isolate_proposal => |proposal| self.applyMirrorProposal(host, frame, proposal),
            .compensate => |compensate| self.applyMirrorCompensate(host, frame, compensate),
            .restart => |min_state| self.applyMirrorRestart(host, frame, min_state),
            .restart_in => |restart_in| self.applyMirrorRestartIn(host, frame, restart_in),
            .request_log => |request| self.answerLogRequest(host, request),
            .requested_log => |requested| self.applyRequestedLog(host, requested),
            .requested_log_not_available => |unavailable| self.applyLogUnavailable(unavailable),
            .request_snapshot => |request| self.answerSnapshotRequest(host, request),
            .requested_snapshot => |requested| self.applyRequestedSnapshot(requested),
        }

        // Every frame carries one vector clock pair, whatever its operation.
        // The pair is noted after the operation of the frame: a report that
        // rode the same frame as its mutation must not ask for data this index
        // is just taking in (stage 7).
        self.noteVector(host, frame);
    }

    /// Feeds one mirror answer into the round in flight (2.5 step 4), after the
    /// epoch barrier of docs/consensus.md: a stale epoch is a hard refusal, a
    /// greater one leaves this host abstaining, and only an equal one counts as
    /// the answer the mirror sent.
    fn dispatchMirrorAnswer(self: *Self, host: u8, sent: state.ConsensusResponse, answer: wire.Answer) void {
        // An isolation vote is answered by the same `Ack`/`Nack` as a mutation
        // but names a boundary instead of a session (stage 7).
        switch (answer.op) {
            .isolate_proposal => |boundary| return self.noteProposalAnswer(host, sent, boundary, answer.epoch),
            else => {},
        }
        // Only a session-bearing mutation has a round to feed. The answer to a
        // stage-6 command carries no session and is informational: the command
        // itself is idempotent at every receiver.
        const session_id = wire.acknowledgedSession(answer.op) orelse return;
        // The socket names the responder; the vector clock pair of the frame
        // reports whichever host it is that frame's turn to report.
        const response = self.barrierResponse(host, sent, answer.epoch);
        self.driver.dispatchExpectOp(self, host, session_id, response);
    }

    /// The epoch barrier applied to one answer (docs/consensus.md).
    fn barrierResponse(self: *Self, host: u8, sent: state.ConsensusResponse, epoch: u128) state.ConsensusResponse {
        return switch (state.compareEpoch(epoch, self.expected_epoch[host])) {
            .lt => .nack,
            .gt => .abstain,
            .eq => sent,
        };
    }

    /// Applies one replicated mutation to this host's copy of the session
    /// (2.5): the epoch barrier gates it, the own `index` slice takes its
    /// post-bump value, exactly as the flush of the owning host advances it,
    /// and the request is answered with the resulting state. The operation is
    /// written to the replica log of the leading host (stage 7) and advances
    /// that replica's log pointer, which is what fires a deferred isolation.
    fn applyMirrorRequest(self: *Self, host: u8, frame: wire.Frame) void {
        const session_id = wire.sessionId(frame.op) orelse return;

        // The session id carries the host and the epoch that lead the session,
        // which is the pair the barrier of docs/consensus.md compares. The
        // vector clock pair of the frame rotates over the hosts, so it is not
        // the sender's own state.
        const leader = state.IndexState.unpack(session_id);
        switch (state.compareEpoch(leader.epoch_id, self.expected_epoch[leader.host_id])) {
            // A stale host: a hard refusal, its state is not this shard's.
            .lt => {
                if (wire.acked(frame.op)) |answer| {
                    _ = self.sendFrame(host, .{
                        .seq_id = self.send_seq[host],
                        .host_idx = self.ownHost(),
                        .host_state = self.state,
                        .op = .{ .nack = .{ .epoch = self.epochId(), .op = answer } },
                    });
                }
                self.log.warn("mirror request from a stale epoch", .{
                    .ring_idx = self.indexIdx().ring_idx,
                    .host_idx = leader.host_id,
                    .epoch = @as(u64, leader.epoch_id),
                });
                return;
            },
            // This host is behind the sender: it abstains until the vector
            // clock synchronization brings it up to the sender's state.
            .gt => {
                self.log.warn("mirror request from a greater epoch, abstaining", .{
                    .ring_idx = self.indexIdx().ring_idx,
                    .host_idx = leader.host_id,
                    .epoch = @as(u64, leader.epoch_id),
                });
                return;
            },
            .eq => {},
        }

        self.log.info("mirror request", .{
            .ring_idx = self.indexIdx().ring_idx,
            .host_idx = frame.host_idx,
            .op = @tagName(wire.tagOf(frame.op)),
            .session_id_hi = @as(u64, @truncate(session_id >> 64)),
            .session_id_lo = @as(u64, @truncate(session_id)),
        });

        self.state = state.IndexState.unpack(self.state).bumped().pack();

        // Stage 6: the session on this host's copy of the leader's log, the
        // log pointer it advances to and any deferred isolation the replica
        // just reached. The post-op leader state is the one the session was
        // predicted to upgrade to, `Session.upgrade_idx` of 2.5: a create's id
        // already is that state, every other mutation upgrades by one.
        const leader_state = switch (frame.op) {
            .create => session_id,
            else => state.IndexState.unpack(session_id).bumped().pack(),
        };
        if (leader.host_id < self.mirrors.len) {
            // Stage 7: the operation of the leader lands in its replica log
            // before the in-memory replica takes it, so the log of a host this
            // index mirrors can be served to a peer that fell behind.
            if (wire.stateOp(frame.op)) |op| {
                self.storeReplica(leader.host_id, .{ .mutation = .{
                    .session_id = session_id,
                    .op = op,
                    .upgrade_idx = leader_state,
                } });
            }
            self.mirrors[leader.host_id].advance(session_id, leader_state, currentSecond()) catch |err| {
                self.log.err("could not advance a replicated session", .{
                    .ring_idx = self.indexIdx().ring_idx,
                    .host_idx = leader.host_id,
                    .err = @errorName(err),
                });
            };
        }
        self.advanceSync(leader.host_id, leader_state);

        const answer = wire.acked(frame.op) orelse return;
        _ = self.sendFrame(host, .{
            .seq_id = self.send_seq[host],
            .host_idx = self.ownHost(),
            .host_state = self.state,
            .op = .{ .ack = .{ .epoch = self.epochId(), .op = answer } },
        });
    }

    /// Retires a mirror connection that failed or closed (2.3). A peer this
    /// host dials is parked for a retry; a peer that dialled us waits for a
    /// new connection, the other side owning the dial.
    fn dropMirror(self: *Self, host: u8, res: i32) void {
        self.disarmDialDeadline(host);
        const fd = self.mirror_fds[host];
        self.mirror_fds[host] = -1;
        self.connect_state[host] = .waiting_connect;
        self.recv_armed[host] = false;
        self.recv_len[host] = 0;
        self.recv_seq[host] = 0;
        self.send_seq[host] = 0;
        self.closeReorder(host);
        if (fd >= 0) _ = std.os.linux.close(fd);

        self.log.warn("mirror connection lost", .{
            .ring_idx = self.indexIdx().ring_idx,
            .host_idx = host,
            .fd = fd,
            .res = res,
        });
        if (Self.dialsMirror(self.ownHost(), host)) self.parkMirrorRetry(host);
    }

    /// The completion of one step of the connection machine (2.3).
    fn finishConnect(self: *Self, host: u8, stage: slots.ConnectStage, res: i32) void {
        const fd = self.mirror_fds[host];
        switch (stage) {
            .waiting_connect => {
                // A connect the wheel already abandoned: the descriptor is
                // gone and the completion only reports the close (2.3).
                if (self.mirror_fds[host] < 0) return;
                self.disarmDialDeadline(host);
                if (res < 0) {
                    self.log.warn("mirror connect failed", .{
                        .ring_idx = self.indexIdx().ring_idx,
                        .host_idx = host,
                        .err = @tagName(@as(std.os.linux.E, @fromBackingInt(@intCast(-res)))),
                    });
                    self.dropMirror(host, res);
                    return;
                }
                // The connection is up: the greeting names the host that
                // dialled and the index service the socket serves, so the
                // accepting side can route the descriptor (2.3).
                wire.encodeGreeting(&self.greetings[host], .{
                    .host_idx = self.ownHost(),
                    .index_idx = self.indexIdx().inbox_idx,
                });
                const task_idx = self.slots.add(.{ .connect_op = .{
                    .host_idx = host,
                    .stage = .awaiting_accept,
                } }) catch |err| {
                    self.log.err("could not allocate the greeting step", .{
                        .ring_idx = self.indexIdx().ring_idx,
                        .host_idx = host,
                        .err = @errorName(err),
                    });
                    self.dropMirror(host, -1);
                    return;
                };
                self.connect_state[host] = .greeting_sent;
                self.ring.ring.pushSend(fd, task_idx, &self.greetings[host], wire.greeting_len, .{}) catch |err| {
                    self.slots.del(task_idx);
                    self.log.err("could not send the mirror greeting", .{
                        .ring_idx = self.indexIdx().ring_idx,
                        .host_idx = host,
                        .err = @errorName(err),
                    });
                    self.dropMirror(host, -1);
                };
            },
            // The greeting is out: the peer accepts this socket as one of its
            // mirrors and the stream takes the frames. No greeting comes back,
            // the accepting side learning the dialling host from the greeting
            // it read.
            .greeting_sent, .awaiting_accept => {
                if (res < 0) {
                    self.log.warn("mirror greeting failed", .{
                        .ring_idx = self.indexIdx().ring_idx,
                        .host_idx = host,
                        .err = @tagName(@as(std.os.linux.E, @fromBackingInt(@intCast(-res)))),
                    });
                    self.dropMirror(host, res);
                    return;
                }
                self.connect_state[host] = .established;
                self.startMirrorStream(host);
                self.armMirrorRecv(host);
            },
            .established => {},
        }
    }

    /// Starts the consensus round of `op` (2.5 step 2) in `cluster` mode: the
    /// own vote is counted at once and one `replicate_op` per established
    /// mirror carries the request.
    fn startReplication(self: *Self, session_id: u128, op: state.Op) void {
        const session = self.sessions.getPtr(session_id) orelse return;
        if (session.state != .ExpectConsensus or session.op != op) return;

        const factor = self.ctrl.cfg.replication.factor;
        const quorum = quorumOf(factor);

        // The own vote needs no message: the index applies the op itself.
        _ = session.recordResponse(.ack);
        if (session.consensus_progress.accepted >= quorum) {
            self.updateSessionState(session_id, .{ .op_acknowledged = op });
            return;
        }

        var outstanding: u32 = 0;
        var host: u8 = 0;
        while (host < factor) : (host += 1) {
            if (host == self.ownHost()) continue;
            if (self.connect_state[host] != .established) continue;
            if (self.mirror_fds[host] < 0) continue;
            if (self.sendFrame(host, .{
                .seq_id = self.send_seq[host],
                .host_idx = self.ownHost(),
                .host_state = self.state,
                .op = wire.requestOf(op, session_id),
            })) outstanding += 1;
        }

        if (session.consensus_progress.accepted + outstanding < quorum) {
            // An unreachable shard cannot decide. The round waits for answers
            // that may never come, and the acknowledgement deadline below
            // releases the client of it; the isolation of the stranded host is
            // the shard's own business (stage 6, `maintainPeer`).
            self.log.warn("consensus round cannot reach its quorum", .{
                .ring_idx = self.indexIdx().ring_idx,
                .accepted = session.consensus_progress.accepted,
                .outstanding = outstanding,
                .quorum = quorum,
                .session_id_hi = @as(u64, @truncate(session_id >> 64)),
                .session_id_lo = @as(u64, @truncate(session_id)),
            });
        }

        // The acknowledgement deadline of the round (2.7). It replaces the
        // inactivity deadline the operation armed, which `finishReply` restores
        // once the round is over, so a peer that never answers cannot keep the
        // session waiting for a whole inactivity interval.
        self.armDeadline(session_id, session, self.ctrl.cfg.consensus_timeout.value.nanos);
    }

    /// Feeds one mirror's answer into the round in flight (2.5 step 4): the
    /// quorum moves the session on, a straggler is ignored.
    fn applyMirrorAnswer(self: *Self, host_idx: u8, session_id: u128, resp: state.ConsensusResponse) void {
        if (host_idx >= self.ctrl.cfg.replication.factor) return;

        const session = self.sessions.getPtr(session_id) orelse return;
        if (session.state != .ExpectConsensus) return;

        const progress = session.recordResponse(resp);
        if (progress.accepted < quorumOf(self.ctrl.cfg.replication.factor)) return;
        self.updateSessionState(session_id, .{ .op_acknowledged = session.op });
    }

    /// Encodes one frame and arms its send on the mirror socket of `host`. The
    /// buffer travels with the slot and is released on completion.
    fn sendFrame(self: *Self, host: u8, frame: wire.Frame) bool {
        const fd = self.mirror_fds[host];
        if (fd < 0) return false;

        const allocator = self.ctrl.allocator;
        const len = wire.frameLen(frame.op);
        const owned = allocator.alloc(u8, len) catch |err| {
            self.log.err("could not allocate a mirror frame", .{
                .ring_idx = self.indexIdx().ring_idx,
                .host_idx = host,
                .err = @errorName(err),
            });
            return false;
        };
        wire.encode(owned, frame);

        const task_idx = self.slots.add(.{ .replicate_op = .{
            .session_id = wire.sessionId(frame.op) orelse 0,
            .host_idx = host,
            .buf = owned.ptr,
            .len = @intCast(owned.len),
        } }) catch |err| {
            allocator.free(owned);
            self.log.err("could not allocate a mirror send", .{
                .ring_idx = self.indexIdx().ring_idx,
                .host_idx = host,
                .err = @errorName(err),
            });
            return false;
        };
        self.ring.ring.pushSend(fd, task_idx, owned.ptr, owned.len, .{}) catch |err| {
            self.slots.del(task_idx);
            allocator.free(owned);
            self.log.err("could not arm a mirror send", .{
                .ring_idx = self.indexIdx().ring_idx,
                .host_idx = host,
                .err = @errorName(err),
            });
            return false;
        };

        self.send_seq[host] +%= 1;
        return true;
    }

    /// Closes every mirror socket this index owns (2.3).
    fn closeMirrors(self: *Self) void {
        var host: u8 = 0;
        const factor = self.ctrl.cfg.replication.factor;
        while (host < factor and host < max_hosts) : (host += 1) {
            const fd = self.mirror_fds[host];
            if (fd < 0) continue;
            self.mirror_fds[host] = -1;
            _ = std.os.linux.close(fd);
        }
    }

    /// Reads one handed-over mirror descriptor out of its cross-task slot and
    /// puts it under the connection machine (2.3). The front that accepted the
    /// socket released its hold here; the index owns the descriptor now.
    fn acceptMirrorSocket(self: *Self, slot_idx: u32) void {
        const cross = self.ctrl.cross_slots.at(slot_idx).*;
        self.ctrl.cross_slots.release(slot_idx);

        switch (cross) {
            .MirrorSocket => |handed| self.driver.connectionEstablished(self, handed.host_idx, handed.fd),
            else => self.log.warn("index received a cross-task payload it does not serve", .{
                .ring_idx = self.indexIdx().ring_idx,
                .slot = slot_idx,
            }),
        }
    }

    /// Handles one completion of the index ring.
    fn handleCqe(self: *Self, logger: *lifetime.LoggerStuff, cqe: zigring.CQE) void {
        const task_idx = cqe.taskIdx();
        if (logger.completeLogging(task_idx)) return;
        switch (task_idx) {
            // The launch broadcast is a no-op for an index: it ignores the
            // socket fd and keeps working off its ring and its inbox.
            messages.StartWorkIdx => {},
            // A payload-less wakeup: the inbox drain delivers.
            messages.IndexWakeupTaskIdx => {},
            // A front hands over the descriptor of an accepted replication
            // connection: the greeting has already named the dialling host and
            // the index service the socket serves (2.3).
            messages.CrossTaskMessageIdx => self.acceptMirrorSocket(@intCast(cqe.res)),
            else => {
                const task = self.slots.get(task_idx) orelse return;
                self.slots.del(task_idx);
                switch (task) {
                    // Step 5 of 2.5 done: the operation reached the log, so
                    // the reply goes out directly (step 6).
                    .flush_op => |op| self.finishFlush(op.session_id, op.buf[0..op.len], cqe.res),
                    // Stage 7: one log command of this host reached the log.
                    .log_command => |op| {
                        self.ctrl.allocator.free(op.buf[0..op.len]);
                        if (cqe.res < 0) {
                            self.log.err("the log command append failed", .{
                                .ring_idx = self.indexIdx().ring_idx,
                                .err = @tagName(@as(std.os.linux.E, @fromBackingInt(@intCast(-cqe.res)))),
                            });
                        }
                    },
                    // Step 6 of 2.5 done: the client has its answer, and the
                    // buffer the write borrowed from is released.
                    .reply_op => |op| {
                        self.ctrl.allocator.free(op.buf[0..op.len]);
                        self.finishReply(op.session_id, op.fd, op.known, cqe.res);
                    },
                    // One consensus request left for a mirror (2.4 step 2).
                    // A failed send is a mirror that will not answer; the
                    // round waits for its quorum and the session's deadline
                    // bounds it (2.5).
                    .replicate_op => |op| {
                        self.ctrl.allocator.free(op.buf[0..op.len]);
                        if (cqe.res < 0) {
                            self.log.warn("mirror send failed", .{
                                .ring_idx = self.indexIdx().ring_idx,
                                .host_idx = op.host_idx,
                                .err = @tagName(@as(std.os.linux.E, @fromBackingInt(@intCast(-cqe.res)))),
                            });
                        }
                    },
                    // A reply or a request arrived from a mirror (2.4).
                    .mirror_recv => |op| self.finishMirrorRecv(op.host_idx, cqe.res),
                    // One step of the connection machine (2.3).
                    .connect_op => |op| self.finishConnect(op.host_idx, op.stage, cqe.res),
                    else => self.log.warn("index ring completion without a handler", .{
                        .ring_idx = self.indexIdx().ring_idx,
                        .task_idx = task_idx,
                    }),
                }
            },
        }
    }

    /// Handles one queued front message. Returns true when the service loop
    /// must stop.
    fn handleTask(self: *Self, loop: *LoopState, task: FrontMessage) bool {
        switch (task) {
            .create => |create| self.openSession(create.fd, create.tag),
            .session_op => |msg| self.applySessionOp(msg),
            .tick => |second| self.handleTick(second),
            .shutdown_soft => {
                if (!loop.draining) {
                    loop.draining = true;
                    self.log.info("index soft shutdown", .{ .ring_idx = self.indexIdx().ring_idx });
                }
                if (self.sessions.count() == 0) {
                    self.reportDrained();
                    return true;
                }
            },
            .shutdown_hard => {
                self.log.info("index hard shutdown", .{ .ring_idx = self.indexIdx().ring_idx });
                self.reportDrained();
                return true;
            },
        }
        return false;
    }

    /// Opens the session of a freshly accepted client socket. The id of the
    /// session is the post-bump index state, which is also the state the index
    /// takes once the create is acknowledged (2.5); the endpoint is recorded
    /// against the operation in flight, and the descriptor stays with the
    /// front.
    fn openSession(self: *Self, fd: posix.fd_t, tag: usize) void {
        const begin = self.state;
        const id = state.IndexState.unpack(begin).bumped().pack();

        self.sessions.put(id, state.Session.created(id, begin, fd, tag)) catch |err| {
            // The create is lost: without a session entry there is no id to
            // route the next operation of this client by.
            self.log.err("could not open a session", .{
                .ring_idx = self.indexIdx().ring_idx,
                .fd = fd,
                .tag = tag,
                .err = @errorName(err),
            });
            return;
        };
        // The id is reserved at once, so two creates in flight cannot predict
        // the same future id. Stage 4 moves the bump to the acknowledgement.
        self.state = id;

        self.log.info("index opened session", .{
            .ring_idx = self.indexIdx().ring_idx,
            .fd = fd,
            .tag = tag,
            .session_id_hi = @as(u64, @truncate(id >> 64)),
            .session_id_lo = @as(u64, @truncate(id)),
        });

        // A create is the first operation of its session and walks the same
        // phases as any mutation (2.5), so the driver sees it too.
        const session = self.sessions.getPtr(id) orelse return;
        session.startOp(.create, begin, fd, tag);
        self.armDeadline(id, session, self.ctrl.cfg.session_inactivity_timeout.value.nanos);
        self.driver.expectOp(self, id, .create);
    }

    /// Applies one operation to its session: step 1 of the tract of 2.5.
    fn applySessionOp(self: *Self, msg: SessionOp) void {
        const session = self.sessions.getPtr(msg.session_id) orelse {
            // An unknown session has its own reaction in 2.5, drawn by the
            // flag of 2.7: the fatal pole leaves the writing to the front
            // through the complaint, the other pole is the index' own direct
            // angry write. Either way the op retires here.
            self.log.warn("session op for an unknown session", .{
                .ring_idx = self.indexIdx().ring_idx,
                .fd = msg.endpoint.fd,
                .tag = msg.endpoint.tag,
                .session_id_hi = @as(u64, @truncate(msg.session_id >> 64)),
                .session_id_lo = @as(u64, @truncate(msg.session_id)),
                .fatal = self.ctrl.cfg.unknown_session_is_fatal.value,
            });
            self.retireUnknownSession(msg);
            return;
        };

        if (session.state != .ExpectOp) {
            // A mutation sent before the previous one resolved. The client is
            // faulty and the index never writes to it itself: the complaint
            // rides a cross-task slot into the parent front (2.3), which
            // validates it, answers the client and marks the socket for the
            // deferred close. The repeats are idempotent there, so the log
            // entry repeats with them.
            self.log.err("faulty client: protocol violation with mutation sent before the previous mutation resolved", .{
                .ring_idx = self.indexIdx().ring_idx,
                .session_details = session.diag(),
                .unexpected_mutation = msg.op.string(),
            });
            self.pushComplaint(.protocol_violation, msg.endpoint.fd, msg.endpoint.tag, msg.session_id);
            self.ctrl.sockets.bumpIndex(msg.endpoint.fd, self.role.index.counter_slot);
            if (session.state != .Violated) {
                // The session is parked until the replay takes it over (2.5);
                // the deadline is armed once, the repeats above only add
                // complaints.
                session.state = .Violated;
                self.armDeadline(msg.session_id, session, self.ctrl.cfg.protocol_violation_replay.value.nanos);
            }
            return;
        }

        session.startOp(msg.op, self.state, msg.endpoint.fd, msg.endpoint.tag);
        self.armDeadline(msg.session_id, session, self.ctrl.cfg.session_inactivity_timeout.value.nanos);
        self.driver.expectOp(self, msg.session_id, msg.op);
    }

    /// The reaction to an op naming a session this index does not know (2.5).
    /// The fatal pole pushes the complaint and lets the front answer; the
    /// non-fatal pole writes the same angry text itself, as the cheap direct
    /// write, and the op retires through the ordinary reply path.
    fn retireUnknownSession(self: *Self, msg: SessionOp) void {
        if (self.ctrl.cfg.unknown_session_is_fatal.value) {
            self.pushComplaint(.unknown_session, msg.endpoint.fd, msg.endpoint.tag, msg.session_id);
            self.ctrl.sockets.bumpIndex(msg.endpoint.fd, self.role.index.counter_slot);
            return;
        }

        var text: [reply.max_len]u8 = undefined;
        const body = reply.encode(.unknown_session, msg.session_id, &text);
        self.writeDirect(msg.session_id, msg.endpoint.fd, false, body);
    }

    /// Step 5 of 2.5: the quorum is reached, so the operation goes to the log.
    /// The session waits for the record; the record is a heap buffer that
    /// travels with the slot and is released on completion. The record is the
    /// framed one of `wal.zig`, checksum and all, so a torn tail of this very
    /// write is recognisable after a restart.
    fn beginFlush(self: *Self, session_id: u128) void {
        const session = self.sessions.getPtr(session_id) orelse return;
        session.state = .ExpectAcceptedFlush;

        var record: [wal.record_len]u8 = undefined;
        wal.encode(&record, .{
            .session_id = session.id,
            .op = session.op,
            .upgrade_idx = session.upgrade_idx,
        });

        if (!self.wal.enabled()) {
            // No log: the operation is retired as if the record landed.
            self.finishFlush(session_id, &.{}, 0);
            return;
        }

        const allocator = self.ctrl.allocator;
        const owned = allocator.dupe(u8, &record) catch |err| {
            self.log.err("could not allocate a WAL record", .{
                .ring_idx = self.indexIdx().ring_idx,
                .err = @errorName(err),
            });
            self.finishFlush(session_id, &.{}, -1);
            return;
        };
        const task_idx = self.slots.add(.{ .flush_op = .{
            .session_id = session_id,
            .buf = owned.ptr,
            .len = @intCast(owned.len),
        } }) catch |err| {
            allocator.free(owned);
            self.log.err("could not allocate a flush slot", .{
                .ring_idx = self.indexIdx().ring_idx,
                .err = @errorName(err),
            });
            self.finishFlush(session_id, &.{}, -1);
            return;
        };
        self.ring.ring.pushWrite(self.wal.fd, task_idx, owned.ptr, owned.len, .{}) catch |err| {
            self.slots.del(task_idx);
            allocator.free(owned);
            self.log.err("could not arm the WAL write", .{
                .ring_idx = self.indexIdx().ring_idx,
                .err = @errorName(err),
            });
            self.finishFlush(session_id, &.{}, -1);
        };
    }

    /// The completion of step 5: the record is in the log, the index state
    /// takes the post-bump value the operation was predicted with (2.5), and
    /// the reply is armed on the client fd.
    fn finishFlush(self: *Self, session_id: u128, record: []u8, res: i32) void {
        if (record.len != 0) self.ctrl.allocator.free(record);

        const session = self.sessions.getPtr(session_id) orelse return;
        if (res < 0) {
            self.log.err("the WAL append failed", .{
                .ring_idx = self.indexIdx().ring_idx,
                .session_id_hi = @as(u64, @truncate(session_id >> 64)),
                .session_id_lo = @as(u64, @truncate(session_id)),
                .err = @tagName(@as(std.os.linux.E, @fromBackingInt(@intCast(-res)))),
            });
        }

        session.state = .ExpectReply;
        self.state = session.upgrade_idx;

        var text: [reply.max_len]u8 = undefined;
        const body = reply.encode(if (res < 0) .nack else .ack, session_id, &text);
        self.writeDirect(session_id, session.client_fd, true, body);
    }

    /// Step 6 of 2.5: one write on the client fd through the index' own ring,
    /// no cross-task message on the path. The buffer travels with the slot and
    /// is released on completion.
    fn writeDirect(self: *Self, session_id: u128, fd: posix.fd_t, known: bool, body: []const u8) void {
        const allocator = self.ctrl.allocator;
        const owned = allocator.dupe(u8, body) catch |err| {
            self.log.err("could not allocate a client reply", .{
                .ring_idx = self.indexIdx().ring_idx,
                .fd = fd,
                .err = @errorName(err),
            });
            self.finishReply(session_id, fd, known, -1);
            return;
        };

        const task_idx = self.slots.add(.{ .reply_op = .{
            .session_id = session_id,
            .fd = fd,
            .known = known,
            .buf = owned.ptr,
            .len = @intCast(owned.len),
        } }) catch |err| {
            allocator.free(owned);
            self.log.err("could not allocate a reply slot", .{
                .ring_idx = self.indexIdx().ring_idx,
                .fd = fd,
                .err = @errorName(err),
            });
            self.finishReply(session_id, fd, known, -1);
            return;
        };

        self.ring.ring.pushWrite(fd, task_idx, owned.ptr, owned.len, .{}) catch |err| {
            self.slots.del(task_idx);
            allocator.free(owned);
            self.log.err("could not arm the client reply", .{
                .ring_idx = self.indexIdx().ring_idx,
                .fd = fd,
                .err = @errorName(err),
            });
            self.finishReply(session_id, fd, known, -1);
        };
    }

    /// The completion of step 6: the in-flight `+1` of the monotone counters
    /// lands (2.3), the session waits for its next mutation again, and a
    /// `Close` retires the entry and hands the socket to the front through a
    /// complaint with the close code.
    fn finishReply(self: *Self, session_id: u128, fd: posix.fd_t, known: bool, res: i32) void {
        if (res < 0) {
            self.log.warn("the client reply failed", .{
                .ring_idx = self.indexIdx().ring_idx,
                .fd = fd,
                .err = @tagName(@as(std.os.linux.E, @fromBackingInt(@intCast(-res)))),
            });
        }

        // The op is retired: exactly one bump per operation, whatever the
        // outcome (2.3).
        self.ctrl.sockets.bumpIndex(fd, self.role.index.counter_slot);

        if (!known) return;

        const session = self.sessions.getPtr(session_id) orelse return;
        session.state = .ExpectOp;
        // The round replaced the inactivity deadline with its own (2.7); the
        // idle session goes back to the full inactivity interval.
        self.armDeadline(session_id, session, self.ctrl.cfg.session_inactivity_timeout.value.nanos);
        if (session.op != .close) return;

        // A Close ends the session: the front learns about it through the
        // complaint of 2.5 and takes the socket through the deferred close.
        self.pushComplaint(.closed, session.client_fd, session.client_tag, session_id);
        self.disarmDeadline(session);
        _ = self.sessions.remove(session_id);
    }

    /// Hands a faulty client over to the parent front (2.3): a cross-task slot
    /// carrying the complaint and a `MSG_RING` into the ring every task of this
    /// index arrived through. The counter bump belongs to the caller, which
    /// owns the retirement point of the operation.
    fn pushComplaint(self: *Self, code: cross_task.Code, fd: posix.fd_t, tag: usize, session_id: u128) void {
        const id = self.indexIdx();
        const slot_idx = self.ctrl.cross_slots.acquire() catch |err| {
            self.log.err("could not acquire a complaint slot", .{
                .ring_idx = id.ring_idx,
                .fd = fd,
                .err = @errorName(err),
            });
            return;
        };
        self.ctrl.cross_slots.at(slot_idx).* = .{ .Complaint = .{
            .code = code,
            .fd = fd,
            .tag = tag,
            .session_id = session_id,
        } };

        const front_ring = &self.ctrl.rings[id.front_idx].ring;
        while (true) {
            if (self.ring.ring.pushMsgRing(front_ring, messages.CrossTaskMessageIdx, slot_idx, .{})) |_| {
                return;
            } else |err| switch (err) {
                error.RingFull => std.atomic.spinLoopHint(),
            }
        }
    }

    /// Arms the wheel deadline of a session (2.3) `nanos` from now. The entry
    /// is scheduled the tick distance ahead and carries the second it must not
    /// expire before: a wheel round shorter than the deadline re-arms it, so
    /// the session expires at its second and never earlier.
    fn armDeadline(self: *Self, session_id: u128, session: *state.Session, nanos: i64) void {
        self.armSessionDeadlineAt(session_id, session, currentSecond() +% durationSeconds(nanos));
    }

    /// Arms the deadline of a session for the absolute second `due`.
    fn armSessionDeadlineAt(self: *Self, session_id: u128, session: *state.Session, due: u32) void {
        self.disarmDeadline(session);

        self.deadline_serial +%= 1;
        const token = self.deadline_serial;
        const handle = self.wheel.add_delay(token, ticksUntil(due, self.ticks_per_second)) catch |err| {
            self.log.err("could not arm a session deadline", .{
                .ring_idx = self.indexIdx().ring_idx,
                .err = @errorName(err),
            });
            return;
        };
        self.deadlines.put(token, .{
            .handle = handle,
            .due_second = due,
            .target = .{ .session = session_id },
        }) catch |err| {
            self.wheel.delete_by_index(handle);
            self.log.err("could not record a session deadline", .{
                .ring_idx = self.indexIdx().ring_idx,
                .err = @errorName(err),
            });
            return;
        };
        session.wheel_idx = token;
    }

    /// Withdraws the armed deadline of a session, if any.
    fn disarmDeadline(self: *Self, session: *state.Session) void {
        const token = session.wheel_idx orelse return;
        session.wheel_idx = null;

        const deadline = self.deadlines.get(token) orelse return;
        self.wheel.delete_by_index(deadline.handle);
        _ = self.deadlines.remove(token);
    }

    /// One relayed tick: the wheel matures the stripe of this instant and every
    /// matured session is asked whether it outlived its inactivity interval.
    /// The answer is read from its socket's `last tick` (2.3): a socket that
    /// moved since the deadline was armed moves the session on, one that did
    /// not expires into the replay.
    fn handleTick(self: *Self, second: u32) void {
        const shifted = self.wheel.shift(self.wheel_scratch) catch |err| {
            self.log.err("the session wheel could not shift", .{
                .ring_idx = self.indexIdx().ring_idx,
                .err = @errorName(err),
            });
            return;
        };
        self.wheel_scratch = shifted.backing;

        for (shifted.backing[0..shifted.size]) |token| self.mature(token, second);

        // Stage 6: the background synchronization and the leadership takeover
        // ride the same tick (2.6, docs/consensus.md).
        self.syncMirrors(second);
    }

    /// Applies one matured deadline: the entry is either re-armed or dropped.
    fn mature(self: *Self, token: u64, second: u32) void {
        const deadline = self.deadlines.get(token) orelse return;
        _ = self.deadlines.remove(token);

        switch (deadline.target) {
            .session => |session_id| self.matureSession(session_id, deadline, second),
            .mirror => |host| self.matureMirror(host, deadline, second),
            .dial => |host| self.matureDial(host, deadline, second),
            .proposal => |host| self.matureProposal(host, deadline, second),
        }
    }

    /// Applies the deadline of one session (2.3): a consensus round that
    /// outlived its acknowledgement window is released, a violated session
    /// waits out the replay window, an ordinary one is asked whether its
    /// socket moved from its `last tick`.
    fn matureSession(self: *Self, session_id: u128, deadline: Deadline, second: u32) void {
        const session = self.sessions.getPtr(session_id) orelse return;
        session.wheel_idx = null;

        if (session.state == .Violated) {
            if (second < deadline.due_second) {
                self.armSessionDeadlineAt(session_id, session, deadline.due_second);
                return;
            }
            // The violator's window is over and the entry goes to the replay
            // (2.5, stage 6).
            self.replaySession(session_id, second, .violated);
            return;
        }

        if (session.state == .ExpectConsensus) {
            if (second < deadline.due_second) {
                self.armSessionDeadlineAt(session_id, session, deadline.due_second);
                return;
            }
            // The acknowledgement deadline of the round expired (2.7): the
            // mirrors did not answer in time. The round is abandoned and the
            // client is told so through the ordinary reply path, exactly as a
            // failed flush is. The index state does not move, since nothing
            // was acknowledged.
            self.log.warn("consensus round outlived its acknowledgement deadline", .{
                .ring_idx = self.indexIdx().ring_idx,
                .accepted = session.consensus_progress.accepted,
                .quorum = quorumOf(self.ctrl.cfg.replication.factor),
                .session_id_hi = @as(u64, @truncate(session_id >> 64)),
                .session_id_lo = @as(u64, @truncate(session_id)),
            });
            session.state = .ExpectReply;
            var text: [reply.max_len]u8 = undefined;
            const body = reply.encode(.nack, session_id, &text);
            self.writeDirect(session_id, session.client_fd, true, body);
            return;
        }

        const last = self.ctrl.sockets.lastTick(session.client_fd);
        if (second -% last < self.inactivity_secs) {
            self.armDeadline(session_id, session, self.ctrl.cfg.session_inactivity_timeout.value.nanos);
            return;
        }

        // The client is gone and the session is idle past its interval: it
        // goes to the replay (2.3, stage 6).
        self.log.info("session expired into the replay", .{
            .ring_idx = self.indexIdx().ring_idx,
            .session_id_hi = @as(u64, @truncate(session_id >> 64)),
            .session_id_lo = @as(u64, @truncate(session_id)),
            .last_tick = last,
        });
        self.replaySession(session_id, second, .idle);
    }

    /// Applies the deadline of one mirror connection (2.3): the retry of a
    /// peer this host dials. A retry longer than a wheel round re-arms the
    /// entry until its second really came.
    fn matureMirror(self: *Self, host: u8, deadline: Deadline, second: u32) void {
        self.connect_tokens[host] = null;
        if (second < deadline.due_second) {
            self.armMirrorDeadline(host, deadline.due_second);
            return;
        }

        self.connect_state[host] = .waiting_connect;
        self.dialMirror(host, self.mirrorEndpoint(host)) catch |err| {
            self.log.warn("mirror redial failed", .{
                .ring_idx = self.indexIdx().ring_idx,
                .host_idx = host,
                .err = @errorName(err),
            });
            self.parkMirrorRetry(host);
        };
    }

    /// Applies the deadline of a connect in flight (2.3): a connect that
    /// neither completed nor failed within `consensus_timeout` is abandoned,
    /// the socket closed and the pair parked for a retry. A window longer than
    /// a wheel round re-arms the entry until its second really came.
    fn matureDial(self: *Self, host: u8, deadline: Deadline, second: u32) void {
        self.dial_tokens[host] = null;
        if (second < deadline.due_second) {
            self.armDialDeadlineAt(host, deadline.due_second);
            return;
        }

        if (self.mirror_fds[host] < 0 or self.connect_state[host] != .waiting_connect) return;

        self.log.warn("mirror connect outlived its deadline", .{
            .ring_idx = self.indexIdx().ring_idx,
            .host_idx = host,
            .fd = self.mirror_fds[host],
            .due_second = deadline.due_second,
        });
        self.dropMirror(host, -1);
    }

    /// Tells the parent front that this index has stopped. The front ignores
    /// the payload and reads its own per-index bit set instead.
    fn reportDrained(self: *Self) void {
        const id = self.indexIdx();
        const front_ring = &self.ctrl.rings[id.front_idx].ring;
        while (true) {
            if (self.ring.ring.pushMsgRing(front_ring, messages.IndexDrainedIdx, id.ring_idx, .{})) |_| {
                return;
            } else |err| switch (err) {
                error.RingFull => std.atomic.spinLoopHint(),
            }
        }
    }

    // -- Stage 6: the replay, the isolation and the background sync. --

    /// The replay (compensation) process, a plain synchronous call on the
    /// controller: the session leaves the live table and its debt is recorded
    /// with the second it may start at. The consumer that would play the
    /// accumulated data does not exist yet, the sessions storing none.
    pub fn replaySession(self: *Self, session_id: u128, second: u32, reason: replay.Reason) void {
        self.replaySessionAt(session_id, second, reason, 0);
    }

    /// The replay of one session, under the successor id a takeover gave it.
    fn replaySessionAt(self: *Self, session_id: u128, second: u32, reason: replay.Reason, successor: u128) void {
        if (self.sessions.getPtr(session_id)) |session| self.disarmDeadline(session);
        _ = self.sessions.remove(session_id);

        const host_idx = state.IndexState.unpack(session_id).host_id;
        self.replay.push(.{
            .session_id = session_id,
            .at = second,
            .reason = reason,
            .host_idx = host_idx,
            .successor = successor,
        });
        self.log.info("session handed to the replay", .{
            .ring_idx = self.indexIdx().ring_idx,
            .reason = reason.string(),
            .host_idx = host_idx,
            .due_second = second,
            .session_id_hi = @as(u64, @truncate(session_id >> 64)),
            .session_id_lo = @as(u64, @truncate(session_id)),
        });
    }

    /// Applies an isolation (docs/consensus.md): the peer is fenced in its
    /// current epoch and the sessions at or below the carried boundary wait in
    /// its isolated FIFO for a capture. An own decision and a mirror's command
    /// share this reaction.
    fn isolateHost(self: *Self, host_state: u128) mirror.Isolation {
        const leader = state.IndexState.unpack(host_state);
        if (leader.host_id >= self.mirrors.len) return .empty;
        if (leader.host_id == self.ownHost()) {
            // A restarted host isolates its own past state (docs/consensus.md);
            // this build has no log of the past epoch to isolate.
            self.log.warn("isolation of the own state ignored", .{
                .ring_idx = self.indexIdx().ring_idx,
                .epoch = @as(u64, leader.epoch_id),
            });
            return .empty;
        }

        const peer = &self.mirrors[leader.host_id];
        const fence = peer.fence(host_state);
        if (fence > self.expected_epoch[leader.host_id]) self.expected_epoch[leader.host_id] = fence;

        const outcome = peer.isolate(host_state) catch |err| {
            self.log.err("could not isolate a peer", .{
                .ring_idx = self.indexIdx().ring_idx,
                .host_idx = leader.host_id,
                .err = @errorName(err),
            });
            return .empty;
        };

        self.log.info("peer isolated", .{
            .ring_idx = self.indexIdx().ring_idx,
            .host_idx = leader.host_id,
            .epoch = @as(u64, fence),
            .boundary = leader.index,
            .outcome = @tagName(outcome),
        });
        return outcome;
    }

    /// Opens the isolation vote of a peer this index is behind on (stage 7):
    /// the boundary is the newest state heard about it, and the shard decides.
    /// A single viewpoint never fences a healthy host by itself: the decision
    /// needs the quorum of `quorumOf`, the own vote counted.
    fn initiateIsolate(self: *Self, host: u8, second: u32) void {
        const boundary = self.sync[host].known;
        if (state.IndexState.unpack(boundary).host_id != host) return;
        if (self.proposals[host] != null) return;
        if (second < self.vote_backoff[host]) return;

        const factor = self.ctrl.cfg.replication.factor;
        const quorum = quorumOf(factor);
        var proposal = Proposal{
            .boundary = boundary,
            .accepted = 1,
            .rejected = 0,
            .outstanding = 0,
            .second = second,
        };

        var peer: u8 = 0;
        while (peer < factor and peer < max_hosts) : (peer += 1) {
            if (peer == self.ownHost()) continue;
            if (self.connect_state[peer] != .established) continue;
            if (self.mirror_fds[peer] < 0) continue;
            if (!self.sendFrame(peer, .{
                .seq_id = self.send_seq[peer],
                .host_idx = self.ownHost(),
                .host_state = self.state,
                .op = .{ .isolate_proposal = .{ .host_state = boundary } },
            })) continue;
            proposal.asked.set(peer);
            proposal.outstanding += 1;
        }

        if (proposal.accepted + proposal.outstanding < quorum) {
            self.backOffVote(host, second);
            self.log.warn("isolation vote cannot reach its quorum", .{
                .ring_idx = self.indexIdx().ring_idx,
                .host_idx = host,
                .accepted = proposal.accepted,
                .outstanding = proposal.outstanding,
                .quorum = quorum,
                .second = second,
            });
            return;
        }

        self.proposals[host] = proposal;
        if (proposal.accepted >= quorum) {
            self.decideIsolate(host);
            return;
        }
        self.armProposalDeadline(host, second +% durationSeconds(self.ctrl.cfg.consensus_timeout.value.nanos));
    }

    /// The quorum approved an isolation (stage 7): the peer is fenced, the
    /// sessions at or below the boundary wait for a capture, the decision is
    /// replicated to the shard and the `Isolate` command is written to this
    /// host's own log (docs/consensus.md).
    fn decideIsolate(self: *Self, host: u8) void {
        const proposal = self.proposals[host] orelse return;
        const boundary = proposal.boundary;
        self.clearProposal(host);

        self.vote_backoff[host] = 0;
        _ = self.isolateHost(boundary);
        self.broadcast(.{ .isolate = .{ .host_state = boundary } });
        self.appendOwnCommand(.{ .isolate = .{ .host_state = boundary, .own_state = self.state } });

        self.log.info("isolation decided by the shard's quorum", .{
            .ring_idx = self.indexIdx().ring_idx,
            .host_idx = host,
            .accepted = proposal.accepted,
            .quorum = quorumOf(self.ctrl.cfg.replication.factor),
            .second = proposal.second,
        });
    }

    /// `IsolateProposal` from a mirror (stage 7): one host asks the shard to
    /// isolate a peer it sees lost. This index only votes here; the decision
    /// and its `Isolate` command arrive from the initiator once the quorum
    /// approved, so no single viewpoint can fence a healthy host.
    fn applyMirrorProposal(self: *Self, host: u8, frame: wire.Frame, proposal: wire.Isolate) void {
        const allowed = self.commandBarrier(host, frame) orelse return;
        if (!allowed) return self.sendAnswer(host, false, .{ .isolate_proposal = proposal.host_state });

        const target = state.IndexState.unpack(proposal.host_state);
        // The own state is never isolated by a vote: a restarted host isolates
        // its own past itself (docs/consensus.md). A boundary this index never
        // heard about is voted against, the voter not knowing that state.
        const known = if (target.host_id < self.sync.len)
            state.IndexState.unpack(self.sync[target.host_id].known).index
        else
            0;
        const accept = target.host_id < self.mirrors.len and
            target.host_id != self.ownHost() and
            known >= target.index;

        self.log.info("isolation vote received", .{
            .ring_idx = self.indexIdx().ring_idx,
            .host_idx = target.host_id,
            .boundary = target.index,
            .accept = accept,
        });
        self.sendAnswer(host, accept, .{ .isolate_proposal = proposal.host_state });
    }

    /// One answer to the isolation vote this index opened (stage 7): the epoch
    /// barrier of docs/consensus.md applies, the quorum decides, and a vote
    /// that can no longer reach it is dropped.
    fn noteProposalAnswer(self: *Self, host: u8, sent: state.ConsensusResponse, boundary: u128, epoch: u128) void {
        const target = state.IndexState.unpack(boundary).host_id;
        if (target >= self.proposals.len) return;

        const proposal = if (self.proposals[target]) |*pending| pending else return;
        if (proposal.boundary != boundary or proposal.outstanding == 0) return;
        if (!proposal.asked.isSet(host)) return;
        proposal.asked.unset(host);
        proposal.outstanding -= 1;

        switch (self.barrierResponse(host, sent, epoch)) {
            .ack => proposal.accepted += 1,
            .nack => proposal.rejected += 1,
            .abstain => {},
        }

        const quorum = quorumOf(self.ctrl.cfg.replication.factor);
        if (proposal.accepted >= quorum) {
            self.decideIsolate(target);
            return;
        }
        if (proposal.accepted + proposal.outstanding < quorum) {
            self.backOffVote(target, currentSecond());
            self.log.warn("isolation vote lost its quorum", .{
                .ring_idx = self.indexIdx().ring_idx,
                .host_idx = target,
                .accepted = proposal.accepted,
                .rejected = proposal.rejected,
                .quorum = quorum,
            });
            self.clearProposal(target);
        }
    }

    /// Keeps a host out of the vote for one acknowledgement window, so a shard
    /// that cannot or will not decide is asked once per window rather than on
    /// every tick (stage 7).
    fn backOffVote(self: *Self, host: u8, second: u32) void {
        self.vote_backoff[host] = second +% durationSeconds(self.ctrl.cfg.consensus_timeout.value.nanos);
    }

    /// Withdraws a vote and its wheel deadline, whatever its outcome.
    fn clearProposal(self: *Self, host: u8) void {
        self.proposals[host] = null;
        const token = self.proposal_tokens[host] orelse return;
        self.proposal_tokens[host] = null;

        const deadline = self.deadlines.get(token) orelse return;
        self.wheel.delete_by_index(deadline.handle);
        _ = self.deadlines.remove(token);
    }

    /// Arms the deadline of one isolation vote (stage 7): a shard that does not
    /// answer within `consensus_timeout` refuses the isolation, and the next
    /// silent tick votes again.
    fn armProposalDeadline(self: *Self, host: u8, due: u32) void {
        self.deadline_serial +%= 1;
        const token = self.deadline_serial;
        const handle = self.wheel.add_delay(token, ticksUntil(due, self.ticks_per_second)) catch |err| {
            self.log.err("could not arm an isolation vote deadline", .{
                .ring_idx = self.indexIdx().ring_idx,
                .host_idx = host,
                .err = @errorName(err),
            });
            return;
        };
        self.deadlines.put(token, .{
            .handle = handle,
            .due_second = due,
            .target = .{ .proposal = host },
        }) catch |err| {
            self.wheel.delete_by_index(handle);
            self.log.err("could not record an isolation vote deadline", .{
                .ring_idx = self.indexIdx().ring_idx,
                .host_idx = host,
                .err = @errorName(err),
            });
            return;
        };
        self.proposal_tokens[host] = token;
    }

    /// Applies the deadline of one isolation vote (stage 7): an unanswered vote
    /// is dropped, so the next silent tick starts a fresh one instead of
    /// keeping a stale boundary forever.
    fn matureProposal(self: *Self, host: u8, deadline: Deadline, second: u32) void {
        self.proposal_tokens[host] = null;
        if (second < deadline.due_second) {
            self.armProposalDeadline(host, deadline.due_second);
            return;
        }

        const proposal = self.proposals[host] orelse return;
        self.proposals[host] = null;
        self.backOffVote(host, second);
        self.log.warn("isolation vote outlived its deadline", .{
            .ring_idx = self.indexIdx().ring_idx,
            .host_idx = host,
            .accepted = proposal.accepted,
            .outstanding = proposal.outstanding,
            .quorum = quorumOf(self.ctrl.cfg.replication.factor),
            .second = second,
        });
    }

    /// Writes one command record to this host's own log through the ring
    /// (stage 7). The record buffer travels with the slot, like a flush.
    fn appendOwnCommand(self: *Self, entry: wal.Entry) void {
        if (!self.wal.enabled()) return;

        var record: [wal.record_len]u8 = undefined;
        wal.encodeEntry(&record, entry);

        const allocator = self.ctrl.allocator;
        const owned = allocator.dupe(u8, &record) catch |err| {
            self.log.err("could not allocate a log command", .{
                .ring_idx = self.indexIdx().ring_idx,
                .err = @errorName(err),
            });
            return;
        };
        const task_idx = self.slots.add(.{ .log_command = .{
            .buf = owned.ptr,
            .len = @intCast(owned.len),
        } }) catch |err| {
            allocator.free(owned);
            self.log.err("could not allocate a log command slot", .{
                .ring_idx = self.indexIdx().ring_idx,
                .err = @errorName(err),
            });
            return;
        };
        self.ring.ring.pushWrite(self.wal.fd, task_idx, owned.ptr, owned.len, .{}) catch |err| {
            self.slots.del(task_idx);
            allocator.free(owned);
            self.log.err("could not arm a log command", .{
                .ring_idx = self.indexIdx().ring_idx,
                .err = @errorName(err),
            });
        };
    }

    /// Hands the head of one host's isolated FIFO to the replay: `Capture` of
    /// docs/consensus.md, carried by `Compensate` on the wire. Returns how many
    /// sessions were taken, null when the list is not there yet or the carried
    /// offset is outdated.
    fn captureIsolated(self: *Self, host_idx: u8, offset: u32, count: u16, seconds: u32, second: u32) ?usize {
        if (host_idx >= self.mirrors.len) return null;

        var batch: [capture_batch]u128 = undefined;
        const taken = self.mirrors[host_idx].captureHead(offset, count, &batch) catch |err| {
            self.log.warn("a capture cannot proceed", .{
                .ring_idx = self.indexIdx().ring_idx,
                .host_idx = host_idx,
                .err = @errorName(err),
            });
            return null;
        };

        const due = second +% seconds;
        for (taken) |session_id| self.replaySessionAt(session_id, due, .isolated, 0);

        self.log.info("isolated sessions captured", .{
            .ring_idx = self.indexIdx().ring_idx,
            .host_idx = host_idx,
            .taken = taken.len,
            .due_second = due,
        });
        return taken.len;
    }

    /// The leadership takeover of stage 6 (docs/consensus.md): the sessions of
    /// a peer that stayed silent are adopted here. Every adopted session is
    /// renumbered into this host's own state and handed to the replay, the data
    /// it accumulated not being stored yet, and the lost peer is fenced so its
    /// stale frames meet the epoch barrier.
    fn takeOverSilent(self: *Self, host: u8, second: u32) void {
        const peer = &self.mirrors[host];

        var ids: [takeover_batch]u128 = undefined;
        const taken = peer.takeReplicas(&ids);

        const fence = peer.fence(self.sync[host].known);
        if (fence > self.expected_epoch[host]) self.expected_epoch[host] = fence;

        const own = self.ownHost();
        for (taken) |session_id| {
            const successor = replay.successorOf(self.state);
            self.state = successor;
            if (own < self.sync.len) {
                self.sync[own].known = successor;
                self.sync[own].applied = successor;
            }
            self.replaySessionAt(session_id, second, .takeover, successor);
        }

        self.log.warn("leadership taken over from a silent peer", .{
            .ring_idx = self.indexIdx().ring_idx,
            .host_idx = host,
            .sessions = taken.len,
            .second = second,
        });
    }

    /// One silent peer per tick (stage 6): its sessions are taken over when
    /// this index is current on its state, and the peer is isolated when it is
    /// not. A peer already isolated only needs its batches compensated.
    fn maintainPeer(self: *Self, host: u8, second: u32) void {
        if (host == self.ownHost() or host >= self.mirrors.len) return;

        if (self.mirrors[host].fenced) {
            if (self.mirrors[host].isolated.items.len != 0) {
                _ = self.captureIsolated(host, 0, std.math.maxInt(u16), 0, second);
            }
            return;
        }

        if (self.mirrors[host].active.count() == 0) return;
        if (!self.mirrors[host].silentFor(second, self.silence_secs)) return;

        if (self.mirrorIsCurrent(host)) {
            self.takeOverSilent(host, second);
            return;
        }
        self.initiateIsolate(host, second);
    }

    /// The newest state of a host this index holds: the pointer of the replica
    /// log when it is ahead of the acknowledged one (stage 7). The two agree on
    /// every applied mutation, the log pointer being the durable copy.
    fn heldState(self: *const Self, host: u8) u128 {
        if (host >= self.mirrors.len) return 0;
        const held = self.mirrors[host].current_idx;
        if (state.IndexState.unpack(held).index >= state.IndexState.unpack(self.sync[host].applied).index) {
            return held;
        }
        return self.sync[host].applied;
    }

    /// Whether this index holds at least the newest state it heard about a
    /// host. A takeover requires it (docs/consensus.md).
    fn mirrorIsCurrent(self: *const Self, host: u8) bool {
        return state.IndexState.unpack(self.heldState(host)).index >=
            state.IndexState.unpack(self.sync[host].known).index;
    }

    /// The background synchronization of stage 6 (docs/consensus.md): every
    /// established mirror gets a pulse frame carrying one host's vector clock,
    /// the reported host moving on with each tick, so the states of the whole
    /// shard travel on the regular traffic instead of a channel of their own.
    fn syncMirrors(self: *Self, second: u32) void {
        const own = self.ownHost();
        if (own >= self.sync.len) return;
        self.sync[own].known = self.state;
        self.sync[own].applied = self.state;

        const factor = self.ctrl.cfg.replication.factor;
        if (self.driver != .cluster or factor == 0) return;

        const turn: u8 = self.pulse_turn % factor;
        var host: u8 = 0;
        while (host < factor) : (host += 1) {
            self.maintainPeer(host, second);
            if (host == own) continue;
            if (self.connect_state[host] != .established) continue;
            if (self.mirror_fds[host] < 0) continue;
            _ = self.sendFrame(host, .{
                .seq_id = self.send_seq[host],
                .host_idx = turn,
                .host_state = self.sync[turn].known,
                .op = .{ .pulse = {} },
            });
        }
        self.pulse_turn = (self.pulse_turn + 1) % factor;
    }

    /// One vector clock pair of an incoming frame (2.6): a peer reported a
    /// state of some host. A peer ahead of this index on that host makes it ask
    /// for the missing log, the answer naming the peer that reported it
    /// (docs/consensus.md).
    fn noteVector(self: *Self, host: u8, frame: wire.Frame) void {
        const reported = frame.host_idx;
        if (reported >= self.sync.len or reported == self.ownHost()) return;
        if (state.IndexState.unpack(frame.host_state).index <= state.IndexState.unpack(self.sync[reported].known).index) {
            return;
        }

        if (reported == host) {
            // A peer reporting itself: the report is about the peer's own
            // counters, which move with every operation it processes, not only
            // with the sessions it leads. This index does not mirror that state
            // (only a leader's session log is replicated), so the report is
            // taken as it is and no log of it is requested; the document asks
            // for the log of a third host (stage 6).
            self.advanceSync(reported, frame.host_state);
            return;
        }

        self.sync[reported].known = frame.host_state;
        if (self.mirrorIsCurrent(reported)) {
            self.advanceSync(reported, frame.host_state);
            return;
        }
        if (self.sync[reported].pending) return;
        if (host >= self.mirror_fds.len or self.connect_state[host] != .established) return;

        self.sync[reported].pending = true;
        const requested = self.sendFrame(host, .{
            .seq_id = self.send_seq[host],
            .host_idx = self.ownHost(),
            .host_state = self.state,
            .op = .{ .request_log = .{
                .host_idx = reported,
                .index = self.heldState(reported),
            } },
        });
        if (!requested) self.sync[reported].pending = false;

        self.log.info("requested the log of a peer ahead of this index", .{
            .ring_idx = self.indexIdx().ring_idx,
            .host_idx = reported,
            .from = host,
        });
    }

    /// Records one applied operation of a peer: this index holds the peer's
    /// state up to `leader_state`.
    fn advanceSync(self: *Self, host: u8, leader_state: u128) void {
        if (host >= self.sync.len) return;
        const at = state.IndexState.unpack(leader_state).index;
        if (at >= state.IndexState.unpack(self.sync[host].applied).index) self.sync[host].applied = leader_state;
        if (at >= state.IndexState.unpack(self.sync[host].known).index) self.sync[host].known = leader_state;
    }

    /// The epoch barrier of docs/consensus.md applied to a stage-6 command: a
    /// stale sender is refused with a hard `Nack` (`false`), a sender ahead of
    /// this host leaves it abstaining (`null`), and only an equal epoch lets
    /// the command in (`true`).
    fn commandBarrier(self: *Self, host: u8, frame: wire.Frame) ?bool {
        if (host >= self.expected_epoch.len) return null;
        const epoch = state.IndexState.unpack(frame.host_state).epoch_id;
        return switch (state.compareEpoch(epoch, self.expected_epoch[host])) {
            .lt => false,
            .gt => null,
            .eq => true,
        };
    }

    /// Answers one command back to the mirror that sent it (stages 6 and 7).
    fn sendAnswer(self: *Self, host: u8, ack: bool, answer: wire.Acknowledged) void {
        if (host >= self.mirror_fds.len) return;
        const sent: wire.Operation = if (ack)
            .{ .ack = .{ .epoch = self.epochId(), .op = answer } }
        else
            .{ .nack = .{ .epoch = self.epochId(), .op = answer } };
        _ = self.sendFrame(host, .{
            .seq_id = self.send_seq[host],
            .host_idx = self.ownHost(),
            .host_state = self.state,
            .op = sent,
        });
    }

    /// Replicates one command to every established mirror (stages 6 and 7). The
    /// answers are informational: the shard's decision does not wait for them,
    /// the commands being idempotent at the receivers.
    fn broadcast(self: *Self, op: wire.Operation) void {
        const factor = self.ctrl.cfg.replication.factor;
        var host: u8 = 0;
        while (host < factor) : (host += 1) {
            if (host == self.ownHost() or host >= self.mirror_fds.len) continue;
            if (self.connect_state[host] != .established) continue;
            if (self.mirror_fds[host] < 0) continue;
            _ = self.sendFrame(host, .{
                .seq_id = self.send_seq[host],
                .host_idx = self.ownHost(),
                .host_state = self.state,
                .op = op,
            });
        }
    }

    /// `Isolate` from a mirror (stage 6).
    fn applyMirrorIsolate(self: *Self, host: u8, frame: wire.Frame, isolate: wire.Isolate) void {
        const allowed = self.commandBarrier(host, frame) orelse return;
        if (!allowed) return self.sendAnswer(host, false, .{ .isolate = isolate.host_state });
        _ = self.isolateHost(isolate.host_state);
        self.sendAnswer(host, true, .{ .isolate = isolate.host_state });
    }

    /// `Compensate` from a mirror: `count` sessions off the head of the carried
    /// host's isolated FIFO go to the replay.
    fn applyMirrorCompensate(self: *Self, host: u8, frame: wire.Frame, compensate: wire.Compensate) void {
        const allowed = self.commandBarrier(host, frame) orelse return;
        if (!allowed) return self.sendAnswer(host, false, .{ .compensate = compensate });

        const taken = self.captureIsolated(compensate.host_idx, 0, compensate.count, 0, currentSecond());
        if (taken == null) {
            // Nothing isolated yet: the initiator retries later
            // (`EpochNotIsolatedYet` of docs/consensus.md).
            self.sendAnswer(host, false, .{ .compensate = compensate });
            return;
        }
        self.sendAnswer(host, true, .{ .compensate = compensate });
    }

    /// `RestartIn` from a mirror: one session waits for its replay second.
    fn applyMirrorRestartIn(self: *Self, host: u8, frame: wire.Frame, restart_in: wire.RestartIn) void {
        const allowed = self.commandBarrier(host, frame) orelse return;
        if (!allowed) return self.sendAnswer(host, false, .{ .restart_in = restart_in });

        const due = currentSecond() +% restart_in.seconds;
        self.replaySessionAt(restart_in.session_id, due, .restart_in, 0);
        self.sendAnswer(host, true, .{ .restart_in = restart_in });
    }

    /// `Restart` from a mirror: the first session of the carried host's list
    /// goes to the replay, provided this index holds at least the carried state
    /// of that host (docs/consensus.md).
    fn applyMirrorRestart(self: *Self, host: u8, frame: wire.Frame, min_state: u128) void {
        const allowed = self.commandBarrier(host, frame) orelse return;
        if (!allowed) return self.sendAnswer(host, false, .{ .restart = min_state });

        const leader = state.IndexState.unpack(min_state);
        if (leader.host_id >= self.mirrors.len or
            state.IndexState.unpack(self.heldState(leader.host_id)).index < leader.index)
        {
            // The list is not there yet: the initiator retries later.
            self.sendAnswer(host, false, .{ .restart = min_state });
            return;
        }

        const taken = self.captureIsolated(leader.host_id, 0, 1, 0, currentSecond());
        if (taken == null or taken.? == 0) {
            self.sendAnswer(host, false, .{ .restart = min_state });
            return;
        }
        self.sendAnswer(host, true, .{ .restart = min_state });
    }

    /// `RequestLog` of the background synchronization (stage 7): the chunk of a
    /// host's log that follows the requested state, read from this index' own
    /// log when the host is this one and from its replica log otherwise. A log
    /// this build does not keep is the honest refusal of the transport
    /// document, never a silent drop or invented data.
    fn answerLogRequest(self: *Self, host: u8, request: wire.LogRequest) void {
        var buf: [wire.max_data]u8 = undefined;
        const stored = self.readLog(request.host_idx, request.index, &buf) catch {
            return self.sendLogUnavailable(host, request, .internal_error);
        };
        const chunk = stored orelse return self.sendLogUnavailable(host, request, .out_of_date);

        _ = self.sendFrame(host, .{
            .seq_id = self.send_seq[host],
            .host_idx = self.ownHost(),
            .host_state = self.state,
            .op = .{ .requested_log = .{
                .host_idx = request.host_idx,
                .index = request.index,
                .final = chunk.final,
                .data = chunk.bytes,
            } },
        });
    }

    /// The chunk of one host's log after a state, null when this index keeps no
    /// such log (stage 7).
    fn readLog(self: *Self, host: u8, after: u128, out: []u8) !?wal.Chunk {
        if (host >= self.replica_logs.len) return null;
        if (host == self.ownHost()) {
            if (!self.wal.enabled()) return null;
            return try self.wal.readAfter(after, out);
        }
        if (!self.replica_logs[host].enabled()) return null;
        return try self.replica_logs[host].readAfter(after, out);
    }

    /// The refusal of a log request (stage 7).
    fn sendLogUnavailable(self: *Self, host: u8, request: wire.LogRequest, code: wire.LogUnavailable.Code) void {
        _ = self.sendFrame(host, .{
            .seq_id = self.send_seq[host],
            .host_idx = self.ownHost(),
            .host_state = self.state,
            .op = .{ .requested_log_not_available = .{
                .host_idx = request.host_idx,
                .index = request.index,
                .code = code,
            } },
        });
    }

    /// A chunk of a log this index asked for (stage 7): every record is
    /// appended to the local replica log of its host and applied to that host's
    /// replica state, and a non-final chunk asks the same peer for the next one.
    fn applyRequestedLog(self: *Self, host: u8, requested: wire.RequestedLog) void {
        const target = requested.host_idx;
        if (target >= self.sync.len or target >= self.replica_logs.len) return;

        var at: usize = 0;
        var last = requested.index;
        while (at + wal.record_len <= requested.data.len) : (at += wal.record_len) {
            const entry = wal.decodeEntry(requested.data[at..][0..wal.record_len]) catch {
                self.log.warn("a log chunk does not hold together, the request is retired", .{
                    .ring_idx = self.indexIdx().ring_idx,
                    .host_idx = target,
                    .bytes = requested.data.len,
                });
                self.sync[target].pending = false;
                return;
            };
            self.storeReplica(target, entry);
            self.applyReplicatedEntry(entry);
            last = wal.stateOf(entry);
        }

        self.advanceSync(target, last);
        self.sync[target].applied = last;

        if (requested.final) {
            self.sync[target].pending = false;
            self.log.info("the replica log of a peer caught up", .{
                .ring_idx = self.indexIdx().ring_idx,
                .host_idx = target,
                .state_hi = @as(u64, @truncate(last >> 64)),
                .state_lo = @as(u64, @truncate(last)),
            });
            return;
        }

        if (host >= self.mirror_fds.len or self.connect_state[host] != .established) {
            self.sync[target].pending = false;
            return;
        }
        const asked = self.sendFrame(host, .{
            .seq_id = self.send_seq[host],
            .host_idx = self.ownHost(),
            .host_state = self.state,
            .op = .{ .request_log = .{ .host_idx = target, .index = last } },
        });
        if (!asked) self.sync[target].pending = false;
    }

    /// Appends one replicated entry to the local replica log of its host
    /// (stage 7). The log is best-effort: a failed append is reported and the
    /// in-memory replica still takes the operation, the alternative being a
    /// replica that stops advancing over a full disk.
    fn storeReplica(self: *Self, host: u8, entry: wal.Entry) void {
        if (host >= self.replica_logs.len) return;
        self.replica_logs[host].append(entry) catch |err| {
            self.log.warn("could not append to a replica log", .{
                .ring_idx = self.indexIdx().ring_idx,
                .host_idx = host,
                .err = @errorName(err),
            });
        };
    }

    /// Applies one entry of another host's log to this index' copy of it
    /// (stage 7): a mutation advances the replica session, an `Isolate` command
    /// applies the isolation the peer decided.
    fn applyReplicatedEntry(self: *Self, entry: wal.Entry) void {
        switch (entry) {
            .mutation => |record| {
                const leader = state.IndexState.unpack(record.session_id);
                if (leader.host_id >= self.mirrors.len) return;
                self.mirrors[leader.host_id].advance(record.session_id, record.upgrade_idx, currentSecond()) catch |err| {
                    self.log.err("could not advance a replicated session", .{
                        .ring_idx = self.indexIdx().ring_idx,
                        .host_idx = leader.host_id,
                        .err = @errorName(err),
                    });
                };
            },
            .isolate => |command| _ = self.isolateHost(command.host_state),
        }
    }

    /// The answer of a peer that cannot serve a log request.
    fn applyLogUnavailable(self: *Self, unavailable: wire.LogUnavailable) void {
        if (unavailable.host_idx < self.sync.len) self.sync[unavailable.host_idx].pending = false;
        self.log.warn("a peer cannot serve the requested log", .{
            .ring_idx = self.indexIdx().ring_idx,
            .host_idx = unavailable.host_idx,
            .code = @tagName(unavailable.code),
        });
    }

    /// `RequestSnapshot`: the snapshot store does not exist yet, so the answer
    /// is an empty final chunk naming this index' own state.
    fn answerSnapshotRequest(self: *Self, host: u8, request: wire.SnapshotRequest) void {
        _ = self.sendFrame(host, .{
            .seq_id = self.send_seq[host],
            .host_idx = self.ownHost(),
            .host_state = self.state,
            .op = .{ .requested_snapshot = .{
                .host_idx = request.host_idx,
                .index = self.state,
                .final = true,
                .data = &.{},
            } },
        });
    }

    /// A snapshot chunk: recorded, the snapshot store not existing yet.
    fn applyRequestedSnapshot(self: *Self, requested: wire.RequestedSnapshot) void {
        self.log.info("snapshot chunk received, the snapshot store is not kept yet", .{
            .ring_idx = self.indexIdx().ring_idx,
            .host_idx = requested.host_idx,
            .bytes = requested.data.len,
            .final = requested.final,
        });
    }

    /// The `.index` payload of the role: ring, inbox and parent front slots.
    fn indexIdx(self: *const Self) @TypeOf(self.role.index) {
        return self.role.index;
    }
};

/// Builds the controller of the calling index thread and runs it to
/// completion.
pub fn run(ctrl: *lifetime.Controller, role: lifetime.Role, logger: *lifetime.LoggerStuff) void {
    var index: Index = undefined;
    index.init(ctrl, role, &logger.logger) catch |err| {
        logger.logger.err("index initialization failed", .{ .ring_idx = role.ringIdx(), .err = @errorName(err) });
        std.process.exit(1);
    };
    defer index.deinit();

    index.run(logger);
}

test "front messages carry the client endpoint" {
    const create: FrontMessage = .{ .create = .{ .fd = 5, .tag = 3 } };
    try std.testing.expectEqual(@as(posix.fd_t, 5), create.create.fd);
    try std.testing.expectEqual(@as(usize, 3), create.create.tag);

    const start = state.IndexState{ .host_id = 0, .index_id = 1, .epoch_id = 0, .index = 9 };
    const sid = start.pack();
    const op: FrontMessage = .{ .session_op = .{
        .endpoint = .{ .fd = 5, .tag = 3 },
        .session_id = sid,
        .op = .append,
    } };
    try std.testing.expectEqual(sid, op.session_op.session_id);
    try std.testing.expectEqual(state.Op.append, op.session_op.op);
    try std.testing.expectEqual(@as(u16, 1), state.IndexState.indexId(sid));
}

/// The controller and the index of one test, with a logger writing to stderr as
/// JSON: the session methods log, and an undefined logger would fault.
const Harness = struct {
    ctrl: lifetime.Controller,
    /// The controller keeps a pointer to this document, so it must outlive it.
    cfg: @import("config.zig").Config = undefined,
    logger: *lifetime.LoggerStuff,
    index: Index,

    fn init(self: *Harness) !void {
        try self.initWith(.{});
    }

    /// Opens a real stub WAL at `wal_path` (2.5 step 5).
    fn initWithWal(self: *Harness, wal_path: []const u8) !void {
        try self.initWith(.{ .wal_path = wal_path });
    }

    /// The non-fatal pole of the unknown-session reaction: the index answers
    /// with its own direct write instead of a complaint (2.7).
    fn initNonFatal(self: *Harness) !void {
        try self.initWith(.{ .unknown_fatal = false });
    }

    const Options = struct {
        /// The stub WAL path, empty when the record is not checked.
        wal_path: []const u8 = "",
        /// The fatal pole of the unknown-session reaction (2.7).
        unknown_fatal: bool = true,
        /// The shard of the process (2.7): `local` unless a test asks for a
        /// cluster.
        replication: config.Replication = .{},
        /// This host's index in the shard (2.7).
        host_index: u16 = 0,
    };

    fn initWith(self: *Harness, opts: Options) !void {
        self.cfg = .{};
        self.cfg.host_index = opts.host_index;
        self.cfg.replication = opts.replication;
        self.cfg.fronts = 1;
        self.cfg.indexes = 1;
        self.cfg.elephants = 0;
        self.cfg.queue_depth = 64;
        self.cfg.cross_task_slots = 8;
        self.cfg.sqpoll_threads = 1;
        self.cfg.ring_slots_capacity = 4096;
        self.cfg.index_inbox_capacity = 8;
        // The stub WAL is disabled unless a test asks for it: the flush path
        // then retires synchronously, so a test drives the tract with one
        // completion (the reply write).
        self.cfg.wal_path = opts.wal_path;
        self.cfg.unknown_session_is_fatal = .{ .value = opts.unknown_fatal };
        self.cfg.logging = .{
            .method = .{ .json = {} },
            .pool_capacity = 64,
            .pool_frame_size = 1024,
        };

        try self.ctrl.init(std.testing.allocator, &self.cfg);
        errdefer self.ctrl.deinit();
        // Ring 0 is the parent front's, ring 1 is this index': the tract posts
        // complaints to the former and its own writes to the latter.
        try self.ctrl.initRing(0, 1);
        errdefer self.ctrl.rings[0].deinit();
        try self.ctrl.initRing(1, 1);
        errdefer self.ctrl.rings[1].deinit();
        try self.ctrl.initIndexInbox(0, 1);

        self.logger = try self.ctrl.getInitLogger();
        errdefer std.testing.allocator.destroy(self.logger);
        errdefer self.logger.deinit(self.ctrl.allocator);

        try self.index.init(&self.ctrl, self.ctrl.roleOf(1), &self.logger.logger);
    }

    fn deinit(self: *Harness) void {
        self.index.deinit();
        self.logger.deinit(self.ctrl.allocator);
        std.testing.allocator.destroy(self.logger);
        self.ctrl.rings[1].deinit();
        self.ctrl.rings[0].deinit();
        self.ctrl.deinit();
    }

    /// Waits for the cross-task wakeup a complaint rides into the parent
    /// front's ring (2.3). `MSG_RING` is a real submission, so its completion
    /// arrives asynchronously.
    fn awaitComplaint(self: *Harness) !zigring.CQE {
        const deadline = zigring.monotonicNs() + 5 * std.time.ns_per_s;
        while (!self.ctrl.rings[0].ring.checkCQNotEmpty()) {
            if (zigring.monotonicNs() >= deadline) return error.CqeTimeout;
            std.atomic.spinLoopHint();
        }
        return self.ctrl.rings[0].ring.popCQE() orelse error.MissingCqe;
    }

    /// Drives `completions` completions through the index, the same way its
    /// service loop would. The tract of 2.5 opens one completion per op in the
    /// local mode with the stub WAL disabled: the direct client write.
    fn settle(self: *Harness, completions: usize) !void {
        var left = completions;
        while (left > 0) : (left -= 1) {
            const deadline = zigring.monotonicNs() + 5 * std.time.ns_per_s;
            while (!self.index.ring.ring.checkCQNotEmpty()) {
                if (zigring.monotonicNs() >= deadline) return error.CqeTimeout;
                std.atomic.spinLoopHint();
            }
            const cqe = self.index.ring.ring.popCQE() orelse return error.MissingCqe;
            self.index.handleCqe(self.logger, cqe);
        }
    }
};

test "index owns its controller state" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    try std.testing.expectEqual(ConsensusDriver.local, h.index.driver);
    try std.testing.expectEqual(@as(u128, 0), h.index.state);
    try std.testing.expectEqual(@as(usize, 0), h.index.sessions.count());
    try std.testing.expectEqual(
        wheelTicks(
            h.cfg.session_inactivity_timeout.value.nanos,
            h.cfg.tick_interval.value.nanos,
        ),
        h.index.wheel.ticks,
    );
    try std.testing.expect(h.index.ring == &h.ctrl.rings[1]);
    try std.testing.expect(h.index.inbox == &h.ctrl.inboxes[0]);
    try std.testing.expectEqual(h.ctrl.roleOf(1).index, h.index.role.index);

    // The service loop has no other caller in a test build; referencing it
    // keeps its body in the analyzed set of `zig build test`.
    _ = Index.run;
}

test "a create opens a session keyed by the post-bump state" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    // A real descriptor, so the test can prove the index left it open.
    var fds: [2]std.os.linux.fd_t = undefined;
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.pipe(&fds)));
    defer _ = std.os.linux.close(fds[0]);
    defer _ = std.os.linux.close(fds[1]);

    const begin = h.index.state;
    var loop = Index.LoopState{};
    try std.testing.expect(!h.index.handleTask(&loop, .{ .create = .{ .fd = fds[0], .tag = 2 } }));
    try h.settle(1);

    const id = state.IndexState.unpack(begin).bumped().pack();
    try std.testing.expectEqual(id, h.index.state);
    try std.testing.expectEqual(@as(usize, 1), h.index.sessions.count());

    const session = h.index.sessions.getPtr(id) orelse return error.MissingSession;
    try std.testing.expectEqual(state.Session.State.ExpectOp, session.state);
    try std.testing.expectEqual(begin, session.index_idx);
    try std.testing.expectEqual(id, session.upgrade_idx);
    try std.testing.expectEqual(fds[0], session.client_fd);
    try std.testing.expectEqual(@as(usize, 2), session.client_tag);

    // The front owns the descriptor: the index did not close it.
    try std.testing.expectEqual(
        std.os.linux.E.SUCCESS,
        std.os.linux.errno(std.os.linux.fcntl(fds[0], std.os.linux.F.GETFD, 0)),
    );
}

test "a session op walks the state machine and bumps the index state" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    var loop = Index.LoopState{};
    _ = h.index.handleTask(&loop, .{ .create = .{ .fd = 7, .tag = 2 } });
    try h.settle(1);
    const id = h.index.state;

    const append = SessionOp{
        .endpoint = .{ .fd = 7, .tag = 2 },
        .session_id = id,
        .op = .append,
    };
    try std.testing.expect(!h.index.handleTask(&loop, .{ .session_op = append }));
    try h.settle(1);

    // The local mode retires the operation in place: the session waits for its
    // next mutation, and the index state took the post-bump value.
    const session = h.index.sessions.getPtr(id) orelse return error.MissingSession;
    try std.testing.expectEqual(state.Session.State.ExpectOp, session.state);
    try std.testing.expectEqual(id, session.index_idx);
    try std.testing.expectEqual(state.IndexState.unpack(id).bumped().pack(), session.upgrade_idx);
    try std.testing.expectEqual(session.upgrade_idx, h.index.state);

    // A close ends the session.
    const close = SessionOp{
        .endpoint = .{ .fd = 7, .tag = 2 },
        .session_id = id,
        .op = .close,
    };
    try std.testing.expect(!h.index.handleTask(&loop, .{ .session_op = close }));
    try h.settle(1);
    try std.testing.expectEqual(@as(usize, 0), h.index.sessions.count());
}

test "an op refreshes the endpoint its reply goes to" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    var loop = Index.LoopState{};
    _ = h.index.handleTask(&loop, .{ .create = .{ .fd = 7, .tag = 2 } });
    try h.settle(1);
    const id = h.index.state;

    // The create walked the tract and left the endpoint of the operation in
    // flight on the session (2.5 step 1).
    {
        const session = h.index.sessions.getPtr(id) orelse return error.MissingSession;
        try std.testing.expectEqual(state.Session.State.ExpectOp, session.state);
        try std.testing.expectEqual(@as(posix.fd_t, 7), session.client_fd);
        try std.testing.expectEqual(@as(usize, 2), session.client_tag);
    }

    // Every op message carries the endpoint of the op in flight; the session
    // keeps that one, not the one of the create. A real pipe end is used, so
    // the reply write has a descriptor whose completion really arrives.
    var fds: [2]std.os.linux.fd_t = undefined;
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.pipe(&fds)));
    defer _ = std.os.linux.close(fds[0]);
    defer _ = std.os.linux.close(fds[1]);

    _ = h.index.handleTask(&loop, .{ .session_op = .{
        .endpoint = .{ .fd = fds[1], .tag = 6 },
        .session_id = id,
        .op = .append,
    } });
    try h.settle(1);

    const session = h.index.sessions.getPtr(id) orelse return error.MissingSession;
    try std.testing.expectEqual(state.Op.append, session.op);
    try std.testing.expectEqual(fds[1], session.client_fd);
    try std.testing.expectEqual(@as(usize, 6), session.client_tag);
}

test "a mutation before the previous one resolved is a protocol violation" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    var loop = Index.LoopState{};
    _ = h.index.handleTask(&loop, .{ .create = .{ .fd = 7, .tag = 2 } });
    try h.settle(1);
    const id = h.index.state;

    // Park the session in a phase that accepts no mutation.
    const parked = h.index.sessions.getPtr(id) orelse return error.MissingSession;
    parked.state = .ExpectConsensus;
    const state_before = h.index.state;

    const op = SessionOp{
        .endpoint = .{ .fd = 7, .tag = 2 },
        .session_id = id,
        .op = .append,
    };
    try std.testing.expect(!h.index.handleTask(&loop, .{ .session_op = op }));

    // The session is parked in `Violated` until the stage-6 replay takes it
    // over; the index state does not move, and the complaint reached the
    // parent front's ring (2.3, 2.5).
    try std.testing.expectEqual(state.Session.State.Violated, parked.state);
    try std.testing.expectEqual(state_before, h.index.state);
    try std.testing.expectEqual(@as(usize, 1), h.index.sessions.count());
    const complaint = try h.awaitComplaint();
    try std.testing.expectEqual(messages.CrossTaskMessageIdx, complaint.taskIdx());
}

test "a session op naming an unknown session changes nothing" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    var loop = Index.LoopState{};
    const op = SessionOp{
        .endpoint = .{ .fd = 7, .tag = 2 },
        .session_id = 0xdead_beef,
        .op = .append,
    };
    try std.testing.expect(!h.index.handleTask(&loop, .{ .session_op = op }));
    try std.testing.expectEqual(@as(usize, 0), h.index.sessions.count());
    try std.testing.expectEqual(@as(u128, 0), h.index.state);
}

test "the session table hashes the whole session id" {
    var table = SessionTable.init(std.testing.allocator);
    defer table.deinit();

    // The automatic integer hash of verztable cuts a key to 64 bits, so an id
    // with its host or index slice set used to fault; both halves are part of
    // the hash now.
    const high = state.IndexState{ .host_id = 3, .index_id = 7, .epoch_id = 1, .index = 0 };
    const id = high.pack();
    try table.put(id, state.Session.created(id, 0, 5, 3));
    try std.testing.expect(table.contains(id));
    try std.testing.expectEqual(@as(usize, 1), table.count());

    // Ids that share the low half but differ in their index slice stay apart.
    const other = state.IndexState{ .host_id = 3, .index_id = 8, .epoch_id = 1, .index = 0 };
    try table.put(other.pack(), state.Session.created(other.pack(), 0, 6, 7));
    try std.testing.expectEqual(@as(usize, 2), table.count());
    try std.testing.expect(table.get(other.pack()) != null);
}

test "a close ends the session and complains to the front" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    var loop = Index.LoopState{};
    _ = h.index.handleTask(&loop, .{ .create = .{ .fd = 7, .tag = 2 } });
    try h.settle(1);
    const id = h.index.state;

    const close = SessionOp{
        .endpoint = .{ .fd = 7, .tag = 2 },
        .session_id = id,
        .op = .close,
    };
    try std.testing.expect(!h.index.handleTask(&loop, .{ .session_op = close }));
    try h.settle(1);

    // The session is retired at the reply completion and the front is told to
    // take the socket through the deferred close (2.5 step 6).
    try std.testing.expectEqual(@as(usize, 0), h.index.sessions.count());
    const complaint = try h.awaitComplaint();
    try std.testing.expectEqual(messages.CrossTaskMessageIdx, complaint.taskIdx());

    // The complaint slot carries the close code and the endpoint the session
    // remembered (2.3).
    const slot_idx: u32 = @intCast(complaint.res);
    const carried = h.ctrl.cross_slots.at(slot_idx).*;
    h.ctrl.cross_slots.release(slot_idx);
    try std.testing.expectEqual(cross_task.Code.closed, carried.Complaint.code);
    try std.testing.expectEqual(@as(posix.fd_t, 7), carried.Complaint.fd);
    try std.testing.expectEqual(@as(usize, 2), carried.Complaint.tag);
}

test "an unknown session is answered directly when the reaction is not fatal" {
    var h: Harness = undefined;
    try h.initNonFatal();
    defer h.deinit();

    // A real descriptor, so the direct write of the angry reply completes.
    var fds: [2]std.os.linux.fd_t = undefined;
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.pipe(&fds)));
    defer _ = std.os.linux.close(fds[0]);
    defer _ = std.os.linux.close(fds[1]);

    var loop = Index.LoopState{};
    const op = SessionOp{
        .endpoint = .{ .fd = fds[1], .tag = 2 },
        .session_id = 0xdead_beef,
        .op = .append,
    };
    try std.testing.expect(!h.index.handleTask(&loop, .{ .session_op = op }));

    // The write is armed on the index' own ring, so the op retires through the
    // ordinary reply completion (2.5), not through a complaint.
    try h.settle(1);
    try std.testing.expect(!h.ctrl.rings[0].ring.checkCQNotEmpty());
    try std.testing.expectEqual(@as(usize, 0), h.index.sessions.count());
    try std.testing.expectEqual(@as(u128, 0), h.index.state);

    // The counter of this index moved by exactly one: the op is retired (2.3).
    const row = h.ctrl.sockets.counterRow(fds[1]) orelse return error.MissingRow;
    var retired: u32 = 0;
    for (row) |counter| retired +%= counter;
    try std.testing.expectEqual(@as(u32, 1), retired);
}

test "a violated session is re-armed once and then replayed" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    var loop = Index.LoopState{};
    _ = h.index.handleTask(&loop, .{ .create = .{ .fd = 7, .tag = 2 } });
    try h.settle(1);
    const id = h.index.state;

    const session = h.index.sessions.getPtr(id) orelse return error.MissingSession;
    session.state = .ExpectConsensus;
    const op = SessionOp{
        .endpoint = .{ .fd = 7, .tag = 2 },
        .session_id = id,
        .op = .append,
    };
    try std.testing.expect(!h.index.handleTask(&loop, .{ .session_op = op }));

    const parked = h.index.sessions.getPtr(id) orelse return error.MissingSession;
    try std.testing.expectEqual(state.Session.State.Violated, parked.state);
    const first = parked.wheel_idx orelse return error.MissingDeadline;
    const due = (h.index.deadlines.get(first) orelse return error.MissingDeadline).due_second;

    // A maturity before the replay deadline re-arms the entry, the session
    // stays parked (2.5).
    h.index.mature(first, due -% 1);
    const still = h.index.sessions.getPtr(id) orelse return error.MissingSession;
    try std.testing.expectEqual(state.Session.State.Violated, still.state);
    const second = still.wheel_idx orelse return error.MissingDeadline;

    // At the deadline the parked session goes to the replay: the entry leaves
    // the live table and the debt is recorded (2.5, stage 6).
    const second_due = (h.index.deadlines.get(second) orelse return error.MissingDeadline).due_second;
    h.index.mature(second, second_due);
    try std.testing.expectEqual(@as(usize, 0), h.index.sessions.count());

    try std.testing.expectEqual(@as(usize, 1), h.index.replay.depth());
    const debt = h.index.replay.peek() orelse return error.MissingReplay;
    try std.testing.expectEqual(replay.Reason.violated, debt.reason);
    try std.testing.expectEqual(id, debt.session_id);
    try std.testing.expectEqual(second_due, debt.at);
}

test "an idle session expires while a live one is re-armed" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    var loop = Index.LoopState{};
    _ = h.index.handleTask(&loop, .{ .create = .{ .fd = 7, .tag = 2 } });
    try h.settle(1);
    const id = h.index.state;

    const session = h.index.sessions.getPtr(id) orelse return error.MissingSession;
    const token = session.wheel_idx orelse return error.MissingDeadline;
    const due = (h.index.deadlines.get(token) orelse return error.MissingDeadline).due_second;

    // The socket moved within the inactivity interval, so the deadline slides.
    h.ctrl.sockets.bumpTick(7, due -% 1);
    h.index.mature(token, due);
    const live = h.index.sessions.getPtr(id) orelse return error.MissingSession;
    try std.testing.expect(live.wheel_idx != null);

    // Once the socket has not moved within the interval, the session expires
    // into the stage-6 replay. The armed deadline was computed from the same
    // instant, so the last tick is moved a full interval behind it.
    const next = live.wheel_idx.?;
    const next_due = (h.index.deadlines.get(next) orelse return error.MissingDeadline).due_second;
    h.ctrl.sockets.bumpTick(7, next_due -% h.index.inactivity_secs);
    h.index.mature(next, next_due);
    try std.testing.expectEqual(@as(usize, 0), h.index.sessions.count());

    // The idle session is a replay debt of its own (2.3).
    const debt = h.index.replay.peek() orelse return error.MissingReplay;
    try std.testing.expectEqual(replay.Reason.idle, debt.reason);
    try std.testing.expectEqual(id, debt.session_id);
}

test "the log appends one record per flushed op" {
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/mpy6a-wal-{d}.log", .{std.os.linux.getpid()});
    path_buf[path.len] = 0;
    const path_z: [:0]const u8 = path_buf[0..path.len :0];
    _ = std.os.linux.unlink(path_z.ptr);
    defer _ = std.os.linux.unlink(path_z.ptr);

    var h: Harness = undefined;
    try h.initWithWal(path);
    defer h.deinit();

    var loop = Index.LoopState{};
    _ = h.index.handleTask(&loop, .{ .create = .{ .fd = 7, .tag = 2 } });
    // Two completions: the WAL append and the direct client reply.
    try h.settle(2);
    const id = h.index.state;

    _ = h.index.handleTask(&loop, .{ .session_op = .{
        .endpoint = .{ .fd = 7, .tag = 2 },
        .session_id = id,
        .op = .append,
    } });
    try h.settle(2);

    const raw = std.os.linux.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, 0);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(raw));
    const fd: posix.fd_t = @intCast(raw);
    defer _ = std.os.linux.close(fd);

    // Two whole records, checksum and all: the create and the append.
    var buf: [2 * wal.record_len]u8 = undefined;
    const n = std.os.linux.read(fd, &buf, buf.len);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(n));
    try std.testing.expectEqual(buf.len, n);

    const created = try wal.decode(buf[0..wal.record_len]);
    const appended = try wal.decode(buf[wal.record_len..]);
    try std.testing.expectEqual(state.Op.create, created.op);
    try std.testing.expectEqual(state.Op.append, appended.op);
    try std.testing.expectEqual(id, created.session_id);
    try std.testing.expectEqual(id, appended.session_id);
    // The append upgrades the session state by one, exactly as it did in the
    // session table of the leader.
    try std.testing.expectEqual(state.IndexState.unpack(id).bumped().pack(), appended.upgrade_idx);
}

test "the driver follows the shard config" {
    var cfg = config.Config{};
    try std.testing.expectEqual(ConsensusDriver.local, ConsensusDriver.fromConfig(&cfg));

    const mirrors = [_]config.BindType{
        .{ .host = "h", .port = 1 },
        .{ .host = "h", .port = 2 },
        .{ .host = "h", .port = 3 },
    };
    cfg.replication = .{ .factor = 3, .mode = .{ .cluster = .{
        .bind = mirrors[0],
        .mirrors = &mirrors,
    } } };
    try std.testing.expectEqual(ConsensusDriver.cluster, ConsensusDriver.fromConfig(&cfg));
}

test "the local driver leaves the stage-2 reaction alone" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    try std.testing.expectEqual(ConsensusDriver.local, h.index.driver);

    var loop = Index.LoopState{};
    _ = h.index.handleTask(&loop, .{ .create = .{ .fd = 7, .tag = 2 } });
    try h.settle(1);
    const id = h.index.state;

    const session = h.index.sessions.getPtr(id) orelse return error.MissingSession;
    try std.testing.expectEqual(state.Session.State.ExpectOp, session.state);
    try std.testing.expectEqual(id, session.upgrade_idx);
    try std.testing.expectEqual(id, h.index.state);

    // The own vote was the whole quorum: no replica reaction was recorded,
    // and a reaction arriving after the operation retired is ignored.
    try std.testing.expectEqual(@as(u16, 0), session.consensus_progress.accepted);
    h.index.updateSessionState(id, .{ .op_acknowledged = .append });
    try std.testing.expectEqual(state.Session.State.ExpectOp, session.state);
    try std.testing.expect(!h.index.ring.ring.checkCQNotEmpty());
}

test "the local driver serves no mirror connections" {
    // A shard-shaped config whose driver is then pinned to `local`: the test
    // proves the stubs of 2.2 directly, whatever the config would select.
    const mirrors = [_]config.BindType{
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
    };
    var h: Harness = undefined;
    try h.initWith(.{ .replication = shard(mirrors[0], &mirrors) });
    defer h.deinit();

    h.index.driver = .local;

    // `connectHosts` is the Nop of 2.2: no socket is dialled, so no mirror
    // slot leaves the invalid value and no retry lands on the wheel.
    try h.index.driver.connectHosts(&h.index);
    for (h.index.mirror_fds[0..3]) |fd| try std.testing.expectEqual(@as(posix.fd_t, -1), fd);
    try std.testing.expectEqual(@as(usize, 0), h.index.deadlines.count());

    // A descriptor handed over anyway has no peer to serve. The hand-off made
    // it the index' own, so the stub releases it instead of leaking it.
    const pair = try mirrorPair();
    defer _ = std.os.linux.close(pair[1]);
    h.index.driver.connectionEstablished(&h.index, 1, pair[0]);
    try std.testing.expectEqual(
        std.os.linux.E.BADF,
        std.os.linux.errno(std.os.linux.fcntl(pair[0], std.os.linux.F.GETFD, 0)),
    );

    // A mirror answer never arrives in single-host mode; the stub is a Nop.
    h.index.driver.dispatchExpectOp(&h.index, 1, 0, .ack);
}

/// A pair of connected stream sockets: the two ends of one mirror
/// connection, handed to the two indexes the way the front hands a socket over
/// (2.3).
fn mirrorPair() ![2]posix.fd_t {
    var fds: [2]std.os.linux.fd_t = undefined;
    const res = std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(res));
    return .{ fds[0], fds[1] };
}

/// The shard of three hosts the connection tests share: the own host at
/// `own`, every mirror on an endpoint nothing listens on, so a connection
/// exists only when a test hands one over.
fn shard(own: config.BindType, mirrors: []const config.BindType) config.Replication {
    return .{ .factor = 3, .mode = .{ .cluster = .{ .bind = own, .mirrors = mirrors } } };
}

test "the cluster driver replicates a create and reaches its quorum" {
    const mirrors = [_]config.BindType{
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
    };
    const pair = try mirrorPair();

    // Two hosts of the shard, each with one index service: the leader dials
    // the follower, so the socket the front accepted on the follower's side is
    // the reply channel of the same pair (2.3).
    var leader: Harness = undefined;
    try leader.initWith(.{ .replication = shard(mirrors[0], &mirrors), .host_index = 0 });
    defer leader.deinit();

    var follower: Harness = undefined;
    try follower.initWith(.{ .replication = shard(mirrors[1], &mirrors), .host_index = 1 });
    defer follower.deinit();

    leader.index.driver.connectionEstablished(&leader.index, 1, pair[0]);
    follower.index.driver.connectionEstablished(&follower.index, 0, pair[1]);
    try std.testing.expectEqual(slots.ConnectStage.established, leader.index.connect_state[1]);
    try std.testing.expectEqual(slots.ConnectStage.established, follower.index.connect_state[0]);

    var loop = Index.LoopState{};
    _ = leader.index.handleTask(&loop, .{ .create = .{ .fd = 7, .tag = 2 } });
    const id = leader.index.state;
    const session = leader.index.sessions.getPtr(id) orelse return error.MissingSession;

    // The own vote alone is one short of the quorum of three, so a request is
    // on its way to the single reachable mirror.
    try std.testing.expectEqual(state.Session.State.ExpectConsensus, session.state);
    try std.testing.expectEqual(@as(u16, 1), session.consensus_progress.accepted);

    // The request leaves, the follower acknowledges it, the answer comes back,
    // and the round is over: the stage-2 tract flushes and replies unchanged.
    try leader.settle(1);
    try follower.settle(2);
    try leader.settle(2);

    try std.testing.expectEqual(state.Session.State.ExpectOp, session.state);
    try std.testing.expectEqual(@as(u16, 2), session.consensus_progress.accepted);
    try std.testing.expectEqual(session.upgrade_idx, leader.index.state);

    // The mirror applied the mutation to its own copy of the state (2.5), so
    // its `index` slice took the same post-bump value the leader's did. The
    // host slices stay apart: each host numbers its own state.
    const applied = state.IndexState.unpack(follower.index.state);
    try std.testing.expectEqual(@as(u8, 1), applied.host_id);
    try std.testing.expectEqual(state.IndexState.unpack(id).index, applied.index);
    try std.testing.expectEqual(@as(u64, 1), applied.index);
}

test "a round without its quorum is released by its acknowledgement deadline" {
    const mirrors = [_]config.BindType{
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
    };
    // A real descriptor, so the angry reply of the abandoned round completes.
    var fds: [2]std.os.linux.fd_t = undefined;
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.pipe(&fds)));
    defer _ = std.os.linux.close(fds[0]);
    defer _ = std.os.linux.close(fds[1]);

    var h: Harness = undefined;
    try h.initWith(.{ .replication = shard(mirrors[0], &mirrors), .host_index = 0 });
    defer h.deinit();

    // No mirror is connected, so the own vote is one short of the quorum of
    // three and the round waits for an answer that cannot come.
    var loop = Index.LoopState{};
    _ = h.index.handleTask(&loop, .{ .create = .{ .fd = fds[1], .tag = 2 } });
    const id = h.index.state;
    const session = h.index.sessions.getPtr(id) orelse return error.MissingSession;
    try std.testing.expectEqual(state.Session.State.ExpectConsensus, session.state);
    try std.testing.expectEqual(@as(u16, 1), session.consensus_progress.accepted);

    // The round replaced the inactivity deadline with `consensus_timeout`
    // (2.7). Matured early, it is re-armed for the same second.
    const token = session.wheel_idx orelse return error.MissingDeadline;
    const due = (h.index.deadlines.get(token) orelse return error.MissingDeadline).due_second;
    try std.testing.expectEqual(
        durationSeconds(h.cfg.consensus_timeout.value.nanos),
        due -% currentSecond(),
    );
    h.index.mature(token, due -% 1);
    const still = h.index.sessions.getPtr(id) orelse return error.MissingSession;
    try std.testing.expectEqual(state.Session.State.ExpectConsensus, still.state);
    const next = still.wheel_idx orelse return error.MissingDeadline;
    try std.testing.expectEqual(due, (h.index.deadlines.get(next) orelse return error.MissingDeadline).due_second);

    // At the deadline the round is abandoned and the client is told so through
    // the ordinary reply path; the index state does not move, nothing having
    // been acknowledged.
    h.index.mature(next, due);
    try std.testing.expectEqual(state.Session.State.ExpectReply, still.state);
    try std.testing.expectEqual(id, h.index.state);
    try h.settle(1);

    try std.testing.expectEqual(state.Session.State.ExpectOp, still.state);
    try std.testing.expectEqual(id, h.index.state);
    try std.testing.expectEqual(@as(usize, 1), h.index.sessions.count());

    // The idle session went back to the full inactivity interval.
    try std.testing.expect(still.wheel_idx != null);
}

test "a mirror connection that cannot be dialled parks its retry on the wheel" {
    const mirrors = [_]config.BindType{
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
    };
    var h: Harness = undefined;
    try h.initWith(.{ .replication = shard(mirrors[0], &mirrors) });
    defer h.deinit();

    // Only the greater hosts are dialled (2.3): the own slot and the lesser
    // hosts belong to the peer's side of the pair.
    try h.index.driver.connectHosts(&h.index);
    try std.testing.expect(h.index.mirror_fds[0] < 0);
    try std.testing.expect(h.index.mirror_fds[1] >= 0);
    try std.testing.expect(h.index.mirror_fds[2] >= 0);

    // The dialling socket clamps its TCP retry window from
    // `consensus_timeout` (2.3), converted to the whole milliseconds the
    // option takes.
    var window: u32 = 0;
    var window_len: std.os.linux.socklen_t = @sizeOf(u32);
    const opt = std.os.linux.getsockopt(
        h.index.mirror_fds[1],
        std.os.linux.IPPROTO.TCP,
        std.os.linux.TCP.USER_TIMEOUT,
        @ptrCast(&window),
        &window_len,
    );
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(opt));
    try std.testing.expectEqual(@as(u32, 3000), window);

    // Nothing listens on the endpoints, so both connects are refused and both
    // peers are parked for a retry.
    try h.settle(2);
    try std.testing.expectEqual(@as(posix.fd_t, -1), h.index.mirror_fds[1]);
    try std.testing.expectEqual(slots.ConnectStage.waiting_connect, h.index.connect_state[1]);
    try std.testing.expect(h.index.connect_tokens[1] != null);
    try std.testing.expect(h.index.connect_tokens[2] != null);

    // The wheel round of an index outlives the retry window, so the entry is
    // re-armed until the second it was armed for arrives, and only then dials
    // again.
    const token = h.index.connect_tokens[1].?;
    const due = (h.index.deadlines.get(token) orelse return error.MissingDeadline).due_second;
    h.index.mature(token, due -% 1);
    try std.testing.expect(h.index.connect_tokens[1] != null);
    try std.testing.expect(h.index.connect_tokens[1].? != token);

    const next = h.index.connect_tokens[1].?;
    h.index.mature(next, due);
    try std.testing.expect(h.index.mirror_fds[1] >= 0);
    try h.settle(1);
}

test "a handed-over mirror socket joins the connection machine" {
    const mirrors = [_]config.BindType{
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
    };
    var h: Harness = undefined;
    try h.initWith(.{ .replication = shard(mirrors[0], &mirrors) });
    defer h.deinit();

    const pair = try mirrorPair();
    defer _ = std.os.linux.close(pair[1]);

    // The greater host dialled us, so this host never dials it: the accepted
    // descriptor arrives through the cross-task slot the front posts on the
    // index' ring (2.3), and the receive is armed at once.
    const slot_idx = try h.ctrl.cross_slots.acquire();
    h.ctrl.cross_slots.at(slot_idx).* = .{ .MirrorSocket = .{ .fd = pair[0], .host_idx = 2 } };

    h.index.acceptMirrorSocket(slot_idx);
    try std.testing.expectEqual(pair[0], h.index.mirror_fds[2]);
    try std.testing.expectEqual(slots.ConnectStage.established, h.index.connect_state[2]);
    try std.testing.expect(h.index.recv_armed[2]);
}

test "a connect that outlives its deadline is abandoned and retried" {
    const mirrors = [_]config.BindType{
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
    };
    var h: Harness = undefined;
    try h.initWith(.{ .replication = shard(mirrors[0], &mirrors) });
    defer h.deinit();

    try h.index.driver.connectHosts(&h.index);
    try std.testing.expect(h.index.mirror_fds[1] >= 0);

    // The dial arms its deadline from `consensus_timeout` (2.3).
    const token = h.index.dial_tokens[1] orelse return error.MissingDeadline;
    const due = (h.index.deadlines.get(token) orelse return error.MissingDeadline).due_second;
    try std.testing.expectEqual(
        durationSeconds(h.cfg.consensus_timeout.value.nanos),
        due -% currentSecond(),
    );

    // Matured before its second, the entry is re-armed: the connect is still
    // in flight and a shorter wheel round must not expire it early.
    h.index.mature(token, due -% 1);
    try std.testing.expect(h.index.dial_tokens[1] != null);
    try std.testing.expect(h.index.dial_tokens[1].? != token);
    try std.testing.expect(h.index.mirror_fds[1] >= 0);

    // At the deadline the connect is abandoned: the socket is closed and the
    // pair parked for a retry, exactly as a failed connect is.
    const fd_before = h.index.mirror_fds[1];
    h.index.mature(h.index.dial_tokens[1].?, due);
    try std.testing.expectEqual(@as(posix.fd_t, -1), h.index.mirror_fds[1]);
    try std.testing.expectEqual(slots.ConnectStage.waiting_connect, h.index.connect_state[1]);
    try std.testing.expect(h.index.connect_tokens[1] != null);
    try std.testing.expectEqual(
        std.os.linux.E.BADF,
        std.os.linux.errno(std.os.linux.fcntl(fd_before, std.os.linux.F.GETFD, 0)),
    );

    // The stale completions of the abandoned connects find no descriptor and
    // change nothing; the retry is the only way back.
    try h.settle(2);
    try std.testing.expectEqual(@as(posix.fd_t, -1), h.index.mirror_fds[1]);
    try std.testing.expectEqual(@as(posix.fd_t, -1), h.index.mirror_fds[2]);
    // Both hosts park their retry: the abandoned connect of host 1 and the
    // refused one of host 2.
    try std.testing.expectEqual(@as(usize, 2), h.index.deadlines.count());
}

test "the epoch barrier refuses a stale answer and abstains on a future one" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    // Every host is expected to speak in the local epoch until `Isolate`
    // raises one (stage 6).
    try std.testing.expectEqual(state.ConsensusResponse.ack, h.index.barrierResponse(1, .ack, 0));
    try std.testing.expectEqual(state.ConsensusResponse.nack, h.index.barrierResponse(1, .nack, 0));
    // A host this one already passed is stale, whether it agrees or not.
    try std.testing.expectEqual(state.ConsensusResponse.abstain, h.index.barrierResponse(1, .ack, 1));

    h.index.expected_epoch[1] = 5;
    try std.testing.expectEqual(state.ConsensusResponse.nack, h.index.barrierResponse(1, .ack, 4));
    try std.testing.expectEqual(state.ConsensusResponse.ack, h.index.barrierResponse(1, .ack, 5));
    try std.testing.expectEqual(state.ConsensusResponse.abstain, h.index.barrierResponse(1, .ack, 6));
}

/// Writes one frame into the receive buffer of `host` and returns its length.
fn stageFrame(h: *Harness, host: u8, frame: wire.Frame) usize {
    const buf = h.index.recv_bufs[host][h.index.recv_len[host]..];
    wire.encode(buf, frame);
    const len = wire.frameLen(frame.op);
    h.index.recv_len[host] += @intCast(len);
    return len;
}

test "a reordered mirror stream is applied in sequence" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    h.index.startMirrorStream(1);
    h.index.connect_state[1] = .established;

    // Two frames on one connection, the later ring number arriving first: the
    // window holds it until the missing frame lands (2.6).
    const later = wire.Frame{
        .seq_id = 1,
        .host_idx = 0,
        .host_state = 0,
        .op = .{ .append = .{ .session_id = 1, .data = &.{} } },
    };
    const earlier = wire.Frame{
        .seq_id = 0,
        .host_idx = 0,
        .host_state = 0,
        .op = .{ .close = 2 },
    };
    _ = stageFrame(&h, 1, later);
    _ = stageFrame(&h, 1, earlier);

    h.index.consumeMirrorFrames(1);

    // Both frames were applied, in the ring order rather than the arrival
    // order: one bump of the index state each, and the next frame expected
    // carries ring number 2.
    try std.testing.expectEqual(@as(u64, 2), h.index.recv_seq[1]);
    try std.testing.expectEqual(@as(u64, 2), state.IndexState.unpack(h.index.state).index);
    try std.testing.expectEqual(@as(u32, 0), h.index.recv_len[1]);

    // A frame already applied is dropped, not counted twice.
    _ = stageFrame(&h, 1, earlier);
    h.index.consumeMirrorFrames(1);
    try std.testing.expectEqual(@as(u64, 2), h.index.recv_seq[1]);
    try std.testing.expectEqual(@as(u64, 2), state.IndexState.unpack(h.index.state).index);
}

test "a pulse and a stage-6 command do not break the stream" {
    const endpoints = [_]config.BindType{
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
    };
    var h: Harness = undefined;
    try h.initWith(.{ .replication = shard(endpoints[0], &endpoints) });
    defer h.deinit();

    h.index.startMirrorStream(1);
    h.index.connect_state[1] = .established;

    const boundary = (state.IndexState{ .host_id = 2, .index_id = 0, .epoch_id = 0, .index = 0 }).pack();
    _ = stageFrame(&h, 1, .{ .seq_id = 0, .host_idx = 0, .host_state = 0, .op = .{ .pulse = {} } });
    _ = stageFrame(&h, 1, .{
        .seq_id = 1,
        .host_idx = 0,
        .host_state = 0,
        .op = .{ .isolate = .{ .host_state = boundary } },
    });
    _ = stageFrame(&h, 1, .{
        .seq_id = 2,
        .host_idx = 0,
        .host_state = 0,
        .op = .{ .repeat = .{ .session_id = 3, .repeat_in = 5 } },
    });

    h.index.consumeMirrorFrames(1);

    // The pulse only feeds the vector clock, the isolation fences the host it
    // names, and the mutation behind them applies as usual.
    try std.testing.expectEqual(@as(u64, 3), h.index.recv_seq[1]);
    try std.testing.expectEqual(@as(u64, 1), state.IndexState.unpack(h.index.state).index);
    try std.testing.expectEqual(@as(state.EpochId, 1), h.index.expected_epoch[2]);
    try std.testing.expect(h.index.mirrors[2].fenced);
}

/// A packed state of `host` in epoch `epoch` at `index`.
fn peerState(host: u8, epoch: state.EpochId, index: u64) u128 {
    return (state.IndexState{ .host_id = host, .index_id = 0, .epoch_id = epoch, .index = index }).pack();
}

/// The shard of three hosts the stage-6 tests share, this process being host 0
/// and nothing listening on the mirror endpoints.
fn stage6Shard(endpoints: *const [3]config.BindType) config.Replication {
    return shard(endpoints[0], endpoints);
}

test "an isolation hands a peer's sessions to its isolated list" {
    const endpoints = [_]config.BindType{
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
    };
    var h: Harness = undefined;
    try h.initWith(.{ .replication = stage6Shard(&endpoints) });
    defer h.deinit();

    // One session of host 1 lives on this index' copy of its log.
    const begin = peerState(1, 0, 0);
    const session_id = peerState(1, 0, 1);
    try h.index.mirrors[1].advance(session_id, begin, 5);
    try std.testing.expectEqual(@as(usize, 1), h.index.mirrors[1].active.count());

    // The boundary is a state the replica already reached: the isolation lands
    // at once and the session leaves the live set for the isolated list.
    try std.testing.expectEqual(mirror.Isolation.applied, h.index.isolateHost(begin));
    try std.testing.expectEqual(@as(state.EpochId, 1), h.index.expected_epoch[1]);
    try std.testing.expectEqual(@as(usize, 0), h.index.mirrors[1].active.count());

    const batch = h.index.mirrors[1].peekBatch() orelse return error.MissingBatch;
    try std.testing.expectEqual(begin, batch.boundary);
    try std.testing.expectEqual(@as(usize, 1), batch.len);

    // The same boundary is not isolated twice, and the own state is never
    // isolated: a restarted host isolates its own past itself.
    try std.testing.expectEqual(mirror.Isolation.duplicate, h.index.isolateHost(begin));
    try std.testing.expectEqual(mirror.Isolation.empty, h.index.isolateHost(h.index.state));
    // Nothing is replayed by an isolation alone: the capture of a compensation
    // is what takes the list.
    try std.testing.expectEqual(@as(usize, 0), h.index.replay.depth());
}

test "a compensation hands the isolated sessions to the replay" {
    const endpoints = [_]config.BindType{
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
    };
    var h: Harness = undefined;
    try h.initWith(.{ .replication = stage6Shard(&endpoints) });
    defer h.deinit();

    const begin = peerState(1, 0, 0);
    const session_id = peerState(1, 0, 1);
    try h.index.mirrors[1].advance(session_id, begin, 5);
    _ = h.index.isolateHost(begin);

    // Nothing is isolated for host 2 yet: the capture of 2.5 says so instead of
    // taking an empty list for an answer.
    try std.testing.expectEqual(@as(?usize, null), h.index.captureIsolated(2, 0, 8, 0, 100));

    // Host 1 has its batch: the capture takes it with the delay the command
    // carries and the replay records the debt.
    try std.testing.expectEqual(@as(?usize, 1), h.index.captureIsolated(1, 0, 8, 30, 100));
    const debt = h.index.replay.peek() orelse return error.MissingReplay;
    try std.testing.expectEqual(replay.Reason.isolated, debt.reason);
    try std.testing.expectEqual(session_id, debt.session_id);
    try std.testing.expectEqual(@as(u8, 1), debt.host_idx);
    try std.testing.expectEqual(@as(u32, 130), debt.at);

    // The batch is spent: a second capture finds the list empty.
    try std.testing.expectEqual(@as(?usize, null), h.index.captureIsolated(1, 0, 8, 0, 100));
}

test "a mirror's isolate and compensate travel the wire" {
    const endpoints = [_]config.BindType{
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
    };
    const pair = try mirrorPair();
    defer _ = std.os.linux.close(pair[1]);

    var h: Harness = undefined;
    try h.initWith(.{ .replication = stage6Shard(&endpoints) });
    defer h.deinit();
    h.index.driver.connectionEstablished(&h.index, 1, pair[0]);

    // One replicated create of host 1: the replica holds the session.
    const begin = peerState(1, 0, 0);
    const session_id = peerState(1, 0, 1);
    _ = stageFrame(&h, 1, .{
        .seq_id = 0,
        .host_idx = 1,
        .host_state = begin,
        .op = .{ .create = .{ .session_id = session_id, .data = "" } },
    });
    h.index.consumeMirrorFrames(1);
    try h.settle(1);
    try std.testing.expectEqual(@as(usize, 1), h.index.mirrors[1].active.count());

    // The shard isolates host 1 at the state the create produced.
    _ = stageFrame(&h, 1, .{
        .seq_id = 1,
        .host_idx = 1,
        .host_state = begin,
        .op = .{ .isolate = .{ .host_state = session_id } },
    });
    h.index.consumeMirrorFrames(1);
    try h.settle(1);
    try std.testing.expectEqual(@as(state.EpochId, 1), h.index.expected_epoch[1]);
    try std.testing.expectEqual(@as(usize, 1), h.index.mirrors[1].isolated.items.len);

    // The compensation of that host names it, in the epoch the isolation left
    // behind.
    _ = stageFrame(&h, 1, .{
        .seq_id = 2,
        .host_idx = 1,
        .host_state = peerState(1, 1, 1),
        .op = .{ .compensate = .{ .host_idx = 1, .count = 1 } },
    });
    h.index.consumeMirrorFrames(1);
    try h.settle(1);

    try std.testing.expectEqual(@as(usize, 1), h.index.replay.depth());
    const debt = h.index.replay.peek() orelse return error.MissingReplay;
    try std.testing.expectEqual(replay.Reason.isolated, debt.reason);
    try std.testing.expectEqual(session_id, debt.session_id);
    try std.testing.expectEqual(@as(usize, 0), h.index.mirrors[1].isolated.items.len);
}

test "a silent peer's sessions are taken over by this index" {
    const endpoints = [_]config.BindType{
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
    };
    var h: Harness = undefined;
    try h.initWith(.{ .replication = stage6Shard(&endpoints) });
    defer h.deinit();

    const begin = peerState(1, 0, 0);
    const session_id = peerState(1, 0, 1);
    try h.index.mirrors[1].advance(session_id, begin, 0);
    h.index.advanceSync(1, begin);
    h.index.mirrors[1].sawTraffic(0);
    try std.testing.expect(h.index.mirrorIsCurrent(1));

    const now = currentSecond();
    h.index.maintainPeer(1, now);

    // The replica set is empty, the session is a replay debt under an id of
    // this host, and the lost leader is fenced in the next epoch.
    try std.testing.expectEqual(@as(usize, 0), h.index.mirrors[1].active.count());
    const debt = h.index.replay.peek() orelse return error.MissingReplay;
    try std.testing.expectEqual(replay.Reason.takeover, debt.reason);
    try std.testing.expectEqual(session_id, debt.session_id);
    try std.testing.expectEqual(@as(u8, 0), state.IndexState.unpack(debt.successor).host_id);
    try std.testing.expectEqual(@as(u64, 1), state.IndexState.unpack(debt.successor).index);
    try std.testing.expectEqual(debt.successor, h.index.state);
    try std.testing.expectEqual(@as(state.EpochId, 1), h.index.expected_epoch[1]);

    // A second pass has nothing left to adopt.
    h.index.maintainPeer(1, now);
    try std.testing.expectEqual(@as(usize, 1), h.index.replay.depth());
}

test "a lagging index votes the silent peer out and isolates it on the quorum" {
    const endpoints = [_]config.BindType{
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
    };
    const pair = try mirrorPair();
    defer _ = std.os.linux.close(pair[1]);

    var h: Harness = undefined;
    try h.initWith(.{ .replication = stage6Shard(&endpoints) });
    defer h.deinit();
    h.index.driver.connectionEstablished(&h.index, 1, pair[0]);

    const begin = peerState(1, 0, 0);
    const session_id = peerState(1, 0, 1);
    try h.index.mirrors[1].advance(session_id, begin, 0);
    h.index.advanceSync(1, begin);
    // The peer is known to be four states ahead of what this index holds: the
    // sessions can be neither adopted nor isolated at the state this index
    // reached, so the shard is asked first.
    h.index.sync[1].known = peerState(1, 0, 4);
    h.index.mirrors[1].sawTraffic(0);
    try std.testing.expect(!h.index.mirrorIsCurrent(1));

    h.index.maintainPeer(1, currentSecond());

    // The vote is open and nothing is fenced yet: the own vote and the one
    // peer asked make the quorum of three.
    const proposal = h.index.proposals[1] orelse return error.MissingProposal;
    try std.testing.expectEqual(peerState(1, 0, 4), proposal.boundary);
    try std.testing.expectEqual(@as(u16, 1), proposal.accepted);
    try std.testing.expectEqual(@as(u16, 1), proposal.outstanding);
    try std.testing.expect(h.index.proposal_tokens[1] != null);
    try std.testing.expect(!h.index.mirrors[1].fenced);
    try std.testing.expectEqual(@as(usize, 0), h.index.mirrors[1].deferred.items.len);
    try h.settle(1);

    // The peer approves; the quorum is reached and the isolation lands, the
    // sessions waiting for the replica to reach the boundary it named.
    _ = stageFrame(&h, 1, .{
        .seq_id = 0,
        .host_idx = 1,
        .host_state = 0,
        .op = .{ .ack = .{ .epoch = 0, .op = .{ .isolate_proposal = proposal.boundary } } },
    });
    h.index.consumeMirrorFrames(1);

    try std.testing.expect(h.index.proposals[1] == null);
    try std.testing.expect(h.index.proposal_tokens[1] == null);
    try std.testing.expect(h.index.mirrors[1].fenced);
    try std.testing.expectEqual(@as(state.EpochId, 1), h.index.expected_epoch[1]);
    try std.testing.expectEqual(@as(usize, 1), h.index.mirrors[1].active.count());
    try std.testing.expectEqual(@as(usize, 0), h.index.replay.depth());
    try std.testing.expectEqual(@as(usize, 1), h.index.mirrors[1].deferred.items.len);
    // The decision itself is replicated to the peer that approved it.
    try h.settle(1);
}

test "an isolation vote without a reachable quorum fences nobody" {
    const endpoints = [_]config.BindType{
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
    };
    var h: Harness = undefined;
    try h.initWith(.{ .replication = stage6Shard(&endpoints) });
    defer h.deinit();

    const begin = peerState(1, 0, 0);
    try h.index.mirrors[1].advance(peerState(1, 0, 1), begin, 0);
    h.index.advanceSync(1, begin);
    h.index.sync[1].known = peerState(1, 0, 4);
    h.index.mirrors[1].sawTraffic(0);

    // No mirror is connected, so the own vote alone is short of the quorum of
    // three: the peer stays live and no vote is left behind.
    h.index.maintainPeer(1, currentSecond());

    try std.testing.expect(h.index.proposals[1] == null);
    try std.testing.expect(!h.index.mirrors[1].fenced);
    try std.testing.expectEqual(@as(usize, 1), h.index.mirrors[1].active.count());
    try std.testing.expectEqual(@as(usize, 0), h.index.mirrors[1].deferred.items.len);

    // A shard that cannot decide is not asked on every tick: the refusal holds
    // for one acknowledgement window.
    const now = currentSecond();
    try std.testing.expect(h.index.vote_backoff[1] > now);
    h.index.maintainPeer(1, now + 1);
    try std.testing.expect(h.index.proposals[1] == null);
}

test "an isolation vote that is never answered is refused by its deadline" {
    const endpoints = [_]config.BindType{
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
    };
    const pair = try mirrorPair();
    defer _ = std.os.linux.close(pair[1]);

    var h: Harness = undefined;
    try h.initWith(.{ .replication = stage6Shard(&endpoints) });
    defer h.deinit();
    h.index.driver.connectionEstablished(&h.index, 1, pair[0]);

    h.index.sync[1].known = peerState(1, 0, 4);
    h.index.mirrors[1].sawTraffic(0);
    const now = currentSecond();
    h.index.initiateIsolate(1, now);
    try h.settle(1);

    const token = h.index.proposal_tokens[1] orelse return error.MissingDeadline;
    const due = (h.index.deadlines.get(token) orelse return error.MissingDeadline).due_second;
    // The vote rides `consensus_timeout`, and matures early it is re-armed.
    try std.testing.expectEqual(durationSeconds(h.cfg.consensus_timeout.value.nanos), due -% now);
    h.index.mature(token, due -% 1);
    try std.testing.expect(h.index.proposals[1] != null);

    // At its second the vote is withdrawn; the next silent tick starts over.
    const rearmed = h.index.proposal_tokens[1] orelse return error.MissingDeadline;
    h.index.mature(rearmed, due);
    try std.testing.expect(h.index.proposals[1] == null);
    try std.testing.expect(!h.index.mirrors[1].fenced);
}

test "a mirror is answered on an isolation vote without applying it" {
    const endpoints = [_]config.BindType{
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
    };
    const pair = try mirrorPair();
    defer _ = std.os.linux.close(pair[1]);

    var h: Harness = undefined;
    try h.initWith(.{ .replication = stage6Shard(&endpoints) });
    defer h.deinit();
    h.index.driver.connectionEstablished(&h.index, 1, pair[0]);

    // This index holds host 2 up to the boundary it is asked to vote about.
    h.index.advanceSync(2, peerState(2, 0, 3));
    _ = stageFrame(&h, 1, .{
        .seq_id = 0,
        .host_idx = 1,
        .host_state = 0,
        .op = .{ .isolate_proposal = .{ .host_state = peerState(2, 0, 3) } },
    });
    h.index.consumeMirrorFrames(1);
    try h.settle(1);

    // The vote is an acceptance and nothing was isolated: the decision is the
    // initiator's to take, not theirs to announce.
    try std.testing.expect(!h.index.mirrors[2].fenced);
    try std.testing.expectEqual(@as(state.EpochId, 0), h.index.expected_epoch[2]);

    var buf: [wire.max_frame_len]u8 = undefined;
    const n = std.os.linux.read(pair[1], &buf, buf.len);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(n));
    const decoded = try wire.decode(buf[0..@intCast(n)]);
    const answer = decoded.frame.op.ack;
    try std.testing.expectEqual(peerState(2, 0, 3), answer.op.isolate_proposal);

    // A boundary this index never heard about is voted against.
    _ = stageFrame(&h, 1, .{
        .seq_id = 1,
        .host_idx = 1,
        .host_state = 0,
        .op = .{ .isolate_proposal = .{ .host_state = peerState(2, 0, 9) } },
    });
    h.index.consumeMirrorFrames(1);
    try h.settle(1);
    const n2 = std.os.linux.read(pair[1], &buf, buf.len);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(n2));
    const refusal = try wire.decode(buf[0..@intCast(n2)]);
    try std.testing.expectEqual(wire.Tag.nack, wire.tagOf(refusal.frame.op));
}

test "the restart commands schedule the replay of a session" {
    const endpoints = [_]config.BindType{
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
    };
    const pair = try mirrorPair();
    defer _ = std.os.linux.close(pair[1]);

    var h: Harness = undefined;
    try h.initWith(.{ .replication = stage6Shard(&endpoints) });
    defer h.deinit();
    h.index.driver.connectionEstablished(&h.index, 1, pair[0]);

    // `RestartIn` waits for its second before the replay may start.
    const session_id = peerState(1, 0, 1);
    const before = currentSecond();
    _ = stageFrame(&h, 1, .{
        .seq_id = 0,
        .host_idx = 1,
        .host_state = 0,
        .op = .{ .restart_in = .{ .session_id = session_id, .seconds = 120 } },
    });
    h.index.consumeMirrorFrames(1);
    try h.settle(1);

    const debt = h.index.replay.peek() orelse return error.MissingReplay;
    try std.testing.expectEqual(replay.Reason.restart_in, debt.reason);
    try std.testing.expectEqual(session_id, debt.session_id);
    try std.testing.expect(debt.at >= before + 120);

    // `Restart` of a host with nothing isolated is refused, and the refusal is
    // the honest answer instead of a silent drop.
    _ = stageFrame(&h, 1, .{
        .seq_id = 1,
        .host_idx = 1,
        .host_state = 0,
        .op = .{ .restart = peerState(2, 0, 0) },
    });
    h.index.consumeMirrorFrames(1);
    try h.settle(1);
    try std.testing.expectEqual(@as(usize, 1), h.index.replay.depth());

    // A host that reached the carried state has the first session of its list
    // run at the replay.
    const listed = peerState(2, 0, 1);
    try h.index.mirrors[2].advance(listed, peerState(2, 0, 0), 5);
    h.index.advanceSync(2, peerState(2, 0, 1));
    _ = h.index.isolateHost(peerState(2, 0, 0));

    _ = stageFrame(&h, 1, .{
        .seq_id = 2,
        .host_idx = 1,
        .host_state = 0,
        .op = .{ .restart = peerState(2, 0, 0) },
    });
    h.index.consumeMirrorFrames(1);
    try h.settle(1);

    try std.testing.expectEqual(@as(usize, 2), h.index.replay.depth());
    var debts: [2]replay.Entry = undefined;
    _ = h.index.replay.drain(&debts);
    try std.testing.expectEqual(replay.Reason.restart_in, debts[0].reason);
    try std.testing.expectEqual(replay.Reason.isolated, debts[1].reason);
    try std.testing.expectEqual(listed, debts[1].session_id);
}

test "a peer ahead of this index has the missing log requested" {
    const endpoints = [_]config.BindType{
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
    };
    const pair = try mirrorPair();
    defer _ = std.os.linux.close(pair[1]);

    var h: Harness = undefined;
    try h.initWith(.{ .replication = stage6Shard(&endpoints) });
    defer h.deinit();
    h.index.driver.connectionEstablished(&h.index, 1, pair[0]);

    // Host 1 reports host 2 seven states ahead of this index: the log is
    // requested from the reporter.
    const ahead = peerState(2, 0, 7);
    _ = stageFrame(&h, 1, .{ .seq_id = 0, .host_idx = 2, .host_state = ahead, .op = .{ .pulse = {} } });
    h.index.consumeMirrorFrames(1);

    try std.testing.expectEqual(ahead, h.index.sync[2].known);
    try std.testing.expect(h.index.sync[2].pending);
    try h.settle(1);

    // A report of the same state does not ask again while the request is in
    // flight.
    _ = stageFrame(&h, 1, .{ .seq_id = 1, .host_idx = 2, .host_state = ahead, .op = .{ .pulse = {} } });
    h.index.consumeMirrorFrames(1);
    try std.testing.expect(h.index.sync[2].pending);

    // The refusal of the peer retires the request; the replica state is not
    // invented from data this build cannot apply.
    _ = stageFrame(&h, 1, .{
        .seq_id = 2,
        .host_idx = 1,
        .host_state = 0,
        .op = .{ .requested_log_not_available = .{ .host_idx = 2, .index = 0, .code = .out_of_date } },
    });
    h.index.consumeMirrorFrames(1);
    try std.testing.expect(!h.index.sync[2].pending);
    try std.testing.expectEqual(@as(u128, 0), h.index.sync[2].applied);
}

test "the pulses of a tick carry the vector clock over the shard" {
    const endpoints = [_]config.BindType{
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
    };
    const pair = try mirrorPair();
    defer _ = std.os.linux.close(pair[1]);

    var h: Harness = undefined;
    try h.initWith(.{ .replication = stage6Shard(&endpoints) });
    defer h.deinit();
    h.index.driver.connectionEstablished(&h.index, 1, pair[0]);

    const now = currentSecond();
    h.index.syncMirrors(now);
    h.index.syncMirrors(now);
    try h.settle(2);

    // Two pulse frames left for the peer, each reporting the next host of the
    // shard: the vector clocks loop over the hosts (2.6).
    var buf: [4 * wire.header_len]u8 = undefined;
    const n = std.os.linux.read(pair[1], &buf, buf.len);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(n));
    try std.testing.expectEqual(@as(usize, 2 * wire.header_len), n);

    const first = try wire.decode(buf[0..wire.header_len]);
    const second = try wire.decode(buf[wire.header_len..][0..wire.header_len]);
    try std.testing.expectEqual(wire.Tag.pulse, wire.tagOf(first.frame.op));
    try std.testing.expectEqual(wire.Tag.pulse, wire.tagOf(second.frame.op));
    try std.testing.expectEqual(@as(u8, 0), first.frame.host_idx);
    try std.testing.expectEqual(@as(u8, 1), second.frame.host_idx);
    try std.testing.expectEqual(h.index.state, first.frame.host_state);
}

test "the restart epoch of the log moves the index state" {
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/mpy6a-epoch-{d}.log", .{std.os.linux.getpid()});
    path_buf[path.len] = 0;
    const path_z: [:0]const u8 = path_buf[0..path.len :0];
    _ = std.os.linux.unlink(path_z.ptr);
    defer _ = std.os.linux.unlink(path_z.ptr);

    var first: Harness = undefined;
    try first.initWithWal(path);
    var loop = Index.LoopState{};
    _ = first.index.handleTask(&loop, .{ .create = .{ .fd = 7, .tag = 2 } });
    try first.settle(2);
    try std.testing.expectEqual(@as(state.EpochId, 0), state.IndexState.unpack(first.index.state).epoch_id);
    first.deinit();

    // The restarted process reads its log and works in the next epoch, so the
    // sessions of the previous run are recognisable as someone else's.
    var second: Harness = undefined;
    try second.initWithWal(path);
    defer second.deinit();
    try std.testing.expectEqual(@as(state.EpochId, 1), state.IndexState.unpack(second.index.state).epoch_id);
    try std.testing.expectEqual(@as(u64, 0), state.IndexState.unpack(second.index.state).index);
    try std.testing.expectEqual(@as(u64, 0), second.index.wal.truncated);
}

/// Removes a test's own log and the replica logs derived from it: the three
/// host indexes of the shared shard and the index service 0.
fn removeLogs(path: [:0]const u8) void {
    _ = std.os.linux.unlink(path.ptr);
    var host: u8 = 0;
    while (host < 3) : (host += 1) {
        var buf: [160]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{s}.0.{d}", .{ path, host }) catch return;
        buf[text.len] = 0;
        _ = std.os.linux.unlink(buf[0..text.len :0].ptr);
    }
}

/// Reads and drops `frames` frames of `frame_len` bytes from a socket: the
/// answers a test is not interested in, so the next read sees its own frame.
fn drainFrames(fd: posix.fd_t, frames: usize, frame_len: usize) !void {
    var buf: [wire.max_frame_len]u8 = undefined;
    var total: usize = 0;
    while (total < frames * frame_len) {
        const n = std.os.linux.read(fd, &buf, buf.len);
        try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(n));
        if (n <= 0) return error.MissingFrame;
        total += @intCast(n);
    }
}

/// Writes entries to a log file the way a previous run would have, so the
/// recovery of the next run can be tested without the consensus tract.
fn writeLogEntries(path: [:0]const u8, entries: []const wal.Entry) !void {
    const raw = std.os.linux.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(raw));
    const fd: posix.fd_t = @intCast(raw);
    defer _ = std.os.linux.close(fd);

    for (entries) |entry| {
        var buf: [wal.record_len]u8 = undefined;
        wal.encodeEntry(&buf, entry);
        const res = std.os.linux.write(fd, &buf, buf.len);
        try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(res));
    }
}

test "a replicated operation lands in its host's replica log" {
    const endpoints = [_]config.BindType{
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
    };
    const pair = try mirrorPair();
    defer _ = std.os.linux.close(pair[1]);

    var path_buf: [96]u8 = undefined;
    const text = try std.fmt.bufPrint(&path_buf, "/tmp/mpy6a-replica-{d}.log", .{std.os.linux.getpid()});
    path_buf[text.len] = 0;
    const path: [:0]const u8 = path_buf[0..text.len :0];
    removeLogs(path);
    defer removeLogs(path);

    var h: Harness = undefined;
    try h.initWith(.{ .replication = stage6Shard(&endpoints), .wal_path = path });
    defer h.deinit();
    h.index.driver.connectionEstablished(&h.index, 1, pair[0]);

    // One create of host 1: the leader's operation is written to the replica
    // log of host 1 before the in-memory replica takes it (stage 7).
    const begin = peerState(1, 0, 0);
    const session_id = peerState(1, 0, 1);
    _ = stageFrame(&h, 1, .{
        .seq_id = 0,
        .host_idx = 1,
        .host_state = begin,
        .op = .{ .create = .{ .session_id = session_id, .data = "" } },
    });
    h.index.consumeMirrorFrames(1);
    try h.settle(1);

    try std.testing.expect(h.index.replica_logs[1].enabled());
    try std.testing.expectEqual(session_id, h.index.replica_logs[1].last_state);

    var out: [wal.record_len]u8 = undefined;
    const chunk = try h.index.replica_logs[1].readAfter(0, &out);
    try std.testing.expectEqual(@as(usize, wal.record_len), chunk.bytes.len);
    const entry = try wal.decodeEntry(chunk.bytes[0..wal.record_len]);
    try std.testing.expectEqual(session_id, entry.mutation.session_id);
    try std.testing.expectEqual(state.Op.create, entry.mutation.op);

    // The own host keeps no replica log: its own log is the one flushes use.
    try std.testing.expect(!h.index.replica_logs[0].enabled());
}

test "the log service answers from a replica log and the requester applies it" {
    const endpoints = [_]config.BindType{
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
    };
    const pair = try mirrorPair();
    defer _ = std.os.linux.close(pair[1]);

    var path_buf: [96]u8 = undefined;
    const text = try std.fmt.bufPrint(&path_buf, "/tmp/mpy6a-service-{d}.log", .{std.os.linux.getpid()});
    path_buf[text.len] = 0;
    const path: [:0]const u8 = path_buf[0..text.len :0];
    removeLogs(path);
    defer removeLogs(path);

    var h: Harness = undefined;
    try h.initWith(.{ .replication = stage6Shard(&endpoints), .wal_path = path });
    defer h.deinit();
    h.index.driver.connectionEstablished(&h.index, 1, pair[0]);

    // Two operations of host 1 land in this index' replica log of it.
    const first = peerState(1, 0, 1);
    const second = peerState(1, 0, 2);
    _ = stageFrame(&h, 1, .{
        .seq_id = 0,
        .host_idx = 1,
        .host_state = peerState(1, 0, 0),
        .op = .{ .create = .{ .session_id = first, .data = "" } },
    });
    _ = stageFrame(&h, 1, .{
        .seq_id = 1,
        .host_idx = 1,
        .host_state = peerState(1, 0, 0),
        .op = .{ .append = .{ .session_id = second, .data = "" } },
    });
    h.index.consumeMirrorFrames(1);
    try h.settle(2);
    // The answers to the two mutations are not what this test reads next.
    try drainFrames(pair[1], 2, wire.header_len + 16 + 1 + 16 + 4);

    // The request is answered from that log, in whole records and to its end.
    h.index.answerLogRequest(1, .{ .host_idx = 1, .index = 0 });
    try h.settle(1);

    var buf: [wire.max_frame_len]u8 = undefined;
    const got = std.os.linux.read(pair[1], &buf, buf.len);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(got));
    const served = (try wire.decode(buf[0..@intCast(got)])).frame.op.requested_log;
    try std.testing.expectEqual(@as(u8, 1), served.host_idx);
    try std.testing.expectEqual(@as(usize, 2 * wal.record_len), served.data.len);
    try std.testing.expect(served.final);

    // A host whose replica log exists but holds nothing yet is answered with
    // an empty final chunk, not with records this index does not have.
    h.index.answerLogRequest(1, .{ .host_idx = 2, .index = 0 });
    try h.settle(1);
    const empty_bytes = std.os.linux.read(pair[1], &buf, buf.len);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(empty_bytes));
    const empty = (try wire.decode(buf[0..@intCast(empty_bytes)])).frame.op.requested_log;
    try std.testing.expectEqual(@as(usize, 0), empty.data.len);
    try std.testing.expect(empty.final);

    // A second index applies the chunk: its own replica log of host 1 grows
    // and its live set takes both sessions.
    var other: Harness = undefined;
    try other.initWith(.{ .replication = stage6Shard(&endpoints), .host_index = 2, .wal_path = path });
    defer other.deinit();

    other.index.applyRequestedLog(1, served);
    // Every mutation advances the leader's state, so the append upgraded the
    // session to the state after the one its id was cut from.
    const applied = peerState(1, 0, 3);
    try std.testing.expectEqual(applied, other.index.replica_logs[1].last_state);
    try std.testing.expectEqual(applied, other.index.sync[1].applied);
    try std.testing.expectEqual(@as(usize, 2), other.index.mirrors[1].active.count());

    var log_buf: [wal.record_len]u8 = undefined;
    const stored = try other.index.replica_logs[1].readAfter(0, &log_buf);
    try std.testing.expectEqual(@as(usize, wal.record_len), stored.bytes.len);
    try std.testing.expectEqual(first, (try wal.decodeEntry(stored.bytes[0..wal.record_len])).mutation.session_id);
}

test "a log this index does not keep is refused, not invented" {
    const endpoints = [_]config.BindType{
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
    };
    const pair = try mirrorPair();
    defer _ = std.os.linux.close(pair[1]);

    // No `wal_path`: neither the own log nor a replica log is kept.
    var h: Harness = undefined;
    try h.initWith(.{ .replication = stage6Shard(&endpoints) });
    defer h.deinit();
    h.index.driver.connectionEstablished(&h.index, 1, pair[0]);

    h.index.answerLogRequest(1, .{ .host_idx = 1, .index = 0 });
    try h.settle(1);

    var buf: [wire.max_frame_len]u8 = undefined;
    const n = std.os.linux.read(pair[1], &buf, buf.len);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(n));
    const refusal = (try wire.decode(buf[0..@intCast(n)])).frame.op;
    try std.testing.expectEqual(wire.Tag.requested_log_not_available, wire.tagOf(refusal));
    try std.testing.expectEqual(wire.LogUnavailable.Code.out_of_date, refusal.requested_log_not_available.code);
}

test "the own log is written and read back across a restart" {
    const endpoints = [_]config.BindType{
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
        .{ .host = "127.0.0.1", .port = 1 },
    };

    var path_buf: [96]u8 = undefined;
    const text = try std.fmt.bufPrint(&path_buf, "/tmp/mpy6a-recover-{d}.log", .{std.os.linux.getpid()});
    path_buf[text.len] = 0;
    const path: [:0]const u8 = path_buf[0..text.len :0];
    removeLogs(path);
    defer removeLogs(path);

    // The log a previous run left behind: one session of this host in the spent
    // epoch, and the isolation decision it took about host 1.
    const orphan = peerState(0, 0, 1);
    const boundary = peerState(1, 0, 4);
    try writeLogEntries(path, &.{
        .{ .mutation = .{ .session_id = orphan, .op = .create, .upgrade_idx = orphan } },
        .{ .isolate = .{ .host_state = boundary, .own_state = orphan } },
    });

    var h: Harness = undefined;
    try h.initWith(.{ .replication = stage6Shard(&endpoints), .wal_path = path });
    defer h.deinit();

    // The restarted process works in the next epoch: the session of the old one
    // is its orphan and goes to the replay, and the command fences host 1 again.
    try std.testing.expectEqual(@as(state.EpochId, 1), state.IndexState.unpack(h.index.state).epoch_id);
    const debt = h.index.replay.peek() orelse return error.MissingReplay;
    try std.testing.expectEqual(replay.Reason.restart, debt.reason);
    try std.testing.expectEqual(orphan, debt.session_id);
    try std.testing.expectEqual(@as(usize, 1), h.index.replay.depth());
    try std.testing.expect(h.index.mirrors[1].fenced);
    try std.testing.expectEqual(@as(state.EpochId, 1), h.index.expected_epoch[1]);

    // A command of this run is written through the ring, like a flush. The
    // state before it is the position the read starts from.
    h.index.appendOwnCommand(.{ .isolate = .{
        .host_state = peerState(2, 0, 1),
        .own_state = h.index.state,
    } });
    try h.settle(1);

    var out: [wal.record_len]u8 = undefined;
    const tail = try h.index.wal.readAfter(orphan, &out);
    try std.testing.expectEqual(@as(usize, wal.record_len), tail.bytes.len);
    const written = try wal.decodeEntry(tail.bytes[0..wal.record_len]);
    try std.testing.expectEqual(peerState(2, 0, 1), written.isolate.host_state);
}
