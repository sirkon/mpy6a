//! The logs of one index, stages 6 and 7 of designs/CONSENSUS-PLAN.md.
//!
//! The own log carries the flush of 2.5 step 5 and produces the restart epoch
//! of docs/consensus.md: after a restart a host must present itself as
//! `(host_idx, cur_host_epoch_idx)` with the epoch computed as the last epoch
//! written to its own log plus one. The replica logs carry the operations of
//! the other hosts this index mirrors: docs/consensus.md keeps one log per
//! host, and the log service of stage 7 answers a peer's `RequestLog` from
//! them.
//!
//! The record is fixed-size, self-delimiting and checksummed:
//!
//! ```text
//! magic: u16 | len: u32 | crc32: u32 | session_id: u128 | op: u8 | upgrade: u128
//! ```
//!
//! `op` is either a `state.Op` of a session mutation or a log command of the
//! `command_base` range; a command reuses the session field for the packed
//! state it names and the upgrade field for the state the host decided at.
//!
//! The checksum lets a restarted process recognise the torn tail of a crash
//! and drop it, so a half-written record never poisons the epoch. Still open,
//! and left to the WAL design of its own: snapshots, compaction, and an offset
//! index over a log (the service below walks the file per request).

const std = @import("std");
const posix = std.posix;
const state = @import("state.zig");

/// The two bytes that open a record; a file that does not start with them is
/// not this build's log.
pub const magic: u16 = 0x3657; // "W6"

/// Bytes of the record header.
pub const header_len = 2 + 4 + 4;

/// Bytes of the record body: the session, its operation and the state the
/// operation upgrades to.
pub const body_len = 16 + 1 + 16;

/// Bytes of one whole record.
pub const record_len = header_len + body_len;

/// One logged operation.
pub const Record = struct {
    session_id: u128,
    op: state.Op,
    /// The index state the operation upgrades to: the packed `IndexState`, so
    /// the record carries the epoch the host worked in.
    upgrade_idx: u128,
};

/// The errors a record that is not this build's own produces.
pub const DecodeError = error{
    /// The record is shorter than `record_len`.
    Truncated,
    /// The magic does not name this log.
    NotARecord,
    /// The length field disagrees with the record layout.
    Malformed,
    /// The checksum does not match the body.
    Corrupt,
    /// The operation tag is not one a session carries.
    UnknownOp,
};

/// The first op byte of the log commands. A session mutation carries a
/// `state.Op` (0..4), a command of this build starts here, so the two
/// vocabularies share the record layout without colliding.
pub const command_base: u8 = 0x80;

/// `Isolate`: the isolation decision of the host that writes the record, the
/// log command of docs/consensus.md. It names the exact logical boundary of
/// the lost host's log and the state of the writer the decision was taken at.
pub const isolate_code: u8 = command_base;

/// One `Isolate` log command.
pub const Isolate = struct {
    /// The packed state of the isolated host: the boundary of its log.
    host_state: u128,
    /// The packed state of the host that wrote the decision.
    own_state: u128,
};

/// One record of a log: a session mutation to replay, or a log command.
pub const Entry = union(enum) {
    mutation: Record,
    isolate: Isolate,
};

/// The packed state one entry records: the state a mutation upgrades to, the
/// state a command was decided at. Both live on the host the log belongs to,
/// so the value is monotone within the log.
pub fn stateOf(entry: Entry) u128 {
    return switch (entry) {
        .mutation => |record| record.upgrade_idx,
        .isolate => |command| command.own_state,
    };
}

/// Encodes one entry, checksum included.
pub fn encodeEntry(buf: *[record_len]u8, entry: Entry) void {
    const id: u128, const code: u8, const upgrade: u128 = switch (entry) {
        .mutation => |record| .{ record.session_id, @backingInt(record.op), record.upgrade_idx },
        .isolate => |command| .{ command.host_state, isolate_code, command.own_state },
    };
    std.mem.writeInt(u16, buf[0..2], magic, .little);
    std.mem.writeInt(u32, buf[2..6], body_len, .little);
    std.mem.writeInt(u128, buf[header_len..][0..16], id, .little);
    buf[header_len + 16] = code;
    std.mem.writeInt(u128, buf[header_len + 17 ..][0..16], upgrade, .little);
    std.mem.writeInt(u32, buf[6..10], std.hash.Crc32.hash(buf[header_len..record_len]), .little);
}

