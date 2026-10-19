//! Logging setup for the whole process.
//!
//! Standard error is the only destination for now. Every thread builds its own
//! `Scoped` logger: its own frame pool, its own `PrettySink` and therefore its
//! own render scratch space, plus a handle onto the one shared `FdWriter` that
//! owns the descriptor. Nothing is shared mutably and no lock is taken, so a
//! log call costs one pooled allocation and one `write(2)`.
//!
//! Records are deliberately not ordered between threads. `FdWriter` is
//! stateless and each record leaves as a single small `write(2)`; the kernel
//! serialises those per file description, and a minor reordering or a spliced
//! record under load is not worth a mutex. Swapping `Writer` for an
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
                return pretty.sink.write(bufpool, buf);
            },
            .json => |json| {
                @branchHint(.cold);
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

    pub fn write(self: *Self, _: *blog.BufferPool, buf: []const u8) blog.WriteError!usize {
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
