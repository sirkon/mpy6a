//! The ordered queue of sessions awaiting replay.
//!
//! Stage one is a `std.PriorityQueue` over opaque replay blobs. Later the
//! wrapper is replaced by an object with the same surface and composite
//! internals, where the heap is only one provider among several ordered files.
//! The wrapper exists from the start so that its failable surface already
//! expresses failures of the backing storage: today allocation, later the
//! file-backed providers.
//!
//! The blob layout is the queue's storage contract: a fixed 24-byte head with
//! the ordering key, then the length-prefixed `SessionData` bytes.

const std = @import("std");

/// Offset of `retry_time: LE(u64)` inside a blob.
pub const RETRY_TIME_OFF: usize = 0;
/// Offset of `session_id: LE(u128)` inside a blob.
pub const SESSION_ID_OFF: usize = 8;
/// The fixed head of every replay blob: retry time then session id.
pub const BLOB_HEAD: usize = 24;

/// Extended when the composite/file-backed providers land.
pub const Error = error{OutOfMemory};

/// Numeric tuple order on the blob heads: retry time first, session id
/// second. Both heads are decoded into integers and compared numerically; a
/// `memcmp` over the little-endian bytes is not the tuple order (`0x0102` is
/// less than `0x0201` numerically, while byte-lexicographic order says the
/// opposite) and is deliberately not used.
pub fn blobOrder(_: void, a: []u8, b: []u8) std.math.Order {
    std.debug.assert(a.len >= BLOB_HEAD);
    std.debug.assert(b.len >= BLOB_HEAD);

    const a_time = std.mem.readInt(u64, a[RETRY_TIME_OFF..][0..8], .little);
    const b_time = std.mem.readInt(u64, b[RETRY_TIME_OFF..][0..8], .little);
    if (a_time != b_time) return std.math.order(a_time, b_time);

    const a_id = std.mem.readInt(u128, a[SESSION_ID_OFF..][0..16], .little);
    const b_id = std.mem.readInt(u128, b[SESSION_ID_OFF..][0..16], .little);
    return std.math.order(a_id, b_id);
}

/// The stage-one queue. Owns every blob it holds: `push` copies, `pop` and
/// `removeSessionId` transfer ownership, `deinit` frees what is left, and
/// `snapshotHandles` only borrows.
pub const ReplayQueue = struct {
    const Self = @This();
    const Inner = std.PriorityQueue([]u8, void, blobOrder);

    allocator: std.mem.Allocator,
    inner: Inner,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .inner = .empty,
        };
    }

    /// Borrow of the head blob, valid until the queue's next mutation.
    pub fn peek(self: *Self) Error!?[]u8 {
        return self.inner.peek();
    }

    /// The recorded due time of the head, decoded; null when empty. The
    /// mechanical helper for the service loop's external time check.
    pub fn peekRetryTime(self: *Self) Error!?u64 {
        const blob = self.inner.peek() orelse return null;
        return std.mem.readInt(u64, blob[RETRY_TIME_OFF..][0..8], .little);
    }

    /// Copies the blob; the queue owns its copy.
    pub fn push(self: *Self, blob: []const u8) Error!void {
        const owned = try self.allocator.dupe(u8, blob);
        errdefer self.allocator.free(owned);
        try self.inner.push(self.allocator, owned);
    }

    /// Removes the head and transfers ownership of the blob.
    pub fn pop(self: *Self) Error!?[]u8 {
        return self.inner.pop();
    }

    /// O(n) scan matching the session id at blob bytes `[8, 24)`, then the
    /// heap's `popIndex`; transfers the blob. `std`'s `update()` only matches
    /// a full `(time, id)` pair and is useless for closing or re-arming a
    /// queued session by id.
    pub fn removeSessionId(self: *Self, id: u128) Error!?[]u8 {
        for (self.inner.items, 0..) |blob, i| {
            const queued_id = std.mem.readInt(
                u128,
                blob[SESSION_ID_OFF..][0..16],
                .little,
            );
            if (queued_id == id) return self.inner.popIndex(i);
        }
        return null;
    }

    pub fn count(self: *const Self) usize {
        return self.inner.items.len;
    }

    /// Ordered-dump support: duplicates the handle slice only; the blobs are
    /// borrowed and stay owned by the queue. The dump sorts the handles with
    /// `blobOrder` and emits in that order.
    pub fn snapshotHandles(self: *Self) Error![][]u8 {
        const handles = try self.allocator.alloc([]u8, self.inner.items.len);
        @memcpy(handles, self.inner.items);
        return handles;
    }

    /// Frees every blob still held, then the items array.
    pub fn deinit(self: *Self) void {
        for (self.inner.items) |blob| self.allocator.free(blob);
        self.inner.deinit(self.allocator);
        self.* = undefined;
    }
};

