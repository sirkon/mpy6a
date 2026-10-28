//! Per-index session state: what a mutation of a session carries, what the
//! consensus round of a session answers, and the index state a session id is
//! cut from.
//!
//! The types here are the vocabulary of designs/CONSENSUS-PLAN.md 2.5. Stage 1
//! wires the session table of an index onto them: a session knows the client
//! endpoint it answers to, the operation in flight and the phase it waits in.

const std = @import("std");
const posix = std.posix;
const verztable = @import("verztable");

pub const Buffer = struct {
    backing: []u8,
    len: usize,
};

/// The mutation vocabulary a session carries.
pub const Op = enum {
    create,
    append,
    overwrite,
    repeat,
    close,

    /// The operation name, for diagnostics.
    pub fn string(self: Op) []const u8 {
        return @tagName(self);
    }
};

/// The answer a mirror or the own flush produces for an operation.
pub const ConsensusResponse = enum {
    ack,
    nack,
    abstain,
};

/// The epoch slice of the index state: the only part of the state the epoch
/// barrier of docs/consensus.md compares.
pub const EpochId = u40;

/// Compares an incoming epoch with the one this host expects from its sender
/// (docs/consensus.md, "the monotonicity of the epoch barrier"): a lesser
/// epoch is stale and is refused, an equal one may be applied, and a greater
/// one leaves this host abstaining because another host already moved on.
pub fn compareEpoch(incoming: u128, expected: EpochId) std.math.Order {
    const value: u128 = expected;
    return if (incoming < value) .lt else if (incoming > value) .gt else .eq;
}

/// The index state `(host_id: u8, index_id: u16, epoch_id: u40, index: u64)`
/// of docs/shard-arch-hld.md, packed into the `u128` an index keeps and a
/// session id is cut from.
///
/// The layout, from the most significant bit down: `host_id` in 120..128,
/// `index_id` in 104..120, `epoch_id` in 64..104, `index` in 0..64. The
/// leading `index_id` lets a front extract the index service number straight
/// from a session id, with no side table.
pub const IndexState = struct {
    host_id: u8,
    index_id: u16,
    epoch_id: u40,
    index: u64,

    /// Packs the four slices into the wire value.
    pub fn pack(self: IndexState) u128 {
        return (@as(u128, self.host_id) << 120) |
            (@as(u128, self.index_id) << 104) |
            (@as(u128, self.epoch_id) << 64) |
            @as(u128, self.index);
    }

    /// Cuts the four slices back out of a packed state or session id.
    pub fn unpack(value: u128) IndexState {
        return .{
            .host_id = @truncate(value >> 120),
            .index_id = @truncate(value >> 104),
            .epoch_id = @truncate(value >> 64),
            .index = @truncate(value),
        };
    }

    /// The state that follows this one: the post-bump value a mutation of any
    /// session of this index takes once it is acknowledged (2.5).
    pub fn bumped(self: IndexState) IndexState {
        var next = self;
        next.index +%= 1;
        return next;
    }

    /// The index service number carried by a packed state or session id.
    pub fn indexId(value: u128) u16 {
        return @truncate(value >> 104);
    }
};

/// The hash of a session id. The key is a `u128` and verztable's automatic
/// integer hash cuts it to 64 bits (it panics rather than truncate), so the id
/// is folded by hand: both halves carry identity, the `index_id` slice in the
/// high one above all.
pub fn hashSession(id: u128) u64 {
    return verztable.hashInteger(@as(u64, @truncate(id))) ^
        verztable.hashInteger(@as(u64, @truncate(id >> 64)));
}

/// Session ids compare by their whole value, never by a slice of it.
pub fn eqlSession(a: u128, b: u128) bool {
    return a == b;
}

