//! mpy6a shard entry point.
//!
//! The CLI is a single optional option: the path of the siggy configuration.
//! Everything else is the two-phase startup process described in
//! docs/startup-en-reworked.md: build the shared state, start every thread,
//! collect their `INITIALIZED` reports, create the server socket, broadcast
//! `START_WORK`, and then run the shutdown choreography on a signal.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const dap = @import("dap");
const zigring = @import("zigring");

const config = @import("config.zig");
const lifetime = @import("lifetime.zig");
const messages = @import("messages.zig");

/// Path used when `-c/--config` is not given.
const default_config_path = "mpy6a.cfg";

const cliDecl = .{
    .run = dap.Command(
        .{ .help = "Run mpy6a with the given config file." },
        .{
            .config = dap.Flag([]const u8){
                .short = "c",
                .default = dap.defaultValue([]const u8, default_config_path),
                .validation = dap.Validate.stringNotEmpty,
                .help = "Path to the configuration file.",
            },
        },
    ),
    .config = dap.Command(.{
        .help = "A set of commands to show config, validate config and so on.",
    }, .{
        .show_dev = dap.Command(
            .{
                .name = "show-dev",
                .help = "Print the default development configuration file into the stdout and exit.",
            },
            .{},
        ),
        .validate = dap.Command(
            .{
                .help = "Validate config file.",
            },
            .{
                .path = dap.Argument([]const u8){
                    .validation = dap.Validate.stringNotEmpty,
                    .help = "Path to the configuration file.",
                },
            },
        ),
    }),
    .version = dap.Command(
        .{ .help = "Show current mpy6a version." },
        .{},
    ),
};

const CLI = dap.generate(
    dap.App{
        .name = "mpy6a",
        .help = "mpy6a distributed WAL.",
        .help_renderer = .{
            .highlight = .color,
        },
    },
    cliDecl,
);

/// TODO make computable by using build.zig.zon info.
const version = "mpy6a 0.0.0";

/// Prints the version and a short blessing of the build.
fn printVersion(io: std.Io) void {
    var buf: [128]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(io, &buf);
    _ = file_writer.interface.writeAll(version ++ "\n") catch {};
    _ = file_writer.interface.flush() catch {};
}

