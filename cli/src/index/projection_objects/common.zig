const std = @import("std");

pub const event_model = @import("../../event/model.zig");
pub const event_json = @import("../../event/json.zig");
pub const git = @import("../../git.zig");
pub const json_writer = @import("../../json_writer.zig");
pub const ordering = @import("../projection_ordering.zig");
pub const sqlite_db = @import("../sqlite_db.zig");
pub const util = @import("../../util.zig");

pub const Allocator = std.mem.Allocator;
pub const SqliteDb = sqlite_db.SqliteDb;
pub const ValidatedEnvelope = event_model.ValidatedEnvelope;
pub const eventInFrontier = ordering.eventInFrontier;
pub const eventWins = ordering.eventWins;

pub const max_projected_labels: usize = 256;
pub const max_projected_participants: usize = 128;
pub const max_projected_issue_relationships: usize = 512;
pub const max_projected_concurrent_groups: usize = 128;
pub const max_projected_project_columns: usize = 128;
pub const max_projected_project_milestones: usize = 256;
pub const max_projected_project_fields: usize = 128;
pub const max_projected_project_field_options: usize = 512;
pub const max_projected_project_views: usize = 64;
pub const default_project_status = "Planned";
pub const max_projected_reaction_emojis: usize = 64;
pub const max_projected_reaction_actors: usize = 1024;

const insert_issue_project_sql = "INSERT OR IGNORE INTO issue_projects(issue_id, project, column_name, add_hash) VALUES (?, ?, ?, ?)";

pub const ProjectedSourceIdentity = struct {
    identity: []const u8,
    author: []const u8,
    email: []const u8,
    avatar_url: []const u8,
};

const ExistingSourceIdentity = struct {
    exists: bool = false,
    display_name_empty: bool = true,
    email_empty: bool = true,
};

pub fn sourceIdentityFromPayload(payload: std.json.ObjectMap) ProjectedSourceIdentity {
    return .{
        .identity = event_json.jsonString(payload.get("source_identity")) orelse "",
        .author = event_json.jsonString(payload.get("source_author")) orelse "",
        .email = event_json.jsonString(payload.get("source_email")) orelse "",
        .avatar_url = event_json.jsonString(payload.get("source_avatar_url")) orelse "",
    };
}

