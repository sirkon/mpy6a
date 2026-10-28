//! The frame of the mirror transport, designs/CONSENSUS-PLAN.md 2.6 and
//! docs/consensus-network-protocol.md.
//!
//! The greeting of 2.3 opens a connection and is exchanged once. Everything
//! after it is a frame:
//!
//! ```text
//! seq_id: u16 | host_idx: u8 | host_state: u128 | tag: u8 | payload_len: u32 | payload
//! ```
//!
//! `seq_id` is the connection-bound ring number, bumped by one per send: the
//! first two bytes carry it, so a reader finds the order without parsing the
//! payload. The receiver repairs the rare reorder through
//! `zigring.ReorderBuffer`; `absoluteSeq` maps the wrapping number to the
//! absolute sequence index the buffer wants.
//!
//! `(host_idx, host_state)` is the vector clock pair: each frame reports one
//! host's state and successive frames loop over the hosts, so the clocks
//! piggyback on the regular traffic (stage 6, the background synchronization).
//!
//! `payload_len` makes every frame self-delimiting, so a frame of a command
//! this build does not serve is skipped without knowing its layout.
//!
//! The vocabulary is the `Operation oneof` of the transport document: the
//! mutations of a session, the mirror liveness pulse, the answers of a
//! consensus round, and the stage-6 commands — `Isolate`, `Compensate`,
//! `Restart`, `RestartIn`, the log and snapshot requests and their answers —
//! plus the stage-7 isolation vote (`IsolateProposal` and its answer).
//! The data blobs of the log and snapshot chunks are bounded by `max_data`, the
//! same cap the mutations use. The `Create` compensator bytes are not carried
//! yet, the compensation process that fills them not storing any data, and the
//! data of the local mutations is still an empty blob, the sessions not storing
//! any data yet.

const std = @import("std");
const state = @import("state.zig");

/// Bytes of a greeting: the magic, the host index and the index service.
pub const greeting_len = 2 + 1 + 2;

/// The two bytes that open a greeting; a stream that does not start with them
/// is not a mirror connection.
pub const greeting_magic: u16 = 0x364d; // "M6"

/// Bytes of the frame header in front of the payload: `seq_id`, the vector
/// clock pair, the op tag and the payload length.
pub const header_len = 2 + 1 + 16 + 1 + 4;

/// The largest data blob one operation carries. The receive buffers and the
/// reorder window are sized after the whole frame, so the cap keeps both
/// bounded; it grows together with the WAL payloads.
pub const max_data = 512;

/// The header of the longest data-bearing payload: a host index, an index, the
/// final flag and the blob length.
pub const chunk_header_len = 1 + 16 + 1 + 4;

/// The largest payload: a mutation, its session id and the longest data blob,
/// or the longest log or snapshot chunk, whichever header is wider.
pub const max_payload = @max(16 + 4 + max_data, chunk_header_len + max_data);

/// The largest frame this codec accepts. A longer one is a peer this build
/// cannot read; the bounded receive could never complete it anyway.
pub const max_frame_len = header_len + max_payload;

/// The greeting of a freshly established connection (2.3).
pub const Greeting = struct {
    /// The host that dialled.
    host_idx: u8,
    /// The index service the socket serves.
    index_idx: u16,
};

/// The op tag of the transport vocabulary. The numbering is this codec's own;
/// the values of the mutations follow `state.Op` for readability only.
pub const Tag = enum(u8) {
    create = 0,
    append = 1,
    overwrite = 2,
    repeat = 3,
    close = 4,
    pulse = 5,
    /// Stage 6: run the first session of a host's list at the replay, provided
    /// the local state of that host reached the carried one.
    restart = 6,
    /// Stage 6: send a session to the replay after a delay.
    restart_in = 7,
    ack = 10,
    nack = 11,
    /// Stage 6: the isolation of a host that stayed silent too long.
    isolate = 20,
    /// Stage 6: the takeover of the sessions of an isolated host.
    compensate = 21,
    /// Stage 7: the isolation vote of a host before the decision is taken.
    isolate_proposal = 27,
    /// Stage 6: the background vector clock synchronization.
    request_log = 22,
    requested_log = 23,
    requested_log_not_available = 24,
    request_snapshot = 25,
    requested_snapshot = 26,
};

/// A mutation that carries fresh data: `Create`, `Append` and `Overwrite` share
/// the layout.
pub const Data = struct {
    session_id: u128,
    data: []const u8,
};

/// `Repeat`: the session goes to replay in `repeat_in` seconds.
pub const Repeat = struct {
    session_id: u128,
    repeat_in: u32,
};

/// `RestartIn`: the session goes to replay in `seconds` seconds.
pub const RestartIn = struct {
    session_id: u128,
    seconds: u16,
};

/// `Isolate`: the exact logical boundary of a lost host's log
/// (docs/consensus.md). The packed state names the host, the epoch it is to be
/// fenced in and the index the isolation is decided at.
pub const Isolate = struct {
    host_state: u128,
};

/// `Compensate`: take `count` sessions of `host_idx` off its isolated FIFO.
pub const Compensate = struct {
    host_idx: u8,
    count: u16,
};

/// `RequestLog`: ask for the log of `host_idx` after `index`.
pub const LogRequest = struct {
    host_idx: u8,
    index: u128,
};