/// Prints the default configuration document to standard out.
fn printDefaultConfig(allocator: std.mem.Allocator, io: std.Io) !void {
    var manager = config.Manager().init(allocator, io, config.check_cpu_cores);
    defer manager.deinit();
    const document = try manager.default();
    defer allocator.free(document);

    var buf: [2048]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(io, &buf);
    try file_writer.interface.writeAll(document);
    try file_writer.interface.flush();
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const arena = init.arena.allocator();

    const argv = try init.minimal.args.toSlice(arena);
    const args = argv[1..];

    var diag: dap.Diag = .{};
    defer diag.deinit(arena);

    var cli = try CLI.parse(arena, init.minimal.environ, args, &diag);
    defer CLI.deinit(&cli, arena);
    var config_path: []const u8 = undefined;
    if (CLI.command(cli)) |cmd| switch (cmd) {
        .run => |c| {
            config_path = c.config;
        },
        .config => |c| {
            if (CLI.command(c)) |scmd| switch (scmd) {
                .show_dev => {
                    try printDefaultConfig(allocator, init.io);
                    return;
                },
                .validate => |v| {
                    var manager = config.Manager().init(allocator, io, config.check_cpu_cores);
                    defer manager.deinit();
                    _ = manager.fromFile(v.path) catch |err| {
                        std.debug.print("invalid config file {s}: {s}\n", .{ v.path, @errorName(err) });
                        std.process.exit(2);
                    };
                    var buf: [256]u8 = undefined;
                    var file_writer = std.Io.File.stdout().writer(io, &buf);
                    try file_writer.interface.print("config {s} is valid\n", .{v.path});
                    try file_writer.interface.flush();
                    return;
                },
            };

            try CLI.usage(cli);
            std.debug.print("\x1b[1;91mno config subcommand specified\x1b[0m\n", .{});
            std.process.exit(1);
        },
        .version => {
            printVersion(init.io);
            return;
        },
    } else {
        std.debug.print("\x1b[1;91mno command specified\x1b[0m\n", .{});
        try CLI.usage(cli);
        std.process.exit(1);
    }

    // The CPU count comes from here, not from the config: the startup runner
    // owns the host query and hands the bound down to the parser.
    const cpu_cores = std.Thread.getCpuCount() catch {
        std.debug.print("could not determine the host CPU count\n", .{});
        std.process.exit(2);
    };

    var cfg_manager = config.Manager().init(allocator, io, @intCast(cpu_cores));
    defer cfg_manager.deinit();
    const cfg = cfg_manager.fromFile(config_path) catch |err| {
        std.debug.print("failed to load config file {s}: {s}\n", .{ config_path, @errorName(err) });
        std.process.exit(2);
    };

    std.debug.print(
        "bind {s}:{d}, fronts {d}, indexes {d}, elephants {d}, host_index {d}\n",
        .{ cfg.bind, cfg.port, cfg.fronts, cfg.indexes, cfg.elephants, cfg.host_index },
    );

    runShard(allocator, &cfg) catch |err| {
        std.debug.print("shard failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

/// Runs one shard instance to completion: phase A, launch, signal wait, phase
/// B shutdown. Returns only once every working thread has been joined.
fn runShard(allocator: std.mem.Allocator, cfg: *const config.Config) !void {
    // Block the stop signals in the process thread before any worker starts:
    // pthreads inherit the mask, so no worker can swallow one.
    var signal_mask = posix.sigemptyset();
    posix.sigaddset(&signal_mask, posix.SIG.INT);
    posix.sigaddset(&signal_mask, posix.SIG.TERM);
    posix.sigaddset(&signal_mask, posix.SIG.HUP);
    posix.sigprocmask(posix.SIG.BLOCK, &signal_mask, null);

    var ctrl: lifetime.Controller = undefined;
    try ctrl.init(allocator, cfg);
    defer ctrl.deinit();

    const total: u16 = cfg.fronts + cfg.indexes + cfg.elephants;
    if (total > max_threads) return error.TooManyThreads;

    try ctrl.spawnThreads();

    var reported: [max_threads]bool = @splat(false);

    waitForInitialized(&ctrl, total, &reported) catch |err| {
        // The doc makes a startup timeout fatal: there is no graceful
        // degradation, and tearing the shared state down under live workers
        // would be worse than exiting.
        std.debug.print("startup failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    const listen_fd = try ctrl.createServerSocket();
    defer _ = linux.close(listen_fd);

    // The peer listener exists exactly when the replication group spans more
    // than one host. Its descriptor travels to the fronts through a slot, and
    // it is closed only after every front has stopped, so no arm outlives the
    // listener.
    const peer_fd: ?posix.fd_t = if (cfg.cluster != null)
        try ctrl.createPeerServerSocket()
    else
        null;
    defer {
        if (peer_fd) |fd| _ = linux.close(fd);
    }

    if (peer_fd) |fd| try postPeerListener(&ctrl, total, fd);

    try broadcastStartWork(&ctrl, total, listen_fd);

    // The process thread now waits for a stop cause: a stop signal or a
    // `ProcessStopRequestIdx` from an elephant's runtime fatality.
    const signal_fd = posix.signalfd(-1, &signal_mask, linux.SFD.CLOEXEC) catch |err| {
        std.debug.print("could not create the signal descriptor: {s}\n", .{@errorName(err)});
        return err;
    };
    defer _ = linux.close(signal_fd);

    switch (try awaitStopCause(&ctrl, signal_fd)) {
        .signal => |signo| std.debug.print("stop requested by signal {d}\n", .{signo}),
        .process_stop => |ring_idx| std.debug.print(
            "stop requested by {s}#{d}\n",
            .{ ctrl.roleOf(ring_idx).name(), ring_idx },
        ),
    }

    shutdown(&ctrl, total) catch |err| {
        std.debug.print("shutdown failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    // Every worker has reported done, so joining cannot block.
    ctrl.joinThreads();
}

/// Why the process thread left its park.
const StopCause = union(enum) {
    /// A stop signal arrived; `signo` is its number.
    signal: u32,
    /// An elephant requested the process stop; the value is the sender's ring
    /// index, the operator's breadcrumb beside the elephant's own log entry.
    process_stop: u16,
};

/// Blocks until a stop cause arrives on the signalfd or the init ring
/// (designs/SNAPSHOTS.md §2.4). The park does not spin: `poll` sleeps on both
/// descriptors.
///
/// The init ring is idle after `waitForInitialized`, so its only expected
/// completion is `ProcessStopRequestIdx`; anything else is dropped with a log
/// line rather than trusted.
fn awaitStopCause(ctrl: *lifetime.Controller, signal_fd: posix.fd_t) !StopCause {
    var fds = [2]posix.pollfd{
        // The signal descriptor first: a stop signal outranks a stop request.
        .{ .fd = signal_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = ctrl.init_ring.ring.fd, .events = posix.POLL.IN, .revents = 0 },
    };

    while (true) {
        _ = try posix.poll(&fds, -1);

        // A broken descriptor would make `poll` return at once forever.
        const broken = posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL;
        if (fds[0].revents & broken != 0) return error.SignalFdClosed;
        if (fds[1].revents & broken != 0) return error.InitRingClosed;

        if (fds[0].revents & posix.POLL.IN != 0) {
            var info: linux.signalfd_siginfo = undefined;
            const n = try posix.read(signal_fd, std.mem.asBytes(&info));
            if (n != @sizeOf(linux.signalfd_siginfo)) return error.SignalReadShort;
            return .{ .signal = info.signo };
        }

        if (fds[1].revents & posix.POLL.IN != 0) {
            while (ctrl.init_ring.ring.popCQE()) |cqe| {
                const task_idx = cqe.taskIdx();
                if (task_idx == messages.ProcessStopRequestIdx) {
                    if (cqe.res < 0 or cqe.res > std.math.maxInt(u16)) {
                        std.debug.print("process-stop request has an invalid sender: {d}\n", .{cqe.res});
                        continue;
                    }
                    return .{ .process_stop = @intCast(cqe.res) };
                }
                std.debug.print("dropping unexpected init-ring completion {d}\n", .{task_idx});
            }
        }
    }
}

/// Upper bound for the number of working threads in one process.
const max_threads = 4096;

/// Blocks on the init ring until every worker reports `INITIALIZED`. A timeout
/// applies; on expiry the roles that did not report are named and the process
/// exits fatally.
fn waitForInitialized(ctrl: *lifetime.Controller, total: u16, reported: *[max_threads]bool) !void {
    // A one-shot multishot timer is the portable deadline: `pushTimeout` with
    // a zero `len` is rejected by the kernel in this zigring version.
    ctrl.init_deadline_spec = .{
        .sec = @intCast(@divExact(ctrl.cfg.init_timeout.value(), std.time.ns_per_s)),
        .nsec = 0,
    };
    try ctrl.init_ring.ring.pushTicker(messages.InitTimeoutIdx, &ctrl.init_deadline_spec, 1, .{});

    var seen: u16 = 0;
    while (seen < total) {
        const cqe = waitOne(&ctrl.init_ring.ring);
        const task_idx = cqe.taskIdx();

        if (task_idx == messages.InitTimeoutIdx) {
            reportMissing(ctrl, total, reported);
            return error.InitTimeout;
        }
        if (task_idx == messages.InitializedIdx) {
            // `res` is the sender's ring index, its slot in every shared array.
            const ring_idx: u16 = @intCast(cqe.res);
            if (ring_idx >= total or reported[ring_idx]) continue;
            reported[ring_idx] = true;
            seen += 1;
        }
    }
}

fn reportMissing(ctrl: *lifetime.Controller, total: u16, reported: *const [max_threads]bool) void {
    std.debug.print("startup timed out; missing reports:", .{});
    var ring_idx: u16 = 0;
    while (ring_idx < total) : (ring_idx += 1) {
        if (reported[ring_idx]) continue;
        std.debug.print(" {s}#{d}", .{ ctrl.roleOf(ring_idx).name(), ring_idx });
    }
    std.debug.print("\n", .{});
}

/// Hands the shared peer listener to every front through the cross-task pool.
///
/// This runs before `broadcastStartWork`, and both messages are pushed from the
/// init ring into the same front ring, so io_uring's per-source ordering is what
/// lets the front arm its peer accept on the descriptor it just stored.
fn postPeerListener(ctrl: *lifetime.Controller, total: u16, peer_fd: posix.fd_t) !void {
    var ring_idx: u16 = 0;
    while (ring_idx < total) : (ring_idx += 1) {
        if (std.meta.activeTag(ctrl.roleOf(ring_idx)) != .front) continue;

        const slot_idx = try ctrl.cross_slots.acquire();
        ctrl.cross_slots.at(slot_idx).* = .{ .PeerServerSocket = .{ .fd = peer_fd } };

        // The front's ring is live: a full SQ is the spin-retry the house rule
        // reserves for the process thread.
        while (true) {
            if (ctrl.init_ring.ring.pushMsgRingFd(
                ctrl.rings[ring_idx].ring.fd,
                messages.CrossTaskMessageIdx,
                slot_idx,
                .{},
            )) |_| {
                break;
            } else |err| switch (err) {
                error.RingFull => std.atomic.spinLoopHint(),
            }
        }
    }
}

/// Sends `START_WORK(socket_fd)` into every worker ring. The main ring has
/// already observed one `INITIALIZED` per worker, and io_uring preserves the
/// order inside each ring, so this single message is a safe launch barrier.
fn broadcastStartWork(ctrl: *lifetime.Controller, total: u16, listen_fd: posix.fd_t) !void {
    var ring_idx: u16 = 0;
    while (ring_idx < total) : (ring_idx += 1) {
        try ctrl.init_ring.ring.pushMsgRingFd(
            ctrl.rings[ring_idx].ring.fd,
            messages.StartWorkIdx,
            // The socket fd travels in `res`.
            @intCast(listen_fd),
            .{},
        );
    }
}

/// The process-side shutdown: demand, wait for all fronts and elephants, count
/// ticks, report what has not stopped, then return so the process can exit.
fn shutdown(ctrl: *lifetime.Controller, total: u16) !void {
    var ring_idx: u16 = 0;
    while (ring_idx < total) : (ring_idx += 1) {
        // The role follows from the ring index, which is the launch slot; the
        // barrier has collected every `INITIALIZED` report by now.
        if (std.meta.activeTag(ctrl.roleOf(ring_idx)) == .index) continue; // stopped by their fronts
        try ctrl.init_ring.ring.pushMsgRingFd(
            ctrl.rings[ring_idx].ring.fd,
            messages.ShutdownDemandIdx,
            0,
            .{},
        );
    }

    // Deadline ticker: one tick every 500 ms, policed from the moment the
    // demand was broadcast.
    ctrl.shutdown_tick_spec = .{ .sec = 0, .nsec = 500 * std.time.ns_per_ms };
    try ctrl.init_ring.ring.pushTicker(messages.ShutdownTickIdx, &ctrl.shutdown_tick_spec, 0, .{});

    // Only fronts and elephants report to the process ring; indexes report to
    // their parent fronts.
    const expected: u16 = ctrl.cfg.fronts + ctrl.cfg.elephants;

    var stopped: [max_threads]bool = @splat(false);
    var done: u16 = 0;
    var ticks: u32 = 0;
    const max_ticks: u32 = @intCast(@divExact(ctrl.cfg.shutdown_timeout.value(), 500 * std.time.ns_per_ms));

    while (done < expected) {
        const cqe = waitOne(&ctrl.init_ring.ring);
        if (cqe.taskIdx() == messages.ShutdownDoneIdx) {
            // `res` is the sender's ring index, its slot in every shared array.
            const sender_ring_idx: u16 = @intCast(cqe.res);
            if (sender_ring_idx >= total or stopped[sender_ring_idx]) continue;
            stopped[sender_ring_idx] = true;
            done += 1;
            continue;
        }
        if (cqe.taskIdx() == messages.ShutdownTickIdx) {
            ticks += 1;
            if (ticks >= max_ticks) {
                reportNotStopped(ctrl, total, &stopped);
                return error.ShutdownTimeout;
            }
        }
    }
}

fn reportNotStopped(ctrl: *lifetime.Controller, total: u16, stopped: *const [max_threads]bool) void {
    std.debug.print("shutdown timed out; still running:", .{});
    var ring_idx: u16 = 0;
    while (ring_idx < total) : (ring_idx += 1) {
        if (stopped[ring_idx]) continue;
        std.debug.print(" {s}#{d}", .{ ctrl.roleOf(ring_idx).name(), ring_idx });
    }
    std.debug.print("\n", .{});
}

/// Blocks until the ring yields one completion.
fn waitOne(ring: *zigring.Ring) zigring.CQE {
    while (true) {
        if (ring.popCQE()) |cqe| return cqe;
        ring.park();
    }
}

const state = @import("state.zig");
const cluster_transport = @import("cluster_transport.zig");

const StopFixture = struct {
    cfg: config.Config = undefined,
    ctrl: lifetime.Controller = undefined,

    fn init(self: *StopFixture) !void {
        self.cfg = .{
            .fronts = 1,
            .indexes = 1,
            .elephants = 1,
            .queue_depth = 64,
            .cross_task_slots = 8,
            .sqpoll_threads = 1,
            .ring_slots_capacity = 4096,
            .index_inbox_capacity = 8,
            .wal = .{ .plain = .{ .dir = "wal" } },
            .logging = .{
                .method = .{ .json = {} },
                .pool_capacity = 64,
                .pool_frame_size = config.bytes(1024),
            },
        };
        try self.ctrl.init(std.testing.allocator, &self.cfg);
    }

    fn deinit(self: *StopFixture) void {
        self.ctrl.deinit();
    }
};

fn emptySignalFd() !posix.fd_t {
    const mask = posix.sigemptyset();
    return posix.signalfd(-1, &mask, linux.SFD.CLOEXEC);
}

test "awaitStopCause reports a process-stop request with its sender" {
    var f: StopFixture = undefined;
    try f.init();
    defer f.deinit();

    const signal_fd = try emptySignalFd();
    defer _ = linux.close(signal_fd);

    try f.ctrl.init_ring.ring.pushMsgRingFd(
        f.ctrl.init_ring.ring.fd,
        messages.ProcessStopRequestIdx,
        2,
        .{},
    );

    const cause = try awaitStopCause(&f.ctrl, signal_fd);
    try std.testing.expect(std.meta.activeTag(cause) == .process_stop);
    try std.testing.expectEqual(@as(u16, 2), cause.process_stop);
}

test "awaitStopCause reports a blocked stop signal" {
    var f: StopFixture = undefined;
    try f.init();
    defer f.deinit();

    var mask = posix.sigemptyset();
    posix.sigaddset(&mask, posix.SIG.TERM);
    var previous_mask: posix.sigset_t = undefined;
    posix.sigprocmask(posix.SIG.BLOCK, &mask, &previous_mask);
    defer posix.sigprocmask(posix.SIG.SETMASK, &previous_mask, null);

    // The signal stays pending in the thread mask; ignoring it keeps a failed
    // read from terminating the whole test run when the mask is restored.
    const ignore: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    var previous_action: posix.Sigaction = undefined;
    posix.sigaction(posix.SIG.TERM, &ignore, &previous_action);
    defer posix.sigaction(posix.SIG.TERM, &previous_action, null);

    const signal_fd = try posix.signalfd(-1, &mask, linux.SFD.CLOEXEC);
    defer _ = linux.close(signal_fd);

    try posix.raise(posix.SIG.TERM);

    const cause = try awaitStopCause(&f.ctrl, signal_fd);
    try std.testing.expect(std.meta.activeTag(cause) == .signal);
    try std.testing.expectEqual(@as(u32, @backingInt(posix.SIG.TERM)), cause.signal);
}

test "awaitStopCause drops a foreign init-ring completion" {
    var f: StopFixture = undefined;
    try f.init();
    defer f.deinit();

    const signal_fd = try emptySignalFd();
    defer _ = linux.close(signal_fd);

    try f.ctrl.init_ring.ring.pushMsgRingFd(
        f.ctrl.init_ring.ring.fd,
        messages.InitializedIdx,
        0,
        .{},
    );
    try f.ctrl.init_ring.ring.pushMsgRingFd(
        f.ctrl.init_ring.ring.fd,
        messages.ProcessStopRequestIdx,
        1,
        .{},
    );

    const cause = try awaitStopCause(&f.ctrl, signal_fd);
    try std.testing.expect(std.meta.activeTag(cause) == .process_stop);
    try std.testing.expectEqual(@as(u16, 1), cause.process_stop);
    try std.testing.expect(f.ctrl.init_ring.ring.popCQE() == null);
}

test "u128 high-bits collision" {
    var sessions: [3]state.Session = undefined;
    var t = state.SessionsMap.init(std.testing.allocator);
    defer t.deinit();

    // Keys differing ONLY in the high 64 bits. The vendored AutoHashFn would
    // panic on these; the session map hashes the index slice and keeps
    // full-width equality.
    const first: u128 = 0x0000_0000_0000_0001_0000_0000_0000_0001;
    const second: u128 = 0x0000_0000_0000_0001_0000_0000_0000_0002;
    const third: u128 = 0x0000_0000_0000_0002_0000_0000_0000_0001;

    try t.put(first, &sessions[0]);
    try t.put(second, &sessions[1]);
    try t.put(third, &sessions[2]);

    try std.testing.expectEqual(&sessions[0], t.get(first).?);
    try std.testing.expectEqual(&sessions[1], t.get(second).?);
    try std.testing.expectEqual(&sessions[2], t.get(third).?);
}

// ============================================================================
// Stage K: the end-to-end transport harness and its scenarios
// ============================================================================
//
// Two independent controllers run in one process, each a full shard with one
// front, one index, its own ring set, WAL directory, client listener and peer
// listener. The harness performs the same startup choreography `runShard`
// does, minus the signal park: phase A, the barrier, both listeners, the peer
// listener hand-over, `START_WORK`, then either a demand-driven shutdown or a
// direct hard drain. The link tables are read through volatile loads because
// the scenarios observe them from the test thread while the shard threads
// write them; that is exactly the "waits on the in-process link tables" shape
// §K1 names.

const ClusterOptions = struct {
    keepalive_interval: config.Seconds = config.seconds(5),
    pulse_timeout: config.Seconds = config.seconds(1),
    handshake_timeout: config.Seconds = config.seconds(5),
    init_timeout: config.Seconds = config.seconds(10),
    shutdown_timeout: config.Seconds = config.seconds(5),
};

fn sleepNs(ns: u64) void {
    const spec = std.os.linux.timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    _ = std.os.linux.nanosleep(&spec, null);
}

/// Binds an ephemeral loopback port, learns its number and releases it. The
/// controllers then bind their own listeners on the returned ports.
fn pickLoopbackPort() !u16 {
    const raw = std.os.linux.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    if (std.os.linux.errno(raw) != .SUCCESS) return error.SocketFailed;
    const fd: posix.fd_t = @intCast(raw);
    defer _ = std.os.linux.close(fd);

    var addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = 0,
        .addr = @bitCast(std.Io.net.Ip4Address.loopback(0).bytes),
    };
    const bind_res = std.os.linux.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));
    if (std.os.linux.errno(bind_res) != .SUCCESS) return error.BindFailed;

    var len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    const name_res = std.os.linux.getsockname(fd, @ptrCast(&addr), &len);
    if (std.os.linux.errno(name_res) != .SUCCESS) return error.GetSockNameFailed;
    return std.mem.nativeToBig(u16, addr.port);
}

/// One controller of the harness: a complete shard with its own threads and
/// listeners. `peer_port` is the group's single peer port (§6): the two shards
/// share it and are separated by their loopback addresses, because the config
/// has one `peer_port` for the whole replication group.
const HarnessNode = struct {
    cfg: config.Config = undefined,
    ctrl: lifetime.Controller = undefined,
    peers: [2][]const u8 = .{ "", "" },
    bind: []const u8 = "127.0.0.1",
    dir: []u8 = &.{},
    inited: bool = false,
    started: bool = false,
    stopped: bool = false,
    listen_fd: posix.fd_t = -1,
    peer_fd: posix.fd_t = -1,
    total: u16 = 2,
    peer_port: u16 = 0,

    fn init(
        self: *HarnessNode,
        own: u16,
        bind: []const u8,
        peer_addr: []const u8,
        peer_port: u16,
        dir: []u8,
        opts: ClusterOptions,
    ) !void {
        self.dir = dir;
        self.peer_port = peer_port;
        self.bind = bind;
        self.peers[own] = "";
        self.peers[1 - own] = peer_addr;
        self.cfg = .{
            .bind = bind,
            // The client endpoint is unused by these tests; the kernel hands
            // out an ephemeral port so two controllers cannot collide.
            .port = 0,
            .fronts = 1,
            .front_cores = .{ .cores = &.{0} },
            .indexes = 1,
            .index_cores = .{ .cores = &.{0} },
            .elephants = 0,
            .host_index = own,
            .queue_depth = 64,
            .init_timeout = opts.init_timeout,
            .shutdown_timeout = opts.shutdown_timeout,
            .cross_task_slots = 64,
            .sqpoll_threads = 1,
            .ring_slots_capacity = 4096,
            .index_inbox_capacity = 8,
            .wal = .{ .plain = .{ .dir = dir, .hosts = 2 } },
            .snapshots = .{},
            .cluster = .{
                .peer_port = peer_port,
                .peers = self.peers[0..],
                .handshake_timeout = opts.handshake_timeout,
                .pulse_timeout = opts.pulse_timeout,
                .keepalive_interval = opts.keepalive_interval,
            },
            .logging = .{
                .method = .{ .json = {} },
                .pool_capacity = 64,
                .pool_frame_size = config.bytes(1024),
            },
        };
        try self.ctrl.init(std.testing.allocator, &self.cfg);
        self.inited = true;
    }

    /// The `runShard` startup, minus the signal park: threads, the barrier,
    /// both listeners, the peer hand-over before `START_WORK`.
    fn start(self: *HarnessNode) !void {
        try self.ctrl.spawnThreads();
        self.started = true;

        var reported: [max_threads]bool = @splat(false);
        try waitForInitialized(&self.ctrl, self.total, &reported);

        self.listen_fd = try self.ctrl.createServerSocket();
        self.peer_fd = try self.ctrl.createPeerServerSocket();
        try postPeerListener(&self.ctrl, self.total, self.peer_fd);
        try broadcastStartWork(&self.ctrl, self.total, self.listen_fd);
    }

    fn stopSoft(self: *HarnessNode) !void {
        if (!self.started or self.stopped) return;
        try shutdown(&self.ctrl, self.total);
        self.stopped = true;
    }

    /// Waits for one `ShutdownDone` on this shard's init ring. Used by the
    /// hard-drain scenario, where no `ShutdownDemand` is ever broadcast.
    fn waitDone(self: *HarnessNode, timeout_ns: u64) !void {
        const deadline = zigring.monotonicNs() + timeout_ns;
        while (zigring.monotonicNs() < deadline) {
            if (self.ctrl.init_ring.ring.popCQE()) |cqe| {
                if (cqe.taskIdx() == messages.ShutdownDoneIdx) {
                    self.stopped = true;
                    return;
                }
                continue;
            }
            sleepNs(1 * std.time.ns_per_ms);
        }
        return error.ShutdownDoneTimeout;
    }

    fn join(self: *HarnessNode) void {
        if (!self.started) return;
        self.ctrl.joinThreads();
        self.started = false;
    }

    fn deinit(self: *HarnessNode) void {
        if (self.inited) {
            if (self.started) {
                // A failed test must not leave the shard running: the demand
                // path is bounded by `shutdown_timeout`. If even that fails the
                // threads are left to the process exit rather than joined live.
                self.stopSoft() catch return;
                self.join();
            }
            if (self.listen_fd >= 0) {
                _ = std.os.linux.close(self.listen_fd);
                self.listen_fd = -1;
            }
            if (self.peer_fd >= 0) {
                _ = std.os.linux.close(self.peer_fd);
                self.peer_fd = -1;
            }
            self.ctrl.deinit();
            self.inited = false;
        }
        if (self.dir.len != 0) {
            std.testing.allocator.free(self.dir);
            self.dir = &.{};
        }
    }
};

/// The two-shard group: host 0 dials host 1, so the first link travels the
/// full front-accept / greet / verdict path on both sides.
const ClusterPair = struct {
    node0: HarnessNode = .{},
    node1: HarnessNode = .{},

    fn init(self: *ClusterPair, tmp: *const std.testing.TmpDir, opts: ClusterOptions) !void {
        const dir0 = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/h0", .{tmp.sub_path[0..]});
        const dir1 = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/h1", .{tmp.sub_path[0..]});

        // §6 pins one peer port for the whole group, so the two shards share it
        // and are separated by loopback addresses instead.
        const peer_port = try pickLoopbackPort();

        // The nodes own their directory strings; a failure inside `init`
        // releases them through `HarnessNode.deinit`, which is safe before the
        // controller exists (only the directory is owned by then).
        errdefer self.node0.deinit();
        try self.node0.init(0, "127.0.0.1", "127.0.0.2", peer_port, dir0, opts);
        errdefer self.node1.deinit();
        try self.node1.init(1, "127.0.0.2", "127.0.0.1", peer_port, dir1, opts);
    }

    fn start(self: *ClusterPair) !void {
        try self.node0.start();
        try self.node1.start();
    }

    fn deinit(self: *ClusterPair) void {
        self.node1.deinit();
        self.node0.deinit();
    }
};

fn volatileLoad(comptime T: type, ptr: *T) T {
    return @as(*volatile T, @ptrCast(ptr)).*;
}

fn nodeEntry(node: *HarnessNode, peer_host: u8) ?*cluster_transport.LinkEntry {
    if (node.ctrl.link_tables.len == 0) return null;
    const table = &node.ctrl.link_tables[0];
    if (peer_host >= table.entries.len) return null;
    return volatileLoad(?*cluster_transport.LinkEntry, &table.entries[peer_host]);
}

fn entryState(entry: *cluster_transport.LinkEntry) cluster_transport.LinkState {
    return volatileLoad(cluster_transport.LinkState, &entry.state);
}

fn entryEpoch(entry: *cluster_transport.LinkEntry) u32 {
    return volatileLoad(u32, &entry.epoch);
}

fn entrySeq(entry: *cluster_transport.LinkEntry) u64 {
    return volatileLoad(u64, &entry.seq_abs);
}

fn waitBothUp(pair: *ClusterPair, timeout_ns: u64) !void {
    const deadline = zigring.monotonicNs() + timeout_ns;
    while (zigring.monotonicNs() < deadline) {
        const e0 = nodeEntry(&pair.node0, 1);
        const e1 = nodeEntry(&pair.node1, 0);
        if (e0 != null and e1 != null and
            entryState(e0.?) == .up and entryState(e1.?) == .up) return;
        sleepNs(500 * std.time.ns_per_us);
    }
    return error.LinkUpTimeout;
}

fn waitBothNotUp(pair: *ClusterPair, timeout_ns: u64) !void {
    const deadline = zigring.monotonicNs() + timeout_ns;
    while (zigring.monotonicNs() < deadline) {
        const e0 = nodeEntry(&pair.node0, 1);
        const e1 = nodeEntry(&pair.node1, 0);
        const dead0 = e0 == null or entryState(e0.?) != .up;
        const dead1 = e1 == null or entryState(e1.?) != .up;
        if (dead0 and dead1) return;
        sleepNs(500 * std.time.ns_per_us);
    }
    return error.LinkStillUp;
}

fn waitEntryUp(node: *HarnessNode, peer_host: u8, timeout_ns: u64) !*cluster_transport.LinkEntry {
    const deadline = zigring.monotonicNs() + timeout_ns;
    while (zigring.monotonicNs() < deadline) {
        if (nodeEntry(node, peer_host)) |entry| {
            if (entryState(entry) == .up) return entry;
        }
        sleepNs(500 * std.time.ns_per_us);
    }
    return error.LinkUpTimeout;
}

fn waitCandidateParked(node: *HarnessNode, peer_host: u8, timeout_ns: u64) !void {
    const deadline = zigring.monotonicNs() + timeout_ns;
    while (zigring.monotonicNs() < deadline) {
        if (nodeEntry(node, peer_host)) |entry| {
            if (volatileLoad(cluster_transport.LinkState, &entry.candidate_state) == .parked) return;
        }
        sleepNs(200 * std.time.ns_per_us);
    }
    return error.CandidateNotParked;
}

fn connectTcp(host_text: []const u8, port: u16) !posix.fd_t {
    const raw = std.os.linux.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0);
    if (std.os.linux.errno(raw) != .SUCCESS) return error.SocketFailed;
    const fd: posix.fd_t = @intCast(raw);
    errdefer _ = std.os.linux.close(fd);

    const ip = if (std.mem.eql(u8, host_text, "localhost"))
        std.Io.net.Ip4Address.loopback(port)
    else
        try std.Io.net.Ip4Address.parse(host_text, port);
    var addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = @bitCast(ip.bytes),
    };
    const res = std.os.linux.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));
    const err = std.os.linux.errno(res);
    if (err == .SUCCESS) return fd;
    if (err != .INPROGRESS) return error.ConnectFailed;

    var fds = [1]posix.pollfd{.{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 }};
    const n = posix.poll(&fds, 5000) catch return error.ConnectTimedOut;
    if (n == 0) return error.ConnectTimedOut;
    if (fds[0].revents & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0) return error.ConnectFailed;
    return fd;
}

