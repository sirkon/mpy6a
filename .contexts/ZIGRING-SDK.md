# AGENTS.md

Public API usage guide for `zigring`. For the internals, build commands and
maintenance conventions, see `AGENTS.md`.

## What it is

`zigring` is a small, libc-backed Zig wrapper around Linux `io_uring`. It is a **library**, not an executable. Consumers
add it as a package and import the
single public module:

```zig
const zigring = @import("zigring");
const Ring = zigring.Ring;
```

Requirements and constraints:

- **Zig 0.16.0** (see `minimum_zig_version` in `build.zig.zon`).
- **Linux only**, and **libc is mandatory**: the build sets `link_libc = true`
  because the threading wrappers call real `pthread_*` symbols. Do not remove it.
- The ring uses **SQPOLL**, so a dedicated kernel thread polls the submission
  queue and submissions usually cost no syscall.

In your `build.zig`, the dependency must keep `link_libc`:

```zig
const dep = b.dependency("zigring", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zigring", dep.module("zigring"));
exe.root_module.link_libc = true;
```

## Public surface at a glance

Re-exported from `src/root.zig` (`file:line` is where the alias lives):

| Symbol                                           | Kind              | Purpose                                                   |
|--------------------------------------------------|-------------------|-----------------------------------------------------------|
| `Ring`                                           | struct            | The io_uring itself: submit, complete, park.              |
| `Factory`                                        | struct            | Thread-safe ring allocator over bounded kernel pollers.   |
| `CQE`                                            | extern struct     | A completion; byte-for-byte layout of `io_uring_cqe`.     |
| `TaskFlags`                                      | packed struct(u8) | Per-SQE flags (`Link`, `Drain`, `SkipSuccess`, ...).      |
| `BufferSizeClass`                                | enum(u16)         | Size classes for registered / provided buffers.           |
| `BatchSQ`                                        | struct            | Batched submission window (`Ring.batchedSQ`).             |
| `BatchCQ`                                        | struct            | Batched completion window (`Ring.batchedCQ`).             |
| `ReorderBuffer`                                  | struct            | Restores in-order delivery from out-of-order completions. |
| `Slots(T)`                                       | generic           | Dense `u64` index allocator for trivially copyable `T`.   |
| `BufferSlots`                                    | struct            | Dense index allocator over fixed-size byte buffers.       |
| `Mutex`, `CondVar`, `Thread`                     | structs           | Thin libc `pthread_*` wrappers.                           |
| `nowNs`, `monotonicNs`                           | functions         | vDSO time reads (`u64` nanoseconds).                      |
| `createTCPServerSocket`, `createTCPClientSocket` | functions         | `SOCK_CLOEXEC` TCP socket helpers.                        |
| `pageSize`                                       | const             | `4096`.                                                   |
| `fireAndForgetTaskIdx`                           | const             | `maxInt(u64)`; task id for fire-and-forget ops.           |

Anything reachable only through the private files (`ProvidedBufferPool`,
`pushBind`, `pushConnect`) is an implementation detail and not part of the
public contract.

## The core loop

Completion-driven flow: call a `push*` method to arm an operation, then drain
completions with `popCQE` (hot path) and fall back to `park` (cold path, one
syscall) only when it returns null. Check the ring every iteration before
sleeping.

```zig
const std = @import("std");
const linux = std.os.linux;
const zigring = @import("zigring");
const Ring = zigring.Ring;

fn waitOne(ring: *Ring) zigring.CQE {
    while (true) {
        if (ring.popCQE()) |cqe| return cqe;
        ring.park();
    }
}

pub fn main() !void {
    var ring = try Ring.init(64, null); // queueDepth must be a power of two
    defer ring.deinit();

    // Arm an operation. `taskIdx` is opaque user data echoed back in the CQE.
    const taskIdx: u64 = 1;
    try ring.pushListen(sockFd, taskIdx, 128, .{});

    const cqe = waitOne(&ring);
    if (cqe.taskIdx() == taskIdx and cqe.res < 0) {
        return error.OperationFailed;
    }
}
```

## `Ring`: signatures and gotchas

```zig
pub fn init(queueDepth: u32, attachFd: ?posix.fd_t) !Self;
pub fn deinit(self: *Self) void;
```

- `init` requires a **power-of-two** `queueDepth`, else
  `error.ZigRingRequiresDepthPowOf2`; any setup failure is
  `error.ZigRingSetupFailed`.
