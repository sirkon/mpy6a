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

/// Schema-guided parser for `Config`, built once at comptime.
const ConfigParser = siggy.parser(Config);

/// Everything that can go wrong while parsing or validating a configuration.
/// The two `*CoresMask` variants report semantic problems with CPU pinning that
/// only validation can see (bounds, duplicates, count and cross-set overlap).
/// Malformed documents and masks surface as `ParseSiggy`, with the offending
/// token rendered by the siggy diagnostics.
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
