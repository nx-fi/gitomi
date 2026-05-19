const std = @import("std");

const common = @import("common.zig");
const reactions = @import("reactions.zig");

const event_json = common.event_json;
const git = common.git;
const util = common.util;
const Allocator = common.Allocator;
const SqliteDb = common.SqliteDb;
const ValidatedEnvelope = common.ValidatedEnvelope;
const creationEventWins = common.creationEventWins;
const acceptedCreationInFrontier = common.acceptedCreationInFrontier;
const eventWins = common.eventWins;
const collectionCountExceeds = common.collectionCountExceeds;
const insertIssueProject = common.insertIssueProject;
const jsonValueOrDefaultOwned = common.jsonValueOrDefaultOwned;
const jsonValueOwned = common.jsonValueOwned;
const jsonStringValueOwned = common.jsonStringValueOwned;
const jsonInteger = common.jsonInteger;
const jsonBool = common.jsonBool;
const isUuidPrefix = common.isUuidPrefix;
const max_projected_labels = common.max_projected_labels;
const max_projected_participants = common.max_projected_participants;
const max_projected_project_columns = common.max_projected_project_columns;
const max_projected_project_milestones = common.max_projected_project_milestones;
const max_projected_project_fields = common.max_projected_project_fields;
const max_projected_project_field_options = common.max_projected_project_field_options;
const max_projected_project_views = common.max_projected_project_views;
const default_project_status = common.default_project_status;
const insertReaction = reactions.insertReaction;
const deleteReaction = reactions.deleteReaction;
const reactionLimitRejection = reactions.reactionLimitRejection;

pub fn applyProjectProjection(allocator: Allocator, db: *SqliteDb, event_hash: []const u8, envelope: ValidatedEnvelope, body: []const u8) !?[]const u8 {
    if (!std.mem.startsWith(u8, envelope.event_type, "project.")) return null;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return "invalid_event_envelope",
    };
    const payload = switch (root.get("payload") orelse return "invalid_event_envelope") {
        .object => |object| object,
        else => return "invalid_event_envelope",
    };

    if (std.mem.eql(u8, envelope.event_type, "project.created")) {
        if (!(try creationEventWins(db, "project.created", envelope.object_id, event_hash))) return "duplicate_object_id";
        const name = event_json.jsonString(payload.get("name")) orelse return "invalid_event_envelope";
        const slug = try projectSlugForCreate(allocator, db, payload, envelope.object_id, name);
        defer allocator.free(slug);
        const description = event_json.jsonString(payload.get("description")) orelse "";
        const state = event_json.jsonString(payload.get("state")) orelse "open";
        try insertProjectCreated(db, event_hash, envelope, name, slug, description, state);
        try insertPayloadProjectColumns(allocator, db, payload, envelope.object_id, event_hash);
        if (try projectColumnLimitRejection(db, envelope.object_id)) |reason| return reason;
        return try projectPropertyLimitRejection(db, envelope.object_id);
    }

    if (!(try acceptedCreationInFrontier(allocator, db, "project.created", envelope.object_id, event_hash))) return "object_not_created";

    if (std.mem.eql(u8, envelope.event_type, "project.updated")) {
        if (event_json.jsonString(payload.get("name"))) |name| {
            try updateProjectScalar(allocator, db, envelope.object_id, name, event_hash, envelope, "name", "name_occurred_at", "name_actor_principal", "name_event_hash");
        }
        if (event_json.jsonString(payload.get("description"))) |description| {
            try updateProjectScalar(allocator, db, envelope.object_id, description, event_hash, envelope, "description", "description_occurred_at", "description_actor_principal", "description_event_hash");
        }
        if (event_json.jsonString(payload.get("state"))) |state| {
            try updateProjectScalar(allocator, db, envelope.object_id, state, event_hash, envelope, "state", "state_occurred_at", "state_actor_principal", "state_event_hash");
        }
        if (event_json.jsonString(payload.get("status"))) |status| {
            try updateProjectScalar(allocator, db, envelope.object_id, status, event_hash, envelope, "status", "status_occurred_at", "status_actor_principal", "status_event_hash");
        }
        if (event_json.jsonString(payload.get("priority"))) |priority| {
            try updateProjectScalar(allocator, db, envelope.object_id, priority, event_hash, envelope, "priority", "priority_occurred_at", "priority_actor_principal", "priority_event_hash");
        }
        if (event_json.jsonString(payload.get("start_at"))) |start_at| {
            try updateProjectScalar(allocator, db, envelope.object_id, start_at, event_hash, envelope, "start_at", "start_at_occurred_at", "start_at_actor_principal", "start_at_event_hash");
        }
        if (event_json.jsonString(payload.get("end_at"))) |end_at| {
            try updateProjectScalar(allocator, db, envelope.object_id, end_at, event_hash, envelope, "end_at", "end_at_occurred_at", "end_at_actor_principal", "end_at_event_hash");
        }
        try insertProjectPayloadStringArray(db, payload, "leads_added", "INSERT OR IGNORE INTO project_leads(project_id, lead, add_hash, created_at, actor_principal) VALUES (?, ?, ?, ?, ?)", envelope.object_id, event_hash, envelope);
        try deleteProjectPayloadStringArray(allocator, db, payload, "leads_removed", "SELECT add_hash FROM project_leads WHERE project_id = ? AND lead = ?", "DELETE FROM project_leads WHERE project_id = ? AND lead = ? AND add_hash = ?", envelope.object_id, event_hash);
        try insertProjectPayloadStringArray(db, payload, "members_added", "INSERT OR IGNORE INTO project_members(project_id, member, add_hash, created_at, actor_principal) VALUES (?, ?, ?, ?, ?)", envelope.object_id, event_hash, envelope);
        try deleteProjectPayloadStringArray(allocator, db, payload, "members_removed", "SELECT add_hash FROM project_members WHERE project_id = ? AND member = ?", "DELETE FROM project_members WHERE project_id = ? AND member = ? AND add_hash = ?", envelope.object_id, event_hash);
        try insertProjectPayloadStringArray(db, payload, "labels_added", "INSERT OR IGNORE INTO project_labels(project_id, label, add_hash, created_at, actor_principal) VALUES (?, ?, ?, ?, ?)", envelope.object_id, event_hash, envelope);
        try deleteProjectPayloadStringArray(allocator, db, payload, "labels_removed", "SELECT add_hash FROM project_labels WHERE project_id = ? AND label = ?", "DELETE FROM project_labels WHERE project_id = ? AND label = ? AND add_hash = ?", envelope.object_id, event_hash);
        try insertProjectPayloadStringArray(db, payload, "milestones_added", "INSERT OR IGNORE INTO project_milestones(project_id, milestone_id, add_hash, created_at, actor_principal) VALUES (?, ?, ?, ?, ?)", envelope.object_id, event_hash, envelope);
        try deleteProjectPayloadStringArray(allocator, db, payload, "milestones_removed", "SELECT add_hash FROM project_milestones WHERE project_id = ? AND milestone_id = ?", "DELETE FROM project_milestones WHERE project_id = ? AND milestone_id = ? AND add_hash = ?", envelope.object_id, event_hash);
        if (try projectPropertyLimitRejection(db, envelope.object_id)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "project.column_added")) {
        const column = event_json.jsonString(payload.get("column")) orelse return "invalid_event_envelope";
        const column_ref = try projectColumnRefForAdd(allocator, db, payload, envelope.object_id, column);
        defer allocator.free(column_ref);
        try insertProjectColumn(db, envelope.object_id, column, column_ref, event_hash);
        if (try projectColumnLimitRejection(db, envelope.object_id)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "project.column_removed")) {
        const column = event_json.jsonString(payload.get("column")) orelse return "invalid_event_envelope";
        try deleteProjectColumn(allocator, db, envelope.object_id, column, event_hash);
    } else if (std.mem.eql(u8, envelope.event_type, "project.field_created")) {
        if (try applyProjectFieldCreated(allocator, db, payload, envelope.object_id, event_hash, envelope)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "project.field_updated")) {
        if (try applyProjectFieldUpdated(allocator, db, payload, envelope.object_id, event_hash, envelope)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "project.field_removed")) {
        const field_id = event_json.jsonString(payload.get("field_id")) orelse return "invalid_event_envelope";
        try updateProjectFieldState(allocator, db, envelope.object_id, field_id, "removed", event_hash, envelope);
    } else if (std.mem.eql(u8, envelope.event_type, "project.field_option_added")) {
        if (try applyProjectFieldOptionAdded(db, payload, envelope.object_id, event_hash, envelope)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "project.field_option_updated")) {
        if (try applyProjectFieldOptionUpdated(allocator, db, payload, envelope.object_id, event_hash, envelope)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "project.field_option_removed")) {
        const field_id = event_json.jsonString(payload.get("field_id")) orelse return "invalid_event_envelope";
        const option_id = event_json.jsonString(payload.get("option_id")) orelse return "invalid_event_envelope";
        try updateProjectFieldOptionState(allocator, db, envelope.object_id, field_id, option_id, "removed", event_hash, envelope);
    } else if (std.mem.eql(u8, envelope.event_type, "project.view_created")) {
        if (try applyProjectViewCreated(allocator, db, payload, envelope.object_id, event_hash, envelope)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "project.view_updated")) {
        if (try applyProjectViewUpdated(allocator, db, payload, envelope.object_id, event_hash, envelope)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "project.view_removed")) {
        const view_id = event_json.jsonString(payload.get("view_id")) orelse return "invalid_event_envelope";
        try updateProjectViewState(allocator, db, envelope.object_id, view_id, "removed", event_hash, envelope);
    } else if (std.mem.eql(u8, envelope.event_type, "project.reaction_added")) {
        const emoji = event_json.jsonString(payload.get("emoji")) orelse return "invalid_event_envelope";
        try insertReaction(db, "project", envelope.object_id, emoji, envelope.actor_principal, event_hash, envelope.occurred_at);
        if (try reactionLimitRejection(db, "project", envelope.object_id)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "project.reaction_removed")) {
        const emoji = event_json.jsonString(payload.get("emoji")) orelse return "invalid_event_envelope";
        try deleteReaction(allocator, db, "project", envelope.object_id, emoji, envelope.actor_principal, event_hash, payload);
    }
    return null;
}

