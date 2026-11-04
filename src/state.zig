//! Shapes of the per-index session state.
//!
//! This file holds structures and the mechanical accessors that belong to
//! them. Every behavioral function lives on `lifetime.Controller`, the
//! registry for resources: when work needs memory, the compensator registry or
//! the config, it goes there.
//!
//! One index thread owns one `IndexState` per member of its index's
//! replication group: its own data set plus a mirror per remote host. The state
//! is thread-local; the G1 discipline of `timing_wheel.zig` applies (no locks,
//! no atomics).

const std = @import("std");
const verztable = @import("verztable");
const replay_queue = @import("replay_queue.zig");

/// The wire/snapshot format version written into the `IndexState` dump. A
/// loader rejects any other value with `error.UnsupportedVersion`.
pub const SNAPSHOT_VERSION: u16 = 1;

/// One configured compensator endpoint: the `compensators = fixed {...}` block
/// of the config, resolved once at startup. Key names are immutable once
/// created, a hard requirement of the source design.
pub const CompensatorEndpoint = struct {
    bind: []const u8,
    port: u16,
};

/// The compensator registry's shape; the instance lives on the
/// `lifetime.Controller` (the registry for resources).
pub const CompensatorMap = verztable.HashMapWithFns(
    []const u8,
    CompensatorEndpoint,
    hashCompensatorName,
    eqlCompensatorName,
);

/// The operations that reach the state. `docs/consensus.md` is outdated and
/// not consulted; this is the state between two consensus ops, and the op
/// stream of the future consensus driver dispatches into these tags.
pub const Op = union(enum) {
    create: struct { compensator: []const u8, payload: []const u8 },
    append: struct { session_id: u128, payload: []const u8 },
    overwrite: struct { session_id: u128, payload: []const u8 },
    close: struct { session_id: u128 },
    restart_in: struct { session_id: u128, seconds: u32 },
};

/// The capacity holder for a session's payload. Content is
/// `backing[0..len]`; growth amortizes into the spare capacity.
pub const Buffer = struct {
    backing: []u8,
    len: usize,
};

/// The four persisted fields, exactly as the source pins them. These bytes,
/// and only these, ride every codec: the replay blob, the per-session dump
/// record, the wire.
pub const SessionData = struct {
    /// A session may be a restored one, brought back for replay-compensation.
    /// Work on it then happens in a NEW session, because the data may have
    /// been moved to a completely different shard with its own settings, where
    /// this index simply does not exist and the front would go crazy figuring
    /// out which index to push the client's next portion of data into. The
    /// ORIGINAL is carried verbatim through any number of generations; for a
    /// freshly created session this is, of course, a duplicate of the
    /// session's own id.
    original_id: u128,

    /// The identifier of the service that must perform compensations for this
    /// session. Set by the user at session creation; validated by the service
    /// against the configured registry. A string rather than a number: the
    /// operation is rare, and on the logging path fetching a name by
    /// identifier would be the pain. The registry's key names must NEVER
    /// change:
    ///
    ///     compensators = fixed {
    ///         marker = bind { bind = "10.0.0.1", port = 20301 }
    ///         viper  = bind { bind = "10.0.0.2", port = 20301 }
    ///         hermes = bind { bind = "10.0.0.10", port = 20301 }
    ///     }
    ///
    /// Mind the cloud-native extensions: besides `bind` there will be `dns`,
    /// `grpc` (xDS, etcd), and eventually the compensators block becomes a
    /// runtime resolver of compensator endpoints. The session owns its copy of
    /// the name; the codec makes the session self-contained.
    compensator: []const u8,

    /// Count of compensation attempts. 0 for new sessions. A failed
    /// compensation increases it by 1, never the replay round-trip itself.
    retry_count: u32,

    /// The session's own data, chunked: `uvarint(len) || payload`,
    /// `uvarint(len) || payload`, ... Changed by Create (one chunk; a
    /// payload-free Create would cost an extra hop), Append (one chunk at the
    /// tail), Overwrite (the whole content replaced by one chunk). All other
    /// operations touch metadata only.
    data: Buffer,
};

