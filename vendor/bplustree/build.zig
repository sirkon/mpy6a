const std = @import("std");

/// Vendored copy of zig-bplus-tree 0.0.0 (commit e9ac649).
///
/// Only the `bplustree` module is exported. Upstream's build script targets
/// Zig 0.16 and builds examples plus a `tests/` directory that is not part of
/// the published package, so it is kept out of the vendored tree.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("bplustree", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
}