fn insertProjectCreated(db: *SqliteDb, event_hash: []const u8, envelope: ValidatedEnvelope, name: []const u8, slug: []const u8, description: []const u8, state: []const u8) !void {
    const start_at = eventDate(envelope.occurred_at);
    var stmt = try db.prepare(
        \\INSERT OR IGNORE INTO projects(
        \\  id,
        \\  name, slug, name_occurred_at, name_actor_principal, name_event_hash,
        \\  description, description_occurred_at, description_actor_principal, description_event_hash,
        \\  state, state_occurred_at, state_actor_principal, state_event_hash,
        \\  status, status_occurred_at, status_actor_principal, status_event_hash,
        \\  priority, priority_occurred_at, priority_actor_principal, priority_event_hash,
        \\  start_at, start_at_occurred_at, start_at_actor_principal, start_at_event_hash,
        \\  end_at, end_at_occurred_at, end_at_actor_principal, end_at_event_hash,
        \\  created_at, author_principal, author_device
        \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    );
    defer stmt.deinit();
    try stmt.bindText(1, envelope.object_id);
    try stmt.bindText(2, name);
    try stmt.bindText(3, slug);
    try stmt.bindText(4, envelope.occurred_at);
    try stmt.bindText(5, envelope.actor_principal);
    try stmt.bindText(6, event_hash);
    try stmt.bindText(7, description);
    try stmt.bindText(8, envelope.occurred_at);
    try stmt.bindText(9, envelope.actor_principal);
    try stmt.bindText(10, event_hash);
    try stmt.bindText(11, state);
    try stmt.bindText(12, envelope.occurred_at);
    try stmt.bindText(13, envelope.actor_principal);
    try stmt.bindText(14, event_hash);
    try stmt.bindText(15, default_project_status);
    try stmt.bindText(16, envelope.occurred_at);
    try stmt.bindText(17, envelope.actor_principal);
    try stmt.bindText(18, event_hash);
    try stmt.bindText(19, "");
    try stmt.bindText(20, envelope.occurred_at);
    try stmt.bindText(21, envelope.actor_principal);
    try stmt.bindText(22, event_hash);
    try stmt.bindText(23, start_at);
    try stmt.bindText(24, envelope.occurred_at);
    try stmt.bindText(25, envelope.actor_principal);
    try stmt.bindText(26, event_hash);
    try stmt.bindText(27, "");
    try stmt.bindText(28, envelope.occurred_at);
    try stmt.bindText(29, envelope.actor_principal);
    try stmt.bindText(30, event_hash);
    try stmt.bindText(31, envelope.occurred_at);
    try stmt.bindText(32, envelope.actor_principal);
    try stmt.bindText(33, envelope.actor_device);
    try stmt.stepDone();
    if (envelope.actor_principal.len != 0) {
        try insertProjectCollectionValue(db, "INSERT OR IGNORE INTO project_leads(project_id, lead, add_hash, created_at, actor_principal) VALUES (?, ?, ?, ?, ?)", envelope.object_id, envelope.actor_principal, event_hash, envelope);
    }
}

fn eventDate(occurred_at: []const u8) []const u8 {
    if (occurred_at.len >= 10 and occurred_at[4] == '-' and occurred_at[7] == '-') return occurred_at[0..10];
    return "";
}

fn projectExists(db: *SqliteDb, project_id: []const u8) !bool {
    var stmt = try db.prepare("SELECT 1 FROM projects WHERE id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, project_id);
    return try stmt.step();
}

fn updateProjectScalar(
    allocator: Allocator,
    db: *SqliteDb,
    project_id: []const u8,
    value: []const u8,
    event_hash: []const u8,
    envelope: ValidatedEnvelope,
    comptime value_col: []const u8,
    comptime occurred_at_col: []const u8,
    comptime actor_col: []const u8,
    comptime event_hash_col: []const u8,
) !void {
    var select = try db.prepare("SELECT " ++ occurred_at_col ++ ", " ++ actor_col ++ ", " ++ event_hash_col ++ " FROM projects WHERE id = ?");
    defer select.deinit();
    try select.bindText(1, project_id);
    if (!(try select.step())) return;
    const old_occurred_at = try select.columnTextDup(allocator, 0);
    defer allocator.free(old_occurred_at);
    const old_actor = try select.columnTextDup(allocator, 1);
    defer allocator.free(old_actor);
    const old_event_hash = try select.columnTextDup(allocator, 2);
    defer allocator.free(old_event_hash);

    if (!(try eventWins(allocator, event_hash, old_event_hash))) return;

    var update = try db.prepare("UPDATE projects SET " ++ value_col ++ " = ?, " ++ occurred_at_col ++ " = ?, " ++ actor_col ++ " = ?, " ++ event_hash_col ++ " = ? WHERE id = ?");
    defer update.deinit();
    try update.bindText(1, value);
    try update.bindText(2, envelope.occurred_at);
    try update.bindText(3, envelope.actor_principal);
    try update.bindText(4, event_hash);
    try update.bindText(5, project_id);
    try update.stepDone();
}

fn insertProjectPayloadStringArray(
    db: *SqliteDb,
    payload: std.json.ObjectMap,
    key: []const u8,
    comptime sql_text: []const u8,
    project_id: []const u8,
    event_hash: []const u8,
    envelope: ValidatedEnvelope,
) !void {
    const value = payload.get(key) orelse return;
    const array = switch (value) {
        .array => |items| items,
        else => return,
    };
    for (array.items) |item| {
        if (item != .string) continue;
        try insertProjectCollectionValue(db, sql_text, project_id, item.string, event_hash, envelope);
    }
}

fn deleteProjectPayloadStringArray(
    allocator: Allocator,
    db: *SqliteDb,
    payload: std.json.ObjectMap,
    key: []const u8,
    comptime select_sql: []const u8,
    comptime delete_sql: []const u8,
    project_id: []const u8,
    event_hash: []const u8,
) !void {
    const value = payload.get(key) orelse return;
    const array = switch (value) {
        .array => |items| items,
        else => return,
    };
    for (array.items) |item| {
        if (item != .string) continue;
        try deleteProjectCollectionValue(allocator, db, select_sql, delete_sql, project_id, item.string, event_hash);
    }
}

fn insertProjectCollectionValue(db: *SqliteDb, comptime sql_text: []const u8, project_id: []const u8, value: []const u8, event_hash: []const u8, envelope: ValidatedEnvelope) !void {
    if (std.mem.trim(u8, value, " \t\r\n").len == 0) return;
    var stmt = try db.prepare(sql_text);
    defer stmt.deinit();
    try stmt.bindText(1, project_id);
    try stmt.bindText(2, value);
    try stmt.bindText(3, event_hash);
    try stmt.bindText(4, envelope.occurred_at);
    try stmt.bindText(5, envelope.actor_principal);
    try stmt.stepDone();
}

fn deleteProjectCollectionValue(
    allocator: Allocator,
    db: *SqliteDb,
    comptime select_sql: []const u8,
    comptime delete_sql: []const u8,
    project_id: []const u8,
    value: []const u8,
    remove_hash: []const u8,
) !void {
    var select = try db.prepare(select_sql);
    defer select.deinit();
    try select.bindText(1, project_id);
    try select.bindText(2, value);
    while (try select.step()) {
        const add_hash = try select.columnTextDup(allocator, 0);
        defer allocator.free(add_hash);
        if (!(try git.isAncestor(allocator, add_hash, remove_hash))) continue;
        var delete = try db.prepare(delete_sql);
        defer delete.deinit();
        try delete.bindText(1, project_id);
        try delete.bindText(2, value);
        try delete.bindText(3, add_hash);
        try delete.stepDone();
    }
}

fn insertPayloadProjectColumns(allocator: Allocator, db: *SqliteDb, payload: std.json.ObjectMap, project_id: []const u8, event_hash: []const u8) !void {
    const value = payload.get("columns") orelse return;
    const array = switch (value) {
        .array => |items| items,
        else => return,
    };
    for (array.items) |item| {
        if (item != .string) continue;
        const column_ref = try projectColumnRefForName(allocator, db, project_id, item.string);
        defer allocator.free(column_ref);
        try insertProjectColumn(db, project_id, item.string, column_ref, event_hash);
    }
}

fn insertProjectColumn(db: *SqliteDb, project_id: []const u8, column: []const u8, column_ref: []const u8, event_hash: []const u8) !void {
    if (std.mem.trim(u8, column, " \t\r\n").len == 0) return;
    var stmt = try db.prepare("INSERT OR IGNORE INTO project_columns(project_id, column_name, column_ref, add_hash) VALUES (?, ?, ?, ?)");
    defer stmt.deinit();
    try stmt.bindText(1, project_id);
    try stmt.bindText(2, column);
    try stmt.bindText(3, column_ref);
    try stmt.bindText(4, event_hash);
    try stmt.stepDone();
}

fn deleteProjectColumn(allocator: Allocator, db: *SqliteDb, project_id: []const u8, column: []const u8, remove_hash: []const u8) !void {
    var select = try db.prepare("SELECT add_hash FROM project_columns WHERE project_id = ? AND column_name = ?");
    defer select.deinit();
    try select.bindText(1, project_id);
    try select.bindText(2, column);
    while (try select.step()) {
        const add_hash = try select.columnTextDup(allocator, 0);
        defer allocator.free(add_hash);
        if (!(try git.isAncestor(allocator, add_hash, remove_hash))) continue;
        var delete = try db.prepare("DELETE FROM project_columns WHERE project_id = ? AND column_name = ? AND add_hash = ?");
        defer delete.deinit();
        try delete.bindText(1, project_id);
        try delete.bindText(2, column);
        try delete.bindText(3, add_hash);
        try delete.stepDone();
    }
}

fn projectColumnLimitRejection(db: *SqliteDb, project_id: []const u8) !?[]const u8 {
    if (try collectionCountExceeds(db, "SELECT COUNT(DISTINCT column_name) FROM project_columns WHERE project_id = ?", project_id, max_projected_project_columns)) {
        return "collection_limit_exceeded";
    }
    return null;
}

fn projectPropertyLimitRejection(db: *SqliteDb, project_id: []const u8) !?[]const u8 {
    if (try collectionCountExceeds(db, "SELECT COUNT(DISTINCT lead) FROM project_leads WHERE project_id = ?", project_id, max_projected_participants)) {
        return "collection_limit_exceeded";
    }
    if (try collectionCountExceeds(db, "SELECT COUNT(DISTINCT member) FROM project_members WHERE project_id = ?", project_id, max_projected_participants)) {
        return "collection_limit_exceeded";
    }
    if (try collectionCountExceeds(db, "SELECT COUNT(DISTINCT label) FROM project_labels WHERE project_id = ?", project_id, max_projected_labels)) {
        return "collection_limit_exceeded";
    }
    if (try collectionCountExceeds(db, "SELECT COUNT(DISTINCT milestone_id) FROM project_milestones WHERE project_id = ?", project_id, max_projected_project_milestones)) {
        return "collection_limit_exceeded";
    }
    return null;
}

fn projectFieldLimitRejection(db: *SqliteDb, project_id: []const u8) !?[]const u8 {
    if (try collectionCountExceeds(db, "SELECT COUNT(*) FROM project_fields WHERE project_id = ? AND state != 'removed'", project_id, max_projected_project_fields)) {
        return "collection_limit_exceeded";
    }
    return null;
}

fn projectFieldOptionLimitRejection(db: *SqliteDb, field_id: []const u8) !?[]const u8 {
    if (try collectionCountExceeds(db, "SELECT COUNT(*) FROM project_field_options WHERE field_id = ? AND state != 'removed'", field_id, max_projected_project_field_options)) {
        return "collection_limit_exceeded";
    }
    return null;
}

fn projectViewLimitRejection(db: *SqliteDb, project_id: []const u8) !?[]const u8 {
    if (try collectionCountExceeds(db, "SELECT COUNT(*) FROM project_views WHERE project_id = ? AND state != 'removed'", project_id, max_projected_project_views)) {
        return "collection_limit_exceeded";
    }
    return null;
}

fn projectSlugForCreate(allocator: Allocator, db: *SqliteDb, payload: std.json.ObjectMap, project_id: []const u8, name: []const u8) ![]u8 {
    const raw_slug = event_json.jsonString(payload.get("slug")) orelse name;
    const sanitized = try util.sanitizeRefSegment(allocator, raw_slug);
    defer allocator.free(sanitized);
    const slug = if (sanitized.len == 0)
        try std.fmt.allocPrint(allocator, "project-{s}", .{project_id[0..@min(project_id.len, 7)]})
    else
        try allocator.dupe(u8, sanitized);
    defer allocator.free(slug);

    if (!(try projectSlugExistsForOther(db, slug, project_id))) return try allocator.dupe(u8, slug);
    return try std.fmt.allocPrint(allocator, "{s}-{s}", .{ slug, project_id[0..@min(project_id.len, 7)] });
}

fn projectSlugExistsForOther(db: *SqliteDb, slug: []const u8, project_id: []const u8) !bool {
    var stmt = try db.prepare("SELECT 1 FROM projects WHERE slug = ? AND id != ? LIMIT 1");
    defer stmt.deinit();
    try stmt.bindText(1, slug);
    try stmt.bindText(2, project_id);
    return try stmt.step();
}

fn projectColumnRefForAdd(allocator: Allocator, db: *SqliteDb, payload: std.json.ObjectMap, project_id: []const u8, column: []const u8) ![]u8 {
    if (event_json.jsonString(payload.get("column_ref"))) |column_ref| {
        const sanitized = try util.sanitizeRefSegment(allocator, column_ref);
        if (sanitized.len != 0) return sanitized;
        allocator.free(sanitized);
    }
    return try projectColumnRefForName(allocator, db, project_id, column);
}

fn projectColumnRefForName(allocator: Allocator, db: *SqliteDb, project_id: []const u8, column: []const u8) ![]u8 {
    const sanitized = try util.sanitizeRefSegment(allocator, column);
    defer allocator.free(sanitized);
    const base = if (sanitized.len == 0) try allocator.dupe(u8, "column") else try allocator.dupe(u8, sanitized);
    defer allocator.free(base);

    if (!(try projectColumnRefExists(db, project_id, base))) return try allocator.dupe(u8, base);
    var suffix: usize = 2;
    while (suffix < 1000) : (suffix += 1) {
        const candidate = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ base, suffix });
        errdefer allocator.free(candidate);
        if (!(try projectColumnRefExists(db, project_id, candidate))) return candidate;
        allocator.free(candidate);
    }
    return try std.fmt.allocPrint(allocator, "{s}-{d}", .{ base, suffix });
}

