//! Logging setup for the whole process.
//!
//! Standard error is the only destination for now. Every thread builds its own
//! `Scoped` logger: its own frame pool, its own `PrettySink` and therefore its
//! own render scratch space, plus a handle onto the one shared `FdWriter` that
//! owns the descriptor. Render state is per thread, but the final write to the
//! descriptor is serialised with `std.debug`'s stderr lock: the process also
//! prints lifecycle messages with `std.debug.print`, and without the shared
//! lock those records can land in the middle of a rendered frame.
//!
//! Records are deliberately not ordered between threads. Each record leaves as
//! one `write(2)` while the lock is held, so a caller cannot observe a splice
//! even if the kernel returns a short write. Swapping `Writer` for an
//! io_uring-backed sink later needs no change at the call sites.
//!
//! `blog`'s sinks are typed over the non-thread-safe pool (`BufferPool(false)`),
//! which is another reason the pool is per thread: a single shared pool would
//! not type-check against `PrettySink` at all.

const std = @import("std");
const linux = std.os.linux;
const blog = @import("blog");
const zigring = @import("zigring");
const slots = @import("slots.zig");
const config = @import("config.zig");
const lifetime = @import("lifetime.zig");

pub const Logger = blog.Logger(blog.BufferPool, Sink);

/// Sink for blog.Logger. Borrows its values.
pub const Sink = union(enum) {
    const Self = @This();

    const Pretty = struct {
        sink: blog.PrettySink(blog.FdWriter),
        writer: blog.FdWriter,
    };
    const Json = struct {
        sink: blog.JsonSink(blog.FdWriter),
        writer: blog.FdWriter,
    };
    const File = struct {
        sink: IouringSink,
        fd: std.posix.fd_t,
    };

    pretty: *Pretty,
    json: *Json,
    file: *File,

    pub fn write(self: *Self, bufpool: *blog.BufferPool, buf: []const u8) blog.WriteError!usize {
        switch (self.*) {
            .pretty => |pretty| {
                @branchHint(.cold);
                _ = std.debug.lockStderr(&.{});
                defer std.debug.unlockStderr();
                return pretty.sink.write(bufpool, buf);
            },
            .json => |json| {
                @branchHint(.cold);
                _ = std.debug.lockStderr(&.{});
                defer std.debug.unlockStderr();
                return json.sink.write(bufpool, buf);
            },
            .file => |file| {
                @branchHint(.likely);
                return file.sink.write(bufpool, buf);
            },
        }
    }

    /// Releases the buffer and slot of a completed file write. Returns false
    /// when `task_idx` is not a `.logging` operation.
    pub fn complete(self: *Self, pool: *blog.BufferPool, task_idx: u64) bool {
        return switch (self.*) {
            .pretty, .json => false,
            .file => |file| file.sink.complete(pool, task_idx),
        };
    }

    /// Waits for every file write still in flight. Returns false when the
    /// deadline expires, in which case the caller must not free the record
    /// buffers or close the log descriptor.
    pub fn drain(self: *Self, pool: *blog.BufferPool) bool {
        return switch (self.*) {
            .pretty, .json => true,
            .file => |file| file.sink.drain(pool),
        };
    }

    pub fn init(self: *Self, lt: *lifetime.Controller, cfg: config.Logging, ring: *lifetime.RingStuff) !void {
        switch (cfg.method) {
            .pretty => |pretty| {
                const branch = try lt.allocator.create(Sink.Pretty);
                branch.* = .{
                    .sink = undefined,
                    .writer = undefined,
                };

                branch.writer.init(2);
                const profile: blog.ColorProfile = switch (pretty) {
                    .dark => .dark,
                    .light => .light,
                    .flat => .plain,
                };
                branch.sink.init(lt.allocator, profile, &branch.writer);
                self.* = .{
                    .pretty = branch,
                };
            },
            .json => {
                const branch = try lt.allocator.create(Sink.Json);
                branch.* = .{
                    .sink = undefined,
                    .writer = undefined,
                };

                branch.writer.init(2);
                branch.sink.init(lt.allocator, &branch.writer);
                self.* = .{
                    .json = branch,
                };
            },
            .file => |file| {
                const f = try lt.createLogFile(file);
                const branch = try lt.allocator.create(Sink.File);
                branch.* = .{
                    .sink = .{
                        .fd = f,
                        .ring = &ring.ring,
                        .slots = &ring.slots,
                    },
                    .fd = f,
                };
                self.* = .{
                    .file = branch,
                };
            },
        }
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .pretty => |pretty| {
                pretty.sink.deinit();
                allocator.destroy(pretty);
            },
            .json => |json| {
                json.sink.deinit();
                allocator.destroy(json);
            },
            .file => |file| {
                _ = std.os.linux.close(file.fd);
                allocator.destroy(file);
            },
        }
    }
};

