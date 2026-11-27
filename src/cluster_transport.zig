//! Cluster link transport: the wire vocabulary and the frame codec.
//!
//! This file owns the fixed parts of the index-to-index protocol: the greet and
//! reply codecs of the handshake, the frame layout the receive path parses, the
//! verdict and op-code number spaces, the per-op payload codecs, the
//! sequence-number lift and the link state names. The socket lifecycle, the
//! io_uring pushes and the reorder plumbing live with the threads that run
//! them; nothing here performs I/O.

const std = @import("std");
const posix = std.posix;
const blog = @import("blog");
const reorder_buffer = @import("reorder_buffer.zig");
const res_handle = @import("resources_handle.zig");

/// Bumped on any incompatible change of the greet or the frame layout.
pub const VERSION: u16 = 1;

/// The dialer's fixed greeting: `version: u16, host_idx: u8, index_idx: u16`.
pub const GREET_LEN = 5;

/// The acceptor's fixed reply: the greet fields plus the two-byte verdict.
pub const REPLY_LEN = 7;

/// The smallest legal control or transport frame: prefix, vector clock, op and
/// the empty payload length.
pub const FRAME_MIN: usize = 23;

/// The smallest legal consensus frame: the broad minimum plus the two state
/// fields and the envelope length.
pub const FRAME_MIN_CONSENSUS: usize = 56;

/// The largest frame the v1 transport accepts.
pub const FRAME_CAP = 4096;

/// The largest data slice a `LogData`/`Snapshot`/`Log` arm can carry: the
/// frame cap minus the 33 bytes of prefix, payload length, `host_id`, transfer
/// `seq_id`, oneof tag, data-length uvarint and `final` bool (§3.4). The
/// chunker uses this bound.
pub const CHUNK_DATA_MAX: usize = FRAME_CAP - 33;

/// The three op-code classes. The class is a range test on `op_code`; there is
/// no second tag.
pub const FrameClass = enum {
    control,
    transport,
    consensus,
};

/// The class of `op`, or null when the op code has no class. Values inside a
/// valid range are class members even when unassigned; `0x80..0xFF` has none.
pub fn frameClass(op: u8) ?FrameClass {
    return switch (op) {
        0x00...0x0F => .control,
        0x10...0x1F => .transport,
        0x20...0x7F => .consensus,
        else => null,
    };
}

/// The smallest legal frame length for `class`.
pub fn frameMin(class: FrameClass) usize {
    return switch (class) {
        .control, .transport => FRAME_MIN,
        .consensus => FRAME_MIN_CONSENSUS,
    };
}

/// Control-wire ops. `0x04..0x0F` are reserved.
pub const OP_PULSE: u8 = 0x00;
pub const OP_PULSE_ACK: u8 = 0x01;
pub const OP_EMERGENCY_STOP: u8 = 0x02;
pub const OP_DECISION: u8 = 0x03;

/// Transport-wire ops. `0x16..0x1F` are reserved.
pub const OP_DELIVER_LOG: u8 = 0x10;
pub const OP_DELIVER_LOG_RESPONSE: u8 = 0x11;
pub const OP_DELIVER_LOG_COMMIT: u8 = 0x12;
pub const OP_DELIVER_SNAPSHOT: u8 = 0x13;
pub const OP_DELIVER_SNAPSHOT_RESPONSE: u8 = 0x14;
pub const OP_DELIVER_SNAPSHOT_COMMIT: u8 = 0x15;

/// Consensus-wire ops. `0x2A..0x7F` are reserved.
pub const OP_CREATE: u8 = 0x20;
pub const OP_APPEND: u8 = 0x21;
pub const OP_OVERWRITE: u8 = 0x22;
pub const OP_CLOSE: u8 = 0x23;
pub const OP_REPEAT: u8 = 0x24;
pub const OP_COMPENSATE: u8 = 0x25;
pub const OP_ISOLATE: u8 = 0x26;
pub const OP_CAPTURE: u8 = 0x27;
pub const OP_CAPTURE_COMPENSATE: u8 = 0x28;
pub const OP_NOP: u8 = 0x29;

/// The flat `Decision` kind byte. Tags `4..255` are reserved and malformed at
/// decode.
pub const DecisionKind = enum(u8) {
    confirmed = 0,
    rejected_update_yourself = 1,
    rejected_you_are_late = 2,
    data_integrity_violated = 3,
};

/// The dial retry bounds: exponential from `RETRY_MIN` to `RETRY_MAX`,
/// reset on a successful link.
pub const RETRY_MIN: u64 = 100 * std.time.ns_per_ms;
pub const RETRY_MAX: u64 = 5 * std.time.ns_per_s;

