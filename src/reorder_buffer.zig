//! Fixed-item reorder buffer for the cluster link receive path.
//!
//! This is `zigring.ReorderBuffer` with the fixed-item `push` split into a
//! reserve/commit pair, because the original `push` cannot take a frame in
//! pieces: the receive path reserves the slot when the frame header arrives,
//! writes the body into it as the short completions land, and commits it only
//! when the last byte is in place. The absolute `wave`, the two window checks
//! and the caller-owned delivery cursor are the upstream ones; `advanceWave`
//! corrects the upstream off-by-one that left the wave on the last linked item
//! of an out-of-order run, which let a repeated frame past the outdated check.
//! `push` survives as the reserve + memcpy + commit shim so the upstream tests
//! port over unchanged.

const std = @import("std");

pub const ReorderBuffer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    /// Committed item storage: `mod` slots of `item_size` bytes each.
    buf: []u8,
    /// Pending-list links, relative slot numbers or -1.
    nexts: []i32,
    prevs: []i32,
    /// Committed length per slot. A frame never exceeds `item_size`, and the
    /// transport caps it at 4096, so `u16` is enough.
    lens: []u16,

    /// The reorder window N and `2 * N`, the slot count.
    size: u64,
    mod: u64,
    item_size: usize,

    /// The first absolute index not yet committed by a consecutive run.
    wave: u64,
    /// Head and tail of the pending list, relative slot numbers or -1.
    first: i32,
    last: i32,
    /// The absolute index of the one open reservation, if any.
    reserved: ?u64,

    /// Creates in place a reorder buffer that holds up to `size` in-flight items
    /// of `item_size` bytes each.
    ///
    /// `size` must be a power of two and no more than 0xFFFF, else
    /// `error.ReorderBufferSizeMustBeAPowOf2` or
    /// `error.ReorderBufferNoMoreThan32KibItems` is returned. The backing
    /// storage is `2 * size` slots, one ring length of headroom.
    pub fn init(self: *Self, allocator: std.mem.Allocator, size: usize, item_size: usize) !void {
        if (@popCount(size) != 1) {
            return error.ReorderBufferSizeMustBeAPowOf2;
        }
        if (size > 0xFFFF) {
            return error.ReorderBufferNoMoreThan32KibItems;
        }

        const mod = 2 * size;
        const buf = try allocator.alloc(u8, mod * item_size);
        errdefer allocator.free(buf);

        const nexts = try allocator.alloc(i32, mod);
        errdefer allocator.free(nexts);

        const prevs = try allocator.alloc(i32, mod);
        errdefer allocator.free(prevs);

        const lens = try allocator.alloc(u16, mod);
        errdefer allocator.free(lens);

        @memset(nexts, -1);
        @memset(prevs, -1);
        @memset(lens, 0);

        self.* = .{
            .allocator = allocator,
            .buf = buf,
            .nexts = nexts,
            .prevs = prevs,
            .lens = lens,
            .size = size,
            .mod = mod,
            .item_size = item_size,
            .wave = 0,
            .first = -1,
            .last = -1,
            .reserved = null,
        };
    }

    /// Releases the storage allocated by `init`, using the same allocator.
    ///
    /// Every slice previously handed out by `reserve`, `peekHeadCond` or
    /// `popHeadCond` dangles afterwards.
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.buf);
        self.allocator.free(self.nexts);
        self.allocator.free(self.prevs);
        self.allocator.free(self.lens);
    }

    /// Reserves the slot for the absolute index `idx` and returns its full
    /// `item_size`-byte view, without linking it or advancing the wave.
    ///
    /// The reservation pins the slot: no other item can take it until
    /// `commit`, `abandon` or `reset`. Only one reservation may be open at a
    /// time. An index below `wave` is rejected with `error.OutdatedFrame`, one
    /// `size` or more ahead with `error.FramesAreTooFarAway`.
    pub fn reserve(self: *Self, idx: u64) ![]u8 {
        if (idx < self.wave) {
            @branchHint(.cold);
            return error.OutdatedFrame;
        }

        if (idx - self.wave >= self.size) {
            @branchHint(.cold);
            return error.FramesAreTooFarAway;
        }

        std.debug.assert(self.reserved == null);
        self.reserved = idx;

        const offset = @as(usize, @intCast(idx & (self.mod - 1))) * self.item_size;
        return self.buf[offset .. offset + self.item_size];
    }

    /// Links the slot reserved at `idx`, records its committed length and
    /// advances the wave across every consecutive committed item.
    ///
    /// `len` must not exceed `item_size`.
    pub fn commit(self: *Self, idx: u64, len: usize) void {
        std.debug.assert(self.reserved == idx);
        std.debug.assert(len <= self.item_size);
        std.debug.assert(len <= std.math.maxInt(u16));

        self.reserved = null;

        const relIdx: i32 = @intCast(idx & (self.mod - 1));
        self.lens[@intCast(relIdx)] = @intCast(len);

        // First element in the list.
        if (self.last < 0) {
            @branchHint(.cold);
            self.first = relIdx;
            self.last = relIdx;
            self.nexts[@intCast(relIdx)] = -1;
            self.prevs[@intCast(relIdx)] = -1;
            self.advanceWave(idx);
            return;
        }

        // Fast path: insert after the tail.
        const mod: i32 = @truncate(@as(i64, @bitCast(self.mod)));
        const distFromLast = (relIdx - self.last) & (mod - 1);
        if (distFromLast < @as(i32, @intCast(self.size))) {
            @branchHint(.likely);

            self.nexts[@intCast(self.last)] = relIdx;
            self.prevs[@intCast(relIdx)] = self.last;
            self.nexts[@intCast(relIdx)] = -1;
            self.last = relIdx;
            self.advanceWave(idx);
            return;
        }

        // Slow path: find the insertion point by moving backward from the tail.
        var cur: i32 = self.last;
        while (cur >= 0) {
            const distFromCur = (relIdx - cur) & (mod - 1);
            if (distFromCur >= @as(i32, @intCast(self.size))) {
                @branchHint(.likely);

                cur = self.prevs[@intCast(cur)];
                continue;
            }

            break;
        }

        if (cur < 0) {
            @branchHint(.cold);
            self.nexts[@intCast(relIdx)] = self.first;
            self.prevs[@intCast(relIdx)] = -1;
            self.prevs[@intCast(self.first)] = relIdx;
            self.first = relIdx;
            self.advanceWave(idx);
            return;
        }

        const nextNode = self.nexts[@intCast(cur)];
        self.nexts[@intCast(cur)] = relIdx;
        self.prevs[@intCast(relIdx)] = cur;
        self.nexts[@intCast(relIdx)] = nextNode;
        self.prevs[@intCast(nextNode)] = relIdx;
        self.advanceWave(idx);
    }

    /// Frees a reservation whose frame never completed, without linking it.
    ///
    /// A no-op when the open reservation is for a different index.
    pub fn abandon(self: *Self, idx: u64) void {
        if (self.reserved != idx) return;
        self.reserved = null;
    }

    /// Returns the buffer to its initial state: absolute wave zero, an empty
    /// list, no lengths and no reservation.
    pub fn reset(self: *Self) void {
        @memset(self.nexts, -1);
        @memset(self.prevs, -1);
        @memset(self.lens, 0);
        self.wave = 0;
        self.first = -1;
        self.last = -1;
        self.reserved = null;
    }

    /// Inserts `data` as the item at absolute index `idx`.
    ///
    /// The reserve + memcpy + commit shim; the zigring tests drive the copy
    /// through this entry point.
    pub fn push(self: *Self, idx: u64, data: []const u8) !void {
        std.debug.assert(data.len <= self.item_size);

        const slot = try self.reserve(idx);
        @memcpy(slot[0..data.len], data);
        self.commit(idx, data.len);
    }

    /// Advances the wave past every committed item that extends the
    /// consecutive run starting at `idx`.
    ///
    /// The item at `idx` is committed before this is called, so the wave moves
    /// at least one step whenever `idx` is the wave. Upstream checked for a
    /// successor before stepping and compared relative slot numbers directly,
    /// which left the wave on the last linked item and stopped dead at a slot
    /// wrap; both let a repeated frame pass the outdated check and relink a
    /// slot. The step here is taken in ring order, so the run crosses `mod`.
    inline fn advanceWave(self: *Self, idx: u64) void {
        var frontIdx: i32 = @intCast(idx & (self.mod - 1));
        const mod: i32 = @truncate(@as(i64, @bitCast(self.mod)));

        if (self.wave != idx) {
            return;
        }

        while (true) {
            self.wave += 1;

            const nextIdx = self.nexts[@intCast(frontIdx)];
            if (nextIdx < 0) {
                return;
            }
            if (((nextIdx -% frontIdx) & (mod - 1)) != 1) {
                return;
            }

            frontIdx = nextIdx;
        }
    }

    /// Removes and returns the head item only if its sequence index equals
    /// `idx`, otherwise returns null and leaves the buffer untouched.
    ///
    /// The returned slice is a borrowed view into the buffer and carries the
    /// item's committed length: it stays valid until a later `push` reuses its
    /// slot, and is not owned by the caller.
    pub fn popHeadCond(self: *Self, idx: u64) ?[]u8 {
        const relIdx: i32 = @intCast(idx & (self.mod - 1));

        if (self.first != relIdx) {
            return null;
        }

        const offset = @as(usize, @intCast(relIdx)) * self.item_size;
        const len = self.lens[@intCast(relIdx)];
        const res = self.buf[offset .. offset + len];

        const second = self.nexts[@bitCast(@as(i64, relIdx))];
        if (second < 0) {
            self.first = -1;
            self.last = -1;
            return res;
        }

        self.prevs[@bitCast(@as(i64, second))] = -1;
        self.first = second;
        return res;
    }

    /// Returns the head item only if its index matches, WITHOUT removing it, so
    /// a caller can retry a failed dispatch on the next pass.
    pub fn peekHeadCond(self: *Self, idx: u64) ?[]u8 {
        const relIdx: i32 = @intCast(idx & (self.mod - 1));

        if (self.first != relIdx) {
            return null;
        }

        const offset = @as(usize, @intCast(relIdx)) * self.item_size;
        const len = self.lens[@intCast(relIdx)];
        return self.buf[offset .. offset + len];
    }

    /// Removes the current head item without returning it.
    pub fn dropHead(self: *Self) void {
        if (self.first < 0) {
            return;
        }

        const second = self.nexts[@bitCast(@as(i64, self.first))];
        if (second < 0) {
            self.first = -1;
            self.last = -1;
            return;
        }

        self.prevs[@bitCast(@as(i64, second))] = -1;
        self.first = second;
    }
};

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "reorder buffer" {
    const allocator = std.testing.allocator;

    {
        // Write-delete-write-delete.
        var ordbuf: ReorderBuffer = undefined;
        try ordbuf.init(allocator, 128, 1);
        defer ordbuf.deinit();
        for (0..1000) |i| {
            const buf = [1]u8{@truncate(i)};
            try ordbuf.push(i, buf[0..1]);

            const res = ordbuf.popHeadCond(i) orelse {
                std.debug.panic("expected buffer, got null", .{});
            };

            try std.testing.expectEqualSlices(u8, buf[0..1], res);
        }
    }

    {
        // Write 1-2, add 0, write 4-5, add 3. And so on for a while.
        var ordbuf: ReorderBuffer = undefined;
        try ordbuf.init(allocator, 128, 1);
        defer ordbuf.deinit();
        for (0..15) |i| {
            const tasks = [3]u64{
                i * 3 + 1,
                i * 3 + 2,
                i * 3,
            };
            for (tasks) |value| {
                const buf = [1]u8{@truncate(value)};
                try ordbuf.push(value, buf[0..1]);
            }
        }

        for (0..15 * 3) |index| {
            if (ordbuf.popHeadCond(index + 1) != null) {
                std.debug.panic("unexpected element from the head", .{});
            }

            const res = ordbuf.popHeadCond(index) orelse {
                std.debug.panic("missing expected element {} in the head", .{index});
            };

            if (ordbuf.popHeadCond(index) != null) {
                std.debug.panic("unexpected element from the head", .{});
            }

            const ref = [1]u8{@truncate(index)};
            try std.testing.expectEqualSlices(u8, ref[0..1], res[0..1]);
        }

        if (ordbuf.popHeadCond(15 * 3) != null) {
            std.debug.panic("unexpected element from the head", .{});
        }
    }
}

