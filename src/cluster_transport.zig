//! Cluster link transport: the wire vocabulary and the frame codec.
//!
//! This file owns the fixed parts of the index-to-index protocol: the greet and
//! reply codecs of the handshake, the frame layout the receive path parses, the
//! verdict and op-code number spaces, the sequence-number lift and the link
//! state names. The socket lifecycle, the io_uring pushes and the reorder
//! plumbing live with the threads that run them; nothing here performs I/O.

const std = @import("std");
const posix = std.posix;
const blog = @import("blog");
const reorder_buffer = @import("reorder_buffer.zig");

/// Bumped on any incompatible change of the greet or the frame layout.
pub const VERSION: u16 = 1;

/// The dialer's fixed greeting: `version: u16, host_idx: u8, index_idx: u16`.
pub const GREET_LEN = 5;

/// The acceptor's fixed reply: the greet fields plus the two-byte verdict.
pub const REPLY_LEN = 7;

/// The smallest legal frame: prefix, vector clock, op, empty payload, empty
/// envelope.
pub const FRAME_MIN = 24;

/// The largest frame the v1 transport accepts.
pub const FRAME_CAP = 4096;

/// Link liveness ops. The rest of the number space belongs to the catch-up,
/// snapshot and consensus families.
pub const OP_PULSE: u8 = 0x00;
pub const OP_PULSE_ACK: u8 = 0x01;

/// The dial retry bounds: exponential from `RETRY_MIN` to `RETRY_MAX`,
/// reset on a successful link.
pub const RETRY_MIN: u64 = 100 * std.time.ns_per_ms;
pub const RETRY_MAX: u64 = 5 * std.time.ns_per_s;

comptime {
    std.debug.assert(FRAME_MIN == 4 + 1 + 16 + 1 + 1 + 1);
}

/// The pinned `blog` exports only the varint half of its encoder, so the
/// scalar shape is spelled out with the same little-endian wire form
/// `blog.append` uses. Returns the bytes written.
inline fn appendScalar(dst: [*]u8, value: anytype) usize {
    const bits = @bitSizeOf(@TypeOf(value));

    if (bits == 8) {
        dst[0] = value;
        return 1;
    }

    switch (bits) {
        16 => std.mem.writeInt(u16, @ptrCast(dst), value, .little),
        64 => std.mem.writeInt(u64, @ptrCast(dst), value, .little),
        else => @compileError("unsupported scalar width"),
    }

    return bits / 8;
}

/// Bytes `blog.appendVarint` writes for `value`, so the encoder can bound the
/// frame before touching it.
fn varintSize(value: usize) usize {
    var v: u64 = @intCast(value);
    var n: usize = 1;

    while (v >= 0x80) : (v >>= 7) {
        n += 1;
    }

    return n;
}

/// The handshake verdict codes. Values above `invalid_host` are reserved and a
/// decoder rejects them; a peer speaking a later version is caught by
/// `version_mismatch` first.
pub const Verdict = enum(u8) {
    ok = 0,
    host_index_squatting = 1,
    internal_error = 2,
    version_mismatch = 3,
    unknown_index = 4,
    not_accepting = 5,
    peer_address_mismatch = 6,
    invalid_host = 7,
};

/// The per-link lifecycle. A candidate is `parked` while the switch predicate
/// probes the established link; only `up` carries frames.
pub const LinkState = enum(u8) { none, greeting, parked, up };

