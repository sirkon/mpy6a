//! mpy6a shard entry point.
//!
//! The CLI is a single optional option: the path of the siggy configuration.
//! Everything else about the process lives in `startup.zig`, which builds the
//! shard, brings up the socket and then runs the process loop until a signal
//! asks the shard to stop.

const std = @import("std");
const dap = @import("dap");

const config = @import("config.zig");

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
}