/// `RequestedLog`: one chunk of that log.
pub const RequestedLog = struct {
    host_idx: u8,
    index: u128,
    final: bool,
    data: []const u8,
};

/// `RequestedLogNotAvailable`: the answer to a log request this host cannot
/// serve.
pub const LogUnavailable = struct {
    pub const Code = enum(u8) {
        /// The requested position is older than anything this host keeps.
        out_of_date,
        /// The host failed to read its own log.
        internal_error,
    };

    host_idx: u8,
    index: u128,
    code: Code,
};

/// `RequestSnapshot`: ask for the newest snapshot of `host_idx`.
pub const SnapshotRequest = struct {
    host_idx: u8,
};

/// `RequestedSnapshot`: one chunk of that snapshot.
pub const RequestedSnapshot = struct {
    host_idx: u8,
    index: u128,
    final: bool,
    data: []const u8,
};

/// The operation an `Ack` or a `Nack` answers.
pub const Acknowledged = union(enum) {
    create: u128,
    append: u128,
    overwrite: u128,
    repeat: u128,
    close: u128,
    restart: u128,
    restart_in: RestartIn,
    isolate: u128,
    /// Stage 7: the answer of one host to an isolation vote.
    isolate_proposal: u128,
    compensate: Compensate,
};

/// An answer of a mirror: the epoch the responder works in and the operation
/// it decided on (2.6).
pub const Answer = struct {
    /// The responder's own epoch: the `epoch_id` slice of its state, widened to
    /// the `u128` of the transport document. An acknowledgement from a host the
    /// cluster decided is gone is discounted by the epoch barrier of 2.5.
    epoch: u128,
    op: Acknowledged,
};

/// The op vocabulary: a mutation, the answer to one, the mirror liveness pulse,
/// or a stage-6 command of the background synchronization and the isolation.
pub const Operation = union(enum) {
    create: Data,
    append: Data,
    overwrite: Data,
    repeat: Repeat,
    close: u128,
    pulse: void,
    restart: u128,
    restart_in: RestartIn,
    ack: Answer,
    nack: Answer,
    isolate: Isolate,
    isolate_proposal: Isolate,
    compensate: Compensate,
    request_log: LogRequest,
    requested_log: RequestedLog,
    requested_log_not_available: LogUnavailable,
    request_snapshot: SnapshotRequest,
    requested_snapshot: RequestedSnapshot,
};

/// One frame of the mirror stream.
pub const Frame = struct {
    /// The ring number of the connection, bumped per send (2.6).
    seq_id: u16,
    /// The sender's host index, the `host_idx` half of the vector clock frame.
    host_idx: u8,
    /// The sender's index state, the `host_state` half of the vector clock
    /// frame. The epoch barrier of 2.5 step 4 reads its `epoch_id` slice.
    host_state: u128,
    op: Operation,
};

/// A decoded frame and the bytes it occupied: the decoder is handed a stream,
/// so the caller needs to know where the next frame starts.
pub const Decoded = struct {
    frame: Frame,
    len: usize,
};

/// The errors a malformed record produces. A mirror that sends one is a peer
/// this transport cannot talk to, so the connection is dropped.
pub const DecodeError = error{
    /// Fewer bytes than a record needs.
    Truncated,
    /// The greeting does not start with the magic.
    NotAGreeting,
    /// The op tag is not one this codec knows.
    UnknownTag,
    /// The payload does not match the layout of its tag.
    Malformed,
    /// The payload is longer than this build's frame cap.
    FrameTooLarge,
};

/// Writes the greeting of one connection.
pub fn encodeGreeting(buf: *[greeting_len]u8, greeting: Greeting) void {
    std.mem.writeInt(u16, buf[0..2], greeting_magic, .little);
    buf[2] = greeting.host_idx;
    std.mem.writeInt(u16, buf[3..5], greeting.index_idx, .little);
}

/// Reads a greeting back.
pub fn decodeGreeting(bytes: []const u8) DecodeError!Greeting {
    if (bytes.len < greeting_len) return error.Truncated;
    if (std.mem.readInt(u16, bytes[0..2], .little) != greeting_magic) return error.NotAGreeting;
    return .{
        .host_idx = bytes[2],
        .index_idx = std.mem.readInt(u16, bytes[3..5], .little),
    };
}

/// The tag of an operation.
pub fn tagOf(op: Operation) Tag {
    return switch (op) {
        .create => .create,
        .append => .append,
        .overwrite => .overwrite,
        .repeat => .repeat,
        .close => .close,
        .pulse => .pulse,
        .restart => .restart,
        .restart_in => .restart_in,
        .ack => .ack,
        .nack => .nack,
        .isolate => .isolate,
        .isolate_proposal => .isolate_proposal,
        .compensate => .compensate,
        .request_log => .request_log,
        .requested_log => .requested_log,
        .requested_log_not_available => .requested_log_not_available,
        .request_snapshot => .request_snapshot,
        .requested_snapshot => .requested_snapshot,
    };
}