/// One link: the pair `(own index thread, peer host)`. The table slot names the
/// pair, so nothing on the wire does (§2).
///
/// The entry is allocated on the first promotion of the link and lives until
/// the controller is torn down; a connection replacement resets it instead of
/// reallocating. `fd` is `-1` when the entry holds no socket, and whichever
/// side closes a descriptor clears the field.
pub const LinkEntry = struct {
    const Self = @This();

    /// Backing allocator of the reorder buffer and the send buffers.
    allocator: std.mem.Allocator,

    /// The peer host this link talks to.
    host_idx: u8,
    /// The index number both ends share; every frame belongs to it.
    index_idx: u16,

    /// Where the handshake left the link (§3.3, §3.4).
    state: LinkState = .none,
    /// Bumped on every phase change. Every armed `TaskCtx` carries it so a late
    /// completion is attributable and ignorable.
    epoch: u32 = 0,

    /// The socket, `-1` when none is held.
    fd: posix.fd_t = -1,
    /// The version the greet or the reply carried; the local one until then.
    version: u16 = VERSION,

    /// The absolute send counter. It is truncated into `seq_id` and advanced
    /// only after a successful submit, so a local `RingFull` leaves no hole
    /// (§4.5).
    seq_abs: u64 = 0,
    /// The absolute index the next received header lifts to.
    pushed_absolute: u64 = 0,
    /// The delivery cursor: frames below it reached the control plane.
    delivered: u64 = 0,
    /// Set while the peer's acknowledgement is outstanding (§4.8).
    acked: bool = false,

    /// The receive reorder buffer: `2 * window` slots of `FRAME_CAP` bytes.
    reorder: reorder_buffer.ReorderBuffer,
    /// The four-byte frame prefix being read and how much of it landed (§4.3).
    frame_hdr: [4]u8 = @splat(0),
    filled_hdr: usize = 0,
    /// The absolute index of the one open reservation, if any.
    open_reservation: ?u64 = null,
    /// The reserved slot's view and how much of the body landed. The
    /// reservation pins the slot, so the view stays valid until `commit`.
    frame_slot: ?[]u8 = null,
    frame_filled: usize = 0,
    /// The armed receive's slot, so a late completion is attributable.
    recv_task: ?u64 = null,
    /// The armed greeting send's slot.
    greeting_task: ?u64 = null,

    /// The dialer's greet and the acceptor's reply. Both live here, so the send
    /// completion never races a buffer that went away (§3.1, §3.3).
    greet: [GREET_LEN]u8 = @splat(0),
    reply: [REPLY_LEN]u8 = @splat(0),

    /// The dialer's connect, its bound, the greet send, the verdict read and
    /// its bound. Each is stored until its completion lands, so a retry cannot
    /// mistake a stale completion for the current attempt (§3.1, §3.5).
    connect_task: ?u64 = null,
    connect_deadline_task: ?u64 = null,
    greet_task: ?u64 = null,
    verdict_task: ?u64 = null,
    verdict_deadline_task: ?u64 = null,
    verdict_filled: usize = 0,
    /// The retry timer and the backoff in force when it was armed (§3.6).
    retry_task: ?u64 = null,
    retry_backoff: u64 = RETRY_MIN,
    /// A retry whose timer could not be armed yet; retried once per pass.
    retry_pending: bool = false,

    /// The parked duplicate candidate of the switch predicate (§3.4). It
    /// carries no traffic: it waits, without a receive arm, for the probe of
    /// the established link to resolve. `candidate_state` is `.parked` while
    /// the probe runs and `.greeting` while the candidate's verdict is in
    /// flight; the socket stays in `candidate_fd` until that send closes it.
    candidate_fd: posix.fd_t = -1,
    candidate_version: u16 = VERSION,
    candidate_state: LinkState = .none,
    /// The candidate's seven-byte verdict, kept here because the kernel reads
    /// it asynchronously.
    candidate_reply: [REPLY_LEN]u8 = @splat(0),
    candidate_reply_task: ?u64 = null,
    /// The probe's one-shot deadline and whether its pulse could not be
    /// submitted yet; the pulse is retried once per loop pass, like a refused
    /// snapshot push.
    predicate_task: ?u64 = null,
    probe_pending: bool = false,

    /// The repeating keepalive ticker armed on every established link by both
    /// sides (§4.8), and a pulse the ring refused, retried once per pass like
    /// the probe's. The ticker keeps its slot across every tick; only its
    /// final completion releases it.
    keepalive_task: ?u64 = null,
    keepalive_pending: bool = false,

    /// The kernel reads these asynchronously, so they live in the entry rather
    /// than on the arming pass's stack.
    connect_deadline_spec: std.os.linux.kernel_timespec = .{ .sec = 0, .nsec = 0 },
    verdict_deadline_spec: std.os.linux.kernel_timespec = .{ .sec = 0, .nsec = 0 },
    retry_spec: std.os.linux.kernel_timespec = .{ .sec = 0, .nsec = 0 },
    predicate_spec: std.os.linux.kernel_timespec = .{ .sec = 0, .nsec = 0 },
    keepalive_spec: std.os.linux.kernel_timespec = .{ .sec = 0, .nsec = 0 },

    /// One `FRAME_CAP`-byte send buffer per in-flight frame: a fixed bound, not
    /// a pool that falls back to the heap (§4.2).
    send_buffers: []u8,
    /// One bit per send buffer, set while the buffer waits for its CQE. The
    /// word count is `(inflight + 63) / 64`.
    send_busy: []u64,
    /// The slot each busy send buffer was armed with, so its completion frees
    /// the right buffer.
    send_task: []?u64,
    /// `cluster.inflight_frames`, the number of send buffers.
    inflight: u16,
    /// The next host whose frontier the vector clock carries (§5.1).
    vc_cursor: u8 = 0,

    /// Allocates the link's buffers. `window` is `cluster.reorder_window`,
    /// `inflight` is `cluster.inflight_frames`; both are validated by config.
    pub fn init(
        self: *Self,
        allocator: std.mem.Allocator,
        host_idx: u8,
        index_idx: u16,
        window: u16,
        inflight: u16,
    ) !void {
        var reorder: reorder_buffer.ReorderBuffer = undefined;
        try reorder.init(allocator, window, FRAME_CAP);
        errdefer reorder.deinit();

        const send_buffers = try allocator.alloc(u8, @as(usize, inflight) * FRAME_CAP);
        errdefer allocator.free(send_buffers);

        const send_busy = try allocator.alloc(u64, (@as(usize, inflight) + 63) / 64);
        errdefer allocator.free(send_busy);
        @memset(send_busy, 0);

        const send_task = try allocator.alloc(?u64, @as(usize, inflight));
        errdefer allocator.free(send_task);
        @memset(send_task, null);

        self.* = .{
            .allocator = allocator,
            .host_idx = host_idx,
            .index_idx = index_idx,
            .reorder = reorder,
            .send_buffers = send_buffers,
            .send_busy = send_busy,
            .send_task = send_task,
            .inflight = inflight,
        };
    }

    /// Returns the link's buffers. The socket is not touched: its owner closes
    /// it and clears `fd` first.
    pub fn deinit(self: *Self) void {
        self.reorder.deinit();
        self.allocator.free(self.send_buffers);
        self.allocator.free(self.send_busy);
        self.allocator.free(self.send_task);
    }

    /// Clears the per-connection state: the reorder buffer, the counters, the
    /// partial frame and the task tracking. The descriptor and the state are
    /// the caller's, and the epoch advances so a late completion from the old
    /// connection is ignored.
    ///
    /// The candidate fields are deliberately untouched: a parked candidate,
    /// and the verdict being sent to one, belong to the switch predicate and
    /// outlive the link whose probe decided them (§3.4).
    pub fn resetConnection(self: *Self) void {
        self.epoch +%= 1;
        self.version = VERSION;
        self.seq_abs = 0;
        self.pushed_absolute = 0;
        self.delivered = 0;
        self.acked = false;
        self.reorder.reset();
        self.frame_hdr = @splat(0);
        self.filled_hdr = 0;
        self.open_reservation = null;
        self.frame_slot = null;
        self.frame_filled = 0;
        self.recv_task = null;
        self.greeting_task = null;
        self.connect_task = null;
        self.connect_deadline_task = null;
        self.greet_task = null;
        self.verdict_task = null;
        self.verdict_deadline_task = null;
        self.verdict_filled = 0;
        self.keepalive_task = null;
        self.keepalive_pending = false;
        @memset(self.send_task, null);
        @memset(self.send_busy, 0);
        self.vc_cursor = 0;
    }

    /// The `seq`th send buffer, one frame's worth of wire bytes.
    pub fn sendBuffer(self: *Self, seq: u16) []u8 {
        std.debug.assert(seq < self.inflight);
        const off = @as(usize, seq) * FRAME_CAP;
        return self.send_buffers[off..][0..FRAME_CAP];
    }

    /// Whether the `seq`th send buffer still waits for its completion.
    pub fn sendBusy(self: *const Self, seq: u16) bool {
        std.debug.assert(seq < self.inflight);
        const word = @as(usize, seq) / 64;
        const bit: u6 = @intCast(@as(usize, seq) % 64);
        return self.send_busy[word] & (@as(u64, 1) << bit) != 0;
    }

    /// Marks the `seq`th send buffer busy or free.
    pub fn setSendBusy(self: *Self, seq: u16, busy: bool) void {
        std.debug.assert(seq < self.inflight);
        const word = @as(usize, seq) / 64;
        const bit: u6 = @intCast(@as(usize, seq) % 64);
        const mask = @as(u64, 1) << bit;
        if (busy) {
            self.send_busy[word] |= mask;
        } else {
            self.send_busy[word] &= ~mask;
        }
    }

    /// The first send buffer whose completion has not landed, or null when all
    /// `inflight_frames` buffers are busy: caller-visible backpressure (§4.2).
    pub fn freeSendBuffer(self: *const Self) ?u16 {
        var seq: u16 = 0;
        while (seq < self.inflight) : (seq += 1) {
            if (!self.sendBusy(seq)) return seq;
        }
        return null;
    }

    /// The send buffer armed with `task_idx`, or null when the completion is
    /// stale.
    pub fn findSendTask(self: *const Self, task_idx: u64) ?u16 {
        for (self.send_task, 0..) |maybe, seq| {
            if (maybe == task_idx) return @intCast(seq);
        }
        return null;
    }
};