pub const Session = struct {
    const Self = @This();

    /// The phases of 2.5: one operation in flight at a time, the reply wait
    /// being the tail that grows out of the direct client write.
    pub const State = enum(u32) {
        /// Ready for the next mutation.
        ExpectOp,
        /// Waiting for the consensus round of the operation in flight.
        ExpectConsensus,
        /// Waiting for the operation to reach the log.
        ExpectAcceptedFlush,
        /// Waiting for the reply to leave for the client.
        ExpectReply,
        /// Parked after a protocol violation, waiting for its replay deadline
        /// (2.5). No mutation is accepted until the entry is handed over.
        Violated,
    };

    pub const ConsensusProgress = struct {
        accepted: u16 = 0,
        rejected: u16 = 0,
    };

    /// The printable details of a session, for the fault log of 2.5. Every
    /// field is a plain word: identifiers travel as two halves because the
    /// logger encodes at most 64 bits per field.
    pub const Diag = struct {
        state: []const u8,
        op: []const u8,
        accepted: u16,
        rejected: u16,
        client_fd: posix.fd_t,
        client_tag: usize,
        id_hi: u64,
        id_lo: u64,
        index_idx_hi: u64,
        index_idx_lo: u64,
    };

    id: u128,
    index_idx: u128,
    upgrade_idx: u128, // Identifier that will become an index_idx once the last op will be successfully passed.
    wheel_idx: ?u64, // Handle of the session's deadline in the timing wheel, null when unarmed. Refreshed on activity (2.3).
    state: State,
    consensus_progress: ConsensusProgress,

    /// The operation in flight; the session stores the code of its current
    /// operation, as docs/shard-arch-hld.md requires.
    op: Op,
    /// The client endpoint of the operation in flight: the descriptor value and
    /// the tag the front minted for it (2.3). The session owns no descriptor
    /// lifecycle; the front does.
    client_fd: posix.fd_t,
    client_tag: usize,

    data: Buffer,

    /// A session opened by a create: its id is the index state the create
    /// produced, `begin` the state the operation began at.
    pub fn created(id: u128, begin: u128, client_fd: posix.fd_t, client_tag: usize) Self {
        return .{
            .id = id,
            .index_idx = begin,
            .upgrade_idx = id,
            .wheel_idx = null,
            .state = .ExpectOp,
            .consensus_progress = .{},
            .op = .create,
            .client_fd = client_fd,
            .client_tag = client_tag,
            .data = .{ .backing = &.{}, .len = 0 },
        };
    }

    /// 2.5, step 1: applies the mutation and starts waiting for its consensus.
    /// `index_state` is the state at the moment the operation began; the
    /// post-bump value of it becomes the session's future `index_idx`.
    pub fn startOp(self: *Self, op: Op, index_state: u128, client_fd: posix.fd_t, client_tag: usize) void {
        self.op = op;
        self.index_idx = index_state;
        self.upgrade_idx = IndexState.unpack(index_state).bumped().pack();
        self.state = .ExpectConsensus;
        self.client_fd = client_fd;
        self.client_tag = client_tag;
        self.prepareForNewConsensus();
    }

    pub fn prepareForNewConsensus(self: *Self) void {
        self.consensus_progress = .{};
    }

    /// Records one answer of the consensus round. Returns the progress after it.
    pub fn recordResponse(self: *Self, resp: ConsensusResponse) ConsensusProgress {
        switch (resp) {
            .ack => self.consensus_progress.accepted +|= 1,
            .nack => self.consensus_progress.rejected +|= 1,
            .abstain => {},
        }
        return self.consensus_progress;
    }

    pub fn diag(self: *const Self) Diag {
        return .{
            .state = @tagName(self.state),
            .op = self.op.string(),
            .accepted = self.consensus_progress.accepted,
            .rejected = self.consensus_progress.rejected,
            .client_fd = self.client_fd,
            .client_tag = self.client_tag,
            .id_hi = @truncate(self.id >> 64),
            .id_lo = @truncate(self.id),
            .index_idx_hi = @truncate(self.index_idx >> 64),
            .index_idx_lo = @truncate(self.index_idx),
        };
    }
};

const WALOperation = struct {
    op: union {
        create: struct {
            replayer: u64,
            data: Buffer,
        },
        append: struct {
            data: Buffer,
        },
        ovewrite: struct {
            data: Buffer,
        },
        close: struct {},
        repeat: struct {
            delay: u32,
        },
    },
};

test "index state slices pack and unpack" {
    const s = IndexState{
        .host_id = 2,
        .index_id = 5,
        .epoch_id = 0x0000_0001_00,
        .index = 0xdead_beef_0000_0001,
    };
    const value = s.pack();
    try std.testing.expectEqual(s, IndexState.unpack(value));

    // The `index_id` slice is readable straight from the packed value.
    try std.testing.expectEqual(@as(u16, 5), IndexState.indexId(value));
    try std.testing.expectEqual(@as(u64, 0xdead_beef_0000_0001), IndexState.unpack(value).index);

    // The high bits belong to the host, the low ones to the index.
    try std.testing.expectEqual(@as(u8, 2), @as(u8, @truncate(value >> 120)));
    try std.testing.expectEqual(@as(u64, 0xdead_beef_0000_0001), @as(u64, @truncate(value)));
}

