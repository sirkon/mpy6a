//! Timing wheel: a hierarchical O(1) bucket wheel for expiry-ordered payloads.
//!
//! See designs/TIMING_WHEEL.md and TASK-TIMING-WHEEL.md for the normative
//! specification. This module is strictly single-threaded (G1), uses bitwise
//! masking for all ring arithmetic (G3), and keeps every persistent index or
//! counter in `i32`/`u32` (G4).
//!
//! `TimingWheel` is a comptime factory, not a concrete type. Call it with the
//! three shape parameters and it returns a wheel type specialized to them:
//!
//! ```zig
//! const W = TimingWheel(16, 4, 8);
//! const w = try W.init(allocator);
//! ```
//!
//! `M` (slot count), `N` (block capacity) and `L` (inline pool capacity) must
//! each be a power of two and satisfy `1 <= M <= 2^20`, `1 <= N <= 2^20`,
//! `1 <= L <= 2^30`; violations are `@compileError`s raised while instantiating
//! the type. Each returned type re-exports its parameters as `W.M`, `W.N` and
//! `W.L`.

const std = @import("std");

/// NIL sentinel for packed positions and free-chain links.
const NIL: i32 = -1;
/// Bit offset of the stripe field inside a u64 handle.
const STRIPE_SHIFT: u6 = 32;

/// Handle fields as decoded from the u64 returned by `add_value`.
pub const Handle = struct { stripe: u32, block: u32, slot: u32 };

/// Position fields as decoded from a packed i32 list link.
pub const Pos = struct { block: u32, slot: u32 };

/// Decoded set of payloads returned by `shift`.
pub const ShiftResult = struct { backing: []u64, size: usize };