/// The session an operation refers to, null for the session-less ones.
pub fn sessionId(op: Operation) ?u128 {
    return switch (op) {
        .create, .append, .overwrite => |data| data.session_id,
        .repeat => |repeat| repeat.session_id,
        .close => |session_id| session_id,
        .restart_in => |restart_in| restart_in.session_id,
        .pulse,
        .restart,
        .isolate,
        .isolate_proposal,
        .compensate,
        .request_log,
        .requested_log,
        .requested_log_not_available,
        .request_snapshot,
        .requested_snapshot,
        => null,
        .ack, .nack => |answer| acknowledgedSession(answer.op),
    };
}

/// The mutation of `op` as a request for `session_id`. The data is empty and
/// the repeat delay zero until the sessions and the replay keep them.
pub fn requestOf(op: state.Op, session_id: u128) Operation {
    const data = Data{ .session_id = session_id, .data = &.{} };
    return switch (op) {
        .create => .{ .create = data },
        .append => .{ .append = data },
        .overwrite => .{ .overwrite = data },
        .repeat => .{ .repeat = .{ .session_id = session_id, .repeat_in = 0 } },
        .close => .{ .close = session_id },
    };
}

/// The answer an operation asks of its mirrors, null for the operations that do
/// not name a command.
pub fn acked(op: Operation) ?Acknowledged {
    return switch (op) {
        .create => |data| .{ .create = data.session_id },
        .append => |data| .{ .append = data.session_id },
        .overwrite => |data| .{ .overwrite = data.session_id },
        .repeat => |repeat| .{ .repeat = repeat.session_id },
        .close => |session_id| .{ .close = session_id },
        .restart => |min_state| .{ .restart = min_state },
        .restart_in => |restart_in| .{ .restart_in = restart_in },
        .isolate => |isolate| .{ .isolate = isolate.host_state },
        .isolate_proposal => |proposal| .{ .isolate_proposal = proposal.host_state },
        .compensate => |compensate| .{ .compensate = compensate },
        .pulse,
        .ack,
        .nack,
        .request_log,
        .requested_log,
        .requested_log_not_available,
        .request_snapshot,
        .requested_snapshot,
        => null,
    };
}

/// The tag of an answered operation.
pub fn acknowledgedTag(op: Acknowledged) Tag {
    return switch (op) {
        .create => .create,
        .append => .append,
        .overwrite => .overwrite,
        .repeat => .repeat,
        .close => .close,
        .restart => .restart,
        .restart_in => .restart_in,
        .isolate => .isolate,
        .isolate_proposal => .isolate_proposal,
        .compensate => .compensate,
    };
}

/// The session an answered operation names; the session-less commands carry
/// none.
pub fn acknowledgedSession(op: Acknowledged) ?u128 {
    return switch (op) {
        .create, .append, .overwrite, .repeat, .close => |session_id| session_id,
        .restart_in => |restart_in| restart_in.session_id,
        .restart, .isolate, .isolate_proposal, .compensate => null,
    };
}

/// The payload bytes of an operation.
pub fn payloadLen(op: Operation) usize {
    return switch (op) {
        .create, .append, .overwrite => |data| 16 + 4 + data.data.len,
        .repeat => 16 + 4,
        .close => 16,
        .pulse => 0,
        .restart => 16,
        .restart_in => 16 + 2,
        .ack, .nack => answer_len,
        .isolate => 16,
        .isolate_proposal => 16,
        .compensate => 1 + 2,
        .request_log => 1 + 16,
        .requested_log => |requested| chunk_header_len + requested.data.len,
        .requested_log_not_available => 1 + 16 + 1,
        .request_snapshot => 1,
        .requested_snapshot => |requested| chunk_header_len + requested.data.len,
    };
}

/// The payload of an answer: the epoch, the tag of the answered operation, the
/// session (or the packed host state of an `Isolate`) and a side word the
/// commands with more than one argument split between themselves: the delay of
/// `RestartIn`, the host index and the count of `Compensate`.
const answer_len = 16 + 1 + 16 + 4;

/// The whole frame length of an operation.
pub fn frameLen(op: Operation) usize {
    return header_len + payloadLen(op);
}

