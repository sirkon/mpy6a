//! The replicated state of one peer host, stage 6 of designs/CONSENSUS-PLAN.md
//! and the `MirrorState` of docs/consensus.md.
//!
//! Every host keeps, per peer, the sessions that peer leads on this host's
//! copy: the `active_map` of Proto, its log pointer `current_idx`, the
//! `expected_epoch_id` the epoch barrier compares, the `isolated_fifo` of the
//! sessions an isolation pushed out of the live set, and the `deferred_hooks`
//! of the isolations whose boundary the replica has not reached yet.
//!
//! The replicated log itself lives next door, one framed `wal.ReplicaLog` per
//! host (stage 7): the pointer below is the newest leader state this replica
//! holds, which is the state the last record of that log carries, and the log
//! service answers a lagging peer from it. An isolation still hands over the
//! sessions at or below the boundary it names rather than a byte range: the
//! records are replayed through the same pointer, so the FIFO order of the
//! batches is the order of the log.

const std = @import("std");
const verztable = @import("verztable");
const state = @import("state.zig");

/// One session on this host's copy of a leader's log.
pub const Replica = struct {
    /// The packed leader state the replica was last advanced to.
    leader_state: u128,
    /// The absolute second of the last operation that touched the replica.
    seen: u32,
};

/// The sessions isolated together under one boundary of a leader's log.
pub const Batch = struct {
    /// The packed leader state the isolation was decided at.
    boundary: u128,
    /// The sessions of the batch. The allocation is a snapshot of the replica
    /// set and may be wider than what the batch needs.
    sessions: []u128,
    /// How many entries of `sessions` belong to the batch.
    len: usize,
    /// How many of them a capture already took.
    processed: u32 = 0,

    /// How many sessions of the batch are still to be captured.
    pub fn remaining(self: Batch) usize {
        return self.len - self.processed;
    }
};

/// How an isolation landed.
pub const Isolation = enum {
    /// The replica reached the boundary: the sessions moved to the FIFO.
    applied,
    /// The replica is still behind the boundary: the hook waits for it.
    deferred,
    /// Nothing was replicated at or below the boundary.
    empty,
    /// This boundary was already isolated.
    duplicate,
};

/// The isolation window is full: the shard is losing hosts faster than this
/// index can capture them.
pub const IsolateError = error{ DeferredFull, IsolatedFull, OutOfMemory };

/// A capture that cannot proceed.
pub const CaptureError = error{
    /// No batch of the host reached the FIFO yet: the isolation is deferred.
    NotIsolatedYet,
    /// The carried offset does not match the head batch: the initiator is
    /// looking at a context this index already moved past.
    Outdated,
};

/// The FIFO depth of one peer: how many isolation boundaries may wait for a
/// capture.
pub const max_batches = 8;

/// How many deferred isolation hooks one peer may carry.
pub const max_deferred = 16;

/// The session table of one peer's replica set. Both halves of a session id
/// carry identity, so verztable's integer hash is folded by hand.
pub const ActiveMap = verztable.HashMapWithFns(u128, Replica, state.hashSession, state.eqlSession);