/// Build a timing wheel type with `ticks` slots, blocks of `blockSize` payload
/// slots, and an inline pool of `readyBlocks` blocks. All three are comptime
/// parameters; the returned type owns no global state, so several differently
/// shaped wheels can coexist in one binary.
pub fn TimingWheel(comptime ticks: comptime_int, comptime blockSize: comptime_int, comptime readyBlocks: comptime_int) type {
    comptime {
        if (!std.math.isPowerOfTwo(ticks)) @compileError("ticks must be a power of two");
        if (!std.math.isPowerOfTwo(blockSize)) @compileError("blockSize must be a power of two");
        if (!std.math.isPowerOfTwo(readyBlocks)) @compileError("readyBlocks must be a power of two");
        if (ticks < 1 or ticks > 0x10_0000) @compileError("ticks must satisfy 1 <= M <= 2^20");
        if (blockSize < 1 or blockSize > 0x10_0000) @compileError("blockSize must satisfy 1 <= N <= 2^20");
        if (readyBlocks < 1 or readyBlocks > 0x4000_0000) @compileError("readyBlocks must fit the i32 free index");
    }

    return struct {
        const Self = @This();

        /// Wheel slot count, fixed at instantiation.
        pub const M = ticks;
        /// Payload slots per block, fixed at instantiation.
        pub const N = blockSize;
        /// Blocks held inline by the pool, fixed at instantiation.
        pub const L = readyBlocks;

        /// Bit width of the slot field: exactly enough for `N` distinct indices.
        const SLOT_BITS: u6 = std.math.log2_int(u32, Self.N);
        /// Bit offset of the block field in packed positions: it sits directly
        /// above the slot field, so packing follows `N` rather than the fixed
        /// width of the u64 handle.
        const BLOCK_SHIFT: u6 = SLOT_BITS;
        /// Bit width reserved for the block index. Bit 31 stays clear to keep
        /// packed positions non-negative and `NIL` unambiguous.
        const BLOCK_BITS: u5 = 31 - SLOT_BITS;
        /// Largest block index a stripe can hold.
        const MAX_BLOCKS: u32 = @as(u32, 1) << BLOCK_BITS;
        const SLOT_MASK: u32 = (@as(u32, 1) << SLOT_BITS) - 1;

        /// Bit layout of the u64 handle returned by `add_value`:
        /// bits 63..32 stripe (`cursor & (M - 1)` at insertion), bits
        /// `SLOT_BITS + BLOCK_BITS - 1 .. SLOT_BITS` block index inside the
        /// stripe, bits `SLOT_BITS - 1 .. 0` slot index inside that block.
        inline fn encode(stripe: u32, block: u32, slot: u32) u64 {
            return (@as(u64, stripe) << STRIPE_SHIFT) |
                (@as(u64, block) << BLOCK_SHIFT) |
                @as(u64, slot);
        }

        inline fn decode(h: u64) Handle {
            return .{
                .stripe = @truncate(h >> STRIPE_SHIFT),
                .block = @as(u32, @truncate(h >> BLOCK_SHIFT)) & (MAX_BLOCKS - 1),
                .slot = @as(u32, @truncate(h)) & SLOT_MASK,
            };
        }

        /// Pack a (block, slot) pair into an i32 list link. Bit 31 stays clear
        /// so the NIL sentinel never collides with a real position.
        inline fn pack(block: u32, slot: u32) i32 {
            return @bitCast((block << BLOCK_SHIFT) | slot);
        }

        inline fn unpack(p: i32) Pos {
            const u: u32 = @bitCast(p);
            return .{ .block = (u >> BLOCK_SHIFT) & (MAX_BLOCKS - 1), .slot = u & SLOT_MASK };
        }

        const Block = struct {
            ids: [Self.N]u64,
            prevs: [Self.N]i32,
            nexts: [Self.N]i32,
            len: i32,
            occupied: i32,
            index: i32,
        };

        const Stripe = struct {
            blocks: []?*Block,
            len: u32,
            last: i32,
        };

        const BlocksPool = struct {
            blocks: [Self.L]Block,
            nexts: [Self.L]i32,
            free: i32,
            allocator: std.mem.Allocator,

            /// Pop a block from the free chain, falling back to the heap when
            /// the static pool is depleted (`free < 0`). Returned blocks always
            /// have `len == 0` and `occupied == 0`.
            fn take_block(pool: *BlocksPool) error{OutOfMemory}!*Block {
                if (pool.free < 0) {
                    const b = try pool.allocator.create(Block);
                    b.* = .{
                        .ids = undefined,
                        .prevs = undefined,
                        .nexts = undefined,
                        .len = 0,
                        .occupied = 0,
                        .index = -1,
                    };
                    return b;
                }
                const idx = pool.free;
                pool.free = pool.nexts[@intCast(idx)];
                pool.nexts[@intCast(idx)] = NIL;
                const b = &pool.blocks[@intCast(idx)];
                b.len = 0;
                b.occupied = 0;
                return b;
            }

            /// Return an outstanding block to the pool. Heap blocks
            /// (`index < 0`) are destroyed instead of linked, since `-1` is not
            /// a valid chain slot.
            fn return_block(pool: *BlocksPool, b: *Block) void {
                if (b.index < 0) {
                    pool.allocator.destroy(b);
                    return;
                }
                pool.nexts[@intCast(b.index)] = pool.free;
                pool.free = b.index;
            }
        };

        slots: [Self.M]*Stripe,
        cursor: u32,
        pool: BlocksPool,
        allocator: std.mem.Allocator,

        /// Heap-allocate and initialize a wheel. The returned object owns inline
        /// pool storage and must never be moved or copied: stripes hold raw
        /// pointers into it.
        pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!*Self {
            const w = try allocator.create(Self);
            errdefer allocator.destroy(w);
            w.allocator = allocator;
            w.cursor = 0;
            w.pool.allocator = allocator;
            w.pool.free = 0;

            var i: usize = 0;
            while (i < Self.L) : (i += 1) {
                w.pool.blocks[i] = .{
                    .ids = undefined,
                    .prevs = undefined,
                    .nexts = undefined,
                    .len = 0,
                    .occupied = 0,
                    .index = @intCast(i),
                };
                w.pool.nexts[i] = if (i + 1 < Self.L) @intCast(i + 1) else NIL;
            }

            var created: usize = 0;
            errdefer for (0..created) |j| allocator.destroy(w.slots[j]);
            while (created < Self.M) : (created += 1) {
                const s = try allocator.create(Stripe);
                s.* = .{ .blocks = &.{}, .len = 0, .last = NIL };
                w.slots[created] = s;
            }
            return w;
        }

        /// Release every owned allocation: outstanding heap blocks, stripe
        /// capacity slices, stripe objects, then the wheel itself (inline pool
        /// storage is freed with it).
        pub fn deinit(self: *Self) void {
            const allocator = self.allocator;
            for (0..Self.M) |i| {
                const s = self.slots[i];
                for (0..s.len) |bi| {
                    if (s.blocks[bi]) |b| {
                        if (b.index < 0) allocator.destroy(b);
                    }
                }
                allocator.free(s.blocks);
                allocator.destroy(s);
            }
            allocator.destroy(self);
        }

        /// Insert `value` into the current stripe and return its position handle.
        /// Fallible operations precede all state commits, so a failed call leaves
        /// the wheel unchanged and is safe to retry.
        pub fn add_value(self: *Self, value: u64) error{OutOfMemory}!u64 {
            const s = self.slots[self.cursor & (Self.M - 1)];

            if (s.len == 0) {
                if (s.blocks.len == 0) {
                    s.blocks = try self.allocator.alloc(?*Block, 1);
                }
                s.blocks[0] = try self.pool.take_block();
                s.len = 1;
            } else {
                const frontier = s.blocks[s.len - 1];
                if (frontier) |b| {
                    if (b.len >= Self.N) {
                        if (s.len == MAX_BLOCKS) {
                            @panic("timing wheel: stripe block index overflow");
                        }
                        if (s.len == s.blocks.len) {
                            s.blocks = try self.allocator.realloc(s.blocks, @as(usize, s.len) + 1);
                        }
                        s.blocks[@as(usize, s.len)] = try self.pool.take_block();
                        s.len += 1;
                    }
                } else {
                    s.blocks[s.len - 1] = try self.pool.take_block();
                }
            }

            const bi: u32 = s.len - 1;
            const b = s.blocks[bi].?;
            const si: u32 = @intCast(b.len);
            b.ids[si] = value;
            const p = pack(bi, si);
            b.prevs[si] = s.last;
            b.nexts[si] = NIL;
            if (s.last != NIL) {
                const q = unpack(s.last);
                s.blocks[q.block].?.nexts[q.slot] = p;
            }
            s.last = p;
            b.len += 1;
            b.occupied += 1;
            return encode(self.cursor & (Self.M - 1), bi, si);
        }

        /// Unlink and remove a live element. Infallible; the block is reclaimed
        /// to the pool once its last element leaves.
        pub fn delete_by_index(self: *Self, handle: u64) void {
            const d = decode(handle);
            const s = self.slots[d.stripe];
            if (std.debug.runtime_safety) {
                std.debug.assert(d.block < s.len);
                std.debug.assert(s.blocks[d.block] != null);
                std.debug.assert(d.slot < @as(u32, @intCast(s.blocks[d.block].?.len)));
            }
            const b = s.blocks[d.block].?;
            const p = pack(d.block, d.slot);
            const prev = b.prevs[d.slot];
            const next = b.nexts[d.slot];
            if (prev != NIL) {
                const q = unpack(prev);
                s.blocks[q.block].?.nexts[q.slot] = next;
            }
            if (next != NIL) {
                const q = unpack(next);
                s.blocks[q.block].?.prevs[q.slot] = prev;
            }
            if (s.last == p) s.last = prev;
            b.prevs[d.slot] = NIL;
            b.nexts[d.slot] = NIL;
            b.occupied -= 1;
            if (b.occupied > 0) return;
            s.blocks[d.block] = null;
            self.pool.return_block(b);
        }

        /// Advance the wheel one tick: drain the matured stripe and deliver its
        /// live payloads. The returned values are an unordered set (newest-first);
        /// callers that need an order sort the slice themselves. `placeholder`
        /// (typically the previous result's `backing`) is grown by `N` per block
        /// as needed. On success ownership returns via `ShiftResult.backing`; on
        /// error the wheel is unchanged but the placeholder is invalid and must
        /// be discarded.
        pub fn shift(self: *Self, placeholder: []u64) error{OutOfMemory}!ShiftResult {
            const target: u32 = (self.cursor +% 1) & (Self.M - 1);
            const s = self.slots[target];
            var backing = placeholder;
            var out: usize = 0;

            var p = s.last;
            while (p != NIL) {
                const q = unpack(p);
                const b = s.blocks[q.block].?;
                if (out == backing.len) {
                    if (backing.len == 0) {
                        backing = try self.allocator.alloc(u64, Self.N);
                    } else {
                        backing = try self.allocator.realloc(backing, backing.len + Self.N);
                    }
                }
                backing[out] = b.ids[q.slot];
                out += 1;
                p = b.prevs[q.slot];
            }

            self.cursor +%= 1;

            var bi: u32 = 1;
            while (bi < s.len) : (bi += 1) {
                if (s.blocks[bi]) |b| {
                    self.pool.return_block(b);
                    s.blocks[bi] = null;
                }
            }

            if (s.len > 0 and s.blocks[0] != null) {
                const b0 = s.blocks[0].?;
                b0.len = 0;
                b0.occupied = 0;
                s.len = 1;
            } else {
                s.len = 0;
            }
            s.last = NIL;
            return .{ .backing = backing, .size = out };
        }
    };
}