fn waitFd(fd: posix.fd_t, events: i16, timeout_ms: i32) !void {
    var fds = [1]posix.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
    const n = posix.poll(&fds, timeout_ms) catch return error.PollFailed;
    if (n == 0) return error.IoTimeout;
    if (fds[0].revents & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0) return error.IoClosed;
}

fn writeAll(fd: posix.fd_t, src: []const u8, timeout_ms: i32) !void {
    var written: usize = 0;
    while (written < src.len) {
        const rc = std.os.linux.write(fd, src[written..].ptr, src.len - written);
        const err = std.os.linux.errno(rc);
        if (err == .SUCCESS) {
            written += rc;
            continue;
        }
        if (err == .AGAIN) {
            try waitFd(fd, posix.POLL.OUT, timeout_ms);
            continue;
        }
        return error.WriteFailed;
    }
}

fn readAll(fd: posix.fd_t, dst: []u8, timeout_ms: i32) !void {
    var got: usize = 0;
    while (got < dst.len) {
        const rc = std.os.linux.read(fd, dst[got..].ptr, dst.len - got);
        const err = std.os.linux.errno(rc);
        if (err == .SUCCESS) {
            if (rc == 0) return error.EndOfStream;
            got += rc;
            continue;
        }
        if (err == .AGAIN) {
            try waitFd(fd, posix.POLL.IN, timeout_ms);
            continue;
        }
        return error.ReadFailed;
    }
}