/// Sink for blog to write into io_uring backed output stream.
///
/// TODO support design described in designs/LOG_ROTATION.md
pub const IouringSink = struct {
    const Self = @This();

    /// How long `drain` keeps polling for write completions before giving up.
    const drain_timeout_ns: u64 = 5 * std.time.ns_per_s;

    fd: std.posix.fd_t,
    /// The ring owned by the thread that owns this sink. Only direct `push*`
    /// calls are used on it: a `StreamSQ` must never share this ring, because
    /// the two producer cursors would overwrite each other's SQEs.
    ring: *zigring.Ring,
    slots: *slots.RingSlots,
    /// Writes submitted but not completed yet. Only the owning thread touches
    /// this sink, so a plain counter is enough.
    pending: u32 = 0,

    pub fn write(self: *Self, pool: *blog.BufferPool, buf: []const u8) blog.WriteError!usize {
        const task_idx = self.slots.add(.{ .logging = .{
            .buf = @constCast(buf),
        } }) catch |err| {
            std.debug.print("failed to get slot for logging: {s}\n", .{@errorName(err)});
            _ = pool.put(@constCast(buf));
            return blog.WriteError.WriteFailed;
        };

        // `pushWrite` only fails with `RingFull`, before publishing the SQE, so
        // the record can be released here. Once it succeeds, the kernel reads
        // the buffer asynchronously and the slot owns it until completion.
        self.ring.pushWrite(self.fd, task_idx, buf.ptr, buf.len, .{}) catch {
            self.slots.del(task_idx);
            _ = pool.put(@constCast(buf));
            return blog.WriteError.WriteFailed;
        };

        self.pending += 1;
        return buf.len;
    }

    /// Releases the buffer and slot of a completed write. Returns false when
    /// `task_idx` belongs to another operation.
    pub fn complete(self: *Self, pool: *blog.BufferPool, task_idx: u64) bool {
        const ctx = self.slots.get(task_idx) orelse return false;
        switch (ctx) {
            .logging => |entry| {
                self.slots.del(task_idx);
                _ = pool.put(entry.buf);
                std.debug.assert(self.pending > 0);
                self.pending -= 1;
                return true;
            },
            else => return false,
        }
    }

    /// Drains completions until every submitted write is released. Returns
    /// false when `drain_timeout_ns` expires.
    pub fn drain(self: *Self, pool: *blog.BufferPool) bool {
        if (self.pending == 0) return true;

        const deadline = zigring.monotonicNs() + drain_timeout_ns;
        while (true) {
            while (self.ring.popCQE()) |cqe| {
                _ = self.complete(pool, cqe.taskIdx());
            }
            if (self.pending == 0) return true;
            if (zigring.monotonicNs() >= deadline) return false;

            const delay: linux.timespec = .{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
            _ = linux.nanosleep(&delay, null);
        }
    }
};

test "test logging" {
    var cfg: config.Config = .{};
    var lt: lifetime.Controller = undefined;
    try lt.init(std.testing.allocator, &cfg);
    defer lt.deinit();
    var logger = try lt.getInitLogger();
    defer std.testing.allocator.destroy(logger);
    defer logger.deinit(lt.allocator);

    logger.logger.warn("hello", .{ .reply = "world" });
}

test "file sink completes every write and releases its buffers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = blk: {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const len = try tmp.dir.realPath(std.testing.io, &buf);
        break :blk try std.testing.allocator.dupe(u8, buf[0..len]);
    };
    defer std.testing.allocator.free(dir_path);
    const base_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "log" });
    defer std.testing.allocator.free(base_path);

    var cfg: config.Config = .{};
    cfg.fronts = 0;
    cfg.indexes = 0;
    cfg.elephants = 0;
    cfg.logging = .{
        .method = .{ .file = base_path },
        .pool_capacity = 32,
        .pool_frame_size = 1024,
    };

    var lt: lifetime.Controller = undefined;
    try lt.init(std.testing.allocator, &cfg);
    defer lt.deinit();

    const logger = try lt.getInitLogger();
    defer std.testing.allocator.destroy(logger);
    defer logger.deinit(lt.allocator);

    for (0..8) |i| logger.logger.info("record {d}", .{i});

    // Drain polls the ring, so every write must complete and hand its pooled
    // buffer back. Before the fix nothing consumed these completions and the
    // sink released the buffer while the kernel was still reading it.
    try std.testing.expectEqual(@as(u32, 8), logger.sink.file.sink.pending);
    try std.testing.expect(logger.sink.drain(&logger.pool));
    try std.testing.expectEqual(@as(u32, 0), logger.sink.file.sink.pending);

    const stat = try tmp.dir.statFile(std.testing.io, "log.log", .{});
    try std.testing.expect(stat.size > 0);
}
