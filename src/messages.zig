//! Shared vocabulary of the shard skeleton: the reserved `taskIdx` values that
//! threads use to talk to each other through io_uring, the payload types that
//! travel across thread boundaries, and the comptime proofs that none of the
//! reserved values can collide with the ones the `Slots` allocators hand out.
//!
//! Nothing here does any work. It only fixes the numbers and the types that
//! `front.zig`, `index.zig`, `elephant.zig`, `shutdown.zig` and `startup.zig`
//! agree on, so the handshake and the shutdown choreography can be read as one
//! protocol.
//!
//! Every cross-thread message is a `MSG_RING` into the receiver's ring. The
//! `taskIdx` of the resulting CQE says what the message *is*; the `res` field
//! carries at most one small word of payload:
//!
//! | taskIdx                 | `res`                      | sent by            |
//! |-------------------------|----------------------------|--------------------|
//! | `InitDoneIdx`           | sender's `thread_idx`      | every worker       |
//! | `InitFrontReadyIdx`     | front's `thread_idx`       | fronts             |
//! | `CrossTaskMessageIdx`   | `CrossTaskSlots` index     | anyone             |
//! | `IndexWakeupTaskIdx`    | wakeup code (no payload)   | fronts -> indexes  |
//! | `ShutdownDemandIdx`     | `CrossTaskSlots` index     | process -> workers |
//! | `ShutdownDoneIdx`       | sender's `thread_idx`      | fronts, elephants  |
//! | `SignalEventIdx`        | n/a                        | the eventfd read   |
//! | `ShutdownTickIdx`       | n/a                        | the shutdown timer |
//! | `InitTimeoutIdx`        | n/a                        | the init deadline  |
//!
//! Messages that need more than one word (the server socket descriptor, the
//! shutdown demands and drain reports) go through a `CrossTaskSlots` slot and
//! arrive as `CrossTaskMessageIdx`; the receiver reads the slot and releases
//! it. That split is exactly the one described in docs/shard-arch-hld.md.

const std = @import("std");
const posix = std.posix;
const zigring = @import("zigring");
const index_inbox = @import("index_inbox.zig");

/// taskIdx of the init-ring message reporting "this thread finished
/// initializing". `res` is the sender's `thread_idx`.
pub const InitDoneIdx: u64 = std.math.maxInt(u64) - 1;

/// taskIdx of the init-ring message reporting "this front received the server
/// socket and armed its accept machinery". Sent only by fronts, after their
/// `InitDoneIdx`.
pub const InitFrontReadyIdx: u64 = std.math.maxInt(u64) - 4;

/// A CQE whose `res` is an index into `CrossTaskSlots`; the payload is read
/// from the slot. Re-exported from `index_inbox.zig`, which owns the value for
/// the sleep/wakeup protocol.
pub const CrossTaskMessageIdx: u64 = index_inbox.CrossTaskMessageIdx;

/// A payload-less wakeup CQE for an index that announced sleep. Re-exported
/// from `index_inbox.zig`.
pub const IndexWakeupTaskIdx: u64 = index_inbox.IndexWakeupTaskIdx;

/// Process -> worker ring: stop what you are doing and drain. `res` is the
/// `CrossTaskSlots` index of a `CrossTask.ShutdownDemand`.
pub const ShutdownDemandIdx: u64 = std.math.maxInt(u64) - 5;

/// Worker -> init-ring: "I have drained and am about to exit". `res` is the
/// sender's `thread_idx`.
pub const ShutdownDoneIdx: u64 = std.math.maxInt(u64) - 6;

/// Init-ring: the signal eventfd became readable. `res` carries the byte count
/// of the read, which is uninteresting; the arrival itself is the event.
pub const SignalEventIdx: u64 = std.math.maxInt(u64) - 7;

/// Init-ring: the periodic 500 ms tick that polices the shutdown deadline.
pub const ShutdownTickIdx: u64 = std.math.maxInt(u64) - 8;

/// Init-ring: the startup handshake deadline expired.
pub const InitTimeoutIdx: u64 = std.math.maxInt(u64) - 9;

/// Index -> its parent front's ring: "I have drained". The front's flag set
/// carries the detail; this completion is only the wakeup. Its `res` is the
/// front's own `thread_idx`, which the front ignores.
pub const IndexDrainedIdx: u64 = std.math.maxInt(u64) - 10;