- `attachFd`, when non-null, makes this ring share another ring's kernel poller (`IORING_SETUP_ATTACH_WQ`). The
  referenced ring must outlive this one.
- Call `deinit` to unmap the three regions, close the fd and tear down every
  provided buffer pool. `deinit` does **not** free memory returned by
  `registerBuffers`; that mapping is caller-owned (see below).
- **A `Ring` is not thread-safe.** Use one ring per submitting thread; the
  `Factory` is the thread-safe way to hand rings out.

### Submitting (`push*`)

Every `push*` returns an error union; `push*` on a full ring returns
`error.RingFull`. All buffers, paths, `timespec`s and sockaddrs handed to a
`push*` are read by the kernel **asynchronously**: they must stay valid and
unchanged until the matching completion is consumed.

| Signature                                                                | Operation              | Notes                                      |
|--------------------------------------------------------------------------|------------------------|--------------------------------------------|
| `pushWrite(targetFd, taskIdx, dataPtr, len, flags)`                      | `WRITE`                | Short writes possible; check `res`.        |
| `pushWritev(targetFd, taskIdx, iovecs, flags)`                           | `WRITEV`               | Gathers `iovecs`; short writes possible.   |
| `pushRead(targetFd, taskIdx, dst, flags)`                                | `READ`                 | Short reads possible; check `res`.         |
| `pushReadv(targetFd, taskIdx, iovecs, flags)`                            | `READV`                | Scatters into `iovecs`; short reads possible. |
| `pushSend(targetFd, taskIdx, dataPtr, len, flags)`                       | `SEND`                 | Copied send.                               |
| `pushRecv(targetFd, taskIdx, buf, flags)`                                | `RECV`                 | Caller buffer.                             |
| `pushSendZC(targetFd, taskIdx, dataPtr, len, bufIndex, msgFlags, flags)` | `SEND_ZC`              | Two CQEs; needs `registerBuffers`.         |
| `pushReadZC(targetFd, taskIdx, size, flags)`                             | `READ` + buffer select | Needs a registered pool.                   |
| `pushRecvZC(targetFd, taskIdx, size, flags)`                             | `RECV` + buffer select | Needs a registered pool.                   |
| `pushRecvMultishotZC(targetFd, taskIdx, size, flags)`                    | multishot `RECV`       | One per fd; keeps emitting CQEs.           |
| `pushAcceptMultishot(listenFd, taskIdx, flags)`                          | multishot `ACCEPT`     | One per fd; keeps emitting CQEs.           |
| `pushAccept(listenFd, taskIdx, flags)`                                   | `ACCEPT`               | One-shot; `res` is a new fd.               |
| `pushOpenDir(taskIdx, baseDirFd, subPath, flags)`                        | `OPENAT` `O_PATH`      | `subPath` is NUL-terminated.               |
| `pushOpenFile(taskIdx, dirFd, fileName, opts, flags)`                    | `OPENAT`               | `O_CLOEXEC` forced; `opts` is `linux.O`.   |
| `pushClose(taskIdx, targetFd, flags)`                                    | `CLOSE`                | Do not use `targetFd` after pushing.       |
| `pushRename(taskIdx, baseDirFd, oldName, newName, flags)`                | `RENAMEAT`             | Both names NUL-terminated.                 |
| `pushListen(socketFd, taskIdx, backlog, flags)`                          | `LISTEN`               | Socket must be bound.                      |
| `pushBindIp4(fd, user_data, ip_str, port, flags)`                        | `BIND`                 | `ip_str` parsed for you, e.g. `"0.0.0.0"`. |
| `pushConnectIp4(fd, user_data, ip_str, port, flags)`                     | `CONNECT`              | `ip_str` parsed for you.                   |
| `pushBindIp6(fd, user_data, ip_str, port, flags)`                        | `BIND`                 | e.g. `"::1"`, `"::"`.                      |
| `pushConnectIp6(fd, user_data, ip_str, port, flags)`                     | `CONNECT`              | e.g. `"::1"`.                              |
| `pushMsgRing(targetRing, taskIdx, msgResult, flags)`                     | `MSG_RING`             | Wakes another ring; no local CQE.          |
| `pushMsgRingFd(targetRingFd, taskIdx, msgResult, flags)`                 | `MSG_RING`             | Same, but takes the target ring fd.        |
| `pushTimeout(taskIdx, timespecPtr, flags)`                               | `TIMEOUT`              | Standalone timer.                          |
| `pushTimeoutForOp(timespecPtr, taskIdx, flags)`                          | `LINK_TIMEOUT`         | Must share a batch with its op.            |

