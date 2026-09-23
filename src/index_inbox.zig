//! Inbound Queue & Notification/Sleep Protocol (Front producers -> Index consumer).
//!
//! TASK-INDEX-INBOUND.md is the normative specification; every block below is
//! assembled from it. A single `IndexInbox` per Index carries both halves of
//! the protocol: the SPSC inbound ring (`push` / `pop`) plus the sleep flag and
//! the two ring handles of the notification channel (`front_ring`, the owning
//! Front's ring that carries the wakeup, and `index_ring`, this Index's ring
//! that is parked on and woken up). The two actors:
//!
//! - a Front thread (producer) enqueues routing tasks with `push`, which posts
//!   a payload-less wakeup CQE onto the Index's io_uring via `MSG_RING` when the
//!   Index announced sleep;
//! - an Index thread (consumer, exactly one per index) opens one `batch` per
//!   round: a capped CQ window plus a capped inbound window (the `BatchInbox`),
//!   so the whole loop has a single entry point. An empty `batch` bumps
//!   `misses`, and `hang` spins on that counter until the `idle_iters_n` barrier
//!   is reached, then announces sleep, double-checks both sources, parks in the
//!   kernel and clears the flag on wake.
//!
//! Each `IndexInbox` has exactly ONE producer thread (its owning Front, HLD
//! predicate `sid·2^(I-F) <= iid < (sid+1)·2^(I-F)`), so the queue is SPSC by
//! construction. Zig 0.16 removed `@fence`; both full barriers use `fullFence`.

const std = @import("std");
const posix = std.posix;
const zigring = @import("zigring");

const native_arch = @import("builtin").cpu.arch;

/// Full StoreLoad barrier. Zig 0.16 removed `@fence`; emit the hardware fence directly.
inline fn fullFence() void {
    switch (native_arch) {
        .x86_64 => asm volatile ("mfence" ::: .{ .memory = true }),
        .aarch64, .aarch64_be => asm volatile ("dmb ish" ::: .{ .memory = true }),
        else => @compileError("index_inbox: fullFence not implemented for this architecture"),
    }
}

/// taskIdx of a CQE that carries a cross-task slot index in `res` (payload-bearing path).
pub const CrossTaskMessageIdx: u64 = std.math.maxInt(u64) - 2;

/// taskIdx of the payload-less sleep-wakeup CQE (this protocol).
/// Same value as `FrontTaskNotificationIdx` in docs/shard-arch-hld.md; dedicated name.
pub const IndexWakeupTaskIdx: u64 = std.math.maxInt(u64) - 3;

/// `msg_result` codes >= this base carry no payload (docs/shard-arch-hld.md, "no payload" convention).
pub const NoPayloadMsgResultBase: u32 = std.math.maxInt(u32) / 2;

/// `msg_result` of a wakeup CQE. Not an errno; identified by taskIdx, never by res.
pub const IndexWakeupMsgResult: u32 = NoPayloadMsgResultBase + 1;

comptime {
    std.debug.assert(IndexWakeupTaskIdx != zigring.fireAndForgetTaskIdx);
    std.debug.assert(IndexWakeupTaskIdx >= (1 << 63));
    std.debug.assert(IndexWakeupTaskIdx <= std.math.maxInt(u64) - 2);
    std.debug.assert(IndexWakeupMsgResult >= NoPayloadMsgResultBase);
}

/// Runtime tuning of the Index loop. Defaults per TASK-INDEX-INBOUND.md §1.5:
/// `batch_k = 64` is the default cap of both windows opened by `batch` (the CQ
/// window and the inbound window), `idle_iters_n = 32` is the `misses` barrier:
/// once that many consecutive empty observations accumulate, `hang` stops
/// spinning and parks the Index in the kernel.
pub const LoopConfig = struct {
    batch_k: u32 = 64,
    idle_iters_n: u32 = 32,
};

