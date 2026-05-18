const std = @import("std");

const common = @import("common.zig");

const event_json = common.event_json;
const Allocator = common.Allocator;
const SqliteDb = common.SqliteDb;
const ValidatedEnvelope = common.ValidatedEnvelope;
const creationEventWins = common.creationEventWins;
const acceptedCreationInFrontier = common.acceptedCreationInFrontier;
const eventWins = common.eventWins;

pub fn applyLabelProjection(allocator: Allocator, db: *SqliteDb, event_hash: []const u8, envelope: ValidatedEnvelope, body: []const u8) !?[]const u8 {
    if (!std.mem.startsWith(u8, envelope.event_type, "label.")) return null;

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

    if (std.mem.eql(u8, envelope.event_type, "label.created")) {
        if (!(try creationEventWins(db, "label.created", envelope.object_id, event_hash))) return "duplicate_object_id";
        const name = event_json.jsonString(payload.get("name")) orelse return "invalid_event_envelope";
        if (std.mem.trim(u8, name, " \t\r\n").len == 0) return "invalid_event_envelope";
        if (try labelNameInUse(db, name, null)) return "duplicate_label_name";
        const description = event_json.jsonString(payload.get("description")) orelse "";
        const color = event_json.jsonString(payload.get("color")) orelse "#6e7681";
        const priority = event_json.jsonInteger(payload.get("priority")) orelse event_json.jsonInteger(payload.get("position")) orelse 0;
        try insertLabelCreated(db, event_hash, envelope, name, description, color, priority);
        return null;
    }

    if (!(try acceptedCreationInFrontier(allocator, db, "label.created", envelope.object_id, event_hash))) return "object_not_created";

    if (std.mem.eql(u8, envelope.event_type, "label.updated")) {
        if (event_json.jsonString(payload.get("name"))) |name| {
            if (std.mem.trim(u8, name, " \t\r\n").len == 0) return "invalid_event_envelope";
            if (try labelNameInUse(db, name, envelope.object_id)) return "duplicate_label_name";
            try updateLabelScalar(allocator, db, envelope.object_id, name, event_hash, envelope, "name", "name_occurred_at", "name_actor_principal", "name_event_hash");
        }
        if (event_json.jsonString(payload.get("description"))) |description| {
            try updateLabelScalar(allocator, db, envelope.object_id, description, event_hash, envelope, "description", "description_occurred_at", "description_actor_principal", "description_event_hash");
        }
        if (event_json.jsonString(payload.get("color"))) |color| {
            try updateLabelScalar(allocator, db, envelope.object_id, color, event_hash, envelope, "color", "color_occurred_at", "color_actor_principal", "color_event_hash");
        }
        const priority = event_json.jsonInteger(payload.get("priority")) orelse event_json.jsonInteger(payload.get("position"));
        if (priority) |value| {
            try updateLabelIntegerScalar(allocator, db, envelope.object_id, value, event_hash, envelope, "priority", "priority_occurred_at", "priority_actor_principal", "priority_event_hash");
        }
    } else if (std.mem.eql(u8, envelope.event_type, "label.deleted")) {
        try deleteLabelDefinition(db, envelope.object_id);
    } else {
        return "unknown_event_type";
    }
    return null;
}