/// Test instantiations. `Small` is the original 16x4x8 wheel; `Tiny` proves the
/// factory really specializes on its parameters instead of ignoring them.
/// `Wide` exercises a block capacity beyond 2^16, which the slot field must
/// track rather than assume a fixed 16-bit width.
const Small = TimingWheel(16, 4, 8);
const Tiny = TimingWheel(4, 2, 4);
const Big = TimingWheel(1024, 64, 16);
const Wide = TimingWheel(4, 1 << 17, 1);

/// Assert every invariant of Section 2. Test-only helper.
fn checkInvariants(comptime W: type, w: *W) void {
    const pool = &w.pool;

    // P1, P3
    if (pool.free != NIL) {
        std.debug.assert(pool.free >= 0 and pool.free < W.L);
    }
    for (0..W.L) |i| {
        const nx = pool.nexts[i];
        if (nx != NIL) std.debug.assert(nx >= 0 and nx < W.L);
    }

    // P2: chain integrity, reset state, distinct indices.
    {
        var seen = [_]bool{false} ** W.L;
        var chain_len: usize = 0;
        var idx = pool.free;
        while (idx != NIL) {
            std.debug.assert(idx >= 0 and idx < W.L);
            const ui: usize = @intCast(idx);
            std.debug.assert(!seen[ui]);
            seen[ui] = true;
            chain_len += 1;
            std.debug.assert(pool.blocks[ui].index == @as(i32, @intCast(ui)));
            idx = pool.nexts[ui];
        }
        std.debug.assert(chain_len <= W.L);
    }

    for (0..W.M) |si| {
        const s = w.slots[si];

        // S1
        std.debug.assert(s.blocks.len >= s.len);
        std.debug.assert(s.len <= W.MAX_BLOCKS);

        // S2, P4, P5
        for (0..s.len) |bi| {
            if (s.blocks[bi]) |b| {
                if (b.index >= 0) {
                    const uidx: usize = @intCast(b.index);
                    std.debug.assert(uidx < W.L);
                    std.debug.assert(&pool.blocks[uidx] == b);
                } else {
                    std.debug.assert(b.index == -1);
                }
            }
        }

        // S6: sealed non-frontier blocks are full.
        if (s.len > 0) {
            for (0..s.len - 1) |bi| {
                if (s.blocks[bi]) |b| std.debug.assert(b.len == W.N);
            }
        }

        // S6, S7: counters and their sum.
        var occ: usize = 0;
        for (0..s.len) |bi| {
            if (s.blocks[bi]) |b| {
                std.debug.assert(b.occupied >= 0);
                std.debug.assert(b.len >= 0);
                std.debug.assert(b.occupied <= b.len);
                std.debug.assert(b.len <= W.N);
                occ += @intCast(b.occupied);
            }
        }
        std.debug.assert(occ <= s.len * W.N);

        // S4, S8: reverse `prevs` walk from the tail; verify link symmetry,
        // strict lexicographic descent (so forward `nexts` order is strictly
        // increasing), and cycle freedom.
        var live: usize = 0;
        var expected_next: i32 = NIL;
        var min_p: i64 = std.math.maxInt(i64);
        var p = s.last;
        while (p != NIL) {
            const q = W.unpack(p);
            std.debug.assert(q.block < s.len);
            const b = s.blocks[q.block] orelse std.debug.panic("timing wheel: dead list link", .{});
            std.debug.assert(q.slot < @as(u32, @intCast(b.len)));
            std.debug.assert(b.nexts[q.slot] == expected_next);
            const up: i64 = @intCast(@as(u32, @bitCast(p)));
            std.debug.assert(up < min_p);
            min_p = up;
            expected_next = p;
            live += 1;
            std.debug.assert(live <= s.len * W.N);
            p = b.prevs[q.slot];
        }
        std.debug.assert(live == occ);

        // Forward walk from the head (smallest position) checking `prevs`.
        if (live > 0) {
            var q = W.unpack(@bitCast(@as(u32, @intCast(min_p))));
            var expected_prev: i32 = NIL;
            var walk: usize = 0;
            while (true) {
                const b = s.blocks[q.block].?;
                std.debug.assert(b.prevs[q.slot] == expected_prev);
                walk += 1;
                const nxp = b.nexts[q.slot];
                if (nxp == NIL) break;
                expected_prev = W.pack(q.block, q.slot);
                q = W.unpack(nxp);
            }
            std.debug.assert(walk == live);
        }

        // S5: empty list iff NIL tail; retained empty block is legal.
        if (s.last == NIL) std.debug.assert(live == 0);
        if (live == 0 and s.len == 1) {
            if (s.blocks[0]) |b0| std.debug.assert(b0.len == 0 and b0.occupied == 0);
        }
    }
}

