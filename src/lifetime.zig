//! Process lifetime: the shared state every thread of the shard is built on,
//! and the single entry point working threads start from.
//!
//! `Controller` owns everything that is not thread-local: the array of rings,
//! the array of index inboxes, the cross-thread task slots, the ring factory,
//! the init ring and the thread handles. A working thread starts in
//! `runThread`, which derives the thread's role from the rolling counter,
//! creates the thread-local ring and logger and dispatches into `front.zig`,
//! `index.zig` or `elephant.zig` according to that role. The role stays on the
//! thread's stack: nothing else reads it back. A counter value that disagrees
//! with the launch order is fatal.
//!
//! A role's `ring_idx` is the thread's slot in every per-thread shared array:
//! the rings and the payloads of the cross-thread reports. "Thread index" is
//! never used as a separate term.
//!
//! The two-phase startup contract is documented in
//! docs/startup-en-reworked.md: initialization publishes and reports, and only
//! the init thread's `START_WORK` broadcast moves any thread into its working
//! loop.

const std = @import("std");
const posix = std.posix;
const config = @import("config.zig");
const zigring = @import("zigring");
const idxinbox = @import("index_inbox.zig");
const indexmod = @import("index.zig");
const cross_slots = @import("cross_task_slots.zig");
const cross_task = @import("cross_task.zig");
const logging = @import("logging.zig");
const blog = @import("blog");
const barrier = @import("barrier.zig");
const slots = @import("slots.zig");
const messages = @import("messages.zig");
const state = @import("state.zig");
const replay_queue = @import("replay_queue.zig");
const wal = @import("wal.zig");

/// Where one snapshot procedure's job stands, as the index thread left it.
///
/// `create_sent` is set by the mint; `dump_sent` after the handler pass
/// re-dispatches the dump; `close_sent` and `cleanup_sent` by the terminal
/// dispatches (designs/SNAPSHOTS.md §3, §8).
pub const SnapshotPhase = enum { create_sent, dump_sent, close_sent, cleanup_sent };

/// One snapshot procedure's job: the handle that travels in messages and the
/// state the elephant threads act on (designs/SNAPSHOTS.md §2.1).
///
/// Heap on the controller's allocator, freed by the terminal elephant through
/// `Controller.releaseSnapshotJob`. `clone` is valid from the handler pass
/// until the dump, and reading it before the clone or after the dump's arena
/// reset is a bug. `fd` and `old_fd` are `-1` when not held: the sender of a
/// descriptor sets its field to `-1` after handing it over, and whoever closes
/// one does the same.
pub const SnapshotJob = struct {
    /// Owns the clone until the dump resets it; also owns any dump bytes the
    /// elephant appends.
    arena: std.heap.ArenaAllocator,
    clone: state.IndexState,
    host_idx: u8,
    index_idx: u16,
    /// The requesting index ring: replies land there.
    ring_idx: u16,
    /// `X`, the pair's state at the first dispatch, fixed for the whole
    /// procedure and carried by both file names.
    tag: u128,
    /// The snapshot slot, which is also the procedure's temp ring.
    k: u32,
    phase: SnapshotPhase,
    /// The new WAL descriptor; `-1` when not held.
    fd: posix.fd_t,
    /// The old WAL descriptor from the swap; `-1` when not held.
    old_fd: posix.fd_t,
    /// The new WAL path, heap on the controller's allocator.
    wal_path: [:0]u8,
    /// The snapshot path, heap on the controller's allocator.
    snapshot_path: [:0]u8,
};

/// The window's write interface (designs/SNAPSHOTS.md §3.2 step 4, §5).
///
/// Every event is written **new first, then old**, and is complete — durable,
/// replyable — only when both sides' flushes have covered it. `new` is the temp
/// ring `k` writer the procedure adopted; `old` is the pair area's writer,
/// which stays registered for the window's duration.
pub const CompositeWriter = struct {
    new: *wal.WalWriteFile,
    old: *wal.WalWriteFile,
    /// The completion queue: one entry per event both sides accepted, in write
    /// order. Completed events leave from the head, so the list is a FIFO.
    pending: std.ArrayList(PendingEvent) = .empty,
    onComplete: ?*const fn (ctx: ?*anyopaque, end: u64) void = null,
    on_complete_ctx: ?*anyopaque = null,
    /// The side the last refused write refused on; `null` when it was
    /// accepted. The index's refusal classifier reads it (§5): the old side's
    /// refusal freezes the front, the new side's is the ordinary stop or a
    /// protocol answer.
    failed_side: ?Side = null,
    /// Owns `pending` — the controller's allocator.
    allocator: std.mem.Allocator,

    const PendingEvent = struct { end_new: u64, end_old: u64 };

    pub const Side = enum { new, old };

    /// Appends one event: new first, then old (§3.2 step 4).
    ///
    /// The order is load-bearing: the new WAL is the committed future and the
    /// old one the pre-commit fallback, so when the old side refuses the event
    /// is already in the new file. Each side chains from its own head — both
    /// sit at the clone state `Y` — and only an event both sides accepted is
    /// queued, because only that event can ever be complete.
    pub fn write(self: *CompositeWriter, new_state_idx: u128, data: []u8) wal.WalError!void {
        self.failed_side = null;

        self.new.write(new_state_idx, self.new.head, data) catch |err| {
            self.failed_side = .new;
            return err;
        };
        const end_new = self.new.trackedExtent();

        self.old.write(new_state_idx, self.old.head, data) catch |err| {
            self.failed_side = .old;
            return err;
        };
        const end_old = self.old.trackedExtent();

        try self.pending.append(self.allocator, .{ .end_new = end_new, .end_old = end_old });
    }

    /// Delivers every FIFO-head event both sides' flushes have covered (§5).
    ///
    /// `writer` names the side whose flush just completed; both frontiers are
    /// consulted on every call, because an event is complete — durable,
    /// replyable — only once **both** have reached it. Either single-side rule
    /// would lose durable events in one of the two crash outcomes. `end` in
    /// the callback is the completed event's pair-side end offset: the byte
    /// after its last byte in the old file's extent.
    pub fn noteFlush(self: *CompositeWriter, writer: *wal.WalWriteFile) void {
        std.debug.assert(writer == self.new or writer == self.old);
        const new_limit = self.new.flushed_upto * self.new.lba;
        const old_limit = self.old.flushed_upto * self.old.lba;

        var complete: usize = 0;
        while (complete < self.pending.items.len) : (complete += 1) {
            const event = self.pending.items[complete];
            if (event.end_new > new_limit or event.end_old > old_limit) break;
            if (self.onComplete) |callback| callback(self.on_complete_ctx, event.end_old);
        }
        if (complete == 0) return;

        const rest = self.pending.items.len - complete;
        std.mem.copyForwards(PendingEvent, self.pending.items[0..rest], self.pending.items[complete..]);
        self.pending.shrinkRetainingCapacity(rest);
    }

    /// Both writers quiet: no flush in flight and none parked (§3.4). At most
    /// one flush is ever in flight per writer, so the drain that waits for this
    /// is bounded.
    pub fn quiet(self: *const CompositeWriter) bool {
        return !self.new.flush_in_flight and !self.new.flush_pending and
            !self.old.flush_in_flight and !self.old.flush_pending;
    }
};

