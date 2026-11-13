//! Cross-thread task payloads.
//!
//! A `CrossTask` travels inside a `CrossTaskSlots` slot: the sender acquires a
//! slot, writes the union there, and posts `MSG_RING` with the reserved
//! `messages.CrossTaskMessageIdx` as the `taskIdx` and the slot index as the
//! `msg_result`. The receiver sees that CQE on its own ring, reads the slot and
//! releases it.
//!
//! Not every piece of cross-thread traffic needs a slot: tiny control
//! notifications (init acknowledgements, "I have drained" reports, shutdown
//! demands that fit in a single bit) travel as a reserved `taskIdx` plus a
//! one-word `msg_result`. Slots are reserved for payloads that do not fit in
//! the two `u64` words a `MSG_RING` CQE carries, which in the skeleton means
//! the server-socket descriptor distribution.

const std = @import("std");
const posix = std.posix;
const messages = @import("messages.zig");
const index_inbox = @import("index_inbox.zig");

/// Kept as the neutral, zero-information payload so tests and unused slots have
/// something valid to hold. `zigring.Slots` stores values by copy and never
/// runs a destructor, so every variant must be plain data.
pub const CrossTaskPlaceholder = struct {};

/// CrossTask descriptor for tasks that travel between different OS threads.
pub const CrossTask = union(enum) {
    /// Process -> front/elephant ring: begin shutting down. `hard` escalates
    /// from "finish the current operation, then drain" to "drop everything
    /// now"; the skeleton distinguishes them in the front/elephant handlers.
    ShutdownDemand: struct {
        hard: bool,
    },

    /// Front -> index: stop accepting new sessions and drain. The normal path
    /// is the index inbox (`index.FrontMessage.shutdown_soft`); this slot-borne
    /// variant exists for a front that no longer trusts the inbox.
    SoftShutdown: struct {
        ring_idx: u16,
    },

    /// Process -> worker: the listening socket. The skeleton sends it in the
    /// `res` word of the `START_WORK` broadcast instead of through a slot; the
    /// variant stays part of the vocabulary for senders that need a slot.
    ServerSocket: struct {
        fd: posix.fd_t,
    },

    /// Index -> its front: "I have drained and am exiting". The front collects
    /// these to satisfy the shutdown deadline.
    IndexDrained: struct {
        ring_idx: u16,
    },

    /// Index -> elephant: create the new WAL file.
    SnapshotCreate: struct {
        job: usize,
    },

    /// Index -> elephant: dump the clone and commit the registry line.
    SnapshotDump: struct {
        job: usize,
    },

    /// Index -> elephant: unwind cleanup.
    SnapshotCleanup: struct {
        job: usize,
    },

    /// Index -> elephant: final close of the old fd.
    SnapshotClose: struct {
        job: usize,
    },

    /// Elephant -> index: the create reply, the fd alone.
    SnapshotFd: struct {
        fd: posix.fd_t,
    },

    /// Elephant -> index: the create failed.
    SnapshotCreateFailed: struct {},

    /// Elephant -> index: the dump and its registry line are committed.
    SnapshotDumped: struct {},

    /// Elephant -> index: the dump failed.
    SnapshotDumpFailed: struct {},

    /// Elephant -> index: the registry rewrite failed.
    SnapshotAbandon: struct {},

    /// Elephant -> index: terminal reply; the in-flight flag clears on it.
    SnapshotDone: struct {},
};

/// State of one snapshot slot: set by the index at the tick (`in_flight`) and
/// when an unwind dispatches cleanup (`rollback`), cleared by the releasing
/// elephant before `release(k)`.
pub const SnapshotSlotStatus = enum(u8) { idle, in_flight, rollback };

/// The snapshot slot payload: the procedure's status and its job handle.
pub const SnapshotSlot = struct {
    status: SnapshotSlotStatus,
    job: usize,
};

