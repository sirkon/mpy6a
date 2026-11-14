# Using zunit

`zunit` supplies volume and duration **unit literal** types for two Zig libraries:

- [dap](https://github.com/sirkon/dap), the CLI argument parser, where they let a flag or argument accept `2MiB` or
  `1h30m` from the command line;
- [siggy](https://github.com/sirkon/siggy), the config parser, where they let a config leaf be written as `2MiB` or
  `1h30m`.

Both decoded values are plain integers. A volume is a `u128` byte count; a duration is an `i64` nanosecond count with Go
`time.Duration` parity. Parsing is exact: there is no floating point anywhere.

## Adding the dependency

`zunit` is a library module, not an executable. It has no `main`, no install step, and no deployment target. It requires
Zig `0.17.0` or newer.

Fetch the package into your project:

```sh
zig fetch --save=zunit git+https://github.com/sirkon/zunit.git#<commit-or-tag>
```

That writes an entry into your `build.zig.zon`, similar to:

```zig
.dependencies = .{
    .zunit = .{
        .url = "git+https://github.com/sirkon/zunit.git#<commit-or-tag>",
        .hash = "zunit-0.0.1-...",
    },
},
```

For local development you may use a path dependency instead; the committed `build.zig.zon` of `zunit` itself stays
tarball-pinned:

```zig
.zunit = .{ .path = "../zunit" },
```

Wire the public module into your build. The module is named `zunit` and is rooted at `src/root.zig`:

```zig
const zunit = b.dependency("zunit", .{ .target = target, .optimize = optimize }).module("zunit");

exe.root_module.addImport("zunit", zunit);
// or, when the consumer is itself a module:
// module.addImport("zunit", zunit);
```

Then import it from your code:

```zig
const zunit = @import("zunit");
```

The `zunit` module imports only `std`. It never imports `dap` or `siggy`: the `Dap` wrappers use only `std` types and
the `Siggy` wrappers declare their `node` and `diag` parameters as `anytype`. You still add the SDK you actually use
(`dap`, `siggy`, or both) as a direct dependency of your own project, because your code imports it to declare flags and
configs. The wrapper contracts are verified against dap `v0.0.9` and siggy `v0.0.1`, which are the versions pinned in
`zunit`'s own `build.zig.zon`; use compatible releases so the SDK's custom-value gates keep recognizing the wrappers.

## Public surface

The package root exports exactly two base enums and two comptime factories:

```zig
pub const VolumeBase = enum { b, kib, mib, gib, tib, pib, eib, zib, yib };

pub fn Volume(comptime base: VolumeBase) type;

pub const DurationBase = enum { nanosecs, microsecs, millisecs, secs, mins, hours };

pub fn Duration(comptime base: DurationBase) type;
```

Each factory returns a namespace with exactly two members:

```zig
zunit.Volume(base).Dap
zunit.Volume(base).Siggy
zunit.Duration(base).Dap
zunit.Duration(base).Siggy
```

`Dap` is the CLI wrapper; `Siggy` is the config wrapper. They share the same value surface.

### The base parameter

The base is the unit you want to work in, **and it is also the precision constraint**. A decoded value must be a whole
multiple of the selected base, checked after the full literal is evaluated:

| wrapper                  | accepted                            | rejected                            |
| ------------------------ | ----------------------------------- | ----------------------------------- |
| `Volume(.b)`             | `2097152`, `2MiB`, `1.5MiB`, `0`    | bad syntax, inexact bytes           |
| `Volume(.kib)`           | `2048KiB`, `2MiB`, `1.5MiB`, `0KiB` | `512` bytes, `0.0001MiB`            |
| `Volume(.mib)`           | `2MiB`, `2097152`, `2.0MiB`, `0`    | `512KiB`, `4096`, `1.5MiB`          |
| `Duration(.secs)`        | `90s`, `1h30m`, `-120s`, `0`        | `500ms` (not whole seconds)         |
| `Duration(.millisecs)`   | `1500ms`, `2h45m10s500ms`, `0ms`    | `1.5us` (not whole milliseconds)    |
| `Duration(.mins)`        | `2m`, `120s`, `-120s`, `0`          | `90s`, `-90s` (1.5 minutes)         |

`fromBase` constructs a value from a count of base units, so it is always a multiple by construction. `fromBytes` and
`fromNanos` take absolute raw values and enforce the same multiple check. Choose the smallest/coarsest base that matches
the precision you want to accept.

## Literal grammar

### Volume

A volume literal is an unsigned decimal, optionally with a fractional part, optionally followed by a binary suffix:

```text
volume  = digits [ "." digits ] [ suffix ]
suffix  = ( "K" | "k" | "M" | "m" | "G" | "g" | "T" | "t"
          | "P" | "p" | "E" | "e" | "Z" | "z" | "Y" | "y" ) "i" [ "b" | "B" ]
```

- Bare digits mean bytes: `4096`.
- A fraction is allowed before a suffix: `1.5MiB` is 1,572,864 bytes.
- A bare fraction such as `1.5` is rejected, because a bare number must be a whole byte count.
- Accepted suffix spellings are exactly the five forms per prefix: `KiB`, `Kib`, `Ki`, `kib`, `ki`, and likewise for
  `M`, `G`, `T`, `P`, `E`, `Z`, `Y`. Marketing spellings (`MB`, `M`, `MiB B`) are deliberately rejected.
- No sign is accepted.
- The value must fit in `u128`.

### Duration

A duration literal is one or more components in strictly descending unit order, with at most one leading sign for the
whole literal:

```text
duration  = [ "+" | "-" ] component { component }
component = digits [ "." digits ] unit
unit      = "h" | "m" | "s" | "ms" | "us" | "ns"     (descending rank)
```

- Ranks are `h > m > s > ms > us > ns`; each unit may appear at most once and must come after a higher-rank unit.
- A suffixless component is legal only as the entire literal: `5` and `-5` are nanoseconds, but `1h30` is an error, not
  `1h + 30ns`.
- Every component may carry a fraction as long as the resulting nanoseconds are exact: `1h30.5m` is accepted, `0.5ns` is
  not.
- Signs are allowed only once, at the front. `1h-30m` and `--5s` are errors.
- Accepted units are exactly `h`, `m`, `s`, `ms`, `us`, `ns`. `5mks`, `5M`, `5H`, and `µs`/`μs` are rejected.
- The total must fit in `i64` nanoseconds, from `-9223372036854775808ns` to `9223372036854775807ns`.

## Wrapper API

### Volume wrappers

```zig
pub const Dap = struct {
    pub fn decode(allocator: std.mem.Allocator, data: []const u8) error{ InvalidWire, InvalidValue }!Dap;
    pub fn encode(self: *const Dap, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8;
    pub fn deinit(self: *Dap, allocator: std.mem.Allocator) void;
    pub fn value(self: Dap) u128;
    pub fn value64(self: Dap) error{UnitOverflow}!u64;
    pub fn fromBase(n: u128) error{UnitOverflow}!Dap;
    pub fn fromBytes(raw: u128) error{NotMultipleOfBase}!Dap;
};
```

`Siggy` has the same value surface and the same constructors, minus `deinit`, plus the siggy service methods described
below.

### Duration wrappers

```zig
pub const Dap = struct {
    pub fn decode(allocator: std.mem.Allocator, data: []const u8) error{ InvalidWire, InvalidValue }!Dap;
    pub fn encode(self: *const Dap, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8;
    pub fn deinit(self: *Dap, allocator: std.mem.Allocator) void;
    pub fn value(self: Dap) i64;
    pub fn fromBase(n: i64) error{UnitOverflow}!Dap;
    pub fn fromNanos(raw: i64) error{NotMultipleOfBase}!Dap;
};
```

Duration values are signed nanoseconds, so durations have no `value64`. `Siggy` mirrors the same surface, minus
`deinit`, plus the siggy service methods.

### Shared behavior

- `decode` is a static constructor: it returns a fully built value and allocates nothing.
- `encode` prints the canonical spelling into the allocator you pass and returns memory you own. Free it with that
  allocator.
- `value` returns the raw integer: bytes for volumes, nanoseconds for durations.
- `value64` is the checked narrowing for volumes, because `eib` and larger routinely exceed `u64`.
- `fromBase(n)` takes a count of the base unit. For volumes it multiplies by `2^shift` in `u128`; for durations it
  multiplies by the nanosecond factor in `i128`. It fails only with `error.UnitOverflow`.
- `fromBytes(raw)` / `fromNanos(raw)` take an absolute raw value and fail only with `error.NotMultipleOfBase`.
- `deinit` exists for dap's `isDecodable` gate and is a no-op for these integer wrappers.

### Siggy service methods

```zig
pub const Siggy = struct {
    pub fn decode(
        self: *Siggy,
        source_arena: std.mem.Allocator,
        value_arena: std.mem.Allocator,
        node: anytype,
        diag: anytype,
    ) anyerror!void;
    pub fn encode(self: *const Siggy, allocator: std.mem.Allocator) anyerror![]const u8;
};
```

These are called by siggy, not by consumer code. `node` is siggy's AST node and `diag` is its diagnostic; both are
`anytype` so the module stays SDK-free. `decode` accepts `.literal` and `.quoted` nodes, running the same grammar on the
text, and rejects block/tagged shapes.

## Canonical encoding

`encode` always writes the value in the selected base units with that base's canonical suffix:

| wrapper                  | raw value     | encodes as |
| ------------------------ | ------------- | ---------- |
| `Volume(.b)`             | 2097152       | `2097152`  |
| `Volume(.kib)`           | 2097152       | `2048KiB`  |
| `Volume(.mib)`           | 2097152       | `2MiB`     |
| `Volume(.mib)`           | 0             | `0MiB`     |
| `Duration(.nanosecs)`    | 5             | `5ns`      |
| `Duration(.microsecs)`   | 5000          | `5us`      |
| `Duration(.secs)`        | 0             | `0s`       |
| `Duration(.mins)`        | 120000000000  | `2m`       |
| `Duration(.mins)`        | -120000000000 | `-2m`      |

Every canonical form decodes back to the identical value. This round trip is required by both SDKs: dap renders
`.direct` defaults in help and re-decodes them at runtime, and siggy writes encoded values back into configs.

## Errors

dap splits failures by class; siggy reports both as `error.Custom` with a diagnostic message:

| failure class | dap            | siggy                                     |
| ------------- | -------------- | ----------------------------------------- |
| grammar       | `InvalidWire`  | `error.Custom` + message                  |
| value         | `InvalidValue` | `error.Custom` + message                  |
| node shape    | not applicable | `error.UnsupportedShape` + message        |

Grammar failures are bad or unknown suffixes, stray bytes or whitespace, empty input, misordered or repeated duration
units, and bare fractions without a suffix. Value failures are inexact decimals, values that are not a multiple of the
base after evaluation, and domain overflow. For siggy, the diagnostic offset is pre-filled by siggy and left untouched;
only `code` and `message` are set.

## Examples

### A dap CLI flag and argument

```zig
const std = @import("std");
const dap = @import("dap");
const zunit = @import("zunit");

const MiB = zunit.Volume(.mib).Dap;
const Byte = zunit.Volume(.b).Dap;
const Mins = zunit.Duration(.mins).Dap;

const two_mib = MiB.fromBase(2) catch unreachable;
const negative_two_minutes = Mins.fromBase(-2) catch unreachable;

const Def = .{
    .cache = dap.Flag(MiB){
        .default = dap.defaultValue(MiB, two_mib),
        .help = "Cache size, e.g. 2MiB or 2048KiB.",
    },
    .timeout = dap.Flag(Mins){
        .default = dap.defaultValue(Mins, negative_two_minutes),
        .help = "Timeout, e.g. 1h30m or 120s.",
    },
    .path = dap.Argument(Byte){ .help = "Input file size in bytes." },
};

const CLI = dap.generate(dap.App{
    .name = "example",
    .help = "Example CLI with unit literals.",
}, Def);

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var diag: dap.Diag = .{};
    defer diag.deinit(allocator);

    var cli = try CLI.parse(allocator, std.process.Environ.empty, &.{
        "--cache", "8MiB",
        "--timeout", "1h30m",
        "4096",
    }, &diag);
    defer CLI.deinit(&cli, allocator);

    std.debug.print("cache = {d} bytes\n", .{cli.cache.value()});
    std.debug.print("timeout = {d} ns\n", .{cli.timeout.value()});
    std.debug.print("path = {d} bytes\n", .{cli.path.value()});
}
```

`--cache 8MiB`, `--cache 2048KiB`, and `--cache 8388608` all decode under `Volume(.mib)` because each is a whole number
of MiB. `--cache 512KiB` is rejected. The declared defaults are round-tripped by dap: `2MiB` also appears as the
rendered default in `--help`.

### A siggy config

```zig
const std = @import("std");
const siggy = @import("siggy");
const zunit = @import("zunit");

const MiB = zunit.Volume(.mib).Siggy;
const Secs = zunit.Duration(.secs).Siggy;

const Config = struct {
    cache: MiB,
    timeout: ?Secs = null,
};

const Parser = siggy.parser(Config);

fn silentPrinter(allocator: std.mem.Allocator, diag: *siggy.Diagnostics) anyerror!void {
    _ = allocator;
    _ = diag;
}

pub fn main() !void {
    var value_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer value_arena.deinit();

    var p: Parser = undefined;
    try p.init(std.heap.page_allocator, value_arena.allocator(), silentPrinter);

    const config = try p.parse(
        \\cache = 2MiB
        \\timeout = "1h30m"
        \\
    );
    std.debug.print("cache = {d} bytes\n", .{config.cache.value()});
    std.debug.print("timeout = {d} ns\n", .{config.timeout.?.value()});

    const rendered = p.stringify(config);
    std.debug.print("{s}", .{rendered});
}
```

Both literal (`cache = 2MiB`) and quoted (`timeout = "1h30m"`) forms are accepted. An optional field follows normal
siggy optionality: `timeout = { }` yields `null` before the unit decoder runs. On failure, `p.diagnostic.?.code` is
`error.Custom` and `p.diagnostic.?.message` reads, for example, `512KiB is not a whole number of mebibytes`.

### Decoding and encoding directly

```zig
const std = @import("std");
const zunit = @import("zunit");

const MiB = zunit.Volume(.mib).Dap;
const Secs = zunit.Duration(.secs).Dap;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const cache = try MiB.decode(allocator, "2.0MiB");
    std.debug.print("{d}\n", .{cache.value()}); // 2097152

    const text = try cache.encode(allocator);
    defer allocator.free(text);
    std.debug.print("{s}\n", .{text}); // 2MiB

    const timeout = try Secs.decode(allocator, "-1h30m");
    std.debug.print("{d}\n", .{timeout.value()}); // -5400000000000

    // Base units in, raw units out.
    const half_hour = try Secs.fromBase(1800);
    std.debug.print("{d}\n", .{half_hour.value()}); // 1800000000000

    // Absolute raw value in; the multiple check is enforced.
    _ = Secs.fromNanos(1_500_000_000) catch |err| {
        std.debug.print("rejected: {s}\n", .{@errorName(err)}); // NotMultipleOfBase
    };
}
```

### Compile-time defaults and narrowing

```zig
const zunit = @import("zunit");

const MiB = zunit.Volume(.mib).Dap;
const Byte = zunit.Volume(.b).Dap;
const Secs = zunit.Duration(.secs).Dap;

// Checked at comptime: a value that cannot be represented is a compile error.
const default_cache = MiB.fromBase(2) catch unreachable; // 2MiB
const default_timeout = Secs.fromBase(-30) catch unreachable; // -30s

// Narrowing a u128 byte count to u64:
const small: u64 = (Byte.fromBase(4096) catch unreachable).value64() catch unreachable;

// The narrowing can fail, the constructor cannot:
const huge = Byte.fromBase(@as(u128, 1) << 70) catch unreachable; // ok
const narrowed: ?u64 = huge.value64() catch null; // null: does not fit in u64
```

## Where to look next

- `README.md` is the short introduction.
- `designs/units-module.md` is the normative specification: full grammar tables, example verdicts, wrapper contracts,
  and SDK integration constraints.
- `AGENTS.md` documents the repository internals: layout, test layout, and contribution rules.
