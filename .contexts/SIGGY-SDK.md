# siggy SDK

siggy turns a Zig type into a parser for a brace-and-key configuration
format. There is no schema language and no code generation step: `siggy.parser(T)`
returns a comptime-specialized type that lexes, parses, and decodes into `T`,
and encodes `T` back to text.

- Grammar: `GRAMMAR.md`
- Mapping contract: `schema.md` and `README.md`
- Internal layout and invariants: `AGENTS.md`
- Toolchain: Zig 0.17.0 (`build.zig.zon`)

## Import

`build.zig` exposes one module named `siggy` whose root is `src/root.zig`:

```zig
const siggy = @import("siggy");
```

## Public surface

`src/root.zig` exports exactly one callable, `parser`, plus data types:

```zig
pub fn parser(comptime T: type) type   // src/root.zig:29

pub const ParsingError;  // src/diagnostic.zig:6
pub const FileIoError;   // src/diagnostic.zig:37
pub const Diagnostic;    // src/diagnostic.zig:40
pub const Diagnostics;   // src/diagnostic.zig:48
pub const Printer;       // src/diagnostic.zig:56
pub const Options;       // src/options.zig:3
pub const AstNode;       // src/siggy/ast.zig:43, an alias of Value
pub const Token;
pub const TokenKind;
pub const higgy = struct { pub const Location = ... };  // no public render
```

Everything the parser returns is produced by `parser(T)`:

```zig
pub fn init(
    self: *Self,
    source_allocator: std.mem.Allocator, // ephemeral scratch
    dst_allocator: std.mem.Allocator,    // owns the decoded value
    printer: ?Printer,                   // null = higgy output on stderr
) !void

pub fn parse(self: *Self, text: []const u8) ParsingError!T
pub fn parse_file(self: *Self, path: []const u8) (ParsingError || FileIoError)!T
pub fn stringify(self: *Self, value: T) []const u8
```

The returned type also has public fields:

| Field | Meaning |
|-------|---------|
| `source_allocator` | scratch allocator, used during `parse`/`parse_file` |
| `value_allocator` | allocator that owns the decoded value |
| `printer` | `?Printer`, `null` means render with `higgy` to stderr |
| `options` | `Options`; `init` resets it to defaults |
| `diagnostic` | `?Diagnostic` for the last failed call, `null` after a success |

`Options` (`src/options.zig`):

| Field | Default | Enforced by |
|-------|---------|-------------|
| `max_literal_len` | 4096 | lexer (`LiteralTooLong`) |
| `max_depth` | 64 | deserializer, counts nested blocks (root document is depth 1) |
| `max_list_len` | 1 << 20 | deserializer (`MaxListLenExceeded`) |
| `max_file_size` | 16 MiB | `parse_file` |

## Quickstart

```zig
const std = @import("std");
const siggy = @import("siggy");

const Range = struct { start: u32, end: u32 };

const MaskItem = union(enum) {
    literal: u32,   // `0`, `1`, ... (variant name `literal` is special)
    range: Range,   // `range { start = 10 end = 12 }`
};

const CpuConfig = struct {
    index_threads_mask: []const MaskItem,
    pin_threads_mask: []const MaskItem = &.{},
};

const Parser = siggy.parser(CpuConfig);

pub fn main() !void {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug.deinit();
    const gpa = debug.allocator();

    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    var values = std.heap.ArenaAllocator.init(gpa);
    defer values.deinit();

    var p: Parser = undefined;
    try p.init(scratch.allocator(), values.allocator(), null);
    p.options.max_depth = 32; // must come after init

    const text =
        \\# space-separated mask of leaves and tagged blocks
        \\index_threads_mask = { 0 1 range { start = 10 end = 12 } }
        \\pin_threads_mask = { 2, 3, }   # comma-separated, trailing comma ok
    ;
    const config = p.parse(text) catch |err| {
        // p.diagnostic is set; the default printer already wrote to stderr.
        std.debug.print("config error: {s}\n", .{@errorName(err)});
        return err;
    };
    std.debug.print("{d} pinned threads\n", .{config.pin_threads_mask.len});

    const round_trip = p.stringify(config); // arena-owned text
    const again = try p.parse(round_trip);
    _ = again;
}
```

Reading a file:

```zig
const config = try p.parse_file("examples/cpu.cfg");
```

## What types are supported

