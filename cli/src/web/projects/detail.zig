const std = @import("std");
const index = @import("../../index.zig");
const repo_mod = @import("../../repo.zig");
const shared = @import("../shared.zig");
const list = @import("list.zig");
const workspace = @import("workspace.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const SqliteDb = index.SqliteDb;
const queryValueOwned = shared.queryValueOwned;
const sqlite = index.sqlite;

pub fn renderProjectsPage(allocator: Allocator, repo: Repo, target: []const u8, csrf_token: []const u8) ![]u8 {
    if (try shared.renderIndexingPageIfStale(allocator, repo, "Projects", "projects", target)) |body| return body;
    try index.ensureIndex(allocator, repo);

    const project_query = try trimmedQueryValueOwned(allocator, target, "project");
    defer if (project_query) |value| allocator.free(value);
    const view_query = try trimmedQueryValueOwned(allocator, target, "view");
    defer if (view_query) |value| allocator.free(value);

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    if (project_query) |project| {
        return workspace.renderProjectWorkspace(allocator, repo, &db, project, view_query orelse "", target, csrf_token);
    }

    return list.renderProjectIndex(allocator, repo, &db, csrf_token);
}

fn trimmedQueryValueOwned(allocator: Allocator, target: []const u8, wanted_key: []const u8) !?[]u8 {
    const owned = try queryValueOwned(allocator, target, wanted_key) orelse return null;
    const trimmed = std.mem.trim(u8, owned, " \t\r\n");
    if (trimmed.len == 0) {
        allocator.free(owned);
        return null;
    }
    if (trimmed.ptr == owned.ptr and trimmed.len == owned.len) return owned;
    const result = try allocator.dupe(u8, trimmed);
    allocator.free(owned);
    return result;
}