fn sendGreet(fd: posix.fd_t, host_idx: u8, index_idx: u16) !void {
    var bytes: [cluster_transport.GREET_LEN]u8 = undefined;
    cluster_transport.encodeGreet(.{
        .version = cluster_transport.VERSION,
        .host_idx = host_idx,
        .index_idx = index_idx,
    }, &bytes);
    try writeAll(fd, &bytes, 5000);
}

fn readReply(fd: posix.fd_t) !cluster_transport.Reply {
    var bytes: [cluster_transport.REPLY_LEN]u8 = undefined;
    try readAll(fd, &bytes, 5000);
    return cluster_transport.decodeReply(&bytes) catch error.BadReply;
}

test "stage K: the greet establishes the link on both shards" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pair: ClusterPair = .{};
    try pair.init(&tmp, .{});
    defer pair.deinit();

    const started_at = zigring.monotonicNs();
    try pair.start();
    try waitBothUp(&pair, 10 * std.time.ns_per_s);

    // §K1: the first dial lands without a retry, inside the handshake bound.
    const less_than_backoff_bound = zigring.monotonicNs() - started_at < cluster_transport.RETRY_MAX;
    try std.testing.expect(less_than_backoff_bound);

    const e0 = nodeEntry(&pair.node0, 1).?;
    const e1 = nodeEntry(&pair.node1, 0).?;
    try std.testing.expectEqual(cluster_transport.LinkState.up, entryState(e0));
    try std.testing.expectEqual(cluster_transport.LinkState.up, entryState(e1));
    try std.testing.expect(e0.fd >= 0 and e1.fd >= 0);
    try std.testing.expect(volatileLoad(?u64, &e0.connect_task) == null);
    try std.testing.expect(volatileLoad(?u64, &e0.verdict_task) == null);
    try std.testing.expect(volatileLoad(?u64, &e0.retry_task) == null);
    try std.testing.expect(volatileLoad(?u64, &e1.keepalive_task) != null);
    try std.testing.expect(volatileLoad(?u64, &e0.keepalive_task) != null);
    try std.testing.expectEqual(cluster_transport.RETRY_MIN, e0.retry_backoff);

    try pair.node0.stopSoft();
    try pair.node1.stopSoft();
    try std.testing.expectEqual(cluster_transport.LinkState.none, entryState(e0));
    try std.testing.expectEqual(cluster_transport.LinkState.none, entryState(e1));
    try std.testing.expect(e0.fd < 0 and e1.fd < 0);
}