/// SPSC lock-free bounded ring (one per Index) fused with the sleep flag and
/// the wake path of the notification protocol.
///
/// The ring is a Lamport ring specialized to single-producer/single-consumer:
/// each frontier has exactly one writer, so no CAS, no locks and no per-slot
/// sequence numbers are needed. The producer side is the owning Front thread
/// (`push`), the consumer side is the Index thread (`pop`, `hang`, INV-1).
///
/// `push` is wait-free and never blocks on the queue: on full it returns
/// `error.InboundFull` immediately. The wakeup it may issue afterwards
/// (S2-S5) only runs when the Index announced sleep.
pub fn IndexInbox(comptime TaskT: type, comptime capacity_pow2: comptime_int) type {
    if (capacity_pow2 < 2 or capacity_pow2 > (1 << 30))
        @compileError("IndexInbox: capacity must be in [2, 2^30]");
    if (capacity_pow2 & (capacity_pow2 - 1) != 0)
        @compileError("IndexInbox: capacity must be a power of two");
    if (@sizeOf(TaskT) == 0) @compileError("IndexInbox: TaskT must be non-zero-sized");

    return struct {
        const Self = @This();

        pub const Task = TaskT;
        pub const slot_count: u32 = capacity_pow2;
        const mask: u32 = capacity_pow2 - 1;
        pub const Error = error{InboundFull};

        /// Monolithic coordination window over both sources, opened by `batch`.
        pub const Batch = BatchOf(Self);
        /// The inbound half of a `Batch`.
        pub const BatchInbox = BatchInboxOf(Self);

        /// Data slots. Written by the producer after the full-check, read by the
        /// consumer after the empty-check; plain memory, ordered by the
        /// tail/head release-acquire pairs around each access.
        slots: [slot_count]TaskT align(std.atomic.cache_line),

        /// Commit frontier. Written ONLY by the producer (P-4, .release);
        /// read by the consumer (C-2, .acquire) and by the producer itself (P-1, .monotonic).
        tail: std.atomic.Value(u32) align(std.atomic.cache_line),

        /// Free frontier. Written ONLY by the consumer (C-4, .release);
        /// read by the producer (P-2, .acquire).
        head: std.atomic.Value(u32) align(std.atomic.cache_line),

        /// Producer-private cache of `head`; reloaded only on the appears-full
        /// path (P-2). No synchronization required or performed.
        cached_head: u32,

        /// Index thread only: `store(true, .release)` at B1, `store(false, .release)`
        /// at B3/B4 abort-clear and at B7 post-wake. Front thread only: `load(.acquire)` at S3.
        sleep_flag: std.atomic.Value(bool) align(std.atomic.cache_line) = std.atomic.Value(bool).init(false),

        /// Ring of the owning Front thread: the wakeup `MSG_RING` CQE of `push`
        /// is submitted through it. Immutable after publication (INV-7): written
        /// once, single-threaded, before any `Thread.spawn`.
        front_ring: *zigring.Ring,

        /// Ring of this Index: the consumer opens its batched CQ window on it,
        /// `hang` parks on it, and `push` sends the wakeup CQE to its `fd`.
        /// Immutable after publication (INV-7).
        index_ring: *zigring.Ring,

        /// Index thread only: consecutive `batch` calls that found nothing.
        /// `batch` increments it on every miss and resets it to 0 on every hit;
        /// `hang` spins while it is below `cfg.idle_iters_n` and parks once it
        /// reaches that barrier. Never touched by the producer.
        misses: u32,

        /// Storage of the CQ half of the batch currently open, handed out by
        /// `batch` as `Batch.ring`. Kept here so opening a batch does not
        /// allocate.
        batch_cq: zigring.BatchCQ,

        /// Storage of the inbound half of the batch currently open, handed out
        /// by `batch` as `Batch.front`.
        batch_front: BatchInbox,

        /// Bootstrap only, single-threaded, before any `Thread.spawn` (INV-7).
        pub fn init(self: *Self, front_ring: *zigring.Ring, index_ring: *zigring.Ring) void {
            self.slots = undefined;
            self.tail = std.atomic.Value(u32).init(0);
            self.head = std.atomic.Value(u32).init(0);
            self.cached_head = 0;
            self.sleep_flag = std.atomic.Value(bool).init(false);
            self.front_ring = front_ring;
            self.index_ring = index_ring;
            self.misses = 0;
            self.batch_cq = undefined;
            self.batch_front = .{ .inbox = self, .remaining = 0 };
        }

        /// Producer side: the owning Front thread ONLY (INV-1). Enqueues the
        /// task and then wakes the Index with a payload-less `MSG_RING` CQE if
        /// it announced sleep (S1-S5). Wait-free except for the wakeup retry;
        /// never blocks on the queue itself.
        pub fn push(self: *Self, task: TaskT) Error!void {
            const pos = self.tail.load(.monotonic); // own value; sole writer
            if (pos -% self.cached_head >= slot_count) { // appears full (wrap-exact: INV-2)
                self.cached_head = self.head.load(.acquire); // reload peer frontier
                if (pos -% self.cached_head >= slot_count)
                    return Error.InboundFull; // really full: fail immediately
            }
            self.slots[pos & mask] = task; // plain store; ordered by the release below
            self.tail.store(pos +% 1, .release); // commit: publishes the slot (S1)

            fullFence(); // S2: mandatory StoreLoad barrier before the flag read
            if (!self.sleep_flag.load(.acquire)) return; // S3+S4 fast path: Index is polling
            self.signal(); // S5: Index is parked, interrupt its kernel sleep
        }

        /// Consumer side: the Index thread ONLY (INV-1). Non-blocking.
        pub fn pop(self: *Self) ?TaskT {
            const pos = self.head.load(.monotonic); // own value; sole writer
            const peer_tail = self.tail.load(.acquire); // peer commit frontier
            if (pos == peer_tail) return null; // empty
            const task = self.slots[pos & mask]; // plain load; ordered by the acquire above
            self.head.store(pos +% 1, .release); // free the slot for position pos + slot_count
            return task;
        }

        /// Wakeup submission (S5): a payload-less `MSG_RING` CQE on the Index's
        /// ring. Retries while the Front's SQ is full; the SQPOLL kernel thread
        /// drains it unconditionally, so the retry terminates (§3.7).
        fn signal(self: *Self) void {
            while (true) {
                if (self.front_ring.pushMsgRingFd(
                    self.index_ring.fd, // fd of the Index's ring
                    IndexWakeupTaskIdx,
                    IndexWakeupMsgResult,
                    .{},
                )) |_| {
                    return;
                } else |err| switch (err) {
                    // The inferred error set of pushMsgRingFd on native Linux is
                    // exactly {error.RingFull}; any kernel I/O failure is routed
                    // to posix.unexpectedErrno inside zigring.
                    error.RingFull => std.atomic.spinLoopHint(),
                }
            }
        }

        /// Consumer side: the Index thread ONLY (INV-1). Suspends until work
        /// arrives. There are no callbacks: the caller owns the work and simply
        /// re-runs `batch` after `hang` returns.
        ///
        /// While `misses` is below the `idle_iters_n` barrier it keeps spinning
        /// (`spinLoopHint`) and re-checking both sources, so a task that lands
        /// during the spin returns control at once. Once the barrier is hit it
        /// announces sleep (B1), fences (B2), double-checks the CQ and the
        /// inbound ring (B3/B4, `checkCQNotEmpty` + the inbox frontiers), parks
        /// the Index ring (B6) and clears the flag on wake (B7).
        ///
        /// Returns without parking if either check finds work (B5). On every
        /// return path `sleep_flag` is `false` and `misses` is `0`, so the
        /// caller can resume its polling loop immediately.
        pub fn hang(self: *Self, cfg: LoopConfig) void {
            while (self.misses < cfg.idle_iters_n) {
                if (self.hasWork()) {
                    self.misses = 0;
                    return;
                }
                self.misses +%= 1;
                std.atomic.spinLoopHint();
            }

            self.sleep_flag.store(true, .release); // B1
            fullFence(); // B2

            if (self.hasWork()) { // B3/B4: double-check sweep of both sources
                self.sleep_flag.store(false, .release); // B5
                self.misses = 0;
                return;
            }

            self.index_ring.park(); // B6
            self.sleep_flag.store(false, .release); // B7: clear before draining
            self.misses = 0;
        }

        /// Non-consuming readiness poll over both sources: the Index ring's CQ
        /// (any pending completion, including a payload-less wakeup) and the
        /// inbound queue (any committed task).
        inline fn hasWork(self: *Self) bool {
            return self.index_ring.checkCQNotEmpty() or self.available() != 0;
        }

        /// Number of tasks currently committed to the inbound queue. Snapshot
        /// of the two frontiers; only the consumer calls it.
        inline fn available(self: *Self) u32 {
            return self.tail.load(.acquire) -% self.head.load(.monotonic);
        }

        /// Consumer side: the Index thread ONLY (INV-1). Monolithic coordination
        /// window over both sources: the ring's CQ (at most `ring` completions)
        /// and the inbound queue (at most `front` tasks).
        ///
        /// Returns null when both windows are empty, and then `misses` grows by
        /// one; any successful open resets `misses` to 0. The two views stay
        /// valid until the next `batch` call on this inbox: drain them, then
        /// `commit` the ring window before opening the next batch.
        pub fn batch(self: *Self, ring: u32, front: u32) ?Batch {
            const cq = self.index_ring.batchedCQ(ring);
            const remaining = @min(front, self.available());
            if (cq == null and remaining == 0) {
                self.misses +%= 1;
                return null;
            }

            self.misses = 0;
            self.batch_cq = cq orelse self.emptyCqView();
            self.batch_front = .{ .inbox = self, .remaining = remaining };
            return .{ .ring = &self.batch_cq, .front = &self.batch_front };
        }

        /// A window that exposes nothing but still commits safely (its head is
        /// the ring's current head, so `commit` is a no-op).
        inline fn emptyCqView(self: *Self) zigring.BatchCQ {
            const head = self.index_ring.cqHead.*;
            return .{ .ring = self.index_ring, .head = head, .tail = head };
        }
    };
}

