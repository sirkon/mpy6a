//! Elephant thread: heavy background work, reached only through
//! `CrossTaskSlots`.
//!
//! An elephant has no inbox and no session state. It waits in its own ring for
//! two things: a `CrossTaskMessageIdx` completion carrying a slot index, or a
//! `ShutdownDemandIdx`. Its startup broadcast is a no-op: it ignores the
//! listening socket.

const std = @import("std");
const posix = std.posix;
const zigring = @import("zigring");
const lifetime = @import("lifetime.zig");
const messages = @import("messages.zig");
const logging = @import("logging.zig");
const cross_task = @import("cross_task.zig");
const wal = @import("wal.zig");

/// Runs the elephant thread to completion. `role` is the role the thread derived
/// from its `ring_idx` before reporting `INITIALIZED`.
pub fn run(ctrl: *lifetime.Controller, role: lifetime.Role, logger: *lifetime.LoggerStuff) void {
    const ring = &ctrl.rings[role.elephant.ring_idx];
    const log = &logger.logger;

    log.info("elephant started", .{ .ring_idx = role.elephant.ring_idx });

    while (true) {
        while (ring.ring.popCQE()) |cqe| {
            switch (cqe.taskIdx()) {
                // Launch broadcast: an elephant never touches the socket.
                messages.StartWorkIdx => {},
                messages.CrossTaskMessageIdx => {
                    const slot_idx: u32 = @intCast(cqe.res);
                    const task = ctrl.cross_slots.at(slot_idx).*;
                    ctrl.cross_slots.release(slot_idx);
                    handleTask(ctrl, task, log, role.elephant.ring_idx);
                },
                messages.ShutdownDemandIdx => {
                    // There is no multi-step operation in the skeleton, so the
                    // current unit of work is already finished by the time the
                    // demand is observed. A real elephant would drain its
                    // in-flight operation before this report.
                    log.info("elephant stopping", .{ .ring_idx = role.elephant.ring_idx });
                    reportDone(ring, ctrl, role.elephant.ring_idx);
                    return;
                },
                else => {},
            }
        }
        ring.ring.park();
    }
}

fn handleTask(
    ctrl: *lifetime.Controller,
    task: cross_task.CrossTask,
    log: *logging.Logger,
    own_ring_idx: u16,
) void {
    switch (task) {
        // Shutdown demands are delivered as a reserved taskIdx, not through a
        // slot; this variant is only reachable from a direct sender.
        .ShutdownDemand => |demand| {
            log.warn("elephant got a slot-borne shutdown demand", .{ .ring_idx = own_ring_idx, .hard = demand.hard });
        },
        .SoftShutdown => {},
        .ServerSocket => |socket| {
            // The socket is broadcast to fronts only; an elephant that sees it
            // closes its copy rather than leaking the descriptor.
            _ = std.os.linux.close(socket.fd);
        },
        .IndexDrained => {},
        .SnapshotCreate => |request| createSnapshot(ctrl, jobOf(request.job), log),
        .SnapshotDump => |request| dumpSnapshot(ctrl, jobOf(request.job), log, own_ring_idx),
        .SnapshotCleanup => |request| cleanupSnapshot(ctrl, jobOf(request.job), log),
        .SnapshotClose => |request| closeSnapshot(ctrl, jobOf(request.job), log),
        .SnapshotFd, .SnapshotCreateFailed, .SnapshotDumped, .SnapshotDumpFailed, .SnapshotAbandon, .SnapshotDone => {
            log.warn("elephant read a snapshot reply it does not handle", .{ .ring_idx = own_ring_idx });
        },
    }
}

fn jobOf(handle: usize) *lifetime.SnapshotJob {
    return @ptrFromInt(handle);
}

