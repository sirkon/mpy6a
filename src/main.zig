const std = @import("std");
const blog = @import("blog");

pub fn main(_: std.process.Init) !void {
    var pool = try blog.BufferPool.init(std.heap.page_allocator, 64, 16 * 1024);
    defer pool.deinit();

    const Writer = blog.FdWriter;
    var writer = Writer.init(2);

    var sink = blog.PrettySink(Writer).init(std.heap.page_allocator, .light, &writer);
    defer sink.deinit();

    var logger = blog.Logger(blog.BufferPool, blog.PrettySink(Writer)).init(&pool, &sink);
    defer logger.deinit();

    logger.info("mpy6a shard starting", .{ .cores = 8 });
}