/// The two sub-windows of one `IndexInbox.batch`, opened together so the Index
/// loop has a single entry point over its ring and its inbound queue.
pub fn BatchOf(comptime InboxT: type) type {
    return struct {
        /// Capped completion window over the Index ring. Empty but valid when
        /// the ring had nothing to offer.
        ring: *zigring.BatchCQ,
        /// Capped task window over the inbound queue.
        front: *BatchInboxOf(InboxT),
    };
}

/// A capped, forward-only view over an `IndexInbox`'s inbound queue. It is
/// opened by `IndexInbox.batch` with a limit and yields at most that many
/// tasks, so the Index loop can bound how much inbound work it takes per round.
pub fn BatchInboxOf(comptime InboxT: type) type {
    return struct {
        const Self = @This();

        inbox: *InboxT,
        /// Tasks still allowed out of this window.
        remaining: u32,

        /// Next queued task, or null once the window is exhausted or the queue
        /// is empty. Non-blocking; consumes through the inbox's `pop`.
        pub fn next(self: *Self) ?InboxT.Task {
            if (self.remaining == 0) return null;
            const task = self.inbox.pop() orelse return null;
            self.remaining -= 1;
            return task;
        }
    };
}

test "inbound FIFO single producer" {
    const Inbox = IndexInbox(struct { v: u32 }, 8);
    var front_ring = try zigring.Ring.init(64, null);
    defer front_ring.deinit();
    var index_ring = try zigring.Ring.init(64, null);
    defer index_ring.deinit();
    var inbox: Inbox = undefined;
    inbox.init(&front_ring, &index_ring);

    var n: u32 = 0;
    while (n < 8) : (n += 1) try inbox.push(.{ .v = n });
    n = 0;
    while (n < 8) : (n += 1) try std.testing.expectEqual(n, inbox.pop().?.v);
    try std.testing.expect(inbox.pop() == null);
}

