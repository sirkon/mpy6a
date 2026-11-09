//! The persistence primitives a PMEM battery publishes through.
//!
//! designs/wal-impl.md §2 pins the rule: in PMEM mode every control line and
//! every touched data range is written back with `CLWB` and ordered with
//! `SFENCE` before the writer moves on, so the battery's unflushed tail
//! survives a power cut. Plain mode never reaches this module — a DRAM battery
//! becomes durable with its flush, not with a publish.
//!
//! The module-wide `enabled` constant is the plan's §E1 build seam: with it off
//! both publishes become no-ops, so a PMEM-shaped battery carved out of ordinary
//! memory runs the whole write-path suite.

const std = @import("std");
const builtin = @import("builtin");

/// Whether the publishes below really execute. It is a compile-time seam, not a
/// runtime switch: turning it off compiles the no-op arm instead, which is how
/// the logic tests run against a PMEM-shaped battery of ordinary memory.
pub const enabled: bool = builtin.cpu.arch.family() == .x86;

/// The writeback unit: `clwb` and `clflush` address one cache line at a time.
const line: usize = 64;

/// The writeback instruction this build carries, in the widest variant both the
/// CPU and the backend can take.
///
/// Zig's self-hosted x86 backend — the Debug default — encodes `clflush` only,
/// so a Debug build publishes through the baseline instruction; that is still a
/// writeback, it merely drops the line instead of keeping it resident. LLVM
/// builds use `clwb`, or `clflushopt` on a CPU reporting it.
const Op = enum { clwb, clflushopt, clflush };

const op: Op = blk: {
    if (builtin.zig_backend != .stage2_llvm) break :blk .clflush;
    if (builtin.cpu.has(.x86, .clwb)) break :blk .clwb;
    if (builtin.cpu.has(.x86, .clflushopt)) break :blk .clflushopt;
    break :blk .clflush;
};

/// Writes back every cache line the `len` bytes at `addr` touch, so the range
/// survives a power cut once the `sfence` after it completes.
///
/// A publish hands over a whole control line (one `BufferHeader`) or an
/// arbitrary span of a buffer, so the walk starts at the first line the range
/// touches and covers every line it reaches.
pub fn clwb(addr: *const anyopaque, len: usize) void {
    if (enabled) writeback(addr, len) else noop(addr, len);
}

/// Orders the writebacks published before it against everything published after
/// it. Nothing else in the module fences.
pub fn sfence() void {
    if (enabled) fence() else nofence();
}

fn writeback(addr: *const anyopaque, len: usize) void {
    if (len == 0) return;
    const end = @intFromPtr(addr) + len;
    var at = std.mem.alignBackward(usize, @intFromPtr(addr), line);
    while (at < end) : (at += line) writebackLine(at);
}

fn writebackLine(at: usize) void {
    const addr: [*]const u8 = @ptrFromInt(at);
    switch (op) {
        .clwb => asm volatile ("clwb %[addr]"
            :
            : [addr] "m" (addr[0]),
            : .{ .memory = true }),
        .clflushopt => asm volatile ("clflushopt %[addr]"
            :
            : [addr] "m" (addr[0]),
            : .{ .memory = true }),
        .clflush => asm volatile ("clflush %[addr]"
            :
            : [addr] "m" (addr[0]),
            : .{ .memory = true }),
    }
}

fn fence() void {
    asm volatile ("sfence"
        :
        :
        : .{ .memory = true });
}

/// The no-op arm of the seam: a battery of ordinary memory needs no writeback.
fn noop(addr: *const anyopaque, len: usize) void {
    _ = addr;
    _ = len;
}

fn nofence() void {}

test "both arms of the seam compile" {
    var buf: [line]u8 align(line) = @splat(0);

    // The no-op arm is always available: it is what a disabled flag builds.
    noop(&buf, buf.len);
    nofence();

    // The real arm only exists on x86, where it also runs: the target's own CPU
    // report picks the instruction, so the call cannot fault.
    if (enabled) {
        writeback(&buf, buf.len);
        writeback(&buf, buf.len - 1);
        fence();
        clwb(&buf, buf.len);
        sfence();
    }
}

test "the writeback covers every line the range touches" {
    // Two lines plus one byte: the walk starts at the first line the range
    // touches and ends at the line holding its last byte, so a misaligned span
    // never leaves a written byte behind.
    var buf: [2 * line]u8 align(line) = @splat(0);
    const zeroed: [2 * line]u8 = @splat(0);

    clwb(&buf, buf.len);
    clwb(&buf, 0);
    clwb(buf[line - 1 ..].ptr, 2);
    sfence();

    try std.testing.expectEqualSlices(u8, &zeroed, &buf);
}
