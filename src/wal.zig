//! Write-ahead log: the battery layout, the file naming and the writer.
//!
//! Stages A to E of designs/wal-steps.md: the format constants, the
//! `BufferHeader` control line, the record framing, the block framing and its
//! CRC, the pair/area partition math, the path convention, the writer's
//! admission and copy pipeline over a plain battery, the stream-driven flush
//! with its stop and its `drain`, and PMEM mode — the battery's publishes
//! through `barrier.zig` and the recovery walk a reopen resumes from. The read
//! path lands in the later stages; the format core stays pure — no descriptor,
//! no battery, no ring — and only the writer reaches the ring.
//!
//! The specification is designs/wal-impl.md: §2 for the battery, §3 for the
//! write path, §5 for the read path. One index — a mirror included — owns one
//! WAL file per data set, and a pair `(host_idx, index_idx)` owns one battery
//! area for as long as its index thread lives.

const std = @import("std");
const posix = std.posix;
const blog = @import("blog");
const zigring = @import("zigring");
const config = @import("config.zig");
const resources = @import("resources.zig");
const res_handle = @import("resources_handle.zig");
const slots = @import("slots.zig");
const barrier = @import("barrier.zig");

/// WAL block: the CRC unit. Records never cross one.
pub const BLOCK: usize = 1 << 20;

/// The block's last bytes hold its running CRC32C.
pub const CRC_LEN: usize = 4;

/// Bytes of a block available to records: `1 MiB - 4`.
pub const BLOCK_CONTENT: usize = BLOCK - CRC_LEN;

/// Size of one `BufferHeader`, one cache line.
pub const HEADER: usize = 64;

/// CRC32C register seed and final XOR, in the reflected Castagnoli convention
/// blog implements: the raw register starts at this value and the result is
/// XORed with it.
///
/// `blog.crc32c` applies both unconditionally, so the value a *fold* starts a
/// block from is `0` — the CRC of an empty prefix — not this constant. Handing
/// the seed to `blog.crc32c.composedCrc32C` would cancel the register init
/// instead of applying it once, and the block's stored CRC would stop matching
/// the whole-block `hardwareCrc32C` the reader verifies with.
pub const crc_seed: u32 = 0xFFFFFFFF;

/// Bit 0 of `BufferHeader.flags`: the buffer holds committed bytes.
pub const FLAG_FILLED: u32 = 1;

/// One buffer's control line: exactly 64 bytes, so one publish is one cache
/// line write and is atomic in practice.
///
/// The field order is pinned by designs/wal-impl.md §2; the adoption fields
/// fill the old pads without growing the line.
pub const BufferHeader = extern struct {
    /// Valid bytes; the full LBA when filled, `0` for the zero-terminator.
    data_len: u32,
    /// Bit 0 = filled.
    flags: u32,
    /// Absolute ordinal of the buffer: its file position divided by the LBA.
    buffer_seq: u64,
    /// Running CRC32C of the open block at this buffer's committed extent.
    crc_running: u32,
    /// The adoption mark: set only on a pair area's control line, zero forever
    /// on every ring line (designs/SNAPSHOTS.md §2.2).
    snapshot_in_progress: u8,
    /// The temp ring a migrating pair's new writer runs on.
    new_wal_buffer_idx: u16,
    /// The `state_idx` of the last record ending in this committed extent.
    ///
    /// The pinned layout puts it right after the adoption fields, at offset 24,
    /// which is only 8-byte aligned; `align(8)` is what makes offset 24 and the
    /// 64-byte total coexist.
    last_state: u128 align(8),
    /// The migrating pair's tag: the state the adoption is replayed from.
    target_state: u128 align(8),
    _pad_tail: [8]u8,

    comptime {
        std.debug.assert(@sizeOf(BufferHeader) == HEADER);
        std.debug.assert(@offsetOf(BufferHeader, "snapshot_in_progress") == 20);
        std.debug.assert(@offsetOf(BufferHeader, "new_wal_buffer_idx") == 22);
        std.debug.assert(@offsetOf(BufferHeader, "last_state") == 24);
        std.debug.assert(@offsetOf(BufferHeader, "target_state") == 40);
    }
};

/// Everything the write path reports. `OutOfMemory` is added by the entry
/// points that allocate.
pub const WalError = error{
    WalFull,
    RecordTooLarge,
    WalGap,
    InvalidStateIdx,
    NoFreeSlots,
    RingFull,
    WalFaulted,
    WalOpen,
    OutOfMemory,
};

/// How the battery is backed.
pub const Mode = enum { plain, pmem };

/// The mode a config block selects.
pub fn modeOf(wal_cfg: config.Wal) Mode {
    return if (wal_cfg.isPmem()) .pmem else .plain;
}

// ============================================================================
// Record framing
// ============================================================================

/// The framed length of a record carrying a `data_len`-byte op:
/// `state_idx` (16 LE bytes) + `uvarint(data_len)` + `data_len`.
pub fn framedLen(data_len: usize) usize {
    return 16 + resources.uvarintLen(data_len) + data_len;
}

/// Frames one record: `state_idx` as 16 little-endian bytes, the op's length as
/// a base-128 varint, then the op's bytes.
///
/// The floor is not stored — it is validation input, computed as the previous
/// record's state — and the WAL never looks inside an op, so the frame is the
/// whole format. The uvarint is the one `resources` implements; there is no
/// second copy here. The caller owns the result.
pub fn encodeRecord(allocator: std.mem.Allocator, state_idx: u128, data: []const u8) ![]u8 {
    const framed = try allocator.alloc(u8, framedLen(data.len));
    errdefer allocator.free(framed);

    std.mem.writeInt(u128, framed[0..16], state_idx, .little);
    const len_len = try resources.putUvarint(framed[16..], data.len);
    @memcpy(framed[16 + len_len ..][0..data.len], data);
    return framed;
}

/// Framing validation of the record at the front of `bytes`.
///
/// `len` is the framed length a walker advances by. A record whose bytes run
/// past the given extent is `CorruptInput`: a caller holding a possibly torn
/// tail compares the frame against its extent and drops the remainder rather
/// than parsing it, so a torn tail is a caller-side decision, not an error of
/// its own. `state_idx == 0` is the padding sentinel and the reserved empty
/// state, so it is refused as `InvalidStateIdx`.
pub fn decodeRecord(bytes: []const u8) !struct { state_idx: u128, op: []const u8, len: usize } {
    if (bytes.len < 16) return error.CorruptInput;

    const state_idx = std.mem.readInt(u128, bytes[0..16], .little);
    if (state_idx == 0) return error.InvalidStateIdx;

    const op_len = try resources.readUvarint(bytes[16..]);
    const start = 16 + op_len.len;
    if (op_len.value > bytes.len - start) return error.CorruptInput;

    const len: usize = @intCast(op_len.value);
    return .{ .state_idx = state_idx, .op = bytes[start..][0..len], .len = start + len };
}

// ============================================================================
// Block framing and checksums
// ============================================================================

/// The block an absolute offset falls in.
pub fn blockOf(offset: u64) u64 {
    return offset / BLOCK;
}

/// The offset's position inside its block.
pub fn inBlockOffset(offset: u64) usize {
    return @intCast(offset % BLOCK);
}

/// Content bytes left in the block from `offset` on: the room a record has
/// before the block has to be padded and closed.
///
/// The block's last `CRC_LEN` bytes are the CRC slot, not content. A caller
/// asks from a record's start, which is never inside the slot.
pub fn blockRemain(offset: u64) usize {
    const in_block = inBlockOffset(offset);
    std.debug.assert(in_block <= BLOCK_CONTENT);
    return BLOCK_CONTENT - in_block;
}

/// Whether the buffer boundary at `offset` also ends its block.
///
/// The config validates `1 MiB % lba == 0`, so the CRC slot always lands inside
/// the block's last buffer and every block close is also a buffer fill. That is
/// asserted in the tests instead of handled here.
pub fn closesBlock(offset: u64) bool {
    return offset != 0 and offset % BLOCK == 0;
}

// ============================================================================
// On-disk naming
// ============================================================================

/// Renders `wal.<host_idx>.<index_idx>.<state>` inside `dir`, with `state` as
/// 32 lowercase hex digits — symmetric with the snapshot convention.
///
/// The result is sentinel-terminated so it feeds `open`/`unlink` directly. The
/// tag is an ordered marker, not a content binding: `walTagFromPath` reads it
/// back for the adoption rule and the maintenance tool, while startup takes
/// the base state from the walk (designs/SNAPSHOTS.md §2.3).
pub fn walPath(
    allocator: std.mem.Allocator,
    dir: []const u8,
    host_idx: u8,
    index_idx: u16,
    state: u128,
) ![:0]u8 {
    return std.fmt.allocPrintSentinel(
        allocator,
        "{s}/wal.{d}.{d}.{x:0>32}",
        .{ dir, host_idx, index_idx, state },
        0,
    );
}

/// Renders `snapshot.<host_idx>.<index_idx>.<state>` inside `dir`, the leaf
/// symmetric with `walPath` (designs/SNAPSHOTS.md §2.3).
///
/// Equal tags pair the two names: `snapshot.h.i.X` belongs with
/// `wal.h.i.X`, and a same-tag retry truncates its own orphan.
pub fn snapshotPath(
    allocator: std.mem.Allocator,
    dir: []const u8,
    host_idx: u8,
    index_idx: u16,
    state: u128,
) ![:0]u8 {
    return std.fmt.allocPrintSentinel(
        allocator,
        "{s}/snapshot.{d}.{d}.{x:0>32}",
        .{ dir, host_idx, index_idx, state },
        0,
    );
}

/// The tag a WAL leaf name carries, or `null` when `path` is not one.
///
/// The inverse of `walPath`'s leaf template: the `wal.` stem plus 32 lowercase
/// hex digits after the last dot. Only the adoption rule's comparison and the
/// maintenance tool read a name back; startup takes the head from the walk,
/// never from a name (§2.3).
pub fn walTagFromPath(path: []const u8) ?u128 {
    const base = std.fs.path.basename(path);
    if (!std.mem.startsWith(u8, base, "wal.")) return null;
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return null;
    const suffix = base[dot + 1 ..];
    if (suffix.len != 32) return null;
    for (suffix) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return null;
    }
    return std.fmt.parseInt(u128, suffix, 16) catch null;
}

// ============================================================================
// Battery partitioning
// ============================================================================

/// The area a pair's battery lives in.
///
/// Thread-major: `index_idx × hosts + host_idx` of `indexes × hosts` areas.
/// The order is stable across restarts and movable only by the migration
/// toolchain.
pub fn areaIndex(host_idx: u8, index_idx: u16, hosts: u32) usize {
    return @as(usize, index_idx) * hosts + host_idx;
}

/// The alignment every pair's data array needs: one LBA, but never below a
/// page, so a mapped area stays page-aligned too.
pub fn areaGranule(lba: u32, page_size: usize) usize {
    return @max(@as(usize, lba), page_size);
}

/// Size of one area: the data array (`buffers × lba`), the header array
/// (`buffers × 64`), then the 64-byte control line, rounded **up** to the
/// granule so every area's data array starts LBA-aligned wherever the previous
/// one ended.
///
/// A temp ring's area is geometrically identical — control line included, so
/// the areas stay uniform (designs/SNAPSHOTS.md §2.2).
pub fn areaStride(buffers: u32, lba: u32, page_size: usize) usize {
    const raw = @as(usize, buffers) * (@as(usize, lba) + HEADER) + HEADER;
    const granule = areaGranule(lba, page_size);
    return std.mem.alignForward(usize, raw, granule);
}

/// Offset of an area's control line: right after the header array.
pub fn controlLineOffsetInArea(buffers: u32, lba: u32) usize {
    return @as(usize, buffers) * (@as(usize, lba) + HEADER);
}

/// An area's control line — the adoption mark's home (designs/SNAPSHOTS.md
/// §2.2). No writer touches it: the mark's publish is the only rewrite.
pub fn controlLineOf(area: []u8, buffers: u32, lba: u32) *BufferHeader {
    const offset = controlLineOffsetInArea(buffers, lba);
    std.debug.assert(area.len >= offset + HEADER);
    return @ptrCast(@alignCast(area[offset..][0..HEADER].ptr));
}

/// The area a procedure's temp ring `k` lives in: the temp section is appended
/// after the pair areas.
pub fn tempAreaIdx(k: u32, pairs: usize) usize {
    return pairs + k;
}

/// Offset of buffer `buffer_idx`'s data inside its pair's area: the data array
/// comes first, so the offsets are just the slot's ordinal times the LBA.
pub fn dataOffsetInArea(lba: u32, buffer_idx: usize) usize {
    return buffer_idx * @as(usize, lba);
}

/// Offset of buffer `buffer_idx`'s header inside its pair's area: the header
/// array follows the whole data array.
pub fn headerOffsetInArea(buffers: u32, lba: u32, buffer_idx: usize) usize {
    return @as(usize, buffers) * lba + buffer_idx * HEADER;
}

/// The buffer an ordinal lands in: the area's slots form a ring.
pub fn bufferIdx(ordinal: u64, buffers: u32) usize {
    return @intCast(ordinal % buffers);
}

// ============================================================================
// The battery
// ============================================================================

/// Size of the whole battery: one area per hosted pair plus one per snapshot
/// slot, the temp section (designs/SNAPSHOTS.md §2.2).
pub fn batterySize(areas: usize, stride: usize) usize {
    return areas * stride;
}

/// One area as its two columnar arrays: the data array first, the header array
/// after it. The 64-byte control line past the headers stays outside the view
/// — no writer touches it (designs/SNAPSHOTS.md §2.2).
pub const Area = struct {
    data: []u8,
    headers: []BufferHeader,

    /// Wires an area's bytes into the two arrays its geometry prescribes.
    pub fn init(bytes: []u8, buffers: u32, lba: u32) Area {
        std.debug.assert(bytes.len >= headerOffsetInArea(buffers, lba, buffers));
        const data = bytes[0..][0 .. @as(usize, buffers) * lba];
        const raw_headers = bytes[headerOffsetInArea(buffers, lba, 0)..][0 .. @as(usize, buffers) * HEADER];
        return .{
            .data = data,
            .headers = @alignCast(std.mem.bytesAsSlice(BufferHeader, raw_headers)),
        };
    }
};

/// Mints an area before a writer is wired to it: a temp ring is reused
/// procedure after procedure and the walk trusts `buffer_seq`, so a previous
/// procedure's stale lines must never be reachable (designs/SNAPSHOTS.md §2.2).
///
/// The header array is zeroed, one barrier lands it, the reserved control line
/// is zeroed, and only then is the ordinal-0 terminator published the
/// `persistHeader` way — zeroed lines classify as stale at any nonzero ordinal,
/// so the terminator is the one line the mint leaves reachable. The data array
/// is untouched: stale bytes are unreachable behind stale headers.
pub fn mintArea(area: []u8, buffers: u32, lba: u32, head_state: u128, pmem: bool) void {
    const view = Area.init(area, buffers, lba);
    @memset(std.mem.sliceAsBytes(view.headers), 0);
    if (pmem) {
        barrier.clwb(view.headers.ptr, @as(usize, buffers) * HEADER);
        barrier.sfence();
    }

    controlLineOf(area, buffers, lba).* = std.mem.zeroes(BufferHeader);

    const header = &view.headers[0];
    header.* = .{
        .data_len = 0,
        .flags = 0,
        .buffer_seq = 0,
        // The empty block's fold is the CRC of nothing, not the register seed
        // (designs/wal-steps.md §B2's reconciliation).
        .crc_running = 0,
        .snapshot_in_progress = 0,
        .new_wal_buffer_idx = 0,
        .last_state = head_state,
        .target_state = 0,
        ._pad_tail = @splat(0),
    };
    if (pmem) {
        barrier.clwb(header, @sizeOf(BufferHeader));
        barrier.sfence();
    }
}

// ============================================================================
// The walk
// ============================================================================

/// One row of designs/wal-impl.md §5's walk table: what the control line at the
/// ordinal being walked says about the chain.
pub const WalkVerdict = union(enum) {
    /// `buffer_seq != o`: another lap's or another file's line. Stop.
    stale,
    /// The zero-terminator for `o`: the chain ends here.
    terminator,
    /// A committed full buffer: take all of it and walk on.
    full: u32,
    /// The live tail: take its bytes and stop.
    tail: u32,
    /// Metadata no publish produces: stop, never deliver.
    torn,
};

/// Classifies `ordinal`'s control line, row by row of §5's table.
///
/// The rows are the predicate and their order is not free: a line whose
/// `buffer_seq` is not its ordinal belongs to a previous lap or a previous file
/// and stops the walk whatever the rest of it says. After that the terminator,
/// the committed buffer and the live tail are the three shapes the writer's
/// publishes produce, and everything left over is torn metadata.
pub fn walkVerdict(header: *const BufferHeader, ordinal: u64, lba: u32) WalkVerdict {
    if (header.buffer_seq != ordinal) return .stale;
    const filled = header.flags & FLAG_FILLED != 0;
    if (header.data_len == lba and filled) return .{ .full = header.data_len };
    if (header.data_len == 0 and !filled) return .terminator;
    if (header.data_len < lba and !filled) return .{ .tail = header.data_len };
    return .torn;
}

/// The pair every resume needs: the open block's fold and the state the next
/// record must chain from. A control line carries exactly this pair for the
/// extent it starts at (§2's uniform rule), which is what makes a walk of the
/// battery a resume.
pub const Chain = struct {
    crc_running: u32,
    last_state: u128,
};

/// The effective length of a WAL file: every whole buffer, the torn tail of the
/// last one dropped (§3.4). A block is a whole number of buffers, so this also
/// never cuts a block.
pub fn flushedLen(size: u64, lba: u32) u64 {
    return size & ~(@as(u64, lba) - 1);
}

/// The fold of the first `limit` bytes of a block: `composedCrc32C` from the
/// block's start, which is where a block's CRC begins. Zero bytes in — the
/// start of a block with nothing flushed — is zero, not the register seed.
fn foldAt(block: []const u8, limit: usize) u32 {
    return blog.crc32c.composedCrc32C(0, block[0..limit]);
}

/// The state of the last record ending at or before `limit` bytes into a block:
/// the pair a resume from that offset continues from.
fn stateAt(block: []const u8, limit: usize, tag: u128) u128 {
    var pos: usize = 0;
    var last = tag;
    while (pos < limit) {
        const record = decodeRecord(block[pos..]) catch break;
        if (pos + record.len > limit) break;
        last = record.state_idx;
        pos += record.len;
    }
    return last;
}

// ============================================================================
// The writer
// ============================================================================

/// Where a writer's flushes go: `WalFlushSink` on a live thread, the
/// synchronous default in a test.
///
/// `room` is the admission pre-check of designs/wal-steps.md §C1 step 5 — a
/// free slot in the table and room in the SQ window, refused as
/// `NoFreeSlots`/`RingFull`. `submit` hands one filled buffer's ordinal to the
/// sink, which answers by calling `flushComplete` on the writer's own thread;
/// the default answers at once, exactly as a synchronous test pump would.
pub const FlushSink = struct {
    ctx: ?*anyopaque = null,
    room: *const fn (ctx: ?*anyopaque, writer: *WalWriteFile) WalError!void = alwaysRoom,
    submit: *const fn (ctx: ?*anyopaque, writer: *WalWriteFile, ordinal: u64) void = syncSubmit,
};

/// The plain sink's answer to the pre-check: a battery with no ring behind it
/// can always take one more flush.
fn alwaysRoom(ctx: ?*anyopaque, writer: *WalWriteFile) WalError!void {
    _ = ctx;
    _ = writer;
}

/// The plain sink's submission: nothing to wait for, so the flush completes
/// inside the call.
fn syncSubmit(ctx: ?*anyopaque, writer: *WalWriteFile, ordinal: u64) void {
    _ = ctx;
    writer.flushComplete(ordinal);
}