/// Encodes one mutation record, checksum included.
pub fn encode(buf: *[record_len]u8, record: Record) void {
    encodeEntry(buf, .{ .mutation = record });
}

/// Reads one entry back.
pub fn decodeEntry(bytes: []const u8) DecodeError!Entry {
    if (bytes.len < record_len) return error.Truncated;
    if (std.mem.readInt(u16, bytes[0..2], .little) != magic) return error.NotARecord;
    if (std.mem.readInt(u32, bytes[2..6], .little) != body_len) return error.Malformed;
    if (std.mem.readInt(u32, bytes[6..10], .little) != std.hash.Crc32.hash(bytes[header_len..record_len])) {
        return error.Corrupt;
    }
    const code = bytes[header_len + 16];
    if (code == isolate_code) {
        return .{ .isolate = .{
            .host_state = std.mem.readInt(u128, bytes[header_len..][0..16], .little),
            .own_state = std.mem.readInt(u128, bytes[header_len + 17 ..][0..16], .little),
        } };
    }
    return .{ .mutation = .{
        .session_id = std.mem.readInt(u128, bytes[header_len..][0..16], .little),
        .op = std.enums.fromInt(state.Op, code) orelse return error.UnknownOp,
        .upgrade_idx = std.mem.readInt(u128, bytes[header_len + 17 ..][0..16], .little),
    } };
}

/// Reads one mutation record back. A command record is refused: the caller
/// that only knows mutations has no business with the command vocabulary.
pub fn decode(bytes: []const u8) DecodeError!Record {
    return switch (try decodeEntry(bytes)) {
        .mutation => |record| record,
        .isolate => error.UnknownOp,
    };
}

/// The log of one host: the descriptor the flush writes through and the epoch
/// the host works in.
///
/// A negative descriptor means the log is not kept (an empty path, or a file
/// that could not be opened): flushes then complete without a record, exactly
/// as the stage-2 stub did, and the epoch stays zero.
pub const Wal = struct {
    const Self = @This();

    fd: posix.fd_t = -1,
    /// The epoch this run works in: the last epoch in the log plus one, zero
    /// for a log that carries no record yet (docs/consensus.md).
    epoch: state.EpochId = 0,
    /// How many bytes of a torn tail were dropped on open, for diagnostics.
    truncated: u64 = 0,

    /// Opens (creating it when missing) the log at `path`, drops a torn tail
    /// and computes the restart epoch. An empty path keeps no log at all.
    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Self {
        if (path.len == 0) return .{};

        const sentinel = try std.fmt.allocPrintSentinel(allocator, "{s}", .{path}, 0);
        defer allocator.free(sentinel);

        const raw = std.os.linux.open(sentinel, .{
            .ACCMODE = .RDWR,
            .CREAT = true,
            .APPEND = true,
        }, 0o644);
        if (std.os.linux.errno(raw) != .SUCCESS) return error.WalOpenFailed;
        const fd: posix.fd_t = @intCast(raw);
        errdefer _ = std.os.linux.close(fd);

        const scan = try scanLog(fd);
        if (scan.valid_len != scan.total_len) {
            const res = std.os.linux.ftruncate(fd, @intCast(scan.valid_len));
            if (std.os.linux.errno(res) != .SUCCESS) return error.WalTruncateFailed;
        }

        return .{
            .fd = fd,
            .epoch = if (scan.last_epoch) |last| last +% 1 else 0,
            .truncated = scan.total_len - scan.valid_len,
        };
    }

    pub fn close(self: *Self) void {
        if (self.fd < 0) return;
        _ = std.os.linux.close(self.fd);
        self.fd = -1;
    }

    /// Whether flushes are recorded at all.
    pub fn enabled(self: *const Self) bool {
        return self.fd >= 0;
    }

    /// The entries of the own log that follow the state `after`, whole records
    /// only: the answer to a peer's `RequestLog` for this host (stage 7).
    pub fn readAfter(self: *const Self, after: u128, out: []u8) !Chunk {
        return chunkAfter(self.fd, after, out);
    }
};

