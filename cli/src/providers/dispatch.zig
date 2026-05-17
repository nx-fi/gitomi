const std = @import("std");
const errors = @import("../errors.zig");
const io = @import("../io.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;

pub const Handler = *const fn (Allocator, []const []const u8) anyerror!void;

pub const Provider = struct {
    name: []const u8,
    usage: []const u8,
    run: Handler,
};

pub const Subcommand = struct {
    name: []const u8,
    run: Handler,
};

pub fn runSubcommand(
    allocator: Allocator,
    provider_name: []const u8,
    usage: []const u8,
    args: []const []const u8,
    subcommands: []const Subcommand,
) !void {
    if (args.len == 0) {
        try io.eprint("usage: gt {s} <{s}> [options]\n", .{ provider_name, usage });
        return CliError.MissingArgument;
    }

    const subcommand_name = args[0];
    for (subcommands) |subcommand| {
        if (std.mem.eql(u8, subcommand_name, subcommand.name)) {
            return subcommand.run(allocator, args[1..]);
        }
    }

    try io.eprint("unknown {s} subcommand '{s}'\n", .{ provider_name, subcommand_name });
    return CliError.InvalidArgument;
}