/// The thread's flush sink: one SQE per filled buffer through its stream
/// window (§3.3), and the slot the admission pre-check took carried into the
/// submission that follows it in the same `write`.
///
/// Exactly one flush is ever in flight, so one reserved and one in-flight slot
/// cover the queue: the writer submits the next buffer only from the
/// completion of the previous one.
pub const WalFlushSink = struct {
    const Self = @This();

    stream: *zigring.StreamSQ,
    slots: *slots.RingSlots,
    /// The slot taken by a pre-check, waiting for the submission it admitted.
    reserved: ?u64 = null,
    /// The slot of the flush in flight: its completion retires it.
    inflight: ?u64 = null,

    /// The pre-check of §C1 step 5: a slot from the table, then room in the
    /// window. A refusal hands the slot back, so it moves nothing.
    fn room(ctx: ?*anyopaque, writer: *WalWriteFile) WalError!void {
        const self = fromCtx(ctx);
        if (self.reserved == null) {
            self.reserved = self.slots.add(.{ .wal_flush = .{ .writer = writer } }) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.NoFreeSlots,
            };
        }
        if (self.stream.hasRoom()) return;
        self.release();
        return error.RingFull;
    }

    /// One flush: `pushWriteOffset` at the buffer's own file offset, then the
    /// stream commits it. The write flags carry `RWF.DSYNC` in PMEM mode,
    /// where the device's volatile cache drains with the record.
    ///
    /// Both failures are backpressure, not OS errors — the window closing and
    /// the table emptying are the states the pre-check guards — so the writer
    /// parks and the drain retries.
    fn submit(ctx: ?*anyopaque, writer: *WalWriteFile, ordinal: u64) void {
        const self = fromCtx(ctx);
        if (self.reserved == null) {
            self.reserved = self.slots.add(.{ .wal_flush = .{ .writer = writer } }) catch {
                writer.parkFlush();
                return;
            };
        }
        const task_idx = self.reserved.?;
        self.reserved = null;

        const data = writer.bufferData(ordinal);
        self.stream.pushWriteOffset(
            res_handle.borrow(&writer.fd),
            task_idx,
            ordinal * @as(u64, writer.lba),
            data.ptr,
            data.len,
            .{},
            if (writer.pmem) std.os.linux.RWF.DSYNC else 0,
        ) orelse {
            self.slots.del(task_idx);
            writer.parkFlush();
            return;
        };
        self.stream.commit() catch {
            // The ring cannot publish the submission at all: the flush is lost
            // with nothing to return the error to, so the writer stops.
            self.slots.del(task_idx);
            writer.flush_in_flight = false;
            writer.fault(.IO);
            return;
        };
        self.inflight = task_idx;
    }

    /// Hands back the slot a pre-check took but never used.
    fn release(self: *Self) void {
        if (self.reserved) |task_idx| self.slots.del(task_idx);
        self.reserved = null;
    }

    /// Retires the in-flight flush's slot: its completion arrived.
    fn retire(self: *Self) void {
        if (self.inflight) |task_idx| self.slots.del(task_idx);
        self.inflight = null;
    }

    fn fromCtx(ctx: ?*anyopaque) *Self {
        return @ptrCast(@alignCast(ctx.?));
    }
};

/// One data set's write side: a descriptor, the pair's battery view and the
/// chain state that keeps the records contiguous.
///
/// The tag is the file's base state — the state its first record must chain
/// from — and `head` is the state the next record must chain from. At open they
/// coincide; the recovery walk supersedes `head` from the battery (PMEM) or from
/// the file itself (plain mode) in the later stages.
pub const WalWriteFile = struct {
    const Self = @This();

    fd: res_handle.FileHandle,
    host_idx: u8,
    index_idx: u16,
    /// The file's name tag, opaque to the writer.
    tag: u128,
    /// The state the next record must chain from.
    head: u128,

    /// The pair's data array: `buffers` slots of `lba` bytes each.
    data: []u8,
    /// The pair's control lines, one per data slot.
    headers: []BufferHeader,
    lba: u32,
    buffers: u32,
    /// PMEM mode adds `CLWB`/`SFENCE` to every publish and `RWF.DSYNC` to
    /// every flush; plain mode does neither.
    pmem: bool,

    /// The first ordinal whose buffer has no flush outstanding.
    flushed_upto: u64 = 0,
    /// At most one flush is ever in flight (§3.3).
    flush_in_flight: bool = false,
    /// A submission was refused by backpressure: the drain retries it.
    flush_pending: bool = false,
    /// An OS error stopped this writer; it refuses everything from then on.
    faulted: bool = false,
    /// The ordinal of the buffer receiving bytes now.
    current: u64 = 0,
    /// Bytes already written into the current buffer.
    cursor: u32 = 0,
    /// Set once `drain` ran; the writer is unusable afterwards.
    closed: bool = false,
    /// The last committed state at or before `flushed_upto`'s extent 0: the
    /// `last_state` a resume there continues from, so the zero-terminator a
    /// completed flush publishes can carry it.
    flushed_state: u128,
    /// The fold of the block containing `flushed_upto`, at its extent 0.
    flushed_crc: u32 = 0,
    /// Where this writer's flushes go: the synchronous default until
    /// `attachStream` wires the thread's ring.
    sink: FlushSink = .{},
    /// Observes the persistence of every control line publish — the writeback
    /// and the fence in PMEM mode happen first — so a test can assert the
    /// commit-last order.
    persist_hook: ?*const fn (writer: *Self, header: *BufferHeader) void = null,
    /// The thread's logger, when it has one: the stop's diagnostic goes here
    /// (§3.5). Null where nothing logs.
    logger: ?*resources.LoggerStuff = null,
    /// The thread's stream window, when flushes leave through the ring:
    /// `drain` awaits its last completion there. Null with the synchronous
    /// sink, where a submission completes inside its own call.
    stream: ?*zigring.StreamSQ = null,
    /// The ring sink's own state, installed by `attachStream` together with
    /// `stream` and `sink`.
    ring_sink: WalFlushSink = undefined,

    /// Wires a pair's battery area into a writer over `fd`.
    pub fn init(
        fd: res_handle.FileHandle,
        area: Area,
        wal_cfg: config.Wal,
        host_idx: u8,
        index_idx: u16,
        state: u128,
    ) Self {
        return .{
            .fd = fd,
            .host_idx = host_idx,
            .index_idx = index_idx,
            .tag = state,
            .head = state,
            .data = area.data,
            .headers = area.headers,
            .lba = wal_cfg.lba(),
            .buffers = wal_cfg.buffers(),
            .pmem = wal_cfg.isPmem(),
            .flushed_state = state,
        };
    }

    /// Wires this writer's flushes through the thread's stream window: every
    /// completed buffer leaves as one `pushWriteOffset` SQE from the writer's
    /// own slot, with `RWF.DSYNC` following the mode (§3.3).
    ///
    /// Call it once the writer sits at its final address: the sink is reached
    /// through a pointer into the writer itself.
    pub fn attachStream(self: *Self, stream: *zigring.StreamSQ, ring_slots: *slots.RingSlots) void {
        self.stream = stream;
        self.ring_sink = .{ .stream = stream, .slots = ring_slots };
        self.sink = .{
            .ctx = &self.ring_sink,
            .room = WalFlushSink.room,
            .submit = WalFlushSink.submit,
        };
    }

    /// Recovers the chain a reopen resumes from: the battery's in PMEM mode
    /// (§3.4's PMEM arm), the file's own parse in plain mode.
    ///
    /// `size` is the file's length; its effective length counts the buffers the
    /// file itself has flushed, so the walk starts at the first buffer it has
    /// not and stops where §5's table stops — a stale control line, the
    /// zero-terminator, the live tail, torn metadata. The line it stopped at
    /// yields the resume point: `current` and `cursor` are the buffer and the
    /// byte the next record starts at, `head` is the state it must chain from,
    /// and the stopped line carries the fold to continue its block with.
    ///
    /// A stop on a line this file never published — a stale lap or torn
    /// metadata — republishes it as its zero-terminator first, so the battery's
    /// core invariant (a data area receives bytes only after its control line is
    /// a terminator for its ordinal) holds for the resumed writer too.
    pub fn walk(self: *Self, size: u64) !void {
        if (!self.pmem) return self.walkPlain(size);
        const flushed = flushedLen(size, self.lba) / self.lba;

        // The flush frontier's pair: what the first reclamation of the resumed
        // writer publishes, and the resume point when the walk cannot move.
        const frontier = self.flushFrontier(flushed);
        self.flushed_upto = flushed;
        self.flushed_crc = frontier.crc_running;
        self.flushed_state = frontier.last_state;

        var ordinal = flushed;
        var cursor: u32 = 0;
        var chain = frontier;
        // Whether the stopped line is already a valid zero-terminator for its
        // ordinal: the live tail continues in place, the terminator needs
        // nothing, and a stale or torn line is republished below.
        var line_is_current = true;

        chain_walk: while (true) {
            const header = &self.headers[bufferIdx(ordinal, self.buffers)];
            switch (walkVerdict(header, ordinal, self.lba)) {
                .stale, .torn => {
                    line_is_current = false;
                    break :chain_walk;
                },
                .terminator => {
                    chain = .{ .crc_running = header.crc_running, .last_state = header.last_state };
                    break :chain_walk;
                },
                .tail => |len| {
                    cursor = len;
                    chain = .{ .crc_running = header.crc_running, .last_state = header.last_state };
                    break :chain_walk;
                },
                .full => {
                    // A committed full buffer: its own fold and state are the
                    // pair of its successor's extent 0, and a block opening
                    // restarts the fold there.
                    chain = .{
                        .crc_running = if (closesBlock((ordinal + 1) * @as(u64, self.lba)))
                            0
                        else
                            header.crc_running,
                        .last_state = header.last_state,
                    };
                    ordinal += 1;
                },
            }
        }

        if (!line_is_current) self.publishTerminator(ordinal, chain.last_state, chain.crc_running);

        self.current = ordinal;
        self.cursor = cursor;
        self.head = chain.last_state;
    }

    /// The plain-mode resume (§3.4): the battery is DRAM and gone after a
    /// restart, so the file is the only source.
    ///
    /// The open block's flushed extent is parsed once, cold, with the reader's
    /// own framing: records parse while they fit, `head` becomes the last
    /// complete record's state (the tag when the file is empty), the write
    /// offset is that record's end — or the block's end when the parse stopped
    /// at the padding of a closed block — and the open block's fold is reseeded
    /// over its flushed bytes, skipped when the file end is on a block
    /// boundary. A torn record at the extent end is dropped exactly as the
    /// reader drops it.
    ///
    /// The buffers the resumed writer will rewrite are the flush frontier, so
    /// the queue starts at the one holding the write offset: its line carries
    /// the fold the next record continues from, and the pair a resume from that
    /// buffer continues from is what its reclamation will publish.
    fn walkPlain(self: *Self, size: u64) !void {
        const lba: u64 = self.lba;
        const flushed = flushedLen(size, self.lba);
        const n = flushed / lba;

        self.flushed_upto = n;
        self.flushed_state = self.tag;
        self.flushed_crc = 0;
        self.current = n;
        self.cursor = 0;
        self.head = self.tag;

        if (flushed == 0) {
            self.publishTerminator(0, self.tag, 0);
            return;
        }

        // The open block: the one holding the last flushed byte. A file end on
        // a block boundary is the closed block before it, and the writer opens
        // the next one empty.
        const block_start = (flushed - 1) / BLOCK * BLOCK;
        const region_len: usize = @intCast(flushed - block_start);
        const allocator = std.heap.page_allocator;
        const region = try allocator.alloc(u8, region_len);
        defer allocator.free(region);
        try res_handle.readFully(res_handle.borrow(&self.fd), region, block_start);

        var pos: usize = 0;
        var last = self.tag;
        var padding = false;
        while (pos < region.len) {
            const record = decodeRecord(region[pos..]) catch |err| {
                padding = err == error.InvalidStateIdx;
                break;
            };
            last = record.state_idx;
            pos += record.len;
        }

        // The write offset: the last complete record's end, or the block's end
        // when the parse stopped at a closed block's padding.
        const offset = if (padding) block_start + BLOCK else block_start + pos;
        self.current = offset / lba;
        self.cursor = @intCast(offset % lba);
        self.head = last;

        // The fold at the write offset the next record continues from, and the
        // pair a resume from the buffer it lands in continues from. A padding
        // run reaches the block's end, so both land on a block boundary there:
        // the next block starts empty and folds from zero. The byte counts are
        // clamped because a crash can flush a padding run's opening buffers
        // without its last one.
        const frontier = self.current * lba;
        const within: usize = @intCast(@min(frontier - block_start, region.len));
        self.flushed_upto = self.current;
        self.flushed_state = stateAt(region, within, self.tag);
        self.flushed_crc = if (frontier % BLOCK == 0) 0 else foldAt(region, within);
        self.publishCommit(
            self.current,
            self.cursor,
            if (offset % BLOCK == 0) 0 else foldAt(region, @intCast(offset - block_start)),
            last,
        );
    }

    /// The pair a resume from `ordinal`'s extent 0 continues from, read across
    /// the flush frontier.
    ///
    /// The usual shape is the frontier's own line: a completed flush leaves the
    /// flushed ordinal's slot holding exactly that per-tuple terminator. A crash
    /// that left committed buffers in the battery overwrites it, and then the
    /// pair is the preceding ordinal's — its reclaiming terminator is still in
    /// its slot and its bytes are still in the data array, since the ring
    /// reaches that slot again only `buffers` ordinals later. With neither
    /// readable the writer's own start is the answer: the empty fold, and the
    /// tag as the base.
    fn flushFrontier(self: *const Self, ordinal: u64) Chain {
        if (ordinal == 0) return .{ .crc_running = 0, .last_state = self.tag };

        const own = &self.headers[bufferIdx(ordinal, self.buffers)];
        if (walkVerdict(own, ordinal, self.lba) == .terminator) {
            return .{ .crc_running = own.crc_running, .last_state = own.last_state };
        }

        const prev_ordinal = ordinal - 1;
        const prev = &self.headers[bufferIdx(prev_ordinal, self.buffers)];
        if (walkVerdict(prev, prev_ordinal, self.lba) != .terminator) {
            return .{ .crc_running = 0, .last_state = self.tag };
        }
        const prev_data = self.data[bufferIdx(prev_ordinal, self.buffers) * self.lba ..][0..self.lba];
        return .{
            .crc_running = if (closesBlock(ordinal * @as(u64, self.lba)))
                0
            else
                blog.crc32c.composedCrc32C(prev.crc_running, prev_data),
            .last_state = prev.last_state,
        };
    }

    /// The data of one buffer slot, at the offset its flush will use.
    pub fn bufferData(self: *Self, ordinal: u64) []u8 {
        const idx = bufferIdx(ordinal, self.buffers);
        return self.data[idx * self.lba ..][0..self.lba];
    }

    /// Publishes the zero-terminator for `ordinal`: `data_len = 0`, `filled`
    /// clear, and the state a resume from this ordinal continues from.
    ///
    /// Every path that makes a buffer current publishes one first (§2's
    /// uniform rule): a data area only ever receives bytes after its control
    /// line has been persisted as a zero-terminator for its ordinal.
    pub fn publishTerminator(self: *Self, ordinal: u64, last_state: u128, crc_running: u32) void {
        self.publishCommit(ordinal, 0, crc_running, last_state);
    }

    /// Stages one buffer's control line in the battery: `data_len` bytes
    /// committed at `crc_running`, and `last_state` as the state of the last
    /// record ending inside that extent.
    ///
    /// `filled` follows `data_len`: a full buffer is filled, a zero-terminator
    /// and a live tail are not. The whole line is rewritten, so a stale lap
    /// cannot leak a field into the new one — adoption state included: no ring
    /// line ever carries a migration mark.
    fn writeHeader(
        self: *Self,
        ordinal: u64,
        data_len: u32,
        crc_running: u32,
        last_state: u128,
    ) *BufferHeader {
        const header = &self.headers[bufferIdx(ordinal, self.buffers)];
        header.* = .{
            .data_len = data_len,
            .flags = if (data_len == self.lba) FLAG_FILLED else 0,
            .buffer_seq = ordinal,
            .crc_running = crc_running,
            .snapshot_in_progress = 0,
            .new_wal_buffer_idx = 0,
            .last_state = last_state,
            .target_state = 0,
            ._pad_tail = @splat(0),
        };
        return header;
    }

    /// Stages a control line and persists it: the publish every path but the
    /// write's commit point ends with.
    fn publishCommit(
        self: *Self,
        ordinal: u64,
        data_len: u32,
        crc_running: u32,
        last_state: u128,
    ) void {
        self.persistHeader(self.writeHeader(ordinal, data_len, crc_running, last_state));
    }

    /// Persistence seam for control-line publishes: plain mode is a no-op,
    /// since a DRAM battery becomes durable with its flush, not with the
    /// publish. PMEM mode writes the line back and fences it here (§2), which
    /// is what makes one publish one atomic-in-practice cache line.
    fn persistHeader(self: *Self, header: *BufferHeader) void {
        if (self.pmem) {
            barrier.clwb(header, @sizeOf(BufferHeader));
            barrier.sfence();
        }
        if (self.persist_hook) |hook| hook(self, header);
    }

    /// The data half of the PMEM publish (§3.2 step 4): the bytes just copied
    /// into a buffer are written back and fenced before anything chains on
    /// them. Plain mode drops out here — its durability starts at the flush.
    fn persistData(self: *Self, bytes: []const u8) void {
        if (!self.pmem) return;
        barrier.clwb(bytes.ptr, bytes.len);
        barrier.sfence();
    }

    /// Appends one record to the log.
    ///
    /// Admission (`designs/wal-steps.md` §C1) runs in its pinned order and
    /// finishes before a single byte or control line moves, so every refusal
    /// leaves the writer exactly as it was. The copy then never splits a record
    /// across a block boundary (§C2), gives every successor its zero-terminator
    /// before any of its bytes, and publishes the buffer that was current at the
    /// start last — that publish is the write's commit point.
    pub fn write(self: *Self, new_state_idx: u128, floor_state_idx: u128, data: []u8) WalError!void {
        // Admission step 1: a stopped or a closed writer refuses everything.
        if (self.faulted or self.closed) return error.WalFaulted;
        // Step 2: the record must chain from the last accepted one, and state 0
        // stays reserved for "no records yet". Both refusals move nothing.
        if (floor_state_idx != self.head) return error.WalGap;
        if (new_state_idx == 0) return error.InvalidStateIdx;

        const lba: u64 = self.lba;
        const framed = framedLen(data.len);
        // Step 3: a record that cannot fill a fresh block never fits one.
        if (framed > BLOCK_CONTENT) return error.RecordTooLarge;

        const start = self.current * lba + @as(u64, self.cursor);
        const content_remain = blockRemain(start);
        // A record that overruns the block's content remainder zero-pads the
        // whole remainder and closes the block with its CRC: padding plus the
        // CRC slot is a buffer multiple, so the record starts the next block.
        const pad = if (framed > content_remain) content_remain + CRC_LEN else 0;
        const end = start + pad + framed;
        const last = (end - 1) / lba;

        // Step 4: the fundamental rule — after this write at least one buffer
        // stays free, so an exact fill of the last free one is `WalFull`.
        const touched: usize = @intCast(last - self.current + 1);
        if (self.freeBuffers() <= touched) return error.WalFull;

        // Step 5: the flush this write will submit is checked now, while
        // nothing has moved. The check and the submission happen in one call on
        // one thread, so a pre-checked submission cannot fail.
        const submits = self.flushed_upto >= self.current and
            (self.flushed_upto + 1) * lba <= end;
        if (submits and !self.flush_in_flight and !self.flush_pending) try self.flushRoom();

        // The copy. The open block's fold continues from the cursor, whose
        // running value the current buffer's control line already carries.
        var crc: u32 = self.headers[bufferIdx(self.current, self.buffers)].crc_running;
        const start_ordinal = self.current;
        // Set once the buffer current at the start filled: its publish waits
        // for the end of the write (commit-last).
        var deferred = false;

        if (pad != 0) {
            self.appendZeros(content_remain, &crc, start_ordinal, &deferred);
            std.debug.assert(self.lba - self.cursor == CRC_LEN);
            // The block's CRC lands in its last four bytes, inside its last
            // buffer, and is not part of its own content.
            var slot: [CRC_LEN]u8 = undefined;
            std.mem.writeInt(u32, &slot, crc, .little);
            self.append(&slot, false, &crc, start_ordinal, &deferred, self.head, self.head);
        }
        self.appendRecord(new_state_idx, data, &crc, start_ordinal, &deferred);

        // The buffer holding the record's end carries its state. When the
        // record ended exactly on a buffer boundary that publish already
        // happened in `closeBuffer`.
        if (self.cursor != 0) {
            self.publishCommit(self.current, self.cursor, crc, new_state_idx);
        }

        // Commit-last: the buffer current at the start persists after every
        // successor, and that publish is the commit point.
        if (deferred) self.persistHeader(&self.headers[bufferIdx(start_ordinal, self.buffers)]);

        // Accept.
        self.head = new_state_idx;
        self.driveFlush();
    }

    /// Copies `src` into the current buffer, committing the buffer when it
    /// fills.
    ///
    /// `fold` counts the bytes into the open block's CRC — `false` only for the
    /// CRC slot itself, which is not its own content. A buffer that fills
    /// carries `carry` as its `last_state`, or `final_carry` when this piece's
    /// last byte is what filled it: that is how a record's state lands in the
    /// buffer it ends in.
    fn append(
        self: *Self,
        src: []const u8,
        fold: bool,
        crc: *u32,
        start_ordinal: u64,
        deferred: *bool,
        carry: u128,
        final_carry: u128,
    ) void {
        var rest = src;
        while (rest.len > 0) {
            const room: usize = self.lba - self.cursor;
            const take = @min(rest.len, room);
            const piece = rest[0..take];
            const dst = self.bufferData(self.current)[self.cursor..][0..take];
            @memcpy(dst, piece);
            self.persistData(dst);
            if (fold) crc.* = blog.crc32c.composedCrc32C(crc.*, piece);
            self.cursor += @intCast(take);
            rest = rest[take..];
            if (self.cursor == self.lba) {
                self.closeBuffer(crc, start_ordinal, deferred, if (rest.len == 0) final_carry else carry);
            }
        }
    }

    /// Zero-pads a block's content remainder. Zeros count into the block's CRC
    /// like any other byte.
    fn appendZeros(self: *Self, len: usize, crc: *u32, start_ordinal: u64, deferred: *bool) void {
        var left = len;
        while (left > 0) {
            const room: usize = self.lba - self.cursor;
            const take = @min(left, room);
            const dst = self.bufferData(self.current)[self.cursor..][0..take];
            @memset(dst, 0);
            self.persistData(dst);
            crc.* = blog.crc32c.composedCrc32C(crc.*, dst);
            self.cursor += @intCast(take);
            left -= take;
            if (self.cursor == self.lba) self.closeBuffer(crc, start_ordinal, deferred, self.head);
        }
    }

    /// Frames one record and copies it in: the state as 16 little-endian
    /// bytes, the op's length as a uvarint, then the op — no frame is built in
    /// a buffer of its own.
    fn appendRecord(
        self: *Self,
        state_idx: u128,
        data: []const u8,
        crc: *u32,
        start_ordinal: u64,
        deferred: *bool,
    ) void {
        var frame: [16 + 10]u8 = undefined;
        std.mem.writeInt(u128, frame[0..16], state_idx, .little);
        const len_len = resources.putUvarint(frame[16..], data.len) catch unreachable;
        // A zero-length record ends on its own length byte.
        const frame_carry = if (data.len == 0) state_idx else self.head;
        self.append(frame[0 .. 16 + len_len], true, crc, start_ordinal, deferred, self.head, frame_carry);
        self.append(data, true, crc, start_ordinal, deferred, self.head, state_idx);
    }

    /// Commits the buffer that just filled and makes its successor current.
    ///
    /// The successor is current only once its zero-terminator is persisted —
    /// the battery's core invariant: a data area never receives bytes before
    /// its control line is a terminator for its ordinal (§2).
    fn closeBuffer(self: *Self, crc: *u32, start_ordinal: u64, deferred: *bool, last_state: u128) void {
        const ordinal = self.current;
        if (ordinal == start_ordinal) {
            // Commit-last: this buffer was current at the write's start, so its
            // persistence is the commit point and waits for the write's end.
            _ = self.writeHeader(ordinal, self.lba, crc.*, last_state);
            deferred.* = true;
        } else {
            self.publishCommit(ordinal, self.lba, crc.*, last_state);
        }

        const next = ordinal + 1;
        self.current = next;
        self.cursor = 0;
        // A block opening restarts the fold: the block's first buffer carries
        // the CRC of nothing, which is zero, not the register seed.
        if (closesBlock(next * @as(u64, self.lba))) crc.* = 0;
        self.publishTerminator(next, last_state, crc.*);
    }

    /// The tracked write extent of this writer, buffered tail included: the
    /// byte offset the next record starts at. Thread-local, no syscalls, no
    /// statx — the tick's size metric (designs/SNAPSHOTS.md §1.2).
    pub fn trackedExtent(self: *const Self) u64 {
        return self.current * self.lba + self.cursor;
    }

    /// Buffers a write can still take: no bytes committed and no flush
    /// outstanding. The fundamental rule keeps at least one of them free.
    fn freeBuffers(self: *const Self) usize {
        var free: usize = 0;
        for (self.headers) |header| {
            if (header.data_len == 0 and header.flags & FLAG_FILLED == 0) free += 1;
        }
        return free;
    }

    /// Whether `ordinal`'s slot holds a filled, committed buffer of this lap.
    fn isFilled(self: *const Self, ordinal: u64) bool {
        const header = self.headers[bufferIdx(ordinal, self.buffers)];
        return header.buffer_seq == ordinal and header.flags & FLAG_FILLED != 0;
    }

    /// The admission pre-check of the submission this write will make.
    fn flushRoom(self: *Self) WalError!void {
        const sink = self.sink;
        return sink.room(sink.ctx, self);
    }

    /// Hands one filled buffer to the sink. At most one flush is ever in
    /// flight, so the flag is set here, before the sink can answer.
    fn submitFlush(self: *Self, ordinal: u64) void {
        std.debug.assert(!self.flush_in_flight);
        self.flush_in_flight = true;
        self.sink.submit(self.sink.ctx, self, ordinal);
    }

    /// Submits the oldest filled buffer's flush when nothing is in flight, and
    /// parks `flush_pending` when the sink has no room for it: backpressure is
    /// not an error, only a delay.
    ///
    /// Public for the window's bounded drain (§3.4): a parked submission has no
    /// completion owed to it, so the drain retries it as its own completions
    /// reopen the ring.
    pub fn driveFlush(self: *Self) void {
        if (self.flush_in_flight) return;
        if (!self.isFilled(self.flushed_upto)) {
            self.flush_pending = false;
            return;
        }
        self.flushRoom() catch {
            self.flush_pending = true;
            return;
        };
        self.flush_pending = false;
        self.submitFlush(self.flushed_upto);
    }

    /// The flush of `ordinal` completed: its slot becomes the zero-terminator
    /// for that ordinal, the queue advances and the next filled buffer submits.
    ///
    /// The terminator carries the pair a resume *from* `ordinal` continues from
    /// — the state committed at or before its start and the fold of its block
    /// at extent 0 — so a walk that stops on it resumes correctly (§2).
    pub fn flushComplete(self: *Self, ordinal: u64) void {
        std.debug.assert(self.flush_in_flight);
        std.debug.assert(ordinal == self.flushed_upto);
        const header = &self.headers[bufferIdx(ordinal, self.buffers)];
        std.debug.assert(header.flags & FLAG_FILLED != 0);

        // Read the resume pair of the successor before the overwrite below: the
        // state committed inside this buffer and the fold at its end.
        const next_state = header.last_state;
        const next_crc = if (closesBlock((ordinal + 1) * @as(u64, self.lba))) 0 else header.crc_running;

        self.publishTerminator(ordinal, self.flushed_state, self.flushed_crc);

        self.flushed_state = next_state;
        self.flushed_crc = next_crc;
        self.flushed_upto = ordinal + 1;
        self.flush_in_flight = false;

        // The next buffer submits if it is marked filled.
        self.driveFlush();
    }

    /// One flush completion: its slot retires, and then either the queue
    /// advances or the writer stops.
    ///
    /// A negative `res` is the kernel's errno — a real OS error with no caller
    /// to return it to, so it is not retried (§3.3) and ends the writer (§3.5).
    pub fn flushResult(self: *Self, cqe: zigring.CQE) void {
        std.debug.assert(self.flush_in_flight);
        if (self.stream != null) {
            std.debug.assert(self.ring_sink.inflight == cqe.taskIdx());
            self.ring_sink.retire();
        }
        if (cqe.res < 0) return self.fault(cqe.errno());
        self.flushComplete(self.flushed_upto);
    }

    /// The stop (§3.5): an OS error ends this writer for good. Every later
    /// write refuses with `WalFaulted`, nothing is retried and nothing is
    /// repaired until the process restarts; the control plane keeps working.
    ///
    /// Only the flush and the read paths reach it — backpressure, `WalFull`,
    /// `RecordTooLarge`, `WalGap` and `WalOpen` are protocol answers, not
    /// faults.
    pub fn fault(self: *Self, errno: std.os.linux.E) void {
        if (self.faulted) return;
        self.faulted = true;
        self.flush_in_flight = false;
        self.flush_pending = false;
        if (self.logger) |stuff| stuff.logger.err("wal writer stopped", .{
            .host_idx = self.host_idx,
            .index_idx = self.index_idx,
            .errno = @backingInt(errno),
        });
    }

    /// Parks a submission the sink could not make: the drain retries it, so a
    /// momentarily full window or table delays the flush instead of losing it.
    fn parkFlush(self: *Self) void {
        self.flush_in_flight = false;
        self.flush_pending = true;
    }

    /// Waits for the flush in flight on the caller's ring: `popCQE` first,
    /// `park` only once the CQ is empty.
    ///
    /// A completion that is not this writer's flush cannot be stepped here —
    /// `close` owns the flush queue, the thread's own drain owns everything
    /// else — so its slot retires and the completion is dropped.
    fn awaitFlush(self: *Self) void {
        const stream = self.stream orelse return;
        while (self.flush_in_flight) {
            const cqe = stream.ring.popCQE() orelse {
                stream.ring.park();
                continue;
            };
            if (self.ring_sink.inflight) |flush_task| {
                if (cqe.taskIdx() == flush_task) {
                    self.flushResult(cqe);
                    continue;
                }
            }
            self.ring_sink.slots.del(cqe.taskIdx());
        }
    }

    /// Drives every filled buffer's flush to its completion: the bring-tail's
    /// flush-then-append (designs/SNAPSHOTS.md §3.6).
    ///
    /// Startup-safe by contract: the caller is the thread that just opened the
    /// writer, before service, so no other writer shares its ring and a
    /// completion that is not this writer's flush can only be an already
    /// retired slot. Like `close`, it retries a parked submission and waits on
    /// the ring in flight; unlike `close`, it leaves the writer usable.
    pub fn flushAndWait(self: *Self) void {
        while (true) {
            if (self.flush_pending and !self.flush_in_flight) self.driveFlush();
            if (self.flush_in_flight) {
                self.awaitFlush();
                continue;
            }
            if (!self.flush_pending) return;

            // Nothing is in flight and no room could be taken: publish what
            // is pending and re-read the window, then wait for a completion.
            const stream = self.stream orelse return;
            stream.commit() catch return;
            const cqe = stream.ring.popCQE() orelse {
                stream.ring.park();
                continue;
            };
            if (self.ring_sink.inflight) |flush_task| {
                if (cqe.taskIdx() == flush_task) {
                    self.flushResult(cqe);
                    continue;
                }
            }
            self.ring_sink.slots.del(cqe.taskIdx());
        }
    }

    /// Drains the flush queue; releasing the descriptor belongs to the
    /// controller (§1.1).
    ///
    /// A parked submission gets its retry, the flush still in flight is awaited
    /// on the caller's ring, and the queue's slots retire with it. Best effort
    /// under a fault: a stopped writer has no completion left to wait for. The
    /// battery stays where it is — it belongs to the index thread, not to the
    /// file (§A3).
    pub fn drain(self: *Self) void {
        if (self.closed) return;
        self.closed = true;

        if (self.flush_pending and !self.flush_in_flight) self.driveFlush();
        self.awaitFlush();
        if (self.stream != null) {
            self.ring_sink.release();
            self.ring_sink.retire();
        }
    }
};