test "inbound full fails immediately and slot is reusable" {
    const Inbox = IndexInbox(struct { v: u32 }, 2);
    var front_ring = try zigring.Ring.init(64, null);
    defer front_ring.deinit();
    var index_ring = try zigring.Ring.init(64, null);
    defer index_ring.deinit();
    var inbox: Inbox = undefined;
    inbox.init(&front_ring, &index_ring);

    try inbox.push(.{ .v = 1 });
    try inbox.push(.{ .v = 2 });
    try std.testing.expectError(error.InboundFull, inbox.push(.{ .v = 3 }));
    try std.testing.expectEqual(@as(u32, 1), inbox.pop().?.v);
    try inbox.push(.{ .v = 3 });
    try std.testing.expectEqual(@as(u32, 2), inbox.pop().?.v);
    try std.testing.expectEqual(@as(u32, 3), inbox.pop().?.v);
    try std.testing.expect(inbox.pop() == null);
}

test "inbound SPSC two threads: FIFO under backpressure" {
    const Inbox = IndexInbox(struct { v: u32 }, 64);
    var front_ring = try zigring.Ring.init(64, null);
    defer front_ring.deinit();
    var index_ring = try zigring.Ring.init(64, null);
    defer index_ring.deinit();
    var inbox: Inbox = undefined;
    inbox.init(&front_ring, &index_ring);

    const Producer = struct {
        inbox: *Inbox,
        fn run(self: *@This()) void {
            var n: u32 = 0;
            while (n < 1000) {
                if (self.inbox.push(.{ .v = n })) |_| {
                    n += 1;
                } else |_| {
                    std.atomic.spinLoopHint();
                }
            }
        }
    };
    var producer = Producer{ .inbox = &inbox };
    const producer_thread = try zigring.Thread.spawn(&producer, Producer.run);

    var delivered: u32 = 0;
    while (delivered < 1000) {
        if (inbox.pop()) |task| {
            try std.testing.expectEqual(delivered, task.v);
            delivered += 1;
        } else std.atomic.spinLoopHint();
    }
    producer_thread.join();
    try std.testing.expect(inbox.pop() == null);
}