/// Every reserved `taskIdx`, in one place so the comptime block below can
/// prove they are pairwise distinct and out of reach of `Slots`.
pub const reserved_task_indices = [_]u64{
    InitDoneIdx,
    InitFrontReadyIdx,
    CrossTaskMessageIdx,
    IndexWakeupTaskIdx,
    ShutdownDemandIdx,
    ShutdownDoneIdx,
    SignalEventIdx,
    ShutdownTickIdx,
    InitTimeoutIdx,
    IndexDrainedIdx,
};

/// Upper bound on the number of slots any `Slots` table in this process can
/// hand out. `slots.zig` enforces the real per-ring capacity; this is the
/// value the reserved-range proof below is stated against.
pub const max_slot_capacity: u64 = 1 << 32;

comptime {
    // No two reserved indices may collide, and none of them may be the
    // fire-and-forget value the ring uses for untracked completions.
    for (reserved_task_indices, 0..) |a, i| {
        std.debug.assert(a != zigring.fireAndForgetTaskIdx);
        for (reserved_task_indices[i + 1 ..]) |b| {
            std.debug.assert(a != b);
        }
    }

    // All of them live in the top half of the u64 space ...
    for (reserved_task_indices) |idx| {
        std.debug.assert(idx >= (1 << 63));
    }

    // ... while every index a `Slots` table can hand out is far below, so a
    // real operation can never be mistaken for a reserved control message.
    std.debug.assert(max_slot_capacity < (1 << 63));
    std.debug.assert(max_slot_capacity - 1 < InitTimeoutIdx);
}

/// The timeout for the whole startup handshake, expressed in the `res` word of
/// an `InitTimeoutIdx` completion. Unused but kept so the field is not
/// misinterpreted by a reader.
pub const init_timeout_active: u32 = 1;

/// `msg_result` base of the payload-less control messages that travel without
/// a `CrossTaskSlots` slot. Kept strictly below
/// `index_inbox.NoPayloadMsgResultBase` so a control CQE can never be confused
/// with an index wakeup, and strictly above zero so it can never be mistaken
/// for an errno (those arrive as negative `res` values).
pub const ControlMsgResultBase: u32 = 0x4000_0000;

/// `msg_result` of an `InitDoneIdx`, `InitFrontReadyIdx` or `ShutdownDoneIdx`
/// report. Those messages carry no slot; the sender's `thread_idx` is a
/// separate part of the protocol (`res` holds it, see `init_report_thread`).
pub const ControlMsgResult: u32 = ControlMsgResultBase + 1;

/// `msg_result` of a `ShutdownDemandIdx` message that was sent without a slot.
/// The skeleton normally rides a `CrossTaskSlots` slot for shutdown demands, so
/// this code only shows up in the direct/test paths.
pub const ShutdownDemandMsgResult: u32 = ControlMsgResultBase + 2;

/// `msg_result` of the periodic shutdown deadline tick.
pub const ShutdownTickMsgResult: u32 = ControlMsgResultBase + 3;

/// `msg_result` of the signal notification.
pub const SignalMsgResult: u32 = ControlMsgResultBase + 4;

comptime {
    // Control codes must not collide with each other, must stay below the
    // inbox protocol's payload-less base, and must stay positive so that a
    // completion carrying one is never read as an errno.
    std.debug.assert(ControlMsgResult != ShutdownDemandMsgResult);
    std.debug.assert(ShutdownTickMsgResult != SignalMsgResult);
    std.debug.assert(ControlMsgResult > 0);
    std.debug.assert(SignalMsgResult < index_inbox.NoPayloadMsgResultBase);
}

/// Payload of a task that a front pushes into an index's `IndexInbox`.
///
/// The inbox is the cheap front -> index path: a lock-free SPSC ring in shared
/// memory, woken by a `MSG_RING` only when the index has announced sleep.
/// `CrossTaskSlots` remains reserved for work that arrives from outside the
/// front/index pair, per docs/startup-en.md.
pub const IndexTask = union(enum) {
    /// Route a freshly accepted client socket to this index. The skeleton
    /// never gets this far: it only logs the descriptor and closes it. The
    /// variant exists so the routing path is exercised end to end.
    CreateSession: struct {
        fd: posix.fd_t,
    },
    /// The front is draining: stop taking new sessions and report back once
    /// the index's own session count reaches zero.
    SoftShutdown: struct {
        thread_idx: u16,
    },

    /// A placeholder used by tests; never enqueued by the skeleton.
    Ping: struct {
        seq: u64,
    },
};

