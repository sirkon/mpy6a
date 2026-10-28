//! The replay, stage 6 of designs/CONSENSUS-PLAN.md: the compensation process
//! every session that lost its owner is handed to.
//!
//! Four ways lead here. A session parked as violated after a protocol
//! violation waits out `protocol_violation_replay` and is replayed (2.5). A
//! client session that outlived `session_inactivity_timeout` on a socket that
//! never moved is replayed (2.3). A session of a host the shard declared lost
//! is replayed after its isolation and capture (docs/consensus.md). A session
//! of this host's own log that belongs to an older epoch is replayed when the
//! host restarts (stage 7).
//!
//! The process itself is a plain synchronous method call on the index, with
//! the session id and the time, deliberately un-designed while the consensus
//! is the point: the queue below records what must be replayed and when, and
//! the consumer that would play the accumulated data does not exist yet, the
//! sessions not storing any data at all. Until it does, an entry is a durable
//! statement of the debt; the queue is bounded so a pathological client cannot
//! grow it without limit, and the oldest entry is dropped first, the freshest
//! evidence being the more useful one.

const std = @import("std");
const state = @import("state.zig");

/// Why a session was handed to the replay.
pub const Reason = enum {
    /// A protocol violator's parked session reached its replay deadline (2.5).
    violated,
    /// A client session outlived its inactivity interval (2.3).
    idle,
    /// An explicit `RestartIn` of the log (docs/consensus.md).
    restart_in,
    /// A session recovered from the own log of a previous epoch: a restart
    /// left it orphaned (stage 7).
    restart,
    /// A session taken from an isolated batch by `Compensate`/`Capture`.
    isolated,
    /// A session adopted from a leader that went silent (leadership takeover).
    takeover,
    /// An operator command asking for the replay of one session.
    explicit,

    pub fn string(self: Reason) []const u8 {
        return @tagName(self);
    }
};

/// One debt of the replay.
pub const Entry = struct {
    /// The session to replay: the id it was known under.
    session_id: u128,
    /// The absolute second of the replay start: not before this one. A
    /// `RestartIn` schedules the future, everything else starts at once.
    at: u32,
    /// Why the session is here.
    reason: Reason,
    /// The host whose state the session was taken from.
    host_idx: u8,
    /// The id the session continues under, when a leadership takeover had to
    /// renumber it under the taking host. Zero when the id is unchanged.
    successor: u128,
};

/// The depth of the queue. Bounded, so a broken client or a flapping shard
/// cannot grow it without limit.
pub const capacity = 256;

/// The replay queue of one index: a ring of entries, oldest dropped first.
pub const Queue = struct {
    const Self = @This();

    entries: [capacity]Entry = undefined,
    head: usize = 0,
    count: usize = 0,
    /// How many entries were pushed over the life of this index, for tests and
    /// diagnostics.
    pushed: u64 = 0,
    /// How many entries were dropped because the queue was full.
    dropped: u64 = 0,

    /// Records one debt. Never fails: a full queue drops its oldest entry and
    /// counts the loss.
    pub fn push(self: *Self, entry: Entry) void {
        self.pushed +%= 1;
        if (self.count == capacity) {
            self.head = (self.head + 1) % capacity;
            self.count -= 1;
            self.dropped +%= 1;
        }
        const at = (self.head + self.count) % capacity;
        self.entries[at] = entry;
        self.count += 1;
    }

    /// Takes the oldest entry.
    pub fn pop(self: *Self) ?Entry {
        if (self.count == 0) return null;
        const entry = self.entries[self.head];
        self.head = (self.head + 1) % capacity;
        self.count -= 1;
        return entry;
    }

    /// The oldest entry, without taking it.
    pub fn peek(self: *const Self) ?Entry {
        if (self.count == 0) return null;
        return self.entries[self.head];
    }

    /// How many debts are recorded.
    pub fn depth(self: *const Self) usize {
        return self.count;
    }

    /// Takes every entry, oldest first, into `out`. Returns how many landed;
    /// the rest stay queued.
    pub fn drain(self: *Self, out: []Entry) []Entry {
        var taken: usize = 0;
        while (taken < out.len) : (taken += 1) {
            out[taken] = self.pop() orelse break;
        }
        return out[0..taken];
    }
};

