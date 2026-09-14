const std = @import("std");
const Io = std.Io;

const blog = @import("blog/buffer.zig");

pub fn main(init: std.process.Init) !void {
    // This is appropriate for anything that lives as long as the process.
    const arena: std.mem.Allocator = init.arena.allocator();
    var buf = try arena.alloc(u8, 2);
    buf[0] = 0;

    _ = blog.append(buf.ptr, @as(u16, 511));
    std.debug.print("{any}", .{buf});
}