/// The controller that owns all shared process resources.
pub const Controller = struct {
    const Self = @This();

    pub const IndexInbox = idxinbox.IndexInbox(indexmod.FrontMessage);

    allocator: std.mem.Allocator,

    /// Application config.
    cfg: *const config.Config,

    /// "Hidden" atomic counter for role distribution.
    rolling_role_idx: u32 align(std.atomic.cache_line),
    /// One slot per thread, indexed exactly as the role numbering.
    rings: []RingStuff,
    /// One inbox per index thread, indexed by the index's own inbox index.
    inboxes: []IndexInbox,

    /// Ring of the main lifetime controller thread.
    ring_factory: zigring.Factory,
    init_ring: RingStuff,

    /// Storage for cross-thread interaction.
    cross_slots: cross_slots.CrossTaskSlots,

    /// The snapshot procedure pool: one exclusive slot per in-flight
    /// procedure, `cfg.snapshots.slots` of them process-wide. The slot index is
    /// also the procedure's temp ring (designs/SNAPSHOTS.md §2.1).
    snapshot_slots: cross_slots.SlotPool(cross_task.SnapshotSlot),

    /// Round-robin cursor over the elephant rings, shared by every thread that
    /// dispatches a snapshot task. Tasks are rare, so the contention this
    /// creates is a non-issue (§2.1).
    elephant_cursor: std.atomic.Value(u32),

    /// The compensator registry: built once at startup from the config's
    /// `compensators` block; key names immutable once created. The siggy
    /// grammar for the block is a follow-up; until it lands the registry is
    /// built from whatever the config offers (empty today) and tests populate
    /// it directly.
    compensators: state.CompensatorMap,

    /// Lifetime-owned timer arguments. The kernel reads these asynchronously,
    /// so they must outlive the helper that armed the timer. Keeping them here
    /// makes them valid until `deinit`, after every worker has been joined.
    init_deadline_spec: std.os.linux.kernel_timespec = .{ .sec = 0, .nsec = 0 },
    shutdown_tick_spec: std.os.linux.kernel_timespec = .{ .sec = 0, .nsec = 0 },

    /// Handles of the spawned working threads, in role order.
    threads: []zigring.Thread,
    /// Per-thread context handed to `runThread`, one slot per subject in
    /// launch order.
    thread_ctx: []ThreadContext,
    /// How many of `threads` were actually spawned.
    spawned: usize,

    /// How the WAL battery is backed.
    wal_mode: wal.Mode,
    /// Battery areas: one per `(host_idx, index_idx)` pair, `indexes × hosts`.
    wal_pairs: usize,
    /// Bytes between two pair areas, alignment padding included.
    wal_area_stride: usize,
    /// One live writer per pair area, `null` while the pair has none. This is
    /// what makes a second open of one triple `error.WalOpen`.
    wal_writers: []?*wal.WalWriteFile,
    /// Every pair's area in one aligned slab. Acquired at the first index
    /// thread start (plain) or by mapping the device (PMEM) and released in
    /// `deinit`; it outlives every WAL file, since files rotate over the same
    /// area epoch after epoch.
    wal_battery: ?[]u8,
    /// Guards the one-time battery acquisition: only the first index thread to
    /// start allocates, the rest wait for it.
    wal_battery_lock: std.atomic.Mutex,

    /// Test seam: `rewriteRegistry` stops after the staging file's commit and
    /// reports the rename as failed — the "pending write landed, line never
    /// committed" crash shape (designs/SNAPSHOTS-steps.md §J2). Production
    /// never sets it.
    test_fail_registry_rename: bool = false,

    /// Allocates the shared arrays. Rings and inboxes stay `undefined` here:
    /// each thread publishes its own ring, and each index creates its own
    /// inbox, during its initialization.
    pub fn init(self: *Self, allocator: std.mem.Allocator, cfg: *const config.Config) !void {
        const subjects: usize = @intCast(cfg.fronts + cfg.indexes + cfg.elephants);

        const rings = try allocator.alloc(RingStuff, subjects);
        errdefer allocator.free(rings);

        const inboxes = try allocator.alloc(IndexInbox, cfg.indexes);
        // Inboxes are created by their index threads; marking the slots clean
        // keeps `deinit` safe for slots that were never initialized.
        for (inboxes) |*inbox| inbox.initialized = false;
        errdefer allocator.free(inboxes);

        const threads = try allocator.alloc(zigring.Thread, subjects);
        errdefer allocator.free(threads);

        const thread_ctx = try allocator.alloc(ThreadContext, subjects);
        errdefer allocator.free(thread_ctx);

        // WAL geometry is pure config arithmetic; the battery itself is only
        // acquired once an index thread starts or a file is opened.
        const wal_writers = try allocator.alloc(?*wal.WalWriteFile, @as(usize, cfg.indexes) * cfg.wal.hosts());
        errdefer allocator.free(wal_writers);
        @memset(wal_writers, null);

        self.* = .{
            .allocator = allocator,
            .cfg = cfg,
            .rolling_role_idx = 0,
            .rings = rings,
            .inboxes = inboxes,
            .ring_factory = undefined,
            .init_ring = undefined,
            .cross_slots = undefined,
            .snapshot_slots = undefined,
            .elephant_cursor = std.atomic.Value(u32).init(0),
            .compensators = state.CompensatorMap.init(allocator),
            .threads = threads,
            .thread_ctx = thread_ctx,
            .spawned = 0,
            .wal_mode = wal.modeOf(cfg.wal),
            .wal_pairs = @as(usize, cfg.indexes) * cfg.wal.hosts(),
            .wal_area_stride = wal.areaStride(cfg.wal.buffers(), cfg.wal.lba(), std.heap.pageSize()),
            .wal_writers = wal_writers,
            .wal_battery = null,
            .wal_battery_lock = .unlocked,
        };
        errdefer self.compensators.deinit();

        try self.ring_factory.init(allocator, cfg.sqpoll_threads);
        errdefer self.ring_factory.deinit();
        try self.initGivenRing(&self.init_ring, 0);
        errdefer self.init_ring.deinit();

        try self.cross_slots.init(allocator, cfg.cross_task_slots);
        errdefer self.cross_slots.deinit();

        try self.snapshot_slots.init(allocator, cfg.snapshots.slots);
        errdefer self.snapshot_slots.deinit();
    }

    /// Releases the shared containers and the resources the init thread owns.
    ///
    /// Worker rings are owned by their threads and torn down there, so the
    /// caller must have joined all working threads first. Index inboxes are
    /// shared with the parent fronts and are released here, after every thread
    /// has stopped; uninitialized slots are skipped. The init ring goes last
    /// because it may be the poller master every worker ring attaches to.
    pub fn deinit(self: *Self) void {
        for (self.inboxes) |*inbox| inbox.deinit();

        // Live WAL writers outlive their index thread only in a failed
        // shutdown; release whichever are still registered.
        for (self.wal_writers) |maybe_writer| {
            const writer = maybe_writer orelse continue;
            _ = std.os.linux.close(writer.fd);
            self.allocator.destroy(writer);
        }
        self.allocator.free(self.wal_writers);
        if (self.wal_battery) |bytes| {
            wal.closeBattery(self.allocator, self.cfg.wal, bytes, std.heap.pageSize());
            self.wal_battery = null;
        }

        self.allocator.free(self.thread_ctx);
        self.allocator.free(self.threads);
        self.allocator.free(self.inboxes);
        self.allocator.free(self.rings);
        self.compensators.deinit();
        self.cross_slots.deinit();
        self.snapshot_slots.deinit();
        self.init_ring.deinit();
        self.ring_factory.deinit();
    }

    /// Spawns every working thread in role order, pinning fronts and indexes to
    /// their configured cores. Elephants have no configured mask and are left
    /// unpinned.
    pub fn spawnThreads(self: *Self) !void {
        const cfg = self.cfg;

        // The role is decided by the atomic counter inside each thread, so the
        // spawner cannot pin by slot. Every thread pins itself once it knows its
        // role; spawn order only has to match the role ranges in the counter.
        const total: usize = @as(usize, cfg.fronts) + cfg.indexes + cfg.elephants;
        for (0..total) |i| {
            self.thread_ctx[i] = .{ .ctrl = self, .spawn_idx = @intCast(i) };
            try self.threads[i].spawn(&self.thread_ctx[i], runThread);
            self.spawned += 1;
        }
    }

    /// Joins every spawned working thread. Only valid once every thread has
    /// left its service loop; joining a live thread blocks.
    pub fn joinThreads(self: *Self) void {
        for (self.threads[0..self.spawned]) |thread| thread.join();
    }

    /// The entry point of every working thread. It performs the thread-local
    /// part of phase A, reports `INITIALIZED` to the init ring and only then
    /// dispatches to the role logic. Any failure here is fatal by contract.
    ///
    /// The role comes from the atomic counter incremented at thread start, as
    /// docs/startup-en-reworked.md requires, and lives only on this thread's
    /// stack. Its ring index is the thread's slot in every shared array. A
    /// counter value outside the configured ranges is fatal: the formula and
    /// the configured role counts have diverged. The counter value does not
    /// have to match the spawn slot, because threads may reach the counter in
    /// any order; only the set of values must be complete.
    pub fn runThread(ctx: *ThreadContext) void {
        const self = ctx.ctrl;
        const ring_idx = self.getRingIdx() catch |err| {
            std.debug.print("role distribution failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };

        const role = self.roleOf(ring_idx);
        self.pinSelf(role);

        self.initRing(ring_idx, 1) catch |err| fatal("ring initialization", ring_idx, err);
        defer self.rings[ring_idx].deinit();

        const logger = self.getLogger(ring_idx) catch |err| fatal("logger creation", ring_idx, err);
        defer {
            logger.deinit(self.allocator);
            self.allocator.destroy(logger);
        }

        switch (role) {
            // An index creates its LLQ and publishes it before reporting.
            // The inbox is shared with the parent front, which may push into
            // it until it stops, so the controller releases it after every
            // thread has been joined; the index thread must not free it here.
            .index => |r| {
                self.initIndexInbox(r.inbox_idx, ring_idx) catch |err| fatal("index inbox initialization", ring_idx, err);
                // The battery belongs to the index threads: the first one to
                // start acquires it for every pair, the rest find it there.
                self.acquireWalBattery() catch |err| fatal("WAL battery acquisition", ring_idx, err);
            },
            .front, .elephant => {},
        }

        self.rings[ring_idx].ring.pushMsgRingFd(
            self.init_ring.ring.fd,
            messages.InitializedIdx,
            ring_idx,
            .{},
        ) catch |err| fatal("INITIALIZED report", ring_idx, err);

        switch (role) {
            .front => @import("front.zig").run(self, role, logger),
            .index => @import("index.zig").run(self, role, logger),
            .elephant => @import("elephant.zig").run(self, role, logger),
        }
    }

    /// Pins the calling thread to the core configured for its role. A failure
    /// is reported but not fatal: an unpinned thread still works correctly.
    fn pinSelf(self: *Self, role: Role) void {
        const core: u16 = switch (role) {
            .front => |r| self.cfg.front_cores.cores[r.ring_idx],
            .index => |r| self.cfg.index_cores.cores[r.inbox_idx],
            .elephant => return,
        };
        zigring.Thread.setSelfAffinity(core) catch |err| {
            std.debug.print("ring {d}: failed to pin to core {d}: {s}\n", .{ role.ringIdx(), core, @errorName(err) });
        };
    }

    fn fatal(what: []const u8, ring_idx: u16, err: anyerror) noreturn {
        std.debug.print("ring {d}: {s} failed: {s}\n", .{ ring_idx, what, @errorName(err) });
        std.process.exit(1);
    }

    /// Returns a logger and its buffer pool for the thread that owns the ring
    /// at `ring_idx`. The logging stuff is owned by the caller and needs both
    /// deinit and destroy.
    pub fn getLogger(self: *Self, ring_idx: u32) !*LoggerStuff {
        return self.getLoggerWithRing(&self.rings[ring_idx]);
    }

    /// Returns a logger for the initialization thread. The logging stuff is owned
    /// by the initialization thread itself and needs both deinit and destroy.
    pub fn getInitLogger(self: *Self) !*LoggerStuff {
        return self.getLoggerWithRing(&self.init_ring);
    }

    fn getLoggerWithRing(self: *Self, ring: *RingStuff) !*LoggerStuff {
        var logger = try self.allocator.create(LoggerStuff);
        errdefer self.allocator.destroy(logger);

        try logger.pool.init(self.allocator, self.cfg.logging.pool_capacity, self.cfg.logging.pool_frame_size);
        errdefer logger.pool.deinit();
        try logger.sink.init(self, self.cfg.logging, ring);
        logger.logger.init(&logger.pool, &logger.sink);

        return logger;
    }

    pub fn createLogFile(self: *Self, base_path: []const u8) !std.posix.fd_t {
        const allocator = self.allocator;

        const log_file = try std.fmt.allocPrintSentinel(allocator, "{s}.{d}.log", .{ base_path, zigring.monotonicNs() }, 0);
        defer allocator.free(log_file);

        const symlink_path = try std.fmt.allocPrintSentinel(allocator, "{s}.log", .{base_path}, 0);
        defer allocator.free(symlink_path);

        const fd_raw = std.os.linux.open(log_file, .{ .APPEND = true, .CREAT = true }, 0o644);
        const errno = std.os.linux.errno(fd_raw);
        if (errno != .SUCCESS) return std.posix.unexpectedErrno(errno);

        // Symlink, best effort. Better be created, but
        _ = std.os.linux.unlink(symlink_path);
        _ = std.os.linux.symlink(log_file, symlink_path);

        return @intCast(fd_raw);
    }

    /// The battery area of pair `pair`, acquiring the whole battery on first
    /// use. Cold by construction: only an index thread start and the cold open
    /// entries reach this.
    fn walArea(self: *Self, pair: usize) ![]u8 {
        try self.acquireWalBattery();
        const stride = self.wal_area_stride;
        return self.wal_battery.?[pair * stride ..][0..stride];
    }

    /// Acquires the battery once: plain mode allocates zeroed ordinary memory,
    /// PMEM mode maps the configured device as found. The areas outlive every
    /// WAL file, since files rotate over the same area epoch after epoch. The
    /// mapping carries the pair areas plus the temp section of snapshot rings,
    /// one ring per `snapshots.slots` (designs/SNAPSHOTS.md §2.2).
    pub fn acquireWalBattery(self: *Self) !void {
        while (!self.wal_battery_lock.tryLock()) std.Thread.yield() catch {};
        defer self.wal_battery_lock.unlock();
        if (self.wal_battery != null) return;

        self.wal_battery = try wal.openBattery(
            self.allocator,
            self.cfg.wal,
            self.wal_pairs + self.cfg.snapshots.slots,
            self.wal_area_stride,
            std.heap.pageSize(),
        );
    }

    /// The battery area slot of one pair, thread-major.
    fn walPairOf(self: *const Self, host_idx: u8, index_idx: u16) usize {
        const pair = wal.areaIndex(host_idx, index_idx, self.cfg.wal.hosts());
        std.debug.assert(pair < self.wal_pairs);
        return pair;
    }

    /// Opens an existing WAL file. Creation belongs to the elephant threads
    /// (designs/wal-impl.md §1.1), so a missing file surfaces the raw open
    /// error: fatal at startup, never repaired here.
    fn walOpenFile(self: *Self, path: [:0]const u8, write: bool) !posix.fd_t {
        _ = self;
        const flags: std.os.linux.O = .{ .ACCMODE = if (write) .RDWR else .RDONLY };
        const fd_raw = std.os.linux.open(path, flags, 0);
        const errno = std.os.linux.errno(fd_raw);
        if (errno != .SUCCESS) return switch (errno) {
            .NOENT => error.FileNotFound,
            .ACCES, .PERM => error.AccessDenied,
            else => |err| std.posix.unexpectedErrno(err),
        };
        return @intCast(fd_raw);
    }

    /// Opens the WAL of one data set for writing.
    ///
    /// Recovery and the walk are §C/§E: here the file is opened, the pair's
    /// battery view is wired into the writer and — PMEM mode — the chain the
    /// battery survived is walked, so `head`, the write position and the flush
    /// frontier resume where the crash left them (§3.4). Plain mode has no
    /// chain to walk: its battery is DRAM and gone, so the file's own parse is
    /// the only source. A second open of a triple that already has a live
    /// writer is `WalOpen`.
    pub fn walOpenWrite(self: *Self, host_idx: u8, index_idx: u16, tag: u128) !*wal.WalWriteFile {
        const pair = self.walPairOf(host_idx, index_idx);
        if (self.wal_writers[pair] != null) return error.WalOpen;

        const area = try self.walArea(pair);
        const dir = try self.indexDirPath(index_idx);
        defer self.allocator.free(dir);

        const path = try wal.walPath(self.allocator, dir, host_idx, index_idx, tag);
        defer self.allocator.free(path);

        const fd = try self.walOpenFile(path, true);
        errdefer _ = std.os.linux.close(fd);

        const writer = try self.allocator.create(wal.WalWriteFile);
        errdefer self.allocator.destroy(writer);

        writer.* = wal.WalWriteFile.init(
            fd,
            wal.Area.init(area, self.cfg.wal.buffers(), self.cfg.wal.lba()),
            self.cfg.wal,
            host_idx,
            index_idx,
            tag,
        );
        try writer.walk(try wal.fileSize(fd));
        self.wal_writers[pair] = writer;
        return writer;
    }

    /// Adopts the WAL descriptor the elephant threads created for a snapshot
    /// procedure: the window's new writer, opened over temp ring `slot_k`.
    ///
    /// The old writer stays open and stays the pair's registered writer for the
    /// window's duration — the temp ring dissolves the close-first objection
    /// (two writers would share the pair's one ring and collide); the old fd's
    /// close moves to the final-close elephant (designs/SNAPSHOTS.md §3.4).
    ///
    /// The ring is minted before the writer is wired: a temp ring is reused
    /// procedure after procedure, so every line a previous procedure left must
    /// classify as stale. `head_state` is the clone state `Y` — the chain
    /// anchor, never the name tag (§2.3): the ordinal-0 terminator carries it
    /// and the writer chains from it.
    ///
    /// Two adopts on the same `slot_k` while the first writer is alive is a
    /// caller bug; the caller (the composite) owns the writer and the slot
    /// exclusively from acquire to release, which is what makes the ring safe.
    pub fn walAdoptWrite(
        self: *Self,
        host_idx: u8,
        index_idx: u16,
        slot_k: u32,
        head_state: u128,
        fd: posix.fd_t,
    ) !*wal.WalWriteFile {
        _ = self.walPairOf(host_idx, index_idx);
        errdefer _ = std.os.linux.close(fd);

        const area = try self.walArea(wal.tempAreaIdx(slot_k, self.wal_pairs));
        wal.mintArea(area, self.cfg.wal.buffers(), self.cfg.wal.lba(), head_state, self.cfg.wal.isPmem());

        const writer = try self.allocator.create(wal.WalWriteFile);
        errdefer self.allocator.destroy(writer);

        writer.* = wal.WalWriteFile.init(
            fd,
            wal.Area.init(area, self.cfg.wal.buffers(), self.cfg.wal.lba()),
            self.cfg.wal,
            host_idx,
            index_idx,
            head_state,
        );
        writer.head = head_state;

        // `wal_writers[pair]` keeps the old writer: the caller owns this one.
        return writer;
    }

    /// The pair area's control line: the adoption mark's only home
    /// (designs/SNAPSHOTS.md §2.2).
    fn controlLine(self: *Self, host_idx: u8, index_idx: u16) !*wal.BufferHeader {
        const pair = self.walPairOf(host_idx, index_idx);
        const area = try self.walArea(pair);
        return wal.controlLineOf(area, self.cfg.wal.buffers(), self.cfg.wal.lba());
    }

    /// Rewrites the pair area's control line as the migration mark: the
    /// procedure is in flight on temp ring `k`, tagged `target_state` (§3.2
    /// step 1).
    ///
    /// The pointers are stored before the flag, so an in-flight mark is never
    /// read without the ring and the tag it names; one `CLWB`+`SFENCE` then
    /// lands the whole line in PMEM mode, and plain mode needs nothing — its
    /// battery is DRAM and the mark dies with the process (§3.5).
    pub fn publishAdoptionMark(
        self: *Self,
        host_idx: u8,
        index_idx: u16,
        k: u32,
        target_state: u128,
    ) !void {
        const line = try self.controlLine(host_idx, index_idx);
        line.new_wal_buffer_idx = @intCast(k);
        line.target_state = target_state;
        line.snapshot_in_progress = 1;
        if (self.cfg.wal.isPmem()) {
            barrier.clwb(line, @sizeOf(wal.BufferHeader));
            barrier.sfence();
        }
    }

    /// Zeroes the pair area's control line: the procedure is over, swapped or
    /// unwound, and no mark references temp ring `k` any more (§3.4, §8).
    pub fn clearAdoptionMark(self: *Self, host_idx: u8, index_idx: u16) !void {
        const line = try self.controlLine(host_idx, index_idx);
        line.* = std.mem.zeroes(wal.BufferHeader);
        if (self.cfg.wal.isPmem()) {
            barrier.clwb(line, @sizeOf(wal.BufferHeader));
            barrier.sfence();
        }
    }

    /// Copies temp ring `k`'s data and header arrays into the pair area: the
    /// swap's one move (§3.4), and the adoption rule's idempotent replay
    /// (§3.5).
    ///
    /// The control line is not part of the copy — the mark never travels
    /// between areas. The two extents are written back and fenced in PMEM
    /// mode; plain mode needs nothing, its durability being the file's. The
    /// pair's wired view is returned so the caller can re-slice the surviving
    /// writer onto it: the areas are geometrically identical by construction.
    pub fn copyTempIntoPair(self: *Self, pair: usize, k: u32) !wal.Area {
        const buffers = self.cfg.wal.buffers();
        const lba = self.cfg.wal.lba();

        const dst_bytes = try self.walArea(pair);
        const src_bytes = try self.walArea(wal.tempAreaIdx(k, self.wal_pairs));
        const dst = wal.Area.init(dst_bytes, buffers, lba);
        const src = wal.Area.init(src_bytes, buffers, lba);

        @memcpy(dst.data, src.data);
        @memcpy(std.mem.sliceAsBytes(dst.headers), std.mem.sliceAsBytes(src.headers));

        if (self.cfg.wal.isPmem()) {
            barrier.clwb(dst.data.ptr, dst.data.len);
            barrier.sfence();
            barrier.clwb(dst.headers.ptr, @sizeOf(wal.BufferHeader) * dst.headers.len);
            barrier.sfence();
        }
        return dst;
    }

    /// The adoption rule's branch (designs/SNAPSHOTS.md §3.5).
    pub const AdoptionResult = union(enum) {
        /// No mark: the pair is exactly what its files say.
        ordinary,
        /// The new pair won: ring `k` was copied into the pair and the mark
        /// cleared.
        adopted,
        /// The previous pair won: the mark is cleared and the bring-tail is
        /// pending with the ring and tag the mark named.
        aborted: struct { k: u32, tag: u128 },
    };

    /// Runs the adoption rule of one hosted pair: before any open of it.
    ///
    /// The mark lives on the pair area's control line; a plain battery is
    /// zeroed at allocation, so plain mode always lands on `.ordinary`
    /// without a mode branch. Otherwise the winning registry line decides: a
    /// line naming the marked tag means the migration reached its commit and
    /// the copy is finished forward (idempotent), anything else means the
    /// previous pair won and the abandoned pair may owe a surplus record
    /// (§3.5, §3.6).
    pub fn runAdoptionRule(self: *Self, host_idx: u8, index_idx: u16) !AdoptionResult {
        const line = try self.controlLine(host_idx, index_idx);
        if (line.snapshot_in_progress == 0) return .ordinary;

        const k: u32 = line.new_wal_buffer_idx;
        const tag: u128 = line.target_state;

        const entries = try self.loadRegistry(index_idx);
        defer if (entries) |list| self.freeRegistry(list);

        const winner = if (entries) |list| lastLineFor(list, host_idx) else null;
        if (winner) |entry| {
            if (wal.walTagFromPath(entry.wal_path)) |wal_tag| {
                if (wal_tag == tag) {
                    const pair = self.walPairOf(host_idx, index_idx);
                    _ = try self.copyTempIntoPair(pair, k);
                    try self.clearAdoptionMark(host_idx, index_idx);
                    return .adopted;
                }
            }
        }

        // The previous pair won — or no line landed, which names no new pair
        // either. Ring `k` needs no reclaim: the pool is process-global and
        // fresh at startup, so the temp ring is dead but harmless until some
        // later procedure mints it again (§3.4).
        try self.clearAdoptionMark(host_idx, index_idx);
        return .{ .aborted = .{ .k = k, .tag = tag } };
    }

    /// The bring-tail's collection: the abandoned pair's surplus records, held
    /// until the old writer's un-flushed tail is on disk (§3.6).
    ///
    /// The read sink borrows the op for its call only, so every record is
    /// copied into the collector; `deinit` releases them.
    pub const TailSink = struct {
        allocator: std.mem.Allocator,
        records: std.ArrayList(Record) = .empty,

        pub const Record = struct {
            state_idx: u128,
            op: []u8,
        };

        pub fn init(allocator: std.mem.Allocator) TailSink {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *TailSink) void {
            for (self.records.items) |record| self.allocator.free(record.op);
            self.records.deinit(self.allocator);
        }

        /// The read sink's `apply`.
        pub fn apply(ctx: ?*anyopaque, state_idx: u128, op: []const u8) anyerror!void {
            const self: *TailSink = @ptrCast(@alignCast(ctx.?));
            const owned = try self.allocator.dupe(u8, op);
            errdefer self.allocator.free(owned);
            try self.records.append(self.allocator, .{ .state_idx = state_idx, .op = owned });
        }
    };

    /// The abort branch's second act, PMEM only (§3.6): finds the one record
    /// the inter-write cut left new-side and brings it home.
    ///
    /// The abandoned pair is read the way recovery reads any pair — its new
    /// file's flushed bytes merged with temp ring `k`'s chain by ordinal. The
    /// old writer's un-flushed tail is flushed before the append, so the chain
    /// is empty and the record has the room a fresh ring would. A record at or
    /// below the old head is not brought: the composite wrote new first and
    /// old second, so every earlier record already reached the old chain, and
    /// the seek merely delivers the floor's own record.
    pub fn bringTail(
        self: *Self,
        host_idx: u8,
        index_idx: u16,
        k: u32,
        tag: u128,
        old_writer: *wal.WalWriteFile,
        head_before: u128,
        sink: *TailSink,
    ) !void {
        const dir = try self.indexDirPath(index_idx);
        defer self.allocator.free(dir);
        const path = try wal.walPath(self.allocator, dir, host_idx, index_idx, tag);
        defer self.allocator.free(path);

        const fd = self.walOpenFile(path, false) catch |err| switch (err) {
            // Retention, or a create that never reached the file: the new side
            // holds nothing the old one lacks.
            error.FileNotFound => return,
            else => return err,
        };
        defer _ = std.os.linux.close(fd);

        const temp = wal.Area.init(
            try self.walArea(wal.tempAreaIdx(k, self.wal_pairs)),
            self.cfg.wal.buffers(),
            self.cfg.wal.lba(),
        );
        var reader = wal.WalReadFile.init(fd, self.cfg.wal, temp, host_idx, index_idx, tag);
        const process = try reader.beginRead(self.allocator, .{ .seek_then_read = head_before }, .{
            .ctx = sink,
            .apply = TailSink.apply,
        });
        defer reader.endRead(self.allocator, process);
        try process.drive(null);

        // The seek is inclusive, so its floor's own record comes back with the
        // surplus; that record is already old-side (the composite wrote new
        // first and old second), which makes a cut-free abort a true no-op.
        var surplus: usize = 0;
        for (sink.records.items) |record| {
            if (record.state_idx > head_before) surplus += 1;
        }
        if (surplus == 0) return;

        old_writer.flushAndWait();
        for (sink.records.items) |record| {
            if (record.state_idx <= old_writer.head) continue;
            try old_writer.write(record.state_idx, old_writer.head, record.op);
        }
        old_writer.flushAndWait();
    }

    /// Opens the WAL of one data set for reading: the fd wrapper plus the
    /// pair's geometry, so a read operation walks the merged stream itself —
    /// the file's flushed bytes and, in PMEM mode, the battery's chain behind
    /// them (§5).
    pub fn walOpenRead(self: *Self, host_idx: u8, index_idx: u16, tag: u128) !*wal.WalReadFile {
        const pair = self.walPairOf(host_idx, index_idx);
        const dir = try self.indexDirPath(index_idx);
        defer self.allocator.free(dir);

        const path = try wal.walPath(self.allocator, dir, host_idx, index_idx, tag);
        defer self.allocator.free(path);

        // Plain mode's battery is DRAM: after a restart it holds nothing the
        // file does not, so the merged stream is the file alone there.
        const area: ?wal.Area = if (self.cfg.wal.isPmem())
            wal.Area.init(try self.walArea(pair), self.cfg.wal.buffers(), self.cfg.wal.lba())
        else
            null;

        const fd = try self.walOpenFile(path, false);
        errdefer _ = std.os.linux.close(fd);

        const reader = try self.allocator.create(wal.WalReadFile);
        errdefer self.allocator.destroy(reader);

        reader.* = wal.WalReadFile.init(fd, self.cfg.wal, area, host_idx, index_idx, tag);
        return reader;
    }

    /// Releases a reader acquired by `walOpenRead`.
    pub fn walCloseRead(self: *Self, reader: *wal.WalReadFile) void {
        _ = std.os.linux.close(reader.fd);
        self.allocator.destroy(reader);
    }

    /// Removes one WAL file. Idempotent by construction: a missing file is
    /// success, so retention never has to probe first.
    pub fn delete(self: *Self, host_idx: u8, index_idx: u16, tag: u128) !void {
        const dir = try self.indexDirPath(index_idx);
        defer self.allocator.free(dir);

        const path = try wal.walPath(self.allocator, dir, host_idx, index_idx, tag);
        defer self.allocator.free(path);

        const errno = std.os.linux.errno(std.os.linux.unlink(path));
        if (errno == .SUCCESS or errno == .NOENT) return;
        return std.posix.unexpectedErrno(errno);
    }

    /// The directory one index controls: its pair WAL files, its snapshots and
    /// its registry all live under it (designs/SNAPSHOTS.md §2.3).
    ///
    /// The template is pinned: `index.<index_idx>` in plain decimal, under the
    /// configured WAL root. Leaf names keep their globally unique spellings,
    /// so tools and retention keep working inside it.
    pub fn indexDirPath(self: *Self, index_idx: u16) ![]u8 {
        return std.fmt.allocPrint(
            self.allocator,
            "{s}/index.{d}",
            .{ self.cfg.wal.dir(), index_idx },
        );
    }

    /// The fixed registry leaf of one index: `<index dir>/registry.jsonl`.
    pub fn registryPath(self: *Self, index_idx: u16) ![:0]u8 {
        const dir = try self.indexDirPath(index_idx);
        defer self.allocator.free(dir);
        return std.fmt.allocPrintSentinel(self.allocator, "{s}/registry.jsonl", .{dir}, 0);
    }

    /// The fixed staging name of a registry rewrite: `<index dir>/registry.pending`.
    ///
    /// A constant, never a random temporary: a leftover from a crashed rewrite
    /// is junk the next rewrite truncates (designs/SNAPSHOTS.md §2.4).
    pub fn registryPendingPath(self: *Self, index_idx: u16) ![:0]u8 {
        const dir = try self.indexDirPath(index_idx);
        defer self.allocator.free(dir);
        return std.fmt.allocPrintSentinel(self.allocator, "{s}/registry.pending", .{dir}, 0);
    }

    /// Creates the index directory if it does not exist. Idempotent: an
    /// existing directory is success.
    pub fn ensureIndexDir(self: *Self, index_idx: u16) !void {
        const dir = try self.indexDirPath(index_idx);
        defer self.allocator.free(dir);

        const path = try self.allocator.dupeSentinel(u8, dir, 0);
        defer self.allocator.free(path);

        const errno = std.os.linux.errno(std.os.linux.mkdir(path, 0o755));
        if (errno == .SUCCESS or errno == .EXIST) return;
        return std.posix.unexpectedErrno(errno);
    }

    /// One committed snapshot line of a registry: the pair's latest snapshot
    /// and the WAL it hands over to (designs/SNAPSHOTS.md §2.4).
    ///
    /// The paths are heap copies on the controller's allocator; only
    /// `loadRegistry` creates entries, and `freeRegistry` releases them.
    pub const RegistryEntry = struct {
        host_idx: u8,
        snapshot_path: []u8,
        wal_path: []u8,
        state: u128,
    };

    /// The pinned four-key line as parsed, borrowing the input's strings.
    const RegistryLine = struct {
        host_idx: u8,
        snapshot_path: []const u8,
        wal_path: []const u8,
        state: u128,
    };

    /// The last line naming `host_idx`, the registry's precedence rule: a
    /// later line for the same host wins, lines naming other hosts are inert
    /// (§2.4).
    pub fn lastLineFor(entries: []RegistryEntry, host_idx: u8) ?*RegistryEntry {
        var found: ?*RegistryEntry = null;
        for (entries) |*entry| {
            if (entry.host_idx == host_idx) found = entry;
        }
        return found;
    }

    /// Reads one index's whole registry.
    ///
    /// A missing file is `null`, the absent-registry start (§2.4). Otherwise
    /// every line must parse: an unparseable one is `error.RegistryCorrupt`,
    /// the distinct fatality of both startup and functioning. I/O errors other
    /// than `NOENT` propagate — the caller owns the policy (startup treats
    /// them as "no registry", the rewrite as an ordinary failure).
    pub fn loadRegistry(self: *Self, index_idx: u16) !?[]RegistryEntry {
        const raw = (try self.readRegistryRaw(index_idx)) orelse return null;
        defer self.allocator.free(raw);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        var entries: std.ArrayList(RegistryEntry) = .empty;
        errdefer {
            for (entries.items) |entry| {
                self.allocator.free(entry.snapshot_path);
                self.allocator.free(entry.wal_path);
            }
            entries.deinit(self.allocator);
        }

        if (raw.len != 0) {
            var lines = std.mem.splitScalar(u8, registryText(raw), '\n');
            while (lines.next()) |line| {
                const parsed = try parseRegistryLine(arena.allocator(), line);

                const snapshot_path = try self.allocator.dupe(u8, parsed.snapshot_path);
                errdefer self.allocator.free(snapshot_path);
                const wal_path = try self.allocator.dupe(u8, parsed.wal_path);
                errdefer self.allocator.free(wal_path);

                try entries.append(self.allocator, .{
                    .host_idx = parsed.host_idx,
                    .snapshot_path = snapshot_path,
                    .wal_path = wal_path,
                    .state = parsed.state,
                });
            }
        }
        return try entries.toOwnedSlice(self.allocator);
    }

    /// Releases the entries `loadRegistry` returned with their paths.
    pub fn freeRegistry(self: *Self, entries: []RegistryEntry) void {
        for (entries) |entry| {
            self.allocator.free(entry.snapshot_path);
            self.allocator.free(entry.wal_path);
        }
        self.allocator.free(entries);
    }

    /// Rewrites one index's registry with `entry` as its newest line: read,
    /// compact, append, sync the staging file, rename it over the fixed name.
    ///
    /// This is the elephant's whole rewrite (§2.4), not an append — there is
    /// no append that could tear. The compaction keeps the last
    /// `snapshots.registry_keep` lines per hosted host and drops inert ones;
    /// kept lines are re-emitted verbatim. The `fdatasync` of the staging file
    /// is the commit point and precedes the completion message; the rename
    /// needs no directory sync, since after any crash either the old or the
    /// new content stands whole. `entry` borrows its paths for the render.
    pub fn rewriteRegistry(self: *Self, index_idx: u16, entry: RegistryEntry) !void {
        const read = try self.readRegistryRaw(index_idx);
        defer if (read) |bytes| self.allocator.free(bytes);
        const raw = read orelse "";

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);

        const keep: usize = @intCast(self.cfg.snapshots.registry_keep);
        const hosts = self.cfg.wal.hosts();

        // Compact by host, in host order: the last `keep` lines of each hosted
        // host survive, in their original order.
        if (raw.len != 0) {
            var host: u32 = 0;
            while (host < hosts) : (host += 1) {
                var total: usize = 0;
                var lines = std.mem.splitScalar(u8, registryText(raw), '\n');
                while (lines.next()) |line| {
                    const parsed = try parseRegistryLine(arena.allocator(), line);
                    if (@as(u32, parsed.host_idx) == host) total += 1;
                }
                if (total == 0) continue;

                var skip = if (total > keep) total - keep else 0;
                lines = std.mem.splitScalar(u8, registryText(raw), '\n');
                while (lines.next()) |line| {
                    const parsed = try parseRegistryLine(arena.allocator(), line);
                    if (@as(u32, parsed.host_idx) != host) continue;
                    if (skip > 0) {
                        skip -= 1;
                        continue;
                    }
                    try out.appendSlice(self.allocator, line);
                    try out.append(self.allocator, '\n');
                }
            }
        }

        const rendered = try std.fmt.allocPrint(
            self.allocator,
            "{{\"host_idx\":{d},\"snapshot_path\":\"{s}\",\"wal_path\":\"{s}\",\"state\":{d}}}\n",
            .{ entry.host_idx, entry.snapshot_path, entry.wal_path, entry.state },
        );
        defer self.allocator.free(rendered);
        try out.appendSlice(self.allocator, rendered);

        try self.ensureIndexDir(index_idx);

        const pending_path = try self.registryPendingPath(index_idx);
        defer self.allocator.free(pending_path);

        const fd_raw = std.os.linux.open(pending_path, .{
            .ACCMODE = .RDWR,
            .CREAT = true,
            .TRUNC = true,
        }, 0o644);
        const errno = std.os.linux.errno(fd_raw);
        if (errno != .SUCCESS) return std.posix.unexpectedErrno(errno);
        const fd: posix.fd_t = @intCast(fd_raw);

        self.writeAll(fd, out.items) catch |err| {
            _ = std.os.linux.close(fd);
            return err;
        };
        self.syncAll(fd) catch |err| {
            _ = std.os.linux.close(fd);
            return err;
        };
        const closed = std.os.linux.errno(std.os.linux.close(fd));
        if (closed != .SUCCESS) return std.posix.unexpectedErrno(closed);

        // The seam: the staging file and its `fdatasync` are the commit point,
        // and failing here leaves the fixed name's previous content whole.
        if (self.test_fail_registry_rename) return error.RegistryRenameFailed;

        const fixed_path = try self.registryPath(index_idx);
        defer self.allocator.free(fixed_path);

        const renamed = std.os.linux.errno(std.os.linux.rename(pending_path, fixed_path));
        if (renamed != .SUCCESS) return std.posix.unexpectedErrno(renamed);
    }

    /// Reads one index's registry file whole, `null` when it does not exist.
    fn readRegistryRaw(self: *Self, index_idx: u16) !?[]u8 {
        const path = try self.registryPath(index_idx);
        defer self.allocator.free(path);

        const fd = self.walOpenFile(path, false) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer _ = std.os.linux.close(fd);

        const size = try wal.fileSize(fd);
        if (size == 0) return try self.allocator.alloc(u8, 0);

        const bytes = try self.allocator.alloc(u8, @intCast(size));
        errdefer self.allocator.free(bytes);

        var got: usize = 0;
        while (got < bytes.len) {
            const at: posix.off_t = @intCast(got);
            const res = std.os.linux.pread(fd, bytes[got..].ptr, bytes.len - got, at);
            const errno = std.os.linux.errno(res);
            if (errno != .SUCCESS) return std.posix.unexpectedErrno(errno);
            if (res == 0) return error.EndOfStream;
            got += res;
        }
        return bytes;
    }

    /// The registry's line text: the file minus its one trailing newline, so
    /// the split yields no empty final line to parse.
    fn registryText(raw: []const u8) []const u8 {
        if (std.mem.endsWith(u8, raw, "\n")) return raw[0 .. raw.len - 1];
        return raw;
    }

    /// Parses one registry line, `error.RegistryCorrupt` for anything that is
    /// not the pinned four-key shape.
    fn parseRegistryLine(allocator: std.mem.Allocator, line: []const u8) !RegistryLine {
        if (line.len == 0) return error.RegistryCorrupt;
        return std.json.parseFromSliceLeaky(RegistryLine, allocator, line, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.RegistryCorrupt,
        };
    }

    /// Writes every byte of `bytes` into `fd`.
    fn writeAll(self: *Self, fd: posix.fd_t, bytes: []const u8) !void {
        _ = self;
        var done: usize = 0;
        while (done < bytes.len) {
            const res = std.os.linux.write(fd, bytes[done..].ptr, bytes.len - done);
            const errno = std.os.linux.errno(res);
            if (errno != .SUCCESS) return std.posix.unexpectedErrno(errno);
            if (res == 0) return error.WriteZero;
            done += res;
        }
    }

    /// The rewrite's one barrier: the staging file reaches the device before
    /// the rename and the completion message.
    fn syncAll(self: *Self, fd: posix.fd_t) !void {
        _ = self;
        const errno = std.os.linux.errno(std.os.linux.fdatasync(fd));
        if (errno != .SUCCESS) return std.posix.unexpectedErrno(errno);
    }

    /// Returned when `getRingIdx` is not used properly.
    pub const RoleDistributionError = error{
        /// When we did too much `getRingIdx` exceeding an amount of planned subjects (fronts, indexes, elephants).
        Overflow,
    };

    /// Returns the `ring_idx` this thread takes from the rolling counter. This
    /// distribution does as follows:
    ///
    /// ```
    /// when ring_idx {
    ///   [0..fronts) => .front
    ///   [fronts, fronts + indexes) => .index
    ///   [fronts + indexes, fronts + indexes + elephants) => .elephant
    /// }
    /// ```
    ///
    /// The role itself is derived by `roleOf` from the returned index.
    pub fn getRingIdx(self: *Self) RoleDistributionError!u16 {
        const role_idx = @atomicRmw(u32, &self.rolling_role_idx, .Add, 1, .monotonic);
        // role_idx never overflows 0xFFFF as was checked by the config validation.
        const idx: u16 = @truncate(role_idx);
        if (idx >= self.subjectCount()) return RoleDistributionError.Overflow;
        return idx;
    }

    fn subjectCount(self: *const Self) u16 {
        return self.cfg.fronts + self.cfg.indexes + self.cfg.elephants;
    }

    /// Returns the role of the thread owning `ring_idx`. Every subject has a
    /// role, and `ring_idx` is always in `[0, subjects)` because both the
    /// spawning side and `getRingIdx` guarantee it. Public so the process
    /// thread can name its workers without reading anything back from them.
    pub fn roleOf(self: *const Self, ring_idx: u16) Role {
        const idx = ring_idx;

        const index_per_front = self.cfg.indexes / self.cfg.fronts;
        if (idx < self.cfg.fronts) {
            return .{
                .front = .{
                    .ring_idx = idx,
                    .first_index = .{
                        .ring_idx = idx * index_per_front + self.cfg.fronts,
                        .inbox_idx = idx * index_per_front,
                    },
                    .index_count = index_per_front,
                },
            };
        }

        var domain_idx = idx - self.cfg.fronts;
        if (domain_idx < self.cfg.indexes) {
            return .{
                .index = .{
                    .ring_idx = idx,
                    .inbox_idx = domain_idx,
                    .front_idx = domain_idx / index_per_front,
                },
            };
        }

        domain_idx -= self.cfg.indexes;
        if (domain_idx < self.cfg.elephants) {
            return .{
                .elephant = .{
                    .ring_idx = idx,
                },
            };
        }

        unreachable;
    }

    /// Initializes a ring and its related stuff for a thread with the given ring index.
    pub fn initRing(self: *Self, ring_idx: u32, weight: u32) !void {
        return self.initGivenRing(&self.rings[ring_idx], weight);
    }

    fn initGivenRing(self: *Self, stuff: *RingStuff, weight: u32) !void {
        stuff.ready = false;
        try self.ring_factory.acquireRing(&stuff.ring, self.cfg.queue_depth, weight);
        errdefer stuff.ring.deinit();
        stuff.ring.streamedSQ(&stuff.sqstream);
        try stuff.slots.init(self.allocator, self.cfg.ring_slots_capacity);
        stuff.ready = true;
    }

    /// Creates, binds and listens on the server socket described by the
    /// config. The descriptor is owned by the controller's process thread and
    /// is shared with all fronts through `START_WORK`.
    pub fn createServerSocket(self: *Self) !std.posix.fd_t {
        const cfg = self.cfg;

        // The config names an IPv4 endpoint; `localhost` is accepted as the
        // loopback spelling used by the default document.
        const ip = if (std.mem.eql(u8, cfg.bind, "localhost"))
            std.Io.net.Ip4Address.loopback(cfg.port)
        else
            try std.Io.net.Ip4Address.parse(cfg.bind, cfg.port);

        const fd = try zigring.createTCPServerSocket();
        errdefer _ = std.os.linux.close(fd);

        const addr = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, ip.port),
            .addr = @bitCast(ip.bytes),
        };

        const bind_res = std.os.linux.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));
        if (std.os.linux.errno(bind_res) != .SUCCESS) {
            return posix.unexpectedErrno(std.os.linux.errno(bind_res));
        }

        const listen_res = std.os.linux.listen(fd, cfg.accept_backlog);
        if (std.os.linux.errno(listen_res) != .SUCCESS) {
            return posix.unexpectedErrno(std.os.linux.errno(listen_res));
        }

        return fd;
    }

    /// Initializes an input inbox for the given index thread. The producer ring
    /// is attached later by the owning front, after the startup barrier.
    pub fn initIndexInbox(self: *Self, inbox_idx: u32, ring_idx: u32) !void {
        try self.inboxes[inbox_idx].init(
            self.allocator,
            self.cfg.index_inbox_capacity,
            &self.rings[ring_idx].ring,
        );
    }

    // ========================================================================
    // Index state: active sessions and the replay queue.
    //
    // Every behavioral function of the index state lives here because it needs
    // resources (memory and the compensator registry). The data sets are
    // thread-local and owned by the index thread's service loop; the methods
    // below are called only from that thread, except the dump, which the
    // elephant runs over a clone.
    // ========================================================================

    /// A session brought back from the replay queue: the freshly minted id and
    /// the active session inserted under it.
    pub const Reactivated = struct {
        new_id: u128,
        session: *state.Session,
    };

    pub const IndexError = error{
        OutOfMemory,
        UnknownCompensator,
        UnknownSession,
    };

    /// Initializes one data set. The caller assigns `st.state` before the
    /// first op; the loader's caller does the same from the snapshot's
    /// file-name tag.
    pub fn initIndexState(self: *Self, st: *state.IndexState) !void {
        st.* = .{
            .state = 0,
            .sessions = state.SessionsMap.init(self.allocator),
            .replay_queue = replay_queue.ReplayQueue.init(self.allocator),
        };
    }

    /// Releases one data set: every active session, the map, and every blob
    /// the replay queue still holds.
    pub fn deinitIndexState(self: *Self, st: *state.IndexState) void {
        var it = st.sessions.iterator();
        while (it.next()) |bucket| self.freeSession(bucket.val);
        st.sessions.deinit();
        st.replay_queue.deinit();
        st.* = undefined;
    }

    /// Applies one accepted op. The caller (the consensus driver) has already
    /// set `st.state` to this op's state; `create` mints the session id from
    /// it.
    pub fn applyIndexOp(self: *Self, st: *state.IndexState, op: state.Op) IndexError!void {
        switch (op) {
            .create => |create| {
                // Validate before any state change: an unknown name rejects
                // the op and leaves the data set exactly as it was.
                if (!self.validateCompensator(create.compensator)) return error.UnknownCompensator;

                const id = st.state;

                const compensator = try self.allocator.dupe(u8, create.compensator);
                errdefer self.allocator.free(compensator);

                const chunk_len = uvarintLen(create.payload.len) + create.payload.len;
                const backing = try self.allocator.alloc(u8, chunk_len);
                errdefer self.allocator.free(backing);
                const written = putUvarint(backing, create.payload.len) catch unreachable;
                @memcpy(backing[written..][0..create.payload.len], create.payload);

                const session = try self.allocator.create(state.Session);
                errdefer self.allocator.destroy(session);
                session.* = .{
                    .id = id,
                    .index_idx = id,
                    .upgrade_idx = id,
                    .wheel_idx = 0,
                    .state = .ExpectOp,
                    .consensus_progress = .{},
                    .data = .{
                        .original_id = id,
                        .compensator = compensator,
                        .retry_count = 0,
                        .data = .{ .backing = backing, .len = chunk_len },
                    },
                };

                try st.sessions.put(id, session);
            },
            .append => |append| {
                const session = st.sessions.get(append.session_id) orelse
                    return error.UnknownSession;

                const chunk_len = uvarintLen(append.payload.len) + append.payload.len;
                const new_len = session.data.data.len + chunk_len;

                if (new_len > session.data.data.backing.len) {
                    var new_capacity = @max(session.data.data.backing.len, 16);
                    while (new_capacity < new_len) {
                        new_capacity = std.math.mul(usize, new_capacity, 2) catch new_len;
                    }
                    session.data.data.backing = try self.allocator.realloc(
                        session.data.data.backing,
                        new_capacity,
                    );
                }

                const at = session.data.data.len;
                const written = putUvarint(session.data.data.backing[at..], append.payload.len) catch unreachable;
                @memcpy(session.data.data.backing[at + written ..][0..append.payload.len], append.payload);
                session.data.data.len = new_len;
            },
            .overwrite => |overwrite| {
                const session = st.sessions.get(overwrite.session_id) orelse
                    return error.UnknownSession;

                const chunk_len = uvarintLen(overwrite.payload.len) + overwrite.payload.len;
                const backing = try self.allocator.alloc(u8, chunk_len);
                errdefer self.allocator.free(backing);
                const written = putUvarint(backing, overwrite.payload.len) catch unreachable;
                @memcpy(backing[written..][0..overwrite.payload.len], overwrite.payload);

                self.allocator.free(session.data.data.backing);
                session.data.data = .{ .backing = backing, .len = chunk_len };
            },
            .close => |close| {
                if (st.sessions.get(close.session_id)) |session| {
                    _ = st.sessions.remove(close.session_id);
                    self.freeSession(session);
                } else if (try st.replay_queue.removeSessionId(close.session_id)) |blob| {
                    self.allocator.free(blob);
                } else {
                    return error.UnknownSession;
                }
            },
            .restart_in => |restart| {
                const session = st.sessions.get(restart.session_id) orelse
                    return error.UnknownSession;

                const sd_bytes = try self.encodeSessionData(&session.data);
                defer self.allocator.free(sd_bytes);

                const retry_time = nowRealtimeNs() +
                    @as(u64, restart.seconds) * std.time.ns_per_s;
                const blob = try self.makeReplayBlob(retry_time, restart.session_id, sd_bytes);
                defer self.allocator.free(blob);

                try st.replay_queue.push(blob);

                // The session's content lives in the blob now.
                _ = st.sessions.remove(restart.session_id);
                self.freeSession(session);
            },
        }
    }

    /// The head drain: take the first blob out of the queue, decode it, mint
    /// the envelope a fresh id from `st.state`, and re-insert it as an active
    /// session. No time logic inside; the caller compared the head's recorded
    /// retry time against its own clock. Deterministic: the same queue and the
    /// same state yield the same result.
    pub fn popReplayHead(self: *Self, st: *state.IndexState) !?Reactivated {
        const blob = (try st.replay_queue.pop()) orelse return null;
        defer self.allocator.free(blob);

        if (blob.len < replay_queue.BLOB_HEAD + 1) return error.CorruptInput;

        const sd_len_res = try readUvarint(blob[replay_queue.BLOB_HEAD..]);
        const sd_len = std.math.cast(usize, sd_len_res.value) orelse return error.CorruptInput;
        const body_off = replay_queue.BLOB_HEAD + sd_len_res.len;
        if (body_off > blob.len or blob.len - body_off != sd_len) return error.CorruptInput;

        const sd = try self.decodeSessionData(blob[body_off..][0..sd_len]);
        errdefer {
            self.allocator.free(sd.compensator);
            self.allocator.free(sd.data.backing);
        }

        const new_id = st.state;
        const session = try self.allocator.create(state.Session);
        errdefer self.allocator.destroy(session);
        session.* = .{
            .id = new_id,
            .index_idx = new_id,
            .upgrade_idx = new_id,
            .wheel_idx = 0,
            .state = .ExpectOp,
            .consensus_progress = .{},
            .data = sd,
        };

        try st.sessions.put(new_id, session);
        return .{ .new_id = new_id, .session = session };
    }

    /// The whole-state dump. Sessions come in map iteration order; the queue
    /// is emitted in `(retry_time, session_id)` order.
    pub fn dumpIndexState(
        self: *Self,
        st: *const state.IndexState,
        out: *std.ArrayList(u8),
    ) !void {
        // The output rides the dump's own allocator: for a clone that is the
        // elephant's arena, so one reset releases the clone and the snapshot.
        const output_allocator = st.replay_queue.allocator;

        var version: [2]u8 = undefined;
        std.mem.writeInt(u16, &version, state.SNAPSHOT_VERSION, .little);
        try out.appendSlice(output_allocator, &version);

        var count_buf: [10]u8 = undefined;
        const count_len = try putUvarint(&count_buf, st.sessions.count());
        try out.appendSlice(output_allocator, count_buf[0..count_len]);

        var it = st.sessions.iterator();
        while (it.next()) |bucket| {
            const sd_bytes = try self.encodeSessionData(&bucket.val.data);
            defer self.allocator.free(sd_bytes);

            var id_buf: [16]u8 = undefined;
            std.mem.writeInt(u128, &id_buf, bucket.key, .little);
            try out.appendSlice(output_allocator, &id_buf);

            var len_buf: [10]u8 = undefined;
            const len_len = try putUvarint(&len_buf, sd_bytes.len);
            try out.appendSlice(output_allocator, len_buf[0..len_len]);
            try out.appendSlice(output_allocator, sd_bytes);
        }

        const queue_allocator = st.replay_queue.allocator;
        const handles = try @constCast(&st.replay_queue).snapshotHandles();
        defer queue_allocator.free(handles);
        std.mem.sort([]u8, handles, {}, blobLessThan);

        var queue_count_buf: [10]u8 = undefined;
        const queue_count_len = try putUvarint(&queue_count_buf, handles.len);
        try out.appendSlice(output_allocator, queue_count_buf[0..queue_count_len]);
        for (handles) |blob| try out.appendSlice(output_allocator, blob);
    }

    /// The inverse of `dumpIndexState`. Rejects unknown versions with
    /// `error.UnsupportedVersion` and malformed bytes with
    /// `error.CorruptInput`, including a queue section that is not in queue
    /// order. The caller sets `st.state` afterwards from the snapshot file's
    /// name tag.
    pub fn loadIndexState(self: *Self, bytes: []const u8) !state.IndexState {
        if (bytes.len < 2) return error.CorruptInput;
        const version = std.mem.readInt(u16, bytes[0..2], .little);
        if (version != state.SNAPSHOT_VERSION) return error.UnsupportedVersion;

        var st: state.IndexState = undefined;
        try self.initIndexState(&st);
        errdefer self.deinitIndexState(&st);

        var pos: usize = 2;

        const count_res = try readUvarint(bytes[pos..]);
        pos += count_res.len;
        const count = std.math.cast(usize, count_res.value) orelse return error.CorruptInput;

        var i: usize = 0;
        while (i < count) : (i += 1) {
            if (bytes.len - pos < 16) return error.CorruptInput;
            const id = std.mem.readInt(u128, bytes[pos..][0..16], .little);
            pos += 16;

            const len_res = try readUvarint(bytes[pos..]);
            pos += len_res.len;
            const sd_len = std.math.cast(usize, len_res.value) orelse return error.CorruptInput;
            if (bytes.len - pos < sd_len) return error.CorruptInput;

            const sd = try self.decodeSessionData(bytes[pos..][0..sd_len]);
            pos += sd_len;

            const session = try self.allocator.create(state.Session);
            errdefer self.allocator.destroy(session);
            session.* = .{
                .id = id,
                .index_idx = 0,
                .upgrade_idx = 0,
                .wheel_idx = 0,
                .state = .ExpectOp,
                .consensus_progress = .{},
                .data = sd,
            };
            try st.sessions.put(id, session);
        }

        const queue_count_res = try readUvarint(bytes[pos..]);
        pos += queue_count_res.len;
        const queue_count = std.math.cast(usize, queue_count_res.value) orelse return error.CorruptInput;

        var previous: ?[]const u8 = null;
        var q: usize = 0;
        while (q < queue_count) : (q += 1) {
            if (bytes.len - pos < replay_queue.BLOB_HEAD + 1) return error.CorruptInput;

            const sd_len_res = try readUvarint(bytes[pos + replay_queue.BLOB_HEAD ..]);
            const sd_len = std.math.cast(usize, sd_len_res.value) orelse return error.CorruptInput;
            const blob_len = replay_queue.BLOB_HEAD + sd_len_res.len + sd_len;
            if (bytes.len - pos < blob_len) return error.CorruptInput;

            const blob = bytes[pos..][0..blob_len];
            if (previous) |prev| {
                if (replay_queue.blobOrder({}, @constCast(prev), @constCast(blob)) == .gt) {
                    return error.CorruptInput;
                }
            }

            try st.replay_queue.push(blob);
            previous = blob;
            pos += blob_len;
        }

        if (pos != bytes.len) return error.CorruptInput;
        return st;
    }

    /// The snapshot seam: deep-copies the own data set into the caller's
    /// arena. Every `Session` (the struct, the session-owned compensator name
    /// bytes, the `Buffer` backing of `data.data`) and every replay blob is
    /// copied into arena memory; the result shares no allocation with the live
    /// state. The caller releases the clone and the dump buffer together with
    /// one `arena.reset(.free_all)`.
    pub fn cloneIndexState(
        self: *Self,
        st: *const state.IndexState,
        arena: std.mem.Allocator,
    ) !state.IndexState {
        _ = self;
        var clone: state.IndexState = .{
            .state = st.state,
            .sessions = state.SessionsMap.init(arena),
            .replay_queue = replay_queue.ReplayQueue.init(arena),
        };

        var it = st.sessions.iterator();
        while (it.next()) |bucket| {
            const source = bucket.val;
            const session = try arena.create(state.Session);
            session.* = source.*;
            session.data.compensator = try arena.dupe(u8, source.data.compensator);
            session.data.data.backing = try arena.dupe(u8, source.data.data.backing);
            try clone.sessions.put(bucket.key, session);
        }

        const source_allocator = st.replay_queue.allocator;
        const handles = try @constCast(&st.replay_queue).snapshotHandles();
        defer source_allocator.free(handles);
        for (handles) |blob| try clone.replay_queue.push(blob);

        return clone;
    }

    /// Mints one snapshot procedure's job: the shell, its arena, and the two
    /// paths the procedure's files will carry.
    ///
    /// Both paths are rendered under the originating index's directory with
    /// the pair's identity and the tag `X` — the state at the first dispatch,
    /// fixed for the whole procedure (§2.3). The caller owns the job from here
    /// to `releaseSnapshotJob`; the arena is live and empty, and `clone` is
    /// undefined until the handler pass fills it.
    pub fn mintSnapshotJob(
        self: *Self,
        host_idx: u8,
        index_idx: u16,
        tag: u128,
        k: u32,
        ring_idx: u16,
    ) !*SnapshotJob {
        const job = try self.allocator.create(SnapshotJob);
        errdefer self.allocator.destroy(job);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();

        const dir = try self.indexDirPath(index_idx);
        defer self.allocator.free(dir);

        const wal_path = try wal.walPath(self.allocator, dir, host_idx, index_idx, tag);
        errdefer self.allocator.free(wal_path);
        const snapshot_path = try wal.snapshotPath(self.allocator, dir, host_idx, index_idx, tag);
        errdefer self.allocator.free(snapshot_path);

        job.* = .{
            .arena = arena,
            .clone = undefined,
            .host_idx = host_idx,
            .index_idx = index_idx,
            .ring_idx = ring_idx,
            .tag = tag,
            .k = k,
            .phase = .create_sent,
            .fd = -1,
            .old_fd = -1,
            .wal_path = wal_path,
            .snapshot_path = snapshot_path,
        };
        return job;
    }

    /// Releases a job the procedure is done with: the arena and anything the
    /// dump left in it, both paths, the shell.
    ///
    /// The terminal elephant is the only caller (§3.3, §3.4): the index thread
    /// stops dereferencing the job at its last dispatch.
    pub fn releaseSnapshotJob(self: *Self, job: *SnapshotJob) void {
        job.arena.deinit();
        self.allocator.free(job.wal_path);
        self.allocator.free(job.snapshot_path);
        self.allocator.destroy(job);
    }

    /// The next elephant ring, in round-robin order over all elephants.
    ///
    /// One atomic cursor shared by every dispatching thread: a procedure's
    /// successive picks land on different elephants, which is what the design
    /// wants, and the rarity of the tasks makes the contention a non-issue
    /// (§2.1). With one elephant there is no choice.
    pub fn nextElephantRing(self: *Self) u16 {
        std.debug.assert(self.cfg.elephants > 0);
        const first: u32 = @as(u32, self.cfg.fronts) + self.cfg.indexes;
        const cursor = self.elephant_cursor.fetchAdd(1, .monotonic);
        return @intCast(first + cursor % self.cfg.elephants);
    }

    pub fn validateCompensator(self: *const Self, name: []const u8) bool {
        return self.compensators.contains(name);
    }

    /// Encodes the persisted part of a session: `original_id`,
    /// `uvarint(compensator.len) || compensator`, `retry_count`, and
    /// `uvarint(data.len) || data`.
    pub fn encodeSessionData(self: *Self, sd: *const state.SessionData) ![]u8 {
        const comp_len = uvarintLen(sd.compensator.len);
        const data_len = uvarintLen(sd.data.len);
        const total = 16 + comp_len + sd.compensator.len + 4 + data_len + sd.data.len;

        const buf = try self.allocator.alloc(u8, total);
        errdefer self.allocator.free(buf);

        var pos: usize = 0;
        std.mem.writeInt(u128, buf[pos..][0..16], sd.original_id, .little);
        pos += 16;

        pos += putUvarint(buf[pos..], sd.compensator.len) catch unreachable;
        @memcpy(buf[pos..][0..sd.compensator.len], sd.compensator);
        pos += sd.compensator.len;

        std.mem.writeInt(u32, buf[pos..][0..4], sd.retry_count, .little);
        pos += 4;

        pos += putUvarint(buf[pos..], sd.data.len) catch unreachable;
        @memcpy(buf[pos..][0..sd.data.len], sd.data.backing[0..sd.data.len]);
        pos += sd.data.len;

        std.debug.assert(pos == total);
        return buf;
    }

    /// Decodes a `SessionData` produced by `encodeSessionData`. The caller
    /// owns the compensator bytes and the buffer backing.
    pub fn decodeSessionData(self: *Self, bytes: []const u8) !state.SessionData {
        var pos: usize = 0;
        if (bytes.len < 16) return error.CorruptInput;

        const original_id = std.mem.readInt(u128, bytes[pos..][0..16], .little);
        pos += 16;

        const comp_res = try readUvarint(bytes[pos..]);
        pos += comp_res.len;
        const comp_len = std.math.cast(usize, comp_res.value) orelse return error.CorruptInput;
        if (bytes.len - pos < comp_len) return error.CorruptInput;
        const compensator = try self.allocator.dupe(u8, bytes[pos..][0..comp_len]);
        errdefer self.allocator.free(compensator);
        pos += comp_len;

        if (bytes.len - pos < 4) return error.CorruptInput;
        const retry_count = std.mem.readInt(u32, bytes[pos..][0..4], .little);
        pos += 4;

        const data_res = try readUvarint(bytes[pos..]);
        pos += data_res.len;
        const data_len = std.math.cast(usize, data_res.value) orelse return error.CorruptInput;
        if (bytes.len - pos < data_len) return error.CorruptInput;
        const backing = try self.allocator.dupe(u8, bytes[pos..][0..data_len]);
        errdefer self.allocator.free(backing);
        pos += data_len;

        if (pos != bytes.len) return error.CorruptInput;

        return .{
            .original_id = original_id,
            .compensator = compensator,
            .retry_count = retry_count,
            .data = .{ .backing = backing, .len = data_len },
        };
    }

    /// Builds a replay blob: the 24-byte head, then the length-prefixed
    /// `SessionData` codec bytes.
    pub fn makeReplayBlob(
        self: *Self,
        retry_time: u64,
        session_id: u128,
        sd_bytes: []const u8,
    ) ![]u8 {
        const total = replay_queue.BLOB_HEAD + uvarintLen(sd_bytes.len) + sd_bytes.len;
        const blob = try self.allocator.alloc(u8, total);
        errdefer self.allocator.free(blob);

        std.mem.writeInt(u64, blob[replay_queue.RETRY_TIME_OFF..][0..8], retry_time, .little);
        std.mem.writeInt(u128, blob[replay_queue.SESSION_ID_OFF..][0..16], session_id, .little);

        const written = putUvarint(blob[replay_queue.BLOB_HEAD..], sd_bytes.len) catch unreachable;
        const body = replay_queue.BLOB_HEAD + written;
        @memcpy(blob[body..][0..sd_bytes.len], sd_bytes);

        return blob;
    }

    fn freeSession(self: *Self, session: *state.Session) void {
        self.allocator.free(session.data.compensator);
        self.allocator.free(session.data.data.backing);
        self.allocator.destroy(session);
    }

    fn blobLessThan(_: void, a: []u8, b: []u8) bool {
        return replay_queue.blobOrder({}, a, b) == .lt;
    }
};