test "the wave passes every consecutive committed item" {
    var ordbuf: ReorderBuffer = undefined;
    try ordbuf.init(std.testing.allocator, 16, 1);
    defer ordbuf.deinit();

    for ([_]u64{ 1, 2, 0 }) |value| {
        const buf = [1]u8{@truncate(value)};
        try ordbuf.push(value, buf[0..1]);
    }
    try expectEqual(@as(u64, 3), ordbuf.wave);

    try std.testing.expectError(error.OutdatedFrame, ordbuf.reserve(2));

    const three = [1]u8{3};
    try ordbuf.push(3, &three);
    try expectEqual(@as(u64, 4), ordbuf.wave);
}

test "the wave advance survives a relative slot wrap" {
    var ordbuf: ReorderBuffer = undefined;
    try ordbuf.init(std.testing.allocator, 16, 1);
    defer ordbuf.deinit();

    // Bring the wave to 31 with an empty pending list, so the next commit
    // lands on relative slot 0 across the ring wrap.
    for (0..31) |i| {
        const buf = [1]u8{@truncate(i)};
        try ordbuf.push(i, buf[0..1]);
        _ = ordbuf.popHeadCond(i).?;
    }
    try expectEqual(@as(u64, 31), ordbuf.wave);

    const at32 = [1]u8{32};
    try ordbuf.push(32, &at32);
    const at31 = [1]u8{31};
    try ordbuf.push(31, &at31);

    try expectEqual(@as(u64, 33), ordbuf.wave);
    try std.testing.expectError(error.OutdatedFrame, ordbuf.reserve(32));

    try std.testing.expectEqualSlices(u8, &at31, ordbuf.popHeadCond(31).?);
    try std.testing.expectEqualSlices(u8, &at32, ordbuf.popHeadCond(32).?);
}

