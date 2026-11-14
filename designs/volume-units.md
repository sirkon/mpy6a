# Volume units

Promoted from `.mailbox/volume-units/3.md`; the mailbox directory keeps the thread's full history.

This document fixes which configuration values and command-line values in mpy6a are byte or byte-derived quantities, which unit base each one uses, and which numeric knobs deliberately stay plain counts. The unit type comes from `zunit`; the integration into `build.zig` and `build.zig.zon` already exists.

`zunit`'s base is both the working unit and the precision constraint: a value must be a whole number of base units. A coarser base makes the canonical document prettier but rejects values that are legal in a finer base. The base choices below are therefore about the smallest legal value, not about cosmetics.

## 1. The shared aliases

`src/config.zig` exposes three volume aliases and three constructors:

```zig
pub const Bytes = zunit.Volume(.b).Siggy;
pub const Kib = zunit.Volume(.kib).Siggy;
pub const Mib = zunit.Volume(.mib).Siggy;

pub inline fn bytes(n: u128) Bytes {
    return Bytes.fromBase(n) catch unreachable;
}

pub inline fn kib(n: u128) Kib {
    return Kib.fromBase(n) catch unreachable;
}

pub inline fn mib(n: u128) Mib {
    return Mib.fromBase(n) catch unreachable;
}
```

`Bytes` keeps its name because the logging fields and their `config.bytes(...)` fixtures spell it. Durations are already converted to `zunit.Duration(.secs).Siggy` and are outside this document's scope.

## 2. The fields

| config key                      | type    | base   | default               | validation                                                        |
| ------------------------------- | ------- | ------ | --------------------- | ----------------------------------------------------------------- |
| `wal.plain.lba`                 | `Kib`   | `.kib` | `kib(4)` = `4KiB`     | `[1KiB, 1MiB]`, power of two, divides 1 MiB exactly               |
| `wal.pmem.lba`                  | `Kib`   | `.kib` | `kib(4)` = `4KiB`     | same                                                              |
| `snapshots.size_barrier`        | `Mib`   | `.mib` | `mib(256)` = `256MiB` | `>= 1MiB`                                                         |
| `logging.pool_frame_size`       | `Bytes` | `.b`   | `bytes(512)`          | none at parse; `blog.BufferPool.init` requires `>=512` and a power of two |
| `logging.pool_capacity`         | `u32`   | —      | `1024`                | none at parse; `blog.BufferPool.init` requires a non-zero power of two |

The WAL LBA is the buffer size and the flush granularity. The base is `.kib` because NVMe is the only reasonable target and larger frames are preferable even on HDDs for flush performance; the previous 512-byte floor is no longer accepted. A bare number in the document is a whole number of kibibytes, and the canonical spelling is `4KiB`.

The snapshot size barrier is a pair-size bar, so `.mib` renders the default as `256MiB`. The validation floor is 1 MiB. Values below it were useful only in tests and are no longer expressible.

The logging frame size stays on the byte base because the blog pool accepts a 512-byte frame and a coarser base would reject it. The default drops from 2048 to 512 bytes because the large majority of log events fit under one such frame. The pool keeps an explicit frame count: `logging.pool_capacity` is how many frames the pool has, and `logging.pool_frame_size` is how large each frame is. The default pool is therefore 1024 frames of 512 bytes, 512 KiB in total.

A byte budget (`logging.pool_bytes`) is deliberately not added. The frame count is the source of truth; deriving a count from a budget would give the same resource two names without making the ring contract clearer.

## 3. Narrowing at the consumer

`zunit` values are stored as a `u128` raw byte count, so consumers that need a `u32` narrow explicitly. The pattern is the same for both WAL and logging: widen to `u64` first, then cast to `u32`; overflow or an invalid cast collapses to zero, and the consumer's own validation rejects zero.

```zig
pub fn lba(self: Wal) u32 {
    const value = switch (self) {
        .plain => |p| p.lba,
        .pmem => |p| p.lba,
    };
    const widened = value.value64() catch return 0;
    return std.math.cast(u32, widened) orelse 0;
}

pub fn frameSize(self: Logging) u32 {
    const widened = self.pool_frame_size.value64() catch return 0;
    return std.math.cast(u32, widened) orelse 0;
}
```

The blog contract is not copied into the config parser. `BufferPool.init` remains the only place that checks the frame size is a power of two of at least 512 bytes and the frame count is a non-zero power of two. A derived or narrowed value that cannot be formed becomes zero, and `init` rejects it with `error.InvalidConfig`.

## 4. The default document

```text
logging = { method = pretty { dark } pool_capacity = 1024 pool_frame_size = 512 }
wal = plain { dir = "wal" buffers = 32 hosts = 1 lba = 4KiB }
snapshots = { interval = 60s size_barrier = 256MiB slots = 8 registry_keep = 8 }
```

The sample `mpy6a.cfg` uses the same spellings.

## 5. Counts that stay counts

The WAL battery is sized by `wal.buffers` and `wal.lba`, not by a byte budget. The ring depth is not merely a resource knob: the four-buffer floor is a correctness rule for the snapshot bring-tail, and the writer indexes its ring by ordinal modulo `buffers`. No `wal.battery_bytes` key and no battery-bytes accessor exists.

Every other numeric config leaf is a count, not a volume: `fronts`, `indexes`, `elephants`, `host_index`, `queue_depth`, `cross_task_slots`, `accept_backlog`, `sqpoll_threads`, `index_inbox_capacity`, `ring_slots_capacity`, `wal.buffers`, `wal.hosts`, `snapshots.slots` and `registry_keep`. Their constraints are powers of two, slot bounds or thread counts, not byte arithmetic.

Internal constants stay untyped. `wal_block` and `wal.BLOCK` are the fixed 1 MiB WAL block; `CRC_LEN`, `HEADER` and `BLOCK_CONTENT` are structural; `max_config_bytes` is the config manager's read cap. If one is ever exposed as a user-facing knob, `wal_block` is naturally a mebibyte volume and `max_config_bytes` a byte volume.

## 6. Command line

The running CLI stays as it is: `run` has only `-c/--config`, and the other commands are `show-dev-config` and `version`. No config-override flags are added to `run`.

The deferred `mpy6a pmem-migrate lba` command types its `--old-lba` as `zunit.Volume(.b).Dap` and makes it required. The byte base is deliberate: migration must read a legacy 512-byte LBA even though a new config can no longer express one. There is no `--new-lba`; the new LBA is the updated config's `wal.lba`.

```zig
const Lba = zunit.Volume(.b).Dap;

.old_lba = dap.Flag(Lba){
    .help = "Previous device LBA, e.g. 512 or 4KiB.",
},
```

The command itself is not implemented by this design.

## 7. Test fixtures

- Config-boundary WAL tests move their LBA literals with the config: `config.bytes(512)` becomes `config.kib(1)`, `config.bytes(4096)` becomes `config.kib(4)`, and the matching `areaStride`, `Area.init`, `walkVerdict` and `openBattery` geometry literals move from 512 to 1024.
- Pure area-math tests that never construct a `config.Wal` keep 512 and continue to cover the smallest internal geometry.
- The index snapshot fixtures that force a procedure use `mib(1)`. Tests that need the tick to dispatch write more than 1 MiB of WAL extent; the skip-guard test needs no extra data because its guards return before the barrier check. The two end-to-end procedure tests carry large record payloads so their state and session counts are unchanged.
- Validation tests use `0KiB`, `3KiB` and `2048KiB` for the floor, the power-of-two rule and the upper bound. A bare `lba = 512` is asserted to be a parse error, because 512 is not a whole kibibyte.
