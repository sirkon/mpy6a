# dap SDK reference

Audience: users of the `dap` library, including language models generating Zig code against it. This document defines
the public API, its constraints, and its observable behavior. It is not a maintainer guide; internal implementation
lives in `AGENTS.md`.

`dap` is a declarative command-line parser for Zig 0.17.0. A declaration is a comptime struct literal. `dap.generate`
turns it into a namespace containing a parser, a typed result struct, and renderers for help and shell completion.

```zig
const CLI = dap.generate(app, def);                                  // app: dap.App, def: declaration struct
const cli = try CLI.parse(allocator, init, null, args, &diag);       // returns CLI.View
```

All names, types, defaults and constraints are resolved by the compiler. There is no runtime schema and no reflection.

---

## 1. Module wiring

Import the module as `dap`:

```zig
const dap = @import("dap");
```

In a consumer's `build.zig`:

```zig
const dap_module = b.addModule("dap", .{
    .root_source_file = b.path("src/root.zig"), // inside the dap package
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("dap", dap_module);
```

The public surface is re-exported from `src/root.zig`. There is no prelude.

---

## 2. Generated namespace

`dap.generate(app: dap.App, def: anytype)` is a comptime function returning a namespace. The following members are part
of the public contract:

| Member           | Type                                                          | Description                                                                       |
| ---------------- | ------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| `View`           | type                                                          | Result struct for one successful parse.                                           |
| `parse`          | `fn (alloc, init, i18n, args, diag) ParseError!View`          | Parse the payload. Exits on help and usage failure (§6).                          |
| `deinit`         | `fn (*View, alloc) void`                                      | Release every owned field. Namespace function, not a method.                      |
| `helpText`       | `fn (alloc) HelpError!String`                                 | Render help with `app.help_renderer.style`, the declaration default locale, and a highlight the destination supports. |
| `helpData`       | `fn (alloc) Allocator.Error!HelpData`                         | Build the plain-data help model. Caller releases it.                              |
| `usage`          | `fn (anytype) HelpError!void`                                 | Print the context-sensitive page for a `View`, in the locale it carries.          |
| `completion`     | `fn (alloc, app_name, shell, locale) Completion`              | Build a lazy completion-script handle. Root level only.                           |
| `i18n`           | `fn () I18n.Builder`                                          | Root-only builder seeded with the default locale and required keys.               |
| `default_locale` | `I18n.Locale`                                                 | The generated, complete default locale for this declaration.                      |
| `i18n_keys`      | `[]const dap.String`                                          | Every key translation must supply, including `builtin_help`.                      |
| `command`        | `fn (anytype) ?CommandPayload`                                | Switch over the active subcommand. Present only when the level declares commands. |
| `CommandPayload` | type                                                          | Union of subcommand `View`s. Present only with commands.                          |
| `app_meta`       | `dap.App`                                                     | The `App` passed to `generate`.                                                   |

`View`, `parse`, `helpText`, `helpData`, `usage`, `completion`, `i18n`, `default_locale`, `i18n_keys` and `deinit`
exist at every command level, but `i18n()` is a compile error on a non-root namespace. `command` and `CommandPayload`
exist only at levels that declare at least one command; referencing them elsewhere is a compile error.

`App`:

```zig
pub const App = struct {
    name: String,           // usage name or command path, e.g. "app" or "app svc"
    help: String,           // description shown by help
    i18n: ?String = null,   // translation key for `help`
    help_renderer: struct {
        style: HelpRendererStyle = .{ .compact = {} },
        highlight: HelpRendererHighlight = .{ .bold = {} },
    } = .{},
};
```

---

## 3. Declaration DSL

A declaration is an anonymous struct literal whose fields are `Flag`, `Argument`, `Group`, `Alt`, `Command`, or an
optional flag. Declaration order determines `View` field order and positional argument order.

### 3.1 Names and requirements

- A field name is the wire name verbatim: `dry_run` declares `--dry_run`.
- A dashed wire name requires an explicit `.long`: `.dry_run = dap.Flag(bool){ .long = "dry-run" }`.
- A declaration field name must not begin with `_`. That prefix is reserved for command `View` fields.
- A flag or argument is required if and only if it has no default. Booleans are exempt: an omitted boolean flag is
  `false`, and a direct default of `true` is a compile error. Use a negative long name defaulting to `false` to express
  "on by default".
- `.i18n` names a translation for `.help`: a field-name-shaped identifier (`[_A-Za-z][_0-9A-Za-z]*`, ASCII, non-empty)
  that is unique across the whole declaration tree and never `builtin_help`. `App.i18n`, `CommandMeta.i18n` and
  enumeration branch keys participate. The literal a key carries is unique too, so no two keys map to the same value;
  a field without a key may repeat any help text. Without a registered locale the declaration's generated English locale
  resolves the key to the same `.help` literal.

Long flags accept `--name value` and `--name=value`. Short flags are always explicit through `.short` and accept
`-s value` and `-s=value`.

### 3.2 `Flag(T)`

```zig
pub fn Flag(comptime T: type) type
```

| Field        | Type                                         | Default             | Meaning                        |
| ------------ | -------------------------------------------- | ------------------- | ------------------------------ |
| `long`       | `?String`                                    | `null` (field name) | Long wire name.                |
| `short`      | `?String`                                    | `null`              | Short alias, without the dash. |
| `default`    | `?Default(T)`                                | `null`              | Env or direct default.         |
| `validation` | `?fn (Allocator, T) Allocator.Error!?String` | `null`              | Value check.                   |
| `help`       | `String`                                     | `""`                | Help description.              |
| `i18n`       | `?String`                                    | `null`              | Translation key for `help`.    |
| `completion` | `?Completion.Predictor`                      | `null`              | Completion value source.       |

A non-boolean flag consumes one value. A boolean flag consumes no value.

Write `help` as a sentence ending with a period. Keep the existing punctuation when the text already ends with `!`, `?`,
`...`, a Unicode ellipsis (`…`), or a Unicode/full-width period (`。`, `．`); Simplified Chinese uses `。`.

### 3.3 `Argument(T)`

```zig
pub fn Argument(comptime T: type) type
```

