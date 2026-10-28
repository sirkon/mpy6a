//! Server configuration.
//!
//! The document is siggy text: a relaxed ZON-like format whose parser maps
//! documents onto Zig types directly. `Manager.fromText` deserializes it
//! straight into `Config`; there is no intermediate representation.
//!
//! Keys are plain names, strings are quoted, lists are blocks separated by
//! spaces or commas, and tagged unions are written as `tag { payload }`:
//!
//! ```text
//! bind = "localhost"
//! port = 7000
//! logging = pretty { dark }
//! front_cores = { 0 1 4..9 }
//! ```
//!
//! `front_cores` and `index_cores` are `CoresMask` values: a block of cores and
//! inclusive ranges (`{ 0 1 4..9 }`), expanded into the flat, sorted, deduped
//! `[]const u16` exposed through `CoresMask.cores`.
//!
//! Memory: `Config` is plain data and owns nothing it allocates. The manager
//! holds one arena that backs `bind`, the mask core lists and a `.file`
//! logging path for every document it parsed. `Manager.deinit` releases all of
//! them at once, so every `Config` handed out by the manager must not be used
//! afterwards.

const std = @import("std");
const siggy = @import("siggy");

/// Server config structure.
///
/// The owned strings and slices are backed by the manager's arena, so this
/// value must not outlive the manager that produced it.
pub const Config = struct {
    /// Server expo params.
    bind: []const u8 = "localhost",
    port: u16 = 60006,

    /// How many front threads and how they are bound into CPU cores.
    fronts: u16 = 2,
    front_cores: CoresMask = .{ .cores = &.{ 2, 3 } },

    /// How many index threads and core distribution as well.
    indexes: u16 = 4,
    index_cores: CoresMask = .{ .cores = &.{ 4, 5, 6, 7 } },

    /// How many "elephant" threads for heavy synchronous processing. With
    /// optional CPU affinity cause these things are meant to be interacted
    /// rarely, the cost of cache misses is miniscule compared to their
    /// workload.
    elephants: u16 = 1,

    /// Server internal params.
    host_index: u16 = 0,
    /// The shard this host belongs to (2.7).
    replication: Replication = .{},
    /// The acknowledgement deadline of one consensus round (2.5, 2.7). It feeds
    /// the `TCP_USER_TIMEOUT` clamp of the mirror sockets.
    consensus_timeout: SiggyDuration = .{ .value = .{ .nanos = 3 * std.time.ns_per_s } },
    /// How long a session parked as violated waits for its replay before the
    /// entry is handed over (2.5, 2.7).
    protocol_violation_replay: SiggyDuration = .{ .value = .{ .nanos = 15 * std.time.ns_per_s } },
    /// Whether an op naming an unknown session is fatal for its connection
    /// (2.5, 2.7): the fatal pole rides the complaint path, the other pole is
    /// the index's own direct angry write.
    unknown_session_is_fatal: SiggyBool = .{ .value = true },
    /// The interval of the per-front tickers (2.3, 2.7).
    tick_interval: SiggyDuration = .{ .value = .{ .nanos = 50 * std.time.ns_per_ms } },
    /// The maximum inactivity interval of a client socket: the deadline of the
    /// index session wheels and of the front's socket sweep (2.3, 2.7).
    session_inactivity_timeout: SiggyDuration = .{ .value = .{ .nanos = 30 * std.time.ns_per_s } },
    /// The silence after which a mirror connection is considered lost (stage
    /// 6): what the leadership takeover of its sessions and the isolation of
    /// the host it leads hang off.
    host_silence_timeout: SiggyDuration = .{ .value = .{ .nanos = 10 * std.time.ns_per_s } },
    /// The append-only log the operation flush writes to (stage 6,
    /// `src/wal.zig`): framed, checksummed records, and the restart epoch read
    /// back from them. The replica logs of the shard (stage 7) derive their
    /// paths from this one: `<wal_path>.<index>.<host>`. An empty path keeps no
    /// log at all. Still open, and left to the WAL design of its own:
    /// snapshots and compaction.
    wal_path: []const u8 = "mpy6a.wal",
    logging: Logging = .{
        .method = .{ .pretty = .dark },
        .pool_capacity = 1024,
        .pool_frame_size = 2048,
    },
    queue_depth: u32 = 4096,
    init_timeout_sec: u32 = 8,
    shutdown_timeout_sec: u32 = 8,
    cross_task_slots: u32 = 4096,
    accept_backlog: u32 = 1024,
    sqpoll_threads: u32 = 1,

    index_inbox_capacity: u32 = 1024, // TODO: validation, must be a pow of 2.
    ring_slots_capacity: u32 = 4096, // TODO: validation, must a pow of 2.
};

/// One network endpoint of the consensus replication plane (2.7).
pub const BindType = struct {
    host: []const u8,
    port: u16,
};

/// The shard of this host (2.7).
///
/// `factor` counts the hosts of the shard and is always a `2n + 1`; `mode`
/// decides between the single-host `local` deployment and the `cluster` one,
/// which names the replication listener and one mirror endpoint per host
/// index. The own entry of `mirrors` is ignored: only the hosts with a greater
/// index are dialled (2.3).
pub const Replication = struct {
    /// The number of hosts in the shard: a `2n + 1`, `1` in `local` mode.
    factor: u8 = 1,
    mode: union(enum) {
        /// Single-host mode. The factor must be `1`.
        local: void,
        /// Combat mode.
        cluster: struct {
            /// Where the other hosts' indexes connect: not a user-facing port.
            bind: BindType,
            /// One entry per host index; the length must match the factor.
            mirrors: []const BindType,
        },
    } = .local,
};

