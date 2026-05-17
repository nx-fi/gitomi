const std = @import("std");
const errors = @import("errors.zig");
const io = @import("io.zig");

pub const dispatch = @import("providers/dispatch.zig");
pub const github = @import("providers/github.zig");
pub const gitlab = @import("providers/gitlab.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;

pub const Provider = dispatch.Provider;

// Register provider command modules here; the CLI discovers top-level provider
// commands from this list.
pub const all = [_]Provider{
    github.provider,
    gitlab.provider,
};

pub fn get(name: []const u8) ?Provider {
    inline for (all) |provider| {
        if (std.mem.eql(u8, name, provider.name)) return provider;
    }
    return null;
}

pub fn run(allocator: Allocator, name: []const u8, args: []const []const u8) !void {
    const provider = get(name) orelse {
        try io.eprint("gt: unknown provider '{s}'\n", .{name});
        return CliError.InvalidArgument;
    };
    try provider.run(allocator, args);
}