/// The state a captured session continues from: the id it is replayed under.
/// A takeover renumbers the session into the taking host's own state, so its
/// new id is the next value of that state.
pub fn successorOf(taking: u128) u128 {
    return state.IndexState
        .unpack(taking)
        .bumped()
        .pack();
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "entries keep the order they were pushed in" {
    var queue = Queue{};
    try expectEqual(@as(?Entry, null), queue.pop());

    queue.push(.{ .session_id = 1, .at = 10, .reason = .idle, .host_idx = 0, .successor = 0 });
    queue.push(.{ .session_id = 2, .at = 11, .reason = .violated, .host_idx = 1, .successor = 0 });
    queue.push(.{ .session_id = 3, .at = 12, .reason = .restart_in, .host_idx = 0, .successor = 0 });
    try expectEqual(@as(usize, 3), queue.depth());
    try expectEqual(@as(u128, 1), queue.peek().?.session_id);

    try expectEqual(@as(u128, 1), queue.pop().?.session_id);
    try expectEqual(@as(u128, 2), queue.pop().?.session_id);
    try expectEqual(@as(u128, 3), queue.pop().?.session_id);
    try expectEqual(@as(usize, 0), queue.depth());
}

test "a full queue drops its oldest entry and counts the loss" {
    var queue = Queue{};
    for (0..capacity) |i| {
        queue.push(.{ .session_id = i, .at = 0, .reason = .isolated, .host_idx = 0, .successor = 0 });
    }
    try expectEqual(capacity, queue.depth());
    try expectEqual(@as(u64, 0), queue.dropped);

    queue.push(.{ .session_id = capacity, .at = 0, .reason = .isolated, .host_idx = 0, .successor = 0 });
    try expectEqual(capacity, queue.depth());
    try expectEqual(@as(u64, 1), queue.dropped);
    // The oldest went, the newest stayed.
    try expectEqual(@as(u128, 1), queue.peek().?.session_id);
    var out: [capacity]Entry = undefined;
    const drained = queue.drain(&out);
    try expectEqual(capacity, drained.len);
    try expectEqual(@as(u128, capacity), drained[drained.len - 1].session_id);
}

test "a drain takes the entries oldest first and leaves the rest" {
    var queue = Queue{};
    queue.push(.{ .session_id = 1, .at = 1, .reason = .takeover, .host_idx = 1, .successor = 0 });
    queue.push(.{ .session_id = 2, .at = 2, .reason = .idle, .host_idx = 2, .successor = 0 });
    queue.push(.{ .session_id = 3, .at = 3, .reason = .takeover, .host_idx = 1, .successor = 0 });

    var out: [2]Entry = undefined;
    const drained = queue.drain(&out);
    try expectEqual(@as(usize, 2), drained.len);
    try expectEqual(@as(u128, 1), drained[0].session_id);
    try expectEqual(@as(u128, 2), drained[1].session_id);
    try expectEqual(@as(usize, 1), queue.depth());
    try expectEqual(@as(u128, 3), queue.peek().?.session_id);
}

test "a takeover renumbers a session into the taking host's state" {
    const taking = state.IndexState{ .host_id = 1, .index_id = 4, .epoch_id = 2, .index = 9 };
    const successor = successorOf(taking.pack());
    const unpacked = state.IndexState.unpack(successor);
    try expectEqual(@as(u8, 1), unpacked.host_id);
    try expectEqual(@as(u16, 4), unpacked.index_id);
    try expectEqual(@as(state.EpochId, 2), unpacked.epoch_id);
    try expectEqual(@as(u64, 10), unpacked.index);
}
