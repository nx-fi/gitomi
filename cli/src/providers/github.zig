const std = @import("std");
const dispatch = @import("dispatch.zig");
const importer = @import("github/importer.zig");
const exporter = @import("github/exporter.zig");
const sync = @import("github/sync.zig");
pub const common = @import("github/common.zig");
pub const live = @import("github/live.zig");

const Allocator = std.mem.Allocator;

pub const provider = dispatch.Provider{
    .name = "github",
    .usage = "import|export|sync|live",
    .run = cmdGithub,
};

const subcommands = [_]dispatch.Subcommand{
    .{ .name = "import", .run = importer.cmdImport },
    .{ .name = "export", .run = exporter.cmdExport },
    .{ .name = "sync", .run = sync.cmdSync },
    .{ .name = "live", .run = live.cmdLive },
};

pub fn cmdGithub(allocator: Allocator, args: []const []const u8) !void {
    try dispatch.runSubcommand(allocator, provider.name, provider.usage, args, &subcommands);
}

test {
    _ = @import("github/tests.zig");
}