fn projectColumnRefExists(db: *SqliteDb, project_id: []const u8, column_ref: []const u8) !bool {
    var stmt = try db.prepare("SELECT 1 FROM project_columns WHERE project_id = ? AND column_ref = ? LIMIT 1");
    defer stmt.deinit();
    try stmt.bindText(1, project_id);
    try stmt.bindText(2, column_ref);
    return try stmt.step();
}

fn applyProjectFieldCreated(
    allocator: Allocator,
    db: *SqliteDb,
    payload: std.json.ObjectMap,
    project_id: []const u8,
    event_hash: []const u8,
    envelope: ValidatedEnvelope,
) !?[]const u8 {
    const field_id = event_json.jsonString(payload.get("field_id")) orelse return "invalid_event_envelope";
    const key = event_json.jsonString(payload.get("key")) orelse return "invalid_event_envelope";
    const name = event_json.jsonString(payload.get("name")) orelse return "invalid_event_envelope";
    const field_type = event_json.jsonString(payload.get("type")) orelse return "invalid_event_envelope";
    const position = jsonInteger(payload.get("position")) orelse 0;
    const required = jsonBool(payload.get("required")) orelse false;
    const default_value_json = try jsonValueOrDefaultOwned(allocator, payload.get("default_value"), "null");
    defer allocator.free(default_value_json);
    const state = event_json.jsonString(payload.get("state")) orelse "active";

    var stmt = try db.prepare(
        \\INSERT OR IGNORE INTO project_fields(
        \\  id, project_id, key, name, field_type, position, required, default_value_json,
        \\  state, created_at, actor_principal, event_hash
        \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    );
    defer stmt.deinit();
    try stmt.bindText(1, field_id);
    try stmt.bindText(2, project_id);
    try stmt.bindText(3, key);
    try stmt.bindText(4, name);
    try stmt.bindText(5, field_type);
    try stmt.bindInt64(6, position);
    try stmt.bindInt64(7, if (required) 1 else 0);
    try stmt.bindText(8, default_value_json);
    try stmt.bindText(9, state);
    try stmt.bindText(10, envelope.occurred_at);
    try stmt.bindText(11, envelope.actor_principal);
    try stmt.bindText(12, event_hash);
    try stmt.stepDone();
    return try projectFieldLimitRejection(db, project_id);
}

fn applyProjectFieldUpdated(
    allocator: Allocator,
    db: *SqliteDb,
    payload: std.json.ObjectMap,
    project_id: []const u8,
    event_hash: []const u8,
    envelope: ValidatedEnvelope,
) !?[]const u8 {
    const field_id = event_json.jsonString(payload.get("field_id")) orelse return "invalid_event_envelope";
    var current = try loadProjectField(allocator, db, project_id, field_id) orelse return "object_not_created";
    defer current.deinit(allocator);
    if (!(try eventWins(allocator, event_hash, current.event_hash))) return null;

    const key = event_json.jsonString(payload.get("key")) orelse current.key;
    const name = event_json.jsonString(payload.get("name")) orelse current.name;
    const field_type = event_json.jsonString(payload.get("type")) orelse current.field_type;
    const position = jsonInteger(payload.get("position")) orelse current.position;
    const required = jsonBool(payload.get("required")) orelse current.required;
    const default_value_json = try jsonValueOrDefaultOwned(allocator, payload.get("default_value"), current.default_value_json);
    defer allocator.free(default_value_json);
    const state = event_json.jsonString(payload.get("state")) orelse current.state;

    if (try projectFieldKeyInUse(db, project_id, key, field_id)) return "duplicate_project_field_key";

    var stmt = try db.prepare(
        \\UPDATE project_fields
        \\SET key = ?, name = ?, field_type = ?, position = ?, required = ?, default_value_json = ?,
        \\    state = ?, actor_principal = ?, event_hash = ?
        \\WHERE id = ? AND project_id = ?
    );
    defer stmt.deinit();
    try stmt.bindText(1, key);
    try stmt.bindText(2, name);
    try stmt.bindText(3, field_type);
    try stmt.bindInt64(4, position);
    try stmt.bindInt64(5, if (required) 1 else 0);
    try stmt.bindText(6, default_value_json);
    try stmt.bindText(7, state);
    try stmt.bindText(8, envelope.actor_principal);
    try stmt.bindText(9, event_hash);
    try stmt.bindText(10, field_id);
    try stmt.bindText(11, project_id);
    try stmt.stepDone();
    return try projectFieldLimitRejection(db, project_id);
}

fn updateProjectFieldState(allocator: Allocator, db: *SqliteDb, project_id: []const u8, field_id: []const u8, state: []const u8, event_hash: []const u8, envelope: ValidatedEnvelope) !void {
    var current = try loadProjectField(allocator, db, project_id, field_id) orelse return;
    defer current.deinit(allocator);
    if (!(try eventWins(allocator, event_hash, current.event_hash))) return;
    var stmt = try db.prepare("UPDATE project_fields SET state = ?, actor_principal = ?, event_hash = ? WHERE id = ? AND project_id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, state);
    try stmt.bindText(2, envelope.actor_principal);
    try stmt.bindText(3, event_hash);
    try stmt.bindText(4, field_id);
    try stmt.bindText(5, project_id);
    try stmt.stepDone();
}

const ProjectFieldRow = struct {
    key: []u8,
    name: []u8,
    field_type: []u8,
    position: i64,
    required: bool,
    default_value_json: []u8,
    state: []u8,
    event_hash: []u8,

    fn deinit(self: *ProjectFieldRow, allocator: Allocator) void {
        allocator.free(self.key);
        allocator.free(self.name);
        allocator.free(self.field_type);
        allocator.free(self.default_value_json);
        allocator.free(self.state);
        allocator.free(self.event_hash);
    }
};

fn loadProjectField(allocator: Allocator, db: *SqliteDb, project_id: []const u8, field_id: []const u8) !?ProjectFieldRow {
    var stmt = try db.prepare(
        \\SELECT key, name, field_type, position, required, default_value_json, state, event_hash
        \\FROM project_fields
        \\WHERE project_id = ? AND id = ?
    );
    defer stmt.deinit();
    try stmt.bindText(1, project_id);
    try stmt.bindText(2, field_id);
    if (!(try stmt.step())) return null;
    return .{
        .key = try stmt.columnTextDup(allocator, 0),
        .name = try stmt.columnTextDup(allocator, 1),
        .field_type = try stmt.columnTextDup(allocator, 2),
        .position = stmt.columnInt64(3),
        .required = stmt.columnInt64(4) != 0,
        .default_value_json = try stmt.columnTextDup(allocator, 5),
        .state = try stmt.columnTextDup(allocator, 6),
        .event_hash = try stmt.columnTextDup(allocator, 7),
    };
}

fn applyProjectFieldOptionAdded(
    db: *SqliteDb,
    payload: std.json.ObjectMap,
    project_id: []const u8,
    event_hash: []const u8,
    envelope: ValidatedEnvelope,
) !?[]const u8 {
    const field_id = event_json.jsonString(payload.get("field_id")) orelse return "invalid_event_envelope";
    if (!(try projectFieldExists(db, project_id, field_id))) return "object_not_created";
    const option_id = event_json.jsonString(payload.get("option_id")) orelse return "invalid_event_envelope";
    const name = event_json.jsonString(payload.get("name")) orelse return "invalid_event_envelope";
    const color = event_json.jsonString(payload.get("color")) orelse "";
    const position = jsonInteger(payload.get("position")) orelse 0;
    const state = event_json.jsonString(payload.get("state")) orelse "active";

    var stmt = try db.prepare(
        \\INSERT OR IGNORE INTO project_field_options(
        \\  id, project_id, field_id, name, color, position, state, created_at, actor_principal, event_hash
        \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    );
    defer stmt.deinit();
    try stmt.bindText(1, option_id);
    try stmt.bindText(2, project_id);
    try stmt.bindText(3, field_id);
    try stmt.bindText(4, name);
    try stmt.bindText(5, color);
    try stmt.bindInt64(6, position);
    try stmt.bindText(7, state);
    try stmt.bindText(8, envelope.occurred_at);
    try stmt.bindText(9, envelope.actor_principal);
    try stmt.bindText(10, event_hash);
    try stmt.stepDone();
    return try projectFieldOptionLimitRejection(db, field_id);
}

fn applyProjectFieldOptionUpdated(
    allocator: Allocator,
    db: *SqliteDb,
    payload: std.json.ObjectMap,
    project_id: []const u8,
    event_hash: []const u8,
    envelope: ValidatedEnvelope,
) !?[]const u8 {
    const field_id = event_json.jsonString(payload.get("field_id")) orelse return "invalid_event_envelope";
    const option_id = event_json.jsonString(payload.get("option_id")) orelse return "invalid_event_envelope";
    var current = try loadProjectFieldOption(allocator, db, project_id, field_id, option_id) orelse return "object_not_created";
    defer current.deinit(allocator);
    if (!(try eventWins(allocator, event_hash, current.event_hash))) return null;
    const name = event_json.jsonString(payload.get("name")) orelse current.name;
    const color = event_json.jsonString(payload.get("color")) orelse current.color;
    const position = jsonInteger(payload.get("position")) orelse current.position;
    const state = event_json.jsonString(payload.get("state")) orelse current.state;

    var stmt = try db.prepare(
        \\UPDATE project_field_options
        \\SET name = ?, color = ?, position = ?, state = ?, actor_principal = ?, event_hash = ?
        \\WHERE project_id = ? AND field_id = ? AND id = ?
    );
    defer stmt.deinit();
    try stmt.bindText(1, name);
    try stmt.bindText(2, color);
    try stmt.bindInt64(3, position);
    try stmt.bindText(4, state);
    try stmt.bindText(5, envelope.actor_principal);
    try stmt.bindText(6, event_hash);
    try stmt.bindText(7, project_id);
    try stmt.bindText(8, field_id);
    try stmt.bindText(9, option_id);
    try stmt.stepDone();
    return try projectFieldOptionLimitRejection(db, field_id);
}

fn updateProjectFieldOptionState(allocator: Allocator, db: *SqliteDb, project_id: []const u8, field_id: []const u8, option_id: []const u8, state: []const u8, event_hash: []const u8, envelope: ValidatedEnvelope) !void {
    var current = try loadProjectFieldOption(allocator, db, project_id, field_id, option_id) orelse return;
    defer current.deinit(allocator);
    if (!(try eventWins(allocator, event_hash, current.event_hash))) return;
    var stmt = try db.prepare("UPDATE project_field_options SET state = ?, actor_principal = ?, event_hash = ? WHERE project_id = ? AND field_id = ? AND id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, state);
    try stmt.bindText(2, envelope.actor_principal);
    try stmt.bindText(3, event_hash);
    try stmt.bindText(4, project_id);
    try stmt.bindText(5, field_id);
    try stmt.bindText(6, option_id);
    try stmt.stepDone();
}

const ProjectFieldOptionRow = struct {
    name: []u8,
    color: []u8,
    position: i64,
    state: []u8,
    event_hash: []u8,

    fn deinit(self: *ProjectFieldOptionRow, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.color);
        allocator.free(self.state);
        allocator.free(self.event_hash);
    }
};

fn loadProjectFieldOption(allocator: Allocator, db: *SqliteDb, project_id: []const u8, field_id: []const u8, option_id: []const u8) !?ProjectFieldOptionRow {
    var stmt = try db.prepare(
        \\SELECT name, color, position, state, event_hash
        \\FROM project_field_options
        \\WHERE project_id = ? AND field_id = ? AND id = ?
    );
    defer stmt.deinit();
    try stmt.bindText(1, project_id);
    try stmt.bindText(2, field_id);
    try stmt.bindText(3, option_id);
    if (!(try stmt.step())) return null;
    return .{
        .name = try stmt.columnTextDup(allocator, 0),
        .color = try stmt.columnTextDup(allocator, 1),
        .position = stmt.columnInt64(2),
        .state = try stmt.columnTextDup(allocator, 3),
        .event_hash = try stmt.columnTextDup(allocator, 4),
    };
}

fn applyProjectViewCreated(
    allocator: Allocator,
    db: *SqliteDb,
    payload: std.json.ObjectMap,
    project_id: []const u8,
    event_hash: []const u8,
    envelope: ValidatedEnvelope,
) !?[]const u8 {
    const view_id = event_json.jsonString(payload.get("view_id")) orelse return "invalid_event_envelope";
    const name = event_json.jsonString(payload.get("name")) orelse return "invalid_event_envelope";
    const layout = event_json.jsonString(payload.get("layout")) orelse return "invalid_event_envelope";
    const position = jsonInteger(payload.get("position")) orelse 0;
    const config_json = try jsonValueOrDefaultOwned(allocator, payload.get("config"), "{}");
    defer allocator.free(config_json);
    const state = event_json.jsonString(payload.get("state")) orelse "active";

    var stmt = try db.prepare(
        \\INSERT OR IGNORE INTO project_views(
        \\  id, project_id, name, layout, position, config_json, state, created_at, actor_principal, event_hash
        \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    );
    defer stmt.deinit();
    try stmt.bindText(1, view_id);
    try stmt.bindText(2, project_id);
    try stmt.bindText(3, name);
    try stmt.bindText(4, layout);
    try stmt.bindInt64(5, position);
    try stmt.bindText(6, config_json);
    try stmt.bindText(7, state);
    try stmt.bindText(8, envelope.occurred_at);
    try stmt.bindText(9, envelope.actor_principal);
    try stmt.bindText(10, event_hash);
    try stmt.stepDone();
    return try projectViewLimitRejection(db, project_id);
}

fn applyProjectViewUpdated(
    allocator: Allocator,
    db: *SqliteDb,
    payload: std.json.ObjectMap,
    project_id: []const u8,
    event_hash: []const u8,
    envelope: ValidatedEnvelope,
) !?[]const u8 {
    const view_id = event_json.jsonString(payload.get("view_id")) orelse return "invalid_event_envelope";
    var current = try loadProjectView(allocator, db, project_id, view_id) orelse return "object_not_created";
    defer current.deinit(allocator);
    if (!(try eventWins(allocator, event_hash, current.event_hash))) return null;
    const name = event_json.jsonString(payload.get("name")) orelse current.name;
    const layout = event_json.jsonString(payload.get("layout")) orelse current.layout;
    const position = jsonInteger(payload.get("position")) orelse current.position;
    const config_json = try jsonValueOrDefaultOwned(allocator, payload.get("config"), current.config_json);
    defer allocator.free(config_json);
    const state = event_json.jsonString(payload.get("state")) orelse current.state;

    var stmt = try db.prepare(
        \\UPDATE project_views
        \\SET name = ?, layout = ?, position = ?, config_json = ?, state = ?, actor_principal = ?, event_hash = ?
        \\WHERE project_id = ? AND id = ?
    );
    defer stmt.deinit();
    try stmt.bindText(1, name);
    try stmt.bindText(2, layout);
    try stmt.bindInt64(3, position);
    try stmt.bindText(4, config_json);
    try stmt.bindText(5, state);
    try stmt.bindText(6, envelope.actor_principal);
    try stmt.bindText(7, event_hash);
    try stmt.bindText(8, project_id);
    try stmt.bindText(9, view_id);
    try stmt.stepDone();
    return try projectViewLimitRejection(db, project_id);
}

fn updateProjectViewState(allocator: Allocator, db: *SqliteDb, project_id: []const u8, view_id: []const u8, state: []const u8, event_hash: []const u8, envelope: ValidatedEnvelope) !void {
    var current = try loadProjectView(allocator, db, project_id, view_id) orelse return;
    defer current.deinit(allocator);
    if (!(try eventWins(allocator, event_hash, current.event_hash))) return;
    var stmt = try db.prepare("UPDATE project_views SET state = ?, actor_principal = ?, event_hash = ? WHERE project_id = ? AND id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, state);
    try stmt.bindText(2, envelope.actor_principal);
    try stmt.bindText(3, event_hash);
    try stmt.bindText(4, project_id);
    try stmt.bindText(5, view_id);
    try stmt.stepDone();
}

const ProjectViewRow = struct {
    name: []u8,
    layout: []u8,
    position: i64,
    config_json: []u8,
    state: []u8,
    event_hash: []u8,

    fn deinit(self: *ProjectViewRow, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.layout);
        allocator.free(self.config_json);
        allocator.free(self.state);
        allocator.free(self.event_hash);
    }
};

fn loadProjectView(allocator: Allocator, db: *SqliteDb, project_id: []const u8, view_id: []const u8) !?ProjectViewRow {
    var stmt = try db.prepare(
        \\SELECT name, layout, position, config_json, state, event_hash
        \\FROM project_views
        \\WHERE project_id = ? AND id = ?
    );
    defer stmt.deinit();
    try stmt.bindText(1, project_id);
    try stmt.bindText(2, view_id);
    if (!(try stmt.step())) return null;
    return .{
        .name = try stmt.columnTextDup(allocator, 0),
        .layout = try stmt.columnTextDup(allocator, 1),
        .position = stmt.columnInt64(2),
        .config_json = try stmt.columnTextDup(allocator, 3),
        .state = try stmt.columnTextDup(allocator, 4),
        .event_hash = try stmt.columnTextDup(allocator, 5),
    };
}

pub fn applyIssueProjectFieldSet(
    allocator: Allocator,
    db: *SqliteDb,
    issue_id: []const u8,
    payload: std.json.ObjectMap,
    event_hash: []const u8,
    envelope: ValidatedEnvelope,
) !?[]const u8 {
    const project_id = (try projectIdFromPayload(allocator, db, payload)) orelse return "object_not_created";
    defer allocator.free(project_id);
    if (!(try projectMembershipExists(db, project_id, issue_id))) return "object_not_created";
    const field_id = (try projectFieldIdFromPayload(allocator, db, project_id, payload)) orelse return "object_not_created";
    defer allocator.free(field_id);
    const value = payload.get("value") orelse return "invalid_event_envelope";
    const value_json = try jsonValueOwned(allocator, value);
    defer allocator.free(value_json);
    if (!(try projectFieldValueWins(allocator, db, project_id, issue_id, field_id, event_hash))) return null;

    var stmt = try db.prepare(
        \\INSERT INTO project_field_values(project_id, issue_id, field_id, value_json, occurred_at, actor_principal, event_hash)
        \\VALUES (?, ?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(project_id, issue_id, field_id) DO UPDATE SET
        \\  value_json = excluded.value_json,
        \\  occurred_at = excluded.occurred_at,
        \\  actor_principal = excluded.actor_principal,
        \\  event_hash = excluded.event_hash
    );
    defer stmt.deinit();
    try stmt.bindText(1, project_id);
    try stmt.bindText(2, issue_id);
    try stmt.bindText(3, field_id);
    try stmt.bindText(4, value_json);
    try stmt.bindText(5, envelope.occurred_at);
    try stmt.bindText(6, envelope.actor_principal);
    try stmt.bindText(7, event_hash);
    try stmt.stepDone();

    if (try projectFieldKeyIs(db, field_id, "status")) {
        if (value == .string) try replaceLegacyIssueProjectStatus(allocator, db, project_id, issue_id, value.string, event_hash);
    }
    return null;
}

pub fn applyIssueProjectFieldClear(
    allocator: Allocator,
    db: *SqliteDb,
    issue_id: []const u8,
    payload: std.json.ObjectMap,
    event_hash: []const u8,
) !?[]const u8 {
    const project_id = (try projectIdFromPayload(allocator, db, payload)) orelse return "object_not_created";
    defer allocator.free(project_id);
    const field_id = (try projectFieldIdFromPayload(allocator, db, project_id, payload)) orelse return "object_not_created";
    defer allocator.free(field_id);
    if (!(try projectFieldValueWins(allocator, db, project_id, issue_id, field_id, event_hash))) return null;
    var stmt = try db.prepare("DELETE FROM project_field_values WHERE project_id = ? AND issue_id = ? AND field_id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, project_id);
    try stmt.bindText(2, issue_id);
    try stmt.bindText(3, field_id);
    try stmt.stepDone();
    if (try projectFieldKeyIs(db, field_id, "status")) {
        try deleteLegacyIssueProjectStatus(allocator, db, project_id, issue_id);
    }
    return null;
}

pub fn insertProjectMembership(db: *SqliteDb, project_id: []const u8, issue_id: []const u8, event_hash: []const u8, envelope: ValidatedEnvelope) !void {
    var stmt = try db.prepare("INSERT OR IGNORE INTO project_memberships(project_id, issue_id, add_hash, created_at, actor_principal) VALUES (?, ?, ?, ?, ?)");
    defer stmt.deinit();
    try stmt.bindText(1, project_id);
    try stmt.bindText(2, issue_id);
    try stmt.bindText(3, event_hash);
    try stmt.bindText(4, envelope.occurred_at);
    try stmt.bindText(5, envelope.actor_principal);
    try stmt.stepDone();
}

pub fn deleteProjectMembership(allocator: Allocator, db: *SqliteDb, project_id: []const u8, issue_id: []const u8, remove_hash: []const u8) !void {
    var select = try db.prepare("SELECT add_hash FROM project_memberships WHERE project_id = ? AND issue_id = ?");
    defer select.deinit();
    try select.bindText(1, project_id);
    try select.bindText(2, issue_id);
    while (try select.step()) {
        const add_hash = try select.columnTextDup(allocator, 0);
        defer allocator.free(add_hash);
        if (!(try git.isAncestor(allocator, add_hash, remove_hash))) continue;
        var delete = try db.prepare("DELETE FROM project_memberships WHERE project_id = ? AND issue_id = ? AND add_hash = ?");
        defer delete.deinit();
        try delete.bindText(1, project_id);
        try delete.bindText(2, issue_id);
        try delete.bindText(3, add_hash);
        try delete.stepDone();
    }
}

fn projectMembershipExists(db: *SqliteDb, project_id: []const u8, issue_id: []const u8) !bool {
    var stmt = try db.prepare("SELECT 1 FROM project_memberships WHERE project_id = ? AND issue_id = ? LIMIT 1");
    defer stmt.deinit();
    try stmt.bindText(1, project_id);
    try stmt.bindText(2, issue_id);
    return try stmt.step();
}

fn projectFieldExists(db: *SqliteDb, project_id: []const u8, field_id: []const u8) !bool {
    var stmt = try db.prepare("SELECT 1 FROM project_fields WHERE project_id = ? AND id = ? LIMIT 1");
    defer stmt.deinit();
    try stmt.bindText(1, project_id);
    try stmt.bindText(2, field_id);
    return try stmt.step();
}

fn projectFieldKeyInUse(db: *SqliteDb, project_id: []const u8, key: []const u8, except_id: ?[]const u8) !bool {
    var stmt = try db.prepare(
        \\SELECT 1
        \\FROM project_fields
        \\WHERE project_id = ?
        \\  AND key = ?
        \\  AND (? = '' OR id != ?)
        \\LIMIT 1
    );
    defer stmt.deinit();
    const excluded = except_id orelse "";
    try stmt.bindText(1, project_id);
    try stmt.bindText(2, key);
    try stmt.bindText(3, excluded);
    try stmt.bindText(4, excluded);
    return try stmt.step();
}

fn projectIdFromPayload(allocator: Allocator, db: *SqliteDb, payload: std.json.ObjectMap) !?[]u8 {
    if (event_json.jsonString(payload.get("project_id"))) |project_id| {
        if (try projectExists(db, project_id)) return try allocator.dupe(u8, project_id);
        return null;
    }
    if (event_json.jsonString(payload.get("project_ref"))) |project_ref| {
        return try resolveProjectIdInDb(allocator, db, project_ref);
    }
    return null;
}

pub fn projectIdFromPayloadOrName(allocator: Allocator, db: *SqliteDb, payload: std.json.ObjectMap, project_name: []const u8) !?[]u8 {
    if (try projectIdFromPayload(allocator, db, payload)) |project_id| return project_id;
    return try resolveProjectIdInDb(allocator, db, project_name);
}

fn resolveProjectIdInDb(allocator: Allocator, db: *SqliteDb, raw_ref: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, raw_ref, " \t\r\n");
    const without_prefix = if (std.mem.startsWith(u8, trimmed, "project:"))
        trimmed["project:".len..]
    else if (std.mem.startsWith(u8, trimmed, "@"))
        trimmed[1..]
    else
        trimmed;
    const slash = std.mem.indexOfScalar(u8, without_prefix, '/') orelse without_prefix.len;
    const value = without_prefix[0..slash];
    if (value.len == 0) return null;

    if (util.looksLikeUuid(value)) {
        if (try projectExists(db, value)) return try allocator.dupe(u8, value);
    }
    if (isUuidPrefix(value)) {
        if (try resolveUniqueProjectByColumn(allocator, db, "id", value)) |id| return id;
    }
    if (try resolveUniqueProjectByColumn(allocator, db, "slug", value)) |id| return id;
    if (try resolveUniqueProjectByColumn(allocator, db, "name", value)) |id| return id;
    return null;
}

fn resolveUniqueProjectByColumn(allocator: Allocator, db: *SqliteDb, comptime column: []const u8, value: []const u8) !?[]u8 {
    const sql = if (std.mem.eql(u8, column, "id"))
        "SELECT id FROM projects WHERE id LIKE ? ORDER BY id LIMIT 2"
    else
        "SELECT id FROM projects WHERE " ++ column ++ " = ? ORDER BY id LIMIT 2";
    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    if (std.mem.eql(u8, column, "id")) {
        const pattern = try std.fmt.allocPrint(allocator, "{s}%", .{value});
        defer allocator.free(pattern);
        try stmt.bindText(1, pattern);
    } else {
        try stmt.bindText(1, value);
    }
    if (!(try stmt.step())) return null;
    const first = try stmt.columnTextDup(allocator, 0);
    errdefer allocator.free(first);
    if (try stmt.step()) {
        allocator.free(first);
        return null;
    }
    return first;
}

fn projectFieldIdFromPayload(allocator: Allocator, db: *SqliteDb, project_id: []const u8, payload: std.json.ObjectMap) !?[]u8 {
    if (event_json.jsonString(payload.get("field_id"))) |field_id| {
        if (try projectFieldExists(db, project_id, field_id)) return try allocator.dupe(u8, field_id);
        return null;
    }
    if (event_json.jsonString(payload.get("field_key"))) |field_key| {
        var stmt = try db.prepare("SELECT id FROM project_fields WHERE project_id = ? AND key = ? AND state != 'removed' ORDER BY id LIMIT 2");
        defer stmt.deinit();
        try stmt.bindText(1, project_id);
        try stmt.bindText(2, field_key);
        if (!(try stmt.step())) return null;
        const first = try stmt.columnTextDup(allocator, 0);
        errdefer allocator.free(first);
        if (try stmt.step()) return null;
        return first;
    }
    return null;
}

pub fn setStatusFieldValueIfPresent(allocator: Allocator, db: *SqliteDb, project_id: []const u8, issue_id: []const u8, value: []const u8, event_hash: []const u8, envelope: ValidatedEnvelope) !void {
    const field_id = (try projectFieldIdByKey(allocator, db, project_id, "status")) orelse return;
    defer allocator.free(field_id);
    if (!(try projectFieldValueWins(allocator, db, project_id, issue_id, field_id, event_hash))) return;
    const value_json = try jsonStringValueOwned(allocator, value);
    defer allocator.free(value_json);
    var stmt = try db.prepare(
        \\INSERT INTO project_field_values(project_id, issue_id, field_id, value_json, occurred_at, actor_principal, event_hash)
        \\VALUES (?, ?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(project_id, issue_id, field_id) DO UPDATE SET
        \\  value_json = excluded.value_json,
        \\  occurred_at = excluded.occurred_at,
        \\  actor_principal = excluded.actor_principal,
        \\  event_hash = excluded.event_hash
    );
    defer stmt.deinit();
    try stmt.bindText(1, project_id);
    try stmt.bindText(2, issue_id);
    try stmt.bindText(3, field_id);
    try stmt.bindText(4, value_json);
    try stmt.bindText(5, envelope.occurred_at);
    try stmt.bindText(6, envelope.actor_principal);
    try stmt.bindText(7, event_hash);
    try stmt.stepDone();
}

pub fn clearStatusFieldValueIfPresent(allocator: Allocator, db: *SqliteDb, project_id: []const u8, issue_id: []const u8, event_hash: []const u8) !void {
    const field_id = (try projectFieldIdByKey(allocator, db, project_id, "status")) orelse return;
    defer allocator.free(field_id);
    if (!(try projectFieldValueWins(allocator, db, project_id, issue_id, field_id, event_hash))) return;
    var stmt = try db.prepare("DELETE FROM project_field_values WHERE project_id = ? AND issue_id = ? AND field_id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, project_id);
    try stmt.bindText(2, issue_id);
    try stmt.bindText(3, field_id);
    try stmt.stepDone();
}

fn projectFieldIdByKey(allocator: Allocator, db: *SqliteDb, project_id: []const u8, key: []const u8) !?[]u8 {
    var stmt = try db.prepare("SELECT id FROM project_fields WHERE project_id = ? AND key = ? AND state != 'removed' ORDER BY id LIMIT 1");
    defer stmt.deinit();
    try stmt.bindText(1, project_id);
    try stmt.bindText(2, key);
    if (!(try stmt.step())) return null;
    return try stmt.columnTextDup(allocator, 0);
}

fn projectFieldValueWins(allocator: Allocator, db: *SqliteDb, project_id: []const u8, issue_id: []const u8, field_id: []const u8, event_hash: []const u8) !bool {
    var stmt = try db.prepare("SELECT event_hash FROM project_field_values WHERE project_id = ? AND issue_id = ? AND field_id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, project_id);
    try stmt.bindText(2, issue_id);
    try stmt.bindText(3, field_id);
    if (!(try stmt.step())) return true;
    const old_event_hash = try stmt.columnTextDup(allocator, 0);
    defer allocator.free(old_event_hash);
    return try eventWins(allocator, event_hash, old_event_hash);
}

fn projectFieldKeyIs(db: *SqliteDb, field_id: []const u8, expected: []const u8) !bool {
    var stmt = try db.prepare("SELECT 1 FROM project_fields WHERE id = ? AND key = ? LIMIT 1");
    defer stmt.deinit();
    try stmt.bindText(1, field_id);
    try stmt.bindText(2, expected);
    return try stmt.step();
}

fn replaceLegacyIssueProjectStatus(allocator: Allocator, db: *SqliteDb, project_id: []const u8, issue_id: []const u8, column: []const u8, event_hash: []const u8) !void {
    const project_name = (try projectNameById(allocator, db, project_id)) orelse return;
    defer allocator.free(project_name);
    try deleteLegacyIssueProjectStatusByName(db, project_name, issue_id);
    try insertIssueProject(db, issue_id, project_name, column, event_hash);
}

fn deleteLegacyIssueProjectStatus(allocator: Allocator, db: *SqliteDb, project_id: []const u8, issue_id: []const u8) !void {
    const project_name = (try projectNameById(allocator, db, project_id)) orelse return;
    defer allocator.free(project_name);
    try deleteLegacyIssueProjectStatusByName(db, project_name, issue_id);
}

fn deleteLegacyIssueProjectStatusByName(db: *SqliteDb, project_name: []const u8, issue_id: []const u8) !void {
    var stmt = try db.prepare("DELETE FROM issue_projects WHERE project = ? AND issue_id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, project_name);
    try stmt.bindText(2, issue_id);
    try stmt.stepDone();
}

fn projectNameById(allocator: Allocator, db: *SqliteDb, project_id: []const u8) !?[]u8 {
    var stmt = try db.prepare("SELECT name FROM projects WHERE id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, project_id);
    if (!(try stmt.step())) return null;
    return try stmt.columnTextDup(allocator, 0);
}
