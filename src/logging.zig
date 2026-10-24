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
                        .stream = &ring.sqstream,
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

    fd: std.posix.fd_t,
    stream: *zigring.StreamSQ,
    slots: *slots.RingSlots,

    pub fn write(self: *Self, pool: *blog.BufferPool, buf: []const u8) blog.WriteError!usize {
        defer _ = pool.put(@constCast(buf));

        const task_idx = self.slots.add(.{ .logging = .{
            .buf = @constCast(buf),
        } }) catch |err| {
            std.debug.print("failed to get slot for logging: {}", .{err});
            return blog.WriteError.WriteFailed;
        };

        // CQ processor should get .logging task on the completion and release
        // the buffer stored in the context.
        _ = self.stream.pushWrite(self.fd, task_idx, buf.ptr, buf.len, .{});

        return buf.len;
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