/// The dialer's greeting, as the acceptor sees it.
pub const Greet = struct {
    version: u16,
    host_idx: u8,
    index_idx: u16,
};

/// The acceptor's answer. A front-side reject carries `0xFFFF` in `index_idx`,
/// because a front has no target index to name.
pub const Reply = struct {
    version: u16,
    host_idx: u8,
    index_idx: u16,
    verdict: Verdict,
};

pub const DecodeError = error{UnknownVerdict};

/// Writes the five greet bytes, little endian and packed.
pub fn encodeGreet(greet: Greet, dst: *[GREET_LEN]u8) void {
    var pos: usize = 0;

    pos += appendScalar(dst.ptr + pos, greet.version);
    pos += appendScalar(dst.ptr + pos, greet.host_idx);
    pos += appendScalar(dst.ptr + pos, greet.index_idx);

    std.debug.assert(pos == GREET_LEN);
}

pub fn decodeGreet(src: *const [GREET_LEN]u8) Greet {
    var pos: usize = 0;

    const version = std.mem.readInt(u16, src[pos..][0..2], .little);
    pos += 2;
    const host_idx = src[pos];
    pos += 1;
    const index_idx = std.mem.readInt(u16, src[pos..][0..2], .little);
    pos += 2;

    std.debug.assert(pos == GREET_LEN);

    return .{
        .version = version,
        .host_idx = host_idx,
        .index_idx = index_idx,
    };
}

