# dap SDK reference

Audience: an LLM (or a person) **using** the `dap` library as a dependency to
build a command-line program. This is not a guide to working on `dap` itself
(that is `AGENTS.md`).

`dap` is a declarative command-line parser for **Zig 0.16.0**. You describe the
program's flags and arguments once, as a struct literal, and `dap.generate`
produces, at compile time, a parser plus a strongly-typed result struct.

```zig
const CLI = dap.generate(app, def);       // app: dap.App, def: declaration struct
const cli = try CLI.parse(allocator, environ, args, &diag);   // returns CLI.View
```

The declaration is comptime data. Both `generate` arguments are `comptime`, so
every name, type and default is resolved by the compiler. There is no runtime
schema.

---

## 1. Module wiring

`dap` is imported as a normal Zig module named `dap`:

```zig
const dap = @import("dap");
```

In a consumer's `build.zig`, add the dependency and attach it to the module
that needs it:

```zig
const dap_module = b.addModule("dap", .{
    .root_source_file = b.path("src/root.zig"),   // path inside the dap package
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("dap", dap_module);
```

Everything public is re-exported from `src/root.zig`; there is no separate
"prelude" module.

---

## 2. Minimal end-to-end program

```zig
const std = @import("std");
const dap = @import("dap");

// Field names are wire names, verbatim. This declares --login/-l and a
// positional <path>.
const def = .{
    .login = dap.Flag([]const u8){
        .short = "l",
        .default = dap.Default(dap.String){ .env = "USER" },
        .validation = dap.Validate.stringNotEmpty,
        .help = "User login.",
    },
    .path = dap.Argument([]const u8){
        .validation = dap.Validate.stringNotEmpty,
        .help = "Path of the file to download.",
    },
};

const CLI = dap.generate(
    dap.App{ .name = "api-downloader", .help = "Download a file from the API." },
    def,
);

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    // Pure payload: strip the binary name, start at index 0.
    const argv = try init.minimal.args.toSlice(arena);
    const args = argv[1..];

    var diag: dap.Diag = .{};
    defer diag.deinit(arena);

    // On failure this prints diagnostics + help to stderr and exits(1);
    // on --help/-h it prints help to stdout and exits(0). See §9.
    var cli = try CLI.parse(arena, init.minimal.environ, args, &diag);

    // deinit is a namespace function taking `&view`, NOT a method on the View
    // itself (`cli.deinit(...)` does not compile). See §5 and §12.
    defer CLI.deinit(&cli, arena);

    std.debug.print("{} {}\n", .{ cli.login, cli.path });
}
```

The bundled manual example lives in `src/main.zig`; run it with
`zig build run -- --help`.

---

## 3. The declaration DSL

The declaration is an **anonymous struct literal**. Each field is one of:

| Declaration            | Field kind | Appears on `View` as                    |
|------------------------|------------|-----------------------------------------|
| `dap.Flag(T){...}`     | flag       | `T` (or `?T` when optional)             |
| `dap.Argument(T){...}` | argument   | `T` (or `?T` only if declared optional) |
| `dap.Group(def, name)` | group      | its members, flattened                  |
| `dap.Alt(.{...})`      | alt        | `?Union` (one per Alt)                  |
| `dap.Command(meta, def)` | command  | `?View` under a `_`-prefixed name (`_cmd`) |

Order matters: `View` fields appear in declaration order, with the injected
`builtin_help: bool` first (§6), then the `Alt` unions and the per-command
sub-`View`s. Declaration field names must not start with `_`; that prefix is
reserved for the command `View` fields.

### 3.1 Flag names

Field names are **wire names verbatim** (`dry_run` → `--dry_run`). A
dash-spelled wire name requires an explicit `.long`. A field name must not
begin with `_`: that prefix is reserved for the `_`-prefixed command fields
the `View` carries (§3.7, §5).

```zig
.dry_run = dap.Flag(bool){ .long = "dry-run" },   // -> --dry-run
```

`--long` accepts `--name value` and `--name=value`. Short names are always
explicit via `.short`; `-s value`, `-s=value` are accepted.