/// The runtime session: everything meta around the persisted `SessionData`.
/// The map value is `*Session`. The meta fields are the old draft's, absorbed
/// field-for-field; the consensus driver owns their discipline, this module
/// only carries them and initializes them to the resting state.
pub const Session = struct {
    const Self = @This();

    pub const State = enum(u32) {
        ExpectOp,
        ExpectConsensus,
        ExpectAcceptedFlush,
    };
    pub const ConsensusProgress = struct {
        accepted: u16 = 0,
        rejected: u16 = 0,
    };

    id: u128,
    /// The state at which the session's current op was accepted.
    index_idx: u128,
    /// The identifier that becomes `index_idx` once the last op has
    /// successfully passed.
    upgrade_idx: u128,
    /// Current identifier in the timing wheel. Must be changed after a
    /// successful mutation or pulse.
    wheel_idx: u64,
    state: State,
    consensus_progress: ConsensusProgress,

    /// The persisted part, exactly the four source fields. The payload lives
    /// at `data.data` (a `Buffer`); the rest of this struct never serializes.
    data: SessionData,

    /// The kind of simple method allowed to stay on the struct: a trivial
    /// mutator, no resources, no logic.
    pub fn prepareForNewConsensus(self: *Self) void {
        self.consensus_progress = .{};
    }
};

/// The map of active sessions. `HashMapWithFns`, not `HashMap`: the vendored
/// `AutoHashFn` casts the key to `u64` with a checked `@intCast` and panics
/// for ids >= 2^64, and session ids carry host and epoch in the high bits.
pub const SessionsMap = verztable.HashMapWithFns(
    u128,
    *Session,
    hashSessionId,
    eqlSessionId,
);

/// One data set of one index thread: active sessions plus the sessions
/// awaiting replay, ordered by `(retry_time, session_id)`. A thread owns one
/// of these per member of its index's replication group, indexed by host_idx,
/// its own at `cfg.host_index`.
pub const IndexState = struct {
    /// The data set's current state: a full `u128` in the layout of the
    /// sibling WAL design (`host_id: u8, index_id: u16, epoch_id: u40,
    /// index: u64`), whose `index: u64` slice is the op ordinal within the
    /// current epoch. Session ids are minted from it ("the session identifier
    /// becomes equal to the current state index"). Runtime-only, never part
    /// of the dump: the snapshot's file name carries the state. Moved only by
    /// the consensus driver.
    state: u128,

    /// The active sessions of this data set, keyed by the session's current
    /// id.
    sessions: SessionsMap,

    /// The sessions awaiting replay, one blob each.
    replay_queue: replay_queue.ReplayQueue,
};

fn hashSessionId(id: u128) u64 {
    // The index slice only: valid because active sessions belong to the
    // current working epoch only, so the host/epoch prefix is constant within
    // one data set's map, and the op-index slice carries all the entropy.
    return verztable.hashInteger(@as(u64, @truncate(id)));
}

fn eqlSessionId(a: u128, b: u128) bool {
    // Full width: a hash that ignores the high bits must not let equality
    // ignore them.
    return a == b;
}

fn hashCompensatorName(name: []const u8) u64 {
    return verztable.wyhash(name);
}

fn eqlCompensatorName(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test "session ids use index-slice hashing with full-width equality" {
    var sessions: [3]Session = undefined;
    var map = SessionsMap.init(std.testing.allocator);
    defer map.deinit();

    const a: u128 = 0x0000_0000_0000_0001_0000_0000_0000_0001;
    const b: u128 = 0x0000_0000_0000_0001_0000_0000_0000_0002;
    // Same low 64 bits as `a`, different high bits.
    const c: u128 = 0x0000_0000_0000_0002_0000_0000_0000_0001;

    try map.put(a, &sessions[0]);
    try map.put(b, &sessions[1]);
    try map.put(c, &sessions[2]);

    try std.testing.expectEqual(@as(usize, 3), map.count());
    try std.testing.expectEqual(&sessions[0], map.get(a).?);
    try std.testing.expectEqual(&sessions[1], map.get(b).?);
    try std.testing.expectEqual(&sessions[2], map.get(c).?);
    try std.testing.expect(map.get(0x0000_0000_0000_0002_0000_0000_0000_0002) == null);
}

test "compensator registry hashes by name bytes" {
    var registry = CompensatorMap.init(std.testing.allocator);
    defer registry.deinit();

    try registry.put("marker", .{ .bind = "10.0.0.1", .port = 20301 });
    try registry.put("viper", .{ .bind = "10.0.0.2", .port = 20302 });

    try std.testing.expect(registry.contains("marker"));
    try std.testing.expect(registry.contains("viper"));
    try std.testing.expect(!registry.contains("hermes"));
    try std.testing.expect(!registry.contains("Mark"));
}