/// Writes the seven reply bytes. The verdict is a two-byte code on the wire.
pub fn encodeReply(reply: Reply, dst: *[REPLY_LEN]u8) void {
    var pos: usize = 0;

    pos += appendScalar(dst.ptr + pos, reply.version);
    pos += appendScalar(dst.ptr + pos, reply.host_idx);
    pos += appendScalar(dst.ptr + pos, reply.index_idx);
    pos += appendScalar(dst.ptr + pos, @as(u16, @backingInt(reply.verdict)));

    std.debug.assert(pos == REPLY_LEN);
}

pub fn decodeReply(src: *const [REPLY_LEN]u8) DecodeError!Reply {
    var pos: usize = 0;

    const version = std.mem.readInt(u16, src[pos..][0..2], .little);
    pos += 2;
    const host_idx = src[pos];
    pos += 1;
    const index_idx = std.mem.readInt(u16, src[pos..][0..2], .little);
    pos += 2;
    const verdict_code = std.mem.readInt(u16, src[pos..][0..2], .little);
    pos += 2;

    std.debug.assert(pos == REPLY_LEN);

    if (verdict_code > @backingInt(Verdict.invalid_host)) {
        return error.UnknownVerdict;
    }

    return .{
        .version = version,
        .host_idx = host_idx,
        .index_idx = index_idx,
        .verdict = @fromBackingInt(@as(u8, @intCast(verdict_code))),
    };
}

/// The one vector-clock entry a frame carries: which host's frontier this is,
/// and the frontier value.
pub const VectorClockFrame = struct {
    host_idx: u8,
    state: u128,
};

/// The leader's aggregated decisions after the payload: the first decided
/// state, and one bit per consecutive state, LSB-first inside a byte.
pub const CommitEnvelope = struct {
    start_state_idx: u128 = 0,
    decisions: []const u8 = &.{},
};

/// A frame as the encoder consumes it. The frame has no index field: the link
/// it travels on already names the `(index thread, peer host)` pair.
pub const Frame = struct {
    seq_id: u16,
    vector_clock_frame: VectorClockFrame,
    op_code: u8,
    op_payload: []const u8,
    commit_envelope: CommitEnvelope = .{},
};

pub const EncodeError = error{FrameTooLarge};