### 3.2 `Flag(T)`

```zig
pub fn Flag(comptime T: type) type {
    return struct {
        long: ?String = null,                 // defaults to the field name
        short: ?String = null,
        default: ?Default(T) = null,
        validation: ?fn (std.mem.Allocator, T) std.mem.Allocator.Error!?String = null,
        help: String = "",
        i18n: ?String = null,
    };
}
```

### 3.3 `Argument(T)`

```zig
pub fn Argument(comptime T: type) type {
    return struct {
        name: ?String = null,                 // help label; defaults to field name
        default: ?Default(T) = null,          // only on the LAST argument
        validation: ?fn (std.mem.Allocator, T) std.mem.Allocator.Error!?String = null,
        help: String = "",
        i18n: ?String = null,
    };
}
```

Arguments fill positional slots in declaration order. Only the **last**
declared argument may carry a default.

### 3.4 `Default(T)` and `defaultValue`

```zig
pub fn Default(comptime T: type) type {
    return struct {
        direct: ?T = null,   // compile-time literal
        env: ?String = null, // environment variable name, consulted first
    };
}

pub fn defaultValue(comptime T: type, vT: T) Default(T);  // == .{ .direct = vT }
```

Precedence when nothing is on the wire: **env value > direct default > zero
value**. A spec with a default is not required; a spec without one is.

### 3.5 `Group(def, name)`

A purely declarative grouping that affects only help output. Members are
flattened into `View` in declaration order, and the group name becomes a
heading. Flags and arguments are grouped in separate namespaces.

```zig
.server = dap.Group(.{
    .host = dap.Flag([]const u8){ .help = "Host." },
    .port = dap.Flag(u16){ .default = dap.defaultValue(u16, 8080) },
}, "Server settings"),

// cli.host, cli.port are ordinary View fields.
```

Nested groups are rejected at compile time. A `Group` name must not collide
with any `Alt` branch tag.

### 3.6 `Alt(.{...})` and `VariantNamed`

An `Alt` declares **mutually exclusive** groups of flags. Each anonymous-struct
field is a branch; the field name (or a `VariantNamed` override) is the branch
tag and the help-group heading.

```zig
.source = dap.Alt(.{
    .file = .{
        .file = dap.Flag([]const u8){ .short = "s", .help = "Source file." },
    },
    .net = dap.VariantNamed("net", .{
        .url = dap.Flag([]const u8){ .help = "Source URL." },
    }),
}),
```

Rules:

- Branches may contain **only flags**.
- Branch flags **must not declare defaults** (a default would imply implicit
  activation).
- Optional flags are not allowed inside branches.
- Branch tags must be unique; a tag must not equal a `Group` name.
- Flag names (long and short) must be unique across branches and the parent.

Semantics: the union is `null` until one branch member is seen, then it holds
that branch's payload struct. Every member of the active branch is required
(no defaults exist). Seeing members of two branches is a `ConflictingAlt`
error. Each branch renders a usage alternation clause and a help heading.

```zig
if (cli.source) |src| switch (src) {
    .file => |p| try useFile(p.file),
    .net  => |p| try useUrl(p.url),
};
```

### 3.7 `Command(meta, def)`, `CommandMeta`

A subcommand is a **sibling field** of the parent declaration, not a wrapper.
Each command field is a `Command(meta, def)` where `def` is an ordinary
declaration struct (which may itself contain further `Command` fields).

```zig
pub const CommandMeta = struct {
    name: ?String = null,   // wire name; defaults to the field name
    help: String = "",
    i18n: ?String = null,
};

.start = dap.Command(.{ .help = "Start." }, .{
    .name = dap.Argument([]const u8){},
}),
.stop = dap.Command(.{ .name = "halt", .help = "Stop." }, .{}),
```