comptime {
    std.debug.assert(@sizeOf(IndexTask) > 0);
}

/// The concrete inbox type shared by fronts (producers) and indexes
/// (consumers). Aliased here so `context.zig` can name it without importing
/// `index.zig`, which would close an import cycle.
pub const Inbox = index_inbox.IndexInbox(IndexTask);

/// One bit per index, telling whether that index has reported drained.
///
/// docs/startup-en.md has the front's shutdown wait for its indexes, so an
/// index reports to its parent rather than to the process thread. The index
/// writes the bit and then nudges the front's ring; the front reads the bits
/// while draining that ring. A short-held mutex guards the store, so the
/// plain-bool read from the front is not a data race under the Zig memory
/// model. The number of indexes per front is tiny, so a bit set is plenty.
pub const IndexDrainFlags = struct {
    flags: std.DynamicBitSet,
    /// Guards `flags` against the index's store. Initialized in `init`, not as
    /// a field default: `zigring.Mutex.init` calls into libc, which is not
    /// allowed in a comptime default.
    mutex: zigring.Mutex,

    pub fn init(allocator: std.mem.Allocator, count: usize) !IndexDrainFlags {
        return .{
            .flags = try std.DynamicBitSet.initEmpty(allocator, count),
            .mutex = zigring.Mutex.init(),
        };
    }

    pub fn deinit(self: *IndexDrainFlags) void {
        self.mutex.deinit();
        self.flags.deinit();
    }

    /// Marks child `k` as drained and returns whether that was the first time.
    pub fn mark(self: *IndexDrainFlags, k: u16) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (k < self.flags.unmanaged.bit_length) self.flags.set(k);
    }

    /// Whether child `k` has reported. Read by the owning front only.
    pub fn isDrained(self: *const IndexDrainFlags, k: u16) bool {
        if (k >= self.flags.unmanaged.bit_length) return false;
        return self.flags.isSet(k);
    }

    pub fn drainedCount(self: *const IndexDrainFlags) usize {
        var n: usize = 0;
        var it = self.flags.iterator(.{});
        while (it.next()) |_| n += 1;
        return n;
    }
};

