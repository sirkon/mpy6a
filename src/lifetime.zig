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

    /// Client socket bookkeeping shared by every front and every index: the
    /// tag of each open client socket, indexed by the descriptor value itself.
    sockets: SocketTable,

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

        var sockets = try SocketTable.init(allocator, pinSocketLimit());
        errdefer sockets.deinit(allocator);

        self.* = .{
            .allocator = allocator,
            .cfg = cfg,
            .rolling_role_idx = 0,
            .rings = rings,
            .inboxes = inboxes,
            .ring_factory = undefined,
            .init_ring = undefined,
            .cross_slots = undefined,
            .sockets = sockets,
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
        self.sockets.deinit(self.allocator);
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

        const fd_raw = std.os.linux.open(log_file, .{ .ACCMODE = .WRONLY, .APPEND = true, .CREAT = true }, 0o644);
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
                    .counter_slot = domain_idx % index_per_front,
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

        try bindAndListen(fd, ip, cfg.accept_backlog);
        return fd;
    }

    /// Creates, binds and listens on the replication endpoint of `cluster`
    /// mode (2.3). Unlike the client listener this one belongs to the fronts,
    /// since a front is what accepts a mirror connection and reads its
    /// greeting: every front binds the endpoint with `SO_REUSEPORT`, the
    /// kernel spreads the dialling peers over them, and the greeting decides
    /// which index service a connection serves, never the listener it arrived
    /// on.
    pub fn createReplicationSocket(self: *Self) !std.posix.fd_t {
        const cfg = self.cfg;
        const cluster = switch (cfg.replication.mode) {
            .cluster => |cluster| cluster,
            // Single-host mode has no replication plane to listen on.
            .local => return error.NotClusterMode,
        };

        const ip = if (std.mem.eql(u8, cluster.bind.host, "localhost"))
            std.Io.net.Ip4Address.loopback(cluster.bind.port)
        else
            try std.Io.net.Ip4Address.parse(cluster.bind.host, cluster.bind.port);

        const fd = try zigring.createTCPServerSocket();
        errdefer _ = std.os.linux.close(fd);

        // The option must precede the bind, and sharing it only makes sense
        // when there is more than one front of the shard.
        if (cfg.fronts > 1) {
            const on: c_int = 1;
            const res = std.os.linux.setsockopt(
                fd,
                std.os.linux.SOL.SOCKET,
                std.os.linux.SO.REUSEPORT,
                @ptrCast(&on),
                @sizeOf(c_int),
            );
            if (std.os.linux.errno(res) != .SUCCESS) {
                return posix.unexpectedErrno(std.os.linux.errno(res));
            }
        }

        try bindAndListen(fd, ip, cfg.accept_backlog);
        return fd;
    }

    /// Binds `fd` to the IPv4 endpoint `ip` and puts it in the listening
    /// state. Shared by the client listener of the process thread and the
    /// replication listener of every front (2.3).
    fn bindAndListen(fd: posix.fd_t, ip: std.Io.net.Ip4Address, backlog: u32) !void {
        const addr = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, ip.port),
            .addr = @bitCast(ip.bytes),
        };

        const bind_res = std.os.linux.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));
        if (std.os.linux.errno(bind_res) != .SUCCESS) {
            return posix.unexpectedErrno(std.os.linux.errno(bind_res));
        }

        const listen_res = std.os.linux.listen(fd, backlog);
        if (std.os.linux.errno(listen_res) != .SUCCESS) {
            return posix.unexpectedErrno(std.os.linux.errno(listen_res));
        }
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

/// The cap of the socket bookkeeping arrays (2.3). The process pins its
/// descriptor limit to this value before any worker spawns, so every open
/// client socket has a descriptor value that is a valid array index.
pub const socket_limit: usize = 128 * 1024;

/// Floor of the allocated socket table: a process whose descriptor limit
/// cannot be raised still gets a table for the sockets it can open.
const socket_limit_floor: usize = 1024;