The first argument is typed `CommandMeta`, so an anonymous struct literal
coerces. Each command field contributes one `?View` field to the parent
`View`, stored under the declaration field name prefixed with `_` (`_start`),
`null` unless the command's wire name (`.name` orelse the field name) appears.
This raw `_`-prefixed field is how the parsed sub-view is carried; declaration
field names must not themselves begin with `_` (that prefix is reserved, §13),
and consumers normally reach the active command through `command` below:

```zig
// View field: cli._start, cli._stop
if (cli._start) |s| try serve(s.name);
```

Handoff: a positional token equal to a registered command name terminates the
current parse and invokes that subcommand's parse on the remaining tokens
(again from its own index 0). Command names must be unique within a level and
a command field name must not collide with a flag or group-member name;
commands nest arbitrarily. Nested commands read as
`cli._parent.?._child.?.file`.

When a declaration carries at least one command, its generated namespace also
exposes `command(view) ?CommandPayload` — the official, switch-shaped way to
reach the active command. `CommandPayload` is a tagged union with one member
per command, keyed by the **plain declaration field name** (neither the wire
name, nor the `_`-prefixed `View` field: a `stop` field stored as `_stop` and
wire-named `halt` switches as `.stop`), each payload the subcommand's `View`:

```zig
if (CLI.command(cli)) |cmd| switch (cmd) {
    .start => |s| try serve(s.name),
    .stop => try shutdown(),
} else {
    // root level execution (no subcommand token appeared)
}
```

At most one command field is ever non-null (the scan hands off at most once),
so `command` returns the single active branch or `null`. It allocates nothing
and cannot fail. A declaration with no commands exposes neither `command` nor
`CommandPayload` (a reference is a compile error), so the accessor is always
safe to call where a level declares subcommands and simply absent otherwise.

Flag long names and short aliases must be **globally unique across the entire
command tree**, not merely within a level: whenever help is requested, flags
from every ancestor level merge into the active scope (see §10.5), so a name
reused at two levels (or across sibling commands) would be ambiguous. This is
enforced at compile time (§13).

Because flags of all levels merge, `-h`/`--help` is *context-sensitive*: a
request after a command describes that command's scope. `app -h` shows the
app; `app svc -h` shows `svc` (its arguments/subcommands plus the merged flag
set); `app svc build -h` shows the deepest scope. The usage header
reconstructs the path, e.g. `Usage: app svc build ...`. A help token before
the commands (`app -h svc build`) resolves to the deepest command actually
entered, matching the same rule.

---

## 4. Value types

Builtin value types work out of the box:

- `bool`
- all integer types (`u8`…`u64`, `i8`…`i64`, `usize`, `isize`)
- all float types (`f16`…`f128`, including `f80`)
- `dap.String` (`[]const u8`)

`bool` decoding accepts `true`/`false` and `1`/`0`. Integers parse base 10;
floats use `std.fmt.parseFloat`.

### 4.1 Custom value types

Any other type is usable when it exposes:

```zig
pub fn decode(allocator: std.mem.Allocator, data: []const u8) dap.DecodeError!Self
pub fn encode(self: *Self, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8
pub fn deinit(self: *Self, allocator: std.mem.Allocator) void
```

These three are the stable contract; more optional methods may be added later.
`decode` is a static constructor: it takes the allocator and the wire token and
returns a fully built value, so a type with internal allocations (arg arrays,
nested buffers) can own them. `dap.DecodeError` folds in the allocator's error
set for that reason. `decode` returning `InvalidWire` means "this token is not
the right shape"; `InvalidValue` means "shape is fine, value rejected".
`encode` builds the wire spelling into allocator-owned memory the caller frees.
`deinit` releases the value's internals; it must not call
`allocator.destroy(self)` (the value is a copy, see §12).

```zig
const Port = struct {
    value: u16 = 0,
    pub fn decode(allocator: std.mem.Allocator, data: []const u8) dap.DecodeError!Port {
        _ = allocator;
        const v = std.fmt.parseInt(u16, data, 10) catch return error.InvalidWire;
        if (v == 0) return error.InvalidValue;
        return .{ .value = v };
    }
    pub fn encode(self: *Port, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
        return std.fmt.allocPrint(allocator, "{}", .{self.value});
    }
    pub fn deinit(self: *Port, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};
```