/// Writes one frame at the front of `buf`, which must hold `frameLen`.
pub fn encode(buf: []u8, frame: Frame) void {
    const payload_len = payloadLen(frame.op);
    std.debug.assert(buf.len >= header_len + payload_len);

    std.mem.writeInt(u16, buf[0..2], frame.seq_id, .little);
    buf[2] = frame.host_idx;
    std.mem.writeInt(u128, buf[3..19], frame.host_state, .little);
    buf[19] = @backingInt(tagOf(frame.op));
    std.mem.writeInt(u32, buf[20..24], @intCast(payload_len), .little);

    var at: usize = header_len;
    switch (frame.op) {
        .create, .append, .overwrite => |data| {
            std.mem.writeInt(u128, buf[at..][0..16], data.session_id, .little);
            at += 16;
            std.mem.writeInt(u32, buf[at..][0..4], @intCast(data.data.len), .little);
            at += 4;
            putBytes(buf, &at, data.data);
        },
        .repeat => |repeat| {
            std.mem.writeInt(u128, buf[at..][0..16], repeat.session_id, .little);
            at += 16;
            std.mem.writeInt(u32, buf[at..][0..4], repeat.repeat_in, .little);
            at += 4;
        },
        .close => |session_id| {
            std.mem.writeInt(u128, buf[at..][0..16], session_id, .little);
            at += 16;
        },
        .pulse => {},
        .restart => |min_state| {
            std.mem.writeInt(u128, buf[at..][0..16], min_state, .little);
            at += 16;
        },
        .restart_in => |restart_in| {
            std.mem.writeInt(u128, buf[at..][0..16], restart_in.session_id, .little);
            at += 16;
            std.mem.writeInt(u16, buf[at..][0..2], restart_in.seconds, .little);
            at += 2;
        },
        .ack, .nack => |answer| {
            std.mem.writeInt(u128, buf[at..][0..16], answer.epoch, .little);
            at += 16;
            buf[at] = @backingInt(acknowledgedTag(answer.op));
            at += 1;
            std.mem.writeInt(u128, buf[at..][0..16], answerValue(answer.op), .little);
            at += 16;
            std.mem.writeInt(u32, buf[at..][0..4], answerAux(answer.op), .little);
            at += 4;
        },
        .isolate, .isolate_proposal => |isolate| {
            std.mem.writeInt(u128, buf[at..][0..16], isolate.host_state, .little);
            at += 16;
        },
        .compensate => |compensate| {
            buf[at] = compensate.host_idx;
            at += 1;
            std.mem.writeInt(u16, buf[at..][0..2], compensate.count, .little);
            at += 2;
        },
        .request_log => |request| {
            buf[at] = request.host_idx;
            at += 1;
            std.mem.writeInt(u128, buf[at..][0..16], request.index, .little);
            at += 16;
        },
        .requested_log => |requested| {
            putChunk(buf, &at, .{
                .host_idx = requested.host_idx,
                .index = requested.index,
                .final = requested.final,
                .data = requested.data,
            });
        },
        .requested_log_not_available => |unavailable| {
            buf[at] = unavailable.host_idx;
            at += 1;
            std.mem.writeInt(u128, buf[at..][0..16], unavailable.index, .little);
            at += 16;
            buf[at] = @backingInt(unavailable.code);
            at += 1;
        },
        .request_snapshot => |request| {
            buf[at] = request.host_idx;
            at += 1;
        },
        .requested_snapshot => |requested| {
            putChunk(buf, &at, .{
                .host_idx = requested.host_idx,
                .index = requested.index,
                .final = requested.final,
                .data = requested.data,
            });
        },
    }

    std.debug.assert(at == header_len + payload_len);
}

/// Reads one frame back. `bytes` may hold more than the frame; `len` of the
/// result is the number of bytes the frame occupied.
pub fn decode(bytes: []const u8) DecodeError!Decoded {
    if (bytes.len < header_len) return error.Truncated;

    const tag = std.enums.fromInt(Tag, bytes[19]) orelse return error.UnknownTag;
    const payload_len = std.mem.readInt(u32, bytes[20..24], .little);
    if (payload_len > max_payload) return error.FrameTooLarge;

    const total = header_len + @as(usize, payload_len);
    if (bytes.len < total) return error.Truncated;

    return .{
        .frame = .{
            .seq_id = std.mem.readInt(u16, bytes[0..2], .little),
            .host_idx = bytes[2],
            .host_state = std.mem.readInt(u128, bytes[3..19], .little),
            .op = try decodeOp(tag, bytes[header_len..total]),
        },
        .len = total,
    };
}

/// The absolute sequence index of a frame, given the next one expected on the
/// connection. The ring number wraps at 2^16, the reorder window stays far
/// below half of it, so the window alone resolves the ambiguity.
pub fn absoluteSeq(expected: u64, ring: u16) u64 {
    const delta: u16 = ring -% @as(u16, @truncate(expected));
    if (delta == 0) return expected;
    // The far half of the ring is behind the expected one.
    if (delta < 0x8000) return expected +% delta;
    return expected -% @as(u64, 0 -% delta);
}