test "stage K: the keepalive pulses round trip and both links stay up" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pair: ClusterPair = .{};
    try pair.init(&tmp, .{ .keepalive_interval = config.seconds(1) });
    defer pair.deinit();

    try pair.start();
    try waitBothUp(&pair, 10 * std.time.ns_per_s);

    const e0 = nodeEntry(&pair.node0, 1).?;
    const e1 = nodeEntry(&pair.node1, 0).?;
    const epoch0 = entryEpoch(e0);
    const epoch1 = entryEpoch(e1);
    const sent0 = entrySeq(e0);
    const sent1 = entrySeq(e1);

    // Three keepalive periods: each tick sends one pulse (and the peer one
    // acknowledgement), and a tick that finds no acknowledgement kills the
    // link. Staying up across three periods is the round trip.
    sleepNs(3200 * std.time.ns_per_ms);

    try std.testing.expectEqual(cluster_transport.LinkState.up, entryState(e0));
    try std.testing.expectEqual(cluster_transport.LinkState.up, entryState(e1));
    try std.testing.expectEqual(epoch0, entryEpoch(e0));
    try std.testing.expectEqual(epoch1, entryEpoch(e1));
    try std.testing.expect(entrySeq(e0) >= sent0 + 2);
    try std.testing.expect(entrySeq(e1) >= sent1 + 2);

    try pair.node0.stopSoft();
    try pair.node1.stopSoft();
}