If a value type does not satisfy `isDecodable` (no `decode`/`encode`/`deinit`,
or an unsupported pointer), the declaration is a **compile error**.

### 4.2 `Enumeration(T)` and `Enum`

`Enumeration` builds a value type from named branches. Each branch is a
`dap.Enum`, optionally overriding its wire name:

```zig
pub const Enum = struct {
    name: ?String = null,   // wire name; defaults to the field name
    help: String = "",
    i18n: ?String = null,
};

const Mode = dap.Enumeration(.{
    .fast = dap.Enum{},
    .slow = dap.Enum{ .name = "glacial" },
});
```

The resulting type exposes:

- `view` — a Zig enum (`EnumView`) with one tag per branch, defaulting to the
  first branch;
- `EnumView` — that enum type, for comparisons;
- `names` — the wire names in declaration order;
- `decode` / `encode` / `deinit`.

Use it as a `Flag`/`Argument` value type:

```zig
.mode = dap.Flag(Mode){
    .long = "mode",
    .default = dap.Default(Mode){ .direct = Mode{ .view = .slow } },
},
// --mode glacial   -> cli.mode.view == Mode.EnumView.slow
```

Duplicate wire names are a compile error. An **empty** `Enumeration` is
degenerate: it yields a type with `decode`/`encode`/`deinit` only (no `view`,
`EnumView` or `names`) and rejects every token.

---

## 5. `View` and `parse`

`CLI.View` is a generated struct:

- `builtin_help: bool` first (the injected `-h, --help`, §6);
- one field per spec, in declaration order;
- one `?Union` field per `Alt` and one `?View` field per command, after the
  specs. A command's `View` field carries a `_` prefix (`_stop`); the plain
  name is the tag of the `command` union (§3.7). Declaration field names must
  not begin with `_`.

`CLI.parse`:

```zig
pub fn parse(
    allocator: std.mem.Allocator,
    environ: std.process.Environ,   // by value, not pointer
    args: []const []const u8,       // payload, WITHOUT the binary name
    diag: ?*dap.Diag,               // may be null
) ParseError!View
```

`args` is **pure payload**: iteration starts at index `0` and never skips a
token, at every level (root and subcommands). Pass `os.argv[1..]` equivalent.

`parse` is self-contained and **terminating** (see §9): on success it returns
the `View`; on failure it prints diagnostics + help to stderr and
`std.process.exit(1)`; on a help request it prints help to stdout and
`std.process.exit(0)`. The declared error union is therefore not observed in
normal use.

Generated namespace members:

| Member                          | Description                                              |
|---------------------------------|----------------------------------------------------------|
| `View`                          | The result struct (see above).                           |
| `parse(alloc, environ, args, diag) ParseError!View` | Parse and return `View` (exits on help/failure). |
| `helpText(alloc) !String`       | Caller-owned rendered help using `app.help_renderer.style`. |
| `helpData(alloc) !HelpData`     | Runtime description; `HelpData.renderCompact(alloc)` renders it. |
| `app_meta`                      | The `App` passed in.                                     |
| `specs`                         | Normalized comptime spec table.                          |
| `commands`                      | The detected command entries (slice; empty when none).   |
| `CommandPayload`                | Tagged union of command fields; **only when subcommands exist**. |
| `command(view) ?CommandPayload` | Wrap the active subcommand's `View`, else `null`; **only when subcommands exist**. |
| `deinit(&view, alloc)`           | Release every owned field of a `View` from a successful parse (see §12). |

`deinit` is a **namespace-level function**, not a method on `View`. `View` is a
generated struct with fields only, so it has no decls: write
`CLI.deinit(&view, allocator)`, never `view.deinit(allocator)` (the latter is a
"no field or member function named 'deinit'" compile error). Because it mutates
the view, the local must be `var`.

---

## 6. Builtin help flag

A `-h, --help` flag is injected at the **beginning** of every declaration
before normalization. Its `View` field is `builtin_help: bool`, positioned
first.