/// Writes a base-128 varint into `buf` and returns its length.
///
/// This is the one uvarint implementation in the tree: the index-state codecs
/// and the WAL record framing (`src/wal.zig`) both come through it.
pub fn putUvarint(buf: []u8, v: u64) !usize {
    var value = v;
    var i: usize = 0;
    while (value >= 0x80) {
        if (i >= buf.len) return error.BufferTooSmall;
        buf[i] = @as(u8, @truncate(value)) | 0x80;
        value >>= 7;
        i += 1;
    }
    if (i >= buf.len) return error.BufferTooSmall;
    buf[i] = @truncate(value);
    return i + 1;
}

/// Reads one base-128 varint and returns its value and encoded length.
pub fn readUvarint(buf: []const u8) !struct { value: u64, len: usize } {
    var value: u64 = 0;
    var shift: u32 = 0;
    var i: usize = 0;

    while (i < buf.len) : (i += 1) {
        const byte = buf[i];
        if (shift >= 64) return error.CorruptInput;

        const bits: u64 = byte & 0x7f;
        if (shift == 63 and bits > 1) return error.CorruptInput;
        value |= bits << @as(u6, @intCast(shift));

        if (byte & 0x80 == 0) {
            return .{ .value = value, .len = i + 1 };
        }
        shift += 7;
    }

    return error.CorruptInput;
}

