//! Per-ring `taskIdx` registries.
//!
//! Every tracked io_uring operation follows the same three steps, as described
//! in the zigring SDK:
//!
//! 1. take a slot from the ring's `Slots`, obtaining a `task_idx: u64`;
//! 2. push the SQE with `task_idx` as its `user_data`;
//! 3. on the matching CQE, look `cqe.taskIdx()` back up in the slot table and
//!    recover the operation context, then `del` the slot.
//!
//! Reserved control indices (`messages.zig`) must never come out of a slot
//! table. `zigring.Slots` hands out dense indices from a table of at least
//! 4096 entries, which is astronomically far from the reserved top-of-u64
//! range, so the invariant holds by construction; `slotCapacity` is the single
//! place that decides how big a table may ever be.

const std = @import("std");
const zigring = @import("zigring");
const messages = @import("messages.zig");
const wal = @import("wal.zig");

/// Maximum number of slots a single ring may register. `zigring.Slots`
/// requires a power of two of at least 4096, so this is also the smallest
/// legal capacity. Checked against the reserved taskIdx range in the comptime
/// block below.
pub const max_capacity: u64 = 4096;

/// Smallest capacity `zigring.Slots` accepts.
pub const min_capacity: u64 = 4096;

comptime {
    std.debug.assert(min_capacity <= max_capacity);
    std.debug.assert(std.math.isPowerOfTwo(max_capacity));
    // Slots indices stay below `max_capacity`, which must stay below every
    // reserved control index in `messages.zig`.
    std.debug.assert(max_capacity < messages.max_slot_capacity);
    std.debug.assert(max_capacity - 1 < messages.InitTimeoutIdx);
}

/// What a tracked operation was doing. Stored by copy (no destructor ever
/// runs, as `zigring.Slots` requires), so every variant is plain data.
pub const TaskCtx = union(enum) {
    /// A multishot accept armed on the front's listening socket.
    accept: struct {
        /// Where the front thread is in its own lifecycle bookkeeping.
        generation: u32 = 0,
    },
    /// A multishot accept armed on the shared peer listener. The client arm
    /// above stays single-purpose, so the two are never confused.
    peer_accept: struct {
        /// Where the front thread is in its own lifecycle bookkeeping.
        generation: u32 = 0,
    },
    /// The front's exact-length read of a peer greet, into its handshake
    /// entry's buffer.
    greet_read: struct {
        entry: u32,
    },
    /// The front's greet deadline: the one absolute clock over the re-armed
    /// partial reads.
    greet_deadline: struct {
        entry: u32,
    },
    /// A front-side reject reply. The connection is closed after this send's
    /// completion.
    reply_send: struct {
        entry: u32,
    },
    /// The acceptor's seven-byte greeting reply. The link goes `up` on this
    /// send's completion, or closes after it when the verdict rejects.
    greeting_send: struct {
        host_idx: u8,
        epoch: u32,
    },
    /// One frame's send completion: the buffer it used is freed here.
    frame_send: struct {
        host_idx: u8,
        epoch: u32,
    },
    /// One frame's receive completion: a header fragment or a body fragment.
    frame_recv: struct {
        host_idx: u8,
        epoch: u32,
    },
    /// A dedicated close of a link's descriptor, attributable by epoch.
    peer_close: struct {
        host_idx: u8,
        epoch: u32,
    },
    /// The switch predicate's own work: the verdict the parked candidate is
    /// answered with (§3.4). It is sent on the candidate's socket, never the
    /// link's, so its completion must not run the frame-send path.
    pulse: struct {
        host_idx: u8,
        epoch: u32,
    },
    /// The switch predicate's one-shot deadline: a link whose pulse the peer
    /// has not acknowledged by now is dead (§3.4).
    predicate_timeout: struct {
        host_idx: u8,
        epoch: u32,
    },
    /// A liveness tick: a repeating timer armed on every established link by
    /// both sides (§4.8). The completion carries no verdict; the link's ack
    /// flag decides whether the peer is still there.
    keepalive_tick: struct {
        host_idx: u8,
        epoch: u32,
    },
    /// The dialer's non-blocking connect to a peer host (§3.1).
    connect: struct {
        host_idx: u8,
        epoch: u32,
    },
    /// The dialer's connect bound: the one absolute clock around the connect.
    connect_deadline: struct {
        host_idx: u8,
        epoch: u32,
    },
    /// The dialer's five-byte greet, sent only after the connect completed.
    greet_send: struct {
        host_idx: u8,
        epoch: u32,
    },
    /// The dialer's exact-length read of the acceptor's seven-byte verdict.
    verdict_read: struct {
        host_idx: u8,
        epoch: u32,
    },
    /// The dialer's verdict-read deadline: one absolute clock over the
    /// re-armed partial reads (§3.5).
    reply_deadline: struct {
        host_idx: u8,
        epoch: u32,
    },
    /// The dialer's retry backoff timer (§3.6).
    retry_timer: struct {
        host_idx: u8,
        epoch: u32,
    },
    /// A multishot receive armed on one accepted client socket.
    recv: struct {
        fd: std.posix.fd_t,
    },
    /// A fire-and-forget close; kept so the completion can be matched to the
    /// descriptor it retired and logged once.
    close: struct {
        fd: std.posix.fd_t,
    },
    /// A standalone timeout.
    timeout: struct {
        generation: u32 = 0,
    },
    /// A one-shot accept used during shutdown backpressure.
    accept_once: struct {
        generation: u32 = 0,
    },
    logging: struct {
        buf: []u8,
    },
    /// A read of one WAL file: the process that steps it, the offset the read
    /// was armed at and the buffer it lands in (§F).
    file_read: struct {
        file_process: *wal.FileReadProcess,
        offset: u64,
        buf: []u8,
    },
    /// A WAL flush: the writer whose queue its completion advances (§D2).
    wal_flush: struct {
        writer: *wal.WalWriteFile,
    },

    /// A placeholder that never reaches the ring; used by tests and by slots
    /// that are allocated but not yet armed.
    idle: void,
};