/// Kinds of logging.
///
/// Tagged so the same value round-trips through siggy: `.pretty` selects a
/// colored development sink with a profile, `.json` is payload-free, and
/// `.file` names a file sink and owns its path.
pub const Logging = struct {
    method: union(enum) {
        pretty: enum { light, dark, flat },
        json: void,
        file: []const u8,
    },
    pool_capacity: u32,
    pool_frame_size: u32,
};

/// A CPU pinning mask: a sorted, duplicate-free list of core indices produced
/// from one or more core blocks.
///
/// Accepted document forms:
///
/// - a block of items: `{ 0 1 4..9 }` or `{ 0, 1, 4..9 }`
/// - an empty block `{ }`
///
/// An item is either `<int>` or `<int>..<int>`, where the range is inclusive
/// and its first element must not exceed its last. Anything else is a document
/// error reported at the offending item.
pub const CoresMask = struct {
    /// Expanded core indices, sorted ascending and deduplicated.
    cores: []const u16,

    pub const empty: CoresMask = .{ .cores = &.{} };

    /// Decodes a core block. `cores` is copied into the value arena, so the
    /// result outlives the parse.
    pub fn decode(
        self: *CoresMask,
        source_arena: std.mem.Allocator,
        value_arena: std.mem.Allocator,
        node: siggy.AstNode,
        diag: *siggy.Diagnostic,
    ) !void {
        const items = switch (node) {
            .block => |block| switch (block.*) {
                .empty => {
                    self.cores = &.{};
                    return;
                },
                .list => |items| items,
                .document => return fail(
                    diag,
                    source_arena,
                    "core mask expects a list such as '{{ 0 1 4..9 }}'",
                    .{},
                ),
            },
            else => return fail(
                diag,
                source_arena,
                "core mask expects a list such as '{{ 0 1 4..9 }}'",
                .{},
            ),
        };

        var cores: std.ArrayList(u16) = .empty;
        for (items) |item| {
            const text = switch (item) {
                .literal => |literal| literal,
                else => return fail(
                    diag,
                    source_arena,
                    "core mask items are cores or ranges (start..end)",
                    .{},
                ),
            };
            appendItem(source_arena, &cores, text) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidMask => return fail(
                    diag,
                    source_arena,
                    "invalid core mask item '{s}', expected a core or an inclusive start..end range",
                    .{text},
                ),
            };
        }

        std.mem.sort(u16, cores.items, {}, std.sort.asc(u16));
        var unique: usize = 0;
        for (cores.items) |core| {
            if (unique == 0 or cores.items[unique - 1] != core) {
                cores.items[unique] = core;
                unique += 1;
            }
        }

        self.cores = try value_arena.dupe(u16, cores.items[0..unique]);
    }

    /// Emits the canonical core block, compressing runs of four or more
    /// consecutive cores into a range, e.g. `{ 0 1 2 4..9 }`. The result is
    /// owned by `allocator`.
    pub fn encode(self: CoresMask, allocator: std.mem.Allocator) ![]const u8 {
        const sorted = try allocator.dupe(u16, self.cores);
        defer allocator.free(sorted);
        std.mem.sort(u16, sorted, {}, std.sort.asc(u16));

        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        const w = &out.writer;

        try w.writeAll("{");
        var i: usize = 0;
        while (i < sorted.len) {
            var j = i;
            while (j + 1 < sorted.len and
                @as(u32, sorted[j + 1]) == @as(u32, sorted[j]) + 1)
            {
                j += 1;
            }

            if (j - i < 3) {
                var k = i;
                while (k <= j) : (k += 1) try w.print(" {d}", .{sorted[k]});
            } else {
                try w.print(" {d}..{d}", .{ sorted[i], sorted[j] });
            }
            i = j + 1;
        }
        try w.writeAll(" }");

        return out.toOwnedSlice();
    }

    fn fail(
        diag: *siggy.Diagnostic,
        allocator: std.mem.Allocator,
        comptime fmt: []const u8,
        args: anytype,
    ) siggy.ParsingError {
        diag.code = error.Custom;
        diag.message = std.fmt.allocPrint(allocator, fmt, args) catch "";
        return error.Custom;
    }

    /// Expands one item, a core or an inclusive `start..end` range.
    fn appendItem(
        allocator: std.mem.Allocator,
        cores: *std.ArrayList(u16),
        text: []const u8,
    ) (std.mem.Allocator.Error || error{InvalidMask})!void {
        if (std.mem.indexOf(u8, text, "..")) |dots| {
            const first = try parseCore(text[0..dots]);
            const last = try parseCore(text[dots + 2 ..]);
            if (first > last) return error.InvalidMask;

            var core: u32 = first;
            while (core <= last) : (core += 1) {
                try cores.append(allocator, @intCast(core));
            }
            return;
        }

        try cores.append(allocator, try parseCore(text));
    }

    fn parseCore(text: []const u8) error{InvalidMask}!u16 {
        if (text.len == 0) return error.InvalidMask;
        return std.fmt.parseInt(u16, text, 10) catch error.InvalidMask;
    }
};