/// Where a read operation delivers its records (§5).
///
/// The state travels beside the op because the caller sets its own `st.state`
/// from it before applying — `applyIndexOp`'s contract, and the reason the
/// sink is not just the op's bytes.
pub const ReadSink = struct {
    ctx: ?*anyopaque = null,
    apply: *const fn (ctx: ?*anyopaque, state_idx: u128, op: []const u8) anyerror!void,
};

/// One read operation over a `WalReadFile`: the handle a `file_read` slot
/// carries, so its completion steps the walk it belongs to.
///
/// The merged stream is the file's flushed bytes `[0, file_len)` followed, in
/// PMEM mode, by the battery's chain. It is parsed in block-sized pieces; a
/// closed block ends at its padding, everything else is framed alone.
pub const FileReadProcess = struct {
    const Self = @This();

    /// What one operation was asked for.
    pub const Task = union(enum) {
        /// The no-alternative readout: every committed record from the start.
        read_all,
        /// Deliver every record whose state is at or past this one.
        seek_then_read: u128,
    };

    /// Which half of the state machine the next completion steps.
    pub const State = enum { seek, read };

    /// Where the operation's block reads go: the thread's stream window and
    /// slot table on a live ring. The synchronous driver has neither.
    pub const Io = struct {
        stream: *zigring.StreamSQ,
        slots: *slots.RingSlots,
    };

    /// One block read to arm: where it starts and where it lands.
    pub const Request = struct {
        offset: u64,
        dst: []u8,
    };

    /// The file this operation walks.
    file: *WalReadFile,
    task: Task,
    state: State,
    sink: ReadSink,

    /// One block of the merged stream lands here: the file half first, the
    /// battery half copied in behind it.
    buf: []u8,
    /// Bytes of `buf` this block occupies.
    avail: usize = 0,
    /// Bytes of this block the file holds; the rest is battery bytes.
    file_part: usize = 0,
    /// The merged stream's file half: the file's effective length.
    file_len: u64 = 0,
    /// The merged stream's end: `file_len` plus the battery's chain.
    extent: u64 = 0,
    /// The block being armed, loaded or parsed.
    block: u64 = 0,
    /// Seek window: blocks still to probe, and the last probe whose first
    /// record was at or below the target.
    lo: u64 = 0,
    hi: u64 = 0,
    best: ?u64 = null,
    /// Set once the readout has nothing left to deliver.
    done: bool = false,

    /// Steps the state machine as far as it goes without a completion.
    ///
    /// A block made only of battery bytes never reaches the ring — the chain's
    /// half is plain `memcpy` — so it is delivered here and the walk moves on
    /// inside the call. The answer is the block read to arm, or null once
    /// everything the stream holds was delivered.
    pub fn advance(self: *Self) anyerror!?Request {
        while (!self.done) {
            switch (self.state) {
                .seek => {
                    if (self.lo < self.hi) {
                        self.block = (self.lo + self.hi) / 2;
                        return self.stage();
                    }
                    // Converged: the readout starts at the last block found at
                    // or below the target, or at the first record when no block
                    // was.
                    self.state = .read;
                    self.block = self.best orelse 0;
                },
                .read => {
                    if (self.block * BLOCK >= self.extent) {
                        self.done = true;
                        return null;
                    }
                    if (self.stage()) |request| return request;
                    try self.consume(0);
                },
            }
        }
        return null;
    }

    /// A block read landed: `file_bytes` bytes of the block's file half are in
    /// the buffer. The seek probes the block's first record, the readout
    /// parses it.
    pub fn consume(self: *Self, file_bytes: usize) anyerror!void {
        // A short read means the file ended early: the bytes it never returned
        // are not part of the stream.
        self.avail -= self.file_part - file_bytes;
        switch (self.state) {
            .seek => self.probe(),
            .read => {
                try self.parse(self.avail);
                self.block += 1;
            },
        }
    }

    /// Drives the operation to its end.
    ///
    /// With a ring every block read leaves as one `pushReadOffset` through the
    /// stream window and its completion steps the walk — §5's startup driver,
    /// pumping `popCQE`/`park` on the owning index thread. Without one the same
    /// steps run against `pread`, which is how a buffered filesystem and a
    /// logic test read the same stream.
    pub fn drive(self: *Self, io: ?Io) anyerror!void {
        while (true) {
            const request = try self.advance() orelse break;
            const file_bytes = if (io) |ring| try self.ringRead(ring, request) else try self.pread(request);
            try self.consume(file_bytes);
        }
    }

    /// One completion of a read this operation armed: the slot retires, the
    /// block lands and the next read arms on the same stream.
    pub fn onCQE(self: *Self, io: Io, cqe: zigring.CQE) anyerror!void {
        io.slots.del(cqe.taskIdx());
        if (cqe.res < 0) return error.IO;
        try self.consume(@intCast(cqe.res));
        if (try self.advance()) |request| try self.arm(io, request);
    }

    /// Stages `self.block`: the battery half is copied into the buffer and the
    /// file half's read is returned, or null when the block lies entirely in
    /// the battery.
    fn stage(self: *Self) ?Request {
        const start = self.block * BLOCK;
        const avail: usize = @intCast(@min(BLOCK, self.extent - start));
        const file_part: usize = @intCast(@min(avail, self.file_len -| start));
        self.avail = avail;
        self.file_part = file_part;
        if (avail > file_part) self.copyChain(self.buf[file_part..avail], start + file_part);
        if (file_part == 0) return null;
        return .{ .offset = start, .dst = self.buf[0..file_part] };
    }

    /// One seek probe: a mebibyte boundary is always a record start, so the
    /// block's first record decides which half of the window the target falls
    /// in.
    fn probe(self: *Self) void {
        const target = switch (self.task) {
            .seek_then_read => |state_idx| state_idx,
            .read_all => unreachable,
        };

        var first: ?u128 = null;
        if (self.avail != 0) {
            if (decodeRecord(self.buf[0..self.avail])) |record| {
                first = record.state_idx;
            } else |_| {}
        }

        if (first) |state_idx| {
            if (state_idx <= target) {
                self.best = self.block;
                self.lo = self.block + 1;
                return;
            }
        }
        self.hi = self.block;
    }

    /// Parses one block of the merged stream and delivers its records.
    ///
    /// A closed block's CRC match ends parsing at its padding — a padding run
    /// parses as state 0, the reserved empty state framing refuses — and the
    /// walk goes on with the next block. Everything else is framed alone: a
    /// record that does not fit is torn, dropped, and the readout stops there.
    /// Nothing is ever repaired.
    fn parse(self: *Self, avail: usize) anyerror!void {
        const bytes = self.buf[0..avail];
        const closed = avail == BLOCK and closedBlock(bytes);
        const limit = if (closed) BLOCK_CONTENT else avail;

        var pos: usize = 0;
        while (pos < limit) {
            const record = decodeRecord(bytes[pos..limit]) catch {
                if (!closed) self.done = true;
                return;
            };
            try self.deliver(record.state_idx, record.op);
            pos += record.len;
        }
    }

    /// Hands one record to the sink, unless the operation seeks past it. No
    /// arithmetic is done on the state: a jump is legitimate inside one file.
    fn deliver(self: *Self, state_idx: u128, op: []const u8) anyerror!void {
        switch (self.task) {
            .read_all => {},
            .seek_then_read => |target| if (state_idx < target) return,
        }
        try self.sink.apply(self.sink.ctx, state_idx, op);
    }

    /// Copies the battery's chain into the block: the merged stream's second
    /// half is plain `memcpy`, never ring traffic.
    fn copyChain(self: *Self, dst: []u8, offset: u64) void {
        const area = self.file.area orelse return;
        const lba: usize = self.file.lba;
        var copied: usize = 0;
        var at = offset;
        while (copied < dst.len) {
            const ordinal = at / lba;
            const within: usize = @intCast(at % lba);
            const take = @min(dst.len - copied, lba - within);
            const slot = area.data[bufferIdx(ordinal, self.file.buffers) * lba + within ..][0..take];
            @memcpy(dst[copied..][0..take], slot);
            copied += take;
            at += take;
        }
    }

    /// Arms one block read: a slot from the thread's table, the SQE through the
    /// stream window, then the commit that publishes it. Reads carry no
    /// `rw_flags`, and never go through a direct `Ring.push*` — the stream owns
    /// this ring's submission cursor (§F2).
    fn arm(self: *Self, io: Io, request: Request) anyerror!void {
        const task_idx = io.slots.add(.{ .file_read = .{
            .file_process = self,
            .offset = request.offset,
            .buf = request.dst,
        } }) catch return error.NoFreeSlots;

        if (io.stream.pushReadOffset(self.file.fd, task_idx, request.offset, request.dst, .{}) == null) {
            io.slots.del(task_idx);
            return error.RingFull;
        }
        io.stream.commit() catch |err| {
            io.slots.del(task_idx);
            return err;
        };
    }

    /// Arms the read and waits for its completion on the caller's ring.
    ///
    /// A completion that is not this operation's read cannot be stepped here —
    /// the thread's own drain owns everything else — so its slot retires and
    /// the walk waits on.
    fn ringRead(self: *Self, io: Io, request: Request) anyerror!usize {
        while (true) {
            self.arm(io, request) catch |err| switch (err) {
                // The window is momentarily full: nothing was reserved, so the
                // commit slides it and the same read is armed again.
                error.RingFull => {
                    try io.stream.commit();
                    continue;
                },
                else => return err,
            };
            break;
        }

        while (true) {
            const cqe = io.stream.ring.popCQE() orelse {
                io.stream.ring.park();
                continue;
            };
            const mine = if (io.slots.get(cqe.taskIdx())) |ctx| switch (ctx) {
                .file_read => |read| read.file_process == self,
                else => false,
            } else false;
            io.slots.del(cqe.taskIdx());
            if (!mine) continue;
            if (cqe.res < 0) return error.IO;
            return @intCast(cqe.res);
        }
    }

    /// The synchronous driver: one `pread` of the block's file half.
    fn pread(self: *Self, request: Request) anyerror!usize {
        const at: posix.off_t = @intCast(request.offset);
        const res = std.os.linux.pread(self.file.fd, request.dst.ptr, request.dst.len, at);
        const errno = std.os.linux.errno(res);
        if (errno != .SUCCESS) return std.posix.unexpectedErrno(errno);
        return res;
    }
};

