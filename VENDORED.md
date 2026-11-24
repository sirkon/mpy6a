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

## Updating

Replace the directory contents with the new upstream sources, keep the local
build script changes described above, then adjust the version and commit
references in this file. Both packages are declared as `path` dependencies in
[`build.zig.zon`](build.zig.zon), so no hash needs to be updated.