/// F1: creates the new WAL file under its final name.
///
/// The truncate is load-bearing: a same-tag retry would otherwise reopen a file
/// holding the failed attempt's flushed prefix, and that stale prefix would
/// survive the plain-mode walk as if it were content. One `fdatasync` before
/// the reply makes the empty length durable.
pub fn createSnapshot(ctrl: *lifetime.Controller, job: *lifetime.SnapshotJob, log: *logging.Logger) void {
    ctrl.ensureIndexDir(job.index_idx) catch |err| {
        log.err("snapshot create failed: the index directory is unavailable", .{
            .ring_idx = job.ring_idx,
            .index_idx = job.index_idx,
            .err = @errorName(err),
        });
        replyTo(ctrl, job.ring_idx, .{ .SnapshotCreateFailed = .{} });
        return;
    };

    const fd_raw = std.os.linux.open(job.wal_path, .{
        .ACCMODE = .RDWR,
        .CREAT = true,
        .TRUNC = true,
    }, 0o644);
    const errno = std.os.linux.errno(fd_raw);
    if (errno != .SUCCESS) {
        log.err("snapshot create failed", .{
            .ring_idx = job.ring_idx,
            .host_idx = job.host_idx,
            .index_idx = job.index_idx,
            .err = @tagName(errno),
        });
        replyTo(ctrl, job.ring_idx, .{ .SnapshotCreateFailed = .{} });
        return;
    }
    const fd: posix.fd_t = @intCast(fd_raw);

    const synced = std.os.linux.errno(std.os.linux.fdatasync(fd));
    if (synced != .SUCCESS) {
        _ = std.os.linux.close(fd);
        log.err("snapshot create sync failed", .{
            .ring_idx = job.ring_idx,
            .host_idx = job.host_idx,
            .index_idx = job.index_idx,
            .err = @tagName(synced),
        });
        replyTo(ctrl, job.ring_idx, .{ .SnapshotCreateFailed = .{} });
        return;
    }

    job.fd = fd;
    replyTo(ctrl, job.ring_idx, .{ .SnapshotFd = .{ .fd = fd } });
}

/// F2: dumps the clone, commits the registry line, and answers.
///
/// The clone's arena reset releases the clone and the dump bytes on every path.
/// A dump failure answers `SnapshotDumpFailed`; a registry failure answers
/// `SnapshotAbandon`; a corrupt registry is the runtime fatality, requested
/// before any abandon, and gets no reply because the process is coming down.
pub fn dumpSnapshot(
    ctrl: *lifetime.Controller,
    job: *lifetime.SnapshotJob,
    log: *logging.Logger,
    own_ring_idx: u16,
) void {
    const state_y = job.clone.state;

    const written = writeSnapshotFile(ctrl, job);
    _ = job.arena.reset(.free_all);

    written catch |err| {
        log.err("snapshot dump failed", .{
            .ring_idx = job.ring_idx,
            .host_idx = job.host_idx,
            .index_idx = job.index_idx,
            .err = @errorName(err),
        });
        replyTo(ctrl, job.ring_idx, .{ .SnapshotDumpFailed = .{} });
        return;
    };

    ctrl.rewriteRegistry(job.index_idx, .{
        .host_idx = job.host_idx,
        .snapshot_path = job.snapshot_path,
        .wal_path = job.wal_path,
        .state = state_y,
    }) catch |err| switch (err) {
        error.RegistryCorrupt => {
            const rendered = ctrl.registryPath(job.index_idx) catch null;
            defer if (rendered) |path| ctrl.allocator.free(path);
            const registry_path: []const u8 = rendered orelse "<unavailable>";
            log.err("snapshot registry is corrupt; requesting a process stop", .{
                .ring_idx = own_ring_idx,
                .index_idx = job.index_idx,
                .registry_path = registry_path,
            });
            requestProcessStop(ctrl, own_ring_idx, log);
            return;
        },
        else => {
            log.err("snapshot registry rewrite failed; abandoning", .{
                .ring_idx = job.ring_idx,
                .host_idx = job.host_idx,
                .index_idx = job.index_idx,
                .err = @errorName(err),
            });
            replyTo(ctrl, job.ring_idx, .{ .SnapshotAbandon = .{} });
            return;
        },
    };

    replyTo(ctrl, job.ring_idx, .{ .SnapshotDumped = .{} });
}

