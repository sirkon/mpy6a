const std = @import("std");
pub fn bufferedPrint() !void {
    var bw = std.io.bufferedWriter(std.io.getStdOut().writer());
    const stdout = bw.writer();

    try stdout.print("Run `zig build test` to run the tests.\n", .{});

    try bw.flush();
}

/// B+ Tree API
pub const BPlusTree = @import("bplustree.zig").BPlusTree;

// Example usage:
// const std = @import("std");
// const bpt = @import("root").BPlusTree(i32, 4);
// var tree = bpt.init(std.heap.page_allocator);
// defer tree.deinit();
// try tree.insert(42, 42);
// const found = tree.search(42);
// std.debug.print("Found: {any}\n", .{found});