| Field        | Type                                         | Default             | Meaning                                    |
| ------------ | -------------------------------------------- | ------------------- | ------------------------------------------ |
| `name`       | `?String`                                    | `null` (field name) | Display name in help.                      |
| `default`    | `?Default(T)`                                | `null`              | Env or direct default; last argument only. |
| `validation` | `?fn (Allocator, T) Allocator.Error!?String` | `null`              | Value check.                               |
| `help`       | `String`                                     | `""`                | Help description.                          |
| `i18n`       | `?String`                                    | `null`              | Translation key for `help`.                |
| `completion` | `?Completion.Predictor`                      | `null`              | Completion value source.                   |

Arguments fill positional slots in declaration order. Only the last declared argument may carry a default. An argument
without a default is required. Optional arguments are not supported. The `help` punctuation rule from §3.2 applies.

### 3.4 `Default(T)` and `defaultValue`

```zig
pub fn Default(comptime T: type) type // { direct: ?T, env: ?String }
pub fn defaultValue(comptime T: type, value: T) Default(T) // .{ .direct = value }
```

Value precedence, from highest to lowest: argv, environment, direct default, type zero value. An environment value is
decoded like a wire token; a malformed value is reported against the field.

### 3.5 Optional flags

```zig
pub fn Optional(comptime flag: anytype) ?@TypeOf(flag)
```

Both `dap.Optional(dap.Flag(T){...})` and `@as(?dap.Flag(T), dap.Flag(T){...})` declare an optional flag. The `View`
field type is `?T` and is `null` when the flag is absent. Rules:

- An optional flag must not declare a default.
- Validation is skipped when the value is `null`.
- Optional arguments are rejected.
- An optional flag is not allowed inside an `Alt` branch.

### 3.6 `Group(def, name)`

```zig
pub fn Group(comptime def: anytype, comptime name: String) type
```

Groups flags or arguments under a help heading. A group is purely declarative: its members are flattened into `View` in
declaration order, and the `View` has no field for the group itself. Members must be flags or arguments; nested groups
and type-valued members are compile errors.

A group name may repeat. Groups with the same name share one help section. A group name may also equal an `Alt` branch
tag.

### 3.7 `Alt(.{...})` and `VariantNamed`

```zig
pub fn Alt(comptime def: anytype) type
pub fn VariantNamed(comptime name: String, comptime branch: anytype) type
```

An `Alt` declares mutually exclusive sets of flags. Each anonymous-struct field is a branch. The branch tag is the field
name, or the name given to `VariantNamed`. The generated `View` field is `?Union`; the union has one member per branch
tag, and each payload holds the branch's flag values.

```zig
.source = dap.Alt(.{
    .file = .{
        .file = dap.Flag([]const u8){ .short = "f" },
    },
    .remote = dap.VariantNamed("net", .{
        .url = dap.Flag([]const u8){},
    }),
}),

// union tags: .file, .net
```

Constraints:

- Branches may contain only flags.
- Branch flags must not declare defaults.
- Optional flags are not allowed inside branches.
- Branch tags must be unique within the `Alt` (including a repeated `VariantNamed` name).
- Flag names must be unique across branches and the parent level.

Behavior: the union is `null` until a branch member appears, then it holds that branch's payload. Activating two
branches is a `ConflictingAlt` failure. All members of the active branch are required. Each branch contributes a help
heading, and the usage line renders one alternation clause such as `(--file=FILE | --url=URL)`.

### 3.8 `Command(meta, def)` and `CommandMeta`

```zig
pub const CommandMeta = struct {
    name: ?String = null,    // wire name; defaults to the field name
    synonym: ?String = null, // alternative wire spelling
    help: String = "",
    i18n: ?String = null,    // translation key for `help`
};

pub fn Command(comptime meta: CommandMeta, comptime def: anytype) type
```

A command is a sibling field of the parent declaration. Its `def` is an ordinary declaration and may contain further
commands. The parent `View` stores the parsed sub-`View` under the declaration field name prefixed with `_` (`_build`),
set to `null` unless the command appears.

A positional token equal to a command's primary name or synonym terminates the current level and parses the remaining
tokens at the subcommand level, starting again at index 0. `--` disables both flag recognition and command handoff.

Reach the active command through `command`:

```zig
if (CLI.command(cli)) |cmd| switch (cmd) {
    .build => |b| try build(b.jobs),
    .serve => |s| try serve(s.addr),
} else {
    try CLI.usage(cli);
}
```

Union tags are the plain declaration field names, independent of wire names. `command` is infallible, allocation-free,
and returns at most one active branch. It accepts a `View` from any level of the same tree, so dispatch nests:

```zig
if (CLI.command(cli)) |cmd| switch (cmd) {
    .body => |b| if (CLI.command(b)) |sub| switch (sub) {
        .left => |l| runLeft(l),
        .right => |r| runRight(r),
    } else {
        try CLI.usage(b);
    },
} else {
    try CLI.usage(cli);
}
```

A leaf `View` (a level with no commands) is not a valid argument. Flags typed after a command are first resolved at the
current level, then against each ancestor level, nearest first. This makes `app serve --verbose` assign the root flag
into the root `View`.

Flag long names and short aliases must be unique across the entire command tree, not only within a level, because deep
help merges ancestor flags. Command names and synonyms must be unique within a level. Mixing commands with positional
arguments in one declaration is rejected.

### 3.9 Composition

`dap.Compose` transforms declaration values before `generate`. Both functions are comptime-only, allocation-free, and
return declarations with an inferred type.

```zig
pub fn shift(comptime decl: anytype, comptime prefix: []const u8) Shifted
pub fn concat(comptime left: anytype, comptime right: anytype) Concat
```

`shift(decl, prefix)` sets every flag's long name to `prefix ++ (old_long orelse field_name)` and clears every short
name, at every level: top-level flags, optional flags, group members, `Alt` branches (including `VariantNamed`) and
command bodies. Field names, group names, branch tags, command names and synonyms, arguments, defaults, validations,
help/i18n strings and completion predictors are preserved. An implicit long name becomes explicit. An empty declaration
remains empty.

`prefix` is comptime and concatenated without a separator. It must be non-empty and must be a valid long name,
optionally followed by one trailing `-`. A valid long name is non-empty, contains no byte `<= 0x20`, `0x7f` or `=`, and
has no leading or trailing `-`. The outer call's prefix appears first: `shift(shift(decl, "a-"), "b-")` yields
`--b-a-...`.

`concat(left, right)` places `left`'s fields before `right`'s. Fields pair by declaration field name:

- A name declared by one side is copied unchanged.
- A name declared by both sides is legal only as two `Group`s with equal names (members concatenated left then right) or
  two `Alt`s (branches concatenated left then right). The result keeps the left position and the shared name.
- Any other same-named pair is a compile error.

Cross-input collisions are compile errors for: a flat field name (group and `Alt` members included), a positional
argument display name, a long or short flag anywhere in either command tree, a top-level command name or synonym, and
an i18n key (so a duplicate surfaces at the `concat` call site instead of later in `generate`). Help literals are not
compared and may repeat. Inside a merged `Alt`, duplicate branch field names and duplicate branch tags are also errors.
Diagnostics name the class and the dotted declaration-field path on each side, for example
`flag name '--port' clash in declarations (left serve.port, right net.p)` or
`i18n key 'key_port' clash in declarations (left port, right host)`.

`concat(.{}, decl)` and `concat(decl, .{})` are identities. Nested `concat` is associative in declaration order.
Structural validity (commands mixed with arguments, a defaulted argument that stops being last, `Alt` restrictions)
remains the responsibility of `generate`.

---

## 4. Value types

### 4.1 Builtin types

The following value types are supported without extra code:

- `bool`: accepts `true`, `false`, `1`, `0`; never consumes an explicit value when used as a flag.
- All integer types (`u8`...`u64`, `i8`...`i64`, `usize`, `isize`): base 10.
- All float types (`f16`...`f128`, including `f80`): `std.fmt.parseFloat`.
- `dap.String`, an alias of `[]const u8`.
- Any type produced by `Enumeration` (§4.3).

### 4.2 Custom value types

Any other type is usable if it provides at least these methods:

```zig
pub fn decode(allocator: std.mem.Allocator, data: []const u8) dap.DecodeError!Self
pub fn encode(self: *Self, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8
pub fn deinit(self: *Self, allocator: std.mem.Allocator) void
```

- `decode` is a static constructor. It returns a fully built value and owns any internal allocations.
- `InvalidWire` means the token has the wrong shape; `InvalidValue` means the shape is valid but the value is rejected.
- `DecodeError` includes `std.mem.Allocator.Error`, so `decode` may allocate.
- `encode` returns an allocator-owned wire spelling that the caller frees.
- `deinit` releases the value's internals and must not call `allocator.destroy(self)`.

A missing method, or an unsupported type, is a compile error.

### 4.3 `Enumeration(T)` and `Enum`

```zig
pub const Enum = struct {
    name: ?String = null, // wire name; defaults to the field name
    help: ?struct {
        text: String,         // default-locale literal
        i18n: ?String = null, // optional translation key
    } = null,
};

pub fn Enumeration(comptime branches: anytype) type
```

```zig
const Mode = dap.Enumeration(.{
    .fast = dap.Enum{},
    .slow = dap.Enum{ .name = "glacial" },
    .json = dap.Enum{ .help = .{ .text = "Machine-readable JSON output.", .i18n = "mode_json" } },
});
```

The result is a value type with:

- `view`: a Zig enum with one tag per branch, defaulting to the first branch;
- `EnumView`: the enum type;
- `names`: the wire names in declaration order;
- `helps`: the declared branch texts in declaration order, as `[n]?String`;
- `help_i18n`: the declared branch translation keys in declaration order, as `[n]?String`;
- `decode`, `encode`, `deinit` satisfying §4.2.

`helps[i]` is `null` only when the branch declares no help; an explicitly empty text stays a non-null empty slice.
`help_i18n[i]` is `null` when the branch has no help or its help has no key, and an empty key means "no translation".
A key cannot exist without the `help` pair that owns it. Help rendering resolves a keyed branch through the selected
locale (`error.UnknownTranslationKey` when missing) and interpolates the possible values into the page as §8.3
describes. Completion renders a keyed branch through the generation-time locale, with `helps[i] orelse ""` as the
literal fallback; an empty key means no translation.

A branch must be a struct with `name` and `help` fields, and a non-null `help` must carry a `text` field; otherwise it
is `@compileError("enumeration branch '...' must be a dap.Enum")`. Duplicate wire names are a compile error. An empty
`Enumeration` is degenerate: it has `decode`/`encode`/`deinit` only, no `names`/`helps`/`help_i18n`, and rejects every
token; consumers detect the arrays with `@hasDecl`. Completion predictors are not allowed on `Enumeration` targets.

Use it like any other value type:

```zig
.mode = dap.Flag(Mode){
    .default = dap.Default(Mode){ .direct = Mode{ .view = .slow } },
},
// --mode glacial -> cli.mode.view == Mode.EnumView.slow
```

---

## 5. `View`

`CLI.View` is a generated struct with the following layout, in order:

1. `builtin_help: bool`, the injected `-h, --help` flag (always first);
2. one field per declared flag or argument, in declaration order, with group members flattened; optional flags are `?T`;
3. a zero-sized `__command<rank>` tag that makes every level's `View` nominally distinct;
4. a hidden `__i18n: *const dap.I18n.Locale`, the locale `parse` selected;
5. a hidden `__no_color: bool`, whether `NO_COLOR` was set and non-empty in `init.minimal.environ` (§8.1);
6. one `?Union` field per `Alt`, in declaration order (tags are branch tags per §3.7);
7. one `?Sub.View` field per command, in declaration order, named `_<field>`.

`View` types of different command levels are distinct even when their layouts match. A `View` contains only fields;
methods are exposed on the namespace, not on the value.

`CLI.deinit(&view, allocator)` releases every owned field: string slices, custom value internals, the active `Alt`
payload and every active command sub-`View`. It requires a `var` view and is valid once, on a `View` returned by a
successful parse. It is not idempotent.

---

## 6. Parse contract

```zig
pub fn parse(
    allocator: std.mem.Allocator,      // caller-owned working allocator
    init: std.process.Init,            // by value, borrowed for the call
    i18n: ?*const dap.I18n.Builder,    // null selects the declaration default
    args: []const []const u8,          // payload, without the binary name
    diag: ?*dap.Diag,                  // may be null
) ParseError!View
```

- `args` is pure payload. Parsing starts at index 0 and no token is skipped, at any command level. Pass the argument
  list with the binary name removed.
- `init` supplies the process handles. Locale selection and `NO_COLOR` read only `init.minimal.environ`;
  `init.environ_map` is never consulted. The same `init` is forwarded to the hidden completion route, which renders and
  exits before it expires (§10.4).