/// A span of time, stored as nanoseconds and written in the Go
/// `time.Duration` text format (`30s`, `50ms`, `1m30s`; a bare number reads as
/// seconds).
pub const Duration = struct {
    nanos: i64 = 0,

    pub const zero: Duration = .{};
    pub const nanosecond: Duration = .{ .nanos = 1 };
    pub const microsecond: Duration = .{ .nanos = 1_000 };
    pub const millisecond: Duration = .{ .nanos = 1_000_000 };
    pub const second: Duration = .{ .nanos = 1_000_000_000 };
    pub const minute: Duration = .{ .nanos = 60_000_000_000 };
    pub const hour: Duration = .{ .nanos = 3_600_000_000_000 };

    pub const ParseError = error{ InvalidFormat, Overflow };

    pub fn parse(text: []const u8) Duration.ParseError!Duration {
        if (text.len == 0) return error.InvalidFormat;

        var s = text;
        var negative = false;
        if (s[0] == '-' or s[0] == '+') {
            negative = s[0] == '-';
            s = s[1..];
            if (s.len == 0) return error.InvalidFormat;
        }

        var total: u128 = 0;
        var components: usize = 0;

        while (s.len != 0) {
            if (s[0] != '.' and (s[0] < '0' or s[0] > '9')) {
                return error.InvalidFormat;
            }

            var integer: u128 = 0;
            var saw_integer = false;
            while (s.len != 0 and s[0] >= '0' and s[0] <= '9') {
                saw_integer = true;
                const digit: u128 = s[0] - '0';
                integer = std.math.mul(u128, integer, 10) catch return error.Overflow;
                integer = std.math.add(u128, integer, digit) catch return error.Overflow;
                s = s[1..];
            }

            var fraction: u128 = 0;
            var scale: u128 = 1;
            var saw_fraction = false;
            if (s.len != 0 and s[0] == '.') {
                s = s[1..];
                while (s.len != 0 and s[0] >= '0' and s[0] <= '9') {
                    saw_fraction = true;
                    if (scale <= 1_000_000_000_000_000_000) {
                        const digit: u128 = s[0] - '0';
                        fraction = std.math.mul(u128, fraction, 10) catch return error.Overflow;
                        fraction = std.math.add(u128, fraction, digit) catch return error.Overflow;
                        scale = std.math.mul(u128, scale, 10) catch return error.Overflow;
                    }
                    s = s[1..];
                }
            }

            if (!saw_integer and !saw_fraction) return error.InvalidFormat;

            var unit_end: usize = 0;
            while (unit_end < s.len) : (unit_end += 1) {
                const c = s[unit_end];
                if (c == '.' or (c >= '0' and c <= '9')) break;
            }

            var unit: u128 = undefined;
            if (unit_end == 0) {
                if (components != 0 or s.len != 0) return error.InvalidFormat;
                unit = @intCast(second.nanos);
            } else {
                unit = nanosecondsPerUnit(s[0..unit_end]) orelse return error.InvalidFormat;
            }
            s = s[unit_end..];

            const whole = std.math.mul(u128, integer, unit) catch return error.Overflow;
            const fractional = std.math.mul(u128, fraction, unit) catch return error.Overflow;
            const component = std.math.add(u128, whole, fractional / scale) catch return error.Overflow;
            total = std.math.add(u128, total, component) catch return error.Overflow;
            components += 1;

            if (total > (@as(u128, 1) << 63)) return error.Overflow;
        }

        if (components == 0) return error.InvalidFormat;

        if (negative) {
            if (total == (@as(u128, 1) << 63)) return .{ .nanos = std.math.minInt(i64) };
            return .{ .nanos = -@as(i64, @intCast(total)) };
        }
        if (total > std.math.maxInt(i64)) return error.Overflow;
        return .{ .nanos = @intCast(total) };
    }

    /// How many ticks of `tick` cover this duration, rounding up and never
    /// zero. The startup conversions of the two wheels of 2.3 use it to turn
    /// the `session_inactivity_timeout` knob into an integer tick count over
    /// `tick_interval`.
    pub fn tickCount(self: Duration, tick: Duration) u64 {
        std.debug.assert(tick.nanos > 0);
        const span: u64 = @intCast(@max(self.nanos, 0));
        const step: u64 = @intCast(tick.nanos);
        return @max((span + step - 1) / step, 1);
    }

    pub fn toString(self: Duration, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
        var buf: [64]u8 = undefined;
        return allocator.dupe(u8, self.writeBuf(&buf));
    }

    pub fn writeBuf(self: Duration, buf: []u8) []const u8 {
        std.debug.assert(buf.len >= 32);
        if (self.nanos == 0) {
            @memcpy(buf[0..2], "0s");
            return buf[0..2];
        }

        var w = buf.len;
        var u: u64 = @bitCast(self.nanos);
        const negative = self.nanos < 0;
        if (negative) u = 0 -% u;

        if (u < 1_000_000_000) {
            putBack(buf, &w, 's');
            var precision: u8 = 0;
            if (u < 1_000) {
                putBack(buf, &w, 'n');
            } else if (u < 1_000_000) {
                precision = 3;
                w -= 2;
                buf[w] = 0xc2;
                buf[w + 1] = 0xb5;
            } else {
                precision = 6;
                putBack(buf, &w, 'm');
            }
            u = fmtFrac(buf, &w, u, precision);
            fmtInt(buf, &w, u);
        } else {
            putBack(buf, &w, 's');
            u = fmtFrac(buf, &w, u, 9);
            fmtInt(buf, &w, u % 60);
            u /= 60;
            if (u > 0) {
                putBack(buf, &w, 'm');
                fmtInt(buf, &w, u % 60);
                u /= 60;
                if (u > 0) {
                    putBack(buf, &w, 'h');
                    fmtInt(buf, &w, u);
                }
            }
        }

        if (negative) putBack(buf, &w, '-');
        return buf[w..];
    }

    fn nanosecondsPerUnit(name: []const u8) ?u128 {
        if (std.mem.eql(u8, name, "ns")) return 1;
        if (std.mem.eql(u8, name, "us")) return 1_000;
        if (std.mem.eql(u8, name, "\xc2\xb5s")) return 1_000;
        if (std.mem.eql(u8, name, "\xce\xbcs")) return 1_000;
        if (std.mem.eql(u8, name, "ms")) return 1_000_000;
        if (std.mem.eql(u8, name, "s")) return 1_000_000_000;
        if (std.mem.eql(u8, name, "m")) return 60_000_000_000;
        if (std.mem.eql(u8, name, "h")) return 3_600_000_000_000;
        return null;
    }

    fn putBack(buf: []u8, w: *usize, byte: u8) void {
        w.* -= 1;
        buf[w.*] = byte;
    }

    fn fmtInt(buf: []u8, w: *usize, value: u64) void {
        var v = value;
        if (v == 0) {
            putBack(buf, w, '0');
            return;
        }
        while (v != 0) {
            putBack(buf, w, '0' + @as(u8, @intCast(v % 10)));
            v /= 10;
        }
    }

    fn fmtFrac(buf: []u8, w: *usize, value: u64, precision: u8) u64 {
        var v = value;
        var print = false;
        var i: u8 = 0;
        while (i < precision) : (i += 1) {
            const digit: u8 = @intCast(v % 10);
            print = print or digit != 0;
            if (print) putBack(buf, w, '0' + digit);
            v /= 10;
        }
        if (print) putBack(buf, w, '.');
        return v;
    }
};