fn freeBacking(a: std.mem.Allocator, b: []u64) void {
    if (b.len > 0) a.free(b);
}

/// Parameterized shared test bodies: one instantiation per wheel shape below.
fn testWheelShape(comptime W: type) !void {
    const a = std.testing.allocator;

    {
        const w = try W.init(a);
        defer w.deinit();
        checkInvariants(W, w);
        const r = try w.shift(&.{});
        try std.testing.expectEqual(@as(usize, 0), r.size);
        try std.testing.expectEqual(@as(usize, 0), r.backing.len);
        try std.testing.expectEqual(@as(u32, 1), w.cursor);
        checkInvariants(W, w);
    }

    {
        const w = try W.init(a);
        defer w.deinit();
        for (0..W.L * W.N + 1) |i| _ = try w.add_value(@intCast(i));
        checkInvariants(W, w);
        try std.testing.expectEqual(@as(u32, W.L + 1), w.slots[0].len);
        try std.testing.expectEqual(NIL, w.pool.free);
        try std.testing.expectEqual(@as(i32, -1), w.slots[0].blocks[W.L].?.index);

        var backing: []u64 = &.{};
        defer freeBacking(a, backing);
        var i: usize = 0;
        while (i < W.M - 1) : (i += 1) backing = (try w.shift(backing)).backing;
        const r = try w.shift(backing);
        backing = r.backing;
        try std.testing.expectEqual(@as(usize, W.L * W.N + 1), r.size);
        try std.testing.expectEqual(@as(u32, W.M), w.cursor);
        checkInvariants(W, w);
    }

    {
        const w = try W.init(a);
        defer w.deinit();
        var handles: [W.N + 1]u64 = undefined;
        for (0..W.N + 1) |i| handles[i] = try w.add_value(@intCast(i));
        checkInvariants(W, w);
        try std.testing.expectEqual(@as(u32, 2), w.slots[0].len);
        w.delete_by_index(handles[W.N]);
        checkInvariants(W, w);
        try std.testing.expect(w.slots[0].blocks[1] == null);
        _ = try w.add_value(999);
        checkInvariants(W, w);
        try std.testing.expectEqual(@as(i32, 1), w.slots[0].blocks[1].?.len);
    }
}

test "16x4x8 wheel: empty shift, pool depletion, reclaimed frontier" {
    try testWheelShape(Small);
}

test "4x2x4 wheel: empty shift, pool depletion, reclaimed frontier" {
    try testWheelShape(Tiny);
}

test "1024x64x16 wheel: empty shift, pool depletion, reclaimed frontier" {
    try testWheelShape(Big);
}

