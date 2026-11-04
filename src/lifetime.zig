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
const state = @import("state.zig");
const replay_queue = @import("replay_queue.zig");

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

        self.* = .{
            .allocator = allocator,
            .cfg = cfg,
            .rolling_role_idx = 0,
            .rings = rings,
            .inboxes = inboxes,
            .ring_factory = undefined,
            .init_ring = undefined,
            .cross_slots = undefined,
            .compensators = state.CompensatorMap.init(allocator),
            .threads = threads,
            .thread_ctx = thread_ctx,
            .spawned = 0,
        };
        errdefer self.compensators.deinit();

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
        self.compensators.deinit();
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
                const written = self.putUvarint(backing, create.payload.len) catch unreachable;
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
                const written = self.putUvarint(session.data.data.backing[at..], append.payload.len) catch unreachable;
                @memcpy(session.data.data.backing[at + written ..][0..append.payload.len], append.payload);
                session.data.data.len = new_len;
            },
            .overwrite => |overwrite| {
                const session = st.sessions.get(overwrite.session_id) orelse
                    return error.UnknownSession;

                const chunk_len = uvarintLen(overwrite.payload.len) + overwrite.payload.len;
                const backing = try self.allocator.alloc(u8, chunk_len);
                errdefer self.allocator.free(backing);
                const written = self.putUvarint(backing, overwrite.payload.len) catch unreachable;
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

        const sd_len_res = try self.readUvarint(blob[replay_queue.BLOB_HEAD..]);
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
        const count_len = try self.putUvarint(&count_buf, st.sessions.count());
        try out.appendSlice(output_allocator, count_buf[0..count_len]);

        var it = st.sessions.iterator();
        while (it.next()) |bucket| {
            const sd_bytes = try self.encodeSessionData(&bucket.val.data);
            defer self.allocator.free(sd_bytes);

            var id_buf: [16]u8 = undefined;
            std.mem.writeInt(u128, &id_buf, bucket.key, .little);
            try out.appendSlice(output_allocator, &id_buf);

            var len_buf: [10]u8 = undefined;
            const len_len = try self.putUvarint(&len_buf, sd_bytes.len);
            try out.appendSlice(output_allocator, len_buf[0..len_len]);
            try out.appendSlice(output_allocator, sd_bytes);
        }

        const queue_allocator = st.replay_queue.allocator;
        const handles = try @constCast(&st.replay_queue).snapshotHandles();
        defer queue_allocator.free(handles);
        std.mem.sort([]u8, handles, {}, blobLessThan);

        var queue_count_buf: [10]u8 = undefined;
        const queue_count_len = try self.putUvarint(&queue_count_buf, handles.len);
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

        const count_res = try self.readUvarint(bytes[pos..]);
        pos += count_res.len;
        const count = std.math.cast(usize, count_res.value) orelse return error.CorruptInput;

        var i: usize = 0;
        while (i < count) : (i += 1) {
            if (bytes.len - pos < 16) return error.CorruptInput;
            const id = std.mem.readInt(u128, bytes[pos..][0..16], .little);
            pos += 16;

            const len_res = try self.readUvarint(bytes[pos..]);
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

        const queue_count_res = try self.readUvarint(bytes[pos..]);
        pos += queue_count_res.len;
        const queue_count = std.math.cast(usize, queue_count_res.value) orelse return error.CorruptInput;

        var previous: ?[]const u8 = null;
        var q: usize = 0;
        while (q < queue_count) : (q += 1) {
            if (bytes.len - pos < replay_queue.BLOB_HEAD + 1) return error.CorruptInput;

            const sd_len_res = try self.readUvarint(bytes[pos + replay_queue.BLOB_HEAD ..]);
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

    pub fn validateCompensator(self: *const Self, name: []const u8) bool {
        return self.compensators.contains(name);
    }

    /// Writes a base-128 varint into `buf` and returns its length.
    pub fn putUvarint(self: *const Self, buf: []u8, v: u64) !usize {
        _ = self;
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
    pub fn readUvarint(self: *const Self, buf: []const u8) !struct { value: u64, len: usize } {
        _ = self;
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

        pos += self.putUvarint(buf[pos..], sd.compensator.len) catch unreachable;
        @memcpy(buf[pos..][0..sd.compensator.len], sd.compensator);
        pos += sd.compensator.len;

        std.mem.writeInt(u32, buf[pos..][0..4], sd.retry_count, .little);
        pos += 4;

        pos += self.putUvarint(buf[pos..], sd.data.len) catch unreachable;
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

        const comp_res = try self.readUvarint(bytes[pos..]);
        pos += comp_res.len;
        const comp_len = std.math.cast(usize, comp_res.value) orelse return error.CorruptInput;
        if (bytes.len - pos < comp_len) return error.CorruptInput;
        const compensator = try self.allocator.dupe(u8, bytes[pos..][0..comp_len]);
        errdefer self.allocator.free(compensator);
        pos += comp_len;

        if (bytes.len - pos < 4) return error.CorruptInput;
        const retry_count = std.mem.readInt(u32, bytes[pos..][0..4], .little);
        pos += 4;

        const data_res = try self.readUvarint(bytes[pos..]);
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

        const written = self.putUvarint(blob[replay_queue.BLOB_HEAD..], sd_bytes.len) catch unreachable;
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

    fn uvarintLen(v: u64) usize {
        var value = v;
        var len: usize = 1;
        while (value >= 0x80) : (value >>= 7) len += 1;
        return len;
    }
};

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
    var ctx: TestController = .{};
    try ctx.init();
    defer ctx.deinit();

    const values = [_]u64{ 0, 1, 127, 128, 255, 1 << 14, std.math.maxInt(u64) };
    for (values) |value| {
        var buf: [10]u8 = undefined;
        const written = try ctx.ctrl.putUvarint(&buf, value);
        const read = try ctx.ctrl.readUvarint(buf[0..written]);
        try std.testing.expectEqual(value, read.value);
        try std.testing.expectEqual(written, read.len);
    }

    var empty: [0]u8 = .{};
    try std.testing.expectError(error.BufferTooSmall, ctx.ctrl.putUvarint(&empty, 1));
    try std.testing.expectError(error.CorruptInput, ctx.ctrl.readUvarint(&.{}));
    const overlong: [11]u8 = @splat(0x80);
    try std.testing.expectError(error.CorruptInput, ctx.ctrl.readUvarint(&overlong));
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