comptime {
    // Slot values are stored by copy and never destroyed, so a `CrossTask` may
    // not own heap memory.
    const union_info = @typeInfo(CrossTask).@"union";
    for (union_info.field_names, union_info.field_types) |field_name, field_type| {
        switch (@typeInfo(field_type)) {
            .void, .int, .bool, .@"struct", .@"enum" => {},
            else => @compileError("CrossTask variant '" ++ field_name ++
                "' must be plain data, found " ++ @typeName(field_type)),
        }
    }
    std.debug.assert(@sizeOf(CrossTask) <= 16);
    std.debug.assert(@sizeOf(SnapshotSlot) <= 16);
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "variants round-trip through a slot" {
    var slots: @import("cross_task_slots.zig").CrossTaskSlots = undefined;
    try slots.init(std.testing.allocator, 6);
    defer slots.deinit();

    const a = try slots.acquire();
    slots.at(a).* = .{ .ServerSocket = .{ .fd = 42 } };
    try expectEqual(@as(posix.fd_t, 42), slots.at(a).ServerSocket.fd);

    const b = try slots.acquire();
    slots.at(b).* = .{ .ShutdownDemand = .{ .hard = true } };
    try expect(slots.at(b).ShutdownDemand.hard);

    const c = try slots.acquire();
    slots.at(c).* = .{ .IndexDrained = .{ .ring_idx = 7 } };
    try expectEqual(@as(u16, 7), slots.at(c).IndexDrained.ring_idx);

    const d = try slots.acquire();
    slots.at(d).* = .{ .SoftShutdown = .{ .ring_idx = 2 } };
    try expectEqual(@as(u16, 2), slots.at(d).SoftShutdown.ring_idx);

    // One snapshot request and one reply per direction.
    const e = try slots.acquire();
    slots.at(e).* = .{ .SnapshotCreate = .{ .job = @intFromPtr(&slots) } };
    try expectEqual(@as(usize, @intFromPtr(&slots)), slots.at(e).SnapshotCreate.job);

    const f = try slots.acquire();
    slots.at(f).* = .{ .SnapshotFd = .{ .fd = 9 } };
    try expectEqual(@as(posix.fd_t, 9), slots.at(f).SnapshotFd.fd);

    try std.testing.expectError(error.CrossTaskFull, slots.acquire());
}

test "the snapshot requests carry a job and the replies carry status alone" {
    var slots: @import("cross_task_slots.zig").CrossTaskSlots = undefined;
    try slots.init(std.testing.allocator, 16);
    defer slots.deinit();

    const requests = [_]CrossTask{
        .{ .SnapshotCreate = .{ .job = 1 } },
        .{ .SnapshotDump = .{ .job = 2 } },
        .{ .SnapshotCleanup = .{ .job = 3 } },
        .{ .SnapshotClose = .{ .job = 4 } },
    };
    for (requests, 0..) |request, i| {
        const idx = try slots.acquire();
        slots.at(idx).* = request;
        const job = switch (slots.at(idx).*) {
            .SnapshotCreate => |p| p.job,
            .SnapshotDump => |p| p.job,
            .SnapshotCleanup => |p| p.job,
            .SnapshotClose => |p| p.job,
            else => unreachable,
        };
        try expectEqual(std.meta.activeTag(request), std.meta.activeTag(slots.at(idx).*));
        try expectEqual(i + 1, job);
    }

    const replies = [_]CrossTask{
        .{ .SnapshotCreateFailed = .{} },
        .{ .SnapshotDumped = .{} },
        .{ .SnapshotDumpFailed = .{} },
        .{ .SnapshotAbandon = .{} },
        .{ .SnapshotDone = .{} },
    };
    for (replies) |reply| {
        const idx = try slots.acquire();
        slots.at(idx).* = reply;
        // Stored by copy: the slot holds the variant's tag, not a destructor.
        try expectEqual(std.meta.activeTag(reply), std.meta.activeTag(slots.at(idx).*));
    }
}

test "the snapshot slot payload is two words" {
    try expect(@sizeOf(SnapshotSlot) <= 16);
    const slot = SnapshotSlot{ .status = .in_flight, .job = 42 };
    try expectEqual(SnapshotSlotStatus.in_flight, slot.status);
    try expectEqual(@as(usize, 42), slot.job);
    try expectEqual(@as(usize, 1), @backingInt(SnapshotSlotStatus.in_flight));
    try expectEqual(@as(usize, 2), @backingInt(SnapshotSlotStatus.rollback));
    try expectEqual(@as(usize, 0), @backingInt(SnapshotSlotStatus.idle));
}

test "control codes stay out of the wakeup space" {
    // Control codes must not collide with the inbox protocol's payload-less
    // wakeup base.
    try expect(messages.ShutdownTickMsgResult < index_inbox.NoPayloadMsgResultBase);
    try expectEqual(@as(u32, index_inbox.NoPayloadMsgResultBase + 1), index_inbox.IndexWakeupMsgResult);
}