/// The replica log of one host: the operations of another leader this index
/// mirrors, appended as they arrive and served to peers that fell behind
/// (stage 7, docs/consensus.md "one host, one log").
///
/// A negative descriptor means the log is not kept (no `wal_path`, or a file
/// that could not be opened); replicated operations are then applied in memory
/// only, and a log request for the host is refused rather than answered with
/// data this host does not have.
pub const ReplicaLog = struct {
    const Self = @This();

    fd: posix.fd_t = -1,
    /// The packed state of the last record, the log pointer of this replica.
    last_state: u128 = 0,
    /// How many bytes of a torn tail were dropped on open, for diagnostics.
    truncated: u64 = 0,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Self {
        if (path.len == 0) return .{};

        const sentinel = try std.fmt.allocPrintSentinel(allocator, "{s}", .{path}, 0);
        defer allocator.free(sentinel);

        const raw = std.os.linux.open(sentinel, .{
            .ACCMODE = .RDWR,
            .CREAT = true,
            .APPEND = true,
        }, 0o644);
        if (std.os.linux.errno(raw) != .SUCCESS) return error.WalOpenFailed;
        const fd: posix.fd_t = @intCast(raw);
        errdefer _ = std.os.linux.close(fd);

        const scan = try scanLog(fd);
        if (scan.valid_len != scan.total_len) {
            const res = std.os.linux.ftruncate(fd, @intCast(scan.valid_len));
            if (std.os.linux.errno(res) != .SUCCESS) return error.WalTruncateFailed;
        }

        return .{
            .fd = fd,
            .last_state = scan.last_state orelse 0,
            .truncated = scan.total_len - scan.valid_len,
        };
    }

    pub fn close(self: *Self) void {
        if (self.fd < 0) return;
        _ = std.os.linux.close(self.fd);
        self.fd = -1;
    }

    pub fn enabled(self: *const Self) bool {
        return self.fd >= 0;
    }

    /// Appends one replicated entry. The write is synchronous: a replica log
    /// record is not on the client's path, and the asynchronous completion
    /// path of these logs arrives with the rest of the WAL design.
    pub fn append(self: *Self, entry: Entry) !void {
        if (self.fd < 0) return;

        var buf: [record_len]u8 = undefined;
        encodeEntry(&buf, entry);
        const res = std.os.linux.write(self.fd, &buf, buf.len);
        if (std.os.linux.errno(res) != .SUCCESS) return error.WalWriteFailed;
        // A short write leaves a torn tail the next open drops; the replica
        // does not pretend the record landed.
        if (res != record_len) return error.WalWriteFailed;
        self.last_state = stateOf(entry);
    }

    /// The entries that follow `after`, whole records only.
    pub fn readAfter(self: *const Self, after: u128, out: []u8) !Chunk {
        return chunkAfter(self.fd, after, out);
    }
};

/// One chunk of a log, the payload of `RequestedLog`.
pub const Chunk = struct {
    /// Whole records, each `record_len` bytes.
    bytes: []u8,
    /// The state of the last record taken; `after` when nothing was taken.
    last_state: u128,
    /// Whether the end of the trustworthy prefix was reached. A false flag
    /// means the buffer filled before the log ended.
    final: bool,
};

/// Whether `candidate` follows `after` in a log: within one epoch the index
/// slice orders the records, across an epoch the greater epoch does. A host
/// that restarted continues its log in the next epoch at index zero, so the
/// index slice alone cannot order the two.
fn follows(after: u128, candidate: u128) bool {
    const a = state.IndexState.unpack(after);
    const c = state.IndexState.unpack(candidate);
    if (c.epoch_id != a.epoch_id) return c.epoch_id > a.epoch_id;
    return c.index > a.index;
}

/// Reads one entry at `offset`, null at the end of the log or at the first
/// record that does not hold together.
pub fn entryAt(fd: posix.fd_t, offset: u64) !?Entry {
    if (fd < 0) return null;

    var buf: [record_len]u8 = undefined;
    const res = std.os.linux.pread(fd, &buf, buf.len, @intCast(offset));
    if (std.os.linux.errno(res) != .SUCCESS) return error.WalReadFailed;
    if (res < record_len) return null;
    return decodeEntry(&buf) catch null;
}

