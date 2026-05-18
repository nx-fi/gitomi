const std = @import("std");

const common = @import("common.zig");

const git = common.git;
const Allocator = common.Allocator;
const SqliteDb = common.SqliteDb;
const max_projected_reaction_emojis = common.max_projected_reaction_emojis;
const max_projected_reaction_actors = common.max_projected_reaction_actors;

pub fn insertReaction(
    db: *SqliteDb,
    object_kind: []const u8,
    object_id: []const u8,
    emoji: []const u8,
    actor: []const u8,
    event_hash: []const u8,
    created_at: []const u8,
) !void {
    if (std.mem.trim(u8, emoji, " \t\r\n").len == 0) return;
    var stmt = try db.prepare(
        \\INSERT OR IGNORE INTO reactions(object_kind, object_id, emoji, actor_principal, add_hash, created_at)
        \\VALUES (?, ?, ?, ?, ?, ?)
    );
    defer stmt.deinit();
    try stmt.bindText(1, object_kind);
    try stmt.bindText(2, object_id);
    try stmt.bindText(3, emoji);
    try stmt.bindText(4, actor);
    try stmt.bindText(5, event_hash);
    try stmt.bindText(6, created_at);
    try stmt.stepDone();
}

pub fn deleteReaction(
    allocator: Allocator,
    db: *SqliteDb,
    object_kind: []const u8,
    object_id: []const u8,
    emoji: []const u8,
    actor: []const u8,
    remove_hash: []const u8,
    payload: std.json.ObjectMap,
) !void {
    var explicit_hashes = std.StringHashMap(void).init(allocator);
    defer explicit_hashes.deinit();
    if (payload.get("add_hashes")) |value| {
        if (value == .array) {
            for (value.array.items) |item| {
                if (item != .string) continue;
                try explicit_hashes.put(item.string, {});
            }
        }
    }

    var select = try db.prepare(
        \\SELECT add_hash
        \\FROM reactions
        \\WHERE object_kind = ?
        \\  AND object_id = ?
        \\  AND emoji = ?
        \\  AND actor_principal = ?
    );
    defer select.deinit();
    try select.bindText(1, object_kind);
    try select.bindText(2, object_id);
    try select.bindText(3, emoji);
    try select.bindText(4, actor);
    while (try select.step()) {
        const add_hash = try select.columnTextDup(allocator, 0);
        defer allocator.free(add_hash);
        const explicit = explicit_hashes.contains(add_hash);
        if (!explicit and !(try git.isAncestor(allocator, add_hash, remove_hash))) continue;
        var delete = try db.prepare(
            \\DELETE FROM reactions
            \\WHERE object_kind = ?
            \\  AND object_id = ?
            \\  AND emoji = ?
            \\  AND actor_principal = ?
            \\  AND add_hash = ?
        );
        defer delete.deinit();
        try delete.bindText(1, object_kind);
        try delete.bindText(2, object_id);
        try delete.bindText(3, emoji);
        try delete.bindText(4, actor);
        try delete.bindText(5, add_hash);
        try delete.stepDone();
    }
}

pub fn reactionLimitRejection(db: *SqliteDb, object_kind: []const u8, object_id: []const u8) !?[]const u8 {
    if (try reactionCountExceeds(db, "SELECT COUNT(DISTINCT emoji) FROM reactions WHERE object_kind = ? AND object_id = ?", object_kind, object_id, max_projected_reaction_emojis)) {
        return "collection_limit_exceeded";
    }
    if (try reactionCountExceeds(db, "SELECT COUNT(DISTINCT actor_principal) FROM reactions WHERE object_kind = ? AND object_id = ?", object_kind, object_id, max_projected_reaction_actors)) {
        return "collection_limit_exceeded";
    }
    return null;
}

fn reactionCountExceeds(db: *SqliteDb, comptime sql_text: []const u8, object_kind: []const u8, object_id: []const u8, max_count: usize) !bool {
    var stmt = try db.prepare(sql_text);
    defer stmt.deinit();
    try stmt.bindText(1, object_kind);
    try stmt.bindText(2, object_id);
    if (!(try stmt.step())) return false;
    return stmt.columnInt64(0) > @as(i64, @intCast(max_count));
}