Gotchas:

- **Multishot ops**: while `CQE.hasMore()` is set the operation stays armed and
  keeps producing CQEs; the final CQE clears it (on error or cancel). Only one
  multishot receive per fd (a second fails with `-EBUSY`).
- **`pushSendZC`** additionally requires buffers registered with
  `registerBuffers`; `bufIndex` is the index into that registration.
- **`pushTimeout`** reports expiry as success (`IORING_TIMEOUT_ETIME_SUCCESS`),
  so `res == 0`, not `-ETIME`.
- **`pushTimeoutForOp`** guards the operation submitted immediately before it.
  Push both in the *same* `batchedSQ` batch, otherwise the kernel rejects the
  SQE with `-EINVAL`. See "Linked timeout" below.
- **`pushMsgRing`/`pushMsgRingFd`** never produce a local completion
  (`SkipSuccess`); the target ring sees a CQE whose `res` is `msgResult` and
  whose `taskIdx` is this call's `taskIdx`.
- Some operations are offloaded to io-wq internally (`pushOpenDir`,
  `pushOpenFile`, `pushClose`, `pushRename` use `IOSQE_ASYNC`), which keeps
  SQPOLL from sleeping on blocking work.

### Completing

```zig
pub fn popCQE(self: *Self) ?CQE;      // null when the CQ is empty
pub fn park(self: *Self) void;        // blocking wait for >=1 event
pub fn batchedCQ(self: *Self) ?BatchCQ; // null when there is nothing to drain
```

- `popCQE` advances the CQ head, freeing the slot for the kernel. Leaving
  completions unread eventually stalls the CQ.
- Hot path order: `popCQE` first, `park` only when it returned null. `park`
  costs a syscall. It retries `EINTR` internally; any other error panics.
- `park` is safe with an empty SQ: it requests events and wakes a parked SQPOLL
  thread without submitting anything.

### `CQE` methods

```zig
pub inline fn taskIdx(self: CQE) u64;   // user_data, identifies the op
pub inline fn result(self: CQE) usize;  // res bit-cast to usize
pub inline fn errno(self: CQE) linux.E; // res interpreted as errno
pub inline fn hasBuffer(self: CQE) bool; // provided buffer selected
pub inline fn bid(self: CQE) u16;        // provided buffer id
pub inline fn hasMore(self: CQE) bool;    // multishot still armed
pub inline fn hasNotif(self: CQE) bool;   // SEND_ZC buffer is reusable
```

A negative `res` is a negated errno; compare with `linux.E` values. `hasNotif`
is the **second** CQE of a `SEND_ZC`.

## Provided buffers (kernel buffer selection)

Register a pool per size class, then use the `*ZC` buffer-select operations.
The kernel picks a buffer and reports it; return it exactly once when done.

```zig
try ring.regiterSizeClassReceiveBuffer(.net, 256); // entries = power of two
try ring.pushRecvZC(sockFd, 7, .net, .{});

const cqe = waitOne(&ring);
if (cqe.hasBuffer()) {
const buf = ring.buffer(.net, cqe.bid()) orelse unreachable;
const n = cqe.result();
consume(buf[0..n]);
ring.releaseBuffer(.net, cqe.bid()); // exactly once, or the pool drains
}
```

- `regiterSizeClassReceiveBuffer(sizeClass, entries)`: `entries` must be a power
  of two; at most one pool per size class, a second call returns
  `error.BufferOfSizeAlreadyInitialized`.
- Buffer-select ops (`pushReadZC`, `pushRecvZC`, `pushRecvMultishotZC`) return
  `error.BufferPoolNotInitialized` if the class was never registered.
- Every completion with `hasBuffer()` carries a borrowed `bid()` that must be
  `releaseBuffer`ed exactly once. Forget it and the pool drains, after which
  multishot receives start failing with `-ENOBUFS`. There is no automatic
  refill.
- `ring.buffer(sizeClass, bid)` returns a borrowed slice valid until the buffer
  is released; do not free it. Only the first `cqe.result()` bytes hold data.
- The pool is owned and freed by the ring itself; do not free it.