test "factory re-exports its shape parameters" {
    try std.testing.expectEqual(16, Small.M);
    try std.testing.expectEqual(4, Small.N);
    try std.testing.expectEqual(8, Small.L);
    try std.testing.expectEqual(4, Tiny.M);
    try std.testing.expectEqual(2, Tiny.N);
    try std.testing.expectEqual(4, Tiny.L);
    try std.testing.expectEqual(1024, Big.M);
    try std.testing.expectEqual(64, Big.N);
    try std.testing.expectEqual(16, Big.L);
}

test "block sizes follow N and pool sizes follow L" {
    try std.testing.expectEqual(16 * Small.N + 16, @sizeOf(@TypeOf(@as(Small, undefined).pool.blocks[0])));
    try std.testing.expectEqual(16 * Tiny.N + 16, @sizeOf(@TypeOf(@as(Tiny, undefined).pool.blocks[0])));
    try std.testing.expectEqual(16 * Big.N + 16, @sizeOf(@TypeOf(@as(Big, undefined).pool.blocks[0])));
    try std.testing.expectEqual(8 * Small.M, @sizeOf(@TypeOf(@as(Small, undefined).slots)));
    try std.testing.expectEqual(8 * Tiny.M, @sizeOf(@TypeOf(@as(Tiny, undefined).slots)));
    try std.testing.expectEqual(8 * Big.M, @sizeOf(@TypeOf(@as(Big, undefined).slots)));
}

test "packing tracks N instead of a fixed 16-bit slot field" {
    try std.testing.expectEqual(@as(u6, 2), Small.SLOT_BITS);
    try std.testing.expectEqual(@as(u6, 17), Wide.SLOT_BITS);

    inline for (.{ Small, Tiny, Big, Wide }) |W| {
        const slot: u32 = W.N - 1;
        try std.testing.expectEqual(slot, W.unpack(W.pack(0, slot)).slot);
        try std.testing.expectEqual(slot, W.unpack(W.pack(W.MAX_BLOCKS - 1, slot)).slot);
        try std.testing.expectEqual(W.MAX_BLOCKS - 1, W.unpack(W.pack(W.MAX_BLOCKS - 1, slot)).block);
        try std.testing.expect(W.pack(W.MAX_BLOCKS - 1, slot) >= 0);
        try std.testing.expectEqual(@as(u32, W.N - 1), W.decode(W.encode(7, 0, slot)).slot);
    }

    // A slot index past 2^16 must survive a Wide round trip.
    try std.testing.expectEqual(@as(u32, 0x1_FFFF), Wide.unpack(Wide.pack(3, 0x1_FFFF)).slot);
}

test "wide block capacity round-trips through add and shift" {
    const a = std.testing.allocator;
    const w = try Wide.init(a);
    defer w.deinit();

    for (0..Wide.N + 1) |i| _ = try w.add_value(@intCast(i));
    checkInvariants(Wide, w);
    try std.testing.expectEqual(@as(u32, 2), w.slots[0].len);
    try std.testing.expectEqual(@as(i32, Wide.N), w.slots[0].blocks[0].?.len);

    var backing: []u64 = &.{};
    defer freeBacking(a, backing);
    var i: usize = 0;
    while (i < Wide.M - 1) : (i += 1) backing = (try w.shift(backing)).backing;
    const r = try w.shift(backing);
    backing = r.backing;
    try std.testing.expectEqual(@as(usize, Wide.N + 1), r.size);
    checkInvariants(Wide, w);
}

test "shift on an untouched wheel is quiet" {
    const a = std.testing.allocator;
    const w = try Small.init(a);
    defer w.deinit();

    checkInvariants(Small, w);
    const r = try w.shift(&.{});
    try std.testing.expectEqual(@as(usize, 0), r.size);
    try std.testing.expectEqual(@as(usize, 0), r.backing.len);
    try std.testing.expectEqual(@as(u32, 1), w.cursor);
    checkInvariants(Small, w);
}

test "round trip, delete, and M-shift lifetime" {
    const a = std.testing.allocator;
    const w = try Small.init(a);
    defer w.deinit();

    const h0 = try w.add_value(100);
    const h1 = try w.add_value(200);
    try std.testing.expectEqual(@as(u32, 0), Small.decode(h0).stripe);
    try std.testing.expectEqual(@as(u32, 0), Small.decode(h1).stripe);
    checkInvariants(Small, w);

    w.delete_by_index(h0);
    checkInvariants(Small, w);

    var backing: []u64 = &.{};
    defer freeBacking(a, backing);

    var i: usize = 0;
    while (i < Small.M - 1) : (i += 1) {
        const r = try w.shift(backing);
        backing = r.backing;
        try std.testing.expectEqual(@as(usize, 0), r.size);
    }

    const r = try w.shift(backing);
    backing = r.backing;
    try std.testing.expectEqual(@as(usize, 1), r.size);
    try std.testing.expectEqual(@as(u64, 200), r.backing[0]);
    try std.testing.expectEqual(@as(u32, Small.M), w.cursor);
    checkInvariants(Small, w);
}