- `i18n` selects the locale before scanning: `null` uses the generated default locale, a builder uses
  `i18n.locale(init.minimal.environ)`. The selection reads `LC_ALL`, `LC_MESSAGES`, `LANG` from that environment in that
  order and is installed into the root `View` and every active sub-`View`, so help and failure output are localized
  automatically.
- On success, `parse` returns a fully decoded and validated `View`.
- On a usage, decode or validation failure, `parse` prints diagnostics and the context-sensitive help page to stderr and
  calls `std.process.exit(1)`.
- On `-h` or `--help`, it prints help to stdout and calls `std.process.exit(0)`. `--help=false` does not trigger help.
- Because failure exits, the declared error union is not observed in ordinary use; `try CLI.parse(...)` is the intended
  call.

Parsing rules:

- `--` terminates flag and command recognition; every remaining token is a positional literal.
- A non-boolean flag without a value is a `MissingValue` failure.
- An unmatched long or short token is an `UnknownFlag` failure. It is first retried against ancestor levels.
- A positional token with no free slot is a `TooManyArguments` failure.
- A required flag or argument that never appears is a `MissingRequired` failure.
- An absent optional value resolves to `null`; an absent value with a default resolves by §3.4. Absent booleans resolve
  to `false`.

---

## 7. Errors and diagnostics

```zig
pub const DecodeError = error{ InvalidWire, InvalidValue };

pub const ParseError = error{
    UnknownFlag,
    MissingValue,
    MissingRequired,
    TooManyArguments,
    ConflictingAlt,
    InvalidWtf8,
} || std.mem.Allocator.Error || DecodeError;

pub const HelpError = std.mem.Allocator.Error || dap.I18n.Error;
```

`HelpError` is the error set of `helpText`, `usage`, `HelpData.renderCompact` and custom renderers. Its i18n members are
`error.UnknownTranslationKey` (a locale lacks a required key) and `error.UnsupportedLocale` (the lower-level lookup
primitive; `Builder.locale` cannot return it).

`Diag` records details of the most recent failed parse:

| Field     | Meaning                                                                    | Ownership                      |
| --------- | -------------------------------------------------------------------------- | ------------------------------ |
| `field`   | Declaration field that failed.                                             | Borrowed.                      |
| `token`   | Offending argv token.                                                      | Borrowed.                      |
| `message` | Validation message.                                                        | Allocated; free with `deinit`. |
| `unknown` | Closest candidate when the token looked like a misspelled flag or command. | Borrowed.                      |

```zig
var diag: dap.Diag = .{};
defer diag.deinit(allocator); // frees only `message`
```

`unknown` is a `?Suggest`, a union of `flag` and `cmd` variants. Each `SuggestValid` carries `name`, optional `short`,
`kind`, Levenshtein `distance` and a `reason` (`edit` or `prefix`). Its strings are borrowed from the declaration and
remain valid after `parse`. Diagnostics include the suggestion automatically.

`parse` never returns a usage error to the caller; it reports and exits. Applications that need different error handling
should drive their own UI from `helpData`, because the internal parse pipeline is not public.

---

## 8. Help

### 8.1 Rendering API

```zig
const text = try CLI.helpText(allocator);
defer allocator.free(text);

var data = try CLI.helpData(allocator);
defer data.deinit(allocator);
const same = try data.renderCompact(&CLI.default_locale, allocator);
defer allocator.free(same);
```

`helpText` builds a `HelpData` and renders it with `App.help_renderer.style` and `CLI.default_locale`; it returns
`HelpError!String` because a declared key may be missing. `helpData` exposes the model for custom renderers, man pages or
documentation and takes the locale at render time. Nothing help-related runs unless one of these functions is called.

`CLI.usage(view)` prints the context-sensitive help page for a `View` of any level, using the same renderer and the locale
carried by that `View`. It is the usual response when a command level was entered but no subcommand was selected.

`helpText` and `CLI.usage(view)` return and print the *rendered* page, so the configured highlight is applied only when it
can be seen. The decision is per destination and capability-only:

| Path                            | Destination        | Capability source                        |
| ------------------------------- | ------------------ | ---------------------------------------- |
| `-h`/`--help` intercept         | stdout             | `std.Io.File.supportsAnsiEscapeCodes`    |
| `CLI.usage(view)`               | stdout             | same, plus `view.__no_color`             |
| failure page                    | stderr             | same, plus `NO_COLOR`                    |
| standalone diagnostics          | stderr             | same, for the suggested spelling         |
| `helpText`                      | none (returns it)  | stdout                                   |

A destination that is not a terminal, a terminal without ANSI support (`TERM=dumb` included), or an environment with a
set, non-empty `NO_COLOR` downgrades every scheme, custom ones included, to `.flat`; `NO_COLOR=` (empty) does nothing. The
fallback is byte-identical to a declaration configured `.flat`: column widths are measured before escapes are added, so
only the codes disappear. `NO_COLOR` is read from `init.minimal.environ`, the only environment `parse` consults, and
stored in the `View`
(`__no_color`), so `usage` and the help intercept agree with it after the parse; the force-color variables
(`FORCE_COLOR`, `CLICOLOR_FORCE`) and `CLICOLOR` are ignored. dap never calls `enableAnsiEscapeCodes`, so it never mutates
console mode; an old Windows console without virtual terminal processing therefore stays plain. A custom *renderer*
receives the downgraded `HelpData` but may emit its own escapes, which are outside dap's control.

### 8.2 `App` renderer configuration

```zig
pub const HelpRendererStyle = union(enum) {
    compact: void, // default kong-style two-column layout
    custom: *const fn (
        self: *const HelpData,
        locale: *const I18n.Locale,
        allocator: std.mem.Allocator,
    ) HelpError!String,
};

pub const HelpRendererHighlight = union(enum) {
    flat: void,  // no escape codes
    bold: void,  // default
    color: void,
    custom: HelpHighlight,
};
```

A custom renderer receives the filled `HelpData`, the selected locale and the allocator, and returns a caller-owned
string. Resolve keyed rows through `locale.require(key)`; a missing key is an error, never a literal fallback.

### 8.3 Compact layout

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

- Short and long names occupy aligned sub-columns. A value placeholder is `=DEFAULT` when a direct default exists,
  `=$NAME` when only an environment default exists, and `=NAME` in upper case otherwise.