comptime {
    std.debug.assert(FRAME_MIN == 4 + 1 + 16 + 1 + 1);
    std.debug.assert(FRAME_MIN_CONSENSUS == 4 + 1 + 16 + 1 + 16 + 16 + 1 + 1);
    std.debug.assert(CHUNK_DATA_MAX == 4063);
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
        32 => std.mem.writeInt(u32, @ptrCast(dst), value, .little),
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
/// reallocating. `fd` is empty when the entry holds no socket, and whichever
/// side closes a descriptor clears the handle.
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

    /// The socket; empty when none is held.
    fd: res_handle.SocketHandle = .{},
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
    candidate_fd: res_handle.SocketHandle = .{},
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
///
/// The class comes from `op_code`. A consensus frame carries both state fields
/// and may carry an envelope; a control or transport frame carries neither.
/// Keeping the fields optional makes a class mismatch visible to `encodeFrame`
/// instead of silently encoding zeros (§2.3).
pub const Frame = struct {
    seq_id: u16,
    vector_clock_frame: VectorClockFrame,
    op_code: u8,
    op_payload: []const u8,
    state_id: ?u128 = null,
    prev_state_id: ?u128 = null,
    commit_envelope: ?CommitEnvelope = null,
};

pub const EncodeError = error{
    FrameTooLarge,
    InvalidOpCode,
    FrameClassMismatch,
};

/// Writes a `u128` low half first (§2.1). Returns the bytes written.
inline fn appendU128(dst: [*]u8, value: u128) usize {
    var pos: usize = 0;
    pos += appendScalar(dst + pos, @as(u64, @truncate(value)));
    pos += appendScalar(dst + pos, @as(u64, @truncate(value >> 64)));
    return pos;
}

/// Encodes `frame` into `dst` and returns its total length, which is also the
/// value back-patched into `frame_len` at offset 2.
///
/// The class is derived from `op_code`: a consensus frame writes `stateID`,
/// `prevStateID`, the payload and the envelope; a control or transport frame
/// writes the payload and nothing else. Optional fields that disagree with the
/// class return `error.FrameClassMismatch`, because no decoder could observe
/// such a frame; an op outside every class returns `error.InvalidOpCode`. An
/// encoding that would exceed `FRAME_CAP` returns `error.FrameTooLarge` before
/// the caller can submit it; `dst` is unspecified in those cases.
pub fn encodeFrame(dst: []u8, frame: Frame) EncodeError!usize {
    const cap = @min(dst.len, FRAME_CAP);
    const class = frameClass(frame.op_code) orelse return error.InvalidOpCode;
    if (cap < frameMin(class)) {
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

    switch (class) {
        .consensus => {
            const state_id = frame.state_id orelse return error.FrameClassMismatch;
            const prev_state_id = frame.prev_state_id orelse return error.FrameClassMismatch;
            if (pos + 32 > cap) return error.FrameTooLarge;
            pos += appendU128(dst.ptr + pos, state_id);
            pos += appendU128(dst.ptr + pos, prev_state_id);
        },
        .control, .transport => {
            if (frame.state_id != null or frame.prev_state_id != null) {
                return error.FrameClassMismatch;
            }
            if (frame.commit_envelope != null) return error.FrameClassMismatch;
        },
    }

    // The payload is a slice through `blog.append`, so its own uvarint length
    // precedes it; an empty payload is the single byte 0x00.
    const payload_len = frame.op_payload.len;
    const payload_prefix = varintSize(payload_len);
    if (pos + payload_prefix + payload_len > cap) return error.FrameTooLarge;
    _ = blog.appendVarint(dst.ptr + pos, @as(u64, @intCast(payload_len)));
    pos += payload_prefix;
    @memcpy(dst[pos .. pos + payload_len], frame.op_payload);
    pos += payload_len;

    if (class == .consensus) {
        // The envelope is a consensus-only tail. A null envelope encodes as the
        // single byte 0x00, exactly like an empty one (§2.4). The bitmap is a
        // raw copy: the leading uvarint already carries its length.
        const envelope = frame.commit_envelope orelse CommitEnvelope{};
        const decisions = envelope.decisions;
        const decisions_prefix = varintSize(decisions.len);
        const decisions_body: usize = if (decisions.len == 0) 0 else 16 + decisions.len;
        if (pos + decisions_prefix + decisions_body > cap) return error.FrameTooLarge;

        _ = blog.appendVarint(dst.ptr + pos, @as(u64, @intCast(decisions.len)));
        pos += decisions_prefix;

        if (decisions.len != 0) {
            pos += appendU128(dst.ptr + pos, envelope.start_state_idx);
            @memcpy(dst[pos .. pos + decisions.len], decisions);
            pos += decisions.len;
        }
    }

    std.debug.assert(pos >= frameMin(class));
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

/// True when `frame_len` is legal for the class of `op`. A length inside the
/// broad bound but below the class minimum of its own op is a link failure
/// (§2.3).
pub fn frameLenValidFor(op: u8, frame_len: usize) bool {
    const class = frameClass(op) orelse return false;
    return frame_len >= frameMin(class) and frame_len <= FRAME_CAP;
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

// ---------------------------------------------------------------------------
// Payload codecs (§3)
// ---------------------------------------------------------------------------

/// `diag` is a UTF-8 string capped at this many bytes. An over-cap value is a
/// malformed payload, never a truncated one (§2.1).
pub const DIAG_CAP: usize = 256;

/// The payload codec's failures. `PayloadTooLarge` is encode-side: the
/// caller's buffer cannot hold the encoding. The other tags are decode-side
/// malformations that close the link (§4.9); the encoders reject the same
/// structural violations so they cannot emit a payload a peer must kill.
pub const PayloadError = error{
    PayloadTooLarge,
    TruncatedPayload,
    TrailingBytes,
    InvalidBool,
    InvalidUtf8,
    DiagTooLong,
    UnknownOneofTag,
    UnknownDecisionKind,
    SnapshotFinalViolation,
    ZeroStateId,
    ZeroCount,
};

/// The payload writer: little-endian scalars, a `uvarint` length before every
/// variable-size field, no padding (§2.1).
const PayloadWriter = struct {
    dst: []u8,
    pos: usize = 0,

    fn put(self: *PayloadWriter, data: []const u8) PayloadError!void {
        if (data.len > self.dst.len - self.pos) return error.PayloadTooLarge;
        @memcpy(self.dst[self.pos..][0..data.len], data);
        self.pos += data.len;
    }

    fn putVarint(self: *PayloadWriter, value: usize) PayloadError!void {
        const width = varintSize(value);
        if (width > self.dst.len - self.pos) return error.PayloadTooLarge;
        _ = blog.appendVarint(self.dst.ptr + self.pos, @as(u64, @intCast(value)));
        self.pos += width;
    }

    fn putScalar(self: *PayloadWriter, value: anytype) PayloadError!void {
        const width = @bitSizeOf(@TypeOf(value)) / 8;
        if (width > self.dst.len - self.pos) return error.PayloadTooLarge;
        _ = appendScalar(self.dst.ptr + self.pos, value);
        self.pos += width;
    }

    fn putU128(self: *PayloadWriter, value: u128) PayloadError!void {
        try self.putScalar(@as(u64, @truncate(value)));
        try self.putScalar(@as(u64, @truncate(value >> 64)));
    }

    fn putBool(self: *PayloadWriter, value: bool) PayloadError!void {
        try self.putScalar(@as(u8, @intFromBool(value)));
    }

    fn putBytes(self: *PayloadWriter, value: []const u8) PayloadError!void {
        try self.putVarint(value.len);
        try self.put(value);
    }

    fn putString(self: *PayloadWriter, value: []const u8) PayloadError!void {
        try self.putBytes(value);
    }

    fn putDiag(self: *PayloadWriter, value: []const u8) PayloadError!void {
        if (value.len > DIAG_CAP) return error.DiagTooLong;
        try self.putBytes(value);
    }
};

/// The payload reader. Every read is bounds-checked and every decode ends by
/// requiring that the fields tile the payload exactly.
const PayloadReader = struct {
    src: []const u8,
    pos: usize = 0,

    fn take(self: *PayloadReader, count: usize) PayloadError![]const u8 {
        if (self.pos > self.src.len or count > self.src.len - self.pos) {
            return error.TruncatedPayload;
        }
        const data = self.src[self.pos..][0..count];
        self.pos += count;
        return data;
    }

    fn varint(self: *PayloadReader) PayloadError!usize {
        var value: u64 = 0;
        var shift: u32 = 0;
        var i = self.pos;

        while (i < self.src.len) : (i += 1) {
            const byte = self.src[i];
            if (shift >= 64) return error.TruncatedPayload;

            const bits: u64 = byte & 0x7f;
            if (shift == 63 and bits > 1) return error.TruncatedPayload;
            value |= bits << @as(u6, @intCast(shift));

            if (byte & 0x80 == 0) {
                self.pos = i + 1;
                return std.math.cast(usize, value) orelse error.TruncatedPayload;
            }
            shift += 7;
        }

        return error.TruncatedPayload;
    }

    fn scalar(self: *PayloadReader, comptime T: type) PayloadError!T {
        const raw = try self.take(@sizeOf(T));
        return std.mem.readInt(T, raw[0..@sizeOf(T)], .little);
    }

    fn getU128(self: *PayloadReader) PayloadError!u128 {
        const low = try self.scalar(u64);
        const high = try self.scalar(u64);
        return @as(u128, low) | (@as(u128, high) << 64);
    }

    fn boolean(self: *PayloadReader) PayloadError!bool {
        return switch (try self.scalar(u8)) {
            0 => false,
            1 => true,
            else => error.InvalidBool,
        };
    }

    fn bytes(self: *PayloadReader) PayloadError![]const u8 {
        const length = try self.varint();
        return self.take(length);
    }

    fn string(self: *PayloadReader) PayloadError![]const u8 {
        const value = try self.bytes();
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
        return value;
    }

    fn diag(self: *PayloadReader) PayloadError![]const u8 {
        const value = try self.string();
        if (value.len > DIAG_CAP) return error.DiagTooLong;
        return value;
    }

    fn expectEnd(self: *PayloadReader) PayloadError!void {
        if (self.pos != self.src.len) return error.TrailingBytes;
    }
};

/// A consensus `Create` payload. The new session id is the frame's `stateID`,
/// so the payload carries no id (§3.1).
pub const CreatePayload = struct {
    compensator: []const u8,
    payload: []const u8,
};

pub const AppendPayload = struct {
    session_id: u128,
    payload: []const u8,
};

pub const OverwritePayload = struct {
    session_id: u128,
    payload: []const u8,
};

pub const ClosePayload = struct {
    session_id: u128,
};

pub const RepeatPayload = struct {
    session_id: u128,
    timeout_seconds: u32,
};

pub const CompensatePayload = struct {
    new_id: u128,
    original_id: u128,
};

pub const IsolatePayload = struct {
    host_id: u8,
    lost_host_state_id: u128,
};

pub const CapturePayload = struct {
    lost_host_id: u8,
    host_id: u8,
    host_state_id: u128,
    n: u32,
    timeout_seconds: u32,
};

pub const CaptureCompensatePayload = struct {
    lost_host_id: u8,
    host_id: u8,
    host_state_id: u128,
    n: u32,
};

pub fn encodeCreate(dst: []u8, value: CreatePayload) PayloadError!usize {
    var w = PayloadWriter{ .dst = dst };
    try w.putString(value.compensator);
    try w.putBytes(value.payload);
    return w.pos;
}

pub fn decodeCreate(src: []const u8) PayloadError!CreatePayload {
    var r = PayloadReader{ .src = src };
    const compensator = try r.string();
    const payload = try r.bytes();
    try r.expectEnd();
    return .{ .compensator = compensator, .payload = payload };
}

pub fn encodeAppend(dst: []u8, value: AppendPayload) PayloadError!usize {
    var w = PayloadWriter{ .dst = dst };
    try w.putU128(value.session_id);
    try w.putBytes(value.payload);
    return w.pos;
}

pub fn decodeAppend(src: []const u8) PayloadError!AppendPayload {
    var r = PayloadReader{ .src = src };
    const session_id = try r.getU128();
    const payload = try r.bytes();
    try r.expectEnd();
    return .{ .session_id = session_id, .payload = payload };
}

pub fn encodeOverwrite(dst: []u8, value: OverwritePayload) PayloadError!usize {
    var w = PayloadWriter{ .dst = dst };
    try w.putU128(value.session_id);
    try w.putBytes(value.payload);
    return w.pos;
}

pub fn decodeOverwrite(src: []const u8) PayloadError!OverwritePayload {
    var r = PayloadReader{ .src = src };
    const session_id = try r.getU128();
    const payload = try r.bytes();
    try r.expectEnd();
    return .{ .session_id = session_id, .payload = payload };
}

pub fn encodeClose(dst: []u8, value: ClosePayload) PayloadError!usize {
    var w = PayloadWriter{ .dst = dst };
    try w.putU128(value.session_id);
    return w.pos;
}

pub fn decodeClose(src: []const u8) PayloadError!ClosePayload {
    var r = PayloadReader{ .src = src };
    const session_id = try r.getU128();
    try r.expectEnd();
    return .{ .session_id = session_id };
}

pub fn encodeRepeat(dst: []u8, value: RepeatPayload) PayloadError!usize {
    var w = PayloadWriter{ .dst = dst };
    try w.putU128(value.session_id);
    try w.putScalar(value.timeout_seconds);
    return w.pos;
}

pub fn decodeRepeat(src: []const u8) PayloadError!RepeatPayload {
    var r = PayloadReader{ .src = src };
    const session_id = try r.getU128();
    const timeout_seconds = try r.scalar(u32);
    try r.expectEnd();
    return .{ .session_id = session_id, .timeout_seconds = timeout_seconds };
}

pub fn encodeCompensate(dst: []u8, value: CompensatePayload) PayloadError!usize {
    var w = PayloadWriter{ .dst = dst };
    try w.putU128(value.new_id);
    try w.putU128(value.original_id);
    return w.pos;
}

pub fn decodeCompensate(src: []const u8) PayloadError!CompensatePayload {
    var r = PayloadReader{ .src = src };
    const new_id = try r.getU128();
    const original_id = try r.getU128();
    try r.expectEnd();
    return .{ .new_id = new_id, .original_id = original_id };
}

pub fn encodeIsolate(dst: []u8, value: IsolatePayload) PayloadError!usize {
    var w = PayloadWriter{ .dst = dst };
    try w.putScalar(value.host_id);
    try w.putU128(value.lost_host_state_id);
    return w.pos;
}

pub fn decodeIsolate(src: []const u8) PayloadError!IsolatePayload {
    var r = PayloadReader{ .src = src };
    const host_id = try r.scalar(u8);
    const lost_host_state_id = try r.getU128();
    try r.expectEnd();
    return .{ .host_id = host_id, .lost_host_state_id = lost_host_state_id };
}

pub fn encodeCapture(dst: []u8, value: CapturePayload) PayloadError!usize {
    if (value.n == 0) return error.ZeroCount;

    var w = PayloadWriter{ .dst = dst };
    try w.putScalar(value.lost_host_id);
    try w.putScalar(value.host_id);
    try w.putU128(value.host_state_id);
    try w.putScalar(value.n);
    try w.putScalar(value.timeout_seconds);
    return w.pos;
}

pub fn decodeCapture(src: []const u8) PayloadError!CapturePayload {
    var r = PayloadReader{ .src = src };
    const lost_host_id = try r.scalar(u8);
    const host_id = try r.scalar(u8);
    const host_state_id = try r.getU128();
    const n = try r.scalar(u32);
    const timeout_seconds = try r.scalar(u32);
    try r.expectEnd();

    if (n == 0) return error.ZeroCount;

    return .{
        .lost_host_id = lost_host_id,
        .host_id = host_id,
        .host_state_id = host_state_id,
        .n = n,
        .timeout_seconds = timeout_seconds,
    };
}

pub fn encodeCaptureCompensate(dst: []u8, value: CaptureCompensatePayload) PayloadError!usize {
    if (value.n == 0) return error.ZeroCount;

    var w = PayloadWriter{ .dst = dst };
    try w.putScalar(value.lost_host_id);
    try w.putScalar(value.host_id);
    try w.putU128(value.host_state_id);
    try w.putScalar(value.n);
    return w.pos;
}

pub fn decodeCaptureCompensate(src: []const u8) PayloadError!CaptureCompensatePayload {
    var r = PayloadReader{ .src = src };
    const lost_host_id = try r.scalar(u8);
    const host_id = try r.scalar(u8);
    const host_state_id = try r.getU128();
    const n = try r.scalar(u32);
    try r.expectEnd();

    if (n == 0) return error.ZeroCount;

    return .{
        .lost_host_id = lost_host_id,
        .host_id = host_id,
        .host_state_id = host_state_id,
        .n = n,
    };
}

/// Writes an op with no payload: zero bytes.
pub fn encodeEmpty(dst: []u8) PayloadError!usize {
    _ = dst;
    return 0;
}

/// Accepts only the empty payload; the op carries no bytes.
pub fn decodeEmpty(src: []const u8) PayloadError!void {
    if (src.len != 0) return error.TrailingBytes;
}

pub fn encodeNop(dst: []u8) PayloadError!usize {
    return encodeEmpty(dst);
}

pub fn decodeNop(src: []const u8) PayloadError!void {
    return decodeEmpty(src);
}

pub fn encodePulse(dst: []u8) PayloadError!usize {
    return encodeEmpty(dst);
}

pub fn decodePulse(src: []const u8) PayloadError!void {
    return decodeEmpty(src);
}

pub fn encodePulseAck(dst: []u8) PayloadError!usize {
    return encodeEmpty(dst);
}

pub fn decodePulseAck(src: []const u8) PayloadError!void {
    return decodeEmpty(src);
}

pub const EmergencyStopPayload = struct {
    level: u8,
};

pub const DecisionPayload = struct {
    state_id: u128,
    decision: DecisionKind,
};

pub fn encodeEmergencyStop(dst: []u8, value: EmergencyStopPayload) PayloadError!usize {
    var w = PayloadWriter{ .dst = dst };
    try w.putScalar(value.level);
    return w.pos;
}

pub fn decodeEmergencyStop(src: []const u8) PayloadError!EmergencyStopPayload {
    var r = PayloadReader{ .src = src };
    const level = try r.scalar(u8);
    try r.expectEnd();
    return .{ .level = level };
}

/// The decision payload repeats the decided op's `stateID`. A control frame
/// carries no state fields, so this is the only copy on the wire; there is no
/// frame field to compare it with (§3.2).
pub fn encodeDecision(dst: []u8, value: DecisionPayload) PayloadError!usize {
    if (value.state_id == 0) return error.ZeroStateId;

    var w = PayloadWriter{ .dst = dst };
    try w.putU128(value.state_id);
    try w.putScalar(@as(u8, @backingInt(value.decision)));
    return w.pos;
}

pub fn decodeDecision(src: []const u8) PayloadError!DecisionPayload {
    var r = PayloadReader{ .src = src };
    const state_id = try r.getU128();
    if (state_id == 0) return error.ZeroStateId;

    const tag = try r.scalar(u8);
    if (tag > @backingInt(DecisionKind.data_integrity_violated)) {
        return error.UnknownDecisionKind;
    }
    try r.expectEnd();

    return .{ .state_id = state_id, .decision = @fromBackingInt(tag) };
}

/// The `LogDelivery` oneof tags. These numeric values are the wire tags.
pub const LogDeliveryTag = enum(u8) {
    out_of_date = 0,
    log_data = 1,
    delivery_failure = 2,
};

pub const LogDelivery = union(LogDeliveryTag) {
    out_of_date: struct { state_id: u128 },
    log_data: struct { data: []const u8, final: bool },
    delivery_failure: struct { diag: []const u8 },
};

/// The `SnapshotDelivery` oneof tags. These numeric values are the wire tags.
pub const SnapshotDeliveryTag = enum(u8) {
    snapshot = 0,
    log = 1,
    delivery_failure = 2,
};

pub const SnapshotDelivery = union(SnapshotDeliveryTag) {
    snapshot: struct { data: []const u8, final: bool },
    log: struct { data: []const u8, final: bool },
    delivery_failure: struct { diag: []const u8 },
};

fn writeLogDelivery(w: *PayloadWriter, value: LogDelivery) PayloadError!void {
    switch (value) {
        .out_of_date => |arm| {
            try w.putScalar(@as(u8, @backingInt(LogDeliveryTag.out_of_date)));
            try w.putU128(arm.state_id);
        },
        .log_data => |arm| {
            try w.putScalar(@as(u8, @backingInt(LogDeliveryTag.log_data)));
            try w.putBytes(arm.data);
            try w.putBool(arm.final);
        },
        .delivery_failure => |arm| {
            try w.putScalar(@as(u8, @backingInt(LogDeliveryTag.delivery_failure)));
            try w.putDiag(arm.diag);
        },
    }
}

fn readLogDelivery(r: *PayloadReader) PayloadError!LogDelivery {
    return switch (try r.scalar(u8)) {
        @backingInt(LogDeliveryTag.out_of_date) => .{
            .out_of_date = .{ .state_id = try r.getU128() },
        },
        @backingInt(LogDeliveryTag.log_data) => blk: {
            const data = try r.bytes();
            const final = try r.boolean();
            break :blk .{ .log_data = .{ .data = data, .final = final } };
        },
        @backingInt(LogDeliveryTag.delivery_failure) => .{
            .delivery_failure = .{ .diag = try r.diag() },
        },
        else => error.UnknownOneofTag,
    };
}

fn writeSnapshotDelivery(w: *PayloadWriter, value: SnapshotDelivery) PayloadError!void {
    switch (value) {
        .snapshot => |arm| {
            if (arm.final) return error.SnapshotFinalViolation;
            try w.putScalar(@as(u8, @backingInt(SnapshotDeliveryTag.snapshot)));
            try w.putBytes(arm.data);
            try w.putBool(arm.final);
        },
        .log => |arm| {
            try w.putScalar(@as(u8, @backingInt(SnapshotDeliveryTag.log)));
            try w.putBytes(arm.data);
            try w.putBool(arm.final);
        },
        .delivery_failure => |arm| {
            try w.putScalar(@as(u8, @backingInt(SnapshotDeliveryTag.delivery_failure)));
            try w.putDiag(arm.diag);
        },
    }
}

fn readSnapshotDelivery(r: *PayloadReader) PayloadError!SnapshotDelivery {
    return switch (try r.scalar(u8)) {
        @backingInt(SnapshotDeliveryTag.snapshot) => blk: {
            const data = try r.bytes();
            const final = try r.boolean();
            if (final) return error.SnapshotFinalViolation;
            break :blk .{ .snapshot = .{ .data = data, .final = final } };
        },
        @backingInt(SnapshotDeliveryTag.log) => blk: {
            const data = try r.bytes();
            const final = try r.boolean();
            break :blk .{ .log = .{ .data = data, .final = final } };
        },
        @backingInt(SnapshotDeliveryTag.delivery_failure) => .{
            .delivery_failure = .{ .diag = try r.diag() },
        },
        else => error.UnknownOneofTag,
    };
}

pub fn encodeLogDelivery(dst: []u8, value: LogDelivery) PayloadError!usize {
    var w = PayloadWriter{ .dst = dst };
    try writeLogDelivery(&w, value);
    return w.pos;
}

pub fn decodeLogDelivery(src: []const u8) PayloadError!LogDelivery {
    var r = PayloadReader{ .src = src };
    const value = try readLogDelivery(&r);
    try r.expectEnd();
    return value;
}

pub fn encodeSnapshotDelivery(dst: []u8, value: SnapshotDelivery) PayloadError!usize {
    var w = PayloadWriter{ .dst = dst };
    try writeSnapshotDelivery(&w, value);
    return w.pos;
}

pub fn decodeSnapshotDelivery(src: []const u8) PayloadError!SnapshotDelivery {
    var r = PayloadReader{ .src = src };
    const value = try readSnapshotDelivery(&r);
    try r.expectEnd();
    return value;
}

pub const DeliverLogPayload = struct {
    host_id: u8,
    after_state_id: u128,
};

pub const DeliverLogResponsePayload = struct {
    host_id: u8,
    seq_id: u32,
    data: LogDelivery,
};

pub const DeliverLogCommitPayload = struct {
    host_id: u8,
    seq_id: u32,
};

pub const DeliverSnapshotPayload = struct {
    host_id: u8,
};

pub const DeliverSnapshotResponsePayload = struct {
    host_id: u8,
    seq_id: u32,
    data: SnapshotDelivery,
};

pub const DeliverSnapshotCommitPayload = struct {
    host_id: u8,
    seq_id: u32,
};

pub fn encodeDeliverLog(dst: []u8, value: DeliverLogPayload) PayloadError!usize {
    var w = PayloadWriter{ .dst = dst };
    try w.putScalar(value.host_id);
    try w.putU128(value.after_state_id);
    return w.pos;
}

pub fn decodeDeliverLog(src: []const u8) PayloadError!DeliverLogPayload {
    var r = PayloadReader{ .src = src };
    const host_id = try r.scalar(u8);
    const after_state_id = try r.getU128();
    try r.expectEnd();
    return .{ .host_id = host_id, .after_state_id = after_state_id };
}

pub fn encodeDeliverLogResponse(dst: []u8, value: DeliverLogResponsePayload) PayloadError!usize {
    var w = PayloadWriter{ .dst = dst };
    try w.putScalar(value.host_id);
    try w.putScalar(value.seq_id);
    try writeLogDelivery(&w, value.data);
    return w.pos;
}

pub fn decodeDeliverLogResponse(src: []const u8) PayloadError!DeliverLogResponsePayload {
    var r = PayloadReader{ .src = src };
    const host_id = try r.scalar(u8);
    const seq_id = try r.scalar(u32);
    const data = try readLogDelivery(&r);
    try r.expectEnd();
    return .{ .host_id = host_id, .seq_id = seq_id, .data = data };
}

pub fn encodeDeliverLogCommit(dst: []u8, value: DeliverLogCommitPayload) PayloadError!usize {
    var w = PayloadWriter{ .dst = dst };
    try w.putScalar(value.host_id);
    try w.putScalar(value.seq_id);
    return w.pos;
}

pub fn decodeDeliverLogCommit(src: []const u8) PayloadError!DeliverLogCommitPayload {
    var r = PayloadReader{ .src = src };
    const host_id = try r.scalar(u8);
    const seq_id = try r.scalar(u32);
    try r.expectEnd();
    return .{ .host_id = host_id, .seq_id = seq_id };
}

pub fn encodeDeliverSnapshot(dst: []u8, value: DeliverSnapshotPayload) PayloadError!usize {
    var w = PayloadWriter{ .dst = dst };
    try w.putScalar(value.host_id);
    return w.pos;
}

pub fn decodeDeliverSnapshot(src: []const u8) PayloadError!DeliverSnapshotPayload {
    var r = PayloadReader{ .src = src };
    const host_id = try r.scalar(u8);
    try r.expectEnd();
    return .{ .host_id = host_id };
}

pub fn encodeDeliverSnapshotResponse(dst: []u8, value: DeliverSnapshotResponsePayload) PayloadError!usize {
    var w = PayloadWriter{ .dst = dst };
    try w.putScalar(value.host_id);
    try w.putScalar(value.seq_id);
    try writeSnapshotDelivery(&w, value.data);
    return w.pos;
}

pub fn decodeDeliverSnapshotResponse(src: []const u8) PayloadError!DeliverSnapshotResponsePayload {
    var r = PayloadReader{ .src = src };
    const host_id = try r.scalar(u8);
    const seq_id = try r.scalar(u32);
    const data = try readSnapshotDelivery(&r);
    try r.expectEnd();
    return .{ .host_id = host_id, .seq_id = seq_id, .data = data };
}

pub fn encodeDeliverSnapshotCommit(dst: []u8, value: DeliverSnapshotCommitPayload) PayloadError!usize {
    var w = PayloadWriter{ .dst = dst };
    try w.putScalar(value.host_id);
    try w.putScalar(value.seq_id);
    return w.pos;
}

pub fn decodeDeliverSnapshotCommit(src: []const u8) PayloadError!DeliverSnapshotCommitPayload {
    var r = PayloadReader{ .src = src };
    const host_id = try r.scalar(u8);
    const seq_id = try r.scalar(u32);
    try r.expectEnd();
    return .{ .host_id = host_id, .seq_id = seq_id };
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
    try expectEqual(@as(u8, 0x02), OP_EMERGENCY_STOP);
    try expectEqual(@as(u8, 0x03), OP_DECISION);

    try expectEqual(@as(u8, 0x10), OP_DELIVER_LOG);
    try expectEqual(@as(u8, 0x11), OP_DELIVER_LOG_RESPONSE);
    try expectEqual(@as(u8, 0x12), OP_DELIVER_LOG_COMMIT);
    try expectEqual(@as(u8, 0x13), OP_DELIVER_SNAPSHOT);
    try expectEqual(@as(u8, 0x14), OP_DELIVER_SNAPSHOT_RESPONSE);
    try expectEqual(@as(u8, 0x15), OP_DELIVER_SNAPSHOT_COMMIT);

    try expectEqual(@as(u8, 0x20), OP_CREATE);
    try expectEqual(@as(u8, 0x21), OP_APPEND);
    try expectEqual(@as(u8, 0x22), OP_OVERWRITE);
    try expectEqual(@as(u8, 0x23), OP_CLOSE);
    try expectEqual(@as(u8, 0x24), OP_REPEAT);
    try expectEqual(@as(u8, 0x25), OP_COMPENSATE);
    try expectEqual(@as(u8, 0x26), OP_ISOLATE);
    try expectEqual(@as(u8, 0x27), OP_CAPTURE);
    try expectEqual(@as(u8, 0x28), OP_CAPTURE_COMPENSATE);
    try expectEqual(@as(u8, 0x29), OP_NOP);

    try expectEqual(@as(u8, 0), @backingInt(DecisionKind.confirmed));
    try expectEqual(@as(u8, 1), @backingInt(DecisionKind.rejected_update_yourself));
    try expectEqual(@as(u8, 2), @backingInt(DecisionKind.rejected_you_are_late));
    try expectEqual(@as(u8, 3), @backingInt(DecisionKind.data_integrity_violated));

    try expectEqual(@as(usize, 23), frameMin(.control));
    try expectEqual(@as(usize, 23), frameMin(.transport));
    try expectEqual(@as(usize, 56), frameMin(.consensus));

    try expectEqual(@as(u8, 0), @backingInt(LinkState.none));
    try expectEqual(@as(u8, 1), @backingInt(LinkState.greeting));
    try expectEqual(@as(u8, 2), @backingInt(LinkState.parked));
    try expectEqual(@as(u8, 3), @backingInt(LinkState.up));
}

test "every op code maps to its wire class" {
    try expectEqual(@as(?FrameClass, .control), frameClass(OP_PULSE));
    try expectEqual(@as(?FrameClass, .control), frameClass(OP_PULSE_ACK));
    try expectEqual(@as(?FrameClass, .control), frameClass(OP_EMERGENCY_STOP));
    try expectEqual(@as(?FrameClass, .control), frameClass(OP_DECISION));

    try expectEqual(@as(?FrameClass, .transport), frameClass(OP_DELIVER_LOG));
    try expectEqual(@as(?FrameClass, .transport), frameClass(OP_DELIVER_LOG_RESPONSE));
    try expectEqual(@as(?FrameClass, .transport), frameClass(OP_DELIVER_LOG_COMMIT));
    try expectEqual(@as(?FrameClass, .transport), frameClass(OP_DELIVER_SNAPSHOT));
    try expectEqual(@as(?FrameClass, .transport), frameClass(OP_DELIVER_SNAPSHOT_RESPONSE));
    try expectEqual(@as(?FrameClass, .transport), frameClass(OP_DELIVER_SNAPSHOT_COMMIT));

    try expectEqual(@as(?FrameClass, .consensus), frameClass(OP_CREATE));
    try expectEqual(@as(?FrameClass, .consensus), frameClass(OP_APPEND));
    try expectEqual(@as(?FrameClass, .consensus), frameClass(OP_OVERWRITE));
    try expectEqual(@as(?FrameClass, .consensus), frameClass(OP_CLOSE));
    try expectEqual(@as(?FrameClass, .consensus), frameClass(OP_REPEAT));
    try expectEqual(@as(?FrameClass, .consensus), frameClass(OP_COMPENSATE));
    try expectEqual(@as(?FrameClass, .consensus), frameClass(OP_ISOLATE));
    try expectEqual(@as(?FrameClass, .consensus), frameClass(OP_CAPTURE));
    try expectEqual(@as(?FrameClass, .consensus), frameClass(OP_CAPTURE_COMPENSATE));
    try expectEqual(@as(?FrameClass, .consensus), frameClass(OP_NOP));

    // Reserved values inside a valid range still belong to that class.
    try expectEqual(@as(?FrameClass, .control), frameClass(0x04));
    try expectEqual(@as(?FrameClass, .control), frameClass(0x0F));
    try expectEqual(@as(?FrameClass, .transport), frameClass(0x16));
    try expectEqual(@as(?FrameClass, .transport), frameClass(0x1F));
    try expectEqual(@as(?FrameClass, .consensus), frameClass(0x2A));
    try expectEqual(@as(?FrameClass, .consensus), frameClass(0x7F));

    // `0x80..0xFF` has no class.
    try expectEqual(@as(?FrameClass, null), frameClass(0x80));
    try expectEqual(@as(?FrameClass, null), frameClass(0xFF));
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
    try expect(!frameLenValid(22));
    try expect(frameLenValid(23));
    try expect(frameLenValid(24));
    try expect(frameLenValid(4096));
    try expect(!frameLenValid(4097));

    // The broad bound is class-blind; the companion applies the op's own
    // minimum (§2.3).
    try expect(frameLenValidFor(OP_PULSE, 23));
    try expect(!frameLenValidFor(OP_PULSE, 22));
    try expect(frameLenValidFor(OP_DELIVER_LOG, 23));
    try expect(!frameLenValidFor(OP_NOP, 55));
    try expect(frameLenValidFor(OP_NOP, 56));
    try expect(frameLenValidFor(OP_NOP, 4096));
    try expect(!frameLenValidFor(OP_NOP, 4097));
    try expect(!frameLenValidFor(0x80, 56));
}

test "a consensus layout is state fields, payload, then the envelope" {
    var dst: [FRAME_CAP]u8 = undefined;
    const payload = [_]u8{ 0xAA, 0xBB, 0xCC };
    const state: u128 = 0x0102_0304_0506_0708_1112_1314_1516_1718;
    const prev_state: u128 = 0x2122_2324_2526_2728_3132_3334_3536_3738;

    const len = try encodeFrame(&dst, .{
        .seq_id = 0x1234,
        .vector_clock_frame = .{ .host_idx = 7, .state = state },
        .op_code = OP_CREATE,
        .op_payload = &payload,
        .state_id = state,
        .prev_state_id = prev_state,
        .commit_envelope = .{ .start_state_idx = prev_state, .decisions = &.{0x05} },
    });

    try expectEqual(@as(usize, 76), len);

    // Prefix.
    try expectEqual(@as(u8, 0x34), dst[0]);
    try expectEqual(@as(u8, 0x12), dst[1]);
    try expectEqual(@as(u16, 76), std.mem.readInt(u16, dst[2..4], .little));

    // Vector clock: host byte, then the low and the high half, both little
    // endian.
    try expectEqual(@as(u8, 7), dst[4]);
    try expectEqual(@as(u64, 0x1112_1314_1516_1718), std.mem.readInt(u64, dst[5..13], .little));
    try expectEqual(@as(u64, 0x0102_0304_0506_0708), std.mem.readInt(u64, dst[13..21], .little));

    // Op code, then the two state fields, low half first.
    try expectEqual(@as(u8, OP_CREATE), dst[21]);
    try expectEqual(@as(u64, 0x1112_1314_1516_1718), std.mem.readInt(u64, dst[22..30], .little));
    try expectEqual(@as(u64, 0x0102_0304_0506_0708), std.mem.readInt(u64, dst[30..38], .little));
    try expectEqual(@as(u64, 0x3132_3334_3536_3738), std.mem.readInt(u64, dst[38..46], .little));
    try expectEqual(@as(u64, 0x2122_2324_2526_2728), std.mem.readInt(u64, dst[46..54], .little));

    // Payload behind its own uvarint length at 54.
    try expectEqual(@as(u8, 3), dst[54]);
    try expectEqualSlices(u8, &payload, dst[55..58]);

    // Envelope: count, the start state as two halves, then the raw bitmap.
    try expectEqual(@as(u8, 1), dst[58]);
    try expectEqual(@as(u64, 0x3132_3334_3536_3738), std.mem.readInt(u64, dst[59..67], .little));
    try expectEqual(@as(u64, 0x2122_2324_2526_2728), std.mem.readInt(u64, dst[67..75], .little));
    try expectEqual(@as(u8, 0x05), dst[75]);
}

test "a control frame is the broad minimum and ends after its payload" {
    var dst: [FRAME_CAP]u8 = undefined;
    const len = try encodeFrame(&dst, .{
        .seq_id = 0,
        .vector_clock_frame = .{ .host_idx = 0, .state = 0 },
        .op_code = OP_PULSE,
        .op_payload = &.{},
    });

    try expectEqual(FRAME_MIN, len);
    try expectEqual(@as(u16, FRAME_MIN), std.mem.readInt(u16, dst[2..4], .little));
    try expectEqual(@as(u8, OP_PULSE), dst[21]);
    try expectEqual(@as(u8, 0x00), dst[22]);
}

test "a consensus bitmap is a raw copy at the envelope tail" {
    var dst: [FRAME_CAP]u8 = undefined;
    const len = try encodeFrame(&dst, .{
        .seq_id = 0,
        .vector_clock_frame = .{ .host_idx = 0, .state = 0 },
        .op_code = OP_NOP,
        .op_payload = &.{},
        .state_id = 1,
        .prev_state_id = 0,
        .commit_envelope = .{ .decisions = &.{ 0x02, 0x00 } },
    });

    // 54 state fields + 1 empty payload + 1 count + 16 start + 2 bits.
    try expectEqual(@as(usize, 74), len);
    try expectEqual(@as(u8, 0x00), dst[54]);
    try expectEqual(@as(u8, 2), dst[55]);
    try expectEqual(@as(u64, 0), std.mem.readInt(u64, dst[56..64], .little));
    try expectEqual(@as(u64, 0), std.mem.readInt(u64, dst[64..72], .little));
    try expectEqual(@as(u8, 0x02), dst[72]);
    try expectEqual(@as(u8, 0x00), dst[73]);
}

test "every encode back-patches its own validated length" {
    var dst: [FRAME_CAP]u8 = undefined;
    var payload: [1000]u8 = undefined;
    @memset(&payload, 0x5A);

    for ([_]usize{ 0, 1, 127, 128, 1000 }) |payload_len| {
        const len = try encodeFrame(&dst, .{
            .seq_id = 9,
            .vector_clock_frame = .{ .host_idx = 4, .state = 0xDEAD_BEEF },
            .op_code = OP_PULSE,
            .op_payload = payload[0..payload_len],
        });

        try expect(frameLenValid(len));
        try expect(frameLenValidFor(OP_PULSE, len));
        try expectEqual(@as(u16, @intCast(len)), std.mem.readInt(u16, dst[2..4], .little));
        try expectEqual(@as(u16, 9), std.mem.readInt(u16, dst[0..2], .little));
    }

    for ([_]usize{ 0, 1, 127, 128, 1000 }) |payload_len| {
        for ([_]usize{ 0, 1, 2 }) |decisions_len| {
            var decisions: [2]u8 = undefined;
            @memset(&decisions, 0x01);

            const len = try encodeFrame(&dst, .{
                .seq_id = 9,
                .vector_clock_frame = .{ .host_idx = 4, .state = 0xDEAD_BEEF },
                .op_code = OP_NOP,
                .op_payload = payload[0..payload_len],
                .state_id = 0xDEAD_BEEF,
                .prev_state_id = 1,
                .commit_envelope = .{ .decisions = decisions[0..decisions_len] },
            });

            try expect(frameLenValid(len));
            try expect(frameLenValidFor(OP_NOP, len));
            try expectEqual(@as(u16, @intCast(len)), std.mem.readInt(u16, dst[2..4], .little));
            try expectEqual(@as(u16, 9), std.mem.readInt(u16, dst[0..2], .little));
        }
    }
}

test "the frame cap is exact and one byte over is refused" {
    var dst: [FRAME_CAP]u8 = undefined;
    var payload: [FRAME_CAP]u8 = undefined;
    @memset(&payload, 0);

    // Control: 22 prefix + 2 length + 4072 = 4096.
    const full = try encodeFrame(&dst, .{
        .seq_id = 0,
        .vector_clock_frame = .{ .host_idx = 0, .state = 0 },
        .op_code = OP_PULSE,
        .op_payload = payload[0..4072],
    });
    try expectEqual(@as(usize, FRAME_CAP), full);

    try std.testing.expectError(error.FrameTooLarge, encodeFrame(&dst, .{
        .seq_id = 0,
        .vector_clock_frame = .{ .host_idx = 0, .state = 0 },
        .op_code = OP_PULSE,
        .op_payload = payload[0..4073],
    }));

    // Consensus: 54 prefix + 2 length + 4039 + 1 empty envelope = 4096.
    const consensus_full = try encodeFrame(&dst, .{
        .seq_id = 0,
        .vector_clock_frame = .{ .host_idx = 0, .state = 0 },
        .op_code = OP_NOP,
        .op_payload = payload[0..4039],
        .state_id = 1,
        .prev_state_id = 0,
    });
    try expectEqual(@as(usize, FRAME_CAP), consensus_full);

    try std.testing.expectError(error.FrameTooLarge, encodeFrame(&dst, .{
        .seq_id = 0,
        .vector_clock_frame = .{ .host_idx = 0, .state = 0 },
        .op_code = OP_NOP,
        .op_payload = payload[0..4040],
        .state_id = 1,
        .prev_state_id = 0,
    }));
}

test "a transport chunk carries at most 4063 data bytes" {
    var dst: [FRAME_CAP]u8 = undefined;
    var payload: [FRAME_CAP]u8 = undefined;
    var data: [CHUNK_DATA_MAX + 1]u8 = undefined;
    @memset(&data, 0x5a);

    // 22 prefix + 2 payload length + 1 host_id + 4 seq_id + 1 tag
    // + 2 data length + 4063 data + 1 final = 4096.
    const full_value = DeliverLogResponsePayload{
        .host_id = 3,
        .seq_id = 1,
        .data = .{ .log_data = .{ .data = data[0..CHUNK_DATA_MAX], .final = true } },
    };
    const payload_len = try encodeDeliverLogResponse(&payload, full_value);
    try expectEqual(@as(usize, 4072), payload_len);

    const full = try encodeFrame(&dst, .{
        .seq_id = 0x1234,
        .vector_clock_frame = .{ .host_idx = 3, .state = 1 },
        .op_code = OP_DELIVER_LOG_RESPONSE,
        .op_payload = payload[0..payload_len],
    });
    try expectEqual(@as(usize, FRAME_CAP), full);

    // One more data byte makes the same frame 4097, which the cap refuses.
    const over_value = DeliverLogResponsePayload{
        .host_id = 3,
        .seq_id = 2,
        .data = .{ .log_data = .{ .data = data[0 .. CHUNK_DATA_MAX + 1], .final = true } },
    };
    const over_len = try encodeDeliverLogResponse(&payload, over_value);
    try expectEqual(@as(usize, 4073), over_len);

    try std.testing.expectError(error.FrameTooLarge, encodeFrame(&dst, .{
        .seq_id = 0x1234,
        .vector_clock_frame = .{ .host_idx = 3, .state = 1 },
        .op_code = OP_DELIVER_LOG_RESPONSE,
        .op_payload = payload[0..over_len],
    }));

    // The snapshot response shares the overhead, so a `Snapshot` arm at the
    // bound is exactly 4096 as well.
    const snapshot_value = DeliverSnapshotResponsePayload{
        .host_id = 3,
        .seq_id = 3,
        .data = .{ .snapshot = .{ .data = data[0..CHUNK_DATA_MAX], .final = false } },
    };
    const snapshot_len = try encodeDeliverSnapshotResponse(&payload, snapshot_value);
    try expectEqual(@as(usize, 4072), snapshot_len);

    const snapshot_full = try encodeFrame(&dst, .{
        .seq_id = 0x1234,
        .vector_clock_frame = .{ .host_idx = 3, .state = 1 },
        .op_code = OP_DELIVER_SNAPSHOT_RESPONSE,
        .op_payload = payload[0..snapshot_len],
    });
    try expectEqual(@as(usize, FRAME_CAP), snapshot_full);
}

test "a frame's optional fields must agree with its class" {
    var dst: [FRAME_CAP]u8 = undefined;

    // A consensus frame needs both state fields.
    try std.testing.expectError(error.FrameClassMismatch, encodeFrame(&dst, .{
        .seq_id = 0,
        .vector_clock_frame = .{ .host_idx = 0, .state = 0 },
        .op_code = OP_NOP,
        .op_payload = &.{},
    }));
    try std.testing.expectError(error.FrameClassMismatch, encodeFrame(&dst, .{
        .seq_id = 0,
        .vector_clock_frame = .{ .host_idx = 0, .state = 0 },
        .op_code = OP_NOP,
        .op_payload = &.{},
        .state_id = 1,
    }));

    // A control frame carries neither state field.
    try std.testing.expectError(error.FrameClassMismatch, encodeFrame(&dst, .{
        .seq_id = 0,
        .vector_clock_frame = .{ .host_idx = 0, .state = 0 },
        .op_code = OP_PULSE,
        .op_payload = &.{},
        .state_id = 1,
        .prev_state_id = 0,
    }));

    // Neither a control nor a transport frame carries an envelope, even an
    // empty one.
    try std.testing.expectError(error.FrameClassMismatch, encodeFrame(&dst, .{
        .seq_id = 0,
        .vector_clock_frame = .{ .host_idx = 0, .state = 0 },
        .op_code = OP_PULSE,
        .op_payload = &.{},
        .commit_envelope = .{},
    }));
    try std.testing.expectError(error.FrameClassMismatch, encodeFrame(&dst, .{
        .seq_id = 0,
        .vector_clock_frame = .{ .host_idx = 0, .state = 0 },
        .op_code = OP_DELIVER_LOG,
        .op_payload = &.{},
        .commit_envelope = .{},
    }));

    // An op outside every class has no layout to encode.
    try std.testing.expectError(error.InvalidOpCode, encodeFrame(&dst, .{
        .seq_id = 0,
        .vector_clock_frame = .{ .host_idx = 0, .state = 0 },
        .op_code = 0x80,
        .op_payload = &.{},
    }));
}

test "the conformance vectors match byte for byte" {
    var dst: [FRAME_CAP]u8 = undefined;
    var payload: [64]u8 = undefined;

    const pulse_vector = [_]u8{
        0x34, 0x12, 0x17, 0x00, 0x03, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    const pulse_len = try encodeFrame(&dst, .{
        .seq_id = 0x1234,
        .vector_clock_frame = .{ .host_idx = 3, .state = 1 },
        .op_code = OP_PULSE,
        .op_payload = &.{},
    });
    try expectEqual(@as(usize, 23), pulse_len);
    try expectEqualSlices(u8, &pulse_vector, dst[0..pulse_len]);

    const decision_vector = [_]u8{
        0x34, 0x12, 0x28, 0x00, 0x03, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x11, 0x01,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    };
    const decision_payload = try encodeDecision(&payload, .{
        .state_id = 1,
        .decision = .confirmed,
    });
    const decision_len = try encodeFrame(&dst, .{
        .seq_id = 0x1234,
        .vector_clock_frame = .{ .host_idx = 3, .state = 1 },
        .op_code = OP_DECISION,
        .op_payload = payload[0..decision_payload],
    });
    try expectEqual(@as(usize, 40), decision_len);
    try expectEqualSlices(u8, &decision_vector, dst[0..decision_len]);

    const stop_vector = [_]u8{
        0x34, 0x12, 0x18, 0x00, 0x03, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x01, 0x01,
    };
    const stop_payload = try encodeEmergencyStop(&payload, .{ .level = 1 });
    const stop_len = try encodeFrame(&dst, .{
        .seq_id = 0x1234,
        .vector_clock_frame = .{ .host_idx = 3, .state = 1 },
        .op_code = OP_EMERGENCY_STOP,
        .op_payload = payload[0..stop_payload],
    });
    try expectEqual(@as(usize, 24), stop_len);
    try expectEqualSlices(u8, &stop_vector, dst[0..stop_len]);
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
    try expect(!entry.fd.isHeld());
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
    entry.fd = res_handle.adopt(7);
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
    try expectEqual(@as(posix.fd_t, 7), res_handle.borrow(&entry.fd));
    try expectEqual(LinkState.up, entry.state);
}
test "every consensus payload round-trips" {
    var buf: [FRAME_CAP]u8 = undefined;

    {
        const value = CreatePayload{ .compensator = "compensator", .payload = "create" };
        const len = try encodeCreate(&buf, value);
        const got = try decodeCreate(buf[0..len]);
        try expectEqualSlices(u8, value.compensator, got.compensator);
        try expectEqualSlices(u8, value.payload, got.payload);
    }
    {
        const value = AppendPayload{
            .session_id = 0x0102_0304_0506_0708_1112_1314_1516_1718,
            .payload = "append",
        };
        const len = try encodeAppend(&buf, value);
        const got = try decodeAppend(buf[0..len]);
        try expectEqual(value.session_id, got.session_id);
        try expectEqualSlices(u8, value.payload, got.payload);
    }
    {
        const value = OverwritePayload{
            .session_id = 0x2122_2324_2526_2728_3132_3334_3536_3738,
            .payload = "overwrite",
        };
        const len = try encodeOverwrite(&buf, value);
        const got = try decodeOverwrite(buf[0..len]);
        try expectEqual(value.session_id, got.session_id);
        try expectEqualSlices(u8, value.payload, got.payload);
    }
    {
        const value = ClosePayload{ .session_id = 7 };
        const len = try encodeClose(&buf, value);
        try expectEqual(@as(usize, 16), len);
        try expectEqual(value.session_id, (try decodeClose(buf[0..len])).session_id);
    }
    {
        const value = RepeatPayload{ .session_id = 8, .timeout_seconds = 30 };
        const len = try encodeRepeat(&buf, value);
        try expectEqual(@as(usize, 20), len);
        const got = try decodeRepeat(buf[0..len]);
        try expectEqual(value.session_id, got.session_id);
        try expectEqual(value.timeout_seconds, got.timeout_seconds);
    }
    {
        const value = CompensatePayload{ .new_id = 9, .original_id = 10 };
        const len = try encodeCompensate(&buf, value);
        try expectEqual(@as(usize, 32), len);
        const got = try decodeCompensate(buf[0..len]);
        try expectEqual(value.new_id, got.new_id);
        try expectEqual(value.original_id, got.original_id);
    }
    {
        const value = IsolatePayload{ .host_id = 3, .lost_host_state_id = 11 };
        const len = try encodeIsolate(&buf, value);
        try expectEqual(@as(usize, 17), len);
        const got = try decodeIsolate(buf[0..len]);
        try expectEqual(value.host_id, got.host_id);
        try expectEqual(value.lost_host_state_id, got.lost_host_state_id);
    }
    {
        const value = CapturePayload{
            .lost_host_id = 1,
            .host_id = 2,
            .host_state_id = 12,
            .n = 4,
            .timeout_seconds = 5,
        };
        const len = try encodeCapture(&buf, value);
        try expectEqual(@as(usize, 26), len);
        const got = try decodeCapture(buf[0..len]);
        try expectEqual(value.lost_host_id, got.lost_host_id);
        try expectEqual(value.host_id, got.host_id);
        try expectEqual(value.host_state_id, got.host_state_id);
        try expectEqual(value.n, got.n);
        try expectEqual(value.timeout_seconds, got.timeout_seconds);
    }
    {
        const value = CaptureCompensatePayload{
            .lost_host_id = 6,
            .host_id = 7,
            .host_state_id = 13,
            .n = 8,
        };
        const len = try encodeCaptureCompensate(&buf, value);
        try expectEqual(@as(usize, 22), len);
        const got = try decodeCaptureCompensate(buf[0..len]);
        try expectEqual(value.lost_host_id, got.lost_host_id);
        try expectEqual(value.host_id, got.host_id);
        try expectEqual(value.host_state_id, got.host_state_id);
        try expectEqual(value.n, got.n);
    }
    {
        const len = try encodeNop(&buf);
        try expectEqual(@as(usize, 0), len);
        try decodeNop(buf[0..len]);
    }
}

test "every control payload round-trips" {
    var buf: [FRAME_CAP]u8 = undefined;

    const pulse_len = try encodePulse(&buf);
    try expectEqual(@as(usize, 0), pulse_len);
    try decodePulse(buf[0..pulse_len]);

    const ack_len = try encodePulseAck(&buf);
    try expectEqual(@as(usize, 0), ack_len);
    try decodePulseAck(buf[0..ack_len]);

    const stop_len = try encodeEmergencyStop(&buf, .{ .level = 4 });
    try expectEqual(@as(usize, 1), stop_len);
    try expectEqual(@as(u8, 4), (try decodeEmergencyStop(buf[0..stop_len])).level);

    const decision_len = try encodeDecision(&buf, .{
        .state_id = 0x0102_0304_0506_0708_1112_1314_1516_1718,
        .decision = .rejected_you_are_late,
    });
    try expectEqual(@as(usize, 17), decision_len);
    const decision = try decodeDecision(buf[0..decision_len]);
    try expectEqual(
        @as(u128, 0x0102_0304_0506_0708_1112_1314_1516_1718),
        decision.state_id,
    );
    try expectEqual(DecisionKind.rejected_you_are_late, decision.decision);
}

test "every transport payload round-trips" {
    var buf: [FRAME_CAP]u8 = undefined;

    {
        const value = DeliverLogPayload{ .host_id = 3, .after_state_id = 14 };
        const len = try encodeDeliverLog(&buf, value);
        try expectEqual(@as(usize, 17), len);
        const got = try decodeDeliverLog(buf[0..len]);
        try expectEqual(value.host_id, got.host_id);
        try expectEqual(value.after_state_id, got.after_state_id);
    }
    {
        const value = DeliverLogResponsePayload{
            .host_id = 4,
            .seq_id = 9,
            .data = .{ .out_of_date = .{ .state_id = 15 } },
        };
        const len = try encodeDeliverLogResponse(&buf, value);
        try expectEqual(@as(usize, 1 + 4 + 1 + 16), len);
        const got = try decodeDeliverLogResponse(buf[0..len]);
        try expectEqual(value.host_id, got.host_id);
        try expectEqual(value.seq_id, got.seq_id);
        try expectEqual(value.data.out_of_date.state_id, got.data.out_of_date.state_id);
    }
    {
        const value = DeliverLogResponsePayload{
            .host_id = 4,
            .seq_id = 10,
            .data = .{ .log_data = .{ .data = "chunk", .final = true } },
        };
        const len = try encodeDeliverLogResponse(&buf, value);
        const got = try decodeDeliverLogResponse(buf[0..len]);
        try expectEqual(value.seq_id, got.seq_id);
        try expectEqualSlices(u8, value.data.log_data.data, got.data.log_data.data);
        try expectEqual(value.data.log_data.final, got.data.log_data.final);
    }
    {
        const value = DeliverLogResponsePayload{
            .host_id = 4,
            .seq_id = 11,
            .data = .{ .delivery_failure = .{ .diag = "gone" } },
        };
        const len = try encodeDeliverLogResponse(&buf, value);
        const got = try decodeDeliverLogResponse(buf[0..len]);
        try expectEqualSlices(u8, value.data.delivery_failure.diag, got.data.delivery_failure.diag);
    }
    {
        const value = DeliverLogCommitPayload{ .host_id = 5, .seq_id = 12 };
        const len = try encodeDeliverLogCommit(&buf, value);
        try expectEqual(@as(usize, 5), len);
        const got = try decodeDeliverLogCommit(buf[0..len]);
        try expectEqual(value.host_id, got.host_id);
        try expectEqual(value.seq_id, got.seq_id);
    }
    {
        const value = DeliverSnapshotPayload{ .host_id = 6 };
        const len = try encodeDeliverSnapshot(&buf, value);
        try expectEqual(@as(usize, 1), len);
        try expectEqual(value.host_id, (try decodeDeliverSnapshot(buf[0..len])).host_id);
    }
    {
        const value = DeliverSnapshotResponsePayload{
            .host_id = 7,
            .seq_id = 13,
            .data = .{ .snapshot = .{ .data = "snapshot", .final = false } },
        };
        const len = try encodeDeliverSnapshotResponse(&buf, value);
        const got = try decodeDeliverSnapshotResponse(buf[0..len]);
        try expectEqual(value.seq_id, got.seq_id);
        try expectEqualSlices(u8, value.data.snapshot.data, got.data.snapshot.data);
        try expectEqual(value.data.snapshot.final, got.data.snapshot.final);
    }
    {
        const value = DeliverSnapshotResponsePayload{
            .host_id = 7,
            .seq_id = 14,
            .data = .{ .log = .{ .data = &.{}, .final = true } },
        };
        const len = try encodeDeliverSnapshotResponse(&buf, value);
        const got = try decodeDeliverSnapshotResponse(buf[0..len]);
        try expectEqual(@as(usize, 0), got.data.log.data.len);
        try expectEqual(true, got.data.log.final);
    }
    {
        const value = DeliverSnapshotResponsePayload{
            .host_id = 7,
            .seq_id = 15,
            .data = .{ .delivery_failure = .{ .diag = "unknowable" } },
        };
        const len = try encodeDeliverSnapshotResponse(&buf, value);
        const got = try decodeDeliverSnapshotResponse(buf[0..len]);
        try expectEqualSlices(u8, value.data.delivery_failure.diag, got.data.delivery_failure.diag);
    }
    {
        const value = DeliverSnapshotCommitPayload{ .host_id = 8, .seq_id = 16 };
        const len = try encodeDeliverSnapshotCommit(&buf, value);
        try expectEqual(@as(usize, 5), len);
        const got = try decodeDeliverSnapshotCommit(buf[0..len]);
        try expectEqual(value.host_id, got.host_id);
        try expectEqual(value.seq_id, got.seq_id);
    }
}

test "u128 scalars are written low half first" {
    var buf: [FRAME_CAP]u8 = undefined;
    const id: u128 = 0x0102_0304_0506_0708_1112_1314_1516_1718;

    const len = try encodeAppend(&buf, .{ .session_id = id, .payload = &.{} });
    try expectEqual(@as(usize, 17), len);
    try expectEqual(@as(u64, 0x1112_1314_1516_1718), std.mem.readInt(u64, buf[0..8], .little));
    try expectEqual(@as(u64, 0x0102_0304_0506_0708), std.mem.readInt(u64, buf[8..16], .little));
    try expectEqual(id, (try decodeAppend(buf[0..len])).session_id);
}

test "a zero-length variable field is one zero byte" {
    var buf: [FRAME_CAP]u8 = undefined;

    const len = try encodeCreate(&buf, .{ .compensator = &.{}, .payload = &.{} });
    try expectEqual(@as(usize, 2), len);
    try expectEqual(@as(u8, 0), buf[0]);
    try expectEqual(@as(u8, 0), buf[1]);

    const append_len = try encodeAppend(&buf, .{ .session_id = 1, .payload = &.{} });
    try expectEqual(@as(usize, 17), append_len);
    try expectEqual(@as(u8, 0), buf[16]);
}

test "a bool other than zero or one is malformed" {
    // LogData with an empty chunk and a final byte of 2.
    const malformed = [_]u8{ 1, 0x00, 0x02 };
    try std.testing.expectError(error.InvalidBool, decodeLogDelivery(&malformed));
}

test "invalid UTF-8 in a string is malformed" {
    var buf: [FRAME_CAP]u8 = undefined;
    buf[0] = 1;
    buf[1] = 0xFF;
    buf[2] = 0x00;
    try std.testing.expectError(error.InvalidUtf8, decodeCreate(buf[0..3]));

    // A diag validates the same way.
    const failure = [_]u8{ 2, 1, 0xFF };
    try std.testing.expectError(error.InvalidUtf8, decodeLogDelivery(&failure));
}

test "an unknown oneof tag is malformed" {
    const log_tag = [_]u8{3};
    try std.testing.expectError(error.UnknownOneofTag, decodeLogDelivery(&log_tag));

    const snapshot_tag = [_]u8{3};
    try std.testing.expectError(error.UnknownOneofTag, decodeSnapshotDelivery(&snapshot_tag));
}

test "an unknown DecisionKind tag is malformed" {
    var payload: [17]u8 = @splat(0);
    payload[0] = 1;
    payload[16] = 4;
    try std.testing.expectError(error.UnknownDecisionKind, decodeDecision(&payload));
}

test "a truncated oneof arm is malformed" {
    // OutOfDate announces its tag but carries four of the sixteen id bytes.
    const short = [_]u8{ 0, 1, 2, 3, 4 };
    try std.testing.expectError(error.TruncatedPayload, decodeLogDelivery(&short));

    // LogData announces a one-byte chunk and the payload ends before it.
    const missing = [_]u8{ 1, 1 };
    try std.testing.expectError(error.TruncatedPayload, decodeLogDelivery(&missing));
}

test "a payload with a trailing byte is malformed" {
    var buf: [FRAME_CAP]u8 = undefined;
    const len = try encodeClose(&buf, .{ .session_id = 1 });
    buf[len] = 0x00;
    try std.testing.expectError(error.TrailingBytes, decodeClose(buf[0 .. len + 1]));
}

test "a Snapshot arm with Final set is malformed" {
    var buf: [FRAME_CAP]u8 = undefined;
    try std.testing.expectError(error.SnapshotFinalViolation, encodeSnapshotDelivery(&buf, .{
        .snapshot = .{ .data = &.{}, .final = true },
    }));

    const final_snapshot = [_]u8{ 0, 0, 1 };
    try std.testing.expectError(error.SnapshotFinalViolation, decodeSnapshotDelivery(&final_snapshot));

    // The Log arm may be final; an empty final Log ends the transfer cleanly.
    const terminator = [_]u8{ 1, 0, 1 };
    const value = try decodeSnapshotDelivery(&terminator);
    try expectEqual(@as(usize, 0), value.log.data.len);
    try expectEqual(true, value.log.final);
}

test "Decision is the fixed 17-byte state id and kind" {
    var buf: [FRAME_CAP]u8 = undefined;
    const len = try encodeDecision(&buf, .{ .state_id = 1, .decision = .confirmed });
    try expectEqual(@as(usize, 17), len);
    try expectEqual(@as(u8, 1), buf[0]);
    try expectEqual(@as(u8, 0), buf[16]);

    // A control frame has no state field, so the standalone payload decode has
    // nothing to compare the repeated id with.
    const got = try decodeDecision(buf[0..len]);
    try expectEqual(@as(u128, 1), got.state_id);
    try expectEqual(DecisionKind.confirmed, got.decision);

    var zero_id: [17]u8 = @splat(0);
    zero_id[16] = 0;
    try std.testing.expectError(error.ZeroStateId, decodeDecision(&zero_id));
}

test "EmergencyStop is the single level byte" {
    var buf: [FRAME_CAP]u8 = undefined;
    const len = try encodeEmergencyStop(&buf, .{ .level = 7 });
    try expectEqual(@as(usize, 1), len);
    try expectEqual(@as(u8, 7), buf[0]);
    try expectEqual(@as(u8, 7), (try decodeEmergencyStop(buf[0..len])).level);
}

test "a zero capture count is malformed" {
    var buf: [FRAME_CAP]u8 = undefined;

    try std.testing.expectError(error.ZeroCount, encodeCapture(&buf, .{
        .lost_host_id = 1,
        .host_id = 2,
        .host_state_id = 3,
        .n = 0,
        .timeout_seconds = 5,
    }));

    var capture_bytes: [26]u8 = @splat(0);
    try std.testing.expectError(error.ZeroCount, decodeCapture(&capture_bytes));

    try std.testing.expectError(error.ZeroCount, encodeCaptureCompensate(&buf, .{
        .lost_host_id = 1,
        .host_id = 2,
        .host_state_id = 3,
        .n = 0,
    }));

    var compensate_bytes: [22]u8 = @splat(0);
    try std.testing.expectError(error.ZeroCount, decodeCaptureCompensate(&compensate_bytes));
}

test "a diag over the cap is malformed" {
    var over: [DIAG_CAP + 1]u8 = @splat('x');
    var buf: [FRAME_CAP]u8 = undefined;

    try std.testing.expectError(error.DiagTooLong, encodeLogDelivery(&buf, .{
        .delivery_failure = .{ .diag = &over },
    }));

    // Tag 2, then the two-byte varint for 257, then the bytes.
    var wire: [3 + DIAG_CAP + 1]u8 = undefined;
    wire[0] = 2;
    wire[1] = 0x81;
    wire[2] = 0x02;
    @memset(wire[3..], 'x');
    try std.testing.expectError(error.DiagTooLong, decodeLogDelivery(&wire));

    // Exactly the cap is legal.
    var at_cap: [DIAG_CAP]u8 = @splat('x');
    const len = try encodeLogDelivery(&buf, .{ .delivery_failure = .{ .diag = &at_cap } });
    const got = try decodeLogDelivery(buf[0..len]);
    try expectEqual(DIAG_CAP, got.delivery_failure.diag.len);
}
