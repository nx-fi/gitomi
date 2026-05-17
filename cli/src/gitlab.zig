const std = @import("std");
const errors = @import("errors.zig");
const io = @import("io.zig");
const importer = @import("gitlab/importer.zig");
const exporter = @import("gitlab/exporter.zig");
const sync = @import("gitlab/sync.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const eprint = io.eprint;

pub fn cmdGitlab(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try eprint("usage: gt gitlab <import|export|sync> [options]\n", .{});
        return CliError.MissingArgument;
    }
    const sub = args[0];
    if (std.mem.eql(u8, sub, "import")) return importer.cmdImport(allocator, args[1..]);
    if (std.mem.eql(u8, sub, "export")) return exporter.cmdExport(allocator, args[1..]);
    if (std.mem.eql(u8, sub, "sync")) return sync.cmdSync(allocator, args[1..]);
    try eprint("unknown gitlab subcommand '{s}'\n", .{sub});
    return CliError.InvalidArgument;
}

test {
    _ = @import("gitlab/tests.zig");
}