/// The encoded length of `v` as a base-128 varint.
pub fn uvarintLen(v: u64) usize {
    var value = v;
    var len: usize = 1;
    while (value >= 0x80) : (value >>= 7) len += 1;
    return len;
}

/// CLOCK_REALTIME nanoseconds. The queue's due times must survive a dump and
/// reload across a restart, so monotonic is wrong here; zigring's
/// `monotonicNs()` is deliberately not used.
pub fn nowRealtimeNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    const res = std.os.linux.clock_gettime(.REALTIME, &ts);
    if (res != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Fixed context of one working thread, handed to it at spawn time. The role
/// is derived by the thread itself from the rolling counter and never leaves
/// its stack.
pub const ThreadContext = struct {
    ctrl: *Controller,
    /// The slot this thread was spawned into, which is also the `ring_idx` it
    /// must compute. Kept for the startup cross-check only.
    spawn_idx: u16,
};

/// Thread role description.
pub const Role = union(enum) {
    /// Ring and inbox index of one index thread. Rings for indexes go right
    /// after the rings for fronts, and inboxes exist for index threads only.
    pub const IndexIdx = struct {
        ring_idx: u16,
        inbox_idx: u16,
    };

    front: struct {
        ring_idx: u16,
        first_index: Role.IndexIdx,
        index_count: u16,
    },
    index: struct {
        ring_idx: u16,
        inbox_idx: u16,
        front_idx: u16,
    },
    elephant: struct {
        ring_idx: u16,
    },

    /// The slot this role occupies in every per-thread shared array.
    pub fn ringIdx(self: Role) u16 {
        return switch (self) {
            .front => |r| r.ring_idx,
            .index => |r| r.ring_idx,
            .elephant => |r| r.ring_idx,
        };
    }

    /// The role name, for diagnostics.
    pub fn name(self: Role) []const u8 {
        return switch (self) {
            .front => "front",
            .index => "index",
            .elephant => "elephant",
        };
    }
};

/// Ring itself and the related stuff.
pub const RingStuff = struct {
    const Self = @This();

    ring: zigring.Ring,
    sqstream: zigring.StreamSQ,
    slots: slots.RingSlots,
    /// Timer argument owned by this ring's service loop. The kernel reads it
    /// asynchronously, so it must outlive the loop frame that armed the timer;
    /// it lives here until `deinit`, after the thread has been joined.
    tick_spec: std.os.linux.kernel_timespec = .{ .sec = 0, .nsec = 0 },
    /// Whether `initGivenRing` reached the end for this slot.
    ready: bool = false,

    pub fn deinit(self: *Self) void {
        if (!self.ready) return;
        self.slots.deinit();
        self.ring.deinit();
        self.ready = false;
    }
};

/// Logger and its buffer pool.
pub const LoggerStuff = struct {
    const Self = @This();

    pool: blog.BufferPool,
    sink: logging.Sink,
    logger: logging.Logger,

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.logger.deinit();
        self.sink.deinit(allocator);
        self.pool.deinit();
    }
};

test "role distribution" {
    var cfg: config.Config = undefined;
    cfg.fronts = 2;
    cfg.indexes = 4;
    cfg.elephants = 1;
    cfg.queue_depth = 64;
    cfg.cross_task_slots = 16;
    cfg.sqpoll_threads = 1;
    cfg.wal = .{ .plain = .{ .dir = "wal" } };
    cfg.snapshots = .{};
    cfg.ring_slots_capacity = 4096;
    cfg.logging = .{
        .method = .{ .pretty = .dark },
        .pool_capacity = 64,
        .pool_frame_size = 1024,
    };

    var ctrl: Controller = undefined;
    try ctrl.init(std.testing.allocator, &cfg);
    defer ctrl.deinit();

    const expected = [_]Role{
        .{
            .front = .{
                .ring_idx = 0,
                .first_index = Role.IndexIdx{
                    .ring_idx = 2,
                    .inbox_idx = 0,
                },
                .index_count = 2,
            },
        },
        .{
            .front = .{
                .ring_idx = 1,
                .first_index = Role.IndexIdx{
                    .ring_idx = 4,
                    .inbox_idx = 2,
                },
                .index_count = 2,
            },
        },
        .{
            .index = .{
                .ring_idx = 2,
                .inbox_idx = 0,
                .front_idx = 0,
            },
        },
        .{
            .index = .{
                .ring_idx = 3,
                .inbox_idx = 1,
                .front_idx = 0,
            },
        },
        .{
            .index = .{
                .ring_idx = 4,
                .inbox_idx = 2,
                .front_idx = 1,
            },
        },
        .{
            .index = .{
                .ring_idx = 5,
                .inbox_idx = 3,
                .front_idx = 1,
            },
        },
        .{
            .elephant = .{
                .ring_idx = 6,
            },
        },
    };

    for (expected, 0..) |want, i| {
        const ring_idx = try ctrl.getRingIdx();
        try std.testing.expectEqual(@as(u16, @intCast(i)), ring_idx);
        const role = ctrl.roleOf(ring_idx);
        try std.testing.expectEqual(want, role);
        try std.testing.expectEqual(ring_idx, role.ringIdx());
    }

    try std.testing.expectError(error.Overflow, ctrl.getRingIdx());
}

test "roles map to the shared arrays" {
    var cfg: config.Config = undefined;
    cfg.fronts = 1;
    cfg.indexes = 2;
    cfg.elephants = 1;
    cfg.queue_depth = 64;
    cfg.cross_task_slots = 8;
    cfg.sqpoll_threads = 1;
    cfg.wal = .{ .plain = .{ .dir = "wal" } };
    cfg.snapshots = .{};
    cfg.ring_slots_capacity = 4096;
    cfg.index_inbox_capacity = 8;
    cfg.logging = .{
        .method = .{ .json = {} },
        .pool_capacity = 64,
        .pool_frame_size = 1024,
    };

    var ctrl: Controller = undefined;
    try ctrl.init(std.testing.allocator, &cfg);
    defer ctrl.deinit();

    const front_idx = try ctrl.getRingIdx();
    const front = ctrl.roleOf(front_idx);
    try std.testing.expectEqualStrings("front", front.name());
    try std.testing.expectEqual(@as(u16, 2), front.front.index_count);
    try std.testing.expectEqual(@as(u16, 1), front.front.first_index.ring_idx);

    const index_idx = try ctrl.getRingIdx();
    const index = ctrl.roleOf(index_idx);
    try std.testing.expectEqual(@as(u16, 1), index.index.ring_idx);
    try std.testing.expectEqual(@as(u16, 0), index.index.inbox_idx);

    const second_index_idx = try ctrl.getRingIdx();
    const second_index = ctrl.roleOf(second_index_idx);
    try std.testing.expectEqualStrings("index", second_index.name());
    try std.testing.expectEqual(@as(u16, 2), second_index.ringIdx());

    const elephant_idx = try ctrl.getRingIdx();
    const elephant = ctrl.roleOf(elephant_idx);
    try std.testing.expectEqualStrings("elephant", elephant.name());
    try std.testing.expectEqual(@as(u16, 3), elephant.ringIdx());
}

test "the derived role addresses the thread's own slot" {
    var cfg: config.Config = undefined;
    cfg.fronts = 1;
    cfg.indexes = 2;
    cfg.elephants = 1;
    cfg.queue_depth = 64;
    cfg.cross_task_slots = 8;
    cfg.sqpoll_threads = 1;
    cfg.wal = .{ .plain = .{ .dir = "wal" } };
    cfg.snapshots = .{};
    cfg.ring_slots_capacity = 4096;
    cfg.index_inbox_capacity = 8;
    cfg.logging = .{
        .method = .{ .json = {} },
        .pool_capacity = 64,
        .pool_frame_size = 1024,
    };

    var ctrl: Controller = undefined;
    try ctrl.init(std.testing.allocator, &cfg);
    defer ctrl.deinit();

    const ctx = ThreadContext{ .ctrl = &ctrl, .spawn_idx = 0 };
    try std.testing.expectEqual(@as(u16, 0), ctx.spawn_idx);

    // The first thread takes the first slot, and the role derived from that
    // index addresses exactly this thread's ring.
    const ring_idx = try ctrl.getRingIdx();
    try std.testing.expectEqual(ctx.spawn_idx, ring_idx);
    const slot = ctrl.roleOf(ring_idx).ringIdx();
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(&ctrl.rings[slot]) -| @intFromPtr(ctrl.rings.ptr));
}

// ============================================================================
// Index state tests
// ============================================================================

const TestController = struct {
    cfg: config.Config = undefined,
    ctrl: Controller = undefined,

    fn init(self: *TestController) !void {
        self.cfg = .{
            .fronts = 1,
            .indexes = 1,
            .elephants = 1,
            .queue_depth = 64,
            .cross_task_slots = 8,
            .sqpoll_threads = 1,
            .ring_slots_capacity = 4096,
            .index_inbox_capacity = 8,
            .wal = .{ .plain = .{ .dir = "wal" } },
            .logging = .{
                .method = .{ .json = {} },
                .pool_capacity = 64,
                .pool_frame_size = 1024,
            },
        };
        try self.ctrl.init(std.testing.allocator, &self.cfg);
        try self.ctrl.compensators.put("marker", .{ .bind = "10.0.0.1", .port = 20301 });
    }

    fn deinit(self: *TestController) void {
        self.ctrl.deinit();
    }
};

fn freeSessionData(sd: state.SessionData) void {
    std.testing.allocator.free(sd.compensator);
    std.testing.allocator.free(sd.data.backing);
}

test "uvarint round trips its edges" {
    const values = [_]u64{ 0, 1, 127, 128, 255, 1 << 14, std.math.maxInt(u64) };
    for (values) |value| {
        var buf: [10]u8 = undefined;
        const written = try putUvarint(&buf, value);
        const read = try readUvarint(buf[0..written]);
        try std.testing.expectEqual(value, read.value);
        try std.testing.expectEqual(written, read.len);
    }

    var empty: [0]u8 = .{};
    try std.testing.expectError(error.BufferTooSmall, putUvarint(&empty, 1));
    try std.testing.expectError(error.CorruptInput, readUvarint(&.{}));
    const overlong: [11]u8 = @splat(0x80);
    try std.testing.expectError(error.CorruptInput, readUvarint(&overlong));
}