test "push enqueues and posts wakeup CQE to the target ring" {
    const Inbox = IndexInbox(struct { v: u32 }, 64);
    var front_ring = try zigring.Ring.init(64, null);
    defer front_ring.deinit();
    var index_ring = try zigring.Ring.init(64, null);
    defer index_ring.deinit();
    var inbox: Inbox = undefined;
    inbox.init(&front_ring, &index_ring);

    inbox.sleep_flag.store(true, .release);
    try inbox.push(.{ .v = 42 });

    try std.testing.expectEqual(@as(u32, 42), inbox.pop().?.v);
    const deadline = zigring.monotonicNs() + 5 * std.time.ns_per_s;
    while (zigring.monotonicNs() < deadline) {
        if (index_ring.popCQE()) |cqe| {
            try std.testing.expectEqual(IndexWakeupTaskIdx, cqe.taskIdx());
            try std.testing.expectEqual(IndexWakeupMsgResult, @as(u32, @truncate(cqe.result())));
            return;
        }
        std.atomic.spinLoopHint();
    }
    return error.WakeupCqeTimeout;
}

test "push fast path skips the wakeup when the Index is polling" {
    const Inbox = IndexInbox(struct { v: u32 }, 64);
    var front_ring = try zigring.Ring.init(64, null);
    defer front_ring.deinit();
    var index_ring = try zigring.Ring.init(64, null);
    defer index_ring.deinit();
    var inbox: Inbox = undefined;
    inbox.init(&front_ring, &index_ring);

    try inbox.push(.{ .v = 7 });

    try std.testing.expectEqual(@as(u32, 7), inbox.pop().?.v);
    // No CQE may appear: the flag was false, so no MSG_RING was submitted.
    const deadline = zigring.monotonicNs() + 100 * std.time.ns_per_ms;
    while (zigring.monotonicNs() < deadline) {
        try std.testing.expect(index_ring.popCQE() == null);
        std.atomic.spinLoopHint();
    }
}

test "inbound counter wrap-around is transparent (INV-2)" {
    const Inbox = IndexInbox(struct { v: u32 }, 4);
    var front_ring = try zigring.Ring.init(64, null);
    defer front_ring.deinit();
    var index_ring = try zigring.Ring.init(64, null);
    defer index_ring.deinit();
    var inbox: Inbox = undefined;
    inbox.init(&front_ring, &index_ring);

    // Wrap both frontiers past 2^32 - 3 so every push/pop crosses the wrap.
    inbox.tail = std.atomic.Value(u32).init(std.math.maxInt(u32) - 3);
    inbox.head = std.atomic.Value(u32).init(std.math.maxInt(u32) - 3);
    inbox.cached_head = std.math.maxInt(u32) - 3;

    var n: u32 = 0;
    while (n < 10) : (n += 1) {
        try inbox.push(.{ .v = n });
        try std.testing.expectEqual(n, inbox.pop().?.v);
    }
    try std.testing.expect(inbox.pop() == null);
}