/// siggy leaf decoding a boolean literal.
///
/// siggy's own `bool` decoding at the pinned revision accepts only `true` and
/// fails on `false`, which would break the round trip of every flag written as
/// `false`. The value therefore rides a leaf of its own, accepting both
/// literals and nothing else.
pub const SiggyBool = struct {
    value: bool,

    pub fn decode(
        self: *SiggyBool,
        source_arena: std.mem.Allocator,
        value_arena: std.mem.Allocator,
        node: siggy.AstNode,
        diag: *siggy.Diagnostic,
    ) anyerror!void {
        _ = value_arena;
        const text = switch (node) {
            .literal => |literal| literal,
            else => {
                diag.code = error.Custom;
                diag.message = try source_arena.dupe(u8, "flag must be a literal such as false");
                return error.InvalidFormat;
            },
        };
        if (std.mem.eql(u8, text, "true")) {
            self.value = true;
            return;
        }
        if (std.mem.eql(u8, text, "false")) {
            self.value = false;
            return;
        }
        diag.code = error.Custom;
        diag.message = std.fmt.allocPrint(source_arena, "expected true or false, found '{s}'", .{text}) catch "";
        return error.InvalidFormat;
    }

    pub fn encode(self: SiggyBool, allocator: std.mem.Allocator) anyerror![]const u8 {
        return allocator.dupe(u8, if (self.value) "true" else "false");
    }
};

/// siggy leaf decoding a `Duration` from the Go `time.Duration` text format.
pub const SiggyDuration = struct {
    value: Duration,

    pub fn decode(
        self: *SiggyDuration,
        source_arena: std.mem.Allocator,
        value_arena: std.mem.Allocator,
        node: siggy.AstNode,
        diag: *siggy.Diagnostic,
    ) anyerror!void {
        _ = value_arena;
        const text = switch (node) {
            .literal => |literal| literal,
            else => {
                diag.code = error.Custom;
                diag.message = try source_arena.dupe(u8, "duration must be a literal such as 30s");
                return error.InvalidFormat;
            },
        };
        self.value = Duration.parse(text) catch |err| {
            diag.code = error.Custom;
            diag.message = std.fmt.allocPrint(source_arena, "invalid duration '{s}'", .{text}) catch "";
            return err;
        };
    }

    pub fn encode(self: SiggyDuration, allocator: std.mem.Allocator) anyerror![]const u8 {
        return self.value.toString(allocator);
    }
};

/// Schema-guided parser for `Config`, built once at comptime.
const ConfigParser = siggy.parser(Config);

/// Everything that can go wrong while parsing or validating a configuration.
/// The two `*CoresMask` variants report semantic problems with CPU pinning that
/// only validation can see (bounds, duplicates, count and cross-set overlap).
/// The `InvalidReplication*` and `Invalid*Timeout`/`*Interval`/`Replay`
/// variants are the proofs of 2.7: the shard shape and the positivity of the
/// four time knobs. Malformed documents and masks surface as `ParseSiggy`, with
/// the offending token rendered by the siggy diagnostics.
pub const ParseError = error{
    InvalidPort,
    InvalidFronts,
    InvalidIndexes,
    InvalidElephants,
    InvalidCoreCount,
    InvalidQueueDepth,
    InvalidInitTimeout,
    InvalidShutdownTimeout,
    InvalidCrossTaskSlots,
    InvalidAcceptBacklog,
    InvalidFrontCoresMask,
    InvalidIndexCoresMask,
    InvalidReplicationFactor,
    InvalidReplicationMode,
    InvalidReplicationHostIndex,
    InvalidReplicationMirrors,
    InvalidConsensusTimeout,
    InvalidProtocolViolationReplay,
    InvalidTickInterval,
    InvalidSessionInactivityTimeout,
    InvalidHostSilenceTimeout,
    OutOfMemory,
    ParseSiggy,
};