- A default that renders empty is quoted as `""`, both in the `=DEFAULT` placeholder and in the default clause.
- Flag groups are ordered by name, with the ungrouped bucket first.
- Required flags render as `--name` or `--name=VALUE`; optional booleans render as `[--flag]`; positional arguments
  render as `<arg>` or `[<arg>]` when they have any default, including an environment-only one.
- Optional (`?T`) flags are listed in the flags section but omitted from the usage header.
- In the usage header, a value-taking flag with a default is omitted from the required list, a bool flag with any
  default is omitted entirely, and `[flags]` appears when at least one flag has a default.
- `Alt` flags are not listed individually in the usage line. Each `Alt` renders one alternation clause, for example
  `(--file=FILE | --url=URL)`.

An enumeration's branches are rendered after the help text. Let `left_size` be the widest left column in the section
among rows narrower than 30; the right column starts at `H = 2 + left_size + 4` and is constant within a section. The
value block never participates in `left_size`, and all widths are measured before highlight codes are inserted. A row
with a left column of 30 or more moves its right content to a continuation line at the same `H`.

Single-line form: at most four branches, none declaring help.

```text
  -f, --format=json      Output format. Possible values: json, yaml, toml.
```

- The clause starts after the help text, or directly at `H` with no leading space when the help text is empty. A row
  whose left column overflowed starts the clause on the continuation line.
- The label is `meta.possible_values`, the names follow in declaration order joined by `, `, and the clause ends with
  exactly one ASCII `.`. Zero branches print no clause.

Column form: more than four branches, or at least one declaring help (the declaration decides, never a translation).

```text
  -f, --format=json      Output format.
                           Possible values:
                             json  - Machine-readable JSON output.
                             yaml  - Human-readable YAML config.
```

- The label line is `meta.possible_values` with trailing whitespace trimmed, at `H + 2`; each branch is a line at
  `H + 4`. The names column is as wide as the longest name in the block, including branches that print no help.
- A branch whose declared help resolves to empty, whether unkeyed or translated, prints only its name, with no `- ` and
  no trailing spaces. There is no trailing period anywhere in the block.
- When the row's help text is empty and it has no default clause, the row ends at the left column and the block
  follows.
- `Group` members and `Alt` branch flags take the same path. An empty `Enumeration` prints nothing.

An argument adds a default clause in either form: the `meta.default_value` label, the value highlighted `flags_value`,
and one ASCII `.`. For an enumeration argument the order is default then values, separated by one space, for example
`Output mode. Default value: json. Possible values: json, yaml.` A non-enumeration argument prints only the default
clause; an argument without a default prints only its values. An environment-only default renders as `$NAME`.

Branch names in the values clause and the value in the default clause are highlighted `flags_value`; labels,
separators, padding and branch help stay `plain`.

### 8.4 Context-sensitive help

A help request anywhere in the active chain is honored, including one placed before the commands (`app -h svc build`).
Help describes the deepest command entered. The usage header reconstructs the command path (`Usage: app svc build ...`),
positional arguments and subcommand listing come from that deepest level, and flags are merged from every ancestor
level. Groups with the same name merge into one section, `Alt` usage clauses accumulate root first, and the injected
`-h, --help` appears exactly once. Root-level help is unchanged.

The same merged page is used on failure: entering `app svc build` and then failing shows the `build` page with the
merged ancestor flags and the diagnostics. A failure before any handoff shows the root page.

```text
$ app command-2 info -h
Usage: app command-2 info --required=REQUIRED [--flag] [flags]

Info about command 2.

Flags:
  -h, --help                 Show context-sensitive help.
      --required=REQUIRED    Mandatory value.
      --value=               Command 2 value.
      --details=             Info details.
```

### 8.5 `HelpData`

`HelpData` is plain data. Every string and slice is allocated with the caller's allocator and released by
`HelpData.deinit`, except borrowed highlight codes and `error_text`.

```zig
pub const HelpData = struct {
    pub const Value = struct {
        name: String,  // wire name
        help: ?String, // declared literal, or null
        i18n: ?String, // declared key, or null
    };
    pub const Flag = struct {
        name: String,
        short: ?String,
        help: String,
        default: ?String,
        takes_value: bool,
        alt: ?String = null,
        alt_branch: ?String = null,
        optional: bool = false,
        i18n: ?String = null, // translation key for `help`
        values: []Value = &.{},
    };
    pub const Argument = struct {
        name: String,
        help: String,
        default: ?String,
        i18n: ?String = null, // translation key for `help`
        values: []Value = &.{},
    };
    pub const FlagGroup = struct { name: ?String, flags: []Flag };
    pub const ArgGroup = struct { name: ?String, args: []Argument };
    pub const CommandInfo = struct {
        name: String,
        help: String,
        i18n: ?String = null, // translation key for `help`
    };
    pub const Usage = struct { branches: [][]Flag };

    name: String,                       // usage path
    info: String,                       // app description
    info_i18n: ?String = null,          // translation key for `info`
    flag_groups: []FlagGroup,
    arg_groups: []ArgGroup,
    usage_alts: []Usage,
    commands: []CommandInfo,
    error_text: ?String = null,
    highlight: HelpRendererHighlight = .{ .flat = {} },

    pub fn deinit(self: *HelpData, allocator: std.mem.Allocator) void;
    pub fn renderCompact(
        self: *const HelpData,
        locale: *const I18n.Locale,
        allocator: std.mem.Allocator,
    ) HelpError!String;
};
```

`usage_alts` holds one entry per `Alt`; its flag slices reference entries owned by `flag_groups`. `deinit` frees only
the outer arrays for those slices. `error_text` is borrowed and is used by the failure page. The `i18n` keys and
`info_i18n` are duplicated by `helpData`, owned by `HelpData` and freed by `deinit`; `renderCompact` resolves them
through the passed locale.

`values` holds an enumeration's branches in declaration order. It is empty for non-enumeration types and for an empty
`Enumeration`. `Value.help == null` means the branch declared no help, while `help = ""` means help was declared with
an empty literal; the renderer keeps that distinction to pick the layout before consulting a locale. The slice, its
names, and its non-null `help`/`i18n` strings are duplicated by `helpData` and freed by `deinit`. Because `usage_alts`
shallow copies `Flag`, its `values` slices stay owned by `flag_groups` and are never freed through `usage_alts`.