fn decodeOp(tag: Tag, body: []const u8) DecodeError!Operation {
    switch (tag) {
        .create => return .{ .create = try decodeData(body) },
        .append => return .{ .append = try decodeData(body) },
        .overwrite => return .{ .overwrite = try decodeData(body) },
        .repeat => {
            if (body.len != 16 + 4) return error.Malformed;
            return .{ .repeat = .{
                .session_id = std.mem.readInt(u128, body[0..16], .little),
                .repeat_in = std.mem.readInt(u32, body[16..20], .little),
            } };
        },
        .close => {
            if (body.len != 16) return error.Malformed;
            return .{ .close = std.mem.readInt(u128, body[0..16], .little) };
        },
        .pulse => {
            if (body.len != 0) return error.Malformed;
            return .{ .pulse = {} };
        },
        .restart => {
            if (body.len != 16) return error.Malformed;
            return .{ .restart = std.mem.readInt(u128, body[0..16], .little) };
        },
        .restart_in => {
            if (body.len != 16 + 2) return error.Malformed;
            return .{ .restart_in = .{
                .session_id = std.mem.readInt(u128, body[0..16], .little),
                .seconds = std.mem.readInt(u16, body[16..18], .little),
            } };
        },
        .ack, .nack => {
            if (body.len != answer_len) return error.Malformed;
            const answer = Answer{
                .epoch = std.mem.readInt(u128, body[0..16], .little),
                .op = try decodeAcknowledged(body[16..], body[33..37]),
            };
            return if (tag == .ack) .{ .ack = answer } else .{ .nack = answer };
        },
        .isolate => {
            if (body.len != 16) return error.Malformed;
            return .{ .isolate = .{ .host_state = std.mem.readInt(u128, body[0..16], .little) } };
        },
        .isolate_proposal => {
            if (body.len != 16) return error.Malformed;
            return .{ .isolate_proposal = .{ .host_state = std.mem.readInt(u128, body[0..16], .little) } };
        },
        .compensate => {
            if (body.len != 1 + 2) return error.Malformed;
            return .{ .compensate = .{
                .host_idx = body[0],
                .count = std.mem.readInt(u16, body[1..3], .little),
            } };
        },
        .request_log => {
            if (body.len != 1 + 16) return error.Malformed;
            return .{ .request_log = .{
                .host_idx = body[0],
                .index = std.mem.readInt(u128, body[1..17], .little),
            } };
        },
        .requested_log => {
            const chunk = try decodeChunk(body);
            return .{ .requested_log = .{
                .host_idx = chunk.host_idx,
                .index = chunk.index,
                .final = chunk.final,
                .data = chunk.data,
            } };
        },
        .requested_log_not_available => {
            if (body.len != 1 + 16 + 1) return error.Malformed;
            return .{ .requested_log_not_available = .{
                .host_idx = body[0],
                .index = std.mem.readInt(u128, body[1..17], .little),
                .code = std.enums.fromInt(LogUnavailable.Code, body[17]) orelse return error.Malformed,
            } };
        },
        .request_snapshot => {
            if (body.len != 1) return error.Malformed;
            return .{ .request_snapshot = .{ .host_idx = body[0] } };
        },
        .requested_snapshot => {
            const chunk = try decodeChunk(body);
            return .{ .requested_snapshot = .{
                .host_idx = chunk.host_idx,
                .index = chunk.index,
                .final = chunk.final,
                .data = chunk.data,
            } };
        },
    }
}

/// One chunk of a log or a snapshot: the host it belongs to, the position, the
/// final flag and the bytes.
const Chunk = struct {
    host_idx: u8,
    index: u128,
    final: bool,
    data: []const u8,
};

fn putChunk(buf: []u8, at: *usize, chunk: Chunk) void {
    buf[at.*] = chunk.host_idx;
    at.* += 1;
    std.mem.writeInt(u128, buf[at.*..][0..16], chunk.index, .little);
    at.* += 16;
    buf[at.*] = if (chunk.final) 1 else 0;
    at.* += 1;
    std.mem.writeInt(u32, buf[at.*..][0..4], @intCast(chunk.data.len), .little);
    at.* += 4;
    putBytes(buf, at, chunk.data);
}

fn decodeChunk(body: []const u8) DecodeError!Chunk {
    if (body.len < chunk_header_len) return error.Malformed;
    const data_len = std.mem.readInt(u32, body[18..22], .little);
    if (data_len != body.len - chunk_header_len) return error.Malformed;
    return .{
        .host_idx = body[0],
        .index = std.mem.readInt(u128, body[1..17], .little),
        .final = switch (body[17]) {
            0 => false,
            1 => true,
            else => return error.Malformed,
        },
        .data = body[chunk_header_len..],
    };
}

/// The value word of an answer: the session a mutation names, the packed host
/// state an `Isolate` names, the state a `Restart` names. A `Compensate` keeps
/// everything it carries in the side word.
fn answerValue(op: Acknowledged) u128 {
    return switch (op) {
        .create, .append, .overwrite, .repeat, .close => |session_id| session_id,
        .restart_in => |restart_in| restart_in.session_id,
        .restart => |min_state| min_state,
        .isolate => |host_state| host_state,
        .isolate_proposal => |host_state| host_state,
        .compensate => 0,
    };
}

/// The side word of an answer: the delay of a `RestartIn`, the host index and
/// the count of a `Compensate`, zero for the plain mutations.
fn answerAux(op: Acknowledged) u32 {
    return switch (op) {
        .restart_in => |restart_in| restart_in.seconds,
        .compensate => |compensate| @as(u32, compensate.host_idx) |
            (@as(u32, compensate.count) << 8),
        .create, .append, .overwrite, .repeat, .close, .restart, .isolate, .isolate_proposal => 0,
    };
}

fn decodeData(body: []const u8) DecodeError!Data {
    if (body.len < 16 + 4) return error.Malformed;
    const data_len = std.mem.readInt(u32, body[16..20], .little);
    if (data_len != body.len - 20) return error.Malformed;
    return .{
        .session_id = std.mem.readInt(u128, body[0..16], .little),
        .data = body[20..],
    };
}

fn decodeAcknowledged(body: []const u8, aux: []const u8) DecodeError!Acknowledged {
    const tag = std.enums.fromInt(Tag, body[0]) orelse return error.UnknownTag;
    const value = std.mem.readInt(u128, body[1..17], .little);
    const side = std.mem.readInt(u32, aux[0..4], .little);
    return switch (tag) {
        .create => .{ .create = value },
        .append => .{ .append = value },
        .overwrite => .{ .overwrite = value },
        .repeat => .{ .repeat = value },
        .close => .{ .close = value },
        .restart => .{ .restart = value },
        .restart_in => .{ .restart_in = .{
            .session_id = value,
            .seconds = @truncate(side),
        } },
        .isolate => .{ .isolate = value },
        .isolate_proposal => .{ .isolate_proposal = value },
        .compensate => .{ .compensate = .{
            .host_idx = @truncate(side),
            .count = @truncate(side >> 8),
        } },
        .pulse,
        .ack,
        .nack,
        .request_log,
        .requested_log,
        .requested_log_not_available,
        .request_snapshot,
        .requested_snapshot,
        => error.Malformed,
    };
}