test "stage K: a duplicate greet while the link is up is answered host_index_squatting" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pair: ClusterPair = .{};
    try pair.init(&tmp, .{});
    defer pair.deinit();

    try pair.start();
    try waitBothUp(&pair, 10 * std.time.ns_per_s);

    const e0 = nodeEntry(&pair.node0, 1).?;
    const e1 = nodeEntry(&pair.node1, 0).?;
    const epoch0 = entryEpoch(e0);
    const epoch1 = entryEpoch(e1);
    const fd0 = e0.fd;
    const fd1 = e1.fd;

    const intruder = try connectTcp(pair.node1.bind, pair.node1.peer_port);
    defer _ = std.os.linux.close(intruder);
    try sendGreet(intruder, 0, 0);

    const reply = try readReply(intruder);
    try std.testing.expectEqual(cluster_transport.Verdict.host_index_squatting, reply.verdict);
    try std.testing.expectEqual(@as(u16, 0), reply.index_idx);

    // The established link is untouched: same epoch, same descriptor, up.
    try std.testing.expectEqual(cluster_transport.LinkState.up, entryState(e0));
    try std.testing.expectEqual(cluster_transport.LinkState.up, entryState(e1));
    try std.testing.expectEqual(epoch0, entryEpoch(e0));
    try std.testing.expectEqual(epoch1, entryEpoch(e1));
    try std.testing.expectEqual(fd0, e0.fd);
    try std.testing.expectEqual(fd1, e1.fd);
    try std.testing.expect(volatileLoad(cluster_transport.LinkState, &e1.candidate_state) == .none);

    try pair.node0.stopSoft();
    try pair.node1.stopSoft();
}

