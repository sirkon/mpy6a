//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

/// Binary logger: record framing, buffer pool and the pretty/JSON viewers.
pub const blog = @import("blog");
/// io_uring ring factory, thread primitives and socket helpers.
pub const ring = @import("zigring");
/// Open-addressing hash map used for the session state tables.
pub const table = @import("verztable");

/// Session state table keyed by `host_id:epoch_id:index`, the layout described
/// in docs/shard-arch-hld.md.
pub fn SessionTable(comptime V: type) type {
    return table.HashMap(u64, V);
}

/// Inbound Queue & Notification/Sleep Protocol (Front producers -> Index
/// consumer): the `IndexInbox` SPSC ring with its `push` / `pop` methods, the
/// monolithic `batch` window over the ring CQ and the inbound queue (with its
/// `BatchInbox` view), the conditional `MSG_RING` wake path and the `hang`
/// spin-then-park sequence of TASK-INDEX-INBOUND.md.
pub const index_inbound = @import("index_inbox.zig");

/// This is a documentation comment to explain the `printAnotherMessage` function below.
///
/// Accepting an `Io.Writer` instance is a handy way to write reusable code.
pub fn printAnotherMessage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("Run `zig build test` to run the tests.\n", .{});
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}

test "dependencies are reachable" {
    const allocator = std.testing.allocator;

    var pool = try blog.BufferPool.init(allocator, 64, 16 * 1024);
    defer pool.deinit();

    var sink = blog.MemorySink.init(allocator);
    defer sink.deinit();

    var logger = blog.Logger(blog.BufferPool, blog.MemorySink).init(&pool, &sink);
    defer logger.deinit();
    logger.info("shard ready", .{ .cores = 8 });
    try std.testing.expect(sink.bytes.items.len > 0);

    try std.testing.expect(ring.pageSize > 0);

    var sessions = SessionTable(u32).init(allocator);
    defer sessions.deinit();
    try sessions.put(0x0100_0000_0000_0001, 7);
    try std.testing.expectEqual(@as(?u32, 7), sessions.get(0x0100_0000_0000_0001));
}