/// CPU count used for the comptime validation of the default document.
pub const check_cpu_cores: u16 = 8;

/// CPU count the tests validate against.
pub const test_cpu_count: u16 = check_cpu_cores;

/// Factory for the config manager type.
///
/// The returned type parses, validates and owns configuration. Building it
/// validates the default `Config` against `check_cpu_cores` at comptime, so a
/// broken default fails the build.
///
/// Validation is one code path used both at comptime (for the default) and at
/// runtime (for a parsed document, with the host's real core count from the
/// manager instance).
///
/// ## Validation rules.
///
/// Scalar rules:
///
/// - `port > 0`
/// - `fronts` is a power of two and less than `cpu_cores`
/// - `indexes` is a power of two, less than `cpu_cores` and at least `fronts`
/// - `elephants > 0` and less than `cpu_cores`
/// - `fronts + indexes + elephants < cpu_cores` (strictly, no equality)
/// - `queue_depth` is a power of two
/// - `init_timeout_sec > 0`
/// - `shutdown_timeout_sec > 0`
/// - `cross_task_slots` is a power of two
/// - `accept_backlog` is a power of two
///
/// Rules for the shard of 2.7:
///
/// - `replication.factor >= 1` and odd: the shard is a `2n + 1`
/// - `local` mode requires `factor = 1`
/// - `host_index < replication.factor`
/// - `cluster` mode lists exactly one mirror per host index
/// - `consensus_timeout`, `protocol_violation_replay`, `tick_interval` and
///   `session_inactivity_timeout` are positive; a zero `tick_interval` would
///   divide by zero in the startup conversions of the two wheels
///
/// Rules for `front_cores` and `index_cores`:
///
/// - every core is less than `cpu_cores`
/// - no core repeats inside one set
/// - the two sets must not intersect
/// - the expanded length of each set matches `fronts` / `indexes` respectively
pub fn Manager() type {
    comptime {
        validate(Config{}, check_cpu_cores) catch |err| {
            @compileError("default Config is invalid: " ++ @errorName(err));
        };
    }

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        io: std.Io,
        cpu_cores: u16,

        /// Receives parse diagnostics. `null` renders them to stderr.
        printer: ?siggy.Printer = null,

        /// Backs every value handed out by `fromText` and `fromFile`. One
        /// arena for the manager's lifetime keeps earlier configs valid.
        arena: std.heap.ArenaAllocator,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, cpu_cores: u16) Self {
            return .{
                .allocator = allocator,
                .io = io,
                .cpu_cores = cpu_cores,
                .arena = .init(allocator),
            };
        }

        /// Releases the arena and with it every `Config` produced so far.
        /// Those values must not be used afterwards.
        pub fn deinit(self: *Self) void {
            self.arena.deinit();
            self.* = undefined;
        }

        /// Parses the given siggy text into a `Config`.
        ///
        /// The returned value borrows from the manager's arena, so `bind`, the
        /// masks and a `.file` logging path stay valid until `deinit`. The
        /// source text itself is only borrowed for the duration of the call.
        pub fn fromText(self: *Self, data: []const u8) ParseError!Config {
            var parser: ConfigParser = undefined;
            try parser.init(self.allocator, self.arena.allocator(), self.printer);

            const config = parser.parse(data) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.ParseSiggy,
            };

            try validate(config, self.cpu_cores);
            return config;
        }

        /// Reads the file at `path` and parses it with `fromText`.
        pub fn fromFile(self: *Self, path: []const u8) (ParseError || std.Io.Dir.ReadFileAllocError)!Config {
            const data = try std.Io.Dir.readFileAlloc(
                std.Io.Dir.cwd(),
                self.io,
                path,
                self.allocator,
                .limited(max_config_bytes),
            );
            defer self.allocator.free(data);
            return self.fromText(data);
        }

        /// Renders the default document as siggy text. The caller owns the
        /// result and frees it with the manager's allocator.
        pub fn default(self: *Self) std.mem.Allocator.Error![]const u8 {
            var scratch = std.heap.ArenaAllocator.init(self.allocator);
            defer scratch.deinit();

            var parser: ConfigParser = undefined;
            try parser.init(self.allocator, scratch.allocator(), self.printer);

            const text = parser.stringify(.{});
            if (parser.diagnostic != null) return error.OutOfMemory;

            return self.allocator.dupe(u8, text);
        }
    };
}

/// Upper bound for a configuration document, in bytes.
const max_config_bytes: usize = 32768;