test "batch caps the inbound window and leaves the rest queued" {
    const Inbox = IndexInbox(struct { v: u32 }, 64);
    var front_ring = try zigring.Ring.init(64, null);
    defer front_ring.deinit();
    var index_ring = try zigring.Ring.init(64, null);
    defer index_ring.deinit();
    var inbox: Inbox = undefined;
    inbox.init(&front_ring, &index_ring);

    var n: u32 = 0;
    while (n < 5) : (n += 1) try inbox.push(.{ .v = n });

    const b = inbox.batch(0, 3) orelse return error.MissingBatch;
    try std.testing.expectEqual(@as(u32, 0), inbox.misses);
    // The CQ half is empty but still a valid, committable window.
    try std.testing.expect(b.ring.popCQE() == null);
    try b.ring.commit();

    n = 0;
    while (b.front.next()) |task| : (n += 1) try std.testing.expectEqual(n, task.v);
    try std.testing.expectEqual(@as(u32, 3), n);
    try std.testing.expectEqual(@as(u32, 3), inbox.pop().?.v);
    try std.testing.expectEqual(@as(u32, 4), inbox.pop().?.v);
    try std.testing.expect(inbox.pop() == null);
}

test "batch yields the CQ window when only the ring has work" {
    const Inbox = IndexInbox(struct { v: u32 }, 64);
    var front_ring = try zigring.Ring.init(64, null);
    defer front_ring.deinit();
    var index_ring = try zigring.Ring.init(64, null);
    defer index_ring.deinit();
    var inbox: Inbox = undefined;
    inbox.init(&front_ring, &index_ring);

    // Announce sleep, then push: the wakeup CQE lands on the Index ring while
    // the task stays in the inbound queue (the batch window is front-capped).
    inbox.sleep_flag.store(true, .release);
    try inbox.push(.{ .v = 9 });

    const deadline = zigring.monotonicNs() + 5 * std.time.ns_per_s;
    while (!index_ring.checkCQNotEmpty()) {
        if (zigring.monotonicNs() >= deadline) return error.WakeupCqeTimeout;
        std.atomic.spinLoopHint();
    }

    const b = inbox.batch(8, 0) orelse return error.MissingBatch;
    try std.testing.expect(b.front.next() == null);
    const cqe = b.ring.popCQE() orelse return error.MissingCqe;
    try std.testing.expectEqual(IndexWakeupTaskIdx, cqe.taskIdx());
    try std.testing.expect(b.ring.popCQE() == null);
    try b.ring.commit();

    try std.testing.expectEqual(@as(u32, 9), inbox.pop().?.v);
}

test "batch tracks misses: null bumps, success resets" {
    const Inbox = IndexInbox(struct { v: u32 }, 64);
    var front_ring = try zigring.Ring.init(64, null);
    defer front_ring.deinit();
    var index_ring = try zigring.Ring.init(64, null);
    defer index_ring.deinit();
    var inbox: Inbox = undefined;
    inbox.init(&front_ring, &index_ring);

    try std.testing.expect(inbox.batch(8, 8) == null);
    try std.testing.expectEqual(@as(u32, 1), inbox.misses);
    try std.testing.expect(inbox.batch(8, 8) == null);
    try std.testing.expectEqual(@as(u32, 2), inbox.misses);

    try inbox.push(.{ .v = 1 });
    const b = inbox.batch(8, 8) orelse return error.MissingBatch;
    try std.testing.expectEqual(@as(u32, 0), inbox.misses);
    try std.testing.expectEqual(@as(u32, 1), b.front.next().?.v);
}