/// Raises the descriptor limit to `socket_limit` and returns the limit the
/// process actually holds, clamped to the cap. Only the soft limit can be
/// raised without privileges; a refusal of the hard one is noted and the soft
/// limit is raised as far as it goes. Every refusal is non-fatal: the caller
/// sizes its arrays by the returned value, so the arrays always cover every
/// descriptor the kernel can hand out.
fn pinSocketLimit() usize {
    const want: posix.rlim_t = @intCast(socket_limit);

    const current = posix.getrlimit(.NOFILE) catch return socket_limit_floor;
    if (current.cur < want) {
        const raised = posix.setrlimit(.NOFILE, .{ .cur = want, .max = @max(current.max, want) });
        if (raised) |_| {} else |_| {
            _ = posix.setrlimit(.NOFILE, .{
                .cur = @min(want, current.max),
                .max = current.max,
            }) catch {};
        }
    }

    const actual = posix.getrlimit(.NOFILE) catch return socket_limit_floor;
    return @max(socket_limit_floor, @min(socket_limit, @as(usize, @intCast(actual.cur))));
}

/// The hard cap on how many index threads one front can own: also the width of
/// the columnar counter row of the socket bookkeeping (2.3).
pub const max_indexes_per_front: usize = 64;

/// The bookkeeping of one client socket (2.3): the tag it was accepted with,
/// the front counter and the second of the last traffic seen on it.
///
/// The index counters live apart, in the columnar allocation of `SocketTable`,
/// so the drain sums single words instead of comparing snapshots. Every field
/// has exactly one writer, so no lock and no atomic is needed.
pub const SocketInfo = struct {
    /// The accept tag, zero when the descriptor carries no socket.
    tag: usize = 0,
    /// Bumped by the owning front alone, `+1` for every op it pushes into an
    /// `IndexInbox`. Monotone: never decremented, never zeroed mid-life.
    front_counter: u32 = 0,
    /// The absolute monotonic second (`zigring.nowNs()`, CLOCK_REALTIME) of
    /// the last client traffic the front saw on this descriptor.
    last_tick: u32 = 0,
    /// Set by the owning front when the socket is marked for the deferred
    /// close (2.3): no op of it is routed any more, and the ticker closes the
    /// descriptor once every counter has drained.
    closing: bool = false,
    /// Set by the owning front while its own angry write is in flight on the
    /// descriptor, so the deferred close waits for the reply to land (2.3).
    reply_pending: bool = false,
};