/// Reads the entries of an open log that follow `after` into `out`, whole
/// records only. The scan stops at the end of the trustworthy prefix or when
/// the buffer is full; `final` says which.
pub fn chunkAfter(fd: posix.fd_t, after: u128, out: []u8) !Chunk {
    var chunk = Chunk{ .bytes = out[0..0], .last_state = after, .final = true };
    if (fd < 0) return chunk;

    var offset: u64 = 0;
    var buf: [record_len]u8 = undefined;
    while (true) {
        const res = std.os.linux.pread(fd, &buf, buf.len, @intCast(offset));
        if (std.os.linux.errno(res) != .SUCCESS) return error.WalReadFailed;
        if (res < record_len) break;

        const entry = decodeEntry(&buf) catch break;
        offset += record_len;
        if (!follows(after, stateOf(entry))) continue;

        if (chunk.bytes.len + record_len > out.len) {
            // The record does not fit: the caller asks again from
            // `last_state` and this one is sent with that chunk.
            chunk.final = false;
            break;
        }
        @memcpy(out[chunk.bytes.len..][0..record_len], &buf);
        chunk.bytes = out[0 .. chunk.bytes.len + record_len];
        chunk.last_state = stateOf(entry);
    }
    return chunk;
}

/// What a scan of the log found.
pub const Scan = struct {
    /// The epoch of the last valid record, null for a log with no record.
    last_epoch: ?state.EpochId,
    /// The packed state of the last valid record, null for an empty log.
    last_state: ?u128,
    /// The bytes of the records that hold together.
    valid_len: u64,
    /// The bytes of the file, a torn tail included.
    total_len: u64,
};

/// Reads a whole log and checks every record in it. Scanning stops at the
/// first record that does not hold together: the rest of the file is the torn
/// tail of a crash, not a log this build may trust.
fn scanLog(fd: posix.fd_t) !Scan {
    // A whole number of records, so a record never straddles two reads.
    var buf: [record_len * 32]u8 = undefined;

    var valid: u64 = 0;
    var last: ?state.EpochId = null;
    var last_state: ?u128 = null;

    scan: while (true) {
        const res = std.os.linux.pread(fd, &buf, buf.len, @intCast(valid));
        if (std.os.linux.errno(res) != .SUCCESS) return error.WalReadFailed;
        const got: usize = res;
        // Fewer bytes than one record: the end of the log, whole or torn.
        if (got < record_len) break;

        var off: usize = 0;
        while (off + record_len <= got) : (off += record_len) {
            const entry = decodeEntry(buf[off..][0..record_len]) catch break :scan;
            const at = stateOf(entry);
            last = state.IndexState.unpack(at).epoch_id;
            last_state = at;
            valid += record_len;
        }
        // A short read means the file ended on a record boundary.
        if (got < buf.len) break;
    }

    return .{
        .last_epoch = last,
        .last_state = last_state,
        .valid_len = valid,
        .total_len = fileSize(fd),
    };
}

/// The length of the open log file.
fn fileSize(fd: posix.fd_t) u64 {
    return std.os.linux.lseek(fd, 0, std.os.linux.SEEK.END);
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "a record round-trips with its checksum" {
    var buf: [record_len]u8 = undefined;
    const upgrade = state.IndexState{ .host_id = 2, .index_id = 7, .epoch_id = 5, .index = 41 };
    const record = Record{ .session_id = 0xfeed, .op = .append, .upgrade_idx = upgrade.pack() };
    encode(&buf, record);

    const decoded = try decode(&buf);
    try expectEqual(record.session_id, decoded.session_id);
    try expectEqual(state.Op.append, decoded.op);
    try expectEqual(record.upgrade_idx, decoded.upgrade_idx);
    try expectEqual(@as(state.EpochId, 5), state.IndexState.unpack(decoded.upgrade_idx).epoch_id);

    // A flipped body byte is a corrupt record, not a guess.
    var corrupt = buf;
    corrupt[header_len] ^= 0x01;
    try std.testing.expectError(error.Corrupt, decode(&corrupt));

    // The magic and the declared length are checked before the checksum.
    var foreign = buf;
    foreign[0] ^= 0xff;
    try std.testing.expectError(error.NotARecord, decode(&foreign));
    var lying = buf;
    std.mem.writeInt(u32, lying[2..6], body_len - 1, .little);
    try std.testing.expectError(error.Malformed, decode(&lying));
    try std.testing.expectError(error.Truncated, decode(buf[0 .. record_len - 1]));
}

/// A temporary log path, unique per process and `tag`.
fn testPath(buf: []u8, tag: []const u8) [:0]const u8 {
    const text = std.fmt.bufPrint(buf, "/tmp/mpy6a-wal6-{s}-{d}.log", .{
        tag,
        std.os.linux.getpid(),
    }) catch unreachable;
    buf[text.len] = 0;
    return buf[0..text.len :0];
}

/// Appends `count` records with the epoch `epoch` straight to the file, the
/// way a running index would.
fn writeRecords(path: [:0]const u8, epoch: state.EpochId, count: usize) !void {
    const raw = std.os.linux.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644);
    try expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(raw));
    const fd: posix.fd_t = @intCast(raw);
    defer _ = std.os.linux.close(fd);

    var buf: [record_len]u8 = undefined;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const upgrade = state.IndexState{
            .host_id = 1,
            .index_id = 2,
            .epoch_id = epoch,
            .index = i,
        };
        encode(&buf, .{ .session_id = i, .op = .create, .upgrade_idx = upgrade.pack() });
        const res = std.os.linux.write(fd, &buf, buf.len);
        try expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(res));
    }
}