/// Whether a full block is closed: its last four bytes are the CRC32C of its
/// content, padding included (§4). A mismatch — or a block the merged stream
/// does not fill — is read by framing alone.
fn closedBlock(bytes: []const u8) bool {
    if (bytes.len != BLOCK) return false;
    const stored = std.mem.readInt(u32, bytes[BLOCK_CONTENT..][0..CRC_LEN], .little);
    return stored == blog.crc32c.hardwareCrc32C(bytes[0..BLOCK_CONTENT]);
}

/// The battery's half of the merged stream: the chain from ordinal `from` on,
/// walked by §5's predicate, in bytes. Plain mode has no chain — its battery is
/// DRAM and gone after a restart.
fn chainLen(file: *const WalReadFile, from: u64) u64 {
    const area = file.area orelse return 0;
    const lba: u64 = file.lba;

    var len: u64 = 0;
    var ordinal = from;
    // The slots ring, and a chain one file writes can never lap it: the writer
    // keeps one buffer free, so it stops at the terminator before the wrap.
    var lap: u32 = 0;
    while (lap < file.buffers) : (lap += 1) {
        const header = &area.headers[bufferIdx(ordinal, file.buffers)];
        switch (walkVerdict(header, ordinal, file.lba)) {
            .full => len += lba,
            .tail => |data_len| return len + data_len,
            else => return len,
        }
        ordinal += 1;
    }
    return len;
}