fn testBlob(retry_time: u64, session_id: u128) [BLOB_HEAD + 1]u8 {
    var blob: [BLOB_HEAD + 1]u8 = undefined;
    std.mem.writeInt(u64, blob[RETRY_TIME_OFF..][0..8], retry_time, .little);
    std.mem.writeInt(u128, blob[SESSION_ID_OFF..][0..16], session_id, .little);
    blob[BLOB_HEAD] = 0;
    return blob;
}

test "blobOrder compares numerically, not byte-lexicographically" {
    const a = testBlob(0x0102, 0);
    const b = testBlob(0x0201, 0);

    try std.testing.expectEqual(std.math.Order.lt, blobOrder({}, @constCast(&a), @constCast(&b)));
    try std.testing.expectEqual(std.math.Order.gt, blobOrder({}, @constCast(&b), @constCast(&a)));
}

test "blobOrder breaks time ties by the session id" {
    const a = testBlob(7, 0x0000_0000_0000_0001_0000_0000_0000_0001);
    const b = testBlob(7, 0x0000_0000_0000_0001_0000_0000_0000_0002);

    try std.testing.expectEqual(std.math.Order.lt, blobOrder({}, @constCast(&a), @constCast(&b)));
}

test "queue drains in tuple order and keeps ownership one-way" {
    var queue = ReplayQueue.init(std.testing.allocator);
    defer queue.deinit();

    const entries = [_]struct { time: u64, id: u128 }{
        .{ .time = 30, .id = 3 },
        .{ .time = 10, .id = 2 },
        .{ .time = 10, .id = 1 },
        .{ .time = 20, .id = 9 },
    };
    for (entries) |entry| {
        const blob = testBlob(entry.time, entry.id);
        try queue.push(&blob);
    }

    try std.testing.expectEqual(@as(usize, 4), queue.count());
    try std.testing.expectEqual(@as(?u64, 10), try queue.peekRetryTime());

    const expected = [_]struct { time: u64, id: u128 }{
        .{ .time = 10, .id = 1 },
        .{ .time = 10, .id = 2 },
        .{ .time = 20, .id = 9 },
        .{ .time = 30, .id = 3 },
    };
    for (expected) |want| {
        const blob = (try queue.pop()).?;
        defer std.testing.allocator.free(blob);
        try std.testing.expectEqual(want.time, std.mem.readInt(u64, blob[RETRY_TIME_OFF..][0..8], .little));
        try std.testing.expectEqual(want.id, std.mem.readInt(u128, blob[SESSION_ID_OFF..][0..16], .little));
    }
    try std.testing.expectEqual(@as(?[]u8, null), try queue.pop());
}

test "queue removes by session id without disturbing the rest" {
    var queue = ReplayQueue.init(std.testing.allocator);
    defer queue.deinit();

    const first = testBlob(5, 100);
    const second = testBlob(6, 200);
    const third = testBlob(7, 300);
    try queue.push(&first);
    try queue.push(&second);
    try queue.push(&third);

    const removed = (try queue.removeSessionId(200)).?;
    std.testing.allocator.free(removed);

    try std.testing.expectEqual(@as(usize, 2), queue.count());
    try std.testing.expectEqual(@as(?[]u8, null), try queue.removeSessionId(999));

    const head = (try queue.pop()).?;
    defer std.testing.allocator.free(head);
    try std.testing.expectEqual(@as(u128, 100), std.mem.readInt(u128, head[SESSION_ID_OFF..][0..16], .little));
}

test "peek does not disturb the queue" {
    var queue = ReplayQueue.init(std.testing.allocator);
    defer queue.deinit();

    const blob = testBlob(11, 42);
    try queue.push(&blob);

    try std.testing.expectEqual(@as(usize, 1), queue.count());
    try std.testing.expectEqual(@as(?u64, 11), try queue.peekRetryTime());
    try std.testing.expectEqual(@as(usize, 1), queue.count());
    try std.testing.expectEqual(@as(?u64, 11), try queue.peekRetryTime());
}

test "push reports OutOfMemory from a failing allocator" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var queue = ReplayQueue.init(failing.allocator());
    defer queue.deinit();

    const blob = testBlob(1, 1);
    try std.testing.expectError(error.OutOfMemory, queue.push(&blob));
    try std.testing.expectEqual(@as(usize, 0), queue.count());
}

test "snapshotHandles borrows blobs and sorts into queue order" {
    var queue = ReplayQueue.init(std.testing.allocator);
    defer queue.deinit();

    const late = testBlob(9, 1);
    const early = testBlob(1, 2);
    try queue.push(&late);
    try queue.push(&early);

    const handles = try queue.snapshotHandles();
    defer std.testing.allocator.free(handles);

    std.mem.sort([]u8, handles, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return blobOrder({}, a, b) == .lt;
        }
    }.less);

    try std.testing.expectEqual(@as(usize, 2), handles.len);
    try std.testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, handles[0][RETRY_TIME_OFF..][0..8], .little));
    try std.testing.expectEqual(@as(u64, 9), std.mem.readInt(u64, handles[1][RETRY_TIME_OFF..][0..8], .little));
    try std.testing.expectEqual(@as(usize, 2), queue.count());
}
