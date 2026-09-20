const std = @import("std");

/// Vendored copy of verztable 0.1.0.
///
/// Only the `verztable` module is exported: upstream's benchmark executable
/// drags in a C++ toolchain, abseil and boost checkouts, and its
/// `bench_exe.linkLibC()` call no longer compiles against Zig 0.16.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("verztable", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
}