/// The read side of one WAL file: the descriptor and the pair's geometry.
/// Every read operation mints its own `FileReadProcess`, so several can walk
/// one file — a reader beside a live writer included (§5's concurrency rule).
pub const WalReadFile = struct {
    const Self = @This();

    fd: posix.fd_t,
    host_idx: u8,
    index_idx: u16,
    /// The file's name tag: the state every record in it chains on top of.
    tag: u128,
    lba: u32,
    buffers: u32,
    /// The pair's battery area — the merged stream's second half. PMEM mode
    /// only: a plain battery is DRAM and gone after a restart, so the file is
    /// the only source there.
    area: ?Area,

    /// Opens a reader over `fd`, wired to the pair's geometry. `area` is the
    /// pair's battery in PMEM mode and null in plain mode.
    pub fn init(
        fd: posix.fd_t,
        wal_cfg: config.Wal,
        area: ?Area,
        host_idx: u8,
        index_idx: u16,
        tag: u128,
    ) Self {
        return .{
            .fd = fd,
            .host_idx = host_idx,
            .index_idx = index_idx,
            .tag = tag,
            .lba = wal_cfg.lba(),
            .buffers = wal_cfg.buffers(),
            .area = area,
        };
    }

    /// Mints one read operation over this file: `read_all`, or a seek to a
    /// state and a readout from there. The caller owns the result and releases
    /// it with `endRead`; the walk is driven by `drive` (and stepped by
    /// `onCQE` on a live ring).
    pub fn beginRead(
        self: *Self,
        allocator: std.mem.Allocator,
        task: FileReadProcess.Task,
        sink: ReadSink,
    ) !*FileReadProcess {
        const page = std.heap.pageSize();
        const raw = allocator.rawAlloc(BLOCK, .fromByteUnits(page), @returnAddress()) orelse
            return error.OutOfMemory;
        const buf = raw[0..BLOCK];
        errdefer allocator.rawFree(buf, .fromByteUnits(page), @returnAddress());

        const process = try allocator.create(FileReadProcess);
        errdefer allocator.destroy(process);

        const file_len = flushedLen(try res_handle.fileSize(self.fd), self.lba);
        const file_blocks = (file_len + BLOCK - 1) / BLOCK;
        process.* = .{
            .file = self,
            .task = task,
            .state = .read,
            .sink = sink,
            .buf = buf,
            .file_len = file_len,
            .extent = file_len + chainLen(self, file_len / self.lba),
            .lo = 0,
            .hi = file_blocks,
        };
        // A seek has nothing to search when no block starts inside the file's
        // flushed half: the stream starts at its first record either way.
        switch (task) {
            .seek_then_read => if (file_blocks != 0) {
                process.state = .seek;
            },
            .read_all => {},
        }
        return process;
    }

    /// Releases a read operation's block buffer.
    pub fn endRead(self: *Self, allocator: std.mem.Allocator, process: *FileReadProcess) void {
        _ = self;
        const page = std.heap.pageSize();
        allocator.rawFree(process.buf, .fromByteUnits(page), @returnAddress());
        allocator.destroy(process);
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "records round-trip through their framing" {
    // The op lengths cross the uvarint byte counts: 1 byte up to 127, 2 up to
    // 16383, 3 from 16384 on.
    const op_lens = [_]usize{ 0, 1, 127, 128, 16383, 16384 };
    const state: u128 = 0x112233445566778899aabbccddeeff00;

    for (op_lens) |op_len| {
        const op = try testing.allocator.alloc(u8, op_len);
        defer testing.allocator.free(op);
        for (op, 0..) |*byte, i| byte.* = @truncate(i *% 7 +% 1);

        const framed = try encodeRecord(testing.allocator, state, op);
        defer testing.allocator.free(framed);
        try testing.expectEqual(framedLen(op_len), framed.len);

        const decoded = try decodeRecord(framed);
        try testing.expectEqual(state, decoded.state_idx);
        try testing.expectEqualSlices(u8, op, decoded.op);
        try testing.expectEqual(framed.len, decoded.len);
    }
}

test "a record frames its state, its length and its op" {
    const framed = try encodeRecord(testing.allocator, 0x0102, "ab");
    defer testing.allocator.free(framed);

    // A one-byte uvarint for a two-byte op.
    try testing.expectEqual(@as(usize, 16 + 1 + 2), framed.len);
    // The state is little-endian: its low byte comes first.
    try testing.expectEqual(@as(u8, 0x02), framed[0]);
    try testing.expectEqual(@as(u8, 0x01), framed[1]);
    for (framed[2..16]) |byte| try testing.expectEqual(@as(u8, 0), byte);
    try testing.expectEqual(@as(u8, 2), framed[16]);
    try testing.expectEqualStrings("ab", framed[17..]);

    // An empty op still carries its length byte.
    const empty = try encodeRecord(testing.allocator, 0x0102, "");
    defer testing.allocator.free(empty);
    try testing.expectEqual(@as(usize, 17), empty.len);
    try testing.expectEqual(@as(u8, 0), empty[16]);
    try testing.expectEqual(@as(usize, 0), (try decodeRecord(empty)).op.len);
}

test "a torn frame and a zero state are refused" {
    var op = [_]u8{ 9, 9, 9 };
    const framed = try encodeRecord(testing.allocator, 0x42, &op);
    defer testing.allocator.free(framed);

    // Every strict prefix of a whole frame is a torn tail.
    for (0..framed.len) |cut| {
        try testing.expectError(error.CorruptInput, decodeRecord(framed[0..cut]));
    }

    // State 0 is the padding sentinel and the reserved empty state.
    var zero: [24]u8 = @splat(0);
    try testing.expectError(error.InvalidStateIdx, decodeRecord(&zero));

    // A varint that never terminates runs off the extent.
    var overlong: [32]u8 = @splat(0);
    overlong[0] = 1;
    @memset(overlong[16..27], 0x80);
    try testing.expectError(error.CorruptInput, decodeRecord(&overlong));
}

test "framed lengths match the uvarint widths" {
    try testing.expectEqual(@as(usize, 16 + 1 + 0), framedLen(0));
    try testing.expectEqual(@as(usize, 16 + 1 + 127), framedLen(127));
    try testing.expectEqual(@as(usize, 16 + 2 + 128), framedLen(128));
    try testing.expectEqual(@as(usize, 16 + 2 + 16383), framedLen(16383));
    try testing.expectEqual(@as(usize, 16 + 3 + 16384), framedLen(16384));
}

test "padding a block's tail closes it on a buffer boundary" {
    const lbas = [_]u32{ 512, 1024, 4096, 16384, 65536, 1 << 20 };

    for (lbas) |lba| {
        // Validated in the config: a block close is always a buffer fill.
        try testing.expectEqual(@as(usize, 0), BLOCK % lba);
        const buffers = BLOCK / lba;

        var ordinal: u64 = 0;
        while (ordinal < 3 * buffers) : (ordinal += 1) {
            const offset = ordinal * lba;
            try testing.expectEqual(offset / BLOCK, blockOf(offset));
            try testing.expectEqual(
                @as(usize, @intCast((ordinal % buffers) * lba)),
                inBlockOffset(offset),
            );
            try testing.expectEqual(offset != 0 and inBlockOffset(offset) == 0, closesBlock(offset));

            // Padding the content remainder plus the CRC slot fills whole
            // buffers, so the slot never straddles two of them.
            const remain = blockRemain(offset);
            const closed_at = offset + remain + CRC_LEN;
            try testing.expectEqual(@as(usize, BLOCK), inBlockOffset(offset) + remain + CRC_LEN);
            try testing.expectEqual(@as(usize, 0), (remain + CRC_LEN) % lba);
            try testing.expect(closesBlock(closed_at));
            // The next record starts at the next block's first buffer.
            try testing.expectEqual(@as(usize, BLOCK_CONTENT), blockRemain(closed_at));
        }
    }

    try testing.expect(!closesBlock(0));
    try testing.expect(closesBlock(BLOCK));
    try testing.expect(closesBlock(3 * BLOCK));
    try testing.expect(!closesBlock(BLOCK - CRC_LEN));
}

test "the largest record a block holds is exactly BLOCK_CONTENT" {
    // 16 + uvarint + op == 1 MiB - 4: the op length that lands exactly, with
    // the three-byte uvarint such an op's length needs.
    const exact = BLOCK_CONTENT - 16 - 3;
    try testing.expectEqual(@as(usize, 3), resources.uvarintLen(exact));
    try testing.expectEqual(BLOCK_CONTENT, framedLen(exact));
    try testing.expectEqual(blockRemain(0), framedLen(exact));

    // One byte more fits no block, fresh or not.
    try testing.expect(framedLen(exact + 1) > blockRemain(0));
    try testing.expect(framedLen(exact + 1) > blockRemain(BLOCK));
}

test "the seeded fold composes over random splits" {
    var prng = std.Random.DefaultPrng.init(0x00C0_FFEE_1234_5678);
    const random = prng.random();

    var whole: [4096]u8 = undefined;
    random.bytes(&whole);

    // The fold's start of a block prefix is the CRC of nothing, which is zero.
    try testing.expectEqual(@as(u32, 0), blog.crc32c.hardwareCrc32C(whole[0..0]));
    try testing.expectEqual(
        blog.crc32c.hardwareCrc32C(whole[0..64]),
        blog.crc32c.composedCrc32C(0, whole[0..64]),
    );

    for (0..200) |_| {
        const a_len = random.intRangeAtMost(usize, 0, whole.len);
        const b_len = random.intRangeAtMost(usize, 0, whole.len - a_len);
        const total = a_len + b_len;
        const a = whole[0..a_len];
        const b = whole[a_len..][0..b_len];

        try testing.expectEqual(
            blog.crc32c.hardwareCrc32C(whole[0..total]),
            blog.crc32c.composedCrc32C(blog.crc32c.hardwareCrc32C(a), b),
        );

        // The same bytes folded piece by piece give the same CRC.
        var piecewise: u32 = 0;
        var split: usize = 0;
        while (split < total) {
            const piece_len = random.intRangeAtMost(usize, 1, total - split);
            piecewise = blog.crc32c.composedCrc32C(piecewise, whole[split..][0..piece_len]);
            split += piece_len;
        }
        try testing.expectEqual(blog.crc32c.hardwareCrc32C(whole[0..total]), piecewise);
    }
}

test "wal paths render 32 lowercase hex digits of the state" {
    const path = try walPath(testing.allocator, "wal", 3, 7, 0xABCDEF);
    defer testing.allocator.free(path);

    try testing.expectEqualStrings("wal/wal.3.7.00000000000000000000000000abcdef", path);
}

test "wal paths zero-pad a full-width state" {
    const state: u128 = 0x000102030405060708090a0b0c0d0e0f;
    const path = try walPath(testing.allocator, "/var/lib/mpy6a", 0, 0, state);
    defer testing.allocator.free(path);

    try testing.expectEqualStrings(
        "/var/lib/mpy6a/wal.0.0.000102030405060708090a0b0c0d0e0f",
        path,
    );
}

test "the pair area index is thread-major" {
    // Two indexes over three hosts: every index owns a contiguous run of
    // areas, hosts inside it.
    try testing.expectEqual(@as(usize, 0), areaIndex(0, 0, 3));
    try testing.expectEqual(@as(usize, 2), areaIndex(2, 0, 3));
    try testing.expectEqual(@as(usize, 3), areaIndex(0, 1, 3));
    try testing.expectEqual(@as(usize, 5), areaIndex(2, 1, 3));
}

test "area strides keep every pair's data array LBA-aligned" {
    const page_sizes = [_]usize{ 4096, 16384 };
    const lbas = [_]u32{ 512, 1024, 4096, 16384, 1 << 20 };
    const buffer_counts = [_]u32{ 2, 3, 7, 32, 64 };

    for (page_sizes) |page| {
        for (lbas) |lba| {
            const granule = areaGranule(lba, page);
            try testing.expectEqual(@max(@as(usize, lba), page), granule);

            for (buffer_counts) |buffers| {
                const stride = areaStride(buffers, lba, page);

                // The stride is a granule multiple, so the next pair's data
                // array starts as aligned as this one.
                try testing.expectEqual(@as(usize, 0), stride % granule);

                // Both columnar arrays fit inside the area.
                const headers_end = headerOffsetInArea(buffers, lba, buffers);
                try testing.expect(headers_end <= stride);

                for (0..buffers) |idx| {
                    const data_at = dataOffsetInArea(lba, idx);
                    try testing.expectEqual(@as(usize, 0), data_at % lba);
                    try testing.expect(data_at + lba <= headerOffsetInArea(buffers, lba, 0));

                    const header_at = headerOffsetInArea(buffers, lba, idx);
                    try testing.expectEqual(@as(usize, 0), header_at % 16);
                    try testing.expect(header_at + HEADER <= stride);
                }
            }
        }
    }
}

test "buffer indexes wrap at the ring depth" {
    try testing.expectEqual(@as(usize, 0), bufferIdx(0, 32));
    try testing.expectEqual(@as(usize, 31), bufferIdx(31, 32));
    try testing.expectEqual(@as(usize, 0), bufferIdx(32, 32));
    try testing.expectEqual(@as(usize, 1), bufferIdx(33, 32));
    // 2^64 - 1 is a multiple of 3, and the ring wraps to its first slot.
    try testing.expectEqual(@as(usize, 0), bufferIdx(std.math.maxInt(u64), 3));
}

test "the area stride hosts a control line after the header array" {
    const page_sizes = [_]usize{ 4096, 16384 };
    const lbas = [_]u32{ 512, 1024, 4096, 16384, 1 << 20 };
    const buffer_counts = [_]u32{ 4, 7, 32, 64 };
    const pairs: usize = 3;
    const slot_count: usize = 5;

    for (page_sizes) |page| {
        for (lbas) |lba| {
            for (buffer_counts) |buffers| {
                const stride = areaStride(buffers, lba, page);
                const control_at = controlLineOffsetInArea(buffers, lba);

                // The control line sits right after the header array and fits
                // inside the area, 8-byte aligned like the struct it holds.
                try testing.expectEqual(headerOffsetInArea(buffers, lba, buffers), control_at);
                try testing.expectEqual(@as(usize, 0), control_at % 8);
                try testing.expect(control_at + HEADER <= stride);

                // The battery is one area per pair plus one per temp ring.
                const last_temp = tempAreaIdx(@intCast(slot_count - 1), pairs);
                try testing.expectEqual(pairs + slot_count, last_temp + 1);
                try testing.expectEqual((pairs + slot_count) * stride, batterySize(last_temp + 1, stride));
            }
        }
    }
}

test "the mint kills a stale temp ring and publishes the ordinal-0 terminator" {
    const page = std.heap.pageSize();
    const wal_cfg: config.Wal = .{ .plain = .{ .dir = "wal", .buffers = 4, .lba = config.kib(1) } };
    const stride = areaStride(4, 1024, page);

    const bytes = try openTestBattery(testing.allocator, wal_cfg, 1, stride, page);
    defer closeTestBattery(testing.allocator, wal_cfg, bytes, page);

    const area = Area.init(bytes, 4, 1024);

    // A used ring from a previous procedure: stale lines and a live mark.
    @memset(std.mem.sliceAsBytes(area.headers), 0xFF);
    @memset(area.data, 0x5A);
    controlLineOf(bytes, 4, 1024).* = .{
        .data_len = 0,
        .flags = 0,
        .buffer_seq = 9,
        .crc_running = 3,
        .snapshot_in_progress = 1,
        .new_wal_buffer_idx = 2,
        .last_state = 0xDEAD,
        .target_state = 0xBEEF,
        ._pad_tail = @splat(0),
    };

    mintArea(bytes, 4, 1024, 0x777, false);

    for (0..4) |ordinal| {
        switch (walkVerdict(&area.headers[ordinal], ordinal, 1024)) {
            .terminator => try testing.expectEqual(@as(usize, 0), ordinal),
            .stale => {},
            else => return error.TestUnexpectedResult,
        }
    }
    const header = area.headers[0];
    try testing.expectEqual(@as(u64, 0), header.buffer_seq);
    try testing.expectEqual(@as(u32, 0), header.data_len);
    try testing.expectEqual(@as(u32, 0), header.flags);
    try testing.expectEqual(@as(u32, 0), header.crc_running);
    try testing.expectEqual(@as(u128, 0x777), header.last_state);
    try testing.expectEqual(@as(u128, 0), header.target_state);
    try testing.expectEqual(@as(u8, 0), controlLineOf(bytes, 4, 1024).snapshot_in_progress);
    // The data array is not zeroed: stale bytes hide behind stale headers.
    try testing.expectEqual(@as(u8, 0x5A), area.data[0]);

    // A second mint over a ring the writer used re-kills every line it left.
    var writer = WalWriteFile.init(.{}, area, wal_cfg, 0, 0, 0x777);
    var data: [3]u8 = .{ 1, 2, 3 };
    try writer.write(0x778, 0x777, &data);
    try testing.expectEqual(@as(u64, 0), area.headers[0].buffer_seq);

    mintArea(bytes, 4, 1024, 0x800, false);
    try testing.expectEqual(@as(u128, 0x800), area.headers[0].last_state);
    for (0..4) |ordinal| {
        switch (walkVerdict(&area.headers[ordinal], ordinal, 1024)) {
            .terminator => try testing.expectEqual(@as(usize, 0), ordinal),
            .stale => {},
            else => return error.TestUnexpectedResult,
        }
    }
}

test "the walk never reaches the temp section" {
    const page = std.heap.pageSize();
    const wal_cfg: config.Wal = .{ .plain = .{ .dir = "wal", .buffers = 4, .lba = config.kib(1) } };
    const stride = areaStride(4, 1024, page);

    // Two areas: a minted pair area, then a temp ring carrying a chain that
    // would look continuable if the walk crossed the area boundary.
    const bytes = try openTestBattery(testing.allocator, wal_cfg, 2, stride, page);
    defer closeTestBattery(testing.allocator, wal_cfg, bytes, page);

    mintArea(bytes[0..stride], 4, 1024, 0x10, false);
    const temp = Area.init(bytes[stride..][0..stride], 4, 1024);
    for (temp.headers, 0..) |*header, ordinal| {
        header.* = .{
            .data_len = 1024,
            .flags = FLAG_FILLED,
            .buffer_seq = ordinal,
            .crc_running = 0,
            .snapshot_in_progress = 0,
            .new_wal_buffer_idx = 0,
            .last_state = 0,
            .target_state = 0,
            ._pad_tail = @splat(0),
        };
    }

    const pair_area = Area.init(bytes[0..stride], 4, 1024);
    const reader = WalReadFile.init(-1, wal_cfg, pair_area, 0, 0, 0x10);
    // The pair's stream ends at its own terminator; the temp ring behind it is
    // reached only through a writer wired to it or the adoption mark.
    try testing.expectEqual(@as(u64, 0), chainLen(&reader, 0));
}

test "a plain battery is allocated zeroed and carved by stride" {
    const page = std.heap.pageSize();
    const wal_cfg: config.Wal = .{ .plain = .{ .dir = "wal", .buffers = 4, .lba = config.kib(4) } };
    const pairs: usize = 3;
    const stride = areaStride(4, 4096, page);

    const bytes = try openTestBattery(testing.allocator, wal_cfg, pairs, stride, page);
    defer closeTestBattery(testing.allocator, wal_cfg, bytes, page);

    try testing.expectEqual(batterySize(pairs, stride), bytes.len);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(bytes.ptr) % areaGranule(4096, page));
    for (bytes) |byte| try testing.expectEqual(@as(u8, 0), byte);

    // Every pair's area yields the two columnar arrays, headers empty.
    for (0..pairs) |pair| {
        const area = Area.init(bytes[pair * stride ..][0..stride], 4, 4096);
        try testing.expectEqual(@as(usize, 4 * 4096), area.data.len);
        try testing.expectEqual(@as(usize, 4), area.headers.len);
        try testing.expectEqual(@as(usize, 0), @intFromPtr(area.data.ptr) % 4096);
        for (area.headers) |header| {
            try testing.expectEqual(@as(u32, 0), header.data_len);
            try testing.expectEqual(@as(u64, 0), header.buffer_seq);
        }
    }
}

test "a header publish overwrites the whole control line" {
    const page = std.heap.pageSize();
    const wal_cfg: config.Wal = .{ .plain = .{ .dir = "wal", .buffers = 4, .lba = config.kib(4) } };
    const stride = areaStride(4, 4096, page);

    const bytes = try openTestBattery(testing.allocator, wal_cfg, 1, stride, page);
    defer closeTestBattery(testing.allocator, wal_cfg, bytes, page);

    var writer = WalWriteFile.init(.{}, Area.init(bytes, 4, 4096), wal_cfg, 0, 0, 0x1234);

    // A line that still carries a previous procedure's mark: the publish
    // rewrites it whole, so no ring line can ever expose migration state.
    writer.headers[bufferIdx(3, 4)] = .{
        .data_len = 17,
        .flags = 0,
        .buffer_seq = 3,
        .crc_running = 9,
        .snapshot_in_progress = 1,
        .new_wal_buffer_idx = 5,
        .last_state = 0xDEAD,
        .target_state = 0xBEEF,
        ._pad_tail = @splat(0xFF),
    };

    // Ordinal 3 sits inside block 0, so the resume pair carries a running
    // value, not the register seed.
    writer.publishTerminator(3, 0x5678, 0x1234_5678);
    const header = writer.headers[bufferIdx(3, 4)];
    try testing.expectEqual(@as(u32, 0), header.data_len);
    try testing.expectEqual(@as(u32, 0), header.flags);
    try testing.expectEqual(@as(u64, 3), header.buffer_seq);
    try testing.expectEqual(@as(u32, 0x1234_5678), header.crc_running);
    try testing.expectEqual(@as(u128, 0x5678), header.last_state);
    // Adoption state is zero forever on a ring line.
    try testing.expectEqual(@as(u8, 0), header.snapshot_in_progress);
    try testing.expectEqual(@as(u16, 0), header.new_wal_buffer_idx);
    try testing.expectEqual(@as(u128, 0), header.target_state);

    // The buffer's data lives at the offset its ordinal prescribes.
    try testing.expectEqual(@as(usize, 3 * 4096), @intFromPtr(writer.bufferData(3).ptr) - @intFromPtr(writer.data.ptr));
    try testing.expectEqual(@as(usize, 0), @intFromPtr(writer.bufferData(4).ptr) - @intFromPtr(writer.data.ptr));
}

test "the control line keeps its pinned layout with the adoption fields" {
    try testing.expectEqual(@as(usize, HEADER), @sizeOf(BufferHeader));
    try testing.expectEqual(@as(usize, 0), @offsetOf(BufferHeader, "data_len"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(BufferHeader, "buffer_seq"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(BufferHeader, "crc_running"));
    try testing.expectEqual(@as(usize, 20), @offsetOf(BufferHeader, "snapshot_in_progress"));
    try testing.expectEqual(@as(usize, 22), @offsetOf(BufferHeader, "new_wal_buffer_idx"));
    try testing.expectEqual(@as(usize, 24), @offsetOf(BufferHeader, "last_state"));
    try testing.expectEqual(@as(usize, 40), @offsetOf(BufferHeader, "target_state"));
    try testing.expectEqual(@as(usize, 8), @sizeOf(@FieldType(BufferHeader, "_pad_tail")));
}

test "a fresh writer chains from its tag" {
    const page = std.heap.pageSize();
    const plain: config.Wal = .{ .plain = .{ .dir = "wal", .buffers = 4, .lba = config.kib(1) } };
    const pmem: config.Wal = .{ .pmem = .{ .dir = "wal", .device = "/dev/dax0.0", .buffers = 4, .lba = config.kib(1) } };
    const stride = areaStride(4, 1024, page);

    // The area's shape does not depend on the mode, so one plain allocation
    // serves the field wiring of both.
    const bytes = try openTestBattery(testing.allocator, plain, 1, stride, page);
    defer closeTestBattery(testing.allocator, plain, bytes, page);

    const area = Area.init(bytes, 4, 1024);
    const writer = WalWriteFile.init(.{}, area, plain, 1, 2, 0xAA);
    try testing.expectEqual(@as(u128, 0xAA), writer.tag);
    try testing.expectEqual(@as(u128, 0xAA), writer.head);
    try testing.expectEqual(@as(u64, 0), writer.flushed_upto);
    try testing.expect(!writer.flush_in_flight);
    try testing.expect(!writer.flush_pending);
    try testing.expect(!writer.faulted);
    try testing.expect(!writer.pmem);
    try testing.expect(WalWriteFile.init(.{}, area, pmem, 1, 2, 0xAA).pmem);
}

test "the admission guards refuse without moving anything" {
    const page = std.heap.pageSize();
    const wal_cfg: config.Wal = .{ .plain = .{ .dir = "wal", .buffers = 4, .lba = config.kib(1) } };
    const stride = areaStride(4, 1024, page);

    const bytes = try openTestBattery(testing.allocator, wal_cfg, 1, stride, page);
    defer closeTestBattery(testing.allocator, wal_cfg, bytes, page);

    var writer = WalWriteFile.init(.{}, Area.init(bytes, 4, 1024), wal_cfg, 0, 0, 0x10);
    writer.publishTerminator(0, 0x10, 0);
    const before = writer.headers[0];

    var op = [_]u8{ 1, 2, 3 };
    try testing.expectError(error.WalGap, writer.write(0x12, 0x11, &op));
    try testing.expectError(error.InvalidStateIdx, writer.write(0, 0x10, &op));
    try testing.expectEqual(@as(u128, 0x10), writer.head);
    try testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&before),
        std.mem.asBytes(&writer.headers[0]),
    );

    writer.faulted = true;
    try testing.expectError(error.WalFaulted, writer.write(0x12, 0x10, &op));
    try testing.expectEqual(@as(u128, 0x10), writer.head);
}

// ============================================================================
// The write path (stage C)
// ============================================================================

/// Acquires a battery for the fixtures below: `areas × stride` bytes aligned to
/// the area granule. Plain mode allocates zeroed ordinary memory, PMEM mode
/// maps `device` as found. Unlike the controller's battery, this one serves
/// arbitrary geometries, so it keeps its own bodies.
fn openTestBattery(
    allocator: std.mem.Allocator,
    wal_cfg: config.Wal,
    areas: usize,
    stride: usize,
    page_size: usize,
) ![]u8 {
    const total = batterySize(areas, stride);
    const alignment: std.mem.Alignment = .fromByteUnits(areaGranule(wal_cfg.lba(), page_size));

    switch (wal_cfg) {
        .plain => {
            const raw = allocator.rawAlloc(total, alignment, @returnAddress()) orelse
                return error.OutOfMemory;
            const bytes = raw[0..total];
            @memset(bytes, 0);
            return bytes;
        },
        .pmem => |pmem| {
            const path = try allocator.dupeSentinel(u8, pmem.device, 0);
            defer allocator.free(path);

            const fd_raw = std.os.linux.open(path, .{ .ACCMODE = .RDWR }, 0);
            const open_errno = std.os.linux.errno(fd_raw);
            if (open_errno != .SUCCESS) return std.posix.unexpectedErrno(open_errno);
            const fd: posix.fd_t = @intCast(fd_raw);
            defer _ = std.os.linux.close(fd);

            const size = try res_handle.fileSize(fd);
            if (size < total) return error.WalBatteryTooSmall;

            return try posix.mmap(
                null,
                total,
                .{ .READ = true, .WRITE = true },
                .{ .TYPE = .SHARED },
                fd,
                0,
            );
        },
    }
}

/// Releases a battery acquired by `openTestBattery`, matching its mode.
fn closeTestBattery(
    allocator: std.mem.Allocator,
    wal_cfg: config.Wal,
    bytes: []u8,
    page_size: usize,
) void {
    switch (wal_cfg) {
        .plain => allocator.rawFree(
            bytes,
            .fromByteUnits(areaGranule(wal_cfg.lba(), page_size)),
            @returnAddress(),
        ),
        .pmem => _ = std.os.linux.munmap(bytes.ptr, bytes.len),
    }
}

/// One pair's battery with a writer wired on it. The descriptor is a
/// placeholder: this stage's flushes end in the seam, not in the kernel.
const Pair = struct {
    /// What the writer sees: the mode decides the publishes and the flush flags.
    wal_cfg: config.Wal,
    /// How the bytes were acquired — always ordinary memory here, so a
    /// PMEM-shaped pair is the barrier module's no-op seam over DRAM.
    battery_cfg: config.Wal,
    stride: usize,
    bytes: []u8,
    writer: WalWriteFile,

    /// The pair the write-path suite drives: plain while the barrier's
    /// publishes are real, PMEM-shaped once they are compiled out. That is the
    /// plan's §E1 seam read from the other side — with no writeback left, a
    /// PMEM battery of ordinary memory is just memory, so the same suite proves
    /// the mode adds nothing but the persistence.
    ///
    /// `lba` is raw bytes here: these tests cover internal geometry down to a
    /// 512-byte LBA, which a config document can no longer express.
    fn acquire(buffers: u32, lba: u32, tag: u128) !Pair {
        if (barrier.enabled) {
            const wal_cfg: config.Wal = .{ .plain = .{ .dir = "wal", .buffers = buffers, .lba = .{ .raw = lba } } };
            return acquireIn(wal_cfg, buffers, lba, tag);
        }
        return acquirePmem(buffers, lba, tag);
    }

    /// A PMEM-shaped pair: the writer publishes through the barrier module and
    /// flushes with `RWF.DSYNC`, over a battery carved out of ordinary memory.
    fn acquirePmem(buffers: u32, lba: u32, tag: u128) !Pair {
        const wal_cfg: config.Wal = .{
            .pmem = .{ .dir = "wal", .device = "wal", .buffers = buffers, .lba = .{ .raw = lba } },
        };
        return acquireIn(wal_cfg, buffers, lba, tag);
    }

    fn acquireIn(wal_cfg: config.Wal, buffers: u32, lba: u32, tag: u128) !Pair {
        const battery_cfg: config.Wal = .{ .plain = .{ .dir = "wal", .buffers = buffers, .lba = .{ .raw = lba } } };
        const page = std.heap.pageSize();
        const stride = areaStride(buffers, lba, page);
        const bytes = try openTestBattery(testing.allocator, battery_cfg, 1, stride, page);

        var pair = Pair{
            .wal_cfg = wal_cfg,
            .battery_cfg = battery_cfg,
            .stride = stride,
            .bytes = bytes,
            .writer = WalWriteFile.init(.{}, Area.init(bytes, buffers, lba), wal_cfg, 0, 0, tag),
        };
        // What adoption publishes before the registry append: the ordinal-0
        // zero-terminator, carrying the tag as its resume state.
        pair.writer.publishTerminator(0, tag, 0);
        return pair;
    }

    fn release(self: *Pair) void {
        closeTestBattery(testing.allocator, self.battery_cfg, self.bytes, std.heap.pageSize());
    }
};

/// The sink the tests drive by hand: `room` can refuse, `submit` counts the
/// ordinal and completes at once unless `hold` is set. A held sink is how a
/// test sees the battery's committed lines without the reclamation that
/// follows a completed flush.
const TestSink = struct {
    var submits: usize = 0;
    var last_ordinal: u64 = 0;
    var hold: bool = true;
    var refusal: ?WalError = null;

    fn reset(hold_completions: bool) void {
        submits = 0;
        last_ordinal = 0;
        hold = hold_completions;
        refusal = null;
    }

    fn room(ctx: ?*anyopaque, writer: *WalWriteFile) WalError!void {
        _ = ctx;
        _ = writer;
        if (refusal) |err| return err;
    }

    fn submit(ctx: ?*anyopaque, writer: *WalWriteFile, ordinal: u64) void {
        _ = ctx;
        std.debug.assert(writer.flush_in_flight);
        submits += 1;
        last_ordinal = ordinal;
        if (hold) return;
        writer.flushComplete(ordinal);
    }

    fn install(writer: *WalWriteFile) void {
        writer.sink = .{ .room = room, .submit = submit };
    }
};

/// Records every persisted control line in order, so a test can assert the
/// terminator-before-commit rule and the commit-last shape.
const PublishLog = struct {
    const Entry = struct {
        seq: u64,
        data_len: u32,
        crc: u32,
        filled: bool,
        last_state: u128,
    };

    var entries: [4096]Entry = undefined;
    var len: usize = 0;

    fn reset() void {
        len = 0;
    }

    fn hook(writer: *WalWriteFile, header: *BufferHeader) void {
        _ = writer;
        if (len >= entries.len) return;
        entries[len] = .{
            .seq = header.buffer_seq,
            .data_len = header.data_len,
            .crc = header.crc_running,
            .filled = header.flags & FLAG_FILLED != 0,
            .last_state = header.last_state,
        };
        len += 1;
    }

    fn install(writer: *WalWriteFile) void {
        writer.persist_hook = hook;
    }
};

/// Everything an admission refusal must leave untouched: every control line
/// plus the writer's own scalars.
const Snapshot = struct {
    headers: []BufferHeader,
    head: u128,
    current: u64,
    cursor: u32,
    flushed_upto: u64,
    free: usize,

    fn take(writer: *const WalWriteFile) !Snapshot {
        return .{
            .headers = try testing.allocator.dupe(BufferHeader, writer.headers),
            .head = writer.head,
            .current = writer.current,
            .cursor = writer.cursor,
            .flushed_upto = writer.flushed_upto,
            .free = writer.freeBuffers(),
        };
    }

    fn deinit(self: *Snapshot) void {
        testing.allocator.free(self.headers);
    }

    fn expectUnchanged(self: *const Snapshot, writer: *const WalWriteFile) !void {
        try testing.expectEqual(self.head, writer.head);
        try testing.expectEqual(self.current, writer.current);
        try testing.expectEqual(self.cursor, writer.cursor);
        try testing.expectEqual(self.flushed_upto, writer.flushed_upto);
        try testing.expectEqual(self.free, writer.freeBuffers());
        for (self.headers, writer.headers) |before, after| {
            try testing.expectEqualSlices(u8, std.mem.asBytes(&before), std.mem.asBytes(&after));
        }
    }
};

/// An op payload of `len` bytes, seeded so different records differ.
fn payload(allocator: std.mem.Allocator, len: usize, seed: u8) ![]u8 {
    const data = try allocator.alloc(u8, len);
    for (data, 0..) |*byte, i| byte.* = @truncate(i *% 31 +% seed);
    return data;
}

test "a record lands in the current buffer and commits last" {
    var pair = try Pair.acquire(4, 512, 0x100);
    defer pair.release();

    TestSink.reset(true);
    TestSink.install(&pair.writer);
    PublishLog.reset();
    PublishLog.install(&pair.writer);

    const data = try payload(testing.allocator, 5, 1);
    defer testing.allocator.free(data);
    const framed = try encodeRecord(testing.allocator, 0x101, data);
    defer testing.allocator.free(framed);

    try pair.writer.write(0x101, 0x100, data);
    try testing.expectEqual(@as(u128, 0x101), pair.writer.head);

    // The op-start buffer's control line is the commit: the record's length,
    // its fold and its state.
    const header = pair.writer.headers[0];
    try testing.expectEqual(@as(u64, 0), header.buffer_seq);
    try testing.expectEqual(@as(u32, @intCast(framed.len)), header.data_len);
    try testing.expectEqual(@as(u32, 0), header.flags);
    try testing.expectEqual(blog.crc32c.hardwareCrc32C(framed), header.crc_running);
    try testing.expectEqual(@as(u128, 0x101), header.last_state);
    try testing.expectEqual(@as(u32, @intCast(framed.len)), pair.writer.cursor);
    try testing.expectEqualSlices(u8, framed, pair.writer.bufferData(0)[0..framed.len]);

    // Nothing else was published, and that publish was the last one.
    try testing.expectEqual(@as(usize, 1), PublishLog.len);
    try testing.expectEqual(@as(u64, 0), PublishLog.entries[0].seq);
    try testing.expectEqual(@as(u32, @intCast(framed.len)), PublishLog.entries[0].data_len);
}

test "trackedExtent counts the buffered tail" {
    var pair = try Pair.acquire(8, 512, 0x100);
    defer pair.release();

    TestSink.reset(false);
    TestSink.install(&pair.writer);

    try testing.expectEqual(@as(u64, 0), pair.writer.trackedExtent());

    const small = try payload(testing.allocator, 5, 1);
    defer testing.allocator.free(small);
    try pair.writer.write(0x101, 0x100, small);
    try testing.expectEqual(
        @as(u64, @intCast(framedLen(small.len))),
        pair.writer.trackedExtent(),
    );

    // A record spanning into the next buffer moves the extent with it.
    const big = try payload(testing.allocator, 700, 2);
    defer testing.allocator.free(big);
    try pair.writer.write(0x102, 0x101, big);
    try testing.expectEqual(
        pair.writer.current * pair.writer.lba + pair.writer.cursor,
        pair.writer.trackedExtent(),
    );
    try testing.expectEqual(
        @as(u64, @intCast(framedLen(small.len) + framedLen(big.len))),
        pair.writer.trackedExtent(),
    );
}

test "a record spanning buffers publishes the successors first" {
    var pair = try Pair.acquire(4, 512, 0x10);
    defer pair.release();

    TestSink.reset(true);
    TestSink.install(&pair.writer);
    PublishLog.reset();
    PublishLog.install(&pair.writer);

    const data = try payload(testing.allocator, 700, 3);
    defer testing.allocator.free(data);
    const framed = try encodeRecord(testing.allocator, 0x11, data);
    defer testing.allocator.free(framed);
    // 16 bytes of state, a two-byte length and 700 bytes: 718, so the record
    // fills the first buffer and leaves 206 bytes in the second.
    try testing.expectEqual(@as(usize, 718), framed.len);

    try pair.writer.write(0x11, 0x10, data);

    // The predecessor is a whole buffer holding no record end, so it carries
    // the state the write started from.
    const first = pair.writer.headers[0];
    try testing.expectEqual(@as(u32, 512), first.data_len);
    try testing.expectEqual(FLAG_FILLED, first.flags);
    try testing.expectEqual(blog.crc32c.hardwareCrc32C(framed[0..512]), first.crc_running);
    try testing.expectEqual(@as(u128, 0x10), first.last_state);

    // The successor holds the record's end: a live tail with its fold and its
    // state.
    const second = pair.writer.headers[1];
    try testing.expectEqual(@as(u32, 206), second.data_len);
    try testing.expectEqual(@as(u32, 0), second.flags);
    try testing.expectEqual(blog.crc32c.hardwareCrc32C(framed), second.crc_running);
    try testing.expectEqual(@as(u128, 0x11), second.last_state);
    try testing.expectEqualSlices(u8, framed, pair.writer.data[0 .. 512 + 206]);

    // The successor's terminator was persisted before its own bytes were
    // committed, and the op-start buffer's commit came last.
    try testing.expectEqual(@as(usize, 3), PublishLog.len);
    try testing.expectEqual(@as(u64, 1), PublishLog.entries[0].seq);
    try testing.expectEqual(@as(u32, 0), PublishLog.entries[0].data_len);
    try testing.expectEqual(blog.crc32c.hardwareCrc32C(framed[0..512]), PublishLog.entries[0].crc);
    try testing.expectEqual(@as(u64, 1), PublishLog.entries[1].seq);
    try testing.expectEqual(@as(u32, 206), PublishLog.entries[1].data_len);
    try testing.expectEqual(@as(u64, 0), PublishLog.entries[2].seq);
    try testing.expectEqual(@as(u32, 512), PublishLog.entries[2].data_len);
    try testing.expect(PublishLog.entries[2].filled);
}

test "the headers carry the head a recovery resumes from" {
    var pair = try Pair.acquire(16, 512, 0x50);
    defer pair.release();

    TestSink.reset(true);
    TestSink.install(&pair.writer);

    const data = try payload(testing.allocator, 1800, 5);
    defer testing.allocator.free(data);

    var state: u128 = 0x50;
    for (0..3) |_| {
        try pair.writer.write(state + 1, state, data);
        state += 1;
    }
    try testing.expectEqual(state, pair.writer.head);

    // The newest control line holds the last committed record's state, so a
    // walk that trusts the chain recovers the writer's head from it.
    var newest: BufferHeader = pair.writer.headers[0];
    for (pair.writer.headers) |header| {
        if (header.data_len == 0 and header.flags & FLAG_FILLED == 0) continue;
        if (header.buffer_seq > newest.buffer_seq or newest.data_len == 0) newest = header;
    }
    try testing.expectEqual(pair.writer.current, newest.buffer_seq);
    try testing.expectEqual(pair.writer.cursor, newest.data_len);
    try testing.expectEqual(pair.writer.head, newest.last_state);
}

test "a block's tail is padded and closed with its CRC" {
    // A block holds sixteen buffers of this geometry, so the whole block stays
    // in the battery for the CRC check.
    var pair = try Pair.acquire(32, 65536, 0x200);
    defer pair.release();

    TestSink.reset(true);
    TestSink.install(&pair.writer);

    const data = try payload(testing.allocator, 60000, 9);
    defer testing.allocator.free(data);
    const framed_len = framedLen(data.len);
    try testing.expectEqual(@as(usize, 60019), framed_len);

    var state: u128 = 0x200;
    // Records while they still fit the open block's content remainder.
    while (blockRemain(pair.writer.current * 65536 + pair.writer.cursor) >= framed_len) {
        try pair.writer.write(state + 1, state, data);
        state += 1;
    }
    try testing.expectEqual(@as(u128, 0x200 + 17), pair.writer.head);
    const last_ordinal = pair.writer.current;
    try testing.expectEqual(@as(u64, 15), last_ordinal);
    const pad_start = last_ordinal * 65536 + pair.writer.cursor;
    try testing.expectEqual(
        @as(usize, @intCast(BLOCK - CRC_LEN - pad_start)),
        blockRemain(pad_start),
    );

    // The record that does not fit pads the block's tail and starts the next
    // block's first buffer.
    const before_pad = try testing.allocator.dupe(u8, pair.writer.data[pad_start..][0 .. BLOCK - CRC_LEN - pad_start]);
    defer testing.allocator.free(before_pad);
    try pair.writer.write(state + 1, state, data);
    state += 1;

    try testing.expectEqual(@as(u64, 16), pair.writer.current);
    try testing.expectEqual(@as(u32, @intCast(framed_len)), pair.writer.cursor);

    // The padding is zeros and the block's last four bytes are its CRC.
    for (before_pad) |byte| try testing.expectEqual(@as(u8, 0), byte);
    const stored = std.mem.readInt(u32, pair.writer.data[BLOCK - CRC_LEN ..][0..CRC_LEN], .little);
    const content = pair.writer.data[0 .. BLOCK - CRC_LEN];
    try testing.expectEqual(blog.crc32c.hardwareCrc32C(content), stored);

    // The block's last buffer commits the whole CRC; the next block's first
    // buffer starts its fold from zero.
    const closing = pair.writer.headers[bufferIdx(last_ordinal, 32)];
    try testing.expectEqual(@as(u64, last_ordinal), closing.buffer_seq);
    try testing.expectEqual(@as(u32, 65536), closing.data_len);
    try testing.expectEqual(stored, closing.crc_running);
    try testing.expectEqual(@as(u128, 0x200 + 17), closing.last_state);

    const opening = pair.writer.headers[bufferIdx(16, 32)];
    try testing.expectEqual(@as(u64, 16), opening.buffer_seq);
    try testing.expectEqual(@as(u32, @intCast(framed_len)), opening.data_len);
    try testing.expectEqual(@as(u32, 0), opening.flags);
    try testing.expectEqual(@as(u128, 0x200 + 18), opening.last_state);
    // The record's frame is the new block's first bytes.
    const frame = try encodeRecord(testing.allocator, state, data);
    defer testing.allocator.free(frame);
    try testing.expectEqualSlices(u8, frame, pair.writer.bufferData(16)[0..frame.len]);
}

test "a completed flush publishes the reclaiming terminator" {
    var pair = try Pair.acquire(4, 512, 0x20);
    defer pair.release();

    TestSink.reset(false);
    TestSink.install(&pair.writer);
    PublishLog.reset();
    PublishLog.install(&pair.writer);

    // 494 op bytes frame to exactly one buffer.
    const data = try payload(testing.allocator, 494, 7);
    defer testing.allocator.free(data);
    try testing.expectEqual(@as(usize, 512), framedLen(data.len));

    try pair.writer.write(0x21, 0x20, data);
    try testing.expectEqual(@as(usize, 1), TestSink.submits);
    try testing.expectEqual(@as(u64, 0), TestSink.last_ordinal);
    try testing.expectEqual(@as(u64, 1), pair.writer.flushed_upto);
    try testing.expect(!pair.writer.flush_in_flight);
    try testing.expect(!pair.writer.flush_pending);

    // The flushed slot is a zero-terminator for its own ordinal again, carrying
    // the pair a resume from it continues from: the tag and the CRC of nothing.
    const header = pair.writer.headers[0];
    try testing.expectEqual(@as(u64, 0), header.buffer_seq);
    try testing.expectEqual(@as(u32, 0), header.data_len);
    try testing.expectEqual(@as(u32, 0), header.flags);
    try testing.expectEqual(@as(u32, 0), header.crc_running);
    try testing.expectEqual(@as(u128, 0x20), header.last_state);

    // Fill the ring until the writer laps back onto the reclaimed slot.
    var state: u128 = 0x21;
    while (pair.writer.current < 4) : (state += 1) {
        try pair.writer.write(state + 1, state, data);
    }
    // The next write lands on the ring's first slot again, at ordinal 4.
    try pair.writer.write(state + 1, state, data);
    const frame = try encodeRecord(testing.allocator, state + 1, data);
    defer testing.allocator.free(frame);
    try testing.expectEqual(@as(u64, 5), pair.writer.current);
    try testing.expectEqual(@as(u64, 4), pair.writer.headers[0].buffer_seq);
    try testing.expectEqualSlices(u8, frame, pair.writer.bufferData(4)[0..frame.len]);
}

test "a submission the sink cannot take yet is parked and retried" {
    var pair = try Pair.acquire(4, 512, 0x60);
    defer pair.release();

    TestSink.reset(true);
    TestSink.install(&pair.writer);

    const data = try payload(testing.allocator, 1100, 6);
    defer testing.allocator.free(data);

    // The write fills the first buffer, submits it and leaves it in flight.
    try pair.writer.write(0x61, 0x60, data);
    try testing.expectEqual(@as(usize, 1), TestSink.submits);
    try testing.expect(pair.writer.flush_in_flight);
    try testing.expect(!pair.writer.flush_pending);

    // Its completion would submit the next filled buffer, and the sink has no
    // room for it: backpressure, not an error, so the submission parks.
    TestSink.refusal = error.NoFreeSlots;
    pair.writer.flushComplete(0);
    try testing.expectEqual(@as(u64, 1), pair.writer.flushed_upto);
    try testing.expect(!pair.writer.flush_in_flight);
    try testing.expect(pair.writer.flush_pending);

    // Room again: the next write's drain retries the parked submission.
    TestSink.refusal = null;
    const small = try payload(testing.allocator, 10, 2);
    defer testing.allocator.free(small);
    try pair.writer.write(0x62, 0x61, small);
    try testing.expectEqual(@as(usize, 2), TestSink.submits);
    try testing.expectEqual(@as(u64, 1), TestSink.last_ordinal);
    try testing.expect(!pair.writer.flush_pending);
    try testing.expect(pair.writer.flush_in_flight);
}

test "a refused flush pre-check leaves the writer untouched" {
    var pair = try Pair.acquire(4, 512, 0x30);
    defer pair.release();

    TestSink.reset(true);
    TestSink.install(&pair.writer);

    // 494 op bytes frame to exactly one buffer, so this write will submit.
    const data = try payload(testing.allocator, 494, 1);
    defer testing.allocator.free(data);

    var snapshot = try Snapshot.take(&pair.writer);
    defer snapshot.deinit();

    TestSink.refusal = error.NoFreeSlots;
    try testing.expectError(error.NoFreeSlots, pair.writer.write(0x31, 0x30, data));
    try snapshot.expectUnchanged(&pair.writer);

    TestSink.refusal = error.RingFull;
    try testing.expectError(error.RingFull, pair.writer.write(0x31, 0x30, data));
    try snapshot.expectUnchanged(&pair.writer);

    TestSink.refusal = null;
    try pair.writer.write(0x31, 0x30, data);
    try testing.expectEqual(@as(u128, 0x31), pair.writer.head);
}

test "the cost and capacity refusals change nothing" {
    // Two buffers: the fundamental rule bites on the second write.
    var pair = try Pair.acquire(2, 512, 0x40);
    defer pair.release();

    TestSink.reset(true);
    TestSink.install(&pair.writer);

    const filler = try payload(testing.allocator, 494, 2);
    defer testing.allocator.free(filler);
    try pair.writer.write(0x41, 0x40, filler);

    var snapshot = try Snapshot.take(&pair.writer);
    defer snapshot.deinit();

    // The next record would take the last free buffer.
    const more = try payload(testing.allocator, 100, 3);
    defer testing.allocator.free(more);
    try testing.expectError(error.WalFull, pair.writer.write(0x42, 0x41, more));
    try snapshot.expectUnchanged(&pair.writer);

    // A record that cannot fill a fresh block.
    const huge = try payload(testing.allocator, BLOCK_CONTENT, 4);
    defer testing.allocator.free(huge);
    try testing.expectError(error.RecordTooLarge, pair.writer.write(0x42, 0x41, huge));
    try snapshot.expectUnchanged(&pair.writer);

    // The chain guards.
    try testing.expectError(error.WalGap, pair.writer.write(0x42, 0x40, more));
    try snapshot.expectUnchanged(&pair.writer);
    try testing.expectError(error.InvalidStateIdx, pair.writer.write(0, 0x41, more));
    try snapshot.expectUnchanged(&pair.writer);
    try testing.expectEqual(@as(u64, 0), pair.writer.flushed_upto);
}

test "writes keep the chain and the terminator invariant" {
    var pair = try Pair.acquire(8, 512, 0x1000);
    defer pair.release();

    TestSink.reset(false);
    TestSink.install(&pair.writer);
    PublishLog.reset();
    PublishLog.install(&pair.writer);

    var prng = std.Random.DefaultPrng.init(0x5EED_1234);
    const random = prng.random();
    const data = try testing.allocator.alloc(u8, 1500);
    defer testing.allocator.free(data);

    var state: u128 = 0x1000;
    for (0..200) |_| {
        const len = random.intRangeAtMost(usize, 0, data.len);
        for (data[0..len], 0..) |*byte, i| byte.* = @truncate(i *% 13 +% @as(usize, @intCast(state & 0xff)));

        const start_ordinal = pair.writer.current;
        const published = PublishLog.len;
        const submitted = TestSink.submits;

        try pair.writer.write(state + 1, state, data[0..len]);
        state += 1;

        // The record was accepted and its chain closed.
        try testing.expectEqual(state, pair.writer.head);
        try testing.expect(pair.writer.freeBuffers() >= 1);

        // The current buffer's line agrees with the writer's own cursor, and a
        // full line is always a whole buffer.
        const header = pair.writer.headers[bufferIdx(pair.writer.current, 8)];
        try testing.expectEqual(pair.writer.current, header.buffer_seq);
        try testing.expectEqual(pair.writer.cursor, header.data_len);
        try testing.expect(header.flags & FLAG_FILLED == 0);
        try testing.expectEqual(state, header.last_state);
        for (pair.writer.headers) |line| {
            if (line.flags & FLAG_FILLED != 0) try testing.expectEqual(@as(u32, 512), line.data_len);
        }

        // Commit-last: the write's own publishes end with the commit of the
        // buffer that was current at its start — the reclamation publishes that
        // follow every completed flush excluded.
        const reclaimed = TestSink.submits - submitted;
        try testing.expect(PublishLog.len - reclaimed > published);
        try testing.expectEqual(start_ordinal, PublishLog.entries[PublishLog.len - 1 - reclaimed].seq);
    }

    // The first publish of an ordinal is its zero-terminator: a data area only
    // receives bytes after its control line says so (§2's uniform publish
    // rule). Ordinal 0's terminator was published by the fixture, before this
    // log began.
    var checked: usize = 0;
    for (PublishLog.entries[0..PublishLog.len], 0..) |entry, i| {
        var j = i;
        var seen = false;
        while (j > 0) {
            j -= 1;
            if (PublishLog.entries[j].seq == entry.seq) {
                seen = true;
                break;
            }
        }
        if (seen) continue;
        try testing.expect(entry.data_len == 0 or entry.seq == 0);
        checked += 1;
    }
    try testing.expect(checked > 0);
}

test "a record ending at a block's content end closes it next" {
    var pair = try Pair.acquire(32, 65536, 0x300);
    defer pair.release();

    TestSink.reset(true);
    TestSink.install(&pair.writer);

    // The largest record a block holds frames to exactly `1 MiB - 4`, leaving
    // the block's last four bytes for its CRC.
    const data = try payload(testing.allocator, BLOCK_CONTENT - 16 - 3, 11);
    defer testing.allocator.free(data);
    try testing.expectEqual(BLOCK_CONTENT, framedLen(data.len));
    try pair.writer.write(0x301, 0x300, data);

    try testing.expectEqual(@as(u64, 15), pair.writer.current);
    try testing.expectEqual(@as(u32, 65532), pair.writer.cursor);
    try testing.expectEqual(@as(usize, 0), blockRemain(15 * 65536 + pair.writer.cursor));

    // The next write pads nothing: the block's content is full, so only its CRC
    // is left to write, in the block's last buffer.
    const small = try payload(testing.allocator, 8, 12);
    defer testing.allocator.free(small);
    try pair.writer.write(0x302, 0x301, small);

    const stored = std.mem.readInt(u32, pair.writer.data[BLOCK - CRC_LEN ..][0..CRC_LEN], .little);
    const content = pair.writer.data[0 .. BLOCK - CRC_LEN];
    try testing.expectEqual(blog.crc32c.hardwareCrc32C(content), stored);

    const closing = pair.writer.headers[bufferIdx(15, 32)];
    try testing.expectEqual(@as(u64, 15), closing.buffer_seq);
    try testing.expectEqual(@as(u32, 65536), closing.data_len);
    try testing.expectEqual(stored, closing.crc_running);
    try testing.expectEqual(@as(u128, 0x301), closing.last_state);

    // The record after it starts the next block's first buffer.
    try testing.expectEqual(@as(u64, 16), pair.writer.current);
    try testing.expectEqual(@as(u32, @intCast(framedLen(small.len))), pair.writer.cursor);
}

// ============================================================================
// The flush over the ring (stage D)
// ============================================================================

test "never two flushes in flight" {
    var pair = try Pair.acquire(4, 512, 0x70);
    defer pair.release();

    TestSink.reset(true);
    TestSink.install(&pair.writer);

    // 494 op bytes frame to exactly one buffer, so every write fills one.
    const data = try payload(testing.allocator, 494, 3);
    defer testing.allocator.free(data);

    var state: u128 = 0x70;
    for (0..3) |_| {
        try pair.writer.write(state + 1, state, data);
        state += 1;
        // The completion is held, so the first flush stays the only one
        // submitted: the queue waits for it instead of overtaking it.
        try testing.expect(pair.writer.flush_in_flight);
        try testing.expect(!pair.writer.flush_pending);
    }
    try testing.expectEqual(@as(usize, 1), TestSink.submits);
    try testing.expectEqual(@as(u64, 0), pair.writer.flushed_upto);

    // Every completion submits exactly the next buffer, and the queue ends
    // empty rather than submitting a buffer that holds no flush.
    pair.writer.flushComplete(0);
    try testing.expectEqual(@as(usize, 2), TestSink.submits);
    try testing.expectEqual(@as(u64, 1), TestSink.last_ordinal);
    try testing.expect(pair.writer.flush_in_flight);

    pair.writer.flushComplete(1);
    try testing.expectEqual(@as(usize, 3), TestSink.submits);
    try testing.expectEqual(@as(u64, 2), TestSink.last_ordinal);
    try testing.expect(pair.writer.flush_in_flight);

    pair.writer.flushComplete(2);
    try testing.expectEqual(@as(usize, 3), TestSink.submits);
    try testing.expect(!pair.writer.flush_in_flight);
    try testing.expectEqual(@as(u64, 3), pair.writer.flushed_upto);
}

test "the floor chains from the tag base and from the empty state" {
    const data = try payload(testing.allocator, 8, 5);
    defer testing.allocator.free(data);

    // A rotated file: its base is the tag, so its first record chains from the
    // tag and from nothing else.
    var rotated = try Pair.acquire(4, 512, 0x80);
    defer rotated.release();
    TestSink.reset(false);
    TestSink.install(&rotated.writer);

    try testing.expectError(error.WalGap, rotated.writer.write(0x81, 0, data));
    try rotated.writer.write(0x81, 0x80, data);
    try testing.expectEqual(@as(u128, 0x81), rotated.writer.head);
    try testing.expectError(error.WalGap, rotated.writer.write(0x82, 0x80, data));

    // A brand-new data set: the tag is the empty state, so the first record
    // ever chains from 0 and only from 0.
    var fresh = try Pair.acquire(4, 512, 0);
    defer fresh.release();
    TestSink.reset(false);
    TestSink.install(&fresh.writer);

    try testing.expectError(error.WalGap, fresh.writer.write(0x11, 0x10, data));
    try fresh.writer.write(0x11, 0, data);
    try testing.expectEqual(@as(u128, 0x11), fresh.writer.head);
    try testing.expectError(error.WalGap, fresh.writer.write(0x12, 0, data));
}

test "the ring sink takes one slot per admitted flush" {
    var pair = try Pair.acquire(4, 512, 0xC0);
    defer pair.release();

    // A stream over a ring that never saw the kernel: `hasRoom` reads the
    // window alone, and a full window refuses before any SQE storage is
    // touched.
    var ring: zigring.Ring = undefined;
    ring.sq_mask = 3;
    var stream: zigring.StreamSQ = .{ .ring = &ring, .head = 0, .tail = 4 };

    var ring_slots: slots.RingSlots = undefined;
    try ring_slots.init(testing.allocator, 4096);
    defer ring_slots.deinit();

    pair.writer.attachStream(&stream, &ring_slots);
    try testing.expect(pair.writer.sink.ctx == @as(?*anyopaque, &pair.writer.ring_sink));

    // A full window refuses the pre-check and hands its slot back: the free
    // list offers the same index again, so nothing leaked.
    try testing.expectError(error.RingFull, pair.writer.flushRoom());
    try testing.expect(pair.writer.ring_sink.reserved == null);
    try testing.expectEqual(@as(u64, 0), try ring_slots.add(.idle));

    // An empty window admits it, and a second pre-check in the same call keeps
    // the slot it already holds instead of taking another.
    stream.head = 4;
    stream.tail = 4;
    try pair.writer.flushRoom();
    const reserved = pair.writer.ring_sink.reserved.?;
    try pair.writer.flushRoom();
    try testing.expectEqual(reserved, pair.writer.ring_sink.reserved.?);

    // `drain` hands an unused reservation back, so a writer retired before
    // its submission leaks no slot.
    pair.writer.drain();
    try testing.expect(pair.writer.ring_sink.reserved == null);
}

test "a flush's OS error stops the writer" {
    var pair = try Pair.acquire(4, 512, 0x90);
    defer pair.release();

    TestSink.reset(true);
    TestSink.install(&pair.writer);

    // 494 op bytes frame to exactly one buffer.
    const data = try payload(testing.allocator, 494, 4);
    defer testing.allocator.free(data);

    try pair.writer.write(0x91, 0x90, data);
    try testing.expect(pair.writer.flush_in_flight);

    // The completion carries the kernel's errno: a real OS error, so the flush
    // is not retried and the writer stops.
    pair.writer.flushResult(.{
        .user_data = 0,
        .res = -@as(i32, @backingInt(std.os.linux.E.IO)),
        .flags = 0,
    });
    try testing.expect(pair.writer.faulted);
    try testing.expect(!pair.writer.flush_in_flight);
    try testing.expect(!pair.writer.flush_pending);
    try testing.expectEqual(@as(usize, 1), TestSink.submits);

    // From here everything is refused and nothing moved.
    try testing.expectError(error.WalFaulted, pair.writer.write(0x92, 0x91, data));
    try testing.expectEqual(@as(u128, 0x91), pair.writer.head);

    // Best effort: a stopped writer has no completion to await, so draining
    // it returns instead of waiting for one.
    pair.writer.drain();
    try testing.expect(pair.writer.closed);
}

test "drain retries a parked submission and does not wait without a ring" {
    var pair = try Pair.acquire(4, 512, 0xB0);
    defer pair.release();

    TestSink.reset(true);
    TestSink.install(&pair.writer);

    // A record spanning three buffers: the first fills and submits, the flush
    // that follows has nowhere to go while the window refuses it.
    const data = try payload(testing.allocator, 1100, 6);
    defer testing.allocator.free(data);
    try pair.writer.write(0xB1, 0xB0, data);
    try testing.expect(pair.writer.flush_in_flight);

    TestSink.refusal = error.RingFull;
    pair.writer.flushComplete(0);
    try testing.expect(pair.writer.flush_pending);
    try testing.expectEqual(@as(usize, 1), TestSink.submits);

    // `drain` gives the parked submission its retry; with no ring behind the
    // sink there is no completion to await, so it must not wait for one.
    TestSink.refusal = null;
    pair.writer.drain();
    try testing.expectEqual(@as(usize, 2), TestSink.submits);
    try testing.expectEqual(@as(u64, 1), TestSink.last_ordinal);
    try testing.expect(!pair.writer.flush_pending);
    try testing.expect(pair.writer.closed);
}
// ============================================================================
// PMEM mode (stage E)
// ============================================================================

test "the write path runs on a PMEM-shaped battery" {
    // The pair's mode is PMEM — publishes go through the barrier module and the
    // flushes would carry `RWF.DSYNC` — while its bytes are ordinary memory,
    // which is exactly the shape the barrier's no-op seam admits.
    var pair = try Pair.acquirePmem(4, 512, 0x200);
    defer pair.release();

    try testing.expect(pair.writer.pmem);

    TestSink.reset(false);
    TestSink.install(&pair.writer);
    PublishLog.reset();
    PublishLog.install(&pair.writer);

    const data = try payload(testing.allocator, 700, 1);
    defer testing.allocator.free(data);
    const framed = try encodeRecord(testing.allocator, 0x201, data);
    defer testing.allocator.free(framed);

    try pair.writer.write(0x201, 0x200, data);
    try pair.writer.write(0x202, 0x201, data);

    // 718 bytes of frame per record: the first fills buffer 0 and leaves 206
    // bytes in buffer 1, the second takes the rest of buffer 1 and leaves 412 in
    // buffer 2. Both filled buffers flushed and reclaimed, so their lines are
    // zero-terminators again and only the tail holds bytes.
    try testing.expectEqual(@as(u64, 2), pair.writer.flushed_upto);
    try testing.expectEqual(@as(usize, 2), TestSink.submits);

    const first = pair.writer.headers[0];
    try testing.expectEqual(@as(u64, 0), first.buffer_seq);
    try testing.expectEqual(@as(u32, 0), first.data_len);
    try testing.expectEqual(@as(u32, 0), first.flags);

    const second = pair.writer.headers[1];
    try testing.expectEqual(@as(u64, 1), second.buffer_seq);
    try testing.expectEqual(@as(u32, 0), second.data_len);
    try testing.expectEqual(@as(u32, 0), second.flags);

    const tail = pair.writer.headers[2];
    try testing.expectEqual(@as(u64, 2), tail.buffer_seq);
    try testing.expectEqual(@as(u32, 412), tail.data_len);
    try testing.expectEqual(@as(u32, 0), tail.flags);
    try testing.expectEqual(@as(u128, 0x202), tail.last_state);
    try testing.expectEqualSlices(
        u8,
        framed[306..],
        pair.writer.data[2 * 512 ..][0..412],
    );

    // The barrier seam does not hide the publishes: the hook still sees every
    // control line, and the last of them is the reclamation the final flush
    // published.
    try testing.expect(PublishLog.len > 0);
    try testing.expectEqual(@as(u32, 0), PublishLog.entries[PublishLog.len - 1].data_len);

    // Draining a PMEM-shaped writer empties the queue, like a live one.
    pair.writer.drain();
    try testing.expect(pair.writer.closed);
}

test "a PMEM-shaped battery pads and closes a block" {
    // Sixteen 64 KiB buffers hold one block, so the tail padding and the
    // block's CRC land in the battery where the check can read them — the one
    // data publish the mode changes.
    var pair = try Pair.acquirePmem(32, 65536, 0xA00);
    defer pair.release();

    TestSink.reset(true);
    TestSink.install(&pair.writer);

    const data = try payload(testing.allocator, 60000, 9);
    defer testing.allocator.free(data);

    var state: u128 = 0xA00;
    while (blockRemain(pair.writer.current * 65536 + pair.writer.cursor) >= framedLen(data.len)) {
        try pair.writer.write(state + 1, state, data);
        state += 1;
    }
    // The record that does not fit pads the block's tail, writes its CRC and
    // opens the next block at its first buffer.
    try pair.writer.write(state + 1, state, data);
    state += 1;
    try testing.expectEqual(@as(u64, 16), pair.writer.current);

    // The block's stored CRC still matches its content, and the closing buffer
    // carries it as its fold — the writeback of the padded zeros did not disturb
    // either.
    const stored = std.mem.readInt(u32, pair.writer.data[BLOCK - CRC_LEN ..][0..CRC_LEN], .little);
    try testing.expectEqual(
        blog.crc32c.hardwareCrc32C(pair.writer.data[0 .. BLOCK - CRC_LEN]),
        stored,
    );
    const closing = pair.writer.headers[bufferIdx(15, 32)];
    try testing.expectEqual(@as(u64, 15), closing.buffer_seq);
    try testing.expectEqual(@as(u32, 65536), closing.data_len);
    try testing.expectEqual(stored, closing.crc_running);

    // The next block's first buffer folds from the CRC of nothing.
    const opening = pair.writer.headers[bufferIdx(16, 32)];
    try testing.expectEqual(@as(u64, 16), opening.buffer_seq);
    try testing.expectEqual(@as(u32, 0), opening.flags);
    try testing.expectEqual(@as(u128, state), opening.last_state);
}

test "the walk resumes where the battery's chain stopped" {
    var pair = try Pair.acquirePmem(8, 512, 0x300);
    defer pair.release();

    // Held completions: nothing is flushed, so the battery holds the whole
    // chain and the walk reads it from the ordinal the empty file ends at.
    TestSink.reset(true);
    TestSink.install(&pair.writer);

    const data = try payload(testing.allocator, 700, 3);
    defer testing.allocator.free(data);
    try pair.writer.write(0x301, 0x300, data);
    try pair.writer.write(0x302, 0x301, data);

    var reopened = WalWriteFile.init(.{}, Area.init(pair.bytes, 8, 512), pair.wal_cfg, 0, 0, 0x300);
    try reopened.walk(0);

    // The live writer is mid-tail in buffer 2; the reopened one must land on the
    // same ordinal, byte and chain head, with the same fold to continue from.
    try testing.expectEqual(pair.writer.current, reopened.current);
    try testing.expectEqual(pair.writer.cursor, reopened.cursor);
    try testing.expectEqual(pair.writer.head, reopened.head);
    try testing.expectEqual(@as(u64, 2), reopened.current);
    try testing.expectEqual(@as(u32, 412), reopened.cursor);
    try testing.expectEqual(@as(u128, 0x302), reopened.head);
    try testing.expectEqual(@as(u64, 0), reopened.flushed_upto);

    // The recovered fold is the one the tail's line carries, so the next record
    // continues the block instead of restarting it.
    const fold = reopened.headers[2].crc_running;
    const next = try payload(testing.allocator, 40, 4);
    defer testing.allocator.free(next);
    const framed = try encodeRecord(testing.allocator, 0x303, next);
    defer testing.allocator.free(framed);

    try reopened.write(0x303, 0x302, next);
    try testing.expectEqual(@as(u128, 0x303), reopened.head);
    try testing.expectEqual(
        blog.crc32c.composedCrc32C(fold, framed),
        reopened.headers[2].crc_running,
    );
}

test "a stale lap stops the walk and republishes the line it stopped on" {
    var pair = try Pair.acquirePmem(4, 512, 0x400);
    defer pair.release();

    // Completed flushes, so every filled buffer is reclaimed: the ring laps
    // after four of them and slot 0 comes to hold ordinal 4's line.
    TestSink.reset(false);
    TestSink.install(&pair.writer);

    // 494 op bytes frame to exactly one buffer.
    const data = try payload(testing.allocator, 494, 5);
    defer testing.allocator.free(data);

    var state: u128 = 0x400;
    for (0..5) |_| {
        try pair.writer.write(state + 1, state, data);
        state += 1;
    }
    try testing.expectEqual(@as(u64, 4), pair.writer.headers[0].buffer_seq);

    // A file that flushed nothing: the walk starts at ordinal 0 and finds the
    // line of a previous lap there, so it stops and delivers nothing.
    var reopened = WalWriteFile.init(.{}, Area.init(pair.bytes, 4, 512), pair.wal_cfg, 0, 0, 0x400);
    try reopened.walk(0);

    try testing.expectEqual(@as(u64, 0), reopened.current);
    try testing.expectEqual(@as(u32, 0), reopened.cursor);
    try testing.expectEqual(@as(u128, 0x400), reopened.head);

    // The stale line was republished as ordinal 0's zero-terminator before the
    // writer could put a byte behind it.
    const header = reopened.headers[0];
    try testing.expectEqual(@as(u64, 0), header.buffer_seq);
    try testing.expectEqual(@as(u32, 0), header.data_len);
    try testing.expectEqual(@as(u32, 0), header.flags);
    try testing.expectEqual(@as(u128, 0x400), header.last_state);
    try testing.expectEqual(@as(u32, 0), header.crc_running);
}

test "a torn commit stops the walk before its successor" {
    var pair = try Pair.acquirePmem(4, 512, 0x500);
    defer pair.release();

    TestSink.reset(true);
    TestSink.install(&pair.writer);

    // The ordinal-0 terminator adoption published, before any record.
    const adopted = pair.writer.headers[0];
    try testing.expectEqual(@as(u128, 0x500), adopted.last_state);

    // 700 op bytes frame to 718: buffer 0 fills, buffer 1 holds the tail. The
    // successors publish first and the op-start buffer's commit comes last, so
    // dropping that last publish is exactly a torn crash.
    const data = try payload(testing.allocator, 700, 6);
    defer testing.allocator.free(data);
    try pair.writer.write(0x501, 0x500, data);
    try testing.expectEqual(@as(u32, 206), pair.writer.headers[1].data_len);

    pair.writer.headers[0] = adopted;

    var reopened = WalWriteFile.init(.{}, Area.init(pair.bytes, 4, 512), pair.wal_cfg, 0, 0, 0x500);
    try reopened.walk(0);

    // The walk stops on the terminator the commit never replaced: the
    // successor's bytes are never delivered, and the writer resumes at the
    // buffer the crash left current.
    try testing.expectEqual(@as(u64, 0), reopened.current);
    try testing.expectEqual(@as(u32, 0), reopened.cursor);
    try testing.expectEqual(@as(u128, 0x500), reopened.head);
    try testing.expectEqual(@as(u32, 206), pair.writer.headers[1].data_len);
}

test "a second generation's terminator reclaims the pair's ring" {
    var pair = try Pair.acquirePmem(4, 512, 0x600);
    defer pair.release();

    TestSink.reset(true);
    TestSink.install(&pair.writer);

    const data = try payload(testing.allocator, 700, 7);
    defer testing.allocator.free(data);
    try pair.writer.write(0x601, 0x600, data);
    try testing.expectEqual(@as(u32, 206), pair.writer.headers[1].data_len);

    // The swap's publish: the new file's ordinal-0 terminator goes over the old
    // file's ring, before the registry append that makes the new file visible.
    pair.writer.publishTerminator(0, 0x700, 0);

    var reopened = WalWriteFile.init(.{}, Area.init(pair.bytes, 4, 512), pair.wal_cfg, 0, 0, 0x700);
    try reopened.walk(0);

    // The new generation starts at its own tag: the previous file's committed
    // tail is still in the battery behind it and the walk never takes it.
    try testing.expectEqual(@as(u64, 0), reopened.current);
    try testing.expectEqual(@as(u32, 0), reopened.cursor);
    try testing.expectEqual(@as(u128, 0x700), reopened.head);
    try testing.expectEqual(@as(u32, 206), pair.writer.headers[1].data_len);

    // Its first record chains from the new tag, not from the old file's head.
    try testing.expectError(error.WalGap, reopened.write(0x702, 0x601, data));
    try reopened.write(0x702, 0x700, data);
    try testing.expectEqual(@as(u128, 0x702), reopened.head);

    // The successor's terminator carries the new generation's base, and the
    // record's end lands in the tail behind it.
    try testing.expectEqual(@as(u128, 0x700), reopened.headers[0].last_state);
    try testing.expectEqual(@as(u32, 206), reopened.headers[1].data_len);
    try testing.expectEqual(@as(u128, 0x702), reopened.headers[1].last_state);
}

test "a committed buffer past the file's flush frontier keeps the frontier pair" {
    var pair = try Pair.acquirePmem(8, 512, 0x800);
    defer pair.release();

    TestSink.reset(true);
    TestSink.install(&pair.writer);

    // Two records of 718 bytes commit buffers 0 and 1 and leave the tail in
    // buffer 2, none of them flushed: the file is empty, so the frontier is
    // ordinal 0.
    const data = try payload(testing.allocator, 700, 8);
    defer testing.allocator.free(data);
    try pair.writer.write(0x801, 0x800, data);
    try pair.writer.write(0x802, 0x801, data);

    // Reconciled against the live writer's own queue: with the frontier at
    // ordinal 0 the pair is the file's base, and the walk still lands on the
    // tail.
    var reopened = WalWriteFile.init(.{}, Area.init(pair.bytes, 8, 512), pair.wal_cfg, 0, 0, 0x800);
    try reopened.walk(0);
    try testing.expectEqual(pair.writer.flushed_state, reopened.flushed_state);
    try testing.expectEqual(pair.writer.flushed_crc, reopened.flushed_crc);
    try testing.expectEqual(@as(u128, 0x800), reopened.flushed_state);

    // Now let the first flush through: the live writer's first reclamation
    // publishes the frontier pair, which is what the reopened writer would
    // publish too.
    pair.writer.flushComplete(0);
    try testing.expectEqual(@as(u128, 0x800), pair.writer.headers[0].last_state);
    try testing.expectEqual(@as(u32, 0), pair.writer.headers[0].crc_running);
}

// ============================================================================
// The read path (stage F)
// ============================================================================

/// One record exactly fills one 64 KiB buffer of the geometry these tests use:
/// the state's 16 bytes and the three-byte length field are the rest.
const fill_op: usize = 65536 - 16 - 3;

/// The op one record carries, seeded by its own state, so a readout is checked
/// without keeping every byte that went in.
fn recordOp(buf: []u8, state: u128, salt: u8) void {
    const seed: u8 = @as(u8, @truncate(state)) +% salt;
    for (buf, 0..) |*byte, i| byte.* = @truncate(i *% 37 +% @as(usize, seed));
}

/// The file offset of record `index` in the fixture's layout: whole buffers per
/// record, one padding buffer closing each block.
fn syntheticOffset(index: usize, lba: u32) u64 {
    const per_block = BLOCK / lba - 1;
    return @as(u64, index / per_block) * BLOCK + @as(u64, index % per_block) * lba;
}

/// Creates (or empties) one file of the fixture.
fn createFile(path: [:0]const u8) !posix.fd_t {
    const fd_raw = std.os.linux.open(path, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, 0o644);
    const errno = std.os.linux.errno(fd_raw);
    if (errno != .SUCCESS) return std.posix.unexpectedErrno(errno);
    return @intCast(fd_raw);
}

/// A synthetic WAL file over a pair's battery.
///
/// Records go through a real writer, and every buffer its flush submits is
/// copied to the file at that buffer's own offset — exactly where a live ring
/// would put it — so the file holds what a running system leaves behind. A
/// flush held back leaves its buffer in the battery, which is the chain a PMEM
/// read appends to the file's bytes.
const Synth = struct {
    pair: Pair,
    tmp: std.testing.TmpDir,
    root: []u8,
    path: [:0]u8,
    fd: posix.fd_t,
    /// The first ordinal whose flush is held back instead of written and
    /// completed.
    hold_from: u64 = std.math.maxInt(u64),

    fn init(self: *Synth, buffers: u32, lba: u32, tag: u128, pmem: bool) !void {
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();

        self.root = try std.fmt.allocPrint(
            testing.allocator,
            ".zig-cache/tmp/{s}",
            .{self.tmp.sub_path[0..]},
        );
        errdefer testing.allocator.free(self.root);

        self.path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/wal", .{self.root}, 0);
        errdefer testing.allocator.free(self.path);

        self.fd = try createFile(self.path);
        errdefer _ = std.os.linux.close(self.fd);

        self.hold_from = std.math.maxInt(u64);
        self.pair = if (pmem)
            try Pair.acquirePmem(buffers, lba, tag)
        else
            try Pair.acquire(buffers, lba, tag);
        self.pair.writer.fd = res_handle.adopt(self.fd);
        self.pair.writer.sink = .{ .ctx = self, .room = room, .submit = submit };
    }

    fn deinit(self: *Synth) void {
        _ = std.os.linux.close(self.fd);
        self.pair.release();
        testing.allocator.free(self.path);
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    /// Another file beside the WAL one, for the inputs a test mutates.
    fn scratch(self: *Synth, name: []const u8) !posix.fd_t {
        const scratch_path = try std.fmt.allocPrintSentinel(
            testing.allocator,
            "{s}/{s}",
            .{ self.root, name },
            0,
        );
        defer testing.allocator.free(scratch_path);
        return createFile(scratch_path);
    }

    fn room(ctx: ?*anyopaque, writer: *WalWriteFile) WalError!void {
        _ = ctx;
        _ = writer;
    }

    /// Writes the completed buffer at its own offset and completes the flush,
    /// so the file sees exactly the bytes a live flush would have written.
    fn submit(ctx: ?*anyopaque, writer: *WalWriteFile, ordinal: u64) void {
        const self: *Synth = @ptrCast(@alignCast(ctx.?));
        if (ordinal >= self.hold_from) return;
        const data = writer.bufferData(ordinal);
        const at: posix.off_t = @intCast(ordinal * @as(u64, writer.lba));
        const res = std.os.linux.pwrite(self.fd, data.ptr, data.len, at);
        std.debug.assert(std.os.linux.errno(res) == .SUCCESS);
        writer.flushComplete(ordinal);
    }

    /// Appends one record, chaining from the writer's own head.
    fn write(self: *Synth, state: u128, op: []u8) !void {
        try self.pair.writer.write(state, self.pair.writer.head, op);
    }

    /// The read side over the file: `O_DIRECT` where the filesystem has it —
    /// a real device's shape — and buffered where it does not, which is every
    /// logic test on tmpfs. A non-null `area` appends the battery's chain.
    fn openRead(self: *Synth, area: ?Area) !WalReadFile {
        // The fsync makes the buffered writes visible to an `O_DIRECT` read:
        // that path does not consult the page cache.
        _ = std.os.linux.fsync(self.fd);

        var fd_raw = std.os.linux.open(self.path, .{ .ACCMODE = .RDONLY, .DIRECT = true }, 0);
        var errno = std.os.linux.errno(fd_raw);
        if (errno == .INVAL or errno == .OPNOTSUPP) {
            fd_raw = std.os.linux.open(self.path, .{ .ACCMODE = .RDONLY }, 0);
            errno = std.os.linux.errno(fd_raw);
        }
        if (errno != .SUCCESS) return std.posix.unexpectedErrno(errno);
        return WalReadFile.init(@intCast(fd_raw), self.pair.wal_cfg, area, 0, 0, self.pair.writer.tag);
    }
};

/// Collects what a walk delivers, so a readout can be compared with what went
/// in.
const Delivered = struct {
    states: [128]u128 = undefined,
    ops: [128][]u8 = undefined,
    len: usize = 0,

    fn sink(ctx: ?*anyopaque, state_idx: u128, op: []const u8) anyerror!void {
        const self: *Delivered = @ptrCast(@alignCast(ctx.?));
        if (self.len >= self.states.len) return error.DeliveredTooMany;
        self.states[self.len] = state_idx;
        self.ops[self.len] = try testing.allocator.dupe(u8, op);
        self.len += 1;
    }

    fn deinit(self: *Delivered) void {
        for (self.ops[0..self.len]) |op| testing.allocator.free(op);
        self.len = 0;
    }

    fn drain(self: *Delivered) ReadSink {
        return .{ .ctx = self, .apply = sink };
    }
};

/// Fills the fixture's file with buffer-sized records and answers the states it
/// wrote.
fn fillRecords(synth: *Synth, states: []u128, base: u128) !void {
    var op: [fill_op]u8 = undefined;
    for (states, 0..) |*state, i| {
        state.* = base + 1 + @as(u128, i);
        recordOp(&op, state.*, 0);
        try synth.write(state.*, &op);
    }
}

test "a synthetic file reads back every record it holds" {
    try testing.expectEqual(@as(usize, 65536), framedLen(fill_op));

    var synth: Synth = undefined;
    try synth.init(8, 65536, 0x1000, false);
    defer synth.deinit();

    var written: [64]u128 = undefined;
    try fillRecords(&synth, &written, 0x1000);

    var reader = try synth.openRead(null);
    defer _ = std.os.linux.close(reader.fd);

    var delivered: Delivered = .{};
    defer delivered.deinit();

    const process = try reader.beginRead(testing.allocator, .read_all, delivered.drain());
    defer reader.endRead(testing.allocator, process);
    try process.drive(null);

    try testing.expect(process.done);
    try testing.expectEqual(written.len, delivered.len);

    var op: [fill_op]u8 = undefined;
    for (written, 0..) |state, i| {
        try testing.expectEqual(state, delivered.states[i]);
        recordOp(&op, state, 0);
        try testing.expectEqualSlices(u8, &op, delivered.ops[i]);
    }
}

test "a read completion steps the process and retires its slot" {
    var synth: Synth = undefined;
    try synth.init(8, 65536, 0x9000, false);
    defer synth.deinit();

    // Fifteen buffer-sized records: the whole stream fits one block and ends
    // inside it, so the completion of that block ends the walk with nothing
    // left to arm.
    var written: [15]u128 = undefined;
    try fillRecords(&synth, &written, 0x9000);

    var reader = try synth.openRead(null);
    defer _ = std.os.linux.close(reader.fd);

    var delivered: Delivered = .{};
    defer delivered.deinit();

    const process = try reader.beginRead(testing.allocator, .read_all, delivered.drain());
    defer reader.endRead(testing.allocator, process);

    // The ring is never entered: the completion arrives by hand, which is what
    // the CQ drain does on a live thread.
    var ring: zigring.Ring = undefined;
    ring.sq_mask = 3;
    var stream: zigring.StreamSQ = .{ .ring = &ring, .head = 0, .tail = 0 };
    var ring_slots: slots.RingSlots = undefined;
    try ring_slots.init(testing.allocator, 4096);
    defer ring_slots.deinit();
    const io: FileReadProcess.Io = .{ .stream = &stream, .slots = &ring_slots };

    const request = (try process.advance()).?;
    try res_handle.readFully(reader.fd, request.dst, request.offset);

    const task_idx = try ring_slots.add(.{ .file_read = .{
        .file_process = process,
        .offset = request.offset,
        .buf = request.dst,
    } });
    try process.onCQE(io, .{ .user_data = task_idx, .res = @intCast(request.dst.len), .flags = 0 });

    try testing.expect(process.done);
    try testing.expect(ring_slots.get(task_idx) == null);
    try testing.expectEqual(written.len, delivered.len);
    try testing.expectEqualSlices(u128, &written, delivered.states[0..written.len]);
}

test "the seek converges on the block the target's record starts in" {
    var synth: Synth = undefined;
    try synth.init(8, 65536, 0x2000, false);
    defer synth.deinit();

    // A state jump inside the file: a state is not a position, and the search
    // is plain integer compare over record starts.
    var states: [64]u128 = undefined;
    var op: [fill_op]u8 = undefined;
    for (&states, 0..) |*state, i| {
        state.* = 0x2000 + 1 + @as(u128, i) + if (i >= 20) @as(u128, 0x1_0000) else 0;
        recordOp(&op, state.*, 0);
        try synth.write(state.*, &op);
    }

    var reader = try synth.openRead(null);
    defer _ = std.os.linux.close(reader.fd);

    const cases = [_]struct { target: u128, first: usize }{
        .{ .target = states[0], .first = 0 },
        .{ .target = states[19], .first = 19 },
        // A state that was never written: it falls in the jump's gap.
        .{ .target = states[19] + 1, .first = 20 },
        .{ .target = states[20], .first = 20 },
        .{ .target = states[31], .first = 31 },
        .{ .target = states[63], .first = 63 },
    };

    for (cases) |case| {
        var delivered: Delivered = .{};
        defer delivered.deinit();

        const process = try reader.beginRead(
            testing.allocator,
            .{ .seek_then_read = case.target },
            delivered.drain(),
        );
        defer reader.endRead(testing.allocator, process);
        try process.drive(null);

        try testing.expectEqual(states.len - case.first, delivered.len);
        for (states[case.first..], 0..) |state, i| {
            try testing.expectEqual(state, delivered.states[i]);
        }
    }
}

test "the seek stops at the file's own edges" {
    var synth: Synth = undefined;
    try synth.init(8, 65536, 0x3000, false);
    defer synth.deinit();

    var states: [20]u128 = undefined;
    try fillRecords(&synth, &states, 0x3000);

    var reader = try synth.openRead(null);
    defer _ = std.os.linux.close(reader.fd);

    // Below the first record: the readout is the whole file.
    {
        var delivered: Delivered = .{};
        defer delivered.deinit();

        const process = try reader.beginRead(
            testing.allocator,
            .{ .seek_then_read = states[0] - 1 },
            delivered.drain(),
        );
        defer reader.endRead(testing.allocator, process);
        try process.drive(null);

        try testing.expectEqual(states.len, delivered.len);
        try testing.expectEqual(states[0], delivered.states[0]);
    }

    // Past the last one: an empty delivery, the sink never called.
    {
        var delivered: Delivered = .{};
        defer delivered.deinit();

        const process = try reader.beginRead(
            testing.allocator,
            .{ .seek_then_read = states[states.len - 1] + 1 },
            delivered.drain(),
        );
        defer reader.endRead(testing.allocator, process);
        try process.drive(null);

        try testing.expect(process.done);
        try testing.expectEqual(@as(usize, 0), delivered.len);
    }
}

test "the merged stream continues into the battery's chain" {
    var synth: Synth = undefined;
    try synth.init(8, 65536, 0x4000, true);
    defer synth.deinit();

    var written: [6]u128 = undefined;
    var op: [fill_op]u8 = undefined;
    for (&written, 0..) |*state, i| {
        state.* = 0x4000 + 1 + @as(u128, i);
        recordOp(&op, state.*, 0);
        try synth.write(state.*, &op);
        // The first four buffers reach the file; the rest stay in the battery,
        // as a crash after their commits leaves them.
        if (i == 3) synth.hold_from = synth.pair.writer.current;
    }

    // The file alone holds the first four records: the tail was never flushed.
    {
        var reader = try synth.openRead(null);
        defer _ = std.os.linux.close(reader.fd);

        var delivered: Delivered = .{};
        defer delivered.deinit();

        const process = try reader.beginRead(testing.allocator, .read_all, delivered.drain());
        defer reader.endRead(testing.allocator, process);
        try process.drive(null);

        try testing.expectEqual(@as(usize, 4), delivered.len);
        try testing.expectEqualSlices(u128, written[0..4], delivered.states[0..4]);
    }

    // The merged stream adds the battery's chain: six records, in order.
    {
        var reader = try synth.openRead(Area.init(synth.pair.bytes, 8, 65536));
        defer _ = std.os.linux.close(reader.fd);

        var delivered: Delivered = .{};
        defer delivered.deinit();

        const process = try reader.beginRead(testing.allocator, .read_all, delivered.drain());
        defer reader.endRead(testing.allocator, process);
        try process.drive(null);

        try testing.expect(process.done);
        try testing.expectEqual(written.len, delivered.len);
        try testing.expectEqualSlices(u128, &written, delivered.states[0..written.len]);

        var expected: [fill_op]u8 = undefined;
        for (written, 0..) |state, i| {
            recordOp(&expected, state, 0);
            try testing.expectEqualSlices(u8, &expected, delivered.ops[i]);
        }
    }
}

test "a zero state ends the readout and is never delivered" {
    var synth: Synth = undefined;
    try synth.init(8, 65536, 0x5000, false);
    defer synth.deinit();

    var states: [46]u128 = undefined;
    try fillRecords(&synth, &states, 0x5000);

    // The twentieth record's state zeroed inside a closed block: its CRC no
    // longer matches, so the block is framed alone and the reserved empty
    // state stops the readout there.
    const blank: [16]u8 = @splat(0);
    try res_handle.pwriteAll(synth.fd, &blank, syntheticOffset(20, 65536));

    var reader = try synth.openRead(null);
    defer _ = std.os.linux.close(reader.fd);

    var delivered: Delivered = .{};
    defer delivered.deinit();

    const process = try reader.beginRead(testing.allocator, .read_all, delivered.drain());
    defer reader.endRead(testing.allocator, process);
    try process.drive(null);

    try testing.expect(process.done);
    try testing.expectEqual(@as(usize, 20), delivered.len);
    try testing.expectEqualSlices(u128, states[0..20], delivered.states[0..20]);
}

/// Rewrites the scratch file with the first `len` bytes of `content`, flipping
/// the byte at `flip` when there is one.
fn mutate(scratch: posix.fd_t, content: []const u8, len: usize, flip: ?usize) !void {
    const errno = std.os.linux.errno(std.os.linux.ftruncate(scratch, 0));
    if (errno != .SUCCESS) return std.posix.unexpectedErrno(errno);
    try res_handle.pwriteAll(scratch, content[0..len], 0);

    const at = flip orelse return;
    if (at >= len) return;
    const flipped = [_]u8{content[at] ^ 0xFF};
    try res_handle.pwriteAll(scratch, &flipped, at);
}

test "truncations and byte flips never panic, and stop" {
    var synth: Synth = undefined;
    try synth.init(8, 65536, 0x6000, false);
    defer synth.deinit();

    var states: [46]u128 = undefined;
    try fillRecords(&synth, &states, 0x6000);

    const size: usize = @intCast(try res_handle.fileSize(synth.fd));
    const content = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(content);
    try res_handle.readFully(synth.fd, content, 0);

    const scratch = try synth.scratch("mutated");
    defer _ = std.os.linux.close(scratch);

    var reader = WalReadFile.init(scratch, synth.pair.wal_cfg, null, 0, 0, 0x6000);
    var delivered: Delivered = .{};
    defer delivered.deinit();

    // Truncations at the offsets framing and block boundaries straddle.
    const cuts = [_]usize{
        0,    1,     15,    16,    17,      512,
        4096, 65535, 65536, 65537, 1048575, 1048576,
    };
    for (cuts) |cut| {
        if (cut >= size) continue;
        try mutate(scratch, content, cut, null);

        const process = try reader.beginRead(testing.allocator, .read_all, delivered.drain());
        defer reader.endRead(testing.allocator, process);
        try process.drive(null);

        try testing.expect(process.done);
        for (delivered.states[0..delivered.len]) |state| try testing.expect(state != 0);
        delivered.deinit();
    }

    // Single byte flips: a record's state, its length field, the middle of an
    // op, a block's CRC, and the open tail block.
    const flips = [_]usize{
        0,       8,       16,       17, 65536 + 16, 65536 + 1000,
        1048575, 1048576, size - 1,
    };
    for (flips) |at| {
        if (at >= size) continue;
        try mutate(scratch, content, size, at);

        const process = try reader.beginRead(testing.allocator, .read_all, delivered.drain());
        defer reader.endRead(testing.allocator, process);
        try process.drive(null);

        try testing.expect(process.done);
        for (delivered.states[0..delivered.len]) |state| try testing.expect(state != 0);
        delivered.deinit();
    }
}

test "a plain reopen recovers its head from the file itself" {
    var synth: Synth = undefined;
    try synth.init(8, 65536, 0x7000, false);
    defer synth.deinit();

    // A plain configuration even where the barrier module is live: that
    // battery is DRAM and gone, so the file is the only source.
    const plain_cfg: config.Wal = .{ .plain = .{ .dir = "wal", .buffers = 8, .lba = config.kib(64) } };

    var states: [46]u128 = undefined;
    try fillRecords(&synth, &states, 0x7000);
    const size = try res_handle.fileSize(synth.fd);

    var reopened = WalWriteFile.init(
        res_handle.adopt(synth.fd),
        Area.init(synth.pair.bytes, 8, 65536),
        plain_cfg,
        0,
        0,
        0x7000,
    );
    try reopened.walk(size);

    // The file ends on a buffer boundary inside block 3, so the resume is the
    // empty buffer after the last record.
    try testing.expectEqual(states[states.len - 1], reopened.head);
    try testing.expectEqual(@as(u64, 49), reopened.current);
    try testing.expectEqual(@as(u32, 0), reopened.cursor);
    try testing.expectEqual(@as(u64, 49), reopened.flushed_upto);
    try testing.expectEqual(states[states.len - 1], reopened.flushed_state);

    // The fold of the open block's flushed bytes: block 3's first record.
    const block_start: usize = @intCast((size - 1) / BLOCK * BLOCK);
    const region = try testing.allocator.alloc(u8, @intCast(size - block_start));
    defer testing.allocator.free(region);
    try res_handle.readFully(synth.fd, region, block_start);
    try testing.expectEqual(blog.crc32c.hardwareCrc32C(region), reopened.flushed_crc);

    // The line the next record continues from carries the same fold.
    const line = reopened.headers[bufferIdx(49, 8)];
    try testing.expectEqual(@as(u64, 49), line.buffer_seq);
    try testing.expectEqual(@as(u32, 0), line.data_len);
    try testing.expectEqual(@as(u32, 0), line.flags);
    try testing.expectEqual(reopened.flushed_crc, line.crc_running);
    try testing.expectEqual(states[states.len - 1], line.last_state);
}

test "a plain reopen stops at the padding a crash left half written" {
    var synth: Synth = undefined;
    try synth.init(40, 65536, 0xA000, false);
    defer synth.deinit();

    const plain_cfg: config.Wal = .{ .plain = .{ .dir = "wal", .buffers = 40, .lba = config.kib(64) } };

    var op: [50000]u8 = undefined;
    recordOp(&op, 0xA001, 0);
    try synth.write(0xA001, &op);

    // A record too large for what is left of the block pads the remainder
    // first. The crash flushes only the padding run's opening buffers, so the
    // zeros reach the file while the block's end never does.
    const big = try testing.allocator.alloc(u8, 1048000);
    defer testing.allocator.free(big);
    recordOp(big, 0xA002, 0);
    synth.hold_from = 4;
    try synth.write(0xA002, big);

    const size = try res_handle.fileSize(synth.fd);
    try testing.expectEqual(@as(u64, 4 * 65536), size);

    var reopened = WalWriteFile.init(
        res_handle.adopt(synth.fd),
        Area.init(synth.pair.bytes, 40, 65536),
        plain_cfg,
        0,
        0,
        0xA000,
    );
    try reopened.walk(size);

    // The padding run means the block was closed, so the writer opens the next
    // one: the head is the record before the run and the fold starts empty.
    try testing.expectEqual(@as(u128, 0xA001), reopened.head);
    try testing.expectEqual(@as(u64, 16), reopened.current);
    try testing.expectEqual(@as(u32, 0), reopened.cursor);
    try testing.expectEqual(@as(u128, 0xA001), reopened.flushed_state);
    try testing.expectEqual(@as(u32, 0), reopened.flushed_crc);
}

test "a plain reopen drops the record straddling the flush frontier" {
    var synth: Synth = undefined;
    try synth.init(8, 65536, 0x8000, false);
    defer synth.deinit();

    const plain_cfg: config.Wal = .{ .plain = .{ .dir = "wal", .buffers = 8, .lba = config.kib(64) } };

    // Two records of 60000 op bytes: the first ends inside the first buffer,
    // the second straddles the frontier. Only whole buffers reach the file, so
    // the record crossing it is torn and dropped.
    const op_len = 60000;
    var op: [op_len]u8 = undefined;
    recordOp(&op, 0x8001, 0);
    try synth.write(0x8001, &op);
    recordOp(&op, 0x8002, 0);
    try synth.write(0x8002, &op);

    const size = try res_handle.fileSize(synth.fd);
    try testing.expectEqual(@as(u64, 65536), size);

    var reopened = WalWriteFile.init(
        res_handle.adopt(synth.fd),
        Area.init(synth.pair.bytes, 8, 65536),
        plain_cfg,
        0,
        0,
        0x8000,
    );
    try reopened.walk(size);

    // The writer resumes at the first record's end, inside the buffer it must
    // rewrite and re-flush.
    const first_framed = framedLen(op_len);
    try testing.expectEqual(@as(u128, 0x8001), reopened.head);
    try testing.expectEqual(@as(u64, 0), reopened.current);
    try testing.expectEqual(@as(u32, @intCast(first_framed)), reopened.cursor);
    try testing.expectEqual(@as(u64, 0), reopened.flushed_upto);
    try testing.expectEqual(@as(u128, 0x8000), reopened.flushed_state);
    try testing.expectEqual(@as(u32, 0), reopened.flushed_crc);

    // The fold at the write offset is the first record's frame.
    const kept = try testing.allocator.alloc(u8, first_framed);
    defer testing.allocator.free(kept);
    try res_handle.readFully(synth.fd, kept, 0);

    const line = reopened.headers[0];
    try testing.expectEqual(@as(u64, 0), line.buffer_seq);
    try testing.expectEqual(@as(u32, @intCast(first_framed)), line.data_len);
    try testing.expectEqual(@as(u32, 0), line.flags);
    try testing.expectEqual(blog.crc32c.hardwareCrc32C(kept), line.crc_running);
    try testing.expectEqual(@as(u128, 0x8001), line.last_state);

    // The resumed writer continues the block from there: the record that was
    // torn is written again, from the offset the parse stopped at.
    recordOp(&op, 0x8003, 0);
    try reopened.write(0x8003, 0x8001, &op);
    try testing.expectEqual(@as(u128, 0x8003), reopened.head);
    try testing.expectEqual(@as(u64, 1), reopened.current);
    try testing.expectEqual(
        @as(u32, @intCast(first_framed + framedLen(op_len) - 65536)),
        reopened.cursor,
    );

    // The new record's frame starts at the offset the parse stopped at: the
    // record the crash tore is written again over exactly its own bytes.
    var expected: [op_len + 19]u8 = undefined;
    const frame = expected[0..framedLen(op_len)];
    std.mem.writeInt(u128, frame[0..16], 0x8003, .little);
    const len_len = try resources.putUvarint(frame[16..], op_len);
    recordOp(&op, 0x8003, 0);
    @memcpy(frame[16 + len_len ..][0..op_len], &op);

    const filled = Area.init(synth.pair.bytes, 8, 65536).data[0..65536];
    try testing.expectEqualSlices(u8, frame[0 .. 65536 - first_framed], filled[first_framed..]);

    // The flush of that buffer reclaimed it with the recovered frontier pair:
    // the file's base state and an empty fold.
    const reclaimed = reopened.headers[0];
    try testing.expectEqual(@as(u64, 0), reclaimed.buffer_seq);
    try testing.expectEqual(@as(u32, 0), reclaimed.data_len);
    try testing.expectEqual(@as(u32, 0), reclaimed.flags);
    try testing.expectEqual(@as(u32, 0), reclaimed.crc_running);
    try testing.expectEqual(@as(u128, 0x8000), reclaimed.last_state);
}

// ============================================================================
// Naming
// ============================================================================

test "the snapshot leaf mirrors the wal leaf" {
    const allocator = testing.allocator;

    const snap = try snapshotPath(allocator, "/root/index.3", 2, 7, 0xDEADBEEF);
    defer allocator.free(snap);
    try testing.expectEqualStrings(
        "/root/index.3/snapshot.2.7.000000000000000000000000deadbeef",
        snap,
    );

    const wal_leaf = try walPath(allocator, "/root/index.3", 2, 7, 0xDEADBEEF);
    defer allocator.free(wal_leaf);

    // Equal tags pair the two names: their 32-hex tails are byte-equal.
    const tag = walTagFromPath(wal_leaf) orelse return error.UnparsedTag;
    try testing.expectEqual(@as(u128, 0xDEADBEEF), tag);
    try testing.expectEqualStrings(wal_leaf[wal_leaf.len - 32 ..], snap[snap.len - 32 ..]);

    // A same-tag retry renders byte-equal names, so it truncates its own
    // orphan instead of leaving a second one behind.
    const again = try snapshotPath(allocator, "/root/index.3", 2, 7, 0xDEADBEEF);
    defer allocator.free(again);
    try testing.expectEqualStrings(snap, again);
}

test "walTagFromPath round-trips every edge of the state range" {
    const allocator = testing.allocator;
    const tags = [_]u128{ 0, 1, 0x2000, 0xDEADBEEF, std.math.maxInt(u128) };
    for (tags) |tag| {
        const path = try walPath(allocator, "wal", 255, 65535, tag);
        defer allocator.free(path);
        try testing.expectEqual(tag, walTagFromPath(path) orelse return error.UnparsedTag);
    }
}

test "walTagFromPath rejects every other spelling" {
    const rejected = [_][]const u8{
        // The snapshot leaf is the other stem.
        "wal/snapshot.0.0.000000000000000000000000deadbeef",
        // Too short and too long.
        "wal/wal.0.0.deadbeef",
        "wal/wal.0.0.0000000000000000000000000deadbeef",
        // Non-hex and uppercase digits.
        "wal/wal.0.0.000000000000000000000000deadbeeg",
        "wal/wal.0.0.000000000000000000000000DEADBEEF",
        // No leaf at all.
        "wal",
        "",
    };
    for (rejected) |path| try testing.expectEqual(null, walTagFromPath(path));
}