### 8.6 Highlighting

`App.help_renderer.highlight` selects `flat`, `bold` (default), `color`, or `custom` with a `HelpHighlight` scheme.
`HelpHighlight` provides codes for the usage header (`error_msg`, `app_name`, `required_flags`, `optionals`,
`arguments`) and for section rendered text (`groups`, `args`, `flags` name and value). Column widths are measured before
escape codes are emitted, so highlighting never disturbs alignment.

The selection is a recommendation, not an order: §8.1's capability rule downgrades it to `flat` whenever the destination
cannot display it, and `NO_COLOR` downgrades it unconditionally. `helpData` always carries the declared scheme; only the
emission paths substitute the effective one.

---

## 9. Internationalization

Declarations name translations with `.i18n` keys; a caller registers comptime locales and hands the builder to `parse`.
The selected locale travels in the `View`, so `usage` renders post-parse without the environment. A non-null key that the
selected locale lacks is `error.UnknownTranslationKey`, never an English fallback. A declaration that registers nothing
renders its own `.help` literals byte-for-byte.

```zig
pub const I18n = struct {
    pub const Error = error{ UnknownTranslationKey, UnsupportedLocale };
    pub const Entry = struct { key: String, value: String };

    pub const Locale = struct {
        pub const Meta = struct {
            usage: String, flags: String, cmds: String, args: String,
            cmds_placeholder: String, flags_placeholder: String,
            possible_values: String, default_value: String, // both end with a space
        };
        pub const Builtin = struct {
            help: String,
        };
        pub const Diag = struct {
            field_invalid: String, token_invalid: String, message: String, did_you_mean: String,
        };

        meta: Meta,
        builtin: Builtin,
        diag: Diag,
        user: Map(String),

        pub fn default(comptime entries: []const Entry) Locale;
        pub fn withUser(comptime self: Locale, comptime user_map: anytype) Locale;
        pub fn get(self: Locale, key: String) ?String;
        pub fn has(self: Locale, key: String) bool;
        pub fn require(self: Locale, key: String) Error!String;
    };

    pub const Builder = struct {
        locales: Map(Locale),
        required: []const String,

        pub fn init(comptime default: Locale, comptime required: []const String) Builder;
        pub inline fn append(comptime self: Builder, comptime lang: String, comptime locale: Locale) Builder;
        pub fn locale(self: *const Builder, environ: std.process.Environ) *const Locale;
    };

    pub fn normalizeTag(raw: String) String;
    pub fn tagFromEnviron(environ: std.process.Environ) ?String;

    pub const ru: Locale;
    pub const zh: Locale;
    pub const es: Locale;
    pub const it: Locale;
    pub const fr: Locale;
    pub const de: Locale;
    pub const ko: Locale;
    pub const ja: Locale;
};
```

- The default locale is generated per declaration from the `.help` literals plus the private English structural
  template. There is no `I18n.en`, no `I18n.Translations` type, no `build` step and no fallback locale. `helpText`
  always renders this default; `usage(view)` uses the selected locale carried by the view.
- `Locale.withUser(user_map)` replaces the user map with `builtin_help` (seeded from the template) plus the struct's
  fields. Field names are validated as keys; a builtin collision is a compile error. Extra fields are allowed, so one
  template can serve several declarations.
- `Builder.init(default, required)` seeds `""` with the default locale and copies the required keys.
  `Builder.append(lang, locale)` is comptime and rejects an empty or duplicate tag, an invalid locale (`Locale.validate`
  checks non-empty `Meta`/`Builtin` and the exact `Diag` placeholder counts) and any missing required key, all at the
  call site. A runtime `var` builder cannot satisfy these checks.
- `normalizeTag` strips an `@modifier`, keeps the language for a `UTF-8`/`utf8` suffix (any case), and yields `""` for
  another encoding, `C` or `POSIX`. `tagFromEnviron` reads the first non-empty of `LC_ALL`, `LC_MESSAGES`, `LANG`;
  non-POSIX targets return `null`. Lookup tries the exact tag (`ru_RU`), the language (`ru`), then `""`.
- The prefilled set is `ru`, `zh`, `es`, `it`, `fr`, `de`, `ko`, `ja`. Tags are the caller's choice: the Japanese
  template is `ja` but is normally appended as `ja_JP` (and optionally also `ja`). `Meta` supplies headings,
  placeholders and the `possible_values`/`default_value` labels (each includes its own trailing space), `Builtin` only
  the `builtin_help` pair, and `Diag` the four diagnostic templates (one `{s}` for `field_invalid`, `token_invalid`
  and `message`; two for `did_you_mean`). `Locale.validate` requires every `Meta` and `Builtin` field to be non-empty,
  so a user-written locale literal must supply the two new `Meta` fields.
- `CLI.i18n()` seeds the builder with `CLI.default_locale` under `""` and `CLI.i18n_keys`; it is a compile error on a
  non-root namespace. `CLI.default_locale` remains available for callers that intentionally render the declaration
  default.

```zig
const i18n = CLI.i18n()
    .append("ru", dap.I18n.ru.withUser(.{
        .greeting = "Привет",
    }));

var cli = try CLI.parse(allocator, init, &i18n, args, &diag);
```

---

## 10. Completion

Static descriptions are localized at generation time. Every entry with an `i18n` key renders through the locale passed
to `CLI.completion`: flag help (`Spec.i18n`), command help including the injected `--help` (`CommandMeta.i18n`), and
enumeration value help (`Enumeration.help_i18n`). Entries without a key, and branches whose key is empty, keep their
declared literal. Bash prints no descriptions, so its script never changes; the hidden route and predictor output stay
untouched because their text arrives at runtime.

### 10.1 Handle

`CLI.completion(allocator, app_name, shell, locale)` builds a `CLI.Completion` handle for the whole command tree.
`locale` is `*const dap.I18n.Locale`, normally `i18n.locale(init.minimal.environ)` from the same builder handed to
`parse`, or
`&CLI.default_locale`. Construction is infallible and does no work: it takes no `View`, does not parse, does not read
the environment, performs no I/O and performs no validation. The pointer is stored, so every render uses the same
locale.

```zig
var completion = CLI.completion(allocator, "my-app", .zsh, i18n.locale(init.minimal.environ));
const script = try completion.text();
defer allocator.free(script);
```