test "session data codec matches the field table" {
    var ctx: TestController = .{};
    try ctx.init();
    defer ctx.deinit();

    var backing = [_]u8{ 0xAA, 0xBB, 0xCC };
    const sd: state.SessionData = .{
        .original_id = 0x112233445566778899aabbccddeeff00,
        .compensator = "marker",
        .retry_count = 0x01020304,
        .data = .{ .backing = &backing, .len = backing.len },
    };

    const encoded = try ctx.ctrl.encodeSessionData(&sd);
    defer std.testing.allocator.free(encoded);

    const expected = [_]u8{
        0x00, 0xff, 0xee, 0xdd, 0xcc, 0xbb, 0xaa, 0x99,
        0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11,
        6,    'm',  'a',  'r',  'k',  'e',  'r',  0x04,
        0x03, 0x02, 0x01, 3,    0xAA, 0xBB, 0xCC,
    };
    try std.testing.expectEqualSlices(u8, &expected, encoded);

    const decoded = try ctx.ctrl.decodeSessionData(encoded);
    defer freeSessionData(decoded);
    try std.testing.expectEqual(sd.original_id, decoded.original_id);
    try std.testing.expectEqualStrings(sd.compensator, decoded.compensator);
    try std.testing.expectEqual(sd.retry_count, decoded.retry_count);
    try std.testing.expectEqualSlices(u8, backing[0..], decoded.data.backing[0..decoded.data.len]);
}

test "session data codec keeps hostile compensator bytes" {
    var ctx: TestController = .{};
    try ctx.init();
    defer ctx.deinit();

    const hostile = [_]u8{ 0x00, 0xff, '\n', 0x7f };
    var chunk = [_]u8{ 0x82, 0x01, 'a', 'b' };
    const sd: state.SessionData = .{
        .original_id = 0xffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff,
        .compensator = &hostile,
        .retry_count = std.math.maxInt(u32),
        .data = .{ .backing = &chunk, .len = chunk.len },
    };

    const encoded = try ctx.ctrl.encodeSessionData(&sd);
    defer std.testing.allocator.free(encoded);
    const decoded = try ctx.ctrl.decodeSessionData(encoded);
    defer freeSessionData(decoded);

    try std.testing.expectEqualSlices(u8, &hostile, decoded.compensator);
    try std.testing.expectEqualSlices(u8, &chunk, decoded.data.backing[0..decoded.data.len]);
}

test "create append and overwrite shape the chunks" {
    var ctx: TestController = .{};
    try ctx.init();
    defer ctx.deinit();

    var st: state.IndexState = undefined;
    try ctx.ctrl.initIndexState(&st);
    defer ctx.ctrl.deinitIndexState(&st);

    st.state = 1;
    try ctx.ctrl.applyIndexOp(&st, .{ .create = .{ .compensator = "marker", .payload = "ab" } });
    const session = st.sessions.get(1).?;
    try std.testing.expectEqualSlices(u8, &.{ 2, 'a', 'b' }, session.data.data.backing[0..session.data.data.len]);

    st.state = 2;
    try ctx.ctrl.applyIndexOp(&st, .{ .append = .{ .session_id = 1, .payload = "" } });
    try std.testing.expectEqualSlices(u8, &.{ 2, 'a', 'b', 0 }, session.data.data.backing[0..session.data.data.len]);

    var big: [130]u8 = @splat('q');
    st.state = 3;
    try ctx.ctrl.applyIndexOp(&st, .{ .append = .{ .session_id = 1, .payload = &big } });
    try std.testing.expectEqual(@as(u8, 0x82), session.data.data.backing[4]);
    try std.testing.expectEqual(@as(u8, 0x01), session.data.data.backing[5]);

    st.state = 4;
    try ctx.ctrl.applyIndexOp(&st, .{ .overwrite = .{ .session_id = 1, .payload = "xyz" } });
    try std.testing.expectEqualSlices(u8, &.{ 3, 'x', 'y', 'z' }, session.data.data.backing[0..session.data.data.len]);

    const encoded = try ctx.ctrl.encodeSessionData(&session.data);
    defer std.testing.allocator.free(encoded);
    const decoded = try ctx.ctrl.decodeSessionData(encoded);
    defer freeSessionData(decoded);
    try std.testing.expectEqualSlices(u8, &.{ 3, 'x', 'y', 'z' }, decoded.data.backing[0..decoded.data.len]);

    // An empty payload is still one chunk: a zero length byte.
    st.state = 5;
    try ctx.ctrl.applyIndexOp(&st, .{ .create = .{ .compensator = "marker", .payload = "" } });
    const empty = st.sessions.get(5).?;
    try std.testing.expectEqualSlices(u8, &.{0}, empty.data.data.backing[0..empty.data.data.len]);
}

test "create restart and drain preserve identity and retry count" {
    var ctx: TestController = .{};
    try ctx.init();
    defer ctx.deinit();

    var st: state.IndexState = undefined;
    try ctx.ctrl.initIndexState(&st);
    defer ctx.ctrl.deinitIndexState(&st);

    st.state = 0x0000_0000_0000_0001_0000_0000_0000_0100;
    const original_id = st.state;
    try ctx.ctrl.applyIndexOp(&st, .{ .create = .{ .compensator = "marker", .payload = "body" } });
    st.sessions.get(original_id).?.data.retry_count = 7;

    st.state += 1;
    try ctx.ctrl.applyIndexOp(&st, .{ .restart_in = .{ .session_id = original_id, .seconds = 0 } });
    try std.testing.expectEqual(@as(usize, 0), st.sessions.count());
    try std.testing.expectEqual(@as(usize, 1), st.replay_queue.count());
    try std.testing.expect((try st.replay_queue.peekRetryTime()).? <= nowRealtimeNs());

    st.state += 1;
    const reactivated = (try ctx.ctrl.popReplayHead(&st)).?;
    try std.testing.expectEqual(st.state, reactivated.new_id);
    try std.testing.expectEqual(original_id, reactivated.session.data.original_id);
    try std.testing.expectEqual(@as(u32, 7), reactivated.session.data.retry_count);
    try std.testing.expectEqual(state.Session.State.ExpectOp, reactivated.session.state);
    try std.testing.expectEqual(st.state, reactivated.session.index_idx);
    try std.testing.expectEqual(@as(u16, 0), reactivated.session.consensus_progress.accepted);
    try std.testing.expectEqual(@as(usize, 1), st.sessions.count());
    try std.testing.expectEqual(@as(usize, 0), st.replay_queue.count());
}

test "two mints at two states produce two ids" {
    var ctx: TestController = .{};
    try ctx.init();
    defer ctx.deinit();

    var st: state.IndexState = undefined;
    try ctx.ctrl.initIndexState(&st);
    defer ctx.ctrl.deinitIndexState(&st);

    st.state = 10;
    try ctx.ctrl.applyIndexOp(&st, .{ .create = .{ .compensator = "marker", .payload = "a" } });
    st.state = 11;
    try ctx.ctrl.applyIndexOp(&st, .{ .create = .{ .compensator = "marker", .payload = "b" } });

    try std.testing.expectEqual(@as(usize, 2), st.sessions.count());
    try std.testing.expect(st.sessions.get(10) != null);
    try std.testing.expect(st.sessions.get(11) != null);
}

test "close removes an active session and then a queued one" {
    var ctx: TestController = .{};
    try ctx.init();
    defer ctx.deinit();

    var st: state.IndexState = undefined;
    try ctx.ctrl.initIndexState(&st);
    defer ctx.ctrl.deinitIndexState(&st);

    st.state = 20;
    try ctx.ctrl.applyIndexOp(&st, .{ .create = .{ .compensator = "marker", .payload = "x" } });

    st.state = 21;
    try ctx.ctrl.applyIndexOp(&st, .{ .restart_in = .{ .session_id = 20, .seconds = 60 } });
    try std.testing.expectEqual(@as(usize, 1), st.replay_queue.count());

    // A queued session is closed by id without an active entry.
    try ctx.ctrl.applyIndexOp(&st, .{ .close = .{ .session_id = 20 } });
    try std.testing.expectEqual(@as(usize, 0), st.replay_queue.count());
    try std.testing.expectError(error.UnknownSession, ctx.ctrl.applyIndexOp(&st, .{ .close = .{ .session_id = 20 } }));
}

test "unknown compensators are rejected before any state change" {
    var ctx: TestController = .{};
    try ctx.init();
    defer ctx.deinit();

    var st: state.IndexState = undefined;
    try ctx.ctrl.initIndexState(&st);
    defer ctx.ctrl.deinitIndexState(&st);

    st.state = 30;
    try std.testing.expectError(
        error.UnknownCompensator,
        ctx.ctrl.applyIndexOp(&st, .{ .create = .{ .compensator = "nobody", .payload = "x" } }),
    );
    try std.testing.expectEqual(@as(usize, 0), st.sessions.count());

    // Validation is by exact name bytes.
    try std.testing.expectError(
        error.UnknownCompensator,
        ctx.ctrl.applyIndexOp(&st, .{ .create = .{ .compensator = "Marker", .payload = "x" } }),
    );
    try std.testing.expectEqual(@as(usize, 0), st.sessions.count());
}

test "the drain is deterministic for the same queue and state" {
    var ctx: TestController = .{};
    try ctx.init();
    defer ctx.deinit();

    var first: state.IndexState = undefined;
    var second: state.IndexState = undefined;
    try ctx.ctrl.initIndexState(&first);
    defer ctx.ctrl.deinitIndexState(&first);
    try ctx.ctrl.initIndexState(&second);
    defer ctx.ctrl.deinitIndexState(&second);

    first.state = 100;
    second.state = 100;
    try ctx.ctrl.applyIndexOp(&first, .{ .create = .{ .compensator = "marker", .payload = "same" } });
    try ctx.ctrl.applyIndexOp(&second, .{ .create = .{ .compensator = "marker", .payload = "same" } });

    first.state = 101;
    second.state = 101;
    try ctx.ctrl.applyIndexOp(&first, .{ .restart_in = .{ .session_id = 100, .seconds = 60 } });
    try ctx.ctrl.applyIndexOp(&second, .{ .restart_in = .{ .session_id = 100, .seconds = 60 } });

    first.state = 102;
    second.state = 102;
    const a = (try ctx.ctrl.popReplayHead(&first)).?;
    const b = (try ctx.ctrl.popReplayHead(&second)).?;

    try std.testing.expectEqual(a.new_id, b.new_id);
    try std.testing.expectEqual(a.session.data.original_id, b.session.data.original_id);
    try std.testing.expectEqualSlices(
        u8,
        a.session.data.data.backing[0..a.session.data.data.len],
        b.session.data.data.backing[0..b.session.data.data.len],
    );
}

test "dump and load round trip the whole data set" {
    var ctx: TestController = .{};
    try ctx.init();
    defer ctx.deinit();

    var st: state.IndexState = undefined;
    try ctx.ctrl.initIndexState(&st);
    defer ctx.ctrl.deinitIndexState(&st);

    st.state = 40;
    try ctx.ctrl.applyIndexOp(&st, .{ .create = .{ .compensator = "marker", .payload = "first" } });
    st.state = 41;
    try ctx.ctrl.applyIndexOp(&st, .{ .create = .{ .compensator = "marker", .payload = "second" } });
    st.state = 42;
    try ctx.ctrl.applyIndexOp(&st, .{ .restart_in = .{ .session_id = 41, .seconds = 60 } });

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try ctx.ctrl.dumpIndexState(&st, &out);

    var loaded = try ctx.ctrl.loadIndexState(out.items);
    defer ctx.ctrl.deinitIndexState(&loaded);

    try std.testing.expectEqual(@as(u128, 0), loaded.state);
    try std.testing.expectEqual(st.sessions.count(), loaded.sessions.count());
    try std.testing.expectEqual(st.replay_queue.count(), loaded.replay_queue.count());

    var it = st.sessions.iterator();
    while (it.next()) |bucket| {
        const restored = loaded.sessions.get(bucket.key).?;
        try std.testing.expectEqual(bucket.val.data.original_id, restored.data.original_id);
        try std.testing.expectEqualStrings(bucket.val.data.compensator, restored.data.compensator);
        try std.testing.expectEqual(bucket.val.data.retry_count, restored.data.retry_count);
        try std.testing.expectEqualSlices(
            u8,
            bucket.val.data.data.backing[0..bucket.val.data.data.len],
            restored.data.data.backing[0..restored.data.data.len],
        );
    }
}

test "an empty data set round trips and a future version is rejected" {
    var ctx: TestController = .{};
    try ctx.init();
    defer ctx.deinit();

    var st: state.IndexState = undefined;
    try ctx.ctrl.initIndexState(&st);
    defer ctx.ctrl.deinitIndexState(&st);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try ctx.ctrl.dumpIndexState(&st, &out);

    var loaded = try ctx.ctrl.loadIndexState(out.items);
    defer ctx.ctrl.deinitIndexState(&loaded);
    try std.testing.expectEqual(@as(usize, 0), loaded.sessions.count());
    try std.testing.expectEqual(@as(usize, 0), loaded.replay_queue.count());

    const future = [_]u8{ 0x02, 0x00, 0x00 };
    try std.testing.expectError(error.UnsupportedVersion, ctx.ctrl.loadIndexState(&future));
}

test "the dump never contains the runtime state" {
    var ctx: TestController = .{};
    try ctx.init();
    defer ctx.deinit();

    var st: state.IndexState = undefined;
    try ctx.ctrl.initIndexState(&st);
    defer ctx.ctrl.deinitIndexState(&st);

    st.state = 51;
    try ctx.ctrl.applyIndexOp(&st, .{ .create = .{ .compensator = "marker", .payload = "x" } });
    // The consensus driver moves the state on after the op; the new value is
    // runtime-only and must not appear in the dump.
    st.state = 0xDEAD_BEEF_0000_0000_0000_0000_0000_0001;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try ctx.ctrl.dumpIndexState(&st, &out);

    var needle: [16]u8 = undefined;
    std.mem.writeInt(u128, &needle, st.state, .little);
    try std.testing.expect(std.mem.indexOf(u8, out.items, &needle) == null);
}

test "an out-of-order queue section is rejected" {
    var ctx: TestController = .{};
    try ctx.init();
    defer ctx.deinit();

    var later: [replay_queue.BLOB_HEAD + 1]u8 = undefined;
    std.mem.writeInt(u64, later[0..8], 10, .little);
    std.mem.writeInt(u128, later[8..24], 1, .little);
    later[replay_queue.BLOB_HEAD] = 0;

    var earlier: [replay_queue.BLOB_HEAD + 1]u8 = undefined;
    std.mem.writeInt(u64, earlier[0..8], 5, .little);
    std.mem.writeInt(u128, earlier[8..24], 2, .little);
    earlier[replay_queue.BLOB_HEAD] = 0;

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    try bytes.appendSlice(std.testing.allocator, &.{ 0x01, 0x00 }); // version 1
    try bytes.append(std.testing.allocator, 0); // no sessions
    try bytes.append(std.testing.allocator, 2); // two queue entries
    try bytes.appendSlice(std.testing.allocator, &later);
    try bytes.appendSlice(std.testing.allocator, &earlier);

    try std.testing.expectError(error.CorruptInput, ctx.ctrl.loadIndexState(bytes.items));
}

test "cloneIndexState is a deep copy" {
    var ctx: TestController = .{};
    try ctx.init();
    defer ctx.deinit();

    var st: state.IndexState = undefined;
    try ctx.ctrl.initIndexState(&st);
    defer ctx.ctrl.deinitIndexState(&st);

    st.state = 50;
    try ctx.ctrl.applyIndexOp(&st, .{ .create = .{ .compensator = "marker", .payload = "live" } });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const clone = try ctx.ctrl.cloneIndexState(&st, arena.allocator());
    const original = st.sessions.get(50).?;
    const copied = clone.sessions.get(50).?;

    try std.testing.expect(original != copied);
    try std.testing.expect(original.data.compensator.ptr != copied.data.compensator.ptr);
    try std.testing.expect(original.data.data.backing.ptr != copied.data.data.backing.ptr);

    original.data.data.backing[0] ^= 0xff;
    try std.testing.expect(original.data.data.backing[0] != copied.data.data.backing[0]);

    // The clone's dump bytes ride the arena too; the arena releases both.
    var out: std.ArrayList(u8) = .empty;
    try ctx.ctrl.dumpIndexState(&clone, &out);
    try std.testing.expect(out.items.len > 0);
}

test "the replay blob is the head plus the session bytes" {
    var ctx: TestController = .{};
    try ctx.init();
    defer ctx.deinit();

    const body = [_]u8{ 0x01, 0x02, 0x03 };
    const session_id: u128 = 0x112233445566778899aabbccddeeff00;
    const blob = try ctx.ctrl.makeReplayBlob(0x0102030405060708, session_id, &body);
    defer std.testing.allocator.free(blob);

    try std.testing.expectEqual(@as(usize, replay_queue.BLOB_HEAD + 1 + body.len), blob.len);
    try std.testing.expectEqual(
        @as(u64, 0x0102030405060708),
        std.mem.readInt(u64, blob[replay_queue.RETRY_TIME_OFF..][0..8], .little),
    );
    try std.testing.expectEqual(
        session_id,
        std.mem.readInt(u128, blob[replay_queue.SESSION_ID_OFF..][0..16], .little),
    );
    try std.testing.expectEqual(@as(u8, body.len), blob[replay_queue.BLOB_HEAD]);
    try std.testing.expectEqualSlices(u8, &body, blob[replay_queue.BLOB_HEAD + 1 ..]);
}

test "a queued session can be removed and re-armed with a new deadline" {
    var ctx: TestController = .{};
    try ctx.init();
    defer ctx.deinit();

    var st: state.IndexState = undefined;
    try ctx.ctrl.initIndexState(&st);
    defer ctx.ctrl.deinitIndexState(&st);

    st.state = 70;
    try ctx.ctrl.applyIndexOp(&st, .{ .create = .{ .compensator = "marker", .payload = "x" } });
    st.state = 71;
    try ctx.ctrl.applyIndexOp(&st, .{ .restart_in = .{ .session_id = 70, .seconds = 60 } });

    const old = (try st.replay_queue.removeSessionId(70)).?;
    defer std.testing.allocator.free(old);
    try std.testing.expectEqual(@as(usize, 0), st.replay_queue.count());

    std.mem.writeInt(u64, old[0..8], 12345, .little);
    try st.replay_queue.push(old);
    try std.testing.expectEqual(@as(?u64, 12345), try st.replay_queue.peekRetryTime());
}

test "dump and load preserve the queue order" {
    var ctx: TestController = .{};
    try ctx.init();
    defer ctx.deinit();

    var st: state.IndexState = undefined;
    try ctx.ctrl.initIndexState(&st);
    defer ctx.ctrl.deinitIndexState(&st);

    st.state = 80;
    try ctx.ctrl.applyIndexOp(&st, .{ .create = .{ .compensator = "marker", .payload = "a" } });
    st.state = 81;
    try ctx.ctrl.applyIndexOp(&st, .{ .create = .{ .compensator = "marker", .payload = "b" } });

    // The later-created session is due first; the dump must sort by due time.
    st.state = 82;
    try ctx.ctrl.applyIndexOp(&st, .{ .restart_in = .{ .session_id = 80, .seconds = 120 } });
    st.state = 83;
    try ctx.ctrl.applyIndexOp(&st, .{ .restart_in = .{ .session_id = 81, .seconds = 60 } });

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try ctx.ctrl.dumpIndexState(&st, &out);

    var loaded = try ctx.ctrl.loadIndexState(out.items);
    defer ctx.ctrl.deinitIndexState(&loaded);
    try std.testing.expectEqual(@as(usize, 2), loaded.replay_queue.count());

    const head = (try loaded.replay_queue.pop()).?;
    defer std.testing.allocator.free(head);
    try std.testing.expectEqual(
        @as(u128, 81),
        std.mem.readInt(u128, head[replay_queue.SESSION_ID_OFF..][0..16], .little),
    );
}

// ============================================================================
// WAL seam tests
// ============================================================================