test "block rollover grows the stripe slice" {
    const a = std.testing.allocator;
    const w = try Small.init(a);
    defer w.deinit();

    for (0..Small.N + 1) |i| {
        _ = try w.add_value(@intCast(i));
        checkInvariants(Small, w);
    }
    try std.testing.expectEqual(@as(u32, 2), w.slots[0].len);
    try std.testing.expectEqual(@as(usize, 2), w.slots[0].blocks.len);
    try std.testing.expectEqual(@as(i32, Small.N), w.slots[0].blocks[0].?.len);
    try std.testing.expectEqual(@as(i32, 1), w.slots[0].blocks[1].?.len);
}

test "pool depletion falls back to the heap" {
    const a = std.testing.allocator;
    const w = try Small.init(a);
    defer w.deinit();

    for (0..Small.L * Small.N + 1) |i| {
        _ = try w.add_value(@intCast(i));
        checkInvariants(Small, w);
    }
    try std.testing.expectEqual(@as(u32, Small.L + 1), w.slots[0].len);
    try std.testing.expectEqual(NIL, w.pool.free);
    try std.testing.expectEqual(@as(i32, -1), w.slots[0].blocks[Small.L].?.index);
    checkInvariants(Small, w);
}

test "reclaimed frontier block is reused" {
    const a = std.testing.allocator;
    const w = try Small.init(a);
    defer w.deinit();

    var handles: [Small.N + 1]u64 = undefined;
    for (0..Small.N + 1) |i| handles[i] = try w.add_value(@intCast(i));
    checkInvariants(Small, w);
    try std.testing.expectEqual(@as(u32, 2), w.slots[0].len);

    w.delete_by_index(handles[Small.N]);
    checkInvariants(Small, w);
    try std.testing.expect(w.slots[0].blocks[1] == null);
    try std.testing.expectEqual(@as(u32, 2), w.slots[0].len);

    _ = try w.add_value(999);
    checkInvariants(Small, w);
    try std.testing.expect(w.slots[0].blocks[1] != null);
    try std.testing.expectEqual(@as(i32, 1), w.slots[0].blocks[1].?.len);
}

test "delete head, middle, and tail" {
    const a = std.testing.allocator;
    const w = try Small.init(a);
    defer w.deinit();

    const h0 = try w.add_value(1);
    const h1 = try w.add_value(2);
    const h2 = try w.add_value(3);
    checkInvariants(Small, w);

    w.delete_by_index(h1);
    checkInvariants(Small, w);
    w.delete_by_index(h0);
    checkInvariants(Small, w);
    w.delete_by_index(h2);
    checkInvariants(Small, w);

    try std.testing.expectEqual(NIL, w.slots[0].last);
    try std.testing.expect(w.slots[0].blocks[0] == null);
    try std.testing.expectEqual(@as(u32, 1), w.slots[0].len);
}

test "shift retains the first block and preserves buffer capacity" {
    const a = std.testing.allocator;
    const w = try Small.init(a);
    defer w.deinit();

    _ = try w.add_value(11);
    _ = try w.add_value(22);
    checkInvariants(Small, w);

    var backing: []u64 = &.{};
    defer freeBacking(a, backing);

    var i: usize = 0;
    while (i < Small.M) : (i += 1) {
        const r = try w.shift(backing);
        backing = r.backing;
    }
    try std.testing.expectEqual(@as(u32, Small.M), w.cursor);
    checkInvariants(Small, w);

    const s = w.slots[0];
    try std.testing.expectEqual(@as(u32, 1), s.len);
    try std.testing.expect(s.blocks[0] != null);
    try std.testing.expectEqual(@as(i32, 0), s.blocks[0].?.len);
    try std.testing.expectEqual(@as(i32, 0), s.blocks[0].?.occupied);
    try std.testing.expectEqual(NIL, s.last);
}

test "shift grows the buffer and returns the drained set" {
    const a = std.testing.allocator;
    const w = try Small.init(a);
    defer w.deinit();

    for (0..Small.N + 1) |i| _ = try w.add_value(1000 + @as(u64, i));

    var backing: []u64 = &.{};
    defer freeBacking(a, backing);

    var i: usize = 0;
    while (i < Small.M - 1) : (i += 1) backing = (try w.shift(backing)).backing;
    const r = try w.shift(backing);
    backing = r.backing;

    try std.testing.expectEqual(@as(usize, Small.N + 1), r.size);
    var seen = [_]bool{false} ** (Small.N + 1);
    for (r.backing[0..r.size]) |v| {
        try std.testing.expect(v >= 1000 and v < 1000 + Small.N + 1);
        seen[@intCast(v - 1000)] = true;
    }
    for (seen) |s| try std.testing.expect(s);
    checkInvariants(Small, w);
}