**Note the spelling:** the method is `regiterSizeClassReceiveBuffer` (missing
`s`). It is load-bearing public API, do not rename it.

## Zero-copy send (`SEND_ZC`)

```zig
const mem = try ring.registerBuffers(.tiny, 4); // caller owns this mmap
defer posix.munmap(mem); // NOT ring.deinit()

const bufIndex: u16 = 1;
const off = @as(usize, bufIndex) * BufferSizeClass.tiny.size() + 16;
@memcpy(mem[off .. off + payload.len], payload);
try ring.pushSendZC(fd, 10, mem.ptr + off, payload.len, bufIndex, 0, .{});
```

- `registerBuffers(sizeClass, entries)` mmaps `entries * size` bytes (huge
  pages preferred, regular-page fallback) and registers them as io_uring fixed
  buffers. The returned slice is a raw mmap **owned by the caller**: release it
  with `posix.munmap`, not `deinit`. The kernel pins the pages while in flight.
  The slice length is rounded up to the mapping page size and may exceed the
  registered bytes; the whole returned slice is what gets `munmap`ed.
- `pushSendZC` produces **two** completions: the first has `hasMore()` set and
  reports bytes queued (buffer still pinned), the second has `hasNotif()` set
  and means the buffer is reusable. Do not modify or reuse the buffer until the
  `hasNotif` CQE arrives.
- `msgFlags` are regular `MSG_*` flags (e.g. `MSG_NOSIGNAL`).

## Batched submission and consumption

`batchedSQ` reserves SQEs without publishing them; `commit` flushes them with a
single kernel wakeup. `batchedCQ` reads completions without advancing the ring
head; `commit` publishes the advanced head.

```zig
var batch = ring.batchedSQ() orelse return error.RingFull;
if (batch.pushSend(fd, 1, ptr, len, .{}) == null) return error.BatchFull;
try batch.commit();
```

- `BatchSQ` exposes only `pushWrite`, `pushSend`, `pushSendZC`, `pushAccept` and
  `pushTimeoutForOp`; each returns `?void` (null when full, nothing reserved).
  It has **no** read/recv/open/close/listen/bind/connect/msgring/standalone-timeout
  helpers.
- `BatchCQ.popCQE()` returns null once the captured tail is reached.
- `commit` on either batch may return an error from `posix.unexpectedErrno`.

### Linked timeout (canonical batch usage)

The guard must travel in the same submission batch as the operation it guards,
which is exactly why `batchedSQ` exists:

```zig
const spec = linux.kernel_timespec{ .sec = 1, .nsec = 0 };
var batch = ring.batchedSQ() orelse return error.RingFull;
_ = batch.pushAccept(sockFd, 2, TaskFlags.expectNext()); // next op is linked
_ = batch.pushTimeoutForOp(&spec, 3, .{});
try batch.commit();
```

`TaskFlags.expectNext()` sets `Link` on the guarded op. On expiry the accept's
CQE reports `-ECANCELED` and the timeout CQE reports success (`res == 0`).

## `Factory`: threads and pollers

```zig
pub fn init(allocator: std.mem.Allocator, maxPollerThreads: u32) !Self;
pub fn deinit(self: *Self) void;
pub fn acquireRing(self: *Self, queueDepth: u32, weight: u32) !Ring;
```

Thread-safe. `acquireRing` picks the poller with the least accumulated `weight`
and attaches a new ring to it (`IORING_SETUP_ATTACH_WQ`); it starts a new poller
only while fewer than `maxPollerThreads` exist and the best one still has load.
`weight` is your estimate of how much work the ring will do. The factory owns no
rings; the caller owns and deinits each returned `Ring`. The **master ring**
(the first one in a group) must outlive every ring attached to it, since
attached rings share its kernel poller fd.

```zig
var mgr = try Factory.init(allocator, 2);
defer mgr.deinit();
var ring = try mgr.acquireRing(4096, 1);
defer ring.deinit();
```

## `TaskFlags`

```zig
pub const TaskFlags = packed struct(u8) {
    FixedFile: bool = false,
    Drain: bool = false,
    Link: bool = false,
    HardLink: bool = false,
    ForceAsync: bool = false,
    BufferSelect: bool = false,
    SkipSuccess: bool = false,
    pub inline fn flags(self: TaskFlags) u8;
    pub inline fn expectNext() TaskFlags; // { .Link = true }
};
```