| Member                 | Description                                                                |
| ---------------------- | -------------------------------------------------------------------------- |
| `dap.Completion.Shell` | `.bash`, `.zsh` or `.fish`.                                                |
| `text()`               | Render a caller-owned deterministic script with exactly one trailing `\n`. |
| `show(io)`             | Render and write to stdout.                                                |
| `install(io, environ)` | Render and write to the shell's discovery directory.                       |

`text` and `install` can fail with `std.mem.Allocator.Error` or `error.InvalidAppName`. `install` also returns
`error.InstallUnsupported` when no home directory can be determined.

Install locations are:

| Shell | Path                                               |
| ----- | -------------------------------------------------- |
| bash  | `$XDG_DATA_HOME/bash-completion/completions/<app>` |
| zsh   | `$XDG_DATA_HOME/zsh/site-functions/_<app>`         |
| fish  | `$XDG_CONFIG_HOME/fish/completions/<app>.fish`     |

Missing XDG variables fall back to `$HOME/.local/share` and `$HOME/.config`; parent directories are created.

`app_name` is the name the script registers. It is not `App.name`, which is a usage path. It must be non-empty ASCII,
must not start with `-`, must not contain `/`, whitespace or control bytes, and may use only `A-Za-z0-9._+-`. An invalid
name fails with `error.InvalidAppName` before any allocation. Only the root namespace may call `completion`; a
subcommand call is a compile error.

The registration spelling is `app_name` verbatim. Shell identifiers are sanitized separately: every byte outside
`[A-Za-z0-9_]` becomes `_`. The zsh autoload file name must match its function, `_<ident>`.

The script is a snapshot of the declaration. Regenerate it when flags or commands change. Sanitization is not injective,
so two CLIs can collide in one bash or fish session.

### 10.2 Predictors

`Flag(T)` and `Argument(T)` accept `completion: ?dap.Completion.Predictor = null`.

| Constructor                                                      | Offered values                               |
| ---------------------------------------------------------------- | -------------------------------------------- |
| `null`                                                           | The shell's own file completion.             |
| `dap.Completion.fs(.{})`                                         | Same as `null`; native mapping.              |
| `dap.Completion.fs(.{ .wildcard = "*.toml", .root = "config" })` | Matching files, listed by the binary.        |
| `dap.Completion.disabled()`                                      | Nothing; suppresses the file fallback.       |
| `dap.Completion.launch(.{ "git", "ls-files", "$cur" })`          | Output of a literal command line.            |
| `dap.Completion.call("...")`                                     | Shell source inserted verbatim.              |
| `dap.Completion.custom(callback)`                                | Values produced by a callback in the binary. |

`FsOptions`:

```zig
pub const FsOptions = struct {
    pub const Type = enum { all, dir };
    wildcard: []const u8 = "*", // basename-only `*` and `?`
    type: Type = .all,
    root: ?[]const u8 = null,   // process-cwd relative
};
```

`fs` lists directories ending in `/`, lists dot entries only when the typed name starts with `.`, and emits values
relative to `root`. A missing directory yields no values. Only `wildcard = "*"` with no `root` maps to the shell; every
other `fs` combination runs the binary.

`launch` accepts a tuple, array or slice of strings. An element exactly equal to `$cur` expands the current word; the
current word is not appended otherwise. `call` takes one dialect-specific string and sees `cur` and the `line` words.
`custom` takes:

```zig
*const fn (
    allocator: std.mem.Allocator,
    init: std.process.Init,
    cur: []const u8,
    line: []const []const u8,
) anyerror![]const dap.Completion.Suggestion
```

`init` is the `Init` the application handed to `parse`, passed through unchanged. It is valid only for the duration of
the callback: the callback must not retain it or any process-scoped pointers derived from it. An unused parameter is
legal.

The callback owns its result: it allocates the slice, each `value` and each non-null `help` with the given allocator.
Static literals are invalid. The route frees a successful result; a failing callback must release its own partial
result.

A predictor is legal on plain and optional flags, group and `Alt` members, positional arguments, and targets with
defaults. It is a compile error on `bool` and `Enumeration` targets, including `.disabled`. A predictor replaces the
static values of its target. It runs on an empty positional word, never after `--`, and `--flag=value` strips the
`--flag=` prefix before matching and re-attaches it to every result.

### 10.3 Candidate selection

The script tracks the current command level and the number of completed positional words. With an empty current word it
shows one category, in order:

1. subcommands, when the level declares any;
2. enumeration values of the next unfilled positional slot, when that slot is an enumeration;
3. flags.

A non-empty prefix shows matching commands, matching flags, and values of the current positional slot. Enumeration
values are offered as declared; other argument types contribute only through predictors. Typing `-` or `--v` reaches
flags even while a positional is pending.

A long flag pairs with its short alias, and a command pairs with its synonym. zsh and fish merge a matching pair into
one row; the inserted spelling is the one that matched. bash keeps one plain candidate per spelling.

Ordering is: normal entries, then version-family entries, then help-family entries; inside a family entries with help
come before entries without help; ties are sorted by ASCII spelling. zsh renders an aligned table with descriptions,
both for static rows and for predictor results; the candidate column escapes a space as `\ ` and the control bytes as
`\t`, `\n` and `\r`, and a result with no descriptions at all degrades to plain candidates. fish emits
`candidate<TAB>description` and registers with `-k`, and bash uses `COMPREPLY` with the default file fallback.

### 10.4 Route contract

Predictors that run in the binary use a hidden route. The shell invokes the program with a reserved first argument,
followed by a binding index, the current value and the preceding words. `parse` recognizes this call before processing
any other argument and forwards its own `init` to the route; the route hands that same `init` to every predictor,
callback or non-native `fs` alike. The route renders its payload and exits before the `Init` expires, so a predictor
never sees it after the process would otherwise continue past `parse`. The route reads stdin/stdout through `init.io`;
help and diagnostics keep using `std.Options.debug_io`.

The application writes one candidate per line to stdout, either `value` or `value<TAB>help`, and exits:

- `0` on success, including zero candidates;
- `1` on predictor failure;
- `2` on route misuse.

Stdout is empty on non-zero exits. Diagnostics are written to stderr only when `_DAP_DIAGNOSTICS=1`. Because the route
runs at the start of `parse`, the application must perform no file, socket or network work before calling `parse`.

