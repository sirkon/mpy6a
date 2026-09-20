const std = @import("std");
const blog = @import("blog");
const zigring = @import("zigring");
const ringslots = @import("ringslots.zig");

/// Sink for blog to write into io_uring backed output stream.
///
/// TODO support design described in designs/LOG_ROTATION.md
const IouringSink = struct {
    const Self = @This();

    fd: std.posix.fd_t,
    batch: *zigring.BatchSQ,
    slots: *ringslots.RingSlots,

    pub fn write(self: *Self, bufpool: *blog.BufferPool, buf: []const u8) blog.WriteError!usize {
        errdefer bufpool.put(buf);

        const ctx: ringslots.RingTaskContext = .{
            .logging = .{
                .buf = buf,
            },
        };

        const task_idx = self.slots.add(ctx) catch |err| {
            std.debug.print("failed to get a logging slot: {}", .{err});
            return blog.WriteError;
        };

        self.batch.pushWrite(self.fd, task_idx, buf.ptr, buf.len, .{}) catch |err| {
            std.debug.print("failed to push logging write: {}", .{err});
            return blog.WriteError;
        };

        return buf.len;
    }
};