test "a frame arrives as a prefix and two short bodies, and delivers once" {
    var ordbuf: ReorderBuffer = undefined;
    try ordbuf.init(std.testing.allocator, 16, 64);
    defer ordbuf.deinit();

    const frame = [_]u8{ 'h', 'd', 'r', '!' } ++ "body";
    try expectEqual(@as(usize, 8), frame.len);

    const slot = try ordbuf.reserve(0);
    @memcpy(slot[0..4], frame[0..4]);
    @memcpy(slot[4..6], frame[4..6]);
    @memcpy(slot[6..8], frame[6..8]);
    try expectEqual(@as(usize, 64), slot.len);
    ordbuf.commit(0, frame.len);

    const head = ordbuf.peekHeadCond(0) orelse std.debug.panic("missing head", .{});
    try expectEqual(@as(usize, frame.len), head.len);
    try std.testing.expectEqualSlices(u8, frame[0..], head);

    ordbuf.dropHead();
    try expect(ordbuf.peekHeadCond(0) == null);
    try expect(ordbuf.popHeadCond(0) == null);
}

test "an index below the wave and one at the window's edge are rejected" {
    var ordbuf: ReorderBuffer = undefined;
    try ordbuf.init(std.testing.allocator, 16, 2);
    defer ordbuf.deinit();

    try ordbuf.push(0, "aa");
    try std.testing.expectError(error.OutdatedFrame, ordbuf.reserve(0));
    // The wave is at 1 after the push, so 17 is `wave + size` and 16 is the
    // last index inside the window.
    try std.testing.expectError(error.FramesAreTooFarAway, ordbuf.reserve(17));

    const slot = try ordbuf.reserve(16);
    try expectEqual(@as(usize, 2), slot.len);
    ordbuf.abandon(16);
}

