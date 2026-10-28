//! Client replies.
//!
//! The mirror codec of stage 5 (`wire.zig`) covers host-to-host frames only;
//! how a reply is framed for a client has no design yet, so every answer the
//! index or the front writes is one text line. Both sides build it here, so a
//! complaint the front answers on the index' behalf (2.3) and the
//! unknown-session answer the index writes itself on the non-fatal pole (2.5)
//! speak the same language.

const std = @import("std");
const cross_task = @import("cross_task.zig");

/// Upper bound of one encoded reply, the size of a writer's buffer.
pub const max_len = 64;

/// What a reply says.
pub const Kind = enum {
    /// The mutation is in the log; the session id follows, so a create returns
    /// the id its session was opened with (2.5).
    ack,
    /// The flush failed: the operation is not in the log.
    nack,
    /// The session was retired by the client's own `Close` (2.5 step 6).
    closed,
    /// The client pushed a mutation before the previous one resolved (2.5).
    protocol_violation,
    /// The op named a session the index does not know (2.5).
    unknown_session,
};

/// Encodes one reply into `buf` and returns the bytes to write. A buffer too
/// small for the text yields an empty slice instead of a half line.
pub fn encode(kind: Kind, session_id: u128, buf: []u8) []const u8 {
    const out = switch (kind) {
        .ack => std.fmt.bufPrint(buf, "ack {x:0>32}\n", .{session_id}),
        .nack => std.fmt.bufPrint(buf, "nack {x:0>32}\n", .{session_id}),
        .closed => std.fmt.bufPrint(buf, "closed {x:0>32}\n", .{session_id}),
        .protocol_violation => std.fmt.bufPrint(buf, "protocol violation\n", .{}),
        .unknown_session => std.fmt.bufPrint(buf, "unknown session {x:0>32}\n", .{session_id}),
    };
    return out catch buf[0..0];
}

/// The answer a validated complaint of `code` gets (2.3): the front writes it
/// on the index' behalf, so the angry texts of 2.5 stay the same on both
/// poles of the unknown-session reaction.
pub fn forComplaint(code: cross_task.Code, session_id: u128, buf: []u8) []const u8 {
    return encode(switch (code) {
        .protocol_violation => .protocol_violation,
        .closed => .closed,
        .unknown_session => .unknown_session,
    }, session_id, buf);
}

test "every reply fits the buffer and names the session" {
    var buf: [max_len]u8 = undefined;
    const id: u128 = 0x0102_0304_0506_0708_090a_0b0c_0d0e_0f10;

    try std.testing.expectEqualStrings(
        "ack 0102030405060708090a0b0c0d0e0f10\n",
        encode(.ack, id, &buf),
    );
    try std.testing.expectEqualStrings(
        "unknown session 0102030405060708090a0b0c0d0e0f10\n",
        encode(.unknown_session, id, &buf),
    );
    try std.testing.expectEqualStrings("protocol violation\n", encode(.protocol_violation, id, &buf));

    // The complaint path reuses the same texts, so the two poles of 2.5 agree.
    try std.testing.expectEqualStrings(
        encode(.unknown_session, id, &buf),
        forComplaint(.unknown_session, id, &buf),
    );
    try std.testing.expectEqualStrings(
        encode(.closed, id, &buf),
        forComplaint(.closed, id, &buf),
    );
}

test "a buffer too small yields no partial line" {
    var tiny: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), encode(.ack, 1, &tiny).len);
}