test "stage K: a timed-out probe promotes the candidate at absolute zero" {
    // The acceptor is the higher host, so it never dials. The test itself is
    // the lower host: it dials with a raw socket, completes a greet, then lets
    // the probe for the second greet time out by never acknowledging it. That
    // is the §3.4 replacement with a dialer the test can silence.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/acceptor", .{tmp.sub_path[0..]});
    const port = try pickLoopbackPort();

    var node: HarnessNode = .{};
    try node.init(1, "127.0.0.2", "127.0.0.1", port, dir, .{ .keepalive_interval = config.seconds(30) });
    defer node.deinit();
    try node.start();

    const live = try connectTcp(node.bind, node.peer_port);
    defer _ = std.os.linux.close(live);
    try sendGreet(live, 0, 0);
    const first = try readReply(live);
    try std.testing.expectEqual(cluster_transport.Verdict.ok, first.verdict);

    const entry = try waitEntryUp(&node, 0, 5 * std.time.ns_per_s);
    const epoch_before = entryEpoch(entry);

    const candidate = try connectTcp(node.bind, node.peer_port);
    defer _ = std.os.linux.close(candidate);
    try sendGreet(candidate, 0, 0);

    // The dialer's side stops reading: `SHUT_RD` acknowledges nothing to the
    // peer and sends no FIN, so the parked candidate has no receive arm and
    // the probe on the live link goes unanswered. It must time out.
    try waitCandidateParked(&node, 0, 5 * std.time.ns_per_s);
    _ = std.os.linux.shutdown(live, @intCast(posix.SHUT.RD));
    const reply = try readReply(candidate);
    try std.testing.expectEqual(cluster_transport.Verdict.ok, reply.verdict);

    // The `ok` bytes leave before their send completion moves the link to
    // `up`; the completion is what installs it.
    const promoted = try waitEntryUp(&node, 0, 5 * std.time.ns_per_s);
    try std.testing.expectEqual(entry, promoted);

    // §3.4: the replacement bumps the epoch twice (the death and the up), and
    // the stream restarts at absolute zero with nothing replayed.
    try std.testing.expectEqual(cluster_transport.LinkState.up, entryState(entry));
    try std.testing.expect(entryEpoch(entry) >= epoch_before + 2);
    try std.testing.expectEqual(@as(u64, 0), entrySeq(entry));
    try std.testing.expectEqual(@as(u64, 0), volatileLoad(u64, &entry.pushed_absolute));
    try std.testing.expectEqual(@as(u64, 0), volatileLoad(u64, &entry.delivered));
    try std.testing.expect(volatileLoad(cluster_transport.LinkState, &entry.candidate_state) == .none);

    try node.stopSoft();
}

