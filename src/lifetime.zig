const std = @import("std");
const config = @import("config.zig");
const zigring = @import("zigring");
const idxinbox = @import("index_inbox.zig");
const indexmod = @import("index.zig");
const cross_slots = @import("cross_task_slots.zig");
const logging = @import("logging.zig");
const blog = @import("blog");
const slots = @import("slots.zig");

/// Lifetime controller.
pub const Controller = struct {
    const Self = @This();
    const IndexInbox = idxinbox.IndexInbox(indexmod.FrontMessage);

    allocator: std.mem.Allocator,

    /// Application config.
    cfg: *const config.Config,

    /// "Hidden" atomic counter for roles distribution.
    rolling_role_idx: u32 align(std.atomic.cache_line),
    rings: []RingStuff,
    inboxes: []IndexInbox,

    /// Ring of the main lifetime controller thread.
    ring_factory: zigring.Factory,
    init_ring: RingStuff,

    /// Storage for cross-thread interaction.
    cross_slots: cross_slots.CrossTaskSlots,

    /// Logging stuff.
    /// Constructor gets cfg as a borrowed value.
    /// Allocates containers for data.
    pub fn init(self: *Self, allocator: std.mem.Allocator, cfg: *const config.Config) !void {
        const subjects: usize = @intCast(cfg.fronts + cfg.indexes + cfg.elephants);

        const rings = try allocator.alloc(RingStuff, subjects);
        errdefer allocator.free(rings);

        const inboxes = try allocator.alloc(IndexInbox, cfg.indexes);
        errdefer allocator.free(inboxes);

        self.* = .{
            .allocator = allocator,
            .cfg = cfg,
            .rolling_role_idx = 0,
            .rings = rings,
            .inboxes = inboxes,
            .ring_factory = undefined,
            .init_ring = undefined,
            .cross_slots = undefined,
        };

        try self.ring_factory.init(allocator, cfg.sqpoll_threads);
        errdefer self.ring_factory.deinit();
        try self.initGivenRing(&self.init_ring, 0);
        errdefer self.init_ring.deinit();

        try self.cross_slots.init(allocator, cfg.cross_task_slots);
        errdefer self.cross_slots.deinit();
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.rings);
        self.allocator.free(self.inboxes);
        self.cross_slots.deinit();
        self.init_ring.deinit();
        self.ring_factory.deinit();
    }

    /// Returns a logger and its buffer pool for the given thread. The logging stuff
    /// is owned by the caller and needs both deinit and destroy.
    pub fn getLogger(self: *Self, thread_idx: u32) !*LoggerStuff {
        return self.getLoggerWithRing(&self.rings[thread_idx]);
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

    /// Returned when get_role is not used properly.
    pub const RoleDistributionError = error{
        /// When we did too much get_role exceeding an amount of planned subjects (fronts, indexes, elephants).
        Overflow,
    };

    /// Returns computed role. This distribution does as follows:
    ///
    /// ```
    /// when idx {
    ///   [0..fronts) => .front
    ///   [fronts, fronts + indexes) => .index
    ///   [fronts + indexes, fronts + indexes + elephants) => .elephant
    /// }
    /// ```
    ///
    /// With proper parameters described in the definition of Role union.
    pub fn getRole(self: *Self) RoleDistributionError!Role {
        const role_idx = @atomicRmw(u32, &self.rolling_role_idx, .Add, 1, .monotonic);
        // role_idx never overflows 0xFFFF as was checked by the config validation.
        const idx: u16 = @truncate(role_idx);

        const index_per_front = self.cfg.indexes / self.cfg.fronts;
        if (idx < self.cfg.fronts) {
            return .{
                .front = .{
                    .ring_idx = idx,
                    .first_index = .{
                        .ring = idx * index_per_front + self.cfg.fronts,
                        .inbox = idx * index_per_front,
                    },
                    .index_count = index_per_front,
                },
            };
        }

        var domain_idx = idx - self.cfg.fronts;
        if (domain_idx < self.cfg.indexes) {
            return .{
                .index = .{
                    .idx = .{
                        .ring = idx,
                        .inbox = domain_idx,
                    },
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

        return RoleDistributionError.Overflow;
    }

    // Initializes a ring and its related stuff for a thread with the given idx.
    pub fn initRing(self: *Self, thread_idx: u32, weight: u32) !void {
        return self.initGivenRing(&self.rings[thread_idx], weight);
    }

    fn initGivenRing(self: *Self, stuff: *RingStuff, weight: u32) !void {
        try self.ring_factory.acquireRing(&stuff.ring, self.cfg.queue_depth, weight);
        errdefer stuff.ring.deinit();
        stuff.ring.streamedSQ(&stuff.sqstream);
        try stuff.slots.init(self.allocator, 4096); // TODO need to set up via config.
    }

    // Initializes an input inbox for the given index thread with the given idx.
    pub fn initIndexInbox(self: *Self, index_idx: u32, index_ring_idx: u32, front_ring_idx: u32) !void {
        try self.inboxes[index_idx].init(
            self.allocator,
            self.cfg.index_inbox_capacity,
            &self.rings[index_ring_idx].ring,
            &self.rings[front_ring_idx].ring,
        );
    }
};

/// Thread role description.
pub const Role = union(enum) {
    /// Index indexes, where `ring` references an index of a ring for index thread. And inbox - its inbox index.
    /// Rings for indexes goes right after rings for fronts. And inboxes are for index threads only,
    pub const IndexIdx = struct {
        ring: u16,
        inbox: u16,
    };

    front: struct {
        ring_idx: u16,
        first_index: Role.IndexIdx,
        index_count: u16,
    },
    index: struct {
        idx: Role.IndexIdx,
        front_idx: u16,
    },
    elephant: struct {
        ring_idx: u16,
    },
};

/// Ring itself and the related stuff.
pub const RingStuff = struct {
    const Self = @This();

    ring: zigring.Ring,
    sqstream: zigring.StreamSQ,
    slots: slots.RingSlots,

    pub fn deinit(self: *Self) void {
        self.slots.deinit();
        self.ring.deinit();
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

    var ctrl: Controller = undefined;
    try ctrl.init(std.testing.allocator, &cfg);
    defer ctrl.deinit();

    const expected = [_]Role{
        .{
            .front = .{
                .ring_idx = 0,
                .first_index = Role.IndexIdx{
                    .ring = 2,
                    .inbox = 0,
                },
                .index_count = 2,
            },
        },
        .{
            .front = .{
                .ring_idx = 1,
                .first_index = Role.IndexIdx{
                    .ring = 4,
                    .inbox = 2,
                },
                .index_count = 2,
            },
        },
        .{
            .index = .{
                .idx = .{
                    .ring = 2,
                    .inbox = 0,
                },
                .front_idx = 0,
            },
        },
        .{
            .index = .{
                .idx = .{
                    .ring = 3,
                    .inbox = 1,
                },
                .front_idx = 0,
            },
        },
        .{
            .index = .{
                .idx = .{
                    .ring = 4,
                    .inbox = 2,
                },
                .front_idx = 1,
            },
        },
        .{
            .index = .{
                .idx = .{
                    .ring = 5,
                    .inbox = 3,
                },
                .front_idx = 1,
            },
        },
        .{
            .elephant = .{
                .ring_idx = 6,
            },
        },
    };

    for (expected) |want| {
        const role = try ctrl.getRole();
        try std.testing.expectEqual(want, role);
    }

    try std.testing.expectError(error.Overflow, ctrl.getRole());
}