fn insertLabelCreated(db: *SqliteDb, event_hash: []const u8, envelope: ValidatedEnvelope, name: []const u8, description: []const u8, color: []const u8, priority: i64) !void {
    var stmt = try db.prepare(
        \\INSERT OR IGNORE INTO label_definitions(
        \\  id,
        \\  name, name_occurred_at, name_actor_principal, name_event_hash,
        \\  description, description_occurred_at, description_actor_principal, description_event_hash,
        \\  color, color_occurred_at, color_actor_principal, color_event_hash,
        \\  priority, priority_occurred_at, priority_actor_principal, priority_event_hash,
        \\  created_at, author_principal, author_device
        \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    );
    defer stmt.deinit();
    try stmt.bindText(1, envelope.object_id);
    try stmt.bindText(2, name);
    try stmt.bindText(3, envelope.occurred_at);
    try stmt.bindText(4, envelope.actor_principal);
    try stmt.bindText(5, event_hash);
    try stmt.bindText(6, description);
    try stmt.bindText(7, envelope.occurred_at);
    try stmt.bindText(8, envelope.actor_principal);
    try stmt.bindText(9, event_hash);
    try stmt.bindText(10, color);
    try stmt.bindText(11, envelope.occurred_at);
    try stmt.bindText(12, envelope.actor_principal);
    try stmt.bindText(13, event_hash);
    try stmt.bindInt64(14, priority);
    try stmt.bindText(15, envelope.occurred_at);
    try stmt.bindText(16, envelope.actor_principal);
    try stmt.bindText(17, event_hash);
    try stmt.bindText(18, envelope.occurred_at);
    try stmt.bindText(19, envelope.actor_principal);
    try stmt.bindText(20, envelope.actor_device);
    try stmt.stepDone();
}

fn labelDefinitionExists(db: *SqliteDb, label_id: []const u8) !bool {
    var stmt = try db.prepare("SELECT 1 FROM label_definitions WHERE id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, label_id);
    return try stmt.step();
}

fn labelNameInUse(db: *SqliteDb, name: []const u8, except_id: ?[]const u8) !bool {
    var stmt = try db.prepare(
        \\SELECT 1
        \\FROM label_definitions
        \\WHERE name = ?
        \\  AND (? = '' OR id != ?)
        \\LIMIT 1
    );
    defer stmt.deinit();
    const excluded = except_id orelse "";
    try stmt.bindText(1, name);
    try stmt.bindText(2, excluded);
    try stmt.bindText(3, excluded);
    return try stmt.step();
}

fn updateLabelScalar(
    allocator: Allocator,
    db: *SqliteDb,
    label_id: []const u8,
    value: []const u8,
    event_hash: []const u8,
    envelope: ValidatedEnvelope,
    comptime value_col: []const u8,
    comptime occurred_at_col: []const u8,
    comptime actor_col: []const u8,
    comptime event_hash_col: []const u8,
) !void {
    var select = try db.prepare("SELECT " ++ occurred_at_col ++ ", " ++ actor_col ++ ", " ++ event_hash_col ++ " FROM label_definitions WHERE id = ?");
    defer select.deinit();
    try select.bindText(1, label_id);
    if (!(try select.step())) return;
    const old_occurred_at = try select.columnTextDup(allocator, 0);
    defer allocator.free(old_occurred_at);
    const old_actor = try select.columnTextDup(allocator, 1);
    defer allocator.free(old_actor);
    const old_event_hash = try select.columnTextDup(allocator, 2);
    defer allocator.free(old_event_hash);

    if (!(try eventWins(allocator, event_hash, old_event_hash))) return;

    var update = try db.prepare("UPDATE label_definitions SET " ++ value_col ++ " = ?, " ++ occurred_at_col ++ " = ?, " ++ actor_col ++ " = ?, " ++ event_hash_col ++ " = ? WHERE id = ?");
    defer update.deinit();
    try update.bindText(1, value);
    try update.bindText(2, envelope.occurred_at);
    try update.bindText(3, envelope.actor_principal);
    try update.bindText(4, event_hash);
    try update.bindText(5, label_id);
    try update.stepDone();
}

fn updateLabelIntegerScalar(
    allocator: Allocator,
    db: *SqliteDb,
    label_id: []const u8,
    value: i64,
    event_hash: []const u8,
    envelope: ValidatedEnvelope,
    comptime value_col: []const u8,
    comptime occurred_at_col: []const u8,
    comptime actor_col: []const u8,
    comptime event_hash_col: []const u8,
) !void {
    var select = try db.prepare("SELECT " ++ occurred_at_col ++ ", " ++ actor_col ++ ", " ++ event_hash_col ++ " FROM label_definitions WHERE id = ?");
    defer select.deinit();
    try select.bindText(1, label_id);
    if (!(try select.step())) return;
    const old_occurred_at = try select.columnTextDup(allocator, 0);
    defer allocator.free(old_occurred_at);
    const old_actor = try select.columnTextDup(allocator, 1);
    defer allocator.free(old_actor);
    const old_event_hash = try select.columnTextDup(allocator, 2);
    defer allocator.free(old_event_hash);

    if (!(try eventWins(allocator, event_hash, old_event_hash))) return;

    var update = try db.prepare("UPDATE label_definitions SET " ++ value_col ++ " = ?, " ++ occurred_at_col ++ " = ?, " ++ actor_col ++ " = ?, " ++ event_hash_col ++ " = ? WHERE id = ?");
    defer update.deinit();
    try update.bindInt64(1, value);
    try update.bindText(2, envelope.occurred_at);
    try update.bindText(3, envelope.actor_principal);
    try update.bindText(4, event_hash);
    try update.bindText(5, label_id);
    try update.stepDone();
}

fn deleteLabelDefinition(db: *SqliteDb, label_id: []const u8) !void {
    var stmt = try db.prepare("DELETE FROM label_definitions WHERE id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, label_id);
    try stmt.stepDone();
}