/// A controller over a throwaway WAL directory. Every cold WAL entry point is
/// synchronous, so these tests drive them straight from the test thread.
const WalFixture = struct {
    tmp: std.testing.TmpDir,
    dir: []u8,
    cfg: config.Config,
    ctrl: Controller,

    fn init(self: *WalFixture) !void {
        self.tmp = std.testing.tmpDir(.{});
        self.dir = try std.fmt.allocPrint(
            std.testing.allocator,
            ".zig-cache/tmp/{s}",
            .{self.tmp.sub_path[0..]},
        );
        self.cfg = .{
            .fronts = 1,
            .indexes = 2,
            .elephants = 1,
            .queue_depth = 64,
            .cross_task_slots = 8,
            .sqpoll_threads = 1,
            .ring_slots_capacity = 4096,
            .index_inbox_capacity = 8,
            .wal = .{ .plain = .{ .dir = self.dir, .buffers = 4, .lba = 512 } },
            .logging = .{
                .method = .{ .json = {} },
                .pool_capacity = 64,
                .pool_frame_size = 1024,
            },
        };
        try self.ctrl.init(std.testing.allocator, &self.cfg);
    }

    fn deinit(self: *WalFixture) void {
        self.ctrl.deinit();
        std.testing.allocator.free(self.dir);
        self.tmp.cleanup();
    }

    /// Creates the empty file of one triple, standing in for the elephant side
    /// that owns creation.
    fn create(self: *WalFixture, host_idx: u8, index_idx: u16, tag: u128) !posix.fd_t {
        try self.ctrl.ensureIndexDir(index_idx);
        const dir = try self.ctrl.indexDirPath(index_idx);
        defer std.testing.allocator.free(dir);

        const path = try wal.walPath(std.testing.allocator, dir, host_idx, index_idx, tag);
        defer std.testing.allocator.free(path);

        const fd_raw = std.os.linux.open(path, .{ .ACCMODE = .RDWR, .CREAT = true }, 0o644);
        const errno = std.os.linux.errno(fd_raw);
        if (errno != .SUCCESS) return std.posix.unexpectedErrno(errno);
        return @intCast(fd_raw);
    }
};

test "delete removes a wal file and treats a missing one as success" {
    var fixture: WalFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    // Retention never has to probe first: nothing to remove is success.
    try fixture.ctrl.delete(0, 1, 0xAA);

    const fd = try fixture.create(0, 1, 0xAA);
    _ = std.os.linux.close(fd);

    const reader = try fixture.ctrl.walOpenRead(0, 1, 0xAA);
    try std.testing.expectEqual(@as(u128, 0xAA), reader.tag);
    fixture.ctrl.walCloseRead(reader);

    try fixture.ctrl.delete(0, 1, 0xAA);
    try std.testing.expectError(error.FileNotFound, fixture.ctrl.walOpenRead(0, 1, 0xAA));

    // Idempotent by construction.
    try fixture.ctrl.delete(0, 1, 0xAA);
}

test "a missing wal file is an open error, never repaired" {
    var fixture: WalFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    try std.testing.expectError(error.FileNotFound, fixture.ctrl.walOpenWrite(0, 0, 0x99));
    try std.testing.expectError(error.FileNotFound, fixture.ctrl.walOpenRead(0, 0, 0x99));
}

test "a triple owns at most one live writer" {
    var fixture: WalFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const fd = try fixture.create(0, 0, 0x20);
    _ = std.os.linux.close(fd);

    const writer = try fixture.ctrl.walOpenWrite(0, 0, 0x20);
    try std.testing.expectEqual(@as(u128, 0x20), writer.tag);
    try std.testing.expectEqual(@as(u128, 0x20), writer.head);

    // Reopening a triple that already has a live writer is refused; only the
    // swap entry may replace one, and it closes the old writer first.
    try std.testing.expectError(error.WalOpen, fixture.ctrl.walOpenWrite(0, 0, 0x20));

    // Another pair of the same index thread is free.
    const other_fd = try fixture.create(0, 1, 0x20);
    _ = std.os.linux.close(other_fd);
    const other = try fixture.ctrl.walOpenWrite(0, 1, 0x20);
    try std.testing.expect(other != writer);
}

test "adoption leaves the old writer open on the pair and writes on its temp ring" {
    var fixture: WalFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const opened = try fixture.create(0, 0, 0x60);
    _ = std.os.linux.close(opened);
    const old = try fixture.ctrl.walOpenWrite(0, 0, 0x60);
    const old_fd = old.fd;

    // The snapshot procedure's adopt: the elephant handed the new descriptor
    // over, and the window's writer runs on temp ring 0. The old writer is not
    // closed — the final-close elephant owns that — and the pair keeps it as
    // its registered writer for the window.
    const writer = try fixture.ctrl.walAdoptWrite(0, 0, 0, 0x61, try fixture.create(0, 0, 0x61));
    try std.testing.expect(writer != old);
    try std.testing.expectEqual(@as(u128, 0x61), writer.head);

    // The old descriptor is still valid, and still the pair's writer.
    const old_flags = std.os.linux.errno(std.os.linux.fcntl(old_fd, std.os.linux.F.GETFD, 0));
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, old_flags);
    try std.testing.expectEqual(old, fixture.ctrl.wal_writers[0].?);

    // The new writer's arrays are the temp ring's, not the pair's area.
    const battery = fixture.ctrl.wal_battery.?;
    const temp_start = wal.tempAreaIdx(0, fixture.ctrl.wal_pairs) * fixture.ctrl.wal_area_stride;
    const temp_area = wal.Area.init(
        battery[temp_start..][0..fixture.ctrl.wal_area_stride],
        fixture.cfg.wal.buffers(),
        fixture.cfg.wal.lba(),
    );
    try std.testing.expectEqual(@intFromPtr(temp_area.headers.ptr), @intFromPtr(writer.headers.ptr));
    try std.testing.expectEqual(@intFromPtr(temp_area.data.ptr), @intFromPtr(writer.data.ptr));

    // And the pair's own entry still refuses a second open.
    try std.testing.expectError(error.WalOpen, fixture.ctrl.walOpenWrite(0, 0, 0x61));

    // The window's writer is the caller's: nothing else releases it.
    _ = std.os.linux.close(writer.fd);
    fixture.ctrl.allocator.destroy(writer);
}

test "adoption publishes the temp ring's ordinal-0 terminator from the clone state" {
    var fixture: WalFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    // A rotated file: the clone state Y is the anchor its first record chains
    // from, never the name tag.
    const writer = try fixture.ctrl.walAdoptWrite(0, 1, 0, 0x40, try fixture.create(0, 1, 0x40));
    try std.testing.expectEqual(@as(u128, 0x40), writer.head);

    const header = writer.headers[0];
    try std.testing.expectEqual(@as(u64, 0), header.buffer_seq);
    try std.testing.expectEqual(@as(u32, 0), header.data_len);
    try std.testing.expectEqual(@as(u32, 0), header.flags);
    // The empty block's fold is the CRC of nothing, not the register seed.
    try std.testing.expectEqual(@as(u32, 0), header.crc_running);
    try std.testing.expectEqual(@as(u128, 0x40), header.last_state);

    // A brand-new data set: the empty state, on its own temp ring.
    const fresh = try fixture.ctrl.walAdoptWrite(0, 0, 1, 0, try fixture.create(0, 0, 0));
    try std.testing.expectEqual(@as(u128, 0), fresh.head);
    try std.testing.expectEqual(@as(u128, 0), fresh.headers[0].last_state);
    try std.testing.expectEqual(@as(u32, 0), fresh.headers[0].crc_running);

    // The registry append is the snapshot procedure's commit point and runs
    // after adoption returns, so a fake append reading the temp ring's
    // ordinal-0 line at that moment must find the terminator —
    // "registry-visible implies the ordinal-0 terminator was persisted".
    const at_append = writer.headers[0];
    try std.testing.expectEqual(@as(u64, 0), at_append.buffer_seq);
    try std.testing.expectEqual(@as(u32, 0), at_append.data_len);
    try std.testing.expectEqual(@as(u32, 0), at_append.flags);
    try std.testing.expectEqual(@as(u128, 0x40), at_append.last_state);

    // Both writers are the caller's: nothing else releases them.
    _ = std.os.linux.close(writer.fd);
    fixture.ctrl.allocator.destroy(writer);
    _ = std.os.linux.close(fresh.fd);
    fixture.ctrl.allocator.destroy(fresh);
}

test "the battery is one zeroed plain area per pair and per temp ring" {
    var fixture: WalFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    try std.testing.expectEqual(wal.Mode.plain, fixture.ctrl.wal_mode);
    try std.testing.expectEqual(@as(usize, 2), fixture.ctrl.wal_pairs);

    // A quarter-mebibyte-free geometry: 2 × 512 bytes of data plus headers,
    // rounded up to a page so the next pair's data array stays aligned.
    try std.testing.expectEqual(@as(usize, 4096), fixture.ctrl.wal_area_stride);
    try std.testing.expectEqual(@as(usize, 0), fixture.ctrl.wal_area_stride % std.heap.pageSize());

    try fixture.ctrl.acquireWalBattery();
    const bytes = fixture.ctrl.wal_battery.?;
    const areas = fixture.ctrl.wal_pairs + fixture.cfg.snapshots.slots;
    try std.testing.expectEqual(areas * fixture.ctrl.wal_area_stride, bytes.len);
    for (bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);

    // The temp section starts where the pair areas end: `walArea(pair)` slices
    // only below `wal_pairs`, so it can never reach a temp ring.
    try std.testing.expectEqual(fixture.ctrl.wal_pairs, wal.tempAreaIdx(0, fixture.ctrl.wal_pairs));
    const last_pair = try fixture.ctrl.walArea(fixture.ctrl.wal_pairs - 1);
    try std.testing.expectEqual(
        fixture.ctrl.wal_pairs * fixture.ctrl.wal_area_stride,
        @intFromPtr(last_pair.ptr) - @intFromPtr(bytes.ptr) + last_pair.len,
    );
}

test "a pmem reopen maps the device and walks the chain the crash left" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(dir);

    // A plain sized file stands in for the NVDIMM: PMEM mode maps the device as
    // found, so nothing about the battery needs a real stick to be exercised.
    const device = try std.fmt.allocPrint(allocator, "{s}/pmem0", .{dir});
    defer allocator.free(device);

    var cfg: config.Config = .{
        .fronts = 1,
        .indexes = 2,
        .elephants = 1,
        .queue_depth = 64,
        .cross_task_slots = 8,
        .sqpoll_threads = 1,
        .ring_slots_capacity = 4096,
        .index_inbox_capacity = 8,
        .wal = .{ .pmem = .{ .dir = dir, .device = device, .buffers = 4, .lba = 4096 } },
        .logging = .{
            .method = .{ .json = {} },
            .pool_capacity = 64,
            .pool_frame_size = 1024,
        },
    };

    const areas = @as(usize, cfg.indexes) * cfg.wal.hosts() + cfg.snapshots.slots;
    const needed = areas * wal.areaStride(cfg.wal.buffers(), cfg.wal.lba(), std.heap.pageSize());

    const device_path = try std.fmt.allocPrintSentinel(allocator, "{s}/pmem0", .{dir}, 0);
    defer allocator.free(device_path);
    const device_raw = std.os.linux.open(device_path, .{ .ACCMODE = .RDWR, .CREAT = true }, 0o644);
    if (std.os.linux.errno(device_raw) != .SUCCESS) return error.TestUnexpectedResult;
    const device_fd: posix.fd_t = @intCast(device_raw);
    defer _ = std.os.linux.close(device_fd);
    if (std.os.linux.errno(std.os.linux.ftruncate(device_fd, @intCast(needed))) != .SUCCESS) {
        return error.TestUnexpectedResult;
    }

    // The first run opens the WAL file the elephant created and writes one
    // record into the pair's own area: nothing fills a buffer, so no flush
    // happens and the whole chain stays in the battery.
    const tag: u128 = 0x900;

    const data = try allocator.alloc(u8, 700);
    defer allocator.free(data);
    for (data, 0..) |*byte, i| byte.* = @truncate(i *% 17);

    {
        var ctrl: Controller = undefined;
        try ctrl.init(allocator, &cfg);
        defer ctrl.deinit();

        try ctrl.ensureIndexDir(0);
        const dir_path = try ctrl.indexDirPath(0);
        defer allocator.free(dir_path);
        const path = try wal.walPath(allocator, dir_path, 0, 0, tag);
        defer allocator.free(path);

        // The elephant created the empty file and the index thread opens it
        // for writing, which walks the battery and publishes the pair's
        // ordinal-0 terminator into the pair's own area.
        const file_raw = std.os.linux.open(path, .{ .ACCMODE = .RDWR, .CREAT = true }, 0o644);
        if (std.os.linux.errno(file_raw) != .SUCCESS) return error.TestUnexpectedResult;
        _ = std.os.linux.close(@intCast(file_raw));
        const writer = try ctrl.walOpenWrite(0, 0, tag);
        try std.testing.expectEqual(wal.Mode.pmem, ctrl.wal_mode);
        try std.testing.expect(writer.pmem);
        // A zeroed device carries no chain: the open starts at the empty state.
        try std.testing.expectEqual(@as(u128, 0), writer.head);

        try writer.write(0x901, writer.head, data);
        try std.testing.expectEqual(@as(u64, 0), writer.flushed_upto);
    }

    // The second run maps the same device and resumes from the chain: the live
    // tail's byte and its state, with the flush frontier still at what the file
    // itself holds — nothing.
    {
        var ctrl: Controller = undefined;
        try ctrl.init(allocator, &cfg);
        defer ctrl.deinit();

        const writer = try ctrl.walOpenWrite(0, 0, tag);
        try std.testing.expectEqual(@as(u64, 0), writer.current);
        try std.testing.expectEqual(@as(u32, @intCast(wal.framedLen(data.len))), writer.cursor);
        try std.testing.expectEqual(@as(u128, 0x901), writer.head);
        try std.testing.expectEqual(@as(u64, 0), writer.flushed_upto);

        // And the chain continues from there instead of from the tag.
        try std.testing.expectError(error.WalGap, writer.write(0x902, tag, data));
        try writer.write(0x902, 0x901, data);
        try std.testing.expectEqual(@as(u128, 0x902), writer.head);
    }
}

// ============================================================================
// Index directory and registry
// ============================================================================

/// A controller over a throwaway WAL root with `hosts` data sets, for the
/// registry's cold helpers.
const RegistryFixture = struct {
    tmp: std.testing.TmpDir,
    dir: []u8,
    cfg: config.Config,
    ctrl: Controller,

    fn init(self: *RegistryFixture, hosts: u32, keep: u32) !void {
        self.tmp = std.testing.tmpDir(.{});
        self.dir = try std.fmt.allocPrint(
            std.testing.allocator,
            ".zig-cache/tmp/{s}",
            .{self.tmp.sub_path[0..]},
        );
        self.cfg = .{
            .fronts = 1,
            .indexes = 2,
            .elephants = 1,
            .queue_depth = 64,
            .cross_task_slots = 8,
            .sqpoll_threads = 1,
            .ring_slots_capacity = 4096,
            .index_inbox_capacity = 8,
            .wal = .{ .plain = .{ .dir = self.dir, .buffers = 4, .hosts = hosts, .lba = 512 } },
            .snapshots = .{ .registry_keep = keep },
            .logging = .{
                .method = .{ .json = {} },
                .pool_capacity = 64,
                .pool_frame_size = 1024,
            },
        };
        try self.ctrl.init(std.testing.allocator, &self.cfg);
    }

    fn deinit(self: *RegistryFixture) void {
        self.ctrl.deinit();
        std.testing.allocator.free(self.dir);
        self.tmp.cleanup();
    }
};

/// Writes `bytes` into `path`, creating or truncating it.
fn writeRawFile(path: []const u8, bytes: []const u8) !void {
    const path_z = try std.testing.allocator.dupeSentinel(u8, path, 0);
    defer std.testing.allocator.free(path_z);

    const fd_raw = std.os.linux.open(path_z, .{
        .ACCMODE = .RDWR,
        .CREAT = true,
        .TRUNC = true,
    }, 0o644);
    const errno = std.os.linux.errno(fd_raw);
    if (errno != .SUCCESS) return std.posix.unexpectedErrno(errno);
    const fd: posix.fd_t = @intCast(fd_raw);
    defer _ = std.os.linux.close(fd);

    var done: usize = 0;
    while (done < bytes.len) {
        const res = std.os.linux.write(fd, bytes[done..].ptr, bytes.len - done);
        const write_errno = std.os.linux.errno(res);
        if (write_errno != .SUCCESS) return std.posix.unexpectedErrno(write_errno);
        done += res;
    }
}

/// Reads `path` whole.
fn readRawFile(path: []const u8) ![]u8 {
    const path_z = try std.testing.allocator.dupeSentinel(u8, path, 0);
    defer std.testing.allocator.free(path_z);

    const fd_raw = std.os.linux.open(path_z, .{ .ACCMODE = .RDONLY }, 0);
    const errno = std.os.linux.errno(fd_raw);
    if (errno != .SUCCESS) return std.posix.unexpectedErrno(errno);
    const fd: posix.fd_t = @intCast(fd_raw);
    defer _ = std.os.linux.close(fd);

    const size = try wal.fileSize(fd);
    const bytes = try std.testing.allocator.alloc(u8, @intCast(size));
    errdefer std.testing.allocator.free(bytes);

    var got: usize = 0;
    while (got < bytes.len) {
        const at: posix.off_t = @intCast(got);
        const res = std.os.linux.pread(fd, bytes[got..].ptr, bytes.len - got, at);
        const read_errno = std.os.linux.errno(res);
        if (read_errno != .SUCCESS) return std.posix.unexpectedErrno(read_errno);
        if (res == 0) return error.EndOfStream;
        got += res;
    }
    return bytes;
}

test "the index directory hosts every leaf of its own pair" {
    const allocator = std.testing.allocator;

    var fixture: RegistryFixture = undefined;
    try fixture.init(2, 3);
    defer fixture.deinit();

    const dir_path = try fixture.ctrl.indexDirPath(1);
    defer allocator.free(dir_path);
    const want_dir = try std.fmt.allocPrint(allocator, "{s}/index.1", .{fixture.dir});
    defer allocator.free(want_dir);
    try std.testing.expectEqualStrings(want_dir, dir_path);

    const registry = try fixture.ctrl.registryPath(1);
    defer allocator.free(registry);
    const want_registry = try std.fmt.allocPrint(allocator, "{s}/registry.jsonl", .{want_dir});
    defer allocator.free(want_registry);
    try std.testing.expectEqualStrings(want_registry, registry);

    const pending = try fixture.ctrl.registryPendingPath(1);
    defer allocator.free(pending);
    const want_pending = try std.fmt.allocPrint(allocator, "{s}/registry.pending", .{want_dir});
    defer allocator.free(want_pending);
    try std.testing.expectEqualStrings(want_pending, pending);

    // The leaves are globally unique and stay so: only the directory moves.
    const tag: u128 = 0x2A;
    const wal_leaf = try wal.walPath(allocator, want_dir, 1, 1, tag);
    defer allocator.free(wal_leaf);
    const snapshot_leaf = try wal.snapshotPath(allocator, want_dir, 1, 1, tag);
    defer allocator.free(snapshot_leaf);

    const want_wal = try std.fmt.allocPrint(
        allocator,
        "{s}/wal.1.1.{x:0>32}",
        .{ want_dir, tag },
    );
    defer allocator.free(want_wal);
    const want_snapshot = try std.fmt.allocPrint(
        allocator,
        "{s}/snapshot.1.1.{x:0>32}",
        .{ want_dir, tag },
    );
    defer allocator.free(want_snapshot);
    try std.testing.expectEqualStrings(want_wal, wal_leaf);
    try std.testing.expectEqualStrings(want_snapshot, snapshot_leaf);
}

test "ensureIndexDir creates the directory once and is idempotent" {
    const allocator = std.testing.allocator;

    var fixture: RegistryFixture = undefined;
    try fixture.init(2, 3);
    defer fixture.deinit();

    const dir_path = try fixture.ctrl.indexDirPath(1);
    defer allocator.free(dir_path);

    try fixture.ctrl.ensureIndexDir(1);
    try fixture.ctrl.ensureIndexDir(1);

    // The directory is openable, which a missing one is not.
    const dir_z = try allocator.dupeSentinel(u8, dir_path, 0);
    defer allocator.free(dir_z);
    const fd_raw = std.os.linux.open(dir_z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(fd_raw));
    _ = std.os.linux.close(@intCast(fd_raw));

    // A file can only land inside an existing directory.
    const probe = try std.fmt.allocPrint(allocator, "{s}/probe", .{dir_path});
    defer allocator.free(probe);
    try writeRawFile(probe, "x");
}

test "an absent registry is null and the first rewrite creates one line" {
    const allocator = std.testing.allocator;

    var fixture: RegistryFixture = undefined;
    try fixture.init(1, 3);
    defer fixture.deinit();

    try std.testing.expectEqual(
        @as(?[]Controller.RegistryEntry, null),
        try fixture.ctrl.loadRegistry(0),
    );

    const snapshot_path = try std.fmt.allocPrint(allocator, "{s}/index.0/snapshot.0.0.0000000000000000000000000000002a", .{fixture.dir});
    defer allocator.free(snapshot_path);
    const wal_path = try std.fmt.allocPrint(allocator, "{s}/index.0/wal.0.0.0000000000000000000000000000002a", .{fixture.dir});
    defer allocator.free(wal_path);

    try fixture.ctrl.rewriteRegistry(0, .{
        .host_idx = 0,
        .snapshot_path = snapshot_path,
        .wal_path = wal_path,
        .state = 42,
    });

    const registry = try fixture.ctrl.registryPath(0);
    defer allocator.free(registry);

    const want = try std.fmt.allocPrint(
        allocator,
        "{{\"host_idx\":0,\"snapshot_path\":\"{s}\",\"wal_path\":\"{s}\",\"state\":42}}\n",
        .{ snapshot_path, wal_path },
    );
    defer allocator.free(want);
    const raw = try readRawFile(registry);
    defer allocator.free(raw);
    try std.testing.expectEqualStrings(want, raw);

    const loaded = (try fixture.ctrl.loadRegistry(0)).?;
    defer fixture.ctrl.freeRegistry(loaded);
    try std.testing.expectEqual(@as(usize, 1), loaded.len);
    try std.testing.expectEqual(@as(u8, 0), loaded[0].host_idx);
    try std.testing.expectEqual(@as(u128, 42), loaded[0].state);
    try std.testing.expectEqualStrings(snapshot_path, loaded[0].snapshot_path);
    try std.testing.expectEqualStrings(wal_path, loaded[0].wal_path);

    const winning = Controller.lastLineFor(loaded, 0).?;
    try std.testing.expectEqual(@as(u128, 42), winning.state);
}