test "the restart epoch is the last logged epoch plus one" {
    var path_buf: [96]u8 = undefined;
    const path = testPath(&path_buf, "epoch");
    _ = std.os.linux.unlink(path.ptr);
    defer _ = std.os.linux.unlink(path.ptr);

    // A log that holds no record makes the host start at epoch zero.
    var empty = try Wal.open(std.testing.allocator, path);
    defer empty.close();
    try expect(empty.enabled());
    try expectEqual(@as(state.EpochId, 0), empty.epoch);
    try expectEqual(@as(u64, 0), empty.truncated);
    empty.close();

    try writeRecords(path, 3, 2);
    var restarted = try Wal.open(std.testing.allocator, path);
    defer restarted.close();
    try expectEqual(@as(state.EpochId, 4), restarted.epoch);

    // The next restart moves on again, so a host never presents a spent epoch.
    try writeRecords(path, restarted.epoch, 1);
    restarted.close();
    var again = try Wal.open(std.testing.allocator, path);
    defer again.close();
    try expectEqual(@as(state.EpochId, 5), again.epoch);
}

test "a torn tail is dropped instead of poisoning the epoch" {
    var path_buf: [96]u8 = undefined;
    const path = testPath(&path_buf, "torn");
    _ = std.os.linux.unlink(path.ptr);
    defer _ = std.os.linux.unlink(path.ptr);

    try writeRecords(path, 7, 2);

    // Half a record of garbage behind the two good ones: the tail of a crash.
    const raw = std.os.linux.open(path.ptr, .{ .ACCMODE = .WRONLY, .APPEND = true }, 0o644);
    try expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(raw));
    const fd: posix.fd_t = @intCast(raw);
    const torn = [_]u8{ 0xde, 0xad, 0xbe };
    _ = std.os.linux.write(fd, &torn, torn.len);
    _ = std.os.linux.close(fd);

    var wal = try Wal.open(std.testing.allocator, path);
    defer wal.close();
    try expectEqual(@as(state.EpochId, 8), wal.epoch);
    try expectEqual(@as(u64, torn.len), wal.truncated);

    // The tail is gone, so a second open finds a clean log.
    wal.close();
    var clean = try Wal.open(std.testing.allocator, path);
    defer clean.close();
    try expectEqual(@as(state.EpochId, 8), clean.epoch);
    try expectEqual(@as(u64, 0), clean.truncated);
}

test "an empty path keeps no log" {
    var wal = try Wal.open(std.testing.allocator, "");
    defer wal.close();
    try expect(!wal.enabled());
    try expectEqual(@as(state.EpochId, 0), wal.epoch);
}

/// A packed state of host 1 in the given epoch and index.
fn replicaState(epoch: state.EpochId, index: u64) u128 {
    return (state.IndexState{ .host_id = 1, .index_id = 0, .epoch_id = epoch, .index = index }).pack();
}

