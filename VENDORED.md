# Vendored dependencies

Third-party packages that are copied into [`vendor/`](vendor/) instead of being
fetched by the Zig package manager. They live here because their upstream build
scripts target older Zig versions and do not work with the Zig 0.17 build system
this project uses.

Only external, third-party projects are listed here. Packages maintained by the
`mpy6a` authors are regular dependencies and are intentionally not vendored or
described in this file, with one exception: when the WAL implementation needs an
API extension that the published release does not have, the package is copied
into `vendor/` with that extension, so the tree builds offline and without a
pending upstream release. `zigring` and `blog` are in that state today; the
local changes are listed below and are meant to be dropped once the releases
carry them.

## verztable

- Upstream: <https://github.com/ThobiasKnudsen/verztable>
- Version: 0.1.0
- License: MIT (see [`vendor/verztable/LICENSE`](vendor/verztable/LICENSE))
- Local copy: [`vendor/verztable`](vendor/verztable)

A high-performance open-addressing hash map and set for Zig with SIMD-accelerated
metadata scanning, hash-fragment filtering and tombstone-free deletion. It backs
the session state tables, the active-session map and the deadline index.

Local changes: only the `verztable` module is built (upstream's benchmark
executable needs a C++ toolchain plus Abseil and Boost checkouts, and its
`bench_exe.linkLibC()` call does not compile against Zig 0.17). The source also
carries alignment fixes so the bucket allocation is freed with the same
alignment it was allocated with.

## bplustree

- Upstream: <https://github.com/dayvster/zig-bplus-tree>
- Version: 0.0.0, commit [`e9ac649`](https://github.com/dayvster/zig-bplus-tree/commit/e9ac649f8e329cae502cb06f126331818e39c714)
- License: MIT (see [`vendor/bplustree/LICENSE`](vendor/bplustree/LICENSE))
- Local copy: [`vendor/bplustree`](vendor/bplustree)

A generic, self-balancing B+ tree with ordered iteration over linked leaves. It
is used for ordered indexes such as retry deadlines.

Local changes: upstream's build script targets Zig 0.16 and attempts to build
`examples/` and `tests/` files that are not part of the published package. The
vendored [`build.zig`](vendor/bplustree/build.zig) only exports the
`bplustree` module and is compatible with Zig 0.17.

## Updating

Replace the directory contents with the new upstream sources, keep the local
build script changes described above, then adjust the version and commit
references in this file. Both packages are declared as `path` dependencies in
[`build.zig.zon`](build.zig.zon), so no hash needs to be updated.

## zigring

- Upstream: <https://github.com/sirkon/zigring>
- Version: 0.0.14, commit [`6d42fd4`](https://github.com/sirkon/zigring/commit/6d42fd41658c9d83735a131828e0337b805e6fa2)
- License: see [`vendor/zigring/LICENSE`](vendor/zigring/LICENSE)
- Local copy: [`vendor/zigring`](vendor/zigring)

Adds the two gaps the WAL needs (designs/wal-impl.md §8.1):

- the write family (`Ring.pushWrite`, `Ring.pushWriteOffset`,
  `Ring.pushWritev`, `BatchSQ.pushWrite`, `BatchSQ.pushWriteOffset`,
  `StreamSQ.pushWrite`, `StreamSQ.pushWriteOffset`) takes an `rw_flags: u32`
  parameter that lands in `sqe.rw_flags`; the WAL passes
  `std.os.linux.RWF.DSYNC` for PMEM-mode flushes and `0` elsewhere;
- `StreamSQ.hasRoom()` reports whether the stream window has room for one more
  operation, which is the WAL's flush pre-check.

## blog

- Upstream: <https://github.com/sirkon/blog>
- Version: 0.0.17, commit [`df15139`](https://github.com/sirkon/blog/commit/df15139c786ae1b7654e9001d9d65846ffb0f600)
- License: see [`vendor/blog/LICENSE`](vendor/blog/LICENSE)
- Local copy: [`vendor/blog`](vendor/blog)

`src/crc32c.zig` gains `combinedCrc32C(prev: u32, data: []const u8) u32`, the
seeded fold behind the WAL's running block CRC (designs/wal-impl.md §8.2). It
shares the same convention as `hardwareCrc32C` (`CRC-32/ISCSI`, initial value
and final XOR `0xFFFFFFFF`) and composes: `combinedCrc32C(hardwareCrc32C(A), B)
== hardwareCrc32C(A ++ B)`. The assembly paths seed their register from `prev`;
the fallback uses its own reflected table because `std.hash.crc` has no seeded
initializer.