/// The state of one peer host.
pub const MirrorState = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    /// The epoch this host expects the peer to speak in. Only an isolation
    /// raises it (docs/consensus.md).
    expected_epoch: state.EpochId = 0,
    /// The newest leader state of the peer this replica holds.
    current_idx: u128 = 0,
    /// The peer's sessions this host replicates, keyed by the session id.
    active: ActiveMap,
    /// The isolated batches, oldest first (Proto's `isolated_fifo`).
    isolated: std.ArrayListUnmanaged(Batch) = .empty,
    /// The boundaries whose isolation waits for the replica to reach them.
    deferred: std.ArrayListUnmanaged(u128) = .empty,
    /// The absolute second of the last traffic seen on this peer's connection.
    last_traffic: u32 = 0,
    /// Whether the peer was isolated at least once.
    fenced: bool = false,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator, .active = ActiveMap.init(allocator) };
    }

    pub fn deinit(self: *Self) void {
        for (self.isolated.items) |batch| self.allocator.free(batch.sessions);
        self.isolated.deinit(self.allocator);
        self.deferred.deinit(self.allocator);
        self.active.deinit();
    }

    /// Records a replicated operation of `session_id` and advances the log
    /// pointer, firing every deferred isolation the replica has reached.
    pub fn advance(self: *Self, session_id: u128, leader_state: u128, second: u32) IsolateError!void {
        try self.active.put(session_id, .{ .leader_state = leader_state, .seen = second });
        if (state.IndexState.unpack(leader_state).index >= state.IndexState.unpack(self.current_idx).index) {
            self.current_idx = leader_state;
        }
        try self.fireDeferred();
    }

    /// Raises the expected epoch of the peer (docs/consensus.md, `Isolate`):
    /// the state it accumulates from now on belongs to a spent epoch.
    pub fn fence(self: *Self, boundary: u128) state.EpochId {
        const raised = state.IndexState.unpack(boundary).epoch_id +% 1;
        if (raised > self.expected_epoch) self.expected_epoch = raised;
        self.fenced = true;
        return self.expected_epoch;
    }

    /// Isolates the peer's accumulated state up to `boundary`: the sessions at
    /// or below it move to the FIFO at once when the replica already reached
    /// the boundary, and the hook waits for it otherwise.
    pub fn isolate(self: *Self, boundary: u128) IsolateError!Isolation {
        for (self.isolated.items) |batch| {
            if (batch.boundary == boundary) return .duplicate;
        }
        for (self.deferred.items) |pending| {
            if (pending == boundary) return .duplicate;
        }

        if (self.reached(boundary)) return self.pushBatch(boundary);

        if (self.deferred.items.len >= max_deferred) return error.DeferredFull;
        try self.deferred.append(self.allocator, boundary);
        return .deferred;
    }

    /// Fires the deferred hooks whose boundary the replica has reached, oldest
    /// first: the replica's log advances strictly in order, so the batches land
    /// in the FIFO in the order the isolations were decided.
    pub fn fireDeferred(self: *Self) IsolateError!void {
        while (self.deferred.items.len != 0) {
            const next = self.deferred.items[0];
            if (!self.reached(next)) return;
            _ = try self.pushBatch(next);
            _ = self.deferred.orderedRemove(0);
        }
    }

    /// Takes up to `head` sessions off the head batch, `offset` being how many
    /// of that batch a capture already took (docs/consensus.md, `Capture`).
    pub fn captureHead(self: *Self, offset: u32, head: u16, out: []u128) CaptureError![]u128 {
        if (self.isolated.items.len == 0) return error.NotIsolatedYet;
        const batch = &self.isolated.items[0];
        if (batch.processed != offset) return error.Outdated;

        const want = @min(@as(usize, head), batch.remaining());
        const take = @min(want, out.len);
        if (take == 0) return out[0..0];

        @memcpy(out[0..take], batch.sessions[batch.processed..][0..take]);
        batch.processed += @intCast(take);
        if (batch.processed == batch.len) {
            const done = self.isolated.orderedRemove(0);
            self.allocator.free(done.sessions);
        }
        return out[0..take];
    }

    /// The head batch, without taking anything.
    pub fn peekBatch(self: *const Self) ?Batch {
        if (self.isolated.items.len == 0) return null;
        return self.isolated.items[0];
    }

    /// Copies every replicated session into `out` and empties the live set: the
    /// sessions a leadership takeover adopts.
    pub fn takeReplicas(self: *Self, out: []u128) []u128 {
        var taken: usize = 0;
        var it = self.active.keyIterator();
        while (it.next()) |key| {
            if (taken == out.len) break;
            out[taken] = key;
            taken += 1;
        }
        self.active.clear();
        return out[0..taken];
    }

    /// Records that traffic arrived on the peer's connection.
    pub fn sawTraffic(self: *Self, second: u32) void {
        self.last_traffic = second;
    }

    /// Whether the peer's connection was silent for at least `seconds`.
    pub fn silentFor(self: *const Self, second: u32, seconds: u32) bool {
        return second -% self.last_traffic >= seconds;
    }

    /// Whether the replica holds at least `boundary`.
    fn reached(self: *const Self, boundary: u128) bool {
        return state.IndexState.unpack(self.current_idx).index >= state.IndexState.unpack(boundary).index;
    }

    /// Moves the sessions at or below `boundary` out of the live set into the
    /// FIFO, oldest batch last.
    fn pushBatch(self: *Self, boundary: u128) IsolateError!Isolation {
        if (self.active.count() == 0) return .empty;
        if (self.isolated.items.len >= max_batches) return error.IsolatedFull;

        const at = state.IndexState.unpack(boundary).index;
        const sessions = try self.allocator.alloc(u128, self.active.count());
        errdefer self.allocator.free(sessions);

        var len: usize = 0;
        var it = self.active.iterator();
        while (it.next()) |bucket| {
            if (state.IndexState.unpack(bucket.val.leader_state).index > at) continue;
            sessions[len] = bucket.key;
            len += 1;
        }
        if (len == 0) {
            self.allocator.free(sessions);
            return .empty;
        }

        for (sessions[0..len]) |session_id| _ = self.active.remove(session_id);
        try self.isolated.append(self.allocator, .{
            .boundary = boundary,
            .sessions = sessions,
            .len = len,
        });
        return .applied;
    }
};

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

/// A packed leader state of host 1 with the given `index` slice.
fn leader(index: u64) u128 {
    return (state.IndexState{ .host_id = 1, .index_id = 3, .epoch_id = 2, .index = index }).pack();
}