/// Encodes `frame` into `dst` and returns its total length, which is also the
/// value back-patched into `frame_len` at offset 2.
///
/// An encoding that would exceed `FRAME_CAP` returns `error.FrameTooLarge`
/// before the caller can submit it; `dst` is unspecified in that case.
pub fn encodeFrame(dst: []u8, frame: Frame) EncodeError!usize {
    const cap = @min(dst.len, FRAME_CAP);
    if (cap < FRAME_MIN) {
        return error.FrameTooLarge;
    }

    var pos: usize = 0;

    // seq_id; frame_len is back-patched once the tail is known.
    if (pos + 4 > cap) return error.FrameTooLarge;
    pos += appendScalar(dst.ptr + pos, frame.seq_id);
    pos += 2;

    // The vector clock entry: a host byte and a u128 as two u64 appends, which
    // is exactly the 16-byte little-endian form.
    if (pos + 18 > cap) return error.FrameTooLarge;
    pos += appendScalar(dst.ptr + pos, frame.vector_clock_frame.host_idx);
    pos += appendScalar(dst.ptr + pos, @as(u64, @truncate(frame.vector_clock_frame.state)));
    pos += appendScalar(dst.ptr + pos, @as(u64, @truncate(frame.vector_clock_frame.state >> 64)));

    // The op code.
    pos += appendScalar(dst.ptr + pos, frame.op_code);

    // The payload is a slice through `blog.append`, so its own uvarint length
    // precedes it; an empty payload is the single byte 0x00.
    const payload_len = frame.op_payload.len;
    const payload_prefix = varintSize(payload_len);
    if (pos + payload_prefix + payload_len > cap) return error.FrameTooLarge;
    _ = blog.appendVarint(dst.ptr + pos, @as(u64, @intCast(payload_len)));
    pos += payload_prefix;
    @memcpy(dst[pos .. pos + payload_len], frame.op_payload);
    pos += payload_len;

    // The commit envelope. The bitmap is a raw copy: `no_of_decisions` already
    // carries its length. An empty envelope is the single byte 0x00.
    const decisions = frame.commit_envelope.decisions;
    const decisions_prefix = varintSize(decisions.len);
    const decisions_body: usize = if (decisions.len == 0) 0 else 16 + decisions.len;
    if (pos + decisions_prefix + decisions_body > cap) return error.FrameTooLarge;

    _ = blog.appendVarint(dst.ptr + pos, @as(u64, @intCast(decisions.len)));
    pos += decisions_prefix;

    if (decisions.len != 0) {
        pos += appendScalar(dst.ptr + pos, @as(u64, @truncate(frame.commit_envelope.start_state_idx)));
        pos += appendScalar(dst.ptr + pos, @as(u64, @truncate(frame.commit_envelope.start_state_idx >> 64)));
        @memcpy(dst[pos .. pos + decisions.len], decisions);
        pos += decisions.len;
    }

    std.debug.assert(pos >= FRAME_MIN);
    std.debug.assert(pos <= cap);

    const len_field: *[2]u8 = @ptrCast(dst.ptr + 2);
    std.mem.writeInt(u16, len_field, @intCast(pos), .little);

    return pos;
}

/// True when `frame_len`, as read from a frame header, is inside the legal
/// range. A length outside it is a link failure, not a skippable frame.
pub fn frameLenValid(frame_len: usize) bool {
    return frame_len >= FRAME_MIN and frame_len <= FRAME_CAP;
}