fn writeSnapshotFile(ctrl: *lifetime.Controller, job: *lifetime.SnapshotJob) !void {
    var out: std.ArrayList(u8) = .empty;
    try ctrl.dumpIndexState(&job.clone, &out);

    const fd_raw = std.os.linux.open(job.snapshot_path, .{
        .ACCMODE = .RDWR,
        .CREAT = true,
        .TRUNC = true,
    }, 0o644);
    const errno = std.os.linux.errno(fd_raw);
    if (errno != .SUCCESS) return std.posix.unexpectedErrno(errno);
    const fd: posix.fd_t = @intCast(fd_raw);

    writeAll(fd, out.items) catch |err| {
        _ = std.os.linux.close(fd);
        return err;
    };
    syncFd(fd) catch |err| {
        _ = std.os.linux.close(fd);
        return err;
    };
    const closed = std.os.linux.errno(std.os.linux.close(fd));
    if (closed != .SUCCESS) return std.posix.unexpectedErrno(closed);
}

/// F3: the success path's terminal elephant.
///
/// The old descriptor's close is hygiene, not durability: both modes are
/// deliberately buffered, so a refused close is a warning and the procedure
/// still finishes. The slot returns to the pool and the job shell dies here;
/// the index clears its in-flight flag on the `SnapshotDone` reply.
pub fn closeSnapshot(ctrl: *lifetime.Controller, job: *lifetime.SnapshotJob, log: *logging.Logger) void {
    const ring_idx = job.ring_idx;
    const k = job.k;

    if (job.old_fd != -1) {
        const errno = std.os.linux.errno(std.os.linux.close(job.old_fd));
        if (errno != .SUCCESS) {
            log.warn("snapshot final close failed", .{
                .ring_idx = ring_idx,
                .host_idx = job.host_idx,
                .index_idx = job.index_idx,
                .err = @tagName(errno),
            });
        }
        job.old_fd = -1;
    }

    ctrl.snapshot_slots.at(k).status = .idle;
    ctrl.snapshot_slots.release(k);
    ctrl.releaseSnapshotJob(job);
    replyTo(ctrl, ring_idx, .{ .SnapshotDone = .{} });
}

/// F3: the failure path's terminal elephant (design §8).
///
/// Unlinks both files best effort, closes any descriptor still held, clears
/// the slot and releases it, then destroys the job shell and answers
/// `SnapshotDone`. Absent files are success: the create-failure rung has none.
pub fn cleanupSnapshot(ctrl: *lifetime.Controller, job: *lifetime.SnapshotJob, log: *logging.Logger) void {
    const ring_idx = job.ring_idx;
    const k = job.k;

    unlinkBestEffort(job.wal_path, job, log, "wal");
    unlinkBestEffort(job.snapshot_path, job, log, "snapshot");

    if (job.fd != -1) {
        _ = std.os.linux.close(job.fd);
        job.fd = -1;
    }
    if (job.old_fd != -1) {
        _ = std.os.linux.close(job.old_fd);
        job.old_fd = -1;
    }

    if (ctrl.snapshot_slots.at(k).status != .rollback) {
        log.warn("snapshot cleanup arrived with a non-rollback slot status", .{
            .ring_idx = ring_idx,
            .host_idx = job.host_idx,
            .index_idx = job.index_idx,
            .status = @tagName(ctrl.snapshot_slots.at(k).status),
        });
    }
    ctrl.snapshot_slots.at(k).status = .idle;
    ctrl.snapshot_slots.release(k);
    ctrl.releaseSnapshotJob(job);
    replyTo(ctrl, ring_idx, .{ .SnapshotDone = .{} });
}

fn unlinkBestEffort(
    path: [:0]const u8,
    job: *lifetime.SnapshotJob,
    log: *logging.Logger,
    kind: []const u8,
) void {
    const errno = std.os.linux.errno(std.os.linux.unlink(path));
    if (errno == .SUCCESS or errno == .NOENT) return;
    log.warn("snapshot cleanup could not unlink a file", .{
        .ring_idx = job.ring_idx,
        .host_idx = job.host_idx,
        .index_idx = job.index_idx,
        .leaf = kind,
        .err = @tagName(errno),
    });
}

/// The runtime fatality of a corrupt registry (design §2.4, §8 rung 6). The
/// request rides the init ring; with an invalid line there is no torn append
/// that could have produced it, so no reply to the index follows.
fn requestProcessStop(ctrl: *lifetime.Controller, own_ring_idx: u16, log: *logging.Logger) void {
    log.err("snapshot procedure requests a process stop", .{ .ring_idx = own_ring_idx });
    while (true) {
        if (ctrl.init_ring.ring.pushMsgRingFd(
            ctrl.init_ring.ring.fd,
            messages.ProcessStopRequestIdx,
            own_ring_idx,
            .{},
        )) |_| {
            return;
        } else |err| switch (err) {
            error.RingFull => std.atomic.spinLoopHint(),
        }
    }
}

