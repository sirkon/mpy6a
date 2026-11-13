const std = @import("std");
const zigring = @import("zigring");
const cross_task = @import("cross_task.zig");

/// Fixed-size slot allocator for payload values that travel between OS
/// threads.
///
/// Capacity is chosen once at `init` and never changes afterwards: every slot
/// comes from one preallocated array and the free slots are threaded through a
/// free-list, so `acquire` and `release` never touch the backing allocator.
/// A libc mutex guards `head`, `tail` and `nexts`, making the allocator itself
/// safe to share between threads; the values stored in the slots are not
/// synchronized in any way.
///
/// The pool is parametrized over its payload: `CrossTask` values ride the
/// process-wide `cross_slots`, snapshot slot statuses ride `snapshot_slots`
/// (designs/SNAPSHOTS.md §2.1).
pub fn SlotPool(comptime Payload: type) type {
    return struct {
        const Self = @This();

        /// Returned by `acquire` when every slot is currently handed out.
        pub const AcquireError = error{CrossTaskFull};

        /// Backing allocator, kept so `deinit` can hand the slices back.
        allocator: std.mem.Allocator,
        /// Slots handed out by `acquire`. Values are left untouched by this type.
        tasks: []Payload,
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
        pub fn init(self: *Self, allocator: std.mem.Allocator, n: usize) !void {
            // An empty table has no valid head/tail pair (head would start at 0,
            // one past the last free slot), and an index must fit in i32.
            if (n == 0 or n > std.math.maxInt(i32)) return error.InvalidSize;

            const tasks = try allocator.alloc(Payload, n);
            errdefer allocator.free(tasks);

            const nexts = try allocator.alloc(i32, n);
            errdefer allocator.free(nexts);

            var i: usize = 0;
            while (i + 1 < n) : (i += 1) {
                nexts[i] = @intCast(i + 1);
            }
            nexts[n - 1] = -1;

            self.* = .{
                .allocator = allocator,
                .tasks = tasks,
                .head = 0,
                .tail = @intCast(n - 1),
                .nexts = nexts,
                .mutex = undefined,
            };
            self.mutex.init();
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

        /// The payload stored in slot `i`.
        ///
        /// `i` must be an index currently handed out by `acquire`; the returned
        /// pointer stays valid until `i` is released.
        pub fn at(self: *Self, i: u32) *Payload {
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

        /// Number of slots currently on the free-list; bounded so a corrupted list
        /// makes a test fail instead of hanging.
        pub fn freeCount(self: *const Self) usize {
            var count: usize = 0;
            var cur = self.head;
            while (cur >= 0) : (cur = self.nexts[@intCast(cur)]) {
                count += 1;
                if (count > self.tasks.len) return count;
            }
            return count;
        }
    };
}

/// The cross-thread task pool every thread of the shard shares.
pub const CrossTaskSlots = SlotPool(cross_task.CrossTask);

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "init links every slot in index order and starts empty of handed-out slots" {
    var slots: CrossTaskSlots = undefined;
    try slots.init(std.testing.allocator, 4);
    defer slots.deinit();

    try expectEqual(@as(i32, 0), slots.head);
    try expectEqual(@as(i32, 3), slots.tail);
    try expectEqual(@as(usize, 4), slots.freeCount());

    for (slots.nexts, 0..) |next, i| {
        const expected: i32 = if (i + 1 < slots.tasks.len) @intCast(i + 1) else -1;
        try expectEqual(expected, next);
    }
}

test "acquire pops the head and reports exhaustion" {
    var slots: CrossTaskSlots = undefined;
    try slots.init(std.testing.allocator, 3);
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
    try expectEqual(@as(usize, 0), slots.freeCount());

    // Fully occupied: further acquires fail without disturbing the state.
    try std.testing.expectError(error.CrossTaskFull, slots.acquire());
    try std.testing.expectError(error.CrossTaskFull, slots.acquire());
    try expectEqual(@as(usize, 0), slots.freeCount());
}

test "single-slot allocator cycles between full and empty" {
    var slots: CrossTaskSlots = undefined;
    try slots.init(std.testing.allocator, 1);
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
    var slots: CrossTaskSlots = undefined;
    try slots.init(std.testing.allocator, 3);
    defer slots.deinit();

    for (0..3) |_| _ = try slots.acquire();
    try expectEqual(@as(i32, -1), slots.head);
    try expectEqual(@as(usize, 0), slots.freeCount());

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
    try expectEqual(@as(usize, 2), slots.freeCount());

    var order: [2]u32 = undefined;
    for (&order) |*idx| {
        idx.* = try slots.acquire();
    }
    try expectEqual(@as(u32, 2), order[0]);
    try expectEqual(@as(u32, 0), order[1]);
    try std.testing.expectError(error.CrossTaskFull, slots.acquire());
}

test "init rejects a zero-slot allocator" {
    var slots: CrossTaskSlots = undefined;
    try std.testing.expectError(error.InvalidSize, slots.init(std.testing.allocator, 0));
}

test "concurrent acquire and release keep every slot on the free-list" {
    const thread_count = 4;
    var slots: CrossTaskSlots = undefined;
    try slots.init(std.testing.allocator, 8);
    defer slots.deinit();

    const Worker = struct {
        slots: *CrossTaskSlots,
        iterations: usize,

        fn run(self: *@This()) void {
            var k: usize = 0;
            while (k < self.iterations) : (k += 1) {
                const i = self.slots.acquire() catch continue;
                self.slots.at(i).* = .{ .ShutdownDemand = .{ .hard = false } };
                self.slots.release(i);
            }
        }
    };

    var workers: [thread_count]Worker = undefined;
    var threads: [thread_count]zigring.Thread = undefined;
    for (&workers) |*w| w.* = .{ .slots = &slots, .iterations = 2000 };
    for (&workers, &threads) |*w, *t| try t.spawn(w, Worker.run);
    for (&threads) |t| t.join();

    try expectEqual(slots.tasks.len, slots.freeCount());
}

test "a snapshot-slot pool round-trips and enforces the same bound" {
    var slots: SlotPool(cross_task.SnapshotSlot) = undefined;
    try slots.init(std.testing.allocator, 2);
    defer slots.deinit();

    try expectEqual(@as(usize, 2), slots.freeCount());

    const first = try slots.acquire();
    slots.at(first).* = .{ .status = .in_flight, .job = 0x1234 };
    try expectEqual(cross_task.SnapshotSlotStatus.in_flight, slots.at(first).status);
    try expectEqual(@as(usize, 0x1234), slots.at(first).job);

    const second = try slots.acquire();
    slots.at(second).* = .{ .status = .rollback, .job = 0x5678 };
    try expectEqual(cross_task.SnapshotSlotStatus.rollback, slots.at(second).status);
    try expectEqual(@as(usize, 0x5678), slots.at(second).job);

    // Same bound as the cross-task pool, whatever the payload.
    try std.testing.expectError(error.CrossTaskFull, slots.acquire());
    try expectEqual(@as(usize, 0), slots.freeCount());

    // The elephant's clear-then-release shape.
    slots.at(second).* = .{ .status = .idle, .job = 0 };
    slots.release(second);
    try expectEqual(@as(usize, 1), slots.freeCount());
    try expectEqual(second, try slots.acquire());
}