When `-h`/`--help` is seen (bare, or `--help=true`), the parse **bypasses all
required checks and validations**, renders help to stdout, and exits `0`.
`--help=false` is honored and does not trigger help.

The request is honored **anywhere in the active command chain**: a deep
`app svc build -h` (or a help token before the commands, `app -h svc build`)
bypasses the required checks of every ancestor level too, and renders the
context-sensitive help of the deepest active command (§10.5). Every level's
declaration carries the builtin, but a merged rendering shows `-h, --help`
exactly once.

Consequences:

- Declaring your own field named `help` with `.long = "help"` is a compile
  error (duplicate long flag).
- Help output always lists `-h, --help` first in the flags section.

---

## 7. Required, optional and boolean flags

### 7.1 Derived `required`

A flag or argument is **required iff it has no default** (neither direct nor
env). This is uniform across types.

### 7.2 Boolean flags

Boolean flags are a deliberate exception:

- They are **always optional**; an omitted bool flag is `false`.
- A direct default of `true` is a **compile error**. To express "on by
  default", use a negative long name defaulting to `false`:
  `--no-color` with `.default = dap.defaultValue(bool, false)`.
- An optional bool renders bracketed (`[--flag]`) in the usage header.

### 7.3 Optional flags (`?T`)

Wrap a flag to make its `View` field optional:

```zig
.jobs  = dap.Optional(dap.Flag(u32){ .short = "j" }),
.label = @as(?dap.Flag([]const u8), dap.Flag([]const u8){ .long = "label" }),
```

Both spellings store a genuine `?Flag(T)`. The `View` field is `?T`, `null`
when absent. Rules:

- Optional flags **must not declare a default** (direct or env).
- Validation is **skipped** for `null` and runs normally when a value is
  present.
- Optional `Argument`s are rejected (`?Argument` is not supported).
- Optional flags are **not allowed inside `Alt` branches**.

---

## 8. Parsing rules and edge cases

- **Terminator.** `--` makes every following token a literal positional and
  disables command handoff, so command-like or flag-like literals can be
  passed through.
- **Missing value.** A non-bool flag given without a value is `MissingValue`.
- **Unknown flag.** An unmatched `--long` or `-s` token is `UnknownFlag`. A
  token that misses the active level's own specs is first retried against every
  ancestor level's specs (nearest first), since each ancestor's flags merge
  into a deep help scope and are globally unique; a hit assigns into that
  ancestor's `View`, so `app sub --root-flag` works.
- **Too many arguments.** A positional token with no free slot is
  `TooManyArguments`.
- **Zero values.** An absent spec with a defaultless, optional, or bool type
  falls back to a zero value (`""` for strings, `0`/`false`/`null` otherwise).
- **Env decoding.** An env value is decoded like a wire token; a malformed one
  is reported with the field name. A non-WTF-8 env value is `InvalidWtf8`.

---

## 9. Errors, `Diag`, and process exit

`ParseError` folds decode failures into one set:

```zig
pub const DecodeError = error{ InvalidWire, InvalidValue };

pub const ParseError = error{
    UnknownFlag,       // long/short token matched no declaration
    MissingValue,      // non-bool flag without a value
    MissingRequired,   // required flag/argument never provided
    TooManyArguments,  // positional with no free slot
    ConflictingAlt,    // two branches of one Alt activated
    InvalidWtf8,       // env value not valid WTF-8
} || std.mem.Allocator.Error || DecodeError;
```

`Diag` carries detail for the most recent failed parse:

| Field     | Meaning                              | Ownership                    |
|-----------|--------------------------------------|------------------------------|
| `field`   | Declaration field name that failed.  | Borrowed (comptime).         |
| `token`   | Offending argv token.                | Borrowed (caller argv).      |
| `message` | Human-readable validation message.   | Owned; free via `deinit`.    |

```zig
var diag: dap.Diag = .{};
defer diag.deinit(allocator);   // frees only `message`
```

**`parse` never returns an error to the caller.** Internally it runs the parse
pipeline, and:

- on any `ParseError` it prints `field`/`token`/`message` plus the help text to
  **stderr** and calls `std.process.exit(1)`;
- on a help request it prints help to **stdout** and calls
  `std.process.exit(0)`.

Because of this, `try CLI.parse(...)` is idiomatic: there is nothing to handle
for a CLI that should just report and exit. If you need error handling instead
of process exit, you cannot reach the internal `parseInner`; design around
`helpData`/`helpText` and your own driver, or treat `parse`'s exit as the
contract.

---

## 10. Help rendering

Two layers:

1. `CLI.helpText(allocator) !String` — fill an `App`-configured description and
   render it with `app.help_renderer.style`. Returns a caller-owned string.
2. `CLI.helpData(allocator) !HelpData` — fill a runtime, plain-data description
   for custom UIs (completion, man pages) or to render manually with
   `HelpData.renderCompact(allocator)`.

```zig
const text = try CLI.helpText(allocator);
defer allocator.free(text);

// or, explicit two-step:
var data = try CLI.helpData(allocator);
defer data.deinit(allocator);
const compact = try data.renderCompact(allocator);
defer allocator.free(compact);
```

Nothing help-related runs unless `helpText`/`helpData` is called.

### 10.1 `App` and renderer configuration

```zig
pub const App = struct {
    name: String,
    help: String,
    i18n: ?String = null,
    help_renderer: struct {
        style: HelpRendererStyle = .{ .compact = {} },
        highlight: HelpRendererHighlight = .{ .bold = {} },
    } = .{},
};

pub const HelpRendererStyle = union(enum) {
    compact: void,   // builtin kong-style two-column layout
    custom: *const fn (self: *const HelpData, allocator: std.mem.Allocator) std.mem.Allocator.Error!String,
};

pub const HelpRendererHighlight = union(enum) {
    flat: void,      // no escape codes
    bold: void,      // default
    color: void,
    custom: HelpHighlight,
};
```

Custom-style tip: set `App.help_renderer.style = .{ .custom = myRenderer }`.
The callback receives the filled `HelpData` and returns an owned string.

### 10.2 Layout

The compact layout (used by `renderCompact` and the default style) is:

```text
Usage: dap-example [<target>] [flags]

Manual test of the dap module.

Arguments:
  [<target>]    Target directory.

Flags:
  -h, --help        Show context-sensitive help.
      --source=.    Source directory.
  -l, --last        Show last modification.

Group
      --count=1    Number of items.
  -v, --value=1    Value of items.
```

- Short and long names occupy aligned sub-columns; the value placeholder is
  `=DEFAULT` when a direct default exists, else `=NAME` (upper-cased).
- Flag groups are ordered by name, with the ungrouped bucket first.
- In the usage header: required flags render as `--name` / `--name=VALUE`,
  optional bools as `[--flag]`, positionals as `<arg>` or `[<arg>]` when they
  have a default, and `[flags]` appears when there are defaulted flags.
- Optional (`?T`) flags are listed in the flags section but omit from the
  usage header.
- `Alt` flags are not listed individually in the usage line; each `Alt`
  contributes one parenthesized alternation clause:

```text
Usage: dap-example (--file=FILE | --url=URL) <string> [flags]
```

### 10.3 `HelpData` structure

`HelpData` is plain data, all allocated with the caller's allocator and
released with `HelpData.deinit`:

```zig
pub const HelpData = struct {
    pub const Flag = struct {
        name: String,
        short: ?String,
        help: String,
        default: ?String,       // rendered, null when required
        takes_value: bool,
        alt: ?String = null,        // owning Alt field name
        alt_branch: ?String = null, // branch tag
        optional: bool = false,
    };
    pub const Argument = struct { name: String, help: String, default: ?String };
    pub const FlagGroup = struct { name: ?String, flags: []Flag };
    pub const ArgGroup  = struct { name: ?String, args: []Argument };
    pub const CommandInfo = struct { name: String, help: String };
    pub const Usage = struct { branches: [][]Flag };

    name: String,
    info: String,
    flag_groups: []FlagGroup,
    arg_groups: []ArgGroup,
    usage_alts: []Usage,
    commands: []CommandInfo,
    highlight: HelpRendererHighlight,

    pub fn deinit(self: *HelpData, allocator: std.mem.Allocator) void;
    pub fn renderCompact(self: *const HelpData, allocator: std.mem.Allocator) std.mem.Allocator.Error!String;
};
```