/// One reply on the requesting index thread's ring. The slot is acquired once
/// and its payload written once; only a refused `MSG_RING` spins (elephants may
/// spin, `index_inbox.zig:248-262`).
fn replyTo(ctrl: *lifetime.Controller, ring_idx: u16, payload: cross_task.CrossTask) void {
    var slot_idx: u32 = undefined;
    while (true) {
        slot_idx = ctrl.cross_slots.acquire() catch {
            std.atomic.spinLoopHint();
            continue;
        };
        break;
    }
    ctrl.cross_slots.at(slot_idx).* = payload;

    while (true) {
        if (ctrl.rings[ring_idx].ring.pushMsgRingFd(
            ctrl.rings[ring_idx].ring.fd,
            messages.CrossTaskMessageIdx,
            slot_idx,
            .{},
        )) |_| {
            return;
        } else |err| switch (err) {
            error.RingFull => std.atomic.spinLoopHint(),
        }
    }
}

fn writeAll(fd: posix.fd_t, bytes: []const u8) !void {
    var done: usize = 0;
    while (done < bytes.len) {
        const res = std.os.linux.write(fd, bytes[done..].ptr, bytes.len - done);
        const errno = std.os.linux.errno(res);
        if (errno != .SUCCESS) return std.posix.unexpectedErrno(errno);
        if (res == 0) return error.WriteZero;
        done += res;
    }
}

fn syncFd(fd: posix.fd_t) !void {
    const errno = std.os.linux.errno(std.os.linux.fdatasync(fd));
    if (errno != .SUCCESS) return std.posix.unexpectedErrno(errno);
}

fn reportDone(ring: *lifetime.RingStuff, ctrl: *lifetime.Controller, ring_idx: u16) void {
    while (true) {
        if (ring.ring.pushMsgRingFd(ctrl.init_ring.ring.fd, messages.ShutdownDoneIdx, ring_idx, .{})) |_| {
            return;
        } else |err| switch (err) {
            error.RingFull => std.atomic.spinLoopHint(),
        }
    }
}

const config = @import("config.zig");
const state = @import("state.zig");

const ElephantFixture = struct {
    tmp: std.testing.TmpDir,
    dir: []u8,
    cfg: config.Config,
    ctrl: lifetime.Controller,

    fn init(self: *ElephantFixture) !void {
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.dir = try std.fmt.allocPrint(
            std.testing.allocator,
            ".zig-cache/tmp/{s}",
            .{self.tmp.sub_path[0..]},
        );
        self.cfg = .{
            .fronts = 1,
            .indexes = 1,
            .elephants = 1,
            .queue_depth = 64,
            .cross_task_slots = 8,
            .sqpoll_threads = 1,
            .ring_slots_capacity = 4096,
            .index_inbox_capacity = 8,
            .wal = .{ .plain = .{ .dir = self.dir, .buffers = 4, .lba = 512, .hosts = 1 } },
            .snapshots = .{ .registry_keep = 2 },
            .logging = .{
                .method = .{ .json = {} },
                .pool_capacity = 64,
                .pool_frame_size = 1024,
            },
        };
        try self.ctrl.init(std.testing.allocator, &self.cfg);
        errdefer self.ctrl.deinit();
        try self.ctrl.compensators.put("marker", .{ .bind = "10.0.0.1", .port = 20301 });
        try self.ctrl.initRing(1, 1);
    }

    fn deinit(self: *ElephantFixture) void {
        self.ctrl.rings[1].deinit();
        self.ctrl.deinit();
        std.testing.allocator.free(self.dir);
        self.tmp.cleanup();
    }

    fn log(self: *ElephantFixture) !*lifetime.LoggerStuff {
        return self.ctrl.getInitLogger();
    }
};

const index_ring_idx: u16 = 1;
const elephant_ring_idx: u16 = 2;

fn dropLogger(ctrl: *lifetime.Controller, logger: *lifetime.LoggerStuff) void {
    logger.deinit(ctrl.allocator);
    ctrl.allocator.destroy(logger);
}