Pass `.{}` for defaults. `SkipSuccess` suppresses the completion on success;
use with care for operations whose buffer/pointer you must reclaim (e.g.
timeouts), since it also hides the signal that the pointer is no longer needed.
`BufferSelect` is set automatically by the `*ZC` buffer-select ops.

## Timers

```zig
const spec = linux.kernel_timespec{ .sec = 0, .nsec = 500_000_000 }; // 500 ms
try ring.pushTimeout(taskIdx, &spec, .{});
```

Relative to submission unless flagged absolute (`linux.IORING_TIMEOUT_ABS`), and
expiry is reported as success by default. `spec` must stay valid until the
completion is consumed.

## `BufferSizeClass`

```zig
pub const BufferSizeClass = enum(u16) { tiny, small, net, page, big, huge };
```

| Class   | Bytes |
|---------|-------|
| `tiny`  | 128   |
| `small` | 512   |
| `net`   | 2048  |
| `page`  | 4096  |
| `big`   | 16384 |
| `huge`  | 65536 |

`size()` returns the byte size; `bgid()` returns the enum value used as the
kernel buffer group id.

## `ReorderBuffer`

Restores ordering when completions arrive out of order (for example across
multishot or concurrent ops). Items are tagged with an absolute sequence index
and released only once every earlier index has arrived.

```zig
var rb = try ReorderBuffer.init(allocator, 128, 21); // size pow2, <= 0xFFFF
defer rb.deinit();

rb.push(seqIdx, bytes) catch |err| switch (err) {
error.OutdatedFrame, error.FramesAreTooFarAway => return err,
else => return err,
};

if (rb.peekHeadCond(nextExpected)) |frame| {
// ... attempt work, keep the frame if you fail ...
rb.dropHead();
}
// or: if (rb.popHeadCond(nextExpected)) |frame| { ... } // removes it
```

- `size` (the reorder window) must be a power of two and at most `0xFFFF`, else
  `error.ReorderBufferSizeMustBeAPowOf2` / `error.ReorderBufferNoMoreThan32KibItems`.
  Backing storage is `2 * size` slots.
- `push` requires `data.len == itemSize`; copies the data in. An index below the
  current wave is `error.OutdatedFrame`, one `size` or more ahead is
  `error.FramesAreTooFarAway`.
- Returned slices (`popHeadCond`, `peekHeadCond`) are borrowed views valid only
  until a later `push` reuses the slot or `deinit` runs. Do not free them.
- `peekHeadCond` + `dropHead` lets you retry a failed operation without losing
  the frame; `popHeadCond` removes it immediately.

## `Slots(T)` and `BufferSlots`

Both hand out dense `u64` indices that are stable until `del`, with a root
table of `capacity` slots plus up to `childCount` lazily created child tables,
for `capacity * (1 + childCount)` values total.

```zig
var slots = try Slots(u64).init(allocator, 4096, 1); // cap pow2, >= 4096
defer slots.deinit();
const i = try slots.add(42);
_ = slots.get(i); // ?u64
slots.del(i);

var bufs = try BufferSlots.init(allocator, 16384, 32, 4); // 16384 * 32-byte buffers, 4 children
defer bufs.deinit();
const add = try bufs.addSlot(); // { .idx, .slice } aliases backing memory
@memcpy(add.slice, payload);
const j = try bufs.alloc(); // index only
```

- `capacity` must be a power of two and at least 4096 (`error.CapacityMustBePowerOfTwo`, `error.CapacityTooSmall`);
  `elementSize`
  must be non-zero (`error.ElementSizeCannotBeZero`). Full tables return
  `error.NoFreeSlots`.
- `Slots(T)`: values are stored **by copy**, no destructor ever runs, so `T`
  must be trivially copyable and own nothing.
- `BufferSlots` slices alias the backing allocation: mutate freely, never free,
  and treat them as invalid after `del`/`deinit`. Reused slots are **not**
  zeroed.
- `Slots.add` returns `u64`; `get` is O (1) via shift/mask. `del` on an
  out-of-range or already-free index is a silent no-op.

## Threading wrappers

```zig
pub const Mutex = struct { init/deinit, lock, unlock };
pub const CondVar = struct { init/deinit, wait(mutex), signal, broadcast };
pub const Thread = struct {
    pub fn spawn(context: anytype, comptime f: anytype) !Thread;
    pub fn join(self: Thread) void;
    pub fn setAffinity(self: Thread, coreId: u32) !void;
    pub fn setSelfAffinity(coreId: u32) !void;
};
```

