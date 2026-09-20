const std = @import("std");
const zigring = @import("zigring");
const cross_task = @import("cross_task.zig");

const CrossTask = cross_task.CrossTask;

/// Fixed-size slot allocator for `CrossTask` values that travel between OS
/// threads.
///
/// Capacity is chosen once at `init` and never changes afterwards: every slot
/// comes from one preallocated array and the free slots are threaded through a
/// free-list, so `acquire` and `release` never touch the backing allocator.
/// A libc mutex guards `head`, `tail` and `nexts`, making the allocator itself
/// safe to share between threads; the values stored in the slots are not
/// synchronized in any way.
pub const CrossTaskSlots = struct {
    const Self = @This();

    /// Returned by `acquire` when every slot is currently handed out.
    pub const AcquireError = error{CrossTaskFull};

    /// Backing allocator, kept so `deinit` can hand the slices back.
    allocator: std.mem.Allocator,
    /// Slots handed out by `acquire`. Values are left untouched by this type.
    tasks: []CrossTask,
    /// Index of the first free slot, -1 when every slot is handed out.
    head: i32,
    /// Index of the last free slot, only meaningful while `head >= 0`.
    tail: i32,
    /// `nexts[i]` is the free slot after `i`, or -1 when `i` ends the list.
    nexts: []i32,
    /// Guards `head`, `tail` and `nexts`.
    mutex: zigring.Mutex,

    /// Allocates `n` slots, all free, in hand-out order.
    ///
    /// `n` must be at least 1; the returned allocator owns the slices, so
    /// `deinit` must be called on the same instance, and the peer threads must
    /// have stopped before that happens.
    pub fn init(allocator: std.mem.Allocator, n: usize) !Self {
        // An empty table has no valid head/tail pair (head would start at 0,
        // one past the last free slot), and an index must fit in i32.
        if (n == 0 or n > std.math.maxInt(i32)) return error.InvalidSize;

        const tasks = try allocator.alloc(CrossTask, n);
        errdefer allocator.free(tasks);

        const nexts = try allocator.alloc(i32, n);
        errdefer allocator.free(nexts);

        var i: usize = 0;
        while (i + 1 < n) : (i += 1) {
            nexts[i] = @intCast(i + 1);
        }
        nexts[n - 1] = -1;

        return .{
            .allocator = allocator,
            .tasks = tasks,
            .head = 0,
            .tail = @intCast(n - 1),
            .nexts = nexts,
            .mutex = zigring.Mutex.init(),
        };
    }

    /// Destroys the mutex and returns the slices to the allocator.
    ///
    /// The caller must ensure no other thread still uses the allocator.
    pub fn deinit(self: *Self) void {
        self.mutex.deinit();
        self.allocator.free(self.tasks);
        self.allocator.free(self.nexts);
    }

    /// Pops the first free slot and returns its index, or `error.CrossTaskFull`
    /// when all `n` slots are currently handed out.
    ///
    /// The slot's memory is uninitialized and owned by the caller until the
    /// index is passed to `release`. Only `acquire` and `release` may touch the
    /// slot in the meantime; `at` exposes the pointer the caller writes through.
    pub fn acquire(self: *Self) AcquireError!u32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const i = self.head;
        if (i < 0) return error.CrossTaskFull;

        const index: usize = @intCast(i);
        self.head = self.nexts[index];
        return @intCast(index);
    }

    /// The task stored in slot `i`.
    ///
    /// `i` must be an index currently handed out by `acquire`; the returned
    /// pointer stays valid until `i` is released.
    pub fn at(self: *Self, i: u32) *CrossTask {
        return &self.tasks[i];
    }

    /// Returns slot `i` to the free-list, appending it after the current tail so
    /// freed slots are handed back in release order.
    ///
    /// `i` must be an index currently handed out by `acquire`; releasing any
    /// other index is a caller bug that would splice the free-list onto itself,
    /// so it is left unchecked.
    pub fn release(self: *Self, i: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.nexts[i] = -1;
        const idx: i32 = @intCast(i);
        if (self.head < 0) {
            self.head = idx;
            self.tail = idx;
        } else {
            self.nexts[@intCast(self.tail)] = idx;
            self.tail = idx;
        }
    }
};

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

/// Number of slots currently on the free-list; bounded so a corrupted list
/// makes a test fail instead of hanging.
fn freeCount(slots: *const CrossTaskSlots) usize {
    var count: usize = 0;
    var cur = slots.head;
    while (cur >= 0) : (cur = slots.nexts[@intCast(cur)]) {
        count += 1;
        if (count > slots.tasks.len) return count;
    }
    return count;
}