test "hang aborts without parking when work is already visible" {
    const Inbox = IndexInbox(struct { v: u32 }, 64);
    var front_ring = try zigring.Ring.init(64, null);
    defer front_ring.deinit();
    var index_ring = try zigring.Ring.init(64, null);
    defer index_ring.deinit();
    var inbox: Inbox = undefined;
    inbox.init(&front_ring, &index_ring);

    const cfg = LoopConfig{ .batch_k = 4, .idle_iters_n = 2 };

    // Below the barrier: `hang` spins once, sees the task and returns.
    try inbox.push(.{ .v = 5 });
    inbox.hang(cfg);
    try std.testing.expectEqual(@as(u32, 0), inbox.misses);
    try std.testing.expect(!inbox.sleep_flag.load(.acquire));
    try std.testing.expectEqual(@as(u32, 5), inbox.pop().?.v);

    // At the barrier: `hang` announces sleep, the double-check finds the task
    // and aborts the sleep before ever calling `park`.
    try inbox.push(.{ .v = 6 });
    inbox.misses = cfg.idle_iters_n;
    inbox.hang(cfg);
    try std.testing.expectEqual(@as(u32, 0), inbox.misses);
    try std.testing.expect(!inbox.sleep_flag.load(.acquire));
    try std.testing.expectEqual(@as(u32, 6), inbox.pop().?.v);
}

test "hang parks, wakes on push, and delivers the task" {
    const Inbox = IndexInbox(struct { v: u32 }, 64);

    const IndexCtx = struct {
        const Self = @This();

        inbox: Inbox,
        front_ring: zigring.Ring,
        index_ring: zigring.Ring,
        delivered: std.atomic.Value(u32),

        const cfg = LoopConfig{ .batch_k = 8, .idle_iters_n = 4 };

        fn run(self: *Self) void {
            // The consumer owns Phase A; `hang` is its idle path.
            while (true) {
                const b = self.inbox.batch(cfg.batch_k, cfg.batch_k) orelse {
                    self.inbox.hang(cfg);
                    continue;
                };

                var work: u32 = 0;
                while (b.ring.popCQE()) |cqe| { // CQ strictly before inbound
                    if (cqe.taskIdx() != IndexWakeupTaskIdx) work += 1;
                }
                b.ring.commit() catch unreachable;

                while (b.front.next()) |task| {
                    _ = task;
                    _ = self.delivered.fetchAdd(1, .monotonic);
                    work += 1;
                }

                if (work == 0) self.inbox.hang(cfg);
            }
        }
    };

    // Static storage: the worker thread outlives the test body (its loop never
    // returns). After the final task burst it re-enters park() and stays parked
    // in the kernel until process exit reaps it; the rings are therefore never
    // deinit'd under it.
    var index: IndexCtx = .{
        .inbox = undefined,
        .front_ring = try zigring.Ring.init(64, null),
        .index_ring = try zigring.Ring.init(64, null),
        .delivered = std.atomic.Value(u32).init(0),
    };
    index.inbox.init(&index.front_ring, &index.index_ring);
    _ = try zigring.Thread.spawn(&index, IndexCtx.run);

    // Wait for the Index to announce sleep (it has nothing else to do), then
    // push a burst of tasks. This exercises the full T1 path: the flag is
    // observed true, the wakeup CQE is posted, park() returns, and both the
    // sweep and the post-wake polling pass deliver tasks.
    const total: u32 = 100;
    const deadline = zigring.monotonicNs() + 10 * std.time.ns_per_s;
    var pushed: u32 = 0;
    while (zigring.monotonicNs() < deadline) {
        if (pushed == 0 and !index.inbox.sleep_flag.load(.acquire)) {
            std.atomic.spinLoopHint();
            continue;
        }
        // Test-side backpressure: the HLD failure policy (drop + error reply)
        // is a Front decision; here we simply wait for the drain instead.
        if (index.inbox.push(.{ .v = pushed })) |_| {
            pushed += 1;
            if (pushed >= total) break;
        } else |err| switch (err) {
            error.InboundFull => std.atomic.spinLoopHint(),
        }
    }
    try std.testing.expectEqual(total, pushed);

    while (index.delivered.load(.acquire) < total) std.atomic.spinLoopHint();
}