`usage_alts` holds one `Usage` per `Alt`; each `Usage.branches` is one entry
per tag, holding slices of `Flag` that **reference entries already owned by**
`flag_groups` (so `deinit` frees only the outer arrays).

### 10.4 Highlighting

`App.help_renderer.highlight` selects an ANSI scheme: `flat` (none), `bold`
(default), `color`, or `custom` with a `HelpHighlight`. A scheme has tokens for
the usage header (app name, required flag name/value, optionals, arguments) and
for sections (`groups`, `args`, `flags` name/value). Column widths are measured
on the raw text before codes are emitted, so highlighting never disturbs
alignment.

### 10.5 Context-sensitive (merged) help

When help is requested after one or more subcommands, the rendering describes
the **deepest active command**. The parse walks the runtime `View` chain
recursively (`helpRequested` / `appendActiveScopes`), builds one `HelpData`
per active level (root first), and folds them with `absorbScope`:

- **Flags accumulate downwards**: flag groups merge by name (the ungrouped
  bucket merges as one, and same-named `Group`/`Alt` groups from different
  levels combine into a single block under one header). Entries are moved, not
  copied.
- **Arguments and subcommands come from the deepest scope only**: `arg_groups`
  and `commands` are replaced by the deeper level's.
- **`name` becomes the command path**: e.g. `app svc build`, so the usage
  header reads `Usage: app svc build <target> [flags]`.
- **`Alt` usage clauses accumulate** root-first.
- The injected `-h, --help` is deduped, so it appears once.

Rendering then reuses the same `renderCompact` (or `.custom` renderer)
unchanged. Root-scope help is byte-identical to a non-merged rendering. On a
*parse failure* (not a help request) the help stays root-scoped, since the
command path is not reconstructed from `Diag`.

```text
$ app svc build -h
Usage: app svc build --config=CONFIG <target> [flags]

Build.
```

---

## 11. Validation

`Validate` provides ready-made validators:

```zig
dap.Validate.stringNotEmpty        // fn (Allocator, String) Error!?String
dap.Validate.intNotZero(u8)        // comptime factory over an integer type
```

Signature: `fn (std.mem.Allocator, T) std.mem.Allocator.Error!?String`. Return
`null` on success, an **allocated** message on failure; you may also return
`error.OutOfMemory`.

Validation runs in two places: on every absent spec's resolved value, and over
the members of an active `Alt` branch. It runs regardless of whether the value
came from the wire, an env var, or a direct default. On failure, `parse`
reports `InvalidValue` with `diag.field` and `diag.message` (the message is
freed by `Diag.deinit`; when `diag` is `null`, `dap` frees it internally).

Inline example:

```zig
.user = dap.Flag([]const u8){
    .short = "u",
    .validation = dap.Validate.stringNotEmpty,
    .default = dap.Default([]const u8){ .env = "DAP_USER" },
},
.level = dap.Flag(u8){
    .validation = dap.Validate.intNotZero(u8),
    .default = dap.defaultValue(u8, 1),
},
```

---

## 12. Ownership

- **The `View` owns everything it stores.** `[]const u8` fields (wire, env and
  direct defaults included) are duplicated with the allocator passed to `parse`;
  custom-type fields own their internals. Release them with
  `CLI.deinit(&view, allocator)`, which frees string slices, calls a custom
  type's `deinit`, recurses into optionals, releases only the active `Alt`
  branch, and recurses into every activated command sub-`View`. It is valid
  once on a `View` from a **successful** `parse` and is **not idempotent** (a
  second call double-frees). `args`/`environ` are borrowed only during `parse`;
  after it returns the `View` references neither.