test "init links every slot in index order and starts empty of handed-out slots" {
    var slots = try CrossTaskSlots.init(std.testing.allocator, 4);
    defer slots.deinit();

    try expectEqual(@as(i32, 0), slots.head);
    try expectEqual(@as(i32, 3), slots.tail);
    try expectEqual(@as(usize, 4), freeCount(&slots));

    for (slots.nexts, 0..) |next, i| {
        const expected: i32 = if (i + 1 < slots.tasks.len) @intCast(i + 1) else -1;
        try expectEqual(expected, next);
    }
}

test "acquire pops the head and reports exhaustion" {
    var slots = try CrossTaskSlots.init(std.testing.allocator, 3);
    defer slots.deinit();

    var taken: [3]u32 = undefined;
    for (&taken) |*p| {
        // acquire always pops `head`, so the index it returned is the one `head`
        // pointed at before the call.
        const expected = slots.head;
        p.* = try slots.acquire();
        try expectEqual(@as(u32, @intCast(expected)), p.*);
        try expectEqual(slots.nexts[@intCast(expected)], slots.head);
    }

    try expectEqual(@as(i32, -1), slots.head);
    try expectEqual(@as(usize, 0), freeCount(&slots));

    // Fully occupied: further acquires fail without disturbing the state.
    try std.testing.expectError(error.CrossTaskFull, slots.acquire());
    try std.testing.expectError(error.CrossTaskFull, slots.acquire());
    try expectEqual(@as(usize, 0), freeCount(&slots));
}

test "single-slot allocator cycles between full and empty" {
    var slots = try CrossTaskSlots.init(std.testing.allocator, 1);
    defer slots.deinit();

    try expectEqual(@as(i32, 0), slots.head);
    try expectEqual(@as(i32, 0), slots.tail);
    try expectEqual(@as(i32, -1), slots.nexts[0]);

    const i = try slots.acquire();
    try expectEqual(@as(u32, 0), i);
    try expect(slots.at(i) == &slots.tasks[0]);
    try expectEqual(@as(i32, -1), slots.head);
    try std.testing.expectError(error.CrossTaskFull, slots.acquire());

    slots.release(0);
    try expectEqual(@as(i32, 0), slots.head);
    try expectEqual(@as(i32, 0), slots.tail);
    _ = try slots.acquire();
}

test "release appends to the tail so freed slots come back in release order" {
    var slots = try CrossTaskSlots.init(std.testing.allocator, 3);
    defer slots.deinit();

    for (0..3) |_| _ = try slots.acquire();
    try expectEqual(@as(i32, -1), slots.head);
    try expectEqual(@as(usize, 0), freeCount(&slots));

    // First release into an empty list: the slot becomes both head and tail.
    slots.release(2);
    try expectEqual(@as(i32, 2), slots.head);
    try expectEqual(@as(i32, 2), slots.tail);
    try expectEqual(@as(i32, -1), slots.nexts[2]);

    // Second release: appended after the tail, head untouched.
    slots.release(0);
    try expectEqual(@as(i32, 2), slots.head);
    try expectEqual(@as(i32, 0), slots.tail);
    try expectEqual(@as(i32, 0), slots.nexts[2]);
    try expectEqual(@as(i32, -1), slots.nexts[0]);
    try expectEqual(@as(usize, 2), freeCount(&slots));

    var order: [2]u32 = undefined;
    for (&order) |*idx| {
        idx.* = try slots.acquire();
    }
    try expectEqual(@as(u32, 2), order[0]);
    try expectEqual(@as(u32, 0), order[1]);
    try std.testing.expectError(error.CrossTaskFull, slots.acquire());
}

test "init rejects a zero-slot allocator" {
    try std.testing.expectError(error.InvalidSize, CrossTaskSlots.init(std.testing.allocator, 0));
}

test "concurrent acquire and release keep every slot on the free-list" {
    const thread_count = 4;
    var slots = try CrossTaskSlots.init(std.testing.allocator, 8);
    defer slots.deinit();

    const Worker = struct {
        slots: *CrossTaskSlots,
        iterations: usize,

        fn run(self: *@This()) void {
            var k: usize = 0;
            while (k < self.iterations) : (k += 1) {
                const i = self.slots.acquire() catch continue;
                self.slots.at(i).* = .{ .Placeholder = .{} };
                self.slots.release(i);
            }
        }
    };

    var workers: [thread_count]Worker = undefined;
    var threads: [thread_count]zigring.Thread = undefined;
    for (&workers) |*w| w.* = .{ .slots = &slots, .iterations = 2000 };
    for (&workers, &threads) |*w, *t| t.* = try zigring.Thread.spawn(w, Worker.run);
    for (&threads) |t| t.join();

    try expectEqual(slots.tasks.len, freeCount(&slots));
}