/// Lifts the 16-bit `seq_id` to its unique absolute index in
/// `[wave, wave + 0x10000)`.
///
/// The reorder buffer's own checks then reject an absolute below the wave or
/// one `size` or more ahead. A window that is not a power of two in `2..=0xFFFF`
/// makes the lift's uniqueness argument void and returns null; configuration
/// validation rules that out.
pub fn lift(wave: u64, seq_id: u16, window: u16) ?u64 {
    if (window < 2 or window > 0xFFFF or !std.math.isPowerOfTwo(window)) {
        return null;
    }

    const base = wave & ~@as(u64, 0xFFFF);
    const candidate = base + seq_id;
    return if (candidate < wave) candidate + 0x10000 else candidate;
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

test "the verdict, op and link state numbers are the pinned ones" {
    try expectEqual(@as(u8, 0), @backingInt(Verdict.ok));
    try expectEqual(@as(u8, 1), @backingInt(Verdict.host_index_squatting));
    try expectEqual(@as(u8, 2), @backingInt(Verdict.internal_error));
    try expectEqual(@as(u8, 3), @backingInt(Verdict.version_mismatch));
    try expectEqual(@as(u8, 4), @backingInt(Verdict.unknown_index));
    try expectEqual(@as(u8, 5), @backingInt(Verdict.not_accepting));
    try expectEqual(@as(u8, 6), @backingInt(Verdict.peer_address_mismatch));
    try expectEqual(@as(u8, 7), @backingInt(Verdict.invalid_host));

    try expectEqual(@as(u8, 0x00), OP_PULSE);
    try expectEqual(@as(u8, 0x01), OP_PULSE_ACK);

    try expectEqual(@as(u8, 0), @backingInt(LinkState.none));
    try expectEqual(@as(u8, 1), @backingInt(LinkState.greeting));
    try expectEqual(@as(u8, 2), @backingInt(LinkState.parked));
    try expectEqual(@as(u8, 3), @backingInt(LinkState.up));
}

test "greet and reply round-trip" {
    var greet_bytes: [GREET_LEN]u8 = undefined;
    const greet = Greet{ .version = VERSION, .host_idx = 3, .index_idx = 0x1234 };
    encodeGreet(greet, &greet_bytes);

    try expectEqual(@as(u8, 0x01), greet_bytes[0]);
    try expectEqual(@as(u8, 0x00), greet_bytes[1]);
    try expectEqual(@as(u8, 3), greet_bytes[2]);
    try expectEqual(@as(u8, 0x34), greet_bytes[3]);
    try expectEqual(@as(u8, 0x12), greet_bytes[4]);
    try expectEqual(greet, decodeGreet(&greet_bytes));

    var reply_bytes: [REPLY_LEN]u8 = undefined;
    const reply = Reply{
        .version = VERSION,
        .host_idx = 5,
        .index_idx = 2,
        .verdict = .peer_address_mismatch,
    };
    encodeReply(reply, &reply_bytes);

    try expectEqual(@as(u8, 6), reply_bytes[5]);
    try expectEqual(@as(u8, 0), reply_bytes[6]);
    try expectEqual(reply, try decodeReply(&reply_bytes));
}

test "a front-side reject carries the 0xFFFF index sentinel" {
    var reply_bytes: [REPLY_LEN]u8 = undefined;
    encodeReply(.{
        .version = VERSION,
        .host_idx = 0,
        .index_idx = 0xFFFF,
        .verdict = .version_mismatch,
    }, &reply_bytes);

    const reply = try decodeReply(&reply_bytes);
    try expectEqual(@as(u16, 0xFFFF), reply.index_idx);
    try expectEqual(Verdict.version_mismatch, reply.verdict);
    try expectEqual(@as(Verdict, @fromBackingInt(@as(u8, 3))), reply.verdict);
}

test "an unknown verdict code is a decode error" {
    var reply_bytes: [REPLY_LEN]u8 = undefined;
    @memset(&reply_bytes, 0);
    reply_bytes[5] = 8;
    reply_bytes[6] = 0;

    try std.testing.expectError(error.UnknownVerdict, decodeReply(&reply_bytes));
}

test "the length check accepts exactly the wire bounds" {
    try expect(!frameLenValid(23));
    try expect(frameLenValid(24));
    try expect(frameLenValid(4096));
    try expect(!frameLenValid(4097));
}

test "the frame layout is field after field, with the length back-patched" {
    var dst: [FRAME_CAP]u8 = undefined;
    const payload = [_]u8{ 0xAA, 0xBB, 0xCC };
    const state: u128 = 0x0102_0304_0506_0708_1112_1314_1516_1718;
    const start: u128 = 0x2122_2324_2526_2728_3132_3334_3536_3738;

    const len = try encodeFrame(&dst, .{
        .seq_id = 0x1234,
        .vector_clock_frame = .{ .host_idx = 7, .state = state },
        .op_code = 0x20,
        .op_payload = &payload,
        .commit_envelope = .{ .start_state_idx = start, .decisions = &.{0x05} },
    });

    try expectEqual(@as(usize, 44), len);

    // Prefix.
    try expectEqual(@as(u8, 0x34), dst[0]);
    try expectEqual(@as(u8, 0x12), dst[1]);
    try expectEqual(@as(u16, 44), std.mem.readInt(u16, dst[2..4], .little));

    // Vector clock: host byte, then the low and the high half, both little
    // endian.
    try expectEqual(@as(u8, 7), dst[4]);
    try expectEqual(@as(u64, 0x1112_1314_1516_1718), std.mem.readInt(u64, dst[5..13], .little));
    try expectEqual(@as(u64, 0x0102_0304_0506_0708), std.mem.readInt(u64, dst[13..21], .little));

    // Op code, then the payload behind its own uvarint length.
    try expectEqual(@as(u8, 0x20), dst[21]);
    try expectEqual(@as(u8, 3), dst[22]);
    try expectEqualSlices(u8, &payload, dst[23..26]);

    // Envelope: count, the start state as two halves, then the raw bitmap.
    try expectEqual(@as(u8, 1), dst[26]);
    try expectEqual(@as(u64, 0x3132_3334_3536_3738), std.mem.readInt(u64, dst[27..35], .little));
    try expectEqual(@as(u64, 0x2122_2324_2526_2728), std.mem.readInt(u64, dst[35..43], .little));
    try expectEqual(@as(u8, 0x05), dst[43]);
}

test "an empty payload and an empty envelope are one zero byte each" {
    var dst: [FRAME_CAP]u8 = undefined;
    const len = try encodeFrame(&dst, .{
        .seq_id = 0,
        .vector_clock_frame = .{ .host_idx = 0, .state = 0 },
        .op_code = OP_PULSE,
        .op_payload = &.{},
        .commit_envelope = .{},
    });

    try expectEqual(@as(usize, FRAME_MIN), len);
    try expectEqual(@as(u8, OP_PULSE), dst[21]);
    try expectEqual(@as(u8, 0x00), dst[22]);
    try expectEqual(@as(u8, 0x00), dst[23]);
}

test "the decisions bitmap is a raw copy without a varint prefix" {
    var dst: [FRAME_CAP]u8 = undefined;
    const len = try encodeFrame(&dst, .{
        .seq_id = 0,
        .vector_clock_frame = .{ .host_idx = 0, .state = 0 },
        .op_code = OP_PULSE_ACK,
        .op_payload = &.{},
        .commit_envelope = .{ .decisions = &.{ 0x02, 0x00 } },
    });

    // 4 prefix + 17 clock + 1 op + 1 empty payload + 1 count + 16 state + 2 bits.
    try expectEqual(@as(usize, 42), len);
    try expectEqual(@as(u8, 2), dst[23]);
    try expectEqual(@as(u8, 0x02), dst[40]);
    try expectEqual(@as(u8, 0x00), dst[41]);
}

test "every encode back-patches its own validated length" {
    var dst: [FRAME_CAP]u8 = undefined;
    var payload: [1000]u8 = undefined;
    @memset(&payload, 0x5A);

    for ([_]usize{ 0, 1, 127, 128, 1000 }) |payload_len| {
        for ([_]usize{ 0, 1, 2 }) |decisions_len| {
            var decisions: [2]u8 = undefined;
            @memset(&decisions, 0x01);

            const len = try encodeFrame(&dst, .{
                .seq_id = 9,
                .vector_clock_frame = .{ .host_idx = 4, .state = 0xDEAD_BEEF },
                .op_code = OP_PULSE,
                .op_payload = payload[0..payload_len],
                .commit_envelope = .{ .decisions = decisions[0..decisions_len] },
            });

            try expect(frameLenValid(len));
            try expectEqual(@as(u16, @intCast(len)), std.mem.readInt(u16, dst[2..4], .little));
            try expectEqual(@as(u16, 9), std.mem.readInt(u16, dst[0..2], .little));
        }
    }
}

test "the frame cap is exact and one byte over is refused" {
    var dst: [FRAME_CAP]u8 = undefined;
    var payload: [FRAME_CAP]u8 = undefined;
    @memset(&payload, 0);

    const full = try encodeFrame(&dst, .{
        .seq_id = 0,
        .vector_clock_frame = .{ .host_idx = 0, .state = 0 },
        .op_code = OP_PULSE,
        .op_payload = payload[0..4071],
    });
    try expectEqual(@as(usize, FRAME_CAP), full);

    try std.testing.expectError(error.FrameTooLarge, encodeFrame(&dst, .{
        .seq_id = 0,
        .vector_clock_frame = .{ .host_idx = 0, .state = 0 },
        .op_code = OP_PULSE,
        .op_payload = payload[0..4072],
    }));

    try std.testing.expectError(error.FrameTooLarge, encodeFrame(&dst, .{
        .seq_id = 0,
        .vector_clock_frame = .{ .host_idx = 0, .state = 0 },
        .op_code = OP_PULSE,
        .op_payload = payload[0..4060],
        .commit_envelope = .{ .decisions = payload[0..10] },
    }));
}

test "the lift picks the unique absolute in the 16-bit window" {
    try expectEqual(@as(?u64, 0), lift(0, 0, 16));
    try expectEqual(@as(?u64, 1), lift(0, 1, 16));
    try expectEqual(@as(?u64, 2), lift(1, 2, 16));
    try expectEqual(@as(?u64, 0x1_0001), lift(3, 1, 16));
    try expectEqual(@as(?u64, 0x1_0000), lift(0xFFFF, 0, 16));
    try expectEqual(@as(?u64, 0x1_0000), lift(0x1_0000, 0, 16));
    try expectEqual(@as(?u64, 0x1_0005), lift(0x1_0002, 5, 16));

    try expectEqual(@as(?u64, null), lift(0, 0, 0));
    try expectEqual(@as(?u64, null), lift(0, 0, 3));
}

test "frames fed out of order through the reorder buffer deliver in sequence" {
    var ordbuf: reorder_buffer.ReorderBuffer = undefined;
    try ordbuf.init(std.testing.allocator, 16, FRAME_CAP);
    defer ordbuf.deinit();

    var encoded: [3][FRAME_CAP]u8 = undefined;
    var lens: [3]usize = undefined;
    for (0..3) |i| {
        const payload = [2]u8{ 'f', @intCast('0' + i) };
        lens[i] = try encodeFrame(&encoded[i], .{
            .seq_id = @intCast(i),
            .vector_clock_frame = .{ .host_idx = 1, .state = i },
            .op_code = OP_PULSE,
            .op_payload = &payload,
        });
    }

    // Frame 2 lands before frame 1; the buffer must hold it until the hole
    // closes.
    for ([_]u16{ 0, 2, 1 }) |seq_id| {
        const abs = lift(ordbuf.wave, seq_id, 16).?;
        const slot = try ordbuf.reserve(abs);
        @memcpy(slot[0..lens[seq_id]], encoded[seq_id][0..lens[seq_id]]);
        ordbuf.commit(abs, lens[seq_id]);
    }

    for (0..3) |i| {
        const head = ordbuf.popHeadCond(i) orelse std.debug.panic("missing frame {}", .{i});
        try expectEqual(lens[i], head.len);
        try std.testing.expectEqualSlices(u8, encoded[i][0..lens[i]], head);
    }
    try expect(ordbuf.popHeadCond(3) == null);
}

test "a link entry owns its reorder window and its bounded send ring" {
    var entry: LinkEntry = undefined;
    try LinkEntry.init(&entry, std.testing.allocator, 1, 3, 16, 4);
    defer entry.deinit();

    try expectEqual(@as(u8, 1), entry.host_idx);
    try expectEqual(@as(u16, 3), entry.index_idx);
    try expectEqual(LinkState.none, entry.state);
    try expectEqual(@as(u32, 0), entry.epoch);
    try expectEqual(@as(posix.fd_t, -1), entry.fd);
    try expectEqual(VERSION, entry.version);

    // The window is `cluster.reorder_window` slots, `2 * window` backing slots
    // of one frame each; nothing is allocated before the link exists.
    try expectEqual(@as(u64, 16), entry.reorder.size);
    try expectEqual(@as(usize, FRAME_CAP), entry.reorder.item_size);
    try expectEqual(@as(u16, 4), entry.inflight);
    try expectEqual(@as(usize, FRAME_CAP), entry.sendBuffer(3).len);
    try expectEqual(@as(usize, 4 * FRAME_CAP), entry.send_buffers.len);
    try expectEqual(@as(usize, 1), entry.send_busy.len);

    // Every buffer starts free; the busy bits are per buffer, not per ring.
    try expectEqual(@as(?u16, 0), entry.freeSendBuffer());
    entry.setSendBusy(0, true);
    entry.setSendBusy(3, true);
    try expect(entry.sendBusy(0));
    try expect(!entry.sendBusy(1));
    try expect(entry.sendBusy(3));
    try expectEqual(@as(?u16, 1), entry.freeSendBuffer());

    for (0..4) |seq| entry.setSendBusy(@intCast(seq), true);
    try expectEqual(@as(?u16, null), entry.freeSendBuffer());
    for (0..4) |seq| entry.setSendBusy(@intCast(seq), false);
    try expectEqual(@as(?u16, 0), entry.freeSendBuffer());
}
test "a connection reset clears the counters, the reservation and the task map" {
    var entry: LinkEntry = undefined;
    try LinkEntry.init(&entry, std.testing.allocator, 1, 3, 16, 4);
    defer entry.deinit();

    entry.state = .up;
    entry.fd = 7;
    entry.seq_abs = 9;
    entry.pushed_absolute = 5;
    entry.delivered = 2;
    entry.acked = true;
    entry.vc_cursor = 1;
    entry.filled_hdr = 3;
    entry.frame_filled = 4;
    entry.open_reservation = 5;
    entry.frame_slot = try entry.reorder.reserve(5);
    entry.recv_task = 11;
    entry.greeting_task = 12;
    entry.setSendBusy(0, true);
    entry.send_task[0] = 13;

    try expectEqual(@as(?u16, 0), entry.findSendTask(13));
    try expectEqual(@as(?u16, null), entry.findSendTask(14));

    const epoch = entry.epoch;
    entry.resetConnection();

    try expectEqual(epoch +% 1, entry.epoch);
    try expectEqual(@as(u64, 0), entry.seq_abs);
    try expectEqual(@as(u64, 0), entry.pushed_absolute);
    try expectEqual(@as(u64, 0), entry.delivered);
    try expect(!entry.acked);
    try expectEqual(@as(u8, 0), entry.vc_cursor);
    try expectEqual(@as(usize, 0), entry.filled_hdr);
    try expectEqual(@as(usize, 0), entry.frame_filled);
    try expect(entry.open_reservation == null);
    try expect(entry.frame_slot == null);
    try expect(entry.recv_task == null);
    try expect(entry.greeting_task == null);
    try expect(!entry.sendBusy(0));
    try expectEqual(@as(?u16, null), entry.findSendTask(13));
    try expectEqual(@as(u64, 0), entry.reorder.wave);

    // The descriptor and the state are the caller's, not the reset's.
    try expectEqual(@as(posix.fd_t, 7), entry.fd);
    try expectEqual(LinkState.up, entry.state);
}
