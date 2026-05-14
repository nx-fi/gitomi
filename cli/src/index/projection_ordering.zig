const std = @import("std");

const git = @import("../git.zig");

const Allocator = std.mem.Allocator;

pub fn eventWins(allocator: Allocator, new_event_hash: []const u8, old_event_hash: []const u8) !bool {
    if (old_event_hash.len == 0) return true;
    if (new_event_hash.len == 0) return false;
    if (std.mem.eql(u8, new_event_hash, old_event_hash)) return false;
    if (try git.isAncestor(allocator, old_event_hash, new_event_hash)) return true;
    if (try git.isAncestor(allocator, new_event_hash, old_event_hash)) return false;
    return std.mem.order(u8, new_event_hash, old_event_hash) == .gt;
}

pub fn eventInFrontier(allocator: Allocator, event_hash: []const u8, before_event_hash: ?[]const u8) !bool {
    const frontier = before_event_hash orelse return true;
    if (event_hash.len == 0) return true;
    if (std.mem.eql(u8, event_hash, frontier)) return false;
    return try git.isAncestor(allocator, event_hash, frontier);
}
