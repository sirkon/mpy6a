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
const logging = @import("logging.zig");
const blog = @import("blog");
const slots = @import("slots.zig");
const messages = @import("messages.zig");

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

    /// Allocates the shared arrays. Rings and inboxes stay `undefined` here:
    /// each thread publishes its own ring, and each index creates its own
    /// inbox, during its initialization.
    pub fn init(self: *Self, allocator: std.mem.Allocator, cfg: *const config.Config) !void {
        const subjects: usize = @intCast(cfg.fronts + cfg.indexes + cfg.elephants);

        const rings = try allocator.alloc(RingStuff, subjects);
        errdefer allocator.free(rings);

        const inboxes = try allocator.alloc(IndexInbox, cfg.indexes);
        errdefer allocator.free(inboxes);

        const threads = try allocator.alloc(zigring.Thread, subjects);
        errdefer allocator.free(threads);

        const thread_ctx = try allocator.alloc(ThreadContext, subjects);
        errdefer allocator.free(thread_ctx);

        self.* = .{
            .allocator = allocator,
            .cfg = cfg,
            .rolling_role_idx = 0,
            .rings = rings,
            .inboxes = inboxes,
            .ring_factory = undefined,
            .init_ring = undefined,
            .cross_slots = undefined,
            .threads = threads,
            .thread_ctx = thread_ctx,
            .spawned = 0,
        };

        try self.ring_factory.init(allocator, cfg.sqpoll_threads);
        errdefer self.ring_factory.deinit();
        try self.initGivenRing(&self.init_ring, 0);
        errdefer self.init_ring.deinit();

        try self.cross_slots.init(allocator, cfg.cross_task_slots);
        errdefer self.cross_slots.deinit();
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

        self.allocator.free(self.thread_ctx);
        self.allocator.free(self.threads);
        self.allocator.free(self.inboxes);
        self.allocator.free(self.rings);
        self.cross_slots.deinit();
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
            .index => |r| self.initIndexInbox(r.inbox_idx, ring_idx) catch |err| fatal("index inbox initialization", ring_idx, err),
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
};

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