/// Client socket bookkeeping shared by every front and every index, indexed by
/// the descriptor value itself: no `HashMap` on the hot path (2.3). The layout
/// is columnar: the tag, the front counter and the last tick stand in one
/// array, the per-index in-flight counters are one plain allocation of
/// `limit * max_indexes_per_front` `u32`s, one row per (fd, index service).
/// No locks and no atomics: every field has exactly one writer, and every
/// field is a single aligned word, so a concurrent read sees either the old or
/// the new value, never a torn one.
pub const SocketTable = struct {
    const Self = @This();

    /// The allocated entry count. The kernel hands out no descriptor at or
    /// above it, so every live socket has an entry.
    limit: usize,

    /// The tag, front counter and last tick of each open client socket.
    /// Written by the owning front alone, read by the owner and by the index
    /// the socket reports to.
    entries: []SocketInfo,

    /// One row of `max_indexes_per_front` counters per descriptor, each
    /// bumped by the owning index alone, `+1` per op it retires.
    index_counters: []u32,

    pub fn init(allocator: std.mem.Allocator, limit: usize) !Self {
        std.debug.assert(limit > 0);
        const entries = try allocator.alloc(SocketInfo, limit);
        @memset(entries, .{});
        errdefer allocator.free(entries);

        const index_counters = try allocator.alloc(u32, limit * max_indexes_per_front);
        @memset(index_counters, 0);
        return .{ .limit = limit, .entries = entries, .index_counters = index_counters };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        allocator.free(self.index_counters);
        self.* = undefined;
    }

    /// The tag the `serial`-th accept of `front_idx` takes: `n * Fno +
    /// (front_idx + 1)`, the zero invalid. The owner sits in the low bits of
    /// `tag - 1` and the accept generation in the high ones.
    pub fn mintTag(front_idx: u16, serial: usize, fronts: u16) usize {
        return serial * @as(usize, fronts) + (@as(usize, front_idx) + 1);
    }

    /// The front a tag was minted by. `fronts` is a power of two, so only a
    /// mask is needed: never `%`, never `/` (2.3).
    pub fn ownerOf(tag: usize, fronts: u16) usize {
        return (tag - 1) & (@as(usize, fronts) - 1);
    }

    /// The accept generation of a tag, the inverse of `mintTag` together with
    /// `ownerOf`.
    pub fn serialOf(tag: usize, fronts: u16) usize {
        return (tag - 1) >> @intCast(@ctz(@as(usize, fronts)));
    }

    /// The row of index counters belonging to a descriptor.
    pub fn counterRow(self: *Self, fd: posix.fd_t) ?[]u32 {
        const idx = indexOf(fd) orelse return null;
        if (idx >= self.limit) return null;
        return self.index_counters[idx * max_indexes_per_front ..][0..max_indexes_per_front];
    }

    /// Stores the tag of a freshly accepted socket. A descriptor outside the
    /// table cannot exist; the check only keeps the arrays sound if the limit
    /// shrank under a pinned process.
    pub fn set(self: *Self, fd: posix.fd_t, tag: usize) void {
        const entry = self.info(fd) orelse return;
        entry.tag = tag;
    }

    /// The tag of an open socket, zero when the descriptor carries none.
    pub fn get(self: *const Self, fd: posix.fd_t) usize {
        const idx = indexOf(fd) orelse return 0;
        if (idx >= self.limit) return 0;
        return self.entries[idx].tag;
    }

    /// The whole bookkeeping record of a descriptor, `null` outside the table.
    pub fn info(self: *Self, fd: posix.fd_t) ?*SocketInfo {
        const idx = indexOf(fd) orelse return null;
        if (idx >= self.limit) return null;
        return &self.entries[idx];
    }

    /// Bumps the front counter of a socket: one op pushed into an
    /// `IndexInbox`. Called by the owning front alone at push time, which
    /// closes the dequeue race by construction (2.3).
    pub fn bumpFront(self: *Self, fd: posix.fd_t) void {
        const entry = self.info(fd) orelse return;
        entry.front_counter +%= 1;
    }

    /// Bumps the counter of one index service of a socket: one op retired by
    /// that index (a reply written, a complaint pushed, the unknown-session
    /// handling done). Called by that index alone.
    pub fn bumpIndex(self: *Self, fd: posix.fd_t, slot: usize) void {
        std.debug.assert(slot < max_indexes_per_front);
        const row = self.counterRow(fd) orelse return;
        row[slot] +%= 1;
    }

    /// Records the absolute second of the last traffic seen on a socket. A
    /// plain store: the value only grows, and the wheel compares it against a
    /// deadline.
    pub fn bumpTick(self: *Self, fd: posix.fd_t, second: u32) void {
        const entry = self.info(fd) orelse return;
        entry.last_tick = second;
    }

    /// The second of the last traffic seen on a socket, zero when unknown.
    pub fn lastTick(self: *const Self, fd: posix.fd_t) u32 {
        const idx = indexOf(fd) orelse return 0;
        if (idx >= self.limit) return 0;
        return self.entries[idx].last_tick;
    }

    /// Whether everything pushed for this socket has been retired: the sum of
    /// its index counters equals its front counter, modulo `2^32`. The
    /// counters only ever grow, so a straggler keeps the sum short and the
    /// comparison wraps cleanly.
    pub fn drained(self: *const Self, fd: posix.fd_t) bool {
        const idx = indexOf(fd) orelse return true;
        if (idx >= self.limit) return true;

        var retired: u32 = 0;
        const row = self.index_counters[idx * max_indexes_per_front ..][0..max_indexes_per_front];
        for (row) |counter| retired +%= counter;
        return retired == self.entries[idx].front_counter;
    }

    /// Zeroes the whole entry of a socket: the tag and both counters. Called
    /// by the front once the deferred close has drained, never mid-life.
    pub fn clear(self: *Self, fd: posix.fd_t) void {
        const entry = self.info(fd) orelse return;
        entry.* = .{};
        const row = self.counterRow(fd) orelse return;
        @memset(row, 0);
    }

    /// How many entries are taken. A scan, for diagnostics and tests only.
    pub fn count(self: *const Self) usize {
        var taken: usize = 0;
        for (self.entries) |entry| {
            if (entry.tag != 0) taken += 1;
        }
        return taken;
    }

    fn indexOf(fd: posix.fd_t) ?usize {
        if (fd < 0) return null;
        return @intCast(fd);
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
        /// The row of this index in the columnar socket counters (2.3): its
        /// position among the children of its front, never its global index.
        counter_slot: usize,
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

    /// The ring is driven exclusively through its direct `push*` methods.
    /// A `StreamSQ` must not be attached to it: the stream keeps separate
    /// producer cursors, so mixing the two submission paths overwrites SQEs
    /// and can move `sq_tail` backwards.
    ring: zigring.Ring,
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

    /// Releases the record buffer and slot of a completed file write. Returns
    /// false when `task_idx` is not a logging operation.
    pub fn completeLogging(self: *Self, task_idx: u64) bool {
        return self.sink.complete(&self.pool, task_idx);
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        // Write completions still own their record buffers until the kernel is
        // done with them. If they do not arrive in time, leak the pool, the
        // slots and the log descriptor rather than freeing memory under an
        // active read.
        const drained = self.sink.drain(&self.pool);
        self.logger.deinit();
        if (!drained) return;
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
                .counter_slot = 0,
            },
        },
        .{
            .index = .{
                .ring_idx = 3,
                .inbox_idx = 1,
                .front_idx = 0,
                .counter_slot = 1,
            },
        },
        .{
            .index = .{
                .ring_idx = 4,
                .inbox_idx = 2,
                .front_idx = 1,
                .counter_slot = 0,
            },
        },
        .{
            .index = .{
                .ring_idx = 5,
                .inbox_idx = 3,
                .front_idx = 1,
                .counter_slot = 1,
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

test "socket tags identify their owner and generation" {
    const fronts: u16 = 4;

    for (0..fronts) |front_idx| {
        for (0..3) |serial| {
            const tag = SocketTable.mintTag(@intCast(front_idx), serial, fronts);
            try std.testing.expect(tag != 0);
            try std.testing.expectEqual(front_idx, SocketTable.ownerOf(tag, fronts));
            try std.testing.expectEqual(serial, SocketTable.serialOf(tag, fronts));
        }
    }
}

test "the socket drain sums the index counters against the front counter" {
    var table = try SocketTable.init(std.testing.allocator, 64);
    defer table.deinit(std.testing.allocator);

    table.set(5, 7);
    // Nothing pushed, nothing retired: drained from the start.
    try std.testing.expect(table.drained(5));

    // Two ops pushed, one retired: the sum stays short.
    table.bumpFront(5);
    table.bumpFront(5);
    try std.testing.expect(!table.drained(5));
    table.bumpIndex(5, 0);
    try std.testing.expect(!table.drained(5));
    table.bumpIndex(5, 2);
    try std.testing.expect(table.drained(5));

    // The counters are monotone and the comparison is modulo 2^32: a wrap of
    // one side means nothing as long as both sides wrap together.
    const entry = table.info(5).?;
    entry.front_counter = std.math.maxInt(u32);
    const row = table.counterRow(5).?;
    row[0] = std.math.maxInt(u32);
    row[2] = std.math.maxInt(u32);
    table.bumpFront(5);
    table.bumpIndex(5, 0);
    table.bumpIndex(5, 2);
    try std.testing.expectEqual(@as(u32, 0), entry.front_counter);
    try std.testing.expect(table.drained(5));

    // A retried close zeroes the tag and every counter.
    table.clear(5);
    try std.testing.expectEqual(@as(usize, 0), table.get(5));
    try std.testing.expectEqual(@as(u32, 0), table.info(5).?.front_counter);
    for (table.counterRow(5).?) |counter| {
        try std.testing.expectEqual(@as(u32, 0), counter);
    }
}

test "the socket table keeps the last tick of a descriptor" {
    var table = try SocketTable.init(std.testing.allocator, 64);
    defer table.deinit(std.testing.allocator);

    table.set(9, 3);
    try std.testing.expectEqual(@as(u32, 0), table.lastTick(9));
    table.bumpTick(9, 1_700_000_000);
    try std.testing.expectEqual(@as(u32, 1_700_000_000), table.lastTick(9));

    // Out-of-range and negative descriptors are ignored, never an access.
    table.bumpTick(-1, 5);
    table.bumpTick(64, 5);
    table.bumpFront(64);
    table.bumpIndex(-1, 0);
    try std.testing.expect(table.drained(64));
    try std.testing.expect(table.drained(-1));
}

test "the socket table stores the tag of a live descriptor" {
    var table = try SocketTable.init(std.testing.allocator, 64);
    defer table.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), table.get(3));
    table.set(3, 9);
    try std.testing.expectEqual(@as(usize, 9), table.get(3));
    try std.testing.expectEqual(@as(usize, 1), table.count());

    // A descriptor outside the table is ignored rather than stored.
    table.set(64, 11);
    try std.testing.expectEqual(@as(usize, 0), table.get(64));
    try std.testing.expectEqual(@as(usize, 1), table.count());

    table.clear(3);
    try std.testing.expectEqual(@as(usize, 0), table.get(3));
    try std.testing.expectEqual(@as(usize, 0), table.count());
}