/// The session mutation an operation carries, null for the commands that name
/// no session mutation: the replica log stores the mutations of a leader
/// (stage 7).
pub fn stateOp(op: Operation) ?state.Op {
    return switch (op) {
        .create => .create,
        .append => .append,
        .overwrite => .overwrite,
        .repeat => .repeat,
        .close => .close,
        else => null,
    };
}

fn putBytes(buf: []u8, at: *usize, bytes: []const u8) void {
    @memcpy(buf[at.*..][0..bytes.len], bytes);
    at.* += bytes.len;
}

test "a greeting round-trips" {
    var buf: [greeting_len]u8 = undefined;
    encodeGreeting(&buf, .{ .host_idx = 7, .index_idx = 513 });
    const greeting = try decodeGreeting(&buf);
    try std.testing.expectEqual(@as(u8, 7), greeting.host_idx);
    try std.testing.expectEqual(@as(u16, 513), greeting.index_idx);

    try std.testing.expectError(error.Truncated, decodeGreeting(buf[0 .. greeting_len - 1]));
    buf[0] ^= 0xff;
    try std.testing.expectError(error.NotAGreeting, decodeGreeting(&buf));
}

/// Encodes `frame` into `buf` and checks that it decodes back to the same
/// frame, occupying exactly the bytes the length functions promise.
fn roundTrip(buf: []u8, frame: Frame) !void {
    encode(buf, frame);
    const decoded = try decode(buf[0..frameLen(frame.op)]);
    try std.testing.expectEqual(frameLen(frame.op), decoded.len);
    try std.testing.expectEqual(frame.seq_id, decoded.frame.seq_id);
    try std.testing.expectEqual(frame.host_idx, decoded.frame.host_idx);
    try std.testing.expectEqual(frame.host_state, decoded.frame.host_state);
    try std.testing.expectEqual(tagOf(frame.op), tagOf(decoded.frame.op));
}

test "every data mutation round-trips with its payload" {
    var buf: [max_frame_len]u8 = undefined;
    const data = [_]u8{ 1, 2, 3, 0xfe, 0xff };
    const base = Frame{
        .seq_id = 0xfffe,
        .host_idx = 2,
        .host_state = (@as(u128, 3) << 120) | 0x1234,
        .op = .{ .append = .{ .session_id = (@as(u128, 1) << 104) | 9, .data = &data } },
    };
    try roundTrip(&buf, base);

    const decoded = try decode(&buf);
    try std.testing.expectEqualSlices(u8, &data, decoded.frame.op.append.data);
    try std.testing.expectEqual(base.op.append.session_id, decoded.frame.op.append.session_id);

    var created = base;
    created.op = .{ .create = .{ .session_id = 0xabc, .data = "hello" } };
    try roundTrip(&buf, created);
    try std.testing.expectEqualSlices(u8, "hello", (try decode(&buf)).frame.op.create.data);

    var overwritten = base;
    overwritten.op = .{ .overwrite = .{ .session_id = 0xabc, .data = &.{} } };
    try roundTrip(&buf, overwritten);
    try std.testing.expectEqual(@as(usize, 0), (try decode(&buf)).frame.op.overwrite.data.len);
}

test "the session-less and the short operations round-trip" {
    var buf: [max_frame_len]u8 = undefined;

    var frame = Frame{
        .seq_id = 1,
        .host_idx = 0,
        .host_state = 0,
        .op = .{ .repeat = .{ .session_id = 0xabc, .repeat_in = 90 } },
    };
    try roundTrip(&buf, frame);
    try std.testing.expectEqual(@as(u32, 90), (try decode(&buf)).frame.op.repeat.repeat_in);

    frame.op = .{ .close = 0xabc };
    try roundTrip(&buf, frame);
    try std.testing.expectEqual(@as(u128, 0xabc), (try decode(&buf)).frame.op.close);

    frame.op = .{ .pulse = {} };
    try roundTrip(&buf, frame);
    try std.testing.expectEqual(header_len, frameLen(frame.op));
}

test "an answer carries the epoch and the operation it decides on" {
    var buf: [max_frame_len]u8 = undefined;
    var frame = Frame{
        .seq_id = 3,
        .host_idx = 4,
        .host_state = (@as(u128, 7) << 104),
        .op = .{ .ack = .{ .epoch = 7, .op = .{ .append = 0xdead } } },
    };
    try roundTrip(&buf, frame);
    const answer = (try decode(&buf)).frame.op.ack;
    try std.testing.expectEqual(@as(u128, 7), answer.epoch);
    try std.testing.expectEqual(@as(u128, 0xdead), answer.op.append);

    frame.op = .{ .nack = .{ .epoch = 8, .op = .{ .close = 1 } } };
    try roundTrip(&buf, frame);
    try std.testing.expectEqual(@as(u128, 8), (try decode(&buf)).frame.op.nack.epoch);
}