test "fuzz add/delete/shift against a shadow model" {
    const a = std.testing.allocator;
    const w = try Small.init(a);
    defer w.deinit();

    var prng = std.Random.DefaultPrng.init(0x1234_5678_9ABC_DEF0);
    const rnd = prng.random();

    const Entry = struct { handle: u64, value: u64, stripe: u32 };
    var shadow: std.ArrayList(Entry) = .empty;
    defer shadow.deinit(a);
    var backing: []u64 = &.{};
    defer freeBacking(a, backing);

    var op: usize = 0;
    while (op < 5000) : (op += 1) {
        const choice = rnd.uintLessThan(u32, 10);
        if (shadow.items.len == 0 or choice < 4) {
            const value = rnd.int(u64);
            const h = try w.add_value(value);
            const stripe: u32 = w.cursor & (Small.M - 1);
            try std.testing.expectEqual(@as(u32, @truncate(h >> STRIPE_SHIFT)), stripe);
            try shadow.append(a, .{ .handle = h, .value = value, .stripe = stripe });
        } else if (choice < 7) {
            const idx = rnd.uintLessThan(usize, shadow.items.len);
            w.delete_by_index(shadow.items[idx].handle);
            _ = shadow.orderedRemove(idx);
        } else {
            const target: u32 = (w.cursor +% 1) & (Small.M - 1);
            const r = try w.shift(backing);
            backing = r.backing;

            var expected: std.ArrayList(u64) = .empty;
            defer expected.deinit(a);
            for (shadow.items) |e| {
                if (e.stripe == target) try expected.append(a, e.value);
            }
            try std.testing.expectEqual(expected.items.len, r.size);

            // Order is unspecified: match each returned value against the
            // expected multiset and strike it off.
            for (r.backing[0..r.size]) |v| {
                var found = false;
                for (expected.items, 0..) |ev, ei| {
                    if (ev == v) {
                        _ = expected.orderedRemove(ei);
                        found = true;
                        break;
                    }
                }
                try std.testing.expect(found);
            }
            try std.testing.expectEqual(@as(usize, 0), expected.items.len);

            var j: usize = 0;
            while (j < shadow.items.len) {
                if (shadow.items[j].stripe == target) {
                    _ = shadow.orderedRemove(j);
                } else j += 1;
            }
        }
        checkInvariants(Small, w);
    }
}

test "fuzz on the tiny wheel exercises wrap-around every few ticks" {
    const a = std.testing.allocator;
    const w = try Tiny.init(a);
    defer w.deinit();

    var prng = std.Random.DefaultPrng.init(0x0BAD_C0DE_DEAD_BEEF);
    const rnd = prng.random();

    const Entry = struct { handle: u64, value: u64, stripe: u32 };
    var shadow: std.ArrayList(Entry) = .empty;
    defer shadow.deinit(a);
    var backing: []u64 = &.{};
    defer freeBacking(a, backing);

    var op: usize = 0;
    while (op < 2000) : (op += 1) {
        const choice = rnd.uintLessThan(u32, 10);
        if (shadow.items.len == 0 or choice < 4) {
            const value = rnd.int(u64);
            const h = try w.add_value(value);
            const stripe: u32 = w.cursor & (Tiny.M - 1);
            try std.testing.expectEqual(@as(u32, @truncate(h >> STRIPE_SHIFT)), stripe);
            try shadow.append(a, .{ .handle = h, .value = value, .stripe = stripe });
        } else if (choice < 7) {
            const idx = rnd.uintLessThan(usize, shadow.items.len);
            w.delete_by_index(shadow.items[idx].handle);
            _ = shadow.orderedRemove(idx);
        } else {
            const target: u32 = (w.cursor +% 1) & (Tiny.M - 1);
            const r = try w.shift(backing);
            backing = r.backing;

            var expected: std.ArrayList(u64) = .empty;
            defer expected.deinit(a);
            for (shadow.items) |e| {
                if (e.stripe == target) try expected.append(a, e.value);
            }
            try std.testing.expectEqual(expected.items.len, r.size);

            for (r.backing[0..r.size]) |v| {
                var found = false;
                for (expected.items, 0..) |ev, ei| {
                    if (ev == v) {
                        _ = expected.orderedRemove(ei);
                        found = true;
                        break;
                    }
                }
                try std.testing.expect(found);
            }
            try std.testing.expectEqual(@as(usize, 0), expected.items.len);

            var j: usize = 0;
            while (j < shadow.items.len) {
                if (shadow.items[j].stripe == target) {
                    _ = shadow.orderedRemove(j);
                } else j += 1;
            }
        }
        checkInvariants(Tiny, w);
    }
}

test "init is leak-free at every allocation failure" {
    var fail: usize = 0;
    while (fail < Small.M + 2) : (fail += 1) {
        var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail });
        const a = fa.allocator();
        if (Small.init(a)) |w| {
            try std.testing.expect(fail > Small.M);
            w.deinit();
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }
}

test "add OOM on stripe slice growth preserves state" {
    var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const a = fa.allocator();
    const w = try Small.init(a);
    defer w.deinit();

    for (0..Small.N) |i| _ = try w.add_value(@intCast(i));
    checkInvariants(Small, w);
    const len_before = w.slots[0].len;

    fa.fail_index = fa.alloc_index;
    fa.resize_fail_index = fa.resize_index;
    try std.testing.expectError(error.OutOfMemory, w.add_value(7));
    try std.testing.expectEqual(len_before, w.slots[0].len);
    checkInvariants(Small, w);

    fa.fail_index = std.math.maxInt(usize);
    fa.resize_fail_index = std.math.maxInt(usize);
    _ = try w.add_value(7);
    checkInvariants(Small, w);
    try std.testing.expectEqual(len_before + 1, w.slots[0].len);
}