fn recvReply(ctrl: *lifetime.Controller, deadline_ns: u64) !cross_task.CrossTask {
    while (zigring.monotonicNs() < deadline_ns) {
        if (ctrl.rings[index_ring_idx].ring.popCQE()) |cqe| {
            try std.testing.expectEqual(messages.CrossTaskMessageIdx, cqe.taskIdx());
            const slot_idx: u32 = @intCast(cqe.res);
            const task = ctrl.cross_slots.at(slot_idx).*;
            ctrl.cross_slots.release(slot_idx);
            return task;
        }
        std.atomic.spinLoopHint();
    }
    return error.ReplyTimeout;
}

fn deadline() u64 {
    return zigring.monotonicNs() + 2 * std.time.ns_per_s;
}

/// Spins until `ring` yields one completion or the deadline passes. The
/// `MSG_RING` a terminal elephant posts lands on the target ring's CQ a moment
/// after the push returns, so a test must not demand it synchronously.
fn cqeWithin(ring: *zigring.Ring, deadline_ns: u64) ?zigring.CQE {
    while (zigring.monotonicNs() < deadline_ns) {
        if (ring.popCQE()) |cqe| return cqe;
        std.atomic.spinLoopHint();
    }
    return null;
}

fn mintJob(f: *ElephantFixture, tag: u128) !*lifetime.SnapshotJob {
    const k = try f.ctrl.snapshot_slots.acquire();
    return f.ctrl.mintSnapshotJob(0, 0, tag, k, index_ring_idx);
}

fn writeRawFile(path: []const u8, bytes: []const u8) !void {
    const path_z = try std.testing.allocator.dupeSentinel(u8, path, 0);
    defer std.testing.allocator.free(path_z);

    const fd_raw = std.os.linux.open(path_z, .{
        .ACCMODE = .RDWR,
        .CREAT = true,
        .TRUNC = true,
    }, 0o644);
    const errno = std.os.linux.errno(fd_raw);
    if (errno != .SUCCESS) return std.posix.unexpectedErrno(errno);
    const fd: posix.fd_t = @intCast(fd_raw);
    defer _ = std.os.linux.close(fd);
    try writeAll(fd, bytes);
}

fn readRawFile(path: []const u8) ![]u8 {
    const path_z = try std.testing.allocator.dupeSentinel(u8, path, 0);
    defer std.testing.allocator.free(path_z);

    const fd_raw = std.os.linux.open(path_z, .{ .ACCMODE = .RDONLY }, 0);
    const errno = std.os.linux.errno(fd_raw);
    if (errno != .SUCCESS) return std.posix.unexpectedErrno(errno);
    const fd: posix.fd_t = @intCast(fd_raw);
    defer _ = std.os.linux.close(fd);

    const size = try wal.fileSize(fd);
    const bytes = try std.testing.allocator.alloc(u8, @intCast(size));
    errdefer std.testing.allocator.free(bytes);

    var got: usize = 0;
    while (got < bytes.len) {
        const at: posix.off_t = @intCast(got);
        const res = std.os.linux.pread(fd, bytes[got..].ptr, bytes.len - got, at);
        const read_errno = std.os.linux.errno(res);
        if (read_errno != .SUCCESS) return std.posix.unexpectedErrno(read_errno);
        if (res == 0) return error.EndOfStream;
        got += res;
    }
    return bytes;
}

fn fdIsClosed(fd: posix.fd_t) bool {
    const res = std.os.linux.fcntl(fd, std.os.linux.F.GETFD, 0);
    return std.os.linux.errno(res) == .BADF;
}

fn pathExists(path: [:0]const u8) bool {
    const fd_raw = std.os.linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    const errno = std.os.linux.errno(fd_raw);
    if (errno != .SUCCESS) return false;
    _ = std.os.linux.close(@intCast(fd_raw));
    return true;
}

fn openRaw(path: [:0]const u8, flags: std.os.linux.O) !posix.fd_t {
    const fd_raw = std.os.linux.open(path, flags, 0);
    const errno = std.os.linux.errno(fd_raw);
    if (errno != .SUCCESS) return std.posix.unexpectedErrno(errno);
    return @intCast(fd_raw);
}