test "an isolate command shares the record layout with a mutation" {
    var buf: [record_len]u8 = undefined;
    const boundary = replicaState(3, 41);
    const own = replicaState(4, 7);
    encodeEntry(&buf, .{ .isolate = .{ .host_state = boundary, .own_state = own } });

    const entry = try decodeEntry(&buf);
    try expectEqual(boundary, entry.isolate.host_state);
    try expectEqual(own, entry.isolate.own_state);
    try expectEqual(own, stateOf(entry));

    // The mutation-only reader refuses the command instead of guessing at it.
    try std.testing.expectError(error.UnknownOp, decode(&buf));

    // The checksum covers the command body too.
    var corrupt = buf;
    corrupt[header_len + 17] ^= 0x01;
    try std.testing.expectError(error.Corrupt, decodeEntry(&corrupt));
}

test "a replica log appends and serves chunks from a state" {
    var path_buf: [96]u8 = undefined;
    const path = testPath(&path_buf, "replica");
    _ = std.os.linux.unlink(path.ptr);
    defer _ = std.os.linux.unlink(path.ptr);

    var log = try ReplicaLog.open(std.testing.allocator, path);
    try expect(log.enabled());

    // Three mutations of host 1 and the isolation decision at the third.
    for (1..4) |i| {
        try log.append(.{ .mutation = .{
            .session_id = replicaState(0, @intCast(i)),
            .op = .create,
            .upgrade_idx = replicaState(0, @intCast(i)),
        } });
    }
    try log.append(.{ .isolate = .{
        .host_state = replicaState(0, 3),
        .own_state = replicaState(0, 4),
    } });
    try expectEqual(replicaState(0, 4), log.last_state);
    log.close();

    // A clean reopen keeps every record and the pointer.
    log = try ReplicaLog.open(std.testing.allocator, path);
    defer log.close();
    try expectEqual(@as(u64, 0), log.truncated);
    try expectEqual(replicaState(0, 4), log.last_state);

    // The chunk is bounded by whole records: two records fit, so the third
    // waits for the next request, which names the state it stopped at.
    var out: [record_len * 2]u8 = undefined;
    const first = try log.readAfter(0, &out);
    try expectEqual(@as(usize, record_len * 2), first.bytes.len);
    try expectEqual(replicaState(0, 2), first.last_state);
    try expect(!first.final);
    try expectEqual(state.Op.create, (try decodeEntry(first.bytes[0..record_len])).mutation.op);

    // The rest of the log ends the stream: the command is the last record.
    const second = try log.readAfter(first.last_state, &out);
    try expectEqual(@as(usize, record_len * 2), second.bytes.len);
    try expectEqual(replicaState(0, 4), second.last_state);
    try expect(second.final);
    try expectEqual(state.Op.create, (try decodeEntry(second.bytes[0..record_len])).mutation.op);
    try expectEqual(replicaState(0, 3), stateOf(try decodeEntry(second.bytes[0..record_len])));
    switch (try decodeEntry(second.bytes[record_len..][0..record_len])) {
        .isolate => |command| try expectEqual(replicaState(0, 3), command.host_state),
        .mutation => return error.MissingCommand,
    }

    // Nothing follows the last record, and the next epoch of the same host
    // follows it even though its index slice starts over at zero.
    const empty = try log.readAfter(second.last_state, &out);
    try expectEqual(@as(usize, 0), empty.bytes.len);
    try expect(empty.final);

    try log.append(.{ .mutation = .{
        .session_id = replicaState(1, 1),
        .op = .create,
        .upgrade_idx = replicaState(1, 1),
    } });
    const restarted = try log.readAfter(second.last_state, &out);
    try expectEqual(@as(usize, record_len), restarted.bytes.len);
    try expectEqual(replicaState(1, 1), restarted.last_state);
}

test "the own log serves its records to the log service too" {
    var path_buf: [96]u8 = undefined;
    const path = testPath(&path_buf, "own-service");
    _ = std.os.linux.unlink(path.ptr);
    defer _ = std.os.linux.unlink(path.ptr);

    try writeRecords(path, 2, 3);
    var wal = try Wal.open(std.testing.allocator, path);
    defer wal.close();

    var out: [record_len * 4]u8 = undefined;
    const all = try wal.readAfter(0, &out);
    try expectEqual(@as(usize, record_len * 3), all.bytes.len);
    try expect(all.final);

    // From the second record on, the first is skipped.
    const tail = try wal.readAfter(replicaState(2, 0), &out);
    try expectEqual(@as(usize, record_len * 2), tail.bytes.len);
}
