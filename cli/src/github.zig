const std = @import("std");
const errors = @import("errors.zig");
const io = @import("io.zig");
const importer = @import("github/importer.zig");
const exporter = @import("github/exporter.zig");
const live = @import("github/live.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const eprint = io.eprint;

pub fn cmdGithub(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try eprint("usage: gt github <import|export|live> [options]\n", .{});
        return CliError.MissingArgument;
    }
    const sub = args[0];
    if (std.mem.eql(u8, sub, "import")) return importer.cmdImport(allocator, args[1..]);
    if (std.mem.eql(u8, sub, "export")) return exporter.cmdExport(allocator, args[1..]);
    if (std.mem.eql(u8, sub, "live")) return live.cmdLive(allocator, args[1..]);
    try eprint("unknown github subcommand '{s}'\n", .{sub});
    return CliError.InvalidArgument;
}

test {
    _ = @import("github/tests.zig");
}