test "an answer to a stage-6 command carries its arguments" {
    var buf: [max_frame_len]u8 = undefined;
    var frame = Frame{
        .seq_id = 4,
        .host_idx = 1,
        .host_state = 0,
        .op = .{ .ack = .{ .epoch = 9, .op = .{ .isolate = 0x1234 } } },
    };
    try roundTrip(&buf, frame);
    try std.testing.expectEqual(@as(u128, 0x1234), (try decode(&buf)).frame.op.ack.op.isolate);

    // The delay of a RestartIn and the host and count of a Compensate ride the
    // side word of the answer.
    frame.op = .{ .nack = .{ .epoch = 1, .op = .{ .restart_in = .{ .session_id = 5, .seconds = 40 } } } };
    try roundTrip(&buf, frame);
    const restarted = (try decode(&buf)).frame.op.nack.op.restart_in;
    try std.testing.expectEqual(@as(u128, 5), restarted.session_id);
    try std.testing.expectEqual(@as(u16, 40), restarted.seconds);

    frame.op = .{ .ack = .{ .epoch = 2, .op = .{ .compensate = .{ .host_idx = 2, .count = 300 } } } };
    try roundTrip(&buf, frame);
    const compensated = (try decode(&buf)).frame.op.ack.op.compensate;
    try std.testing.expectEqual(@as(u8, 2), compensated.host_idx);
    try std.testing.expectEqual(@as(u16, 300), compensated.count);

    frame.op = .{ .ack = .{ .epoch = 3, .op = .{ .restart = 0x99 } } };
    try roundTrip(&buf, frame);
    try std.testing.expectEqual(@as(u128, 0x99), (try decode(&buf)).frame.op.ack.op.restart);
}

test "the stage-6 commands round-trip" {
    var buf: [max_frame_len]u8 = undefined;
    var frame = Frame{
        .seq_id = 9,
        .host_idx = 1,
        .host_state = 0,
        .op = .{ .isolate = .{ .host_state = 0xdead_beef } },
    };
    try roundTrip(&buf, frame);
    try std.testing.expectEqual(@as(u128, 0xdead_beef), (try decode(&buf)).frame.op.isolate.host_state);

    frame.op = .{ .compensate = .{ .host_idx = 2, .count = 64 } };
    try roundTrip(&buf, frame);
    const compensate = (try decode(&buf)).frame.op.compensate;
    try std.testing.expectEqual(@as(u8, 2), compensate.host_idx);
    try std.testing.expectEqual(@as(u16, 64), compensate.count);

    frame.op = .{ .restart = 0x42 };
    try roundTrip(&buf, frame);
    try std.testing.expectEqual(@as(u128, 0x42), (try decode(&buf)).frame.op.restart);

    frame.op = .{ .restart_in = .{ .session_id = 0xabc, .seconds = 90 } };
    try roundTrip(&buf, frame);
    try std.testing.expectEqual(@as(u16, 90), (try decode(&buf)).frame.op.restart_in.seconds);

    frame.op = .{ .request_log = .{ .host_idx = 1, .index = 0x77 } };
    try roundTrip(&buf, frame);
    try std.testing.expectEqual(@as(u128, 0x77), (try decode(&buf)).frame.op.request_log.index);

    frame.op = .{ .requested_log_not_available = .{
        .host_idx = 1,
        .index = 0x78,
        .code = .out_of_date,
    } };
    try roundTrip(&buf, frame);
    try std.testing.expectEqual(
        LogUnavailable.Code.out_of_date,
        (try decode(&buf)).frame.op.requested_log_not_available.code,
    );

    frame.op = .{ .request_snapshot = .{ .host_idx = 3 } };
    try roundTrip(&buf, frame);
    try std.testing.expectEqual(@as(u8, 3), (try decode(&buf)).frame.op.request_snapshot.host_idx);

    // The stage-7 isolation vote and its answer carry the boundary of the
    // host the shard is asked about.
    frame.op = .{ .isolate_proposal = .{ .host_state = 0x77 } };
    try roundTrip(&buf, frame);
    try std.testing.expectEqual(@as(u128, 0x77), (try decode(&buf)).frame.op.isolate_proposal.host_state);

    frame.op = .{ .ack = .{ .epoch = 1, .op = .{ .isolate_proposal = 0x77 } } };
    try roundTrip(&buf, frame);
    try std.testing.expectEqual(
        @as(u128, 0x77),
        (try decode(&buf)).frame.op.ack.op.isolate_proposal,
    );
    try std.testing.expectEqual(
        Tag.isolate_proposal,
        acknowledgedTag(frame.op.ack.op),
    );
}