`assertSupported(T)` (`src/siggy/support.zig:21`) walks `T` at comptime and
raises `@compileError("unsupported type for siggy: ...")` for anything outside
this table:

| Zig type | Config form | Notes |
|----------|-------------|-------|
| `bool` | `true` / `false` | lowercase only |
| `uN`, `iN`, `usize`, `isize` | `42`, `-7`, `0x1f`, `0b1010`, `1_000` | overflow is `BadNumber` |
| `fN` | `1.5`, `1e3`, `nan`, `inf` | |
| `enum E` | variant name | exact, case-sensitive |
| `[]const u8` | `"quoted"` | bare literal is `ExpectedQuoted` |
| `?T` | absent field or `{ }` | implicit `null` default |
| `struct S` | document block | unknown/duplicate keys are errors |
| `[]T` (any slice) | list block | mutable `[]u8` also works |
| `union(enum) U` | `tag { ... }` or a bare literal | untagged unions rejected |
| `std.AutoArrayHashMapUnmanaged(K, V)` | document block | any structurally matching map; `K` must be `bool`, int, enum, or `[]const u8` |
| `T` with `decode` + `encode` | custom | both must exist to be recognized |
| `void` | none | compiles in `assertSupported`, fails at decode with `UnsupportedShape` |

Pointers other than slices, tuples, untagged unions, and maps with
non-literal keys are compile errors.

The **root type** must be a document: a struct, a map, a custom type, or an
optional of one of those. `parser(u32)`, `parser([]T)`, and `parser(union)`
compile, but every `parse` returns `UnsupportedShape` because the top-level
text always parses as a document.

## Mapping cheatsheet

| Config text | Target | Result |
|-------------|--------|--------|
| `k = 10` | `k: u32` | `10` |
| `k = "10"` | `k: u32` | `UnsupportedShape` |
| `k = text` | `k: []const u8` | `ExpectedQuoted` |
| `k = "text"` | `k: []const u8` | decoded bytes, copied to `value_allocator` |
| `k = { a = 1 }` | `k: struct` | document |
| `k = { 1 2 }` / `{ 1, 2, }` | `k: []u32` | list; separator mode fixed by the first separator |
| `k = { }` | `k: []u32` | empty slice |
| `k = { }` | `k: ?T` | `null`, checked before decoding `T` |
| `k = { }` | `k: struct` | all fields defaulted or optional, else `MissingField` |
| `k = { }` | `k: map` | `EmptyNotAllowed` |
| `k = { }` | `k: union(enum)` | `EmptyNotAllowed` |
| `k = tag { ... }` | `k: union(enum)` | variant named `tag` |
| `k = tag` | `k: union(enum)` | `void` variant `tag`, else non-void variant `literal` |
| `k = tag { 5 }` | `k: union(enum)` with leaf payload | unwraps the single item |
| `k = { a = 1 b = 2 }` | `k: map` | open dictionary, every assign is an entry |

## Allocators

The schema layer takes two plain allocators and builds its own scratch arenas
inside `parse` (`src/siggy/schema.zig:97`):

- `source_allocator` is **ephemeral**. Tokens, AST nodes, decoded QUOTED
  payloads, copies of literals, and diagnostic messages live here. siggy frees
  the scratch arenas before `parse`/`parse_file` return.
- `value_allocator` is **persistent**. It owns the returned `T`, including every
  `[]const u8`, slice, map allocation, and custom value, plus the persisted
  diagnostic message.

Consequences:

- The input `text` only needs to live for the duration of the call; siggy does
  not copy it into the result except where the mapping says so.
- After a successful parse, nothing in `T` points into `text` or into the
  `source_allocator`'s memory. `src/tests.zig` "value survives resetting the
  source allocator" guards this.
- `stringify` also allocates in `value_allocator`; the caller never frees the
  result.

## Diagnostics and printing

```zig
pub const Diagnostic = struct {
    code: ParsingError = error.Custom,
    offset: usize = 0,        // byte offset into the source
    message: []const u8 = "",
};

pub const Diagnostics = struct {
    diagnostic: Diagnostic,
    source: []const u8,       // borrowed during the print only
    path: []const u8,         // "" for parse, the path for parse_file
};

pub const Printer = *const fn (allocator: std.mem.Allocator, diag: *Diagnostics) anyerror!void;
```

`null` printer means the built-in `higgy` renderer writes to stderr:

```
error[UnknownField]: examples/cpu.cfg:3:9: unknown field 'foo' in ram.CpuConfig
   3 | index_threads_mask = { foo }
     |                       ^^^
```

