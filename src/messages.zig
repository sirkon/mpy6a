//! Shared vocabulary of the shard skeleton: the reserved `taskIdx` values that
//! threads use to talk to each other through io_uring, the payload types that
//! travel across thread boundaries, and the comptime proofs that none of the
//! reserved values can collide with the ones the `Slots` allocators hand out.
//!
//! Nothing here does any work. It only fixes the numbers and the types that
//! `front.zig`, `index.zig`, `elephant.zig`, `lifetime.zig` and `main.zig`
//! agree on, so the handshake and the shutdown choreography can be read as one
//! protocol.
//!
//! Every cross-thread message is a `MSG_RING` into the receiver's ring. The
//! `taskIdx` of the resulting CQE says what the message *is*; the `res` field
//! carries at most one small word of payload:
//!
//! | taskIdx                 | `res`                      | sent by            |
//! |-------------------------|----------------------------|--------------------|
//! | `InitializedIdx`        | sender's `ring_idx`        | every worker       |
//! | `StartWorkIdx`          | the listening socket fd    | the init thread    |
//! | `CrossTaskMessageIdx`   | `CrossTaskSlots` index     | anyone             |
//! | `IndexWakeupTaskIdx`    | wakeup code (no payload)   | fronts -> indexes  |
//! | `ShutdownDemandIdx`     | unused                     | process -> workers |
//! | `ShutdownDoneIdx`       | sender's `ring_idx`        | fronts, elephants  |
//! | `ShutdownTickIdx`       | tick number                | the shutdown timer |
//! | `InitTimeoutIdx`        | n/a                        | the init deadline  |
//! | `IndexDrainedIdx`       | index's `ring_idx`         | index -> its front |
//!
//! Payloads that do not fit into the two words a `MSG_RING` CQE carries go
//! through a `CrossTaskSlots` slot and arrive as `CrossTaskMessageIdx`; the
//! receiver reads the slot and releases it. The startup launch and the
//! shutdown reports fit in `res`, so they travel without a slot.

const std = @import("std");
const zigring = @import("zigring");
const index_inbox = @import("index_inbox.zig");

/// taskIdx of the init-ring message reporting "this thread finished
/// initializing". `res` is the sender's `ring_idx`, the sender's slot in every
/// per-thread shared array.
pub const InitializedIdx: u64 = std.math.maxInt(u64) - 1;

/// taskIdx of the `START_WORK` broadcast the init thread sends into every
/// worker ring once all `InitializedIdx` reports are in. `res` is the listening
/// socket descriptor. The message is the single launch barrier of the process:
/// io_uring preserves the order inside one ring, so a worker that sees it has
/// already consumed every earlier message of its own ring.
pub const StartWorkIdx: u64 = std.math.maxInt(u64) - 4;

/// A CQE whose `res` is an index into `CrossTaskSlots`; the payload is read
/// from the slot. Re-exported from `index_inbox.zig`, which owns the value for
/// the sleep/wakeup protocol.
pub const CrossTaskMessageIdx: u64 = index_inbox.CrossTaskMessageIdx;

/// A payload-less wakeup CQE for an index that announced sleep. Re-exported
/// from `index_inbox.zig`.
pub const IndexWakeupTaskIdx: u64 = index_inbox.IndexWakeupTaskIdx;

/// Process -> worker ring: stop what you are doing and drain. Payload-free:
/// the first demand is the whole signal, and a repeated one is ignored.
pub const ShutdownDemandIdx: u64 = std.math.maxInt(u64) - 5;

/// Worker -> init-ring: "I have drained and am about to exit". `res` is the
/// sender's `ring_idx`.
pub const ShutdownDoneIdx: u64 = std.math.maxInt(u64) - 6;

/// Init-ring and front rings: the periodic tick that polices the startup and
/// shutdown deadlines. `res` is the tick number.
pub const ShutdownTickIdx: u64 = std.math.maxInt(u64) - 8;

/// Init-ring: the startup handshake deadline expired.
pub const InitTimeoutIdx: u64 = std.math.maxInt(u64) - 9;

/// Index -> its parent front: "I have drained and stopped". `res` is the index's
/// own `ring_idx`, so the front can translate it into its child slot.
pub const IndexDrainedIdx: u64 = std.math.maxInt(u64) - 10;

/// Every reserved `taskIdx`, in one place so the comptime block below can
/// prove they are pairwise distinct and out of reach of `Slots`.
pub const reserved_task_indices = [_]u64{
    InitializedIdx,
    StartWorkIdx,
    CrossTaskMessageIdx,
    IndexWakeupTaskIdx,
    ShutdownDemandIdx,
    ShutdownDoneIdx,
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

/// `msg_result` base of the payload-less control messages that travel without
/// a `CrossTaskSlots` slot. Kept strictly below
/// `index_inbox.NoPayloadMsgResultBase` so a control CQE can never be confused
/// with an index wakeup, and strictly above zero so it can never be mistaken
/// for an errno (those arrive as negative `res` values).
pub const ControlMsgResultBase: u32 = 0x4000_0000;

/// `msg_result` of a `ShutdownTickIdx`. The other control messages carry their
/// payload in `res` (a `ring_idx`, a slot index, the socket fd) and their
/// `taskIdx` alone identifies them.
pub const ShutdownTickMsgResult: u32 = ControlMsgResultBase + 3;

comptime {
    // Control codes must stay below the inbox protocol's payload-less base and
    // stay positive so that a completion carrying one is never read as an
    // errno.
    std.debug.assert(ShutdownTickMsgResult > 0);
    std.debug.assert(ShutdownTickMsgResult < index_inbox.NoPayloadMsgResultBase);
}

/// Whether `task_idx` belongs to the reserved control range. Definitionally:
/// everything at or above `2^63` (docs/startup-en-reworked.md appendix).
pub inline fn isReserved(task_idx: u64) bool {
    return task_idx >= (1 << 63);
}

test "reserved indices are distinct and out of the slots range" {
    // The comptime block already proves this; the test keeps the property
    // visible from `zig build test` as well.
    for (reserved_task_indices, 0..) |a, i| {
        try std.testing.expect(a != zigring.fireAndForgetTaskIdx);
        for (reserved_task_indices[i + 1 ..]) |b| try std.testing.expect(a != b);
        try std.testing.expect(a >= (1 << 63));
    }
    try std.testing.expect(max_slot_capacity - 1 < InitTimeoutIdx);
}

test "the startup and shutdown indices are reserved" {
    try std.testing.expect(isReserved(InitializedIdx));
    try std.testing.expect(isReserved(StartWorkIdx));
    try std.testing.expect(isReserved(ShutdownDemandIdx));
    try std.testing.expect(isReserved(ShutdownDoneIdx));
    try std.testing.expect(isReserved(ShutdownTickIdx));
    // A slotter index never reaches the reserved range.
    try std.testing.expect(!isReserved(0));
    try std.testing.expect(!isReserved(max_slot_capacity - 1));
}