test "the log and snapshot chunks carry their bounded blob" {
    var buf: [max_frame_len]u8 = undefined;
    const data = [_]u8{ 0xde, 0xad, 0xbe, 0xef };
    var frame = Frame{
        .seq_id = 5,
        .host_idx = 1,
        .host_state = 0,
        .op = .{ .requested_log = .{
            .host_idx = 1,
            .index = 0x10,
            .final = true,
            .data = &data,
        } },
    };
    try roundTrip(&buf, frame);
    const log = (try decode(&buf)).frame.op.requested_log;
    try std.testing.expectEqualSlices(u8, &data, log.data);
    try std.testing.expect(log.final);
    try std.testing.expectEqual(@as(u128, 0x10), log.index);

    frame.op = .{ .requested_snapshot = .{
        .host_idx = 2,
        .index = 0x11,
        .final = false,
        .data = "",
    } };
    try roundTrip(&buf, frame);
    const snapshot = (try decode(&buf)).frame.op.requested_snapshot;
    try std.testing.expectEqual(@as(usize, 0), snapshot.data.len);
    try std.testing.expect(!snapshot.final);

    // The blob is capped: a chunk of `max_data` bytes is the largest frame the
    // codec accepts.
    var big: [max_data]u8 = @splat('x');
    frame.op = .{ .requested_log = .{
        .host_idx = 0,
        .index = 0,
        .final = true,
        .data = &big,
    } };
    try roundTrip(&buf, frame);
    try std.testing.expectEqual(max_frame_len, frameLen(frame.op));
}

test "a malformed frame is refused, not guessed at" {
    var buf: [max_frame_len]u8 = undefined;
    const frame = Frame{
        .seq_id = 0,
        .host_idx = 0,
        .host_state = 0,
        .op = .{ .append = .{ .session_id = 1, .data = "abc" } },
    };
    encode(&buf, frame);
    const len = frameLen(frame.op);

    try std.testing.expectError(error.Truncated, decode(buf[0 .. header_len - 1]));
    try std.testing.expectError(error.Truncated, decode(buf[0 .. len - 1]));

    // An op tag this build does not know: the numbering has no reserved gap a
    // reader may silently skip.
    var bad = buf;
    bad[19] = 0xff;
    try std.testing.expectError(error.UnknownTag, decode(bad[0..len]));

    // The payload must be long enough for the header it declares, and its
    // internal lengths must agree with what arrived.
    var lying = buf;
    std.mem.writeInt(u32, lying[20..24], @intCast(len - header_len + 1), .little);
    try std.testing.expectError(error.Truncated, decode(lying[0..len]));
    std.mem.writeInt(u32, lying[20..24], 6, .little);
    try std.testing.expectError(error.Malformed, decode(lying[0..len]));
    std.mem.writeInt(u32, lying[20..24], 2, .little);
    try std.testing.expectError(error.Malformed, decode(lying[0..len]));

    // A frame longer than this build's cap is refused before it is read.
    var huge = buf;
    std.mem.writeInt(u32, huge[20..24], max_payload + 1, .little);
    try std.testing.expectError(error.FrameTooLarge, decode(huge[0..len]));
}

test "the ring number maps to an absolute sequence index across the wrap" {
    try std.testing.expectEqual(@as(u64, 5), absoluteSeq(5, 5));
    try std.testing.expectEqual(@as(u64, 6), absoluteSeq(5, 6));
    // The ring wraps: the next frame after 0xffff is 0x10000.
    try std.testing.expectEqual(@as(u64, 0x10000), absoluteSeq(0xffff, 0));
    try std.testing.expectEqual(@as(u64, 0x10000), absoluteSeq(0x10000, 0));
    // A frame of the previous ring round is behind the expected one.
    try std.testing.expectEqual(@as(u64, 0xffff), absoluteSeq(0x10001, 0xffff));
    try std.testing.expectEqual(@as(u64, 0xffff), absoluteSeq(0xffff, 0xffff));
}

test "the tags cover the vocabulary and the requests map onto it" {
    for ([_]state.Op{ .create, .append, .overwrite, .repeat, .close }) |op| {
        const request = requestOf(op, 0x42);
        try std.testing.expectEqual(@as(u128, 0x42), sessionId(request).?);
        const answer = acked(request).?;
        try std.testing.expectEqual(tagOf(request), acknowledgedTag(answer));
        try std.testing.expectEqual(@as(u128, 0x42), acknowledgedSession(answer).?);
    }

    // Only the mutations and the stage-6 commands are answered; the answers
    // themselves and the pulse name no op.
    try std.testing.expect(acked(.{ .pulse = {} }) == null);
    try std.testing.expect(sessionId(.{ .pulse = {} }) == null);
    try std.testing.expect(acked(.{ .request_log = .{ .host_idx = 0, .index = 0 } }) == null);
    try std.testing.expect(sessionId(.{ .request_snapshot = .{ .host_idx = 0 } }) == null);

    // A session-bearing stage-6 command names its session, the session-less
    // ones do not.
    try std.testing.expectEqual(
        @as(?u128, 0x42),
        sessionId(.{ .restart_in = .{ .session_id = 0x42, .seconds = 5 } }),
    );
    try std.testing.expectEqual(@as(?u128, null), sessionId(.{ .isolate = .{ .host_state = 0 } }));
    try std.testing.expectEqual(
        @as(?u128, null),
        sessionId(.{ .compensate = .{ .host_idx = 1, .count = 3 } }),
    );
    try std.testing.expectEqual(
        Tag.isolate,
        acknowledgedTag(acked(.{ .isolate = .{ .host_state = 0 } }).?),
    );
    try std.testing.expectEqual(
        Tag.compensate,
        acknowledgedTag(acked(.{ .compensate = .{ .host_idx = 1, .count = 3 } }).?),
    );
}