pub fn upsertSourceIdentity(db: *SqliteDb, source: ProjectedSourceIdentity) !void {
    if (source.identity.len == 0) return;
    const existing = try existingSourceIdentity(db, source.identity);
    const split = std.mem.indexOfScalar(u8, source.identity, ':');
    const provider = if (split) |idx| source.identity[0..idx] else "";
    const provider_user_id = if (split) |idx| source.identity[idx + 1 ..] else source.identity;

    var stmt = try db.prepare(
        \\INSERT INTO identities(id, provider, provider_user_id, display_name, email, avatar_url)
        \\VALUES (?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(id) DO UPDATE SET
        \\  provider = COALESCE(NULLIF(identities.provider, ''), excluded.provider),
        \\  provider_user_id = COALESCE(NULLIF(identities.provider_user_id, ''), excluded.provider_user_id),
        \\  display_name = COALESCE(NULLIF(identities.display_name, ''), excluded.display_name),
        \\  email = COALESCE(NULLIF(identities.email, ''), excluded.email),
        \\  avatar_url = COALESCE(NULLIF(identities.avatar_url, ''), excluded.avatar_url)
    );
    defer stmt.deinit();
    try stmt.bindText(1, source.identity);
    try stmt.bindText(2, provider);
    try stmt.bindText(3, provider_user_id);
    try stmt.bindText(4, source.author);
    try stmt.bindText(5, source.email);
    try stmt.bindText(6, source.avatar_url);
    try stmt.stepDone();

    if (!existing.exists or existing.display_name_empty) {
        try insertIdentityAlias(db, "display", source.author, source.identity);
    }
    if (!existing.exists or existing.email_empty) {
        try insertIdentityAlias(db, "email", source.email, source.identity);
    }
}

fn existingSourceIdentity(db: *SqliteDb, identity: []const u8) !ExistingSourceIdentity {
    var stmt = try db.prepare(
        \\SELECT display_name, email
        \\FROM identities
        \\WHERE id = ?
    );
    defer stmt.deinit();
    try stmt.bindText(1, identity);
    if (!(try stmt.step())) return .{};
    const display_name = try stmt.columnTextDup(db.allocator, 0);
    defer db.allocator.free(display_name);
    const email = try stmt.columnTextDup(db.allocator, 1);
    defer db.allocator.free(email);
    return .{
        .exists = true,
        .display_name_empty = display_name.len == 0,
        .email_empty = email.len == 0,
    };
}

fn insertIdentityAlias(db: *SqliteDb, kind: []const u8, value: []const u8, identity: []const u8) !void {
    if (value.len == 0) return;
    var stmt = try db.prepare(
        \\INSERT OR IGNORE INTO identity_aliases(alias_kind, alias_value, identity_id)
        \\VALUES (?, ?, ?)
    );
    defer stmt.deinit();
    try stmt.bindText(1, kind);
    try stmt.bindText(2, value);
    try stmt.bindText(3, identity);
    try stmt.stepDone();
}

pub fn creationEventWins(db: *SqliteDb, event_type: []const u8, object_id: []const u8, event_hash: []const u8) !bool {
    var stmt = try db.prepare(
        \\SELECT event_hash
        \\FROM events
        \\WHERE event_type = ?
        \\  AND object_id = ?
        \\  AND domain_status = 'accepted'
        \\ORDER BY ordinal
        \\LIMIT 1
    );
    defer stmt.deinit();
    try stmt.bindText(1, event_type);
    try stmt.bindText(2, object_id);
    if (!(try stmt.step())) return true;
    const winner = try stmt.columnTextDup(db.allocator, 0);
    defer db.allocator.free(winner);
    return std.mem.eql(u8, winner, event_hash);
}

pub fn acceptedCreationInFrontier(
    allocator: Allocator,
    db: *SqliteDb,
    event_type: []const u8,
    object_id: []const u8,
    before_event_hash: ?[]const u8,
) !bool {
    var stmt = try db.prepare(
        \\SELECT event_hash
        \\FROM events
        \\WHERE event_type = ?
        \\  AND object_id = ?
        \\  AND domain_status = 'accepted'
        \\ORDER BY event_hash DESC
    );
    defer stmt.deinit();
    try stmt.bindText(1, event_type);
    try stmt.bindText(2, object_id);
    while (try stmt.step()) {
        const creation_hash = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(creation_hash);
        if (try eventInFrontier(allocator, creation_hash, before_event_hash)) return true;
    }
    return false;
}

pub fn acceptedCreationHashInFrontier(
    allocator: Allocator,
    db: *SqliteDb,
    event_type: []const u8,
    object_id: []const u8,
    creation_hash: []const u8,
    before_event_hash: ?[]const u8,
) !bool {
    var stmt = try db.prepare(
        \\SELECT 1
        \\FROM events
        \\WHERE event_type = ?
        \\  AND object_id = ?
        \\  AND event_hash = ?
        \\  AND domain_status = 'accepted'
        \\LIMIT 1
    );
    defer stmt.deinit();
    try stmt.bindText(1, event_type);
    try stmt.bindText(2, object_id);
    try stmt.bindText(3, creation_hash);
    if (!(try stmt.step())) return false;
    return try eventInFrontier(allocator, creation_hash, before_event_hash);
}

pub fn upsertPullMetadata(
    db: *SqliteDb,
    pull_id: []const u8,
    source_identity: ProjectedSourceIdentity,
    commit_count: i64,
    changed_files: i64,
    additions: i64,
    deletions: i64,
) !void {
    var stmt = try db.prepare(
        \\INSERT INTO pull_metadata(pull_id, source_author, source_identity, source_email, source_avatar_url, commit_count, changed_files, additions, deletions)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(pull_id) DO UPDATE SET
        \\  source_author = excluded.source_author,
        \\  source_identity = excluded.source_identity,
        \\  source_email = excluded.source_email,
        \\  source_avatar_url = excluded.source_avatar_url,
        \\  commit_count = excluded.commit_count,
        \\  changed_files = excluded.changed_files,
        \\  additions = excluded.additions,
        \\  deletions = excluded.deletions
    );
    defer stmt.deinit();
    try stmt.bindText(1, pull_id);
    try stmt.bindText(2, source_identity.author);
    try stmt.bindText(3, source_identity.identity);
    try stmt.bindText(4, source_identity.email);
    try stmt.bindText(5, source_identity.avatar_url);
    try stmt.bindInt64(6, commit_count);
    try stmt.bindInt64(7, changed_files);
    try stmt.bindInt64(8, additions);
    try stmt.bindInt64(9, deletions);
    try stmt.stepDone();
}

pub fn metadataCount(payload: std.json.ObjectMap, key: []const u8) i64 {
    const value = event_json.jsonInteger(payload.get(key)) orelse return -1;
    return if (value >= 0) value else -1;
}

pub fn insertLegacyAliasFromEnvelope(db: *SqliteDb, object_kind: []const u8, object_id: []const u8, legacy: std.json.ObjectMap) !void {
    if (std.mem.eql(u8, object_kind, "issue")) {
        try insertLegacyAliasField(db, "github", object_kind, object_id, legacy, "github_issue_number");
        try insertLegacyAliasField(db, "gitlab", object_kind, object_id, legacy, "gitlab_issue_iid");
    } else if (std.mem.eql(u8, object_kind, "pull")) {
        try insertLegacyAliasField(db, "github", object_kind, object_id, legacy, "github_pull_number");
        try insertLegacyAliasField(db, "gitlab", object_kind, object_id, legacy, "gitlab_merge_request_iid");
    }
}

fn insertLegacyAliasField(db: *SqliteDb, provider: []const u8, object_kind: []const u8, object_id: []const u8, legacy: std.json.ObjectMap, key: []const u8) !void {
    const number = event_json.jsonInteger(legacy.get(key)) orelse return;
    if (number <= 0) return;

    var stmt = try db.prepare(
        \\INSERT OR IGNORE INTO legacy_aliases(provider, object_kind, object_id, number)
        \\VALUES (?, ?, ?, ?)
    );
    defer stmt.deinit();
    try stmt.bindText(1, provider);
    try stmt.bindText(2, object_kind);
    try stmt.bindText(3, object_id);
    try stmt.bindInt64(4, number);
    try stmt.stepDone();
}
pub fn insertIssueProject(db: *SqliteDb, issue_id: []const u8, project: []const u8, column: []const u8, event_hash: []const u8) !void {
    if (std.mem.trim(u8, project, " \t\r\n").len == 0) return;
    var stmt = try db.prepare(insert_issue_project_sql);
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    try stmt.bindText(2, project);
    try stmt.bindText(3, column);
    try stmt.bindText(4, event_hash);
    try stmt.stepDone();
}

pub fn jsonValueOrDefaultOwned(allocator: Allocator, value: ?std.json.Value, default_json: []const u8) ![]u8 {
    if (value) |actual| return try jsonValueOwned(allocator, actual);
    return try allocator.dupe(u8, default_json);
}

pub fn jsonValueOwned(allocator: Allocator, value: std.json.Value) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try appendJsonValue(&buf, allocator, value);
    return try buf.toOwnedSlice(allocator);
}

