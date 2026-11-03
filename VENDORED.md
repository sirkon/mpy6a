# Vendored dependencies

Third-party packages that are copied into [`vendor/`](vendor/) instead of being
fetched by the Zig package manager. They live here because their upstream build
scripts target older Zig versions and do not work with the Zig 0.17 build system
this project uses.

Only external, third-party projects are listed here. Packages maintained by the
`mpy6a` authors are regular dependencies and are intentionally not vendored or
described in this file.

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