test "an isolation waits for the replica it names the boundary of" {
    var mirror = MirrorState.init(std.testing.allocator);
    defer mirror.deinit();

    try mirror.advance(leader(1), leader(1), 10);
    try expectEqual(@as(u64, 1), state.IndexState.unpack(mirror.current_idx).index);

    // The boundary is ahead of the replica: the hook waits for the log.
    try expectEqual(Isolation.deferred, try mirror.isolate(leader(3)));
    try expectEqual(@as(usize, 1), mirror.deferred.items.len);
    try expectEqual(@as(usize, 0), mirror.isolated.items.len);

    // The same boundary twice is not isolated twice.
    try expectEqual(Isolation.duplicate, try mirror.isolate(leader(3)));

    // The replica catches up: the hook fires and the batch opens.
    try mirror.advance(state.IndexState.unpack(leader(3)).pack(), leader(3), 11);
    try expectEqual(@as(usize, 0), mirror.deferred.items.len);
    const batch = mirror.peekBatch() orelse return error.MissingBatch;
    try expectEqual(leader(3), batch.boundary);
    try expectEqual(@as(usize, 2), batch.len);
    try expectEqual(@as(usize, 0), mirror.active.count());
}

test "a reached boundary isolates at once and keeps the FIFO order" {
    var mirror = MirrorState.init(std.testing.allocator);
    defer mirror.deinit();

    try mirror.advance(leader(1), leader(1), 10);
    try mirror.advance(leader(2), leader(2), 10);
    try expectEqual(Isolation.applied, try mirror.isolate(leader(1)));
    try expectEqual(Isolation.applied, try mirror.isolate(leader(2)));

    // Two boundaries, two batches, oldest first, each carrying the session at
    // or below its own boundary.
    try expectEqual(@as(usize, 2), mirror.isolated.items.len);
    try expectEqual(leader(1), mirror.isolated.items[0].boundary);
    try expectEqual(@as(usize, 1), mirror.isolated.items[0].len);
    try expectEqual(leader(2), mirror.isolated.items[1].boundary);
    try expectEqual(@as(usize, 1), mirror.isolated.items[1].len);

    // The upper boundary took every session still live, so nothing is left.
    try expectEqual(@as(usize, 0), mirror.active.count());
    // A boundary already isolated is not isolated twice, and one ahead of the
    // replica waits for the log to reach it.
    try expectEqual(Isolation.duplicate, try mirror.isolate(leader(2)));
    try expectEqual(Isolation.deferred, try mirror.isolate(leader(4)));
}

test "a capture walks the head batch by its offset" {
    var mirror = MirrorState.init(std.testing.allocator);
    defer mirror.deinit();

    const ids = [_]u128{ leader(1), leader(2), leader(3) };
    for (ids, 1..) |id, index| try mirror.advance(id, leader(@intCast(index)), 5);
    _ = try mirror.isolate(leader(3));
    try expectEqual(@as(usize, 3), mirror.peekBatch().?.len);

    // No isolation yet is a distinct refusal from an outdated offset.
    var out: [4]u128 = undefined;
    try std.testing.expectError(error.Outdated, mirror.captureHead(1, 2, &out));

    const first = try mirror.captureHead(0, 2, &out);
    try expectEqual(@as(usize, 2), first.len);
    try expectEqual(@as(usize, 1), mirror.peekBatch().?.remaining());

    // The offset now names what the first capture took.
    try std.testing.expectError(error.Outdated, mirror.captureHead(0, 2, &out));
    const rest = try mirror.captureHead(2, 2, &out);
    try expectEqual(@as(usize, 1), rest.len);
    // The batch is gone once every session of it was captured.
    try expect(mirror.peekBatch() == null);
    try std.testing.expectError(error.NotIsolatedYet, mirror.captureHead(0, 1, &out));
}

test "a capture of an empty FIFO says the isolation is not there yet" {
    var mirror = MirrorState.init(std.testing.allocator);
    defer mirror.deinit();

    var out: [1]u128 = undefined;
    try std.testing.expectError(error.NotIsolatedYet, mirror.captureHead(0, 1, &out));
}

test "an isolation raises the expected epoch once" {
    var mirror = MirrorState.init(std.testing.allocator);
    defer mirror.deinit();

    const boundary = (state.IndexState{ .host_id = 1, .index_id = 3, .epoch_id = 6, .index = 4 }).pack();
    try expectEqual(@as(state.EpochId, 7), mirror.fence(boundary));
    try expect(mirror.fenced);

    // An older state of the same host never lowers the fence.
    const older = (state.IndexState{ .host_id = 1, .index_id = 3, .epoch_id = 4, .index = 1 }).pack();
    try expectEqual(@as(state.EpochId, 7), mirror.fence(older));
}

test "a takeover takes every live replica and leaves none behind" {
    var mirror = MirrorState.init(std.testing.allocator);
    defer mirror.deinit();

    try mirror.advance(leader(1), leader(1), 5);
    try mirror.advance(leader(2), leader(2), 5);
    try expect(!mirror.silentFor(5, 10));
    try expect(mirror.silentFor(16, 10));

    var out: [4]u128 = undefined;
    const taken = mirror.takeReplicas(&out);
    try expectEqual(@as(usize, 2), taken.len);
    try expectEqual(@as(usize, 0), mirror.active.count());

    // An empty replica set takes nothing, so a silent peer with no session
    // never starts a replay.
    try expectEqual(@as(usize, 0), mirror.takeReplicas(&out).len);
}
