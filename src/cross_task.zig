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
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "variants round-trip through a slot" {
    var slots: @import("cross_task_slots.zig").CrossTaskSlots = undefined;
    try slots.init(std.testing.allocator, 4);
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

    try std.testing.expectError(error.CrossTaskFull, slots.acquire());
}

test "control codes stay out of the wakeup space" {
    // Control codes must not collide with the inbox protocol's payload-less
    // wakeup base.
    try expect(messages.ShutdownTickMsgResult < index_inbox.NoPayloadMsgResultBase);
    try expectEqual(@as(u32, index_inbox.NoPayloadMsgResultBase + 1), index_inbox.IndexWakeupMsgResult);
}