/// One `Slots` table per ring. Thin wrapper so call sites never deal with the
/// `zigring.Slots` initialization rules directly.
pub const RingSlots = struct {
    const Self = @This();

    slots: zigring.Slots(TaskCtx),

    /// Allocates a table of `capacity` slots. `capacity` must be a power of two
    /// in `[min_capacity, max_capacity]`.
    pub fn init(self: *Self, allocator: std.mem.Allocator, capacity: u64) !void {
        if (capacity < min_capacity or capacity > max_capacity or
            !std.math.isPowerOfTwo(capacity))
        {
            return error.InvalidSlotsCapacity;
        }
        try zigring.Slots(TaskCtx).init(&self.slots, allocator, capacity, 0);
        return;
    }

    pub fn deinit(self: *Self) void {
        self.slots.deinit();
    }

    /// Registers a context and returns the `taskIdx` to arm the SQE with.
    pub fn add(self: *Self, ctx: TaskCtx) !u64 {
        return self.slots.add(ctx);
    }

    /// The context recorded for `task_idx`, or null when it is not a tracked
    /// operation (a reserved control index, or an already-retired slot).
    pub fn get(self: *Self, task_idx: u64) ?TaskCtx {
        return self.slots.get(task_idx);
    }

    /// Retires the slot. Safe to call on an already-free index; that is the
    /// behaviour of `zigring.Slots.del` and the reason CQE handlers stay
    /// idempotent.
    pub fn del(self: *Self, task_idx: u64) void {
        self.slots.del(task_idx);
    }
};

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "capacity validation" {
    var slots: RingSlots = undefined;
    try slots.init(std.testing.allocator, 4096);
    slots.deinit();

    try std.testing.expectError(error.InvalidSlotsCapacity, slots.init(std.testing.allocator, 1024));
    try std.testing.expectError(error.InvalidSlotsCapacity, slots.init(std.testing.allocator, 8192));
    try std.testing.expectError(error.InvalidSlotsCapacity, slots.init(std.testing.allocator, 4097));
}