test "bumped state differs in the index slice only" {
    const s = IndexState{ .host_id = 1, .index_id = 3, .epoch_id = 9, .index = 41 };
    const next = s.bumped();
    try std.testing.expectEqual(@as(u64, 42), next.index);
    try std.testing.expectEqual(s.host_id, next.host_id);
    try std.testing.expectEqual(s.index_id, next.index_id);
    try std.testing.expectEqual(s.epoch_id, next.epoch_id);
    try std.testing.expect(next.pack() != s.pack());
}

test "a created session is ready for the next op" {
    const begin = IndexState{ .host_id = 0, .index_id = 1, .epoch_id = 0, .index = 7 };
    const id = begin.bumped().pack();
    const session = Session.created(id, begin.pack(), 12, 3);

    try std.testing.expectEqual(id, session.id);
    try std.testing.expectEqual(begin.pack(), session.index_idx);
    try std.testing.expectEqual(id, session.upgrade_idx);
    try std.testing.expectEqual(Session.State.ExpectOp, session.state);
    try std.testing.expectEqual(Op.create, session.op);
    try std.testing.expectEqual(@as(posix.fd_t, 12), session.client_fd);
    try std.testing.expectEqual(@as(usize, 3), session.client_tag);
}

test "a session op waits for its consensus" {
    var session = Session.created(0x100, 0x0, 4, 1);
    session.startOp(.append, 0x100, 5, 2);

    try std.testing.expectEqual(Session.State.ExpectConsensus, session.state);
    try std.testing.expectEqual(Op.append, session.op);
    try std.testing.expectEqual(@as(u128, 0x100), session.index_idx);
    try std.testing.expectEqual(@as(u128, 0x101), session.upgrade_idx);
    try std.testing.expectEqual(@as(usize, 2), session.client_tag);
    try std.testing.expectEqual(@as(u16, 0), session.consensus_progress.accepted);

    const progress = session.recordResponse(.ack);
    try std.testing.expectEqual(@as(u16, 1), progress.accepted);
    _ = session.recordResponse(.nack);
    try std.testing.expectEqual(@as(u16, 1), session.consensus_progress.rejected);
    _ = session.recordResponse(.abstain);
    try std.testing.expectEqual(@as(u16, 1), session.consensus_progress.accepted);

    session.prepareForNewConsensus();
    try std.testing.expectEqual(@as(u16, 0), session.consensus_progress.accepted);
    try std.testing.expectEqual(@as(u16, 0), session.consensus_progress.rejected);
}

test "the epoch barrier orders the incoming epoch against the expected one" {
    try std.testing.expectEqual(std.math.Order.lt, compareEpoch(2, 3));
    try std.testing.expectEqual(std.math.Order.eq, compareEpoch(3, 3));
    try std.testing.expectEqual(std.math.Order.gt, compareEpoch(4, 3));
    // An epoch wider than the slice is a host this one already passed.
    try std.testing.expectEqual(std.math.Order.gt, compareEpoch(std.math.maxInt(u128), 3));
}

test "session diagnostics carry plain words" {
    var session = Session.created(0x1_0000_0000_0000_0002, 0x1_0000_0000_0000_0001, 9, 6);
    session.startOp(.overwrite, 0x1_0000_0000_0000_0002, 9, 6);
    _ = session.recordResponse(.ack);

    const diag = session.diag();
    try std.testing.expectEqualStrings("ExpectConsensus", diag.state);
    try std.testing.expectEqualStrings("overwrite", diag.op);
    try std.testing.expectEqual(@as(u64, 1), diag.id_hi);
    try std.testing.expectEqual(@as(u64, 2), diag.id_lo);
    try std.testing.expectEqual(@as(u64, 1), diag.index_idx_hi);
    try std.testing.expectEqual(@as(u64, 2), diag.index_idx_lo);
    try std.testing.expectEqual(@as(u16, 1), diag.accepted);
}