- `deinit` is a **namespace function**, not a method: call
  `CLI.deinit(&view, allocator)`. `View` is a generated struct with no decls,
  so `view.deinit(...)` does not compile, and the receiver must be a `var`.
- A custom `decode` returns `Self` **by value**; its `deinit` must release
  internals without `allocator.destroy(self)`. A custom struct's comptime
  direct default is routed through an `encode`/`decode` roundtrip so the value
  in the `View` is fully owned (never pointing at comptime memory).
- An **arena** remains the simplest lifetime; `CLI.deinit` matters when a plain
  allocator is used.
- `Diag.deinit` frees only the allocated `message`; `field` and `token` are
  borrowed.
- `helpText` and `renderCompact` return caller-owned strings.
- `helpData` returns a `HelpData` whose every string/slice is caller-owned;
  release with `HelpData.deinit`.

---

## 13. Compile-time rules (what fails to build)

These mistakes are compile errors, not runtime errors:

- A declaration field that is not a `Flag`, `Argument`, `Group`, `Alt`,
  or `Command`.
- A declaration field whose name starts with `_` (the prefix is reserved for
  the `_`-prefixed command fields the `View` carries; §3.7, §5).
- Duplicate long flag names, duplicate short flag names, duplicate field names.
- **Duplicate flag names across levels**: because flags of every ancestor level
  merge into a deep help scope, long names and short aliases must be globally
  unique across the whole command tree (sibling commands included). The message
  names both level paths, e.g. `duplicate long flag '--verbose' at 'app svc'
  and 'app svc build'; flag names must be globally unique across the command
  tree (fields 'verbose' / 'verbose')`. The injected builtin and positional
  arguments are exempt.
- Duplicate command names within a level; a command field name colliding with
  a flag or group-member name; duplicate `Enumeration` wire names.
- Mixing subcommands and positional arguments in one declaration (a command
  token hands the rest of the wire to the subcommand, so a parent positional
  could never be filled).
- An `Argument` with a default that is not the last argument.
- A value type that is not decodable (missing `decode`/`encode`/`deinit`).
- A boolean flag with a direct default of `true`.
- An optional flag with a default; an optional `Argument`; an optional flag
  inside an `Alt` branch.
- An `Alt` with zero branches, duplicate branch tags, a non-flag branch member,
  a defaulted branch member, or a tag colliding with a `Group` name.
- Declaring a `--help` flag when the builtin is injected.

---

## 14. Semantics cheat sheet

- Every `parse` is pure payload: no token is skipped, at any nesting level.
- Field names are wire names verbatim; dashes need explicit `.long`. Field
  names must not start with `_` (reserved for the `_`-prefixed command
  `View` fields).
- `required` is derived: required ⇔ no default (bools excepted: always
  optional, default `false`).
- Precedence: wire > env > direct default > zero value.
- Defaults allowed only on the last argument.
- Subcommand handoff triggers on a positional equal to a command name; `--`
  disables it.
- `CLI.command(cli) ?CommandPayload` switches on the active subcommand (tags
  are the plain declaration field names; the `View` stores it `_`-prefixed);
  present only when the level declares commands.
- `Alt`: one active branch max; `ConflictingAlt` otherwise; all members of the
  active branch are required.
- Optional flags yield `?T`; defaults forbidden; validation skipped when null.
- Builtin `-h/--help` bypasses checks, prints help, exits 0 — at any depth;
  deep help merges ancestor flags and scopes to the deepest active command.
- Flag names/aliases are globally unique across the command tree.
- The `View` owns every stored string and custom value; release it with
  `CLI.deinit(&view, allocator)` (a namespace function, not a `View` method)
  on a successful parse, once and not idempotently.
- `parse` exits the process on help/failure; it does not return errors.

---

## 15. Building and testing (in the `dap` package)

```sh
zig build            # compile the module and the example executable
zig build test       # run the unit tests in src/dap.zig
zig test src/dap.zig # one-off test run
zig build run -- --help
```