Supply a printer in `init` to capture errors yourself:

```zig
fn silentPrinter(allocator: std.mem.Allocator, diag: *siggy.Diagnostics) anyerror!void {
    _ = allocator;
    _ = diag;
}

var p: siggy.parser(Config) = undefined;
try p.init(scratch.allocator(), values.allocator(), silentPrinter);
_ = p.parse("b = 1") catch |err| {
    const d = p.diagnostic.?;      // .code == err, .offset, .message
    std.debug.print("line offset {d}: {s}\n", .{ d.offset, d.message });
    return err;
};
```

Contract:

- The message passed to a printer is scratch memory and is valid only while
  the printer runs. Do not store `*Diagnostics` or its slices.
- After the call, `p.diagnostic` holds a copy of `code`, `offset`, and
  `message` allocated in `value_allocator`. It is cleared at the start of every
  call and stays `null` on success.
- Printer errors are ignored; the parse error is never lost.
- `higgy` is intentionally not callable from user code (`root.higgy` exposes
  only `Location`). To render yourself, build the text from `p.diagnostic` and
  the source you already have.

## Custom leaf types

Any struct that declares both members below is decoded as a leaf and encoded
with `encode` (`src/siggy/support.zig:119`):

```zig
const CoresMask = struct {
    cores: []const u16,

    pub fn decode(
        self: *CoresMask,
        source_arena: std.mem.Allocator, // scratch: diagnostics, temporaries
        value_arena: std.mem.Allocator,  // persistent: fill self with this
        node: siggy.AstNode,
        diag: *siggy.Diagnostic,
    ) anyerror!void { ... }

    pub fn encode(
        self: CoresMask,                 // `*const Self` is also accepted
        allocator: std.mem.Allocator,
    ) anyerror![]const u8 { ... }
};
```

Rules:

- siggy allocates `Self` in `value_allocator` and calls `decode` on that
  pointer. Do not allocate `Self` inside `decode`.
- `node` is one of `.literal`, `.quoted`, `.block`, `.tagged`. A custom field
  does **not** get automatic leaf unwrapping: `k = tag { 5 }` arrives as
  `.tagged`.
- On a semantic error, fill `diag.code`, `diag.offset`, and `diag.message`
  (message in scratch memory) and return an error. The returned error is
  classified into `ParsingError`; anything unrecognized becomes
  `error.Custom`. If `diag.message` is empty, siggy uses `@errorName(err)`.
- Never keep `source_arena` memory in the decoded value; it is freed before
  `parse` returns.
- `encode` returns arena-owned bytes; the caller does not free them.

See `src/test.zig` (`CoresMask`, includes ranges and normalization) and
`src/tests.zig` (`Duration`) for complete implementations.

## Encoding (`stringify`)

The encoder is the mirror of the decoder (`src/siggy/schema.zig:603`):

- Struct fields are written as `name = value`, one per line, including fields
  that equal their default.
- `null` optional fields are omitted entirely.
- Empty slices, empty maps, and empty structs are written as `{ }`.
- Lists use space-separated items inside braces; nested structs are written as
  document blocks.