test "add/get/del round-trip and index reuse" {
    var slots: RingSlots = undefined;
    try slots.init(std.testing.allocator, 4096);
    defer slots.deinit();

    const a = try slots.add(.{ .recv = .{ .fd = 7 } });
    const b = try slots.add(.{ .recv = .{ .fd = 9 } });
    try expect(a != b);

    try expectEqual(@as(std.posix.fd_t, 7), slots.get(a).?.recv.fd);
    try expectEqual(@as(std.posix.fd_t, 9), slots.get(b).?.recv.fd);

    slots.del(a);
    try expect(slots.get(a) == null);

    // The freed index comes back from the free-list.
    const c = try slots.add(.{ .close = .{ .fd = 11 } });
    try expectEqual(a, c);
    try expectEqual(@as(std.posix.fd_t, 11), slots.get(c).?.close.fd);
}

test "reserved control indices never resolve to a slot" {
    var slots: RingSlots = undefined;
    try slots.init(std.testing.allocator, 4096);
    defer slots.deinit();

    // Seed every slot so the whole index space is occupied.
    const taken = try std.testing.allocator.alloc(u64, min_capacity);
    defer std.testing.allocator.free(taken);
    for (taken) |*t| t.* = try slots.add(.idle);

    for (taken) |idx| try expect(idx < max_capacity);

    // Reserved indices are far outside the hand-out range and have no context.
    for (messages.reserved_task_indices) |reserved| {
        try expect(reserved >= max_capacity);
        try expect(slots.get(reserved) == null);
    }
}

test "wal contexts round-trip through the slot table" {
    var slots: RingSlots = undefined;
    try slots.init(std.testing.allocator, 4096);
    defer slots.deinit();

    // Both variants are plain data: a pointer plus scalars, no destructor.
    var writer: wal.WalWriteFile = undefined;
    var process: wal.FileReadProcess = undefined;
    var buf: [512]u8 = undefined;

    const flush = try slots.add(.{ .wal_flush = .{ .writer = &writer } });
    const read = try slots.add(.{ .file_read = .{
        .file_process = &process,
        .offset = 4096,
        .buf = &buf,
    } });

    try expectEqual(@as(*wal.WalWriteFile, &writer), slots.get(flush).?.wal_flush.writer);

    const ctx = slots.get(read).?.file_read;
    try expectEqual(@as(*wal.FileReadProcess, &process), ctx.file_process);
    try expectEqual(@as(u64, 4096), ctx.offset);
    try expectEqual(@as(usize, 512), ctx.buf.len);
    try expect(@intFromPtr(ctx.buf.ptr) == @intFromPtr(&buf));

    slots.del(flush);
    slots.del(read);
    try expect(slots.get(flush) == null);
    try expect(slots.get(read) == null);
}

test "the switch predicate's contexts round-trip through the slot table" {
    var slots: RingSlots = undefined;
    try slots.init(std.testing.allocator, 4096);
    defer slots.deinit();

    // All three are plain data: the link they name plus its epoch, nothing else.
    const pulse = try slots.add(.{ .pulse = .{ .host_idx = 1, .epoch = 7 } });
    const timeout = try slots.add(.{ .predicate_timeout = .{ .host_idx = 1, .epoch = 7 } });
    const keepalive = try slots.add(.{ .keepalive_tick = .{ .host_idx = 1, .epoch = 7 } });

    try expectEqual(@as(u8, 1), slots.get(pulse).?.pulse.host_idx);
    try expectEqual(@as(u32, 7), slots.get(timeout).?.predicate_timeout.epoch);
    try expectEqual(@as(u32, 7), slots.get(keepalive).?.keepalive_tick.epoch);

    slots.del(pulse);
    slots.del(timeout);
    slots.del(keepalive);
    try expect(slots.get(pulse) == null);
    try expect(slots.get(timeout) == null);
    try expect(slots.get(keepalive) == null);
}

test "del on a reserved or already-freed index is a no-op" {
    var slots: RingSlots = undefined;
    try slots.init(std.testing.allocator, 4096);
    defer slots.deinit();

    for (messages.reserved_task_indices) |reserved| slots.del(reserved);
    const a = try slots.add(.idle);
    slots.del(a);
    slots.del(a);
    slots.del(a + 100_000);

    // The table is still usable after the spurious deletes.
    const b = try slots.add(.idle);
    try expectEqual(a, b);
}