test "the rewrite compacts per host and drops inert hosts" {
    const allocator = std.testing.allocator;

    var fixture: RegistryFixture = undefined;
    try fixture.init(2, 3);
    defer fixture.deinit();

    try fixture.ctrl.ensureIndexDir(0);
    const registry = try fixture.ctrl.registryPath(0);
    defer allocator.free(registry);

    // A file naming a host the config no longer hosts, plus two hosted hosts.
    try writeRawFile(registry,
        \\{"host_idx":0,"snapshot_path":"s0","wal_path":"w0","state":1}
        \\{"host_idx":5,"snapshot_path":"s5","wal_path":"w5","state":9}
        \\{"host_idx":1,"snapshot_path":"s1","wal_path":"w1","state":2}
        \\
    );

    var next_state: u128 = 10;
    while (next_state < 15) : (next_state += 1) {
        try fixture.ctrl.rewriteRegistry(0, .{
            .host_idx = 0,
            .snapshot_path = @constCast("new-s"),
            .wal_path = @constCast("new-w"),
            .state = next_state,
        });
    }

    const loaded = (try fixture.ctrl.loadRegistry(0)).?;
    defer fixture.ctrl.freeRegistry(loaded);

    // Keep is 3: the rewrite keeps the three newest lines and then appends the
    // new one, so host 0 holds four and host 1 keeps its one. The inert host is
    // gone.
    try std.testing.expectEqual(@as(usize, 5), loaded.len);
    try std.testing.expectEqual(@as(u128, 11), loaded[0].state);
    try std.testing.expectEqual(@as(u128, 12), loaded[1].state);
    try std.testing.expectEqual(@as(u128, 13), loaded[2].state);
    try std.testing.expectEqual(@as(u8, 1), loaded[3].host_idx);
    try std.testing.expectEqual(@as(u128, 2), loaded[3].state);
    try std.testing.expectEqual(@as(u128, 14), loaded[4].state);

    // The verbatim survivors keep their original rendering.
    try std.testing.expectEqualStrings("s1", loaded[3].snapshot_path);
    try std.testing.expectEqualStrings("w1", loaded[3].wal_path);

    try std.testing.expectEqual(@as(u128, 14), Controller.lastLineFor(loaded, 0).?.state);
    try std.testing.expectEqual(@as(u128, 2), Controller.lastLineFor(loaded, 1).?.state);
}

test "an unparseable registry line is the distinct fatality" {
    const allocator = std.testing.allocator;

    var fixture: RegistryFixture = undefined;
    try fixture.init(1, 3);
    defer fixture.deinit();

    try fixture.ctrl.ensureIndexDir(0);
    const registry = try fixture.ctrl.registryPath(0);
    defer allocator.free(registry);

    try writeRawFile(registry,
        \\{"host_idx":0,"snapshot_path":"s","wal_path":"w","state":1}
        \\not json at all
        \\
    );
    try std.testing.expectError(error.RegistryCorrupt, fixture.ctrl.loadRegistry(0));

    // A structurally valid line with a missing key is just as corrupt.
    try writeRawFile(registry, "{\"host_idx\":0,\"snapshot_path\":\"s\"}\n");
    try std.testing.expectError(error.RegistryCorrupt, fixture.ctrl.loadRegistry(0));

    // The rewrite propagates the same fatality before it writes anything.
    try std.testing.expectError(error.RegistryCorrupt, fixture.ctrl.rewriteRegistry(0, .{
        .host_idx = 0,
        .snapshot_path = @constCast("s"),
        .wal_path = @constCast("w"),
        .state = 1,
    }));
}

test "the rewrite truncates a leftover staging file" {
    const allocator = std.testing.allocator;

    var fixture: RegistryFixture = undefined;
    try fixture.init(1, 3);
    defer fixture.deinit();

    try fixture.ctrl.ensureIndexDir(0);
    const pending = try fixture.ctrl.registryPendingPath(0);
    defer allocator.free(pending);
    try writeRawFile(pending, "junk from a crashed procedure, plus a lot of it\n");

    try fixture.ctrl.rewriteRegistry(0, .{
        .host_idx = 0,
        .snapshot_path = @constCast("s"),
        .wal_path = @constCast("w"),
        .state = 7,
    });

    const registry = try fixture.ctrl.registryPath(0);
    defer allocator.free(registry);
    const fixed = try readRawFile(registry);
    defer allocator.free(fixed);
    try std.testing.expectEqualStrings(
        "{\"host_idx\":0,\"snapshot_path\":\"s\",\"wal_path\":\"w\",\"state\":7}\n",
        fixed,
    );

    // The rename consumed the staging name: no junk survives it.
    const staged_z = try allocator.dupeSentinel(u8, pending, 0);
    defer allocator.free(staged_z);
    const staged_fd = std.os.linux.open(staged_z, .{ .ACCMODE = .RDONLY }, 0);
    const staged_errno = std.os.linux.errno(staged_fd);
    if (staged_errno == .SUCCESS) _ = std.os.linux.close(@intCast(staged_fd));
    try std.testing.expectEqual(std.os.linux.E.NOENT, staged_errno);
}

test "a registry state above maxInt(u64) round-trips" {
    const allocator = std.testing.allocator;

    var fixture: RegistryFixture = undefined;
    try fixture.init(1, 3);
    defer fixture.deinit();

    const big: u128 = @as(u128, std.math.maxInt(u64)) + 12345;
    try fixture.ctrl.rewriteRegistry(0, .{
        .host_idx = 0,
        .snapshot_path = @constCast("s"),
        .wal_path = @constCast("w"),
        .state = big,
    });

    const loaded = (try fixture.ctrl.loadRegistry(0)).?;
    defer fixture.ctrl.freeRegistry(loaded);
    try std.testing.expectEqual(big, loaded[0].state);

    const registry = try fixture.ctrl.registryPath(0);
    defer allocator.free(registry);
    const raw = try readRawFile(registry);
    defer allocator.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "18446744073709563960") != null);
}

test "the cross-task and snapshot pools are independent on one controller" {
    var fixture: WalFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    // Exhaust the cross-task pool; the snapshot pool is untouched.
    var cross: [8]u32 = undefined;
    for (&cross) |*slot| slot.* = try fixture.ctrl.cross_slots.acquire();
    try std.testing.expectEqual(@as(usize, 0), fixture.ctrl.cross_slots.freeCount());
    try std.testing.expectEqual(@as(usize, 8), fixture.ctrl.snapshot_slots.freeCount());

    // And the other way around: the snapshot pool still hands out its own
    // indexes while the cross-task pool stays exhausted.
    var snaps: [8]u32 = undefined;
    for (&snaps, 0..) |*slot, i| {
        slot.* = try fixture.ctrl.snapshot_slots.acquire();
        try std.testing.expectEqual(@as(u32, @intCast(i)), slot.*);
    }
    try std.testing.expectEqual(@as(usize, 0), fixture.ctrl.snapshot_slots.freeCount());
    try std.testing.expectError(error.CrossTaskFull, fixture.ctrl.snapshot_slots.acquire());
    try std.testing.expectError(error.CrossTaskFull, fixture.ctrl.cross_slots.acquire());

    for (snaps) |slot| fixture.ctrl.snapshot_slots.release(slot);
    for (cross) |slot| fixture.ctrl.cross_slots.release(slot);
    try std.testing.expectEqual(@as(usize, 8), fixture.ctrl.snapshot_slots.freeCount());
    try std.testing.expectEqual(@as(usize, 8), fixture.ctrl.cross_slots.freeCount());
}

test "mint renders the pinned names and the teardown releases the job" {
    const allocator = std.testing.allocator;

    var fixture: WalFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const tag: u128 = 0x2a;
    const job = try fixture.ctrl.mintSnapshotJob(1, 1, tag, 3, 0);
    defer fixture.ctrl.releaseSnapshotJob(job);

    // The identity the procedure's messages and replies are routed by.
    try std.testing.expectEqual(@as(u8, 1), job.host_idx);
    try std.testing.expectEqual(@as(u16, 1), job.index_idx);
    try std.testing.expectEqual(@as(u16, 0), job.ring_idx);
    try std.testing.expectEqual(tag, job.tag);
    try std.testing.expectEqual(@as(u32, 3), job.k);
    try std.testing.expectEqual(SnapshotPhase.create_sent, job.phase);
    try std.testing.expectEqual(@as(posix.fd_t, -1), job.fd);
    try std.testing.expectEqual(@as(posix.fd_t, -1), job.old_fd);

    // Both names live under the originating index's directory and carry the
    // pair's identity with the tag, zero-padded to 32 lowercase hex digits.
    const dir = try fixture.ctrl.indexDirPath(1);
    defer allocator.free(dir);
    const want_wal = try std.fmt.allocPrint(allocator, "{s}/wal.1.1.0000000000000000000000000000002a", .{dir});
    defer allocator.free(want_wal);
    const want_snapshot = try std.fmt.allocPrint(allocator, "{s}/snapshot.1.1.0000000000000000000000000000002a", .{dir});
    defer allocator.free(want_snapshot);
    try std.testing.expectEqualStrings(want_wal, job.wal_path);
    try std.testing.expectEqualStrings(want_snapshot, job.snapshot_path);

    // The arena is live and empty: the handler pass allocates the clone and
    // the dump's bytes through it, and the teardown above frees them all under
    // the testing allocator.
    const bytes = try job.arena.allocator().alloc(u8, 128);
    try std.testing.expectEqual(@as(usize, 128), bytes.len);
    const clone = try fixture.ctrl.cloneIndexState(&state.IndexState{
        .state = tag,
        .sessions = state.SessionsMap.init(job.arena.allocator()),
        .replay_queue = replay_queue.ReplayQueue.init(job.arena.allocator()),
    }, job.arena.allocator());
    job.clone = clone;
    try std.testing.expectEqual(tag, job.clone.state);
}

test "nextElephantRing round-robins over the elephant rings" {
    var cfg: config.Config = undefined;
    cfg.fronts = 1;
    cfg.indexes = 2;
    cfg.elephants = 3;
    cfg.queue_depth = 64;
    cfg.cross_task_slots = 8;
    cfg.sqpoll_threads = 1;
    cfg.wal = .{ .plain = .{ .dir = "wal" } };
    cfg.snapshots = .{};
    cfg.ring_slots_capacity = 4096;
    cfg.index_inbox_capacity = 8;
    cfg.logging = .{
        .method = .{ .json = {} },
        .pool_capacity = 64,
        .pool_frame_size = 1024,
    };

    var ctrl: Controller = undefined;
    try ctrl.init(std.testing.allocator, &cfg);
    defer ctrl.deinit();

    // Elephants occupy the tail of the ring layout, after fronts and indexes.
    const first: u16 = cfg.fronts + cfg.indexes;
    for (0..2) |_| {
        for (0..cfg.elephants) |i| {
            try std.testing.expectEqual(first + @as(u16, @intCast(i)), ctrl.nextElephantRing());
        }
    }

    // Two racing threads, each picking one full round twice over: whatever the
    // interleaving, every elephant gets the same share, so the picks are a
    // permutation of a whole number of rounds.
    const Worker = struct {
        ctrl: *Controller,
        counts: *[3]std.atomic.Value(u32),
        first: u16,

        fn run(self: *@This()) void {
            for (0..12) |_| {
                const ring_idx = self.ctrl.nextElephantRing();
                _ = self.counts[ring_idx - self.first].fetchAdd(1, .monotonic);
            }
        }
    };

    var counts = [_]std.atomic.Value(u32){
        std.atomic.Value(u32).init(0),
        std.atomic.Value(u32).init(0),
        std.atomic.Value(u32).init(0),
    };
    var workers = [_]Worker{
        .{ .ctrl = &ctrl, .counts = &counts, .first = first },
        .{ .ctrl = &ctrl, .counts = &counts, .first = first },
    };
    var threads: [2]std.Thread = undefined;
    for (&workers, &threads) |*worker, *thread| thread.* = try std.Thread.spawn(.{}, Worker.run, .{worker});
    for (&threads) |thread| thread.join();

    const expected: u32 = @intCast(2 * 12 / cfg.elephants);
    for (counts) |count| try std.testing.expectEqual(expected, count.load(.monotonic));
}

/// The composite's sink in the window tests: every submission is held, so the
/// test decides when a flush completes and observes the both-sides rule one
/// frontier at a time.
const HeldSink = struct {
    fn room(ctx: ?*anyopaque, writer: *wal.WalWriteFile) wal.WalError!void {
        _ = ctx;
        _ = writer;
    }

    fn submit(ctx: ?*anyopaque, writer: *wal.WalWriteFile, ordinal: u64) void {
        _ = ctx;
        _ = writer;
        _ = ordinal;
    }

    fn install(writer: *wal.WalWriteFile) void {
        writer.sink = .{ .room = room, .submit = submit };
    }
};

/// The composite's completion log, in delivery order.
const CompletionLog = struct {
    ends: [8]u64 = undefined,
    len: usize = 0,

    fn push(ctx: ?*anyopaque, end: u64) void {
        const self: *CompletionLog = @ptrCast(@alignCast(ctx.?));
        self.ends[self.len] = end;
        self.len += 1;
    }
};

test "a composite event completes only when both sides' flushes cover it" {
    var fixture: WalFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    // The pair has history: the old writer chains from the file's tag.
    const opened = try fixture.create(0, 0, 0x100);
    _ = std.os.linux.close(opened);
    const old = try fixture.ctrl.walOpenWrite(0, 0, 0x100);

    // The window's writer runs on temp ring 0, chained from the clone state Y.
    const new = try fixture.ctrl.walAdoptWrite(0, 0, 0, 0x100, try fixture.create(0, 0, 0x101));
    defer {
        _ = std.os.linux.close(new.fd);
        fixture.ctrl.allocator.destroy(new);
    }

    HeldSink.install(old);
    HeldSink.install(new);

    var log = CompletionLog{};
    var composite = CompositeWriter{
        .new = new,
        .old = old,
        .allocator = std.testing.allocator,
        .onComplete = CompletionLog.push,
        .on_complete_ctx = &log,
    };
    defer composite.pending.deinit(std.testing.allocator);

    // 494 op bytes frame to exactly one buffer on both sides.
    var op: [494]u8 = undefined;
    for (&op, 0..) |*byte, i| byte.* = @truncate(i *% 31 +% 1);

    try composite.write(0x101, &op);
    try std.testing.expectEqual(@as(usize, 1), composite.pending.items.len);
    try std.testing.expect(old.flush_in_flight and new.flush_in_flight);
    try std.testing.expect(!composite.quiet());

    // Old-side coverage alone completes nothing: the event must be durable in
    // both files or either crash outcome loses it.
    old.flushResult(.{ .user_data = 0, .res = 512, .flags = 0 });
    composite.noteFlush(old);
    try std.testing.expectEqual(@as(usize, 0), log.len);
    try std.testing.expectEqual(@as(usize, 1), composite.pending.items.len);

    // The new side's flush lands on the same buffer: now it is complete.
    new.flushResult(.{ .user_data = 0, .res = 512, .flags = 0 });
    composite.noteFlush(new);
    try std.testing.expectEqual(@as(usize, 1), log.len);
    try std.testing.expectEqual(@as(u64, 512), log.ends[0]);
    try std.testing.expectEqual(@as(usize, 0), composite.pending.items.len);
    try std.testing.expect(composite.quiet());

    // A mid-buffer tail event has no flush of its own; it completes when the
    // buffer it ends in fills and both sides flush it.
    var tail: [100]u8 = undefined;
    @memset(&tail, 0x5a);
    try composite.write(0x102, &tail);
    try std.testing.expectEqual(@as(usize, 1), composite.pending.items.len);
    try std.testing.expect(composite.quiet());

    // 377 op bytes frame to 395: 117 + 395 fills the open buffer exactly.
    var filler: [377]u8 = undefined;
    @memset(&filler, 0xa5);
    try composite.write(0x103, &filler);
    try std.testing.expectEqual(@as(usize, 2), composite.pending.items.len);
    try std.testing.expect(old.flush_in_flight and new.flush_in_flight);

    // New-side coverage alone still completes nothing.
    new.flushResult(.{ .user_data = 0, .res = 512, .flags = 0 });
    composite.noteFlush(new);
    try std.testing.expectEqual(@as(usize, 1), log.len);

    // The old side's covering flush completes both, in write order.
    old.flushResult(.{ .user_data = 0, .res = 512, .flags = 0 });
    composite.noteFlush(old);
    try std.testing.expectEqual(@as(usize, 3), log.len);
    try std.testing.expectEqual(@as(u64, 629), log.ends[1]);
    try std.testing.expectEqual(@as(u64, 1024), log.ends[2]);
    try std.testing.expectEqual(@as(usize, 0), composite.pending.items.len);
    try std.testing.expect(composite.quiet());
}

test "the adoption mark publishes on the pair's control line and clears" {
    var fixture: WalFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const stride = fixture.ctrl.wal_area_stride;
    try fixture.ctrl.acquireWalBattery();
    const battery = fixture.ctrl.wal_battery.?;
    const buffers = fixture.cfg.wal.buffers();
    const lba = fixture.cfg.wal.lba();

    // Pair 1, host 0: the mark lands on that pair's line only.
    try fixture.ctrl.publishAdoptionMark(0, 1, 3, 0xABC);
    const line = wal.controlLineOf(battery[1 * stride ..][0..stride], buffers, lba);
    try std.testing.expectEqual(@as(u8, 1), line.snapshot_in_progress);
    try std.testing.expectEqual(@as(u16, 3), line.new_wal_buffer_idx);
    try std.testing.expectEqual(@as(u128, 0xABC), line.target_state);
    const untouched = wal.controlLineOf(battery[0..stride], buffers, lba);
    try std.testing.expectEqual(@as(u8, 0), untouched.snapshot_in_progress);

    // The clear zeroes the whole line, not only the flag.
    try fixture.ctrl.clearAdoptionMark(0, 1);
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&std.mem.zeroes(wal.BufferHeader)),
        std.mem.asBytes(line),
    );
}

test "the swap copy moves temp ring k's data and headers into the pair area" {
    var fixture: WalFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const stride = fixture.ctrl.wal_area_stride;
    try fixture.ctrl.acquireWalBattery();
    const battery = fixture.ctrl.wal_battery.?;
    const buffers = fixture.cfg.wal.buffers();
    const lba = fixture.cfg.wal.lba();
    const pairs = fixture.ctrl.wal_pairs;

    // A used temp ring: distinct bytes in both arrays.
    const temp_bytes = battery[wal.tempAreaIdx(0, pairs) * stride ..][0..stride];
    const temp = wal.Area.init(temp_bytes, buffers, lba);
    @memset(temp.data, 0x3c);
    for (temp.headers, 0..) |*header, ordinal| header.* = .{
        .data_len = lba,
        .flags = wal.FLAG_FILLED,
        .buffer_seq = ordinal,
        .crc_running = 7,
        .snapshot_in_progress = 0,
        .new_wal_buffer_idx = 0,
        .last_state = 0x55,
        .target_state = 0,
        ._pad_tail = @splat(0),
    };

    // The pair's mark must not be crossed by the copy.
    try fixture.ctrl.publishAdoptionMark(0, 0, 0, 0x55);

    const moved = try fixture.ctrl.copyTempIntoPair(0, 0);
    const pair_bytes = battery[0..stride];
    try std.testing.expectEqual(@intFromPtr(pair_bytes.ptr), @intFromPtr(moved.data.ptr));

    const pair = wal.Area.init(pair_bytes, buffers, lba);
    try std.testing.expectEqualSlices(u8, temp.data, pair.data);
    try std.testing.expectEqualSlices(
        u8,
        std.mem.sliceAsBytes(temp.headers),
        std.mem.sliceAsBytes(pair.headers),
    );
    try std.testing.expectEqual(@as(u8, 1), wal.controlLineOf(pair_bytes, buffers, lba).snapshot_in_progress);
}

// ============================================================================
// Startup recovery: the adoption rule and the bring-tail
// ============================================================================