- Strings are quoted and only `"` and `\` are escaped.
- A union variant with a `void` payload is written as a bare tag; a non-void
  variant named `literal` is written bare; other payloads use `tag { ... }`,
  and leaf payloads use `tag { value }`.
- On an encoding failure `stringify` returns `""` and sets `p.diagnostic`; it
  does not call the printer.

## Known gotchas

Behaviors below were verified against the current tree with Zig 0.17.0.

### Data

- **`false` fails to decode.** `decodeLeaf` tests `text == "true"` and errors
  otherwise (`src/siggy/schema.zig:347`), so `flag = false` returns
  `BadNumber`. Since `stringify` writes `false`, a struct containing `false`
  does not round-trip. Use a custom decoder or avoid `false` until fixed.
- **Strings always need quotes.** `name = my-service` is `ExpectedQuoted`.
  Only `"my-service"` works.
- **Keys are never quoted.** `"a" = 1` is `UnexpectedToken`; map keys and field
  names are LITERAL tokens only.
- **Map duplicates are silent.** Unlike structs, `decodeMap` does not detect
  duplicates: `m = { 1 = 1 1 = 2 }` yields the last value.
- **String map keys are emitted bare.** `stringify` writes `[]const u8` keys
  without quotes, so a key containing a space produces text that will not parse
  back (`m = { my host = 1 }`).
- **A comma outside braces is a document error.** `a = 1,` or
  `k = { 1 },` at the top level is `CommaInDocument`. Commas only exist inside
  list blocks.
- **An empty list block cannot start with a comma**: `k = { , 1 }` is
  `EmptyList`.
- **Separator mode is sticky.** `{ 1 2, 3 }` and `{ 1, 2 3 }` are both
  `MixedListSeparators`; the first separator decides for the whole list.
- **`{ }` means different things per target type.** Empty list for `[]T`,
  `null` for `?T`, defaults for a struct, and `EmptyNotAllowed` for maps,
  unions, and leaves. The parser itself never interprets it.
- **`10..12` is a plain literal.** Interpreting ranges is the job of a custom
  type (see `CoresMask`), not of the decoder.
- **Void variants need an empty block when tagged.** `c = red` works, but
  `c = red { 1 }` is `UnsupportedShape`. `c = red { }` also works.
- **A tagged leaf payload needs exactly one item.** `tag { 1 }` is unwrapped;
  `tag { 1 2 }` and `tag { }` are passed through and usually fail.
- **A non-void `literal` variant of type `[]const u8` cannot be written
  tagged or bare.** `v = bare` is `ExpectedQuoted`, and `v = "x"` reaches
  `decodeUnion` and is `UnsupportedShape`. Prefer a separate variant name.
- **`stringify` does not escape newlines or other control characters.** A
  string containing `\n` produces multi-line output that fails with
  `NewlineInQuote` when parsed again.
- **An empty map field does not round-trip.** `stringify` writes `m = { }`,
  but decoding that as a map is `EmptyNotAllowed`. Make the map field optional
  (`?map`) if empty is a valid state.
- **A non-void union named `literal` is encoded bare**, so an optional
  `literal` variant holding a string produces text that hits the same
  `UnsupportedShape` problem as above.
- **Root-level shapes.** Only documents decode at the top level, so
  `parser([]u32)` or `parser(u32)` always returns `UnsupportedShape`.
- **Empty input is valid** when every field has a default or is optional.
  A missing required field is reported at offset `0`, which renders as
  line 1, column 1.

### API and lifecycle

- **`init` resets `options`.** Set limits after `init`; assigning before is
  overwritten.
- **`parse_file` reports I/O errors as `error.Custom`.** The returned error is
  the real I/O error (`FileNotFound`, `AccessDenied`, ...), but
  `p.diagnostic.code` is `error.Custom` and `p.diagnostic.message` is the error
  name. Do not switch on `p.diagnostic.code` to detect I/O failures.
- **`diagnostic` is per parser and per call.** It is cleared at the start of
  `parse`, `parse_file`, and `stringify`, so read it immediately after a
  failure. Do not share one parser instance across threads.
- **Do not use a file-scoped parser without initializing it.** `parser(T)` is a
  plain struct; `init` assigns every field, including `options = .{}` and
  `diagnostic = null`.
- **Printer messages are scratch memory.** They may dangle after `parse`
  returns; the persisted `p.diagnostic.message` is the copy you may keep.
- **`stringify` returns `""` on failure** and does not print. Check
  `p.diagnostic` when the result is empty (an empty struct also legitimately
  encodes to `""`, so check the diagnostic too).
- **Every `stringify` call allocates again** in `value_allocator` (typically an
  arena). In a long-running process, use a fixed buffer or reset the arena.
- **`parse` clones the input it keeps.** The low-level parser copies literals
  into its scratch arena, so the result never borrows `text`; you may free
  `text` (or reset the scratch arena) right after `parse`.
- **Custom types need both `decode` and `encode`.** With only `decode` the
  struct is treated as an ordinary schema and decoded field by field, which is
  almost never what you want.
- **`void` fields compile but fail at decode** (`UnsupportedShape`). Use
  `?T` or a `union(enum)` with a `void` variant for a present/absent flag.

### Environment

- Test through `src/root.zig`; `zig test src/siggy/schema.zig` fails with
  "import of file outside module path". Run `zig build test` or
  `zig test src/root.zig` from the repository root.
- Adding a new test file requires listing it in the `test` block of
  `src/root.zig`, otherwise it never runs.
- `root.zig` must keep exactly one public function, `parser`; the
  "root: parser is the only public function" test enforces this. Export types,
  not helpers.