test "stage K: a dead link closes the higher side and the lower host redials at zero" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pair: ClusterPair = .{};
    try pair.init(&tmp, .{ .keepalive_interval = config.seconds(30) });
    defer pair.deinit();

    try pair.start();
    try waitBothUp(&pair, 10 * std.time.ns_per_s);

    const e0 = nodeEntry(&pair.node0, 1).?;
    const e1 = nodeEntry(&pair.node1, 0).?;
    const epoch0 = entryEpoch(e0);
    const epoch1 = entryEpoch(e1);

    // Kill the higher host's side. It closes and waits; only the lower host
    // has a retry timer, so the re-established pair is its own dial. (The
    // keepalive-miss arm of the same death is unit-tested in `src/index.zig`:
    // over loopback a one-sided shutdown is the only silent death available.)
    const higher_fd = e1.fd;
    try std.testing.expect(higher_fd >= 0);
    _ = std.os.linux.shutdown(higher_fd, @intCast(posix.SHUT.RD));

    try waitBothNotUp(&pair, 5 * std.time.ns_per_s);
    try waitBothUp(&pair, 10 * std.time.ns_per_s);

    const e0_again = nodeEntry(&pair.node0, 1).?;
    const e1_again = nodeEntry(&pair.node1, 0).?;
    try std.testing.expect(entryEpoch(e0_again) > epoch0);
    try std.testing.expect(entryEpoch(e1_again) > epoch1);

    // §3.4: the replacement restarts the stream at absolute zero.
    try std.testing.expectEqual(@as(u64, 0), entrySeq(e0_again));
    try std.testing.expectEqual(@as(u64, 0), volatileLoad(u64, &e0_again.pushed_absolute));
    try std.testing.expectEqual(@as(u64, 0), volatileLoad(u64, &e0_again.delivered));
    try std.testing.expectEqual(@as(u64, 0), entrySeq(e1_again));
    try std.testing.expectEqual(@as(u64, 0), volatileLoad(u64, &e1_again.pushed_absolute));
    try std.testing.expectEqual(@as(u64, 0), volatileLoad(u64, &e1_again.delivered));

    // The lower host's backoff was reset by the successful redial; the higher
    // host never held a dial arm or a retry at all.
    try std.testing.expectEqual(cluster_transport.RETRY_MIN, e0_again.retry_backoff);
    try std.testing.expect(volatileLoad(?u64, &e0_again.connect_task) == null);
    try std.testing.expect(volatileLoad(?u64, &e0_again.retry_task) == null);
    try std.testing.expect(volatileLoad(?u64, &e1_again.connect_task) == null);
    try std.testing.expect(volatileLoad(?u64, &e1_again.retry_task) == null);

    try pair.node0.stopSoft();
    try pair.node1.stopSoft();
}

test "stage K: soft teardown closes the links before the drain report" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pair: ClusterPair = .{};
    try pair.init(&tmp, .{});
    defer pair.deinit();

    try pair.start();
    try waitBothUp(&pair, 10 * std.time.ns_per_s);

    const e0 = nodeEntry(&pair.node0, 1).?;
    const e1 = nodeEntry(&pair.node1, 0).?;

    try pair.node0.stopSoft();
    try pair.node1.stopSoft();

    // The front reports done only after its index reported drained, and the
    // index closes every link before that report (§3.7).
    try std.testing.expectEqual(cluster_transport.LinkState.none, entryState(e0));
    try std.testing.expectEqual(cluster_transport.LinkState.none, entryState(e1));
    try std.testing.expect(e0.fd < 0 and e1.fd < 0);
    try std.testing.expect(volatileLoad(?u64, &e0.keepalive_task) == null);
    try std.testing.expect(volatileLoad(?u64, &e0.recv_task) == null);
    try std.testing.expect(volatileLoad(?u64, &e1.keepalive_task) == null);
    try std.testing.expect(volatileLoad(?u64, &e1.recv_task) == null);
}

test "stage K: hard teardown closes the links immediately and both shards exit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pair: ClusterPair = .{};
    try pair.init(&tmp, .{});
    defer pair.deinit();

    try pair.start();
    try waitBothUp(&pair, 10 * std.time.ns_per_s);

    const e0 = nodeEntry(&pair.node0, 1).?;
    const e1 = nodeEntry(&pair.node1, 0).?;

    // A direct hard drain of each index: the real trigger is the front's
    // escalation, but a session-free skeleton cannot keep a soft drain open,
    // so the hard branch is driven here exactly as `escalateShutdown` drives
    // it, one inbox push per index.
    const drain_started = zigring.monotonicNs();
    try pair.node0.ctrl.inboxes[0].push(.{ .shutdown_hard = {} });
    try pair.node1.ctrl.inboxes[0].push(.{ .shutdown_hard = {} });

    try pair.node0.waitDone(10 * std.time.ns_per_s);
    try pair.node1.waitDone(10 * std.time.ns_per_s);
    // "Immediately": one pass, not the soft drain's session wait.
    try std.testing.expect(zigring.monotonicNs() - drain_started < 2 * std.time.ns_per_s);

    try std.testing.expectEqual(cluster_transport.LinkState.none, entryState(e0));
    try std.testing.expectEqual(cluster_transport.LinkState.none, entryState(e1));
    try std.testing.expect(e0.fd < 0 and e1.fd < 0);

    pair.node0.join();
    pair.node1.join();
}