/// Validates a parsed config against a CPU count. No allocation, so the same
/// function serves the comptime default check and the runtime `fromText`.
fn validate(config: Config, cpu_cores: u16) ParseError!void {
    if (config.port == 0) return error.InvalidPort;

    if (config.fronts == 0 or
        !std.math.isPowerOfTwo(config.fronts) or
        config.fronts >= cpu_cores)
    {
        return error.InvalidFronts;
    }
    if (config.indexes == 0 or
        !std.math.isPowerOfTwo(config.indexes) or
        config.indexes >= cpu_cores or
        config.indexes < config.fronts)
    {
        return error.InvalidIndexes;
    }
    if (config.elephants == 0 or config.elephants >= cpu_cores) {
        return error.InvalidElephants;
    }

    const busy: u32 = @as(u32, config.fronts) + config.indexes + config.elephants;
    if (busy >= cpu_cores) return error.InvalidCoreCount;

    if (config.queue_depth == 0 or !std.math.isPowerOfTwo(config.queue_depth)) {
        return error.InvalidQueueDepth;
    }
    if (config.init_timeout_sec == 0) return error.InvalidInitTimeout;
    if (config.shutdown_timeout_sec == 0) return error.InvalidShutdownTimeout;
    if (config.cross_task_slots == 0 or !std.math.isPowerOfTwo(config.cross_task_slots)) {
        return error.InvalidCrossTaskSlots;
    }
    if (config.accept_backlog == 0 or !std.math.isPowerOfTwo(config.accept_backlog)) {
        return error.InvalidAcceptBacklog;
    }

    try validateReplication(config);
    try validateDurations(config);

    try validateCores(
        config.front_cores.cores,
        config.fronts,
        cpu_cores,
        error.InvalidFrontCoresMask,
    );
    try validateCores(
        config.index_cores.cores,
        config.indexes,
        cpu_cores,
        error.InvalidIndexCoresMask,
    );

    if (setsIntersect(config.front_cores.cores, config.index_cores.cores)) {
        return error.InvalidIndexCoresMask;
    }
}

/// Proves the shard shape of 2.7: an odd factor, a mode that matches it and a
/// host index that names one of the shard's hosts.
fn validateReplication(config: Config) ParseError!void {
    const factor = config.replication.factor;
    if (factor == 0 or factor & 1 == 0) return error.InvalidReplicationFactor;

    switch (config.replication.mode) {
        .local => if (factor != 1) return error.InvalidReplicationMode,
        .cluster => |cluster| {
            if (cluster.mirrors.len != @as(usize, factor)) {
                return error.InvalidReplicationMirrors;
            }
        },
    }

    if (config.host_index >= factor) return error.InvalidReplicationHostIndex;
}

/// Proves the time knobs positive: every wheel conversion at startup
/// divides by `tick_interval` and sizes itself from `session_inactivity_timeout`.
fn validateDurations(config: Config) ParseError!void {
    if (config.consensus_timeout.value.nanos <= 0) return error.InvalidConsensusTimeout;
    if (config.protocol_violation_replay.value.nanos <= 0) {
        return error.InvalidProtocolViolationReplay;
    }
    if (config.tick_interval.value.nanos <= 0) return error.InvalidTickInterval;
    if (config.session_inactivity_timeout.value.nanos <= 0) {
        return error.InvalidSessionInactivityTimeout;
    }
    if (config.host_silence_timeout.value.nanos <= 0) {
        return error.InvalidHostSilenceTimeout;
    }
}

/// Checks a single core set: bounds, uniqueness and expanded length.
fn validateCores(
    cores: []const u16,
    expected: u16,
    cpu_cores: u16,
    err: ParseError,
) ParseError!void {
    if (cores.len != @as(usize, expected)) return err;

    for (cores, 0..) |core, i| {
        if (core >= cpu_cores) return err;
        for (cores[0..i]) |prev| {
            if (prev == core) return err;
        }
    }
}

/// Whether two core sets share at least one core.
fn setsIntersect(a: []const u16, b: []const u16) bool {
    for (a) |ca| {
        for (b) |cb| {
            if (ca == cb) return true;
        }
    }
    return false;
}

const testing = std.testing;
const ManagerType = Manager();

/// Tests expect parse failures; keep their diagnostics out of the output.
fn silentPrinter(allocator: std.mem.Allocator, diag: *siggy.Diagnostics) anyerror!void {
    _ = allocator;
    _ = diag;
}

fn testManager() ManagerType {
    var manager = ManagerType.init(testing.allocator, testing.io, test_cpu_count);
    manager.printer = silentPrinter;
    return manager;
}

test "core masks accept blocks of cores and ranges" {
    var manager = testManager();
    defer manager.deinit();

    const text =
        \\fronts = 2
        \\front_cores = { 0..1 }
        \\indexes = 2
        \\index_cores = { 2, 3 }
    ;
    const config = try manager.fromText(text);

    try testing.expectEqualSlices(u16, &.{ 0, 1 }, config.front_cores.cores);
    try testing.expectEqualSlices(u16, &.{ 2, 3 }, config.index_cores.cores);
}

test "core masks serialize back into a compressed core block" {
    const text = try (CoresMask{ .cores = &.{ 9, 0, 1, 2, 4, 5, 6, 7, 8 } }).encode(testing.allocator);
    defer testing.allocator.free(text);

    try testing.expectEqualStrings("{ 0 1 2 4..9 }", text);
}

test "core masks normalize order and duplicates" {
    var manager = testManager();
    defer manager.deinit();

    const config = try manager.fromText(
        \\fronts = 2
        \\front_cores = { 3 2 2..3 }
    );

    try testing.expectEqualSlices(u16, &.{ 2, 3 }, config.front_cores.cores);
}