test "create truncates a stale prefix and replies the descriptor" {
    var f: ElephantFixture = undefined;
    try f.init();
    defer f.deinit();
    const log = try f.log();
    defer dropLogger(&f.ctrl, log);

    const job = try mintJob(&f, 0x2a);
    defer f.ctrl.releaseSnapshotJob(job);

    try f.ctrl.ensureIndexDir(0);
    try writeRawFile(job.wal_path, "garbage prefix that must not survive");

    handleTask(&f.ctrl, .{ .SnapshotCreate = .{ .job = @intFromPtr(job) } }, &log.logger, elephant_ring_idx);

    const reply = try recvReply(&f.ctrl, deadline());
    const fd = switch (reply) {
        .SnapshotFd => |r| r.fd,
        else => return error.UnexpectedReply,
    };
    try std.testing.expectEqual(fd, job.fd);
    try std.testing.expectEqual(@as(u64, 0), try wal.fileSize(fd));

    const on_disk = try readRawFile(job.wal_path);
    defer std.testing.allocator.free(on_disk);
    try std.testing.expectEqual(@as(usize, 0), on_disk.len);

    _ = std.os.linux.close(fd);
    job.fd = -1;
}

test "create failure replies SnapshotCreateFailed and holds no descriptor" {
    var f: ElephantFixture = undefined;
    try f.init();
    defer f.deinit();
    const log = try f.log();
    defer dropLogger(&f.ctrl, log);

    const job = try mintJob(&f, 0x2b);
    defer f.ctrl.releaseSnapshotJob(job);

    // A directory where the file belongs makes the open fail.
    try f.ctrl.ensureIndexDir(0);
    const made = std.os.linux.errno(std.os.linux.mkdir(job.wal_path, 0o755));
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, made);

    handleTask(&f.ctrl, .{ .SnapshotCreate = .{ .job = @intFromPtr(job) } }, &log.logger, elephant_ring_idx);

    const reply = try recvReply(&f.ctrl, deadline());
    try std.testing.expectEqual(cross_task.CrossTask.SnapshotCreateFailed, std.meta.activeTag(reply));
    try std.testing.expectEqual(@as(posix.fd_t, -1), job.fd);
    try std.testing.expectEqual(f.ctrl.snapshot_slots.freeCount(), f.ctrl.snapshot_slots.tasks.len - 1);
}

fn makeClone(f: *ElephantFixture, job: *lifetime.SnapshotJob, state_y: u128) !void {
    var live: state.IndexState = undefined;
    try f.ctrl.initIndexState(&live);
    defer f.ctrl.deinitIndexState(&live);

    live.state = state_y;
    try f.ctrl.applyIndexOp(&live, .{ .create = .{ .compensator = "marker", .payload = "snapshotted" } });

    job.clone = try f.ctrl.cloneIndexState(&live, job.arena.allocator());
}