fn appendJsonValue(buf: *std.ArrayList(u8), allocator: Allocator, value: std.json.Value) !void {
    switch (value) {
        .null => try buf.appendSlice(allocator, "null"),
        .bool => |boolean| try buf.appendSlice(allocator, if (boolean) "true" else "false"),
        .integer => |integer| try @import("compat").appendPrint(allocator, buf, "{d}", .{integer}),
        .float => |number| try @import("compat").appendPrint(allocator, buf, "{d}", .{number}),
        .number_string => |number| try buf.appendSlice(allocator, number),
        .string => |string| try json_writer.appendJsonString(buf, allocator, string),
        .array => |array| {
            try buf.append(allocator, '[');
            for (array.items, 0..) |item, idx| {
                if (idx != 0) try buf.append(allocator, ',');
                try appendJsonValue(buf, allocator, item);
            }
            try buf.append(allocator, ']');
        },
        .object => |object| {
            try buf.append(allocator, '{');
            var first = true;
            var it = object.iterator();
            while (it.next()) |entry| {
                if (!first) try buf.append(allocator, ',');
                first = false;
                try json_writer.appendJsonString(buf, allocator, entry.key_ptr.*);
                try buf.append(allocator, ':');
                try appendJsonValue(buf, allocator, entry.value_ptr.*);
            }
            try buf.append(allocator, '}');
        },
    }
}

pub fn jsonStringValueOwned(allocator: Allocator, value: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try json_writer.appendJsonString(&buf, allocator, value);
    return try buf.toOwnedSlice(allocator);
}

pub fn jsonInteger(value: ?std.json.Value) ?i64 {
    const actual = value orelse return null;
    return switch (actual) {
        .integer => |integer| integer,
        else => null,
    };
}

pub fn jsonBool(value: ?std.json.Value) ?bool {
    const actual = value orelse return null;
    return switch (actual) {
        .bool => |boolean| boolean,
        else => null,
    };
}

pub fn isUuidPrefix(value: []const u8) bool {
    if (value.len < 1 or value.len > 36) return false;
    for (value) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F') or c == '-';
        if (!ok) return false;
    }
    return true;
}
pub fn collectionCountExceeds(db: *SqliteDb, comptime sql_text: []const u8, object_id: []const u8, max_count: usize) !bool {
    var stmt = try db.prepare(sql_text);
    defer stmt.deinit();
    try stmt.bindText(1, object_id);
    if (!(try stmt.step())) return false;
    return stmt.columnInt64(0) > @as(i64, @intCast(max_count));
}