test "scalar and core rules are enforced" {
    var manager = testManager();
    defer manager.deinit();

    try testing.expectError(error.InvalidPort, manager.fromText("port = 0"));

    // fronts must be a power of two below the core count.
    try testing.expectError(
        error.InvalidFronts,
        manager.fromText("fronts = 3"),
    );

    // Malformed masks are parse errors, not validation errors.
    try testing.expectError(
        error.ParseSiggy,
        manager.fromText("fronts = 1\nfront_cores = { 5..3 }"),
    );
    try testing.expectError(
        error.ParseSiggy,
        manager.fromText("fronts = 1\nfront_cores = { abc }"),
    );
    try testing.expectError(
        error.ParseSiggy,
        manager.fromText("fronts = 1\nfront_cores = { 70000 }"),
    );

    // Front and index sets must not intersect. The default fronts sit on
    // {2, 3} and the index set below includes 2.
    try testing.expectError(
        error.InvalidIndexCoresMask,
        manager.fromText("indexes = 2\nindex_cores = { 2 5 }"),
    );

    // The expanded length has to match the thread count.
    try testing.expectError(
        error.InvalidFrontCoresMask,
        manager.fromText("fronts = 2\nfront_cores = { 0 }"),
    );

    // Cores must exist on the host.
    try testing.expectError(
        error.InvalidFrontCoresMask,
        manager.fromText("fronts = 2\nfront_cores = { 8..9 }"),
    );
}

test "malformed documents are reported as parse errors" {
    var manager = testManager();
    defer manager.deinit();

    try testing.expectError(error.ParseSiggy, manager.fromText("frobnicate = 1"));
    try testing.expectError(error.ParseSiggy, manager.fromText("port = 1\nport = 2"));
    try testing.expectError(error.ParseSiggy, manager.fromText("port = 1, bind = \"x\""));
    try testing.expectError(error.ParseSiggy, manager.fromText(".port = 1"));
}

test "Duration parses Go duration text" {
    const cases = [_]struct { text: []const u8, nanos: i64 }{
        .{ .text = "0", .nanos = 0 },
        .{ .text = "0s", .nanos = 0 },
        .{ .text = "1ns", .nanos = 1 },
        .{ .text = "1us", .nanos = 1_000 },
        .{ .text = "1\xc2\xb5s", .nanos = 1_000 },
        .{ .text = "1\xce\xbcs", .nanos = 1_000 },
        .{ .text = "300ms", .nanos = 300_000_000 },
        .{ .text = "1.5h", .nanos = 5_400_000_000_000 },
        .{ .text = "-1.5h", .nanos = -5_400_000_000_000 },
        .{ .text = "2h45m", .nanos = 9_900_000_000_000 },
        .{ .text = "1h17m33s", .nanos = 4_653_000_000_000 },
        .{ .text = "1.0000000001s", .nanos = 1_000_000_000 },
        .{ .text = ".5s", .nanos = 500_000_000 },
        .{ .text = "5.s", .nanos = 5_000_000_000 },
        .{ .text = "+5s", .nanos = 5_000_000_000 },
        .{ .text = "30", .nanos = 30_000_000_000 },
        .{ .text = "1.5", .nanos = 1_500_000_000 },
        .{ .text = "1000000h", .nanos = 3_600_000_000_000_000_000 },
        .{ .text = "-9223372036854775808ns", .nanos = std.math.minInt(i64) },
        .{ .text = "-2562047h47m16.854775808s", .nanos = std.math.minInt(i64) },
    };
    for (cases) |case| {
        const parsed = try Duration.parse(case.text);
        try testing.expectEqual(case.nanos, parsed.nanos);
    }
}

test "Duration rejects malformed text" {
    try testing.expectError(error.InvalidFormat, Duration.parse(""));
    try testing.expectError(error.InvalidFormat, Duration.parse("s"));
    try testing.expectError(error.InvalidFormat, Duration.parse("1d"));
    try testing.expectError(error.InvalidFormat, Duration.parse("1h30"));
    try testing.expectError(error.InvalidFormat, Duration.parse("."));
    try testing.expectError(error.Overflow, Duration.parse("9223372036854775808ns"));
    try testing.expectError(error.Overflow, Duration.parse("10000000h"));
}

test "Duration formats like Go time.Duration" {
    const cases = [_]struct { nanos: i64, text: []const u8 }{
        .{ .nanos = 0, .text = "0s" },
        .{ .nanos = 1, .text = "1ns" },
        .{ .nanos = 999, .text = "999ns" },
        .{ .nanos = 1_000, .text = "1\xc2\xb5s" },
        .{ .nanos = 1_500, .text = "1.5\xc2\xb5s" },
        .{ .nanos = 999_999, .text = "999.999\xc2\xb5s" },
        .{ .nanos = 1_000_000, .text = "1ms" },
        .{ .nanos = 1_500_000, .text = "1.5ms" },
        .{ .nanos = 999_999_999, .text = "999.999999ms" },
        .{ .nanos = 1_000_000_000, .text = "1s" },
        .{ .nanos = 1_500_000_000, .text = "1.5s" },
        .{ .nanos = 60_000_000_000, .text = "1m0s" },
        .{ .nanos = 3_600_000_000_000, .text = "1h0m0s" },
        .{ .nanos = 4_653_000_000_000, .text = "1h17m33s" },
        .{ .nanos = 5_400_000_000_000, .text = "1h30m0s" },
        .{ .nanos = -1_500_000_000, .text = "-1.5s" },
        .{ .nanos = -5_400_000_000_000, .text = "-1h30m0s" },
        .{ .nanos = std.math.maxInt(i64), .text = "2562047h47m16.854775807s" },
        .{ .nanos = std.math.minInt(i64), .text = "-2562047h47m16.854775808s" },
    };
    for (cases) |case| {
        const value: Duration = .{ .nanos = case.nanos };
        const text = try value.toString(testing.allocator);
        defer testing.allocator.free(text);
        try testing.expectEqualStrings(case.text, text);
    }
}