test "dump writes the final name, commits the registry line and replies" {
    var f: ElephantFixture = undefined;
    try f.init();
    defer f.deinit();
    const log = try f.log();
    defer dropLogger(&f.ctrl, log);

    const tag: u128 = 0x2c;
    const state_y: u128 = tag + 5;
    const job = try mintJob(&f, tag);
    defer f.ctrl.releaseSnapshotJob(job);
    try makeClone(&f, job, state_y);
    try f.ctrl.ensureIndexDir(0);

    handleTask(&f.ctrl, .{ .SnapshotDump = .{ .job = @intFromPtr(job) } }, &log.logger, elephant_ring_idx);

    const reply = try recvReply(&f.ctrl, deadline());
    try std.testing.expectEqual(cross_task.CrossTask.SnapshotDumped, std.meta.activeTag(reply));

    const bytes = try readRawFile(job.snapshot_path);
    defer std.testing.allocator.free(bytes);
    var loaded = try f.ctrl.loadIndexState(bytes);
    defer f.ctrl.deinitIndexState(&loaded);
    try std.testing.expectEqual(@as(usize, 1), loaded.sessions.count());
    try std.testing.expect(loaded.sessions.get(state_y) != null);

    const entries = (try f.ctrl.loadRegistry(0)).?;
    defer f.ctrl.freeRegistry(entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqual(@as(u8, 0), entries[0].host_idx);
    try std.testing.expectEqual(state_y, entries[0].state);
    try std.testing.expectEqualStrings(job.snapshot_path, entries[0].snapshot_path);
    try std.testing.expectEqualStrings(job.wal_path, entries[0].wal_path);
}

test "a dump compacts a pre-existing multi-line registry" {
    var f: ElephantFixture = undefined;
    try f.init();
    defer f.deinit();
    const log = try f.log();
    defer dropLogger(&f.ctrl, log);

    var line: usize = 0;
    while (line < 5) : (line += 1) {
        try f.ctrl.rewriteRegistry(0, .{
            .host_idx = 0,
            .snapshot_path = @constCast("old-snapshot"),
            .wal_path = @constCast("old-wal"),
            .state = @intCast(line),
        });
    }

    const tag: u128 = 0x2d;
    const job = try mintJob(&f, tag);
    defer f.ctrl.releaseSnapshotJob(job);
    try makeClone(&f, job, tag);

    handleTask(&f.ctrl, .{ .SnapshotDump = .{ .job = @intFromPtr(job) } }, &log.logger, elephant_ring_idx);
    try std.testing.expectEqual(cross_task.CrossTask.SnapshotDumped, std.meta.activeTag(try recvReply(&f.ctrl, deadline())));

    const entries = (try f.ctrl.loadRegistry(0)).?;
    defer f.ctrl.freeRegistry(entries);
    // `registry_keep` retained lines plus the new one.
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqual(tag, entries[entries.len - 1].state);
}

test "a registry rewrite failure replies SnapshotAbandon and keeps the old file" {
    var f: ElephantFixture = undefined;
    try f.init();
    defer f.deinit();
    const log = try f.log();
    defer dropLogger(&f.ctrl, log);

    try f.ctrl.rewriteRegistry(0, .{
        .host_idx = 0,
        .snapshot_path = @constCast("kept-snapshot"),
        .wal_path = @constCast("kept-wal"),
        .state = 7,
    });
    const registry = try f.ctrl.registryPath(0);
    defer std.testing.allocator.free(registry);
    const before = try readRawFile(registry);
    defer std.testing.allocator.free(before);

    // The staging leaf occupied by a directory refuses the rewrite's open.
    const pending = try f.ctrl.registryPendingPath(0);
    defer std.testing.allocator.free(pending);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.mkdir(pending, 0o755)));

    const job = try mintJob(&f, 0x2e);
    defer f.ctrl.releaseSnapshotJob(job);
    try makeClone(&f, job, 0x2e);

    handleTask(&f.ctrl, .{ .SnapshotDump = .{ .job = @intFromPtr(job) } }, &log.logger, elephant_ring_idx);
    try std.testing.expectEqual(cross_task.CrossTask.SnapshotAbandon, std.meta.activeTag(try recvReply(&f.ctrl, deadline())));

    const after = try readRawFile(registry);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "a corrupt registry requests a process stop and sends no reply" {
    var f: ElephantFixture = undefined;
    try f.init();
    defer f.deinit();
    const log = try f.log();
    defer dropLogger(&f.ctrl, log);

    try f.ctrl.ensureIndexDir(0);
    const registry = try f.ctrl.registryPath(0);
    defer std.testing.allocator.free(registry);
    try writeRawFile(registry, "not a registry line\n");

    const job = try mintJob(&f, 0x2f);
    defer f.ctrl.releaseSnapshotJob(job);
    try makeClone(&f, job, 0x2f);

    handleTask(&f.ctrl, .{ .SnapshotDump = .{ .job = @intFromPtr(job) } }, &log.logger, elephant_ring_idx);

    const cqe = cqeWithin(&f.ctrl.init_ring.ring, deadline()) orelse return error.MissingStopRequest;
    try std.testing.expectEqual(messages.ProcessStopRequestIdx, cqe.taskIdx());
    try std.testing.expectEqual(@as(i32, elephant_ring_idx), @as(i32, @intCast(cqe.res)));
    try std.testing.expect(f.ctrl.rings[index_ring_idx].ring.popCQE() == null);
}

