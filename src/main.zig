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
const default_config_path = "mpy6a.toml";

const cliDecl = .{
    .run = dap.Command(
        .{ .help = "Run mpy6a with the given config file." },
        .{
            .config = dap.Flag([]const u8){
                .short = "c",
                .default = dap.defaultValue([]const u8, default_config_path),
                .validation = dap.Validate.stringNotEmpty,
                .help = "Path to the siggy configuration file.",
            },
        },
    ),
    .show_dev_config = dap.Command(
        .{
            .name = "show-dev-config",
            .help = "Print the default development configuration file into stdout and exit.",
        },
        .{},
    ),
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
        .show_dev_config => {
            try printDefaultConfig(arena, init.io);
            return;
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