- `Mutex`/`CondVar` embed the raw pthread object inline: they must live at a
  stable address, matching init/lock/wait/destroy on the same memory. Do not
  copy or move them once possibly contended.
- `CondVar.wait` must be called holding the mutex and always inside a loop that
  re-checks the predicate (wakeups may be spurious). `signal`/`broadcast` do
  not hand off the mutex.
- `Thread.spawn(context, f)`: `context` may be a pointer (the pointee must
  outlive the thread until `join`) or `void`/`null`. Failure returns
  `error.ThreadSpawnFailed`. Every successful spawn needs exactly one `join`
  (not from the thread itself), else resources leak.
- `setAffinity` returns `error.CpuIdOutOfRange` or
  `error.SetCpuAffinityFailed`.

```zig
const worker = struct {
    fn run(state: *Shared) void { /* ... */ }
}.run;
const t = try Thread.spawn(&state, worker);
t.join();
```

## Time and sockets

```zig
pub fn nowNs() u64;        // wall clock, Unix ns (vDSO)
pub fn monotonicNs() u64;  // monotonic ns, for elapsed-time deltas
```

```zig
pub fn createTCPServerSocket() !posix.fd_t;          // SO_REUSEADDR pre-set
pub fn createTCPClientSocket(opts: ?u32) !posix.fd_t; // opts = TCP option, e.g. linux.TCP.NODELAY
```

Both create `AF_INET` / `SOCK_STREAM` / `IPPROTO.TCP` sockets with
`SOCK_CLOEXEC`. The returned fd is caller-owned; close it with `Ring.pushClose`
or `close(2)`. Typical server sequence: `createTCPServerSocket` ->
`pushBindIp4` -> `pushListen` -> `pushAcceptMultishot`. On the `setsockopt`
failure path of `createTCPClientSocket` the fd is not closed by the helper (caller-visible leak on error); the server
helper does close on that path.

## Error reference

| Error                                                                                                                                 | Raised by                       |
|---------------------------------------------------------------------------------------------------------------------------------------|---------------------------------|
| `error.ZigRingRequiresDepthPowOf2`                                                                                                    | `Ring.init`                     |
| `error.ZigRingSetupFailed`                                                                                                            | `Ring.init`                     |
| `error.RegisterBuffersFailed`                                                                                                         | `Ring.registerBuffers`          |
| `error.BufferOfSizeAlreadyInitialized`                                                                                                | `regiterSizeClassReceiveBuffer` |
| `error.BufferPoolNotInitialized`                                                                                                      | buffer-select `push*`           |
| `error.RingFull`                                                                                                                      | any `Ring.push*`                |
| `error.CapacityMustBePowerOfTwo`, `error.CapacityTooSmall`, `error.ElementSizeCannotBeZero`, `error.NoFreeSlots`                      | `Slots` / `BufferSlots`         |
| `error.ReorderBufferSizeMustBeAPowOf2`, `error.ReorderBufferNoMoreThan32KibItems`, `error.OutdatedFrame`, `error.FramesAreTooFarAway` | `ReorderBuffer`                 |
| `error.ThreadSpawnFailed`, `error.CpuIdOutOfRange`, `error.SetCpuAffinityFailed`                                                      | `Thread`                        |

## Gotcha checklist

- **Pointer lifetime**: every buffer/path/`timespec`/sockaddr passed to a
  `push*` must stay valid and unchanged until its `CQE` is consumed. For the
  vectored ops that includes both the iovec array and every segment it points to.
- **Return provided buffers exactly once** with `releaseBuffer`, or the pool
  drains and multishot recv starts returning `-ENOBUFS`.
- **`SEND_ZC` yields two CQEs** (`hasMore`, then `hasNotif`); the registered
  buffer is pinned until the `hasNotif` one.
- **Linked timeout must be in the same batch** as the op it guards, else
  `-EINVAL`.
- **Hot path first**: `popCQE` / `batchedCQ` before `park`.
- **One ring per thread**; the `Factory` is the thread-safe allocator.
- **Check `res`** every time: short reads/writes and negative errnos are normal.
- Do not rename the misspelled public names (`regiterSizeClassReceiveBuffer`).
