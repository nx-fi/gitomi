const std = @import("std");
const index = @import("../index.zig");
const repo_mod = @import("../repo.zig");
const shared = @import("shared.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;

pub fn handleIndexRebuild(allocator: Allocator, repo: Repo, stream: @import("compat").net.Stream) !void {
    try index.ensureIndex(allocator, repo);
    try shared.sendResponse(allocator, stream, 204, "No Content", "text/plain", "", null);
}

pub fn handleNavStats(allocator: Allocator, repo: Repo, stream: @import("compat").net.Stream) !void {
    const body = try shared.renderNavStatsJson(allocator, repo);
    defer allocator.free(body);
    try shared.sendResponse(allocator, stream, 200, "OK", "application/json", body, "Cache-Control: no-store\r\n");
}