An example of a completion command:

```zig
const Shell = dap.Enumeration(.{
    .bash = dap.Enum{},
    .zsh = dap.Enum{},
    .fish = dap.Enum{},
});

const def = .{
    .completion = dap.Command(.{ .help = "Print a completion script." }, .{
        .shell = dap.Argument(Shell){},
    }),
};

if (CLI.command(cli)) |cmd| switch (cmd) {
    .completion => |c| {
        try CLI.completion(arena, "app", switch (c.shell.view) {
            .bash => .bash,
            .zsh => .zsh,
            .fish => .fish,
        }, &CLI.default_locale).show(init.io);
        return;
    },
    else => {},
};
```

---

## 11. Validation

Validators have the signature:

```zig
fn (std.mem.Allocator, T) std.mem.Allocator.Error!?String
```

They return `null` on success, an allocated message on failure, and may return `error.OutOfMemory`. Ready-made helpers:

```zig
dap.Validate.stringNotEmpty // non-empty dap.String
dap.Validate.intNotZero(u8) // non-zero integer, comptime factory
```

Validation runs on every value whether it came from argv, an environment variable or a direct default. It also runs over
the members of an active `Alt` branch. A failed validation reports `InvalidValue` with `diag.field` and `diag.message`.

---

## 12. Ownership

- `View` owns every string and custom value it stores. Strings from argv, the environment and direct defaults are
  duplicated with the allocator passed to `parse`.
- Release a successful `View` with `CLI.deinit(&view, allocator)`. It frees strings, calls custom `deinit` methods,
  releases the active `Alt` branch and recurses into active command sub-views. It is not idempotent.
- `CLI.deinit` is a namespace function. `view.deinit(...)` does not compile, and the receiver must be a `var`.
- An arena is the simplest lifetime. Explicit `CLI.deinit` matters when a general-purpose allocator is used.
- `Diag.deinit` frees only `message`; `field`, `token` and `unknown` are borrowed.
- `helpText`, `HelpData.renderCompact`, `HelpData.deinit`, `Completion.text` and `Completion.install` return or release
  caller-owned memory.
- `View.__i18n` is a pointer into comptime-static locale storage. It is never freed. `View.__no_color` is a plain
  `bool`.
- `HelpData` duplicates the i18n keys (`Flag.i18n`, `Argument.i18n`, `CommandInfo.i18n`, `info_i18n`) and frees them in
  `deinit`; `error_text` stays borrowed.

---

## 13. Compile-time constraints

The following are compile errors:

- A declaration field that is not a `Flag`, `Argument`, optional flag, `Group`, `Alt` or `Command`.
- A declaration field name beginning with `_`.
- Duplicate long names, duplicate short names or duplicate field names within a level.
- Duplicate flag names between a level and any of its ancestors. Sibling commands and unrelated subtrees may reuse a
  spelling; same-level duplicates are rejected separately.
- Duplicate command names or synonyms within a level; a command field name colliding with a flag or group member.
- Mixing commands and positional arguments in one declaration.
- A non-last argument with a default.
- A value type without `decode`/`encode`/`deinit`.
- A boolean flag with a direct default of `true`.
- An optional flag with a default, an optional argument, or an optional flag inside an `Alt` branch.
- An `Alt` with zero branches, duplicate tags, a non-flag member, a defaulted member, or an optional member.
- Declaring a field named `help` with `.long = "help"` (the builtin already owns it).
- A completion predictor on a `bool` or `Enumeration` target.
- An enumeration branch that is not `dap.Enum`-shaped (missing `name`/`help`, or a non-null `help` without `text`), or a
  duplicate enumeration wire name.
- An i18n key that is not `[_A-Za-z][_0-9A-Za-z]*`, repeats anywhere in the declaration tree (enumeration branch keys
  included), or equals `builtin_help`. Help literals are not identifiers and may repeat freely.
- A `Locale` or `withUser` map with an invalid key or a builtin collision; a malformed `Diag` template.
- `Builder.append` with an empty or duplicate locale tag, an invalid locale, or a missing required key.
- `Compose.shift` with an empty or malformed prefix.
- `Compose.concat` with a non-mergeable same-named pair, a cross-input name collision (i18n keys included), or
  duplicate branch names or tags inside a merged `Alt`.

---

## 14. Semantics summary

| Subject             | Rule                                                                                                         |
| ------------------- | ------------------------------------------------------------------------------------------------------------ |
| Input               | `args` is pure payload, no binary name, no skipped token.                                                    |
| Names               | Field names are wire names verbatim; dashes need `.long`; names cannot start with `_`.                       |
| Required            | Required iff no default. Booleans are always optional and default to `false`.                                |
| Precedence          | argv > environment > direct default > zero value.                                                            |
| Defaults            | Only the last argument may have one.                                                                         |
| Terminator          | `--` makes the rest literal and stops command handoff.                                                       |
| Commands            | A command token hands the remaining payload to that level. `command(view)` dispatches; tags are field names. |
| Flags across levels | A flag missing locally is retried on ancestors; names are unique along a chain; siblings may reuse.        |
| `Alt`               | At most one branch active; all members of the active branch are required.                                    |
| Optional flags      | `?T`, `null` when absent, no defaults, validation skipped when null.                                         |
| Help                | `-h`/`--help` anywhere bypasses checks, renders the deepest merged page and exits 0.                         |
| Localization        | `.i18n` keys resolve through the locale `parse` selected; `null` or no match uses the generated default.      |
| Failure             | Diagnostics plus the deepest merged help page on stderr, exit 1.                                             |
| Ownership           | `View` owns its data; release once with `CLI.deinit`.                                                        |
| Composition         | `shift` prefixes long names and drops shorts; `concat` appends fields, merging same-named groups and Alts.   |
| Compilation         | All names, types, defaults and collisions are checked at compile time.                                       |

---

## 15. Verification

```sh
zig build                  # compile the module and the example executable
zig build test             # unit tests for the core and composition
zig test src/dap.zig       # single-root test run
zig test src/compose.zig   # composition test run
zig test src/i18n.zig      # i18n data and locale selection
zig build completion-test  # opt-in shell integration tests
zig build run -- --help
LANG=ru_RU.UTF-8 zig build run -- --help   # localized example output
```

The example binary can also render a completion script:

```sh
zig build run -- --required 0 completion bash
```