test "a dump failure replies SnapshotDumpFailed and frees the arena" {
    var f: ElephantFixture = undefined;
    try f.init();
    defer f.deinit();
    const log = try f.log();
    defer dropLogger(&f.ctrl, log);

    const job = try mintJob(&f, 0x30);
    defer f.ctrl.releaseSnapshotJob(job);
    try makeClone(&f, job, 0x30);

    // A directory at the snapshot leaf makes the write fail.
    try f.ctrl.ensureIndexDir(0);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.mkdir(job.snapshot_path, 0o755)));

    handleTask(&f.ctrl, .{ .SnapshotDump = .{ .job = @intFromPtr(job) } }, &log.logger, elephant_ring_idx);
    try std.testing.expectEqual(cross_task.CrossTask.SnapshotDumpFailed, std.meta.activeTag(try recvReply(&f.ctrl, deadline())));
    try std.testing.expectEqual(
        @as(?[]lifetime.Controller.RegistryEntry, null),
        try f.ctrl.loadRegistry(0),
    );
}

test "close is terminal: the old fd dies, the slot returns, the job is gone" {
    var f: ElephantFixture = undefined;
    try f.init();
    defer f.deinit();
    const log = try f.log();
    defer dropLogger(&f.ctrl, log);

    const job = try mintJob(&f, 0x31);
    const k = job.k;
    const old_fd = try openRaw("/dev/null", .{ .ACCMODE = .RDONLY });
    job.old_fd = old_fd;
    f.ctrl.snapshot_slots.at(k).* = .{ .status = .in_flight, .job = @intFromPtr(job) };

    handleTask(&f.ctrl, .{ .SnapshotClose = .{ .job = @intFromPtr(job) } }, &log.logger, elephant_ring_idx);

    try std.testing.expect(fdIsClosed(old_fd));
    try std.testing.expectEqual(f.ctrl.snapshot_slots.tasks.len, f.ctrl.snapshot_slots.freeCount());
    try std.testing.expectEqual(cross_task.CrossTask.SnapshotDone, std.meta.activeTag(try recvReply(&f.ctrl, deadline())));
}

test "cleanup unlinks both files, closes the live fd and tolerates absences" {
    var f: ElephantFixture = undefined;
    try f.init();
    defer f.deinit();
    const log = try f.log();
    defer dropLogger(&f.ctrl, log);

    try f.ctrl.ensureIndexDir(0);

    // First: files and descriptors present.
    const job = try mintJob(&f, 0x32);
    const k = job.k;
    const wal_path = try std.testing.allocator.dupeSentinel(u8, job.wal_path, 0);
    defer std.testing.allocator.free(wal_path);
    const snapshot_path = try std.testing.allocator.dupeSentinel(u8, job.snapshot_path, 0);
    defer std.testing.allocator.free(snapshot_path);
    try writeRawFile(wal_path, "wal");
    try writeRawFile(snapshot_path, "snapshot");
    const live_fd = try openRaw(wal_path, .{ .ACCMODE = .RDONLY });
    job.fd = live_fd;
    f.ctrl.snapshot_slots.at(k).* = .{ .status = .rollback, .job = @intFromPtr(job) };

    handleTask(&f.ctrl, .{ .SnapshotCleanup = .{ .job = @intFromPtr(job) } }, &log.logger, elephant_ring_idx);

    try std.testing.expect(!pathExists(wal_path));
    try std.testing.expect(!pathExists(snapshot_path));
    try std.testing.expect(fdIsClosed(live_fd));
    try std.testing.expectEqual(cross_task.CrossTask.SnapshotDone, std.meta.activeTag(try recvReply(&f.ctrl, deadline())));
    try std.testing.expectEqual(f.ctrl.snapshot_slots.tasks.len, f.ctrl.snapshot_slots.freeCount());

    // Second: nothing on disk, no descriptors held: still a clean unwind.
    const bare = try mintJob(&f, 0x33);
    f.ctrl.snapshot_slots.at(bare.k).* = .{ .status = .rollback, .job = @intFromPtr(bare) };
    handleTask(&f.ctrl, .{ .SnapshotCleanup = .{ .job = @intFromPtr(bare) } }, &log.logger, elephant_ring_idx);
    try std.testing.expectEqual(cross_task.CrossTask.SnapshotDone, std.meta.activeTag(try recvReply(&f.ctrl, deadline())));
    try std.testing.expectEqual(f.ctrl.snapshot_slots.tasks.len, f.ctrl.snapshot_slots.freeCount());
}