/// A controller over a throwaway WAL root and a plain file standing in for the
/// NVDIMM: PMEM mode maps the device as found, so the battery survives a
/// `reopen` exactly as a crash would leave it.
const PmemFixture = struct {
    tmp: std.testing.TmpDir,
    dir: []u8,
    device: []u8,
    cfg: config.Config,
    ctrl: Controller,
    live: bool = false,

    fn init(self: *PmemFixture, hosts: u32) !void {
        const allocator = std.testing.allocator;
        self.tmp = std.testing.tmpDir(.{});
        self.dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{self.tmp.sub_path[0..]});
        errdefer allocator.free(self.dir);
        self.device = try std.fmt.allocPrint(allocator, "{s}/pmem0", .{self.dir});
        errdefer allocator.free(self.device);

        self.cfg = .{
            .fronts = 1,
            .indexes = 1,
            .elephants = 1,
            .queue_depth = 64,
            .cross_task_slots = 8,
            .sqpoll_threads = 1,
            .ring_slots_capacity = 4096,
            .index_inbox_capacity = 8,
            .wal = .{ .pmem = .{
                .dir = self.dir,
                .device = self.device,
                .buffers = 4,
                .lba = 512,
                .hosts = hosts,
            } },
            .snapshots = .{ .registry_keep = 8 },
            .logging = .{
                .method = .{ .json = {} },
                .pool_capacity = 64,
                .pool_frame_size = 1024,
            },
        };

        try self.sizeDevice();
        try self.openCtrl();
    }

    fn sizeDevice(self: *PmemFixture) !void {
        const allocator = std.testing.allocator;
        const pairs = @as(usize, self.cfg.indexes) * self.cfg.wal.hosts();
        const areas = pairs + self.cfg.snapshots.slots;
        const stride = wal.areaStride(self.cfg.wal.buffers(), self.cfg.wal.lba(), std.heap.pageSize());
        const needed = areas * stride;

        const path = try allocator.dupeSentinel(u8, self.device, 0);
        defer allocator.free(path);
        const fd_raw = std.os.linux.open(path, .{ .ACCMODE = .RDWR, .CREAT = true }, 0o644);
        if (std.os.linux.errno(fd_raw) != .SUCCESS) return error.TestUnexpectedResult;
        const fd: posix.fd_t = @intCast(fd_raw);
        defer _ = std.os.linux.close(fd);
        if (std.os.linux.errno(std.os.linux.ftruncate(fd, @intCast(needed))) != .SUCCESS) {
            return error.TestUnexpectedResult;
        }
    }

    fn openCtrl(self: *PmemFixture) !void {
        try self.ctrl.init(std.testing.allocator, &self.cfg);
        try self.ctrl.compensators.put("marker", .{ .bind = "10.0.0.1", .port = 20301 });
        self.live = true;
    }

    /// The crash: tear this process's mapping and handles down, then map the
    /// same device again as a restart would.
    fn reopen(self: *PmemFixture) !void {
        self.ctrl.deinit();
        self.live = false;
        try self.openCtrl();
    }

    fn deinit(self: *PmemFixture) void {
        if (self.live) self.ctrl.deinit();
        std.testing.allocator.free(self.dir);
        std.testing.allocator.free(self.device);
        self.tmp.cleanup();
    }
};

fn pmemArea(f: *PmemFixture, idx: usize) wal.Area {
    const bytes = f.ctrl.walArea(idx) catch unreachable;
    return wal.Area.init(bytes, f.cfg.wal.buffers(), f.cfg.wal.lba());
}

fn pmemPair(f: *PmemFixture, host_idx: u8, index_idx: u16) wal.Area {
    return pmemArea(f, wal.areaIndex(host_idx, index_idx, f.cfg.wal.hosts()));
}

fn pmemTemp(f: *PmemFixture, k: u32) wal.Area {
    return pmemArea(f, wal.tempAreaIdx(k, f.ctrl.wal_pairs));
}

fn pmemMark(f: *PmemFixture, host_idx: u8, index_idx: u16) *wal.BufferHeader {
    const pair = wal.areaIndex(host_idx, index_idx, f.cfg.wal.hosts());
    const bytes = f.ctrl.walArea(pair) catch unreachable;
    return wal.controlLineOf(bytes, f.cfg.wal.buffers(), f.cfg.wal.lba());
}

/// Fills an area's arrays with a recognizable chain: distinct bytes and one
/// terminator per slot carrying `base + ordinal`.
fn fillViews(area: wal.Area, byte: u8, base: u128) void {
    @memset(area.data, byte);
    for (area.headers, 0..) |*header, ordinal| {
        header.* = .{
            .data_len = 0,
            .flags = 0,
            .buffer_seq = @intCast(ordinal),
            .crc_running = 0,
            .snapshot_in_progress = 0,
            .new_wal_buffer_idx = 0,
            .last_state = base + ordinal,
            .target_state = 0,
            ._pad_tail = @splat(0),
        };
    }
}

fn pmemCreateFile(f: *PmemFixture, host_idx: u8, index_idx: u16, tag: u128) !posix.fd_t {
    try f.ctrl.ensureIndexDir(index_idx);
    const dir = try f.ctrl.indexDirPath(index_idx);
    defer std.testing.allocator.free(dir);
    const path = try wal.walPath(std.testing.allocator, dir, host_idx, index_idx, tag);
    defer std.testing.allocator.free(path);

    const fd_raw = std.os.linux.open(path, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, 0o644);
    const errno = std.os.linux.errno(fd_raw);
    if (errno != .SUCCESS) return std.posix.unexpectedErrno(errno);
    return @intCast(fd_raw);
}

fn writeRegistryLine(
    f: *PmemFixture,
    index_idx: u16,
    host_idx: u8,
    wal_tag: u128,
    snapshot_tag: u128,
    state_y: u128,
) !void {
    const dir = try f.ctrl.indexDirPath(index_idx);
    defer std.testing.allocator.free(dir);

    const wal_path = try wal.walPath(std.testing.allocator, dir, host_idx, index_idx, wal_tag);
    defer std.testing.allocator.free(wal_path);
    const snapshot_path = try wal.snapshotPath(std.testing.allocator, dir, host_idx, index_idx, snapshot_tag);
    defer std.testing.allocator.free(snapshot_path);

    try f.ctrl.rewriteRegistry(index_idx, .{
        .host_idx = host_idx,
        .snapshot_path = snapshot_path,
        .wal_path = wal_path,
        .state = state_y,
    });
}

fn isOrdinary(result: Controller.AdoptionResult) bool {
    return std.meta.activeTag(result) == .ordinary;
}

fn isAdopted(result: Controller.AdoptionResult) bool {
    return std.meta.activeTag(result) == .adopted;
}

test "crash row create reply to mark: the pair is ordinary" {
    var f: PmemFixture = undefined;
    try f.init(1);
    defer f.deinit();

    const before = pmemPair(&f, 0, 0);
    fillViews(before, 0x11, 0xA0);

    const result = try f.ctrl.runAdoptionRule(0, 0);
    try std.testing.expect(isOrdinary(result));

    const after = pmemPair(&f, 0, 0);
    try std.testing.expectEqualSlices(u8, before.data, after.data);
    try std.testing.expectEqualSlices(
        u8,
        std.mem.sliceAsBytes(before.headers),
        std.mem.sliceAsBytes(after.headers),
    );
    try std.testing.expectEqual(@as(u8, 0), pmemMark(&f, 0, 0).snapshot_in_progress);
}

test "crash row mark to line commit: the migration aborts and nothing is copied" {
    var f: PmemFixture = undefined;
    try f.init(1);
    defer f.deinit();

    const pair = pmemPair(&f, 0, 0);
    fillViews(pair, 0x11, 0xA0);
    const temp = pmemTemp(&f, 1);
    fillViews(temp, 0x22, 0x900);

    try f.ctrl.publishAdoptionMark(0, 0, 1, 0x900);
    // The winning line is still the previous pair's.
    try writeRegistryLine(&f, 0, 0, 0x800, 0x800, 0x810);

    const result = try f.ctrl.runAdoptionRule(0, 0);
    switch (result) {
        .aborted => |abort| {
            try std.testing.expectEqual(@as(u32, 1), abort.k);
            try std.testing.expectEqual(@as(u128, 0x900), abort.tag);
        },
        else => return error.TestUnexpectedResult,
    }

    // The pair still bears only its old chain, and the mark is gone.
    const after = pmemPair(&f, 0, 0);
    try std.testing.expectEqualSlices(u8, pair.data, after.data);
    try std.testing.expectEqualSlices(
        u8,
        std.mem.sliceAsBytes(pair.headers),
        std.mem.sliceAsBytes(after.headers),
    );
    try std.testing.expectEqual(@as(u8, 0), pmemMark(&f, 0, 0).snapshot_in_progress);
}

test "crash row line commit to copy: the adoption re-copies ring k" {
    var f: PmemFixture = undefined;
    try f.init(1);
    defer f.deinit();

    const pair = pmemPair(&f, 0, 0);
    fillViews(pair, 0x11, 0xA0);
    const temp = pmemTemp(&f, 1);
    fillViews(temp, 0x22, 0x900);

    try f.ctrl.publishAdoptionMark(0, 0, 1, 0x900);
    // The line names the migrating pair: its WAL leaf carries the marked tag.
    try writeRegistryLine(&f, 0, 0, 0x900, 0x900, 0x910);

    const result = try f.ctrl.runAdoptionRule(0, 0);
    try std.testing.expect(isAdopted(result));

    const after = pmemPair(&f, 0, 0);
    try std.testing.expectEqualSlices(u8, temp.data, after.data);
    try std.testing.expectEqualSlices(
        u8,
        std.mem.sliceAsBytes(temp.headers),
        std.mem.sliceAsBytes(after.headers),
    );
    try std.testing.expectEqual(@as(u8, 0), pmemMark(&f, 0, 0).snapshot_in_progress);
}

test "crash row mid-copy: the adoption finishes the torn pair area forward" {
    var f: PmemFixture = undefined;
    try f.init(1);
    defer f.deinit();

    const pair = pmemPair(&f, 0, 0);
    fillViews(pair, 0x11, 0xA0);
    const temp = pmemTemp(&f, 1);
    fillViews(temp, 0x22, 0x900);

    // The copy started and tore: the first half of both arrays landed.
    const half = pair.data.len / 2;
    @memcpy(pair.data[0..half], temp.data[0..half]);
    @memcpy(
        std.mem.sliceAsBytes(pair.headers[0..2]),
        std.mem.sliceAsBytes(temp.headers[0..2]),
    );

    try f.ctrl.publishAdoptionMark(0, 0, 1, 0x900);
    try writeRegistryLine(&f, 0, 0, 0x900, 0x900, 0x910);

    const result = try f.ctrl.runAdoptionRule(0, 0);
    try std.testing.expect(isAdopted(result));

    const after = pmemPair(&f, 0, 0);
    try std.testing.expectEqualSlices(u8, temp.data, after.data);
    try std.testing.expectEqualSlices(
        u8,
        std.mem.sliceAsBytes(temp.headers),
        std.mem.sliceAsBytes(after.headers),
    );
    try std.testing.expectEqual(@as(u8, 0), pmemMark(&f, 0, 0).snapshot_in_progress);
}

test "crash row copy to mark clear: the repeated copy is a no-op" {
    var f: PmemFixture = undefined;
    try f.init(1);
    defer f.deinit();

    const pair = pmemPair(&f, 0, 0);
    const temp = pmemTemp(&f, 1);
    fillViews(temp, 0x22, 0x900);
    @memcpy(pair.data, temp.data);
    @memcpy(std.mem.sliceAsBytes(pair.headers), std.mem.sliceAsBytes(temp.headers));

    try f.ctrl.publishAdoptionMark(0, 0, 1, 0x900);
    try writeRegistryLine(&f, 0, 0, 0x900, 0x900, 0x910);

    const first = try f.ctrl.runAdoptionRule(0, 0);
    try std.testing.expect(isAdopted(first));
    try std.testing.expectEqual(@as(u8, 0), pmemMark(&f, 0, 0).snapshot_in_progress);

    // The crash between the copy and the clear leaves the mark set; the second
    // run repeats the copy, which is the same bytes.
    try f.ctrl.publishAdoptionMark(0, 0, 1, 0x900);
    const second = try f.ctrl.runAdoptionRule(0, 0);
    try std.testing.expect(isAdopted(second));

    const after = pmemPair(&f, 0, 0);
    try std.testing.expectEqualSlices(u8, temp.data, after.data);
    try std.testing.expectEqualSlices(
        u8,
        std.mem.sliceAsBytes(temp.headers),
        std.mem.sliceAsBytes(after.headers),
    );
    try std.testing.expectEqual(@as(u8, 0), pmemMark(&f, 0, 0).snapshot_in_progress);
}

test "crash row post-swap: the new pair is ordinary" {
    var f: PmemFixture = undefined;
    try f.init(1);
    defer f.deinit();

    const pair = pmemPair(&f, 0, 0);
    fillViews(pair, 0x33, 0x910);
    try writeRegistryLine(&f, 0, 0, 0x900, 0x900, 0x910);

    const result = try f.ctrl.runAdoptionRule(0, 0);
    try std.testing.expect(isOrdinary(result));

    const after = pmemPair(&f, 0, 0);
    try std.testing.expectEqualSlices(u8, pair.data, after.data);
    try std.testing.expectEqualSlices(
        u8,
        std.mem.sliceAsBytes(pair.headers),
        std.mem.sliceAsBytes(after.headers),
    );
}

test "plain mode's zeroed battery always lands on ordinary" {
    var fixture: WalFixture = undefined;
    try fixture.init();

    // Both shapes: no registry at all, and a line naming a WAL. The mark can
    // never be there, because a plain battery is zeroed at allocation.
    try std.testing.expect(isOrdinary(try fixture.ctrl.runAdoptionRule(0, 0)));

    const dir = try fixture.ctrl.indexDirPath(0);
    defer fixture.deinit();
    defer std.testing.allocator.free(dir);
    const wal_path = try wal.walPath(std.testing.allocator, dir, 0, 0, 0x900);
    defer std.testing.allocator.free(wal_path);
    const snapshot_path = try wal.snapshotPath(std.testing.allocator, dir, 0, 0, 0x900);
    defer std.testing.allocator.free(snapshot_path);
    try fixture.ctrl.rewriteRegistry(0, .{
        .host_idx = 0,
        .snapshot_path = snapshot_path,
        .wal_path = wal_path,
        .state = 0x910,
    });

    try std.testing.expect(isOrdinary(try fixture.ctrl.runAdoptionRule(0, 0)));
}

/// A synchronous sink that also writes the buffer into the file: the battery
/// and the file advance together, as a PMEM flush does with `RWF.DSYNC`.
/// `flushComplete` then publishes the resume terminator exactly as a real
/// completion would.
const FileSink = struct {
    fn room(ctx: ?*anyopaque, writer: *wal.WalWriteFile) wal.WalError!void {
        _ = ctx;
        _ = writer;
    }

    fn submit(ctx: ?*anyopaque, writer: *wal.WalWriteFile, ordinal: u64) void {
        _ = ctx;
        const data = writer.bufferData(ordinal);
        const base: posix.off_t = @intCast(ordinal * @as(u64, writer.lba));
        var done: usize = 0;
        while (done < data.len) {
            const at = base + @as(posix.off_t, @intCast(done));
            const res = std.os.linux.pwrite(writer.fd, data[done..].ptr, data.len - done, at);
            const errno = std.os.linux.errno(res);
            if (errno != .SUCCESS) {
                writer.fault(errno);
                return;
            }
            done += res;
        }
        writer.flushComplete(ordinal);
    }

    fn install(writer: *wal.WalWriteFile) void {
        writer.sink = .{ .room = room, .submit = submit };
    }
};

/// One 494-byte op frames to exactly one 512-byte buffer, so every record
/// fills and flushes immediately under the synchronous sink.
const tail_op_len: usize = 494;

fn tailOp(seed: u8) [tail_op_len]u8 {
    var op: [tail_op_len]u8 = undefined;
    for (&op, 0..) |*byte, i| byte.* = @truncate(i *% 31 +% seed);
    return op;
}

test "the bring-tail recovers the inter-write cut's surplus record" {
    var f: PmemFixture = undefined;
    try f.init(1);
    defer f.deinit();

    const old_tag: u128 = 8;
    const x: u128 = 9;
    const y: u128 = 10;
    const k: u32 = 0;

    const opened = try pmemCreateFile(&f, 0, 0, old_tag);
    _ = std.os.linux.close(opened);
    const old = try f.ctrl.walOpenWrite(0, 0, old_tag);
    FileSink.install(old);

    var op9 = tailOp(9);
    var op10 = tailOp(10);
    var op11 = tailOp(11);
    var op12 = tailOp(12);
    var op13 = tailOp(13);
    try old.write(9, old.head, &op9);
    try old.write(10, 9, &op10);

    // The window: the new writer runs on temp ring 0, its file named `X` and
    // its chain anchored at the clone state `Y`.
    const new = try f.ctrl.walAdoptWrite(0, 0, k, y, try pmemCreateFile(&f, 0, 0, x));
    FileSink.install(new);
    try f.ctrl.publishAdoptionMark(0, 0, k, x);

    try new.write(11, new.head, &op11);
    try old.write(11, old.head, &op11);
    try new.write(12, new.head, &op12);
    try old.write(12, old.head, &op12);
    // The cut: new first, old never.
    try new.write(13, new.head, &op13);

    // The crash: the new writer dies, the mark survives, the process goes.
    _ = std.os.linux.close(new.fd);
    f.ctrl.allocator.destroy(new);
    try f.reopen();

    const adoption = try f.ctrl.runAdoptionRule(0, 0);
    switch (adoption) {
        .aborted => |abort| {
            try std.testing.expectEqual(k, abort.k);
            try std.testing.expectEqual(x, abort.tag);
        },
        else => return error.TestUnexpectedResult,
    }

    const reopened = try f.ctrl.walOpenWrite(0, 0, old_tag);
    FileSink.install(reopened);
    try std.testing.expectEqual(@as(u128, 12), reopened.head);
    const head_before = reopened.head;

    var tail = Controller.TailSink.init(std.testing.allocator);
    defer tail.deinit();
    try f.ctrl.bringTail(0, 0, k, x, reopened, head_before, &tail);

    // The seek delivers the floor's own record (already old-side) and the
    // surplus; only the surplus is appended.
    try std.testing.expectEqual(@as(usize, 2), tail.records.items.len);
    try std.testing.expectEqual(@as(u128, 12), tail.records.items[0].state_idx);
    try std.testing.expectEqual(@as(u128, 13), tail.records.items[1].state_idx);
    try std.testing.expectEqual(@as(u128, 13), reopened.head);

    // The old chain now replays every record the new side had, once each.
    var collected = Controller.TailSink.init(std.testing.allocator);
    defer collected.deinit();
    {
        const reader = try f.ctrl.walOpenRead(0, 0, old_tag);
        defer f.ctrl.walCloseRead(reader);
        const process = try reader.beginRead(std.testing.allocator, .read_all, .{
            .ctx = &collected,
            .apply = Controller.TailSink.apply,
        });
        defer reader.endRead(std.testing.allocator, process);
        try process.drive(null);
    }
    try std.testing.expectEqual(@as(usize, 5), collected.records.items.len);
    for (collected.records.items, 0..) |record, i| {
        try std.testing.expectEqual(@as(u128, @intCast(9 + i)), record.state_idx);
    }

    // The chain continues: the floor is the head it just reached.
    var op14 = tailOp(14);
    try reopened.write(14, reopened.head, &op14);
    try std.testing.expectEqual(@as(u128, 14), reopened.head);
    try std.testing.expectEqual(@as(u8, 0), pmemMark(&f, 0, 0).snapshot_in_progress);
}

test "the bring-tail's empty delivery is a no-op" {
    var f: PmemFixture = undefined;
    try f.init(1);
    defer f.deinit();

    const old_tag: u128 = 8;
    const x: u128 = 9;
    const y: u128 = 10;

    const opened = try pmemCreateFile(&f, 0, 0, old_tag);
    _ = std.os.linux.close(opened);
    const old = try f.ctrl.walOpenWrite(0, 0, old_tag);
    FileSink.install(old);
    var op9 = tailOp(9);
    var op10 = tailOp(10);
    try old.write(9, old.head, &op9);
    try old.write(10, 9, &op10);

    // The window opened (mark, mint) but the composite never served.
    const new = try f.ctrl.walAdoptWrite(0, 0, 0, y, try pmemCreateFile(&f, 0, 0, x));
    FileSink.install(new);
    try f.ctrl.publishAdoptionMark(0, 0, 0, x);
    _ = std.os.linux.close(new.fd);
    f.ctrl.allocator.destroy(new);
    try f.reopen();

    const adoption = try f.ctrl.runAdoptionRule(0, 0);
    try std.testing.expect(std.meta.activeTag(adoption) == .aborted);

    const reopened = try f.ctrl.walOpenWrite(0, 0, old_tag);
    FileSink.install(reopened);
    const size_before = try wal.fileSize(reopened.fd);
    try std.testing.expectEqual(@as(u128, 10), reopened.head);

    var tail = Controller.TailSink.init(std.testing.allocator);
    defer tail.deinit();
    try f.ctrl.bringTail(0, 0, 0, x, reopened, reopened.head, &tail);

    try std.testing.expectEqual(@as(usize, 0), tail.records.items.len);
    try std.testing.expectEqual(@as(u128, 10), reopened.head);
    try std.testing.expectEqual(size_before, try wal.fileSize(reopened.fd));

    // And the writer still serves.
    var op11 = tailOp(11);
    try reopened.write(11, reopened.head, &op11);
}