test "the shard of 2.7 round-trips through siggy" {
    var manager = testManager();
    defer manager.deinit();

    const cluster =
        \\replication = { factor = 3 mode = cluster { bind = { host = "10.0.0.1" port = 7100 } mirrors = { { host = "10.0.0.1" port = 7100 } { host = "10.0.0.2" port = 7100 } { host = "10.0.0.3" port = 7100 } } } }
        \\host_index = 2
    ;
    const parsed = try manager.fromText(cluster);
    try testing.expectEqual(@as(u8, 3), parsed.replication.factor);
    try testing.expectEqualStrings("10.0.0.2", parsed.replication.mode.cluster.mirrors[1].host);
    try testing.expectEqual(@as(u16, 7100), parsed.replication.mode.cluster.mirrors[2].port);
    try testing.expectEqual(@as(u16, 2), parsed.host_index);

    const local = try manager.fromText("replication = { factor = 1 mode = local }");
    try testing.expectEqual(@as(u8, 1), local.replication.factor);
    try testing.expect(local.replication.mode == .local);
}

test "the shard rules of 2.7 are enforced" {
    var manager = testManager();
    defer manager.deinit();

    // The factor is a 2n + 1.
    try testing.expectError(
        error.InvalidReplicationFactor,
        manager.fromText("replication = { factor = 2 mode = local }"),
    );
    // `local` mode serves a single host.
    try testing.expectError(
        error.InvalidReplicationMode,
        manager.fromText("replication = { factor = 3 mode = local }"),
    );
    // `cluster` mode names one mirror per host index.
    try testing.expectError(
        error.InvalidReplicationMirrors,
        manager.fromText(
            \\replication = { factor = 3 mode = cluster { bind = { host = "h" port = 1 } mirrors = { { host = "h" port = 1 } } } }
        ),
    );
    // The host index names one of the shard's hosts.
    try testing.expectError(
        error.InvalidReplicationHostIndex,
        manager.fromText("host_index = 1"),
    );
}

test "the time knobs of 2.7 must be positive" {
    var manager = testManager();
    defer manager.deinit();

    try testing.expectError(
        error.InvalidConsensusTimeout,
        manager.fromText("consensus_timeout = 0s"),
    );
    try testing.expectError(
        error.InvalidProtocolViolationReplay,
        manager.fromText("protocol_violation_replay = -1s"),
    );
    try testing.expectError(
        error.InvalidTickInterval,
        manager.fromText("tick_interval = 0s"),
    );
    try testing.expectError(
        error.InvalidSessionInactivityTimeout,
        manager.fromText("session_inactivity_timeout = 0"),
    );
    try testing.expectError(
        error.InvalidHostSilenceTimeout,
        manager.fromText("host_silence_timeout = -2s"),
    );

    const parsed = try manager.fromText(
        \\consensus_timeout = 2s
        \\protocol_violation_replay = 20s
        \\tick_interval = 25ms
        \\session_inactivity_timeout = 1m
        \\host_silence_timeout = 12s
        \\unknown_session_is_fatal = false
    );
    try testing.expectEqual(@as(i64, 2_000_000_000), parsed.consensus_timeout.value.nanos);
    try testing.expectEqual(@as(i64, 20_000_000_000), parsed.protocol_violation_replay.value.nanos);
    try testing.expectEqual(@as(i64, 25_000_000), parsed.tick_interval.value.nanos);
    try testing.expectEqual(@as(i64, 60_000_000_000), parsed.session_inactivity_timeout.value.nanos);
    try testing.expectEqual(@as(i64, 12_000_000_000), parsed.host_silence_timeout.value.nanos);
    try testing.expect(!parsed.unknown_session_is_fatal.value);
}

test "Duration counts the ticks that cover it" {
    const tick: Duration = .{ .nanos = 50 * std.time.ns_per_ms };
    try testing.expectEqual(@as(u64, 1), tick.tickCount(tick));
    try testing.expectEqual(@as(u64, 1), Duration.zero.tickCount(tick));
    try testing.expectEqual(@as(u64, 20), Duration.second.tickCount(tick));
    try testing.expectEqual(@as(u64, 2), (Duration{ .nanos = 51 * std.time.ns_per_ms }).tickCount(tick));
    try testing.expectEqual(@as(u64, 1200), Duration.minute.tickCount(tick));
}

test "SiggyDuration implements the siggy custom leaf contract" {
    const Doc = struct {
        timeout: SiggyDuration = .{ .value = .{} },
    };

    var values = std.heap.ArenaAllocator.init(testing.allocator);
    defer values.deinit();

    var parser: siggy.parser(Doc) = undefined;
    try parser.init(testing.allocator, values.allocator(), silentPrinter);

    const parsed = try parser.parse("timeout = 1h17m33s");
    try testing.expectEqual(@as(i64, 4_653_000_000_000), parsed.timeout.value.nanos);
    try testing.expectEqualStrings("timeout = 1h17m33s\n", parser.stringify(parsed));

    try testing.expectError(error.Custom, parser.parse("timeout = 1d"));
    try testing.expectError(error.Custom, parser.parse("timeout = \"1s\""));
}