test "abandon frees the slot for reuse" {
    var ordbuf: ReorderBuffer = undefined;
    try ordbuf.init(std.testing.allocator, 16, 2);
    defer ordbuf.deinit();

    const first = try ordbuf.reserve(0);
    @memcpy(first[0..2], "xx");
    ordbuf.abandon(0);

    const again = try ordbuf.reserve(0);
    @memcpy(again[0..2], "yy");
    ordbuf.commit(0, 2);

    try std.testing.expectEqualSlices(u8, "yy", ordbuf.popHeadCond(0).?);
}

test "reset clears the wave, the list, the lengths and the reservation" {
    var ordbuf: ReorderBuffer = undefined;
    try ordbuf.init(std.testing.allocator, 16, 2);
    defer ordbuf.deinit();

    try ordbuf.push(1, "bb");
    _ = try ordbuf.reserve(0);

    ordbuf.reset();

    try expectEqual(@as(u64, 0), ordbuf.wave);
    try expect(ordbuf.peekHeadCond(0) == null);
    try expect(ordbuf.peekHeadCond(1) == null);

    const slot = try ordbuf.reserve(0);
    @memcpy(slot[0..1], "z");
    ordbuf.commit(0, 1);
    try std.testing.expectEqualSlices(u8, "z", ordbuf.peekHeadCond(0).?);
}

test "the shim records the pushed length, not the slot size" {
    var ordbuf: ReorderBuffer = undefined;
    try ordbuf.init(std.testing.allocator, 16, 8);
    defer ordbuf.deinit();

    try ordbuf.push(0, "abc");
    try expectEqual(@as(usize, 3), ordbuf.peekHeadCond(0).?.len);
    try std.testing.expectEqualSlices(u8, "abc", ordbuf.popHeadCond(0).?);
}

test "init rejects a non-power-of-two and an oversized window" {
    var ordbuf: ReorderBuffer = undefined;
    try std.testing.expectError(
        error.ReorderBufferSizeMustBeAPowOf2,
        ordbuf.init(std.testing.allocator, 3, 8),
    );
    try std.testing.expectError(
        error.ReorderBufferNoMoreThan32KibItems,
        ordbuf.init(std.testing.allocator, 0x1_0000, 8),
    );
}