test "heap fallback OOM preserves state" {
    var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const a = fa.allocator();
    const w = try Small.init(a);
    defer w.deinit();

    for (0..Small.L * Small.N) |i| _ = try w.add_value(@intCast(i));
    try std.testing.expectEqual(NIL, w.pool.free);
    checkInvariants(Small, w);

    const r = try w.shift(&.{});
    try std.testing.expectEqual(@as(usize, 0), r.size);

    // Let the fresh stripe's slice allocation succeed, then fail the heap
    // block allocation on the depleted pool.
    fa.fail_index = fa.alloc_index + 1;
    try std.testing.expectError(error.OutOfMemory, w.add_value(42));
    checkInvariants(Small, w);
    try std.testing.expectEqual(@as(u32, 0), w.slots[1].len);
    try std.testing.expectEqual(@as(usize, 1), w.slots[1].blocks.len);

    fa.fail_index = std.math.maxInt(usize);
    _ = try w.add_value(42);
    checkInvariants(Small, w);
    try std.testing.expectEqual(@as(u32, 1), w.slots[1].len);
}

test "shift OOM leaves the wheel unchanged and is retry-safe" {
    var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const a = fa.allocator();
    const w = try Small.init(a);
    defer w.deinit();

    _ = try w.add_value(0xCAFE);
    checkInvariants(Small, w);

    var backing: []u64 = &.{};
    defer freeBacking(a, backing);
    var i: usize = 0;
    while (i < Small.M - 1) : (i += 1) backing = (try w.shift(backing)).backing;
    try std.testing.expectEqual(@as(u32, Small.M - 1), w.cursor);

    fa.fail_index = fa.alloc_index;
    fa.resize_fail_index = fa.resize_index;
    try std.testing.expectError(error.OutOfMemory, w.shift(backing));
    try std.testing.expectEqual(@as(u32, Small.M - 1), w.cursor);
    checkInvariants(Small, w);
    try std.testing.expectEqual(@as(u32, 1), w.slots[0].len);

    fa.fail_index = std.math.maxInt(usize);
    fa.resize_fail_index = std.math.maxInt(usize);
    const r = try w.shift(backing);
    backing = r.backing;
    try std.testing.expectEqual(@as(usize, 1), r.size);
    try std.testing.expectEqual(@as(u64, 0xCAFE), r.backing[0]);
    try std.testing.expectEqual(@as(u32, Small.M), w.cursor);
    checkInvariants(Small, w);
}

// Testing scenario where we:
//
//  Slot 0 <- 1, 2, 3.
//
//  Shift to 1 with no elements.
//  Slot 1 <- 4, 5, 6
//  Remove 2 from Slot 0.
//  Remove 6 from Slot 1.
//
//  Shift to 2 with no elements.
//  Remove 4 from Slot 1.
//  Slot 2 <- 7, 8
//  Remove 8 from Slot 2.
//  Remove 7 from Slot 2.
//
//  Shift to 3 with no elements
//
//  Shift to 0 with {1, 2} back again.
//  Shift to 1 with {5}
//  Shift to 2 with no elements.
//  Shift to 3 with no elements.
//  Shift to 0 with no elements and back to once .
test "finally human usage test" {
    var w = try TimingWheel(4, 2, 16).init(std.testing.allocator);
    defer w.deinit();

    const emptyArray = &[_]u64{};
    var backing = ShiftResult{
        .backing = emptyArray,
        .size = 0,
    };

    // Slot 0
    _ = try w.add_value(1);
    const idx12 = try w.add_value(2);
    _ = try w.add_value(3);

    // Slot 1
    backing = try w.shift(backing.backing);
    try expectSet(backing, emptyArray);
    const idx21 = try w.add_value(4);
    _ = try w.add_value(5);
    const idx23 = try w.add_value(6);
    w.delete_by_index(idx12);
    w.delete_by_index(idx23);

    // Slot 2
    backing = try w.shift(backing.backing);
    try expectSet(backing, emptyArray);
    w.delete_by_index(idx21);
    const idx31 = try w.add_value(7);
    const idx32 = try w.add_value(8);
    w.delete_by_index(idx32);
    w.delete_by_index(idx31);

    // Slot 3
    backing = try w.shift(backing.backing);
    try expectSet(backing, emptyArray);

    // Slot 0
    var expectTick4 = [_]u64{ 1, 3 };
    backing = try w.shift(backing.backing);
    try expectSet(backing, &expectTick4);

    // Slot 1
    var expectTick5 = [_]u64{5};
    backing = try w.shift(backing.backing);
    try expectSet(backing, &expectTick5);

    // Slot 2
    backing = try w.shift(backing.backing);
    try expectSet(backing, emptyArray);

    // Slot 3
    backing = try w.shift(backing.backing);
    try expectSet(backing, emptyArray);

    // Slot 0
    backing = try w.shift(backing.backing);
    try expectSet(backing, emptyArray);

    std.testing.allocator.free(backing.backing);
}

// for testing purposes only.
fn expectSet(values: ShiftResult, expect: []u64) !void {
    const data = values.backing[0..values.size];

    std.mem.sort(u64, data, {}, std.sort.asc(u64));
    std.mem.sort(u64, expect, {}, std.sort.asc(u64));
    try std.testing.expectEqualSlices(u64, expect, data);
}