/// Where a thread sits in the process topology. `thread_idx` is the index into
/// the `rings` and `inboxes` arrays, and the numbering is fixed at startup:
///
/// ```text
/// 0 .. fronts                      fronts
/// fronts .. fronts + indexes       indexes, child of front
///                                  (i - fronts) / indexes_per_front
/// fronts + indexes .. total        elephants
/// ```
pub const Topology = struct {
    fronts: u16,
    indexes: u16,
    elephants: u16,
    indexes_per_front: u16,

    pub const Error = error{IndexesNotDivisibleByFronts};

    pub fn init(fronts: u16, indexes: u16, elephants: u16) Error!Topology {
        if (fronts == 0) {
            if (indexes != 0) return error.IndexesNotDivisibleByFronts;
            return .{ .fronts = 0, .indexes = 0, .elephants = elephants, .indexes_per_front = 0 };
        }
        if (indexes % fronts != 0) return error.IndexesNotDivisibleByFronts;
        return .{
            .fronts = fronts,
            .indexes = indexes,
            .elephants = elephants,
            .indexes_per_front = indexes / fronts,
        };
    }

    /// Total number of threads, i.e. the length of the `rings` array.
    pub fn total(self: Topology) u16 {
        return self.fronts + self.indexes + self.elephants;
    }

    /// Number of first-wave init-ring reports: one per front, one per index
    /// and one per elephant.
    pub fn initWave(self: Topology) u16 {
        return self.fronts + self.indexes + self.elephants;
    }

    pub fn isFront(self: Topology, thread_idx: u16) bool {
        return thread_idx < self.fronts;
    }

    pub fn isIndex(self: Topology, thread_idx: u16) bool {
        return thread_idx >= self.fronts and thread_idx < self.fronts + self.indexes;
    }

    pub fn isElephant(self: Topology, thread_idx: u16) bool {
        return thread_idx >= self.fronts + self.indexes;
    }

    /// Ring-array index of the front owning the index at `thread_idx`.
    pub fn parentFront(self: Topology, thread_idx: u16) u16 {
        std.debug.assert(self.isIndex(thread_idx));
        return (thread_idx - self.fronts) / self.indexes_per_front;
    }

    /// First ring-array index of the indexes owned by `front_idx`.
    pub fn firstIndex(self: Topology, front_idx: u16) u16 {
        return self.fronts + front_idx * self.indexes_per_front;
    }

    /// Ring-array index of the `k`-th index owned by front `front_idx`.
    pub fn nthIndex(self: Topology, front_idx: u16, k: u16) u16 {
        return self.firstIndex(front_idx) + k;
    }

    /// Ring-array index of the `k`-th index of the shard, counted globally.
    pub fn indexAt(self: Topology, k: u16) u16 {
        return self.fronts + k;
    }

    /// Offset of `thread_idx` into the `inboxes` array.
    pub fn inboxOffset(self: Topology, thread_idx: u16) u16 {
        std.debug.assert(self.isIndex(thread_idx));
        return thread_idx - self.fronts;
    }

    /// A human-readable role name for logging.
    pub fn roleName(self: Topology, thread_idx: u16) []const u8 {
        if (self.isFront(thread_idx)) return "front";
        if (self.isIndex(thread_idx)) return "index";
        std.debug.assert(self.isElephant(thread_idx));
        return "elephant";
    }
};

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "reserved indices are distinct and out of the slots range" {
    // The comptime block already proves this; the test keeps the property
    // visible from `zig build test` as well.
    for (reserved_task_indices, 0..) |a, i| {
        try expect(a != zigring.fireAndForgetTaskIdx);
        for (reserved_task_indices[i + 1 ..]) |b| try expect(a != b);
        try expect(a >= (1 << 63));
    }
    try expect(max_slot_capacity - 1 < InitTimeoutIdx);
}

test "index task is plain data and non-empty" {
    const t: IndexTask = .{ .CreateSession = .{ .fd = 3 } };
    try expectEqual(@as(posix.fd_t, 3), t.CreateSession.fd);
    try expect(@sizeOf(IndexTask) <= 16);
}

test "inbox alias is the protocol type" {
    try expect(Inbox == index_inbox.IndexInbox(IndexTask));
}

test "topology partitions the ring array" {
    const topo = try Topology.init(2, 4, 1);
    try expectEqual(@as(u16, 7), topo.total());
    try expectEqual(@as(u16, 7), topo.initWave());
    try expectEqual(@as(u16, 2), topo.indexes_per_front);

    try expect(topo.isFront(0));
    try expect(topo.isFront(1));
    try expect(topo.isIndex(2));
    try expect(topo.isIndex(5));
    try expect(topo.isElephant(6));

    try expectEqual(@as(u16, 0), topo.parentFront(2));
    try expectEqual(@as(u16, 0), topo.parentFront(3));
    try expectEqual(@as(u16, 1), topo.parentFront(4));
    try expectEqual(@as(u16, 1), topo.parentFront(5));
    try expectEqual(@as(u16, 2), topo.firstIndex(0));
    try expectEqual(@as(u16, 4), topo.firstIndex(1));
    try expectEqual(@as(u16, 3), topo.nthIndex(0, 1));
    try expectEqual(@as(u16, 6), topo.indexAt(4));
    try expectEqual(@as(u16, 2), topo.inboxOffset(4));
}

test "topology rejects a non-divisible index count" {
    try std.testing.expectError(error.IndexesNotDivisibleByFronts, Topology.init(2, 3, 0));
}

test "topology of a frontless shard" {
    const topo = try Topology.init(0, 0, 2);
    try expectEqual(@as(u16, 2), topo.total());
    try expect(topo.isElephant(0));
    try expect(topo.isElephant(1));
    try expect(!topo.isIndex(0));
}

test "role names cover every range" {
    const topo = try Topology.init(1, 2, 1);
    try std.testing.expectEqualStrings("front", topo.roleName(0));
    try std.testing.expectEqualStrings("index", topo.roleName(1));
    try std.testing.expectEqualStrings("index", topo.roleName(2));
    try std.testing.expectEqualStrings("elephant", topo.roleName(3));
}
