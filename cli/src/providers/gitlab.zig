const std = @import("std");
const dispatch = @import("dispatch.zig");
const importer = @import("gitlab/importer.zig");
const exporter = @import("gitlab/exporter.zig");
const sync = @import("gitlab/sync.zig");
pub const common = @import("gitlab/common.zig");

const Allocator = std.mem.Allocator;

pub const provider = dispatch.Provider{
    .name = "gitlab",
    .usage = "import|export|sync",
    .run = cmdGitlab,
};

const subcommands = [_]dispatch.Subcommand{
    .{ .name = "import", .run = importer.cmdImport },
    .{ .name = "export", .run = exporter.cmdExport },
    .{ .name = "sync", .run = sync.cmdSync },
};

pub fn cmdGitlab(allocator: Allocator, args: []const []const u8) !void {
    try dispatch.runSubcommand(allocator, provider.name, provider.usage, args, &subcommands);
}

test {
    _ = @import("gitlab/tests.zig");
}
