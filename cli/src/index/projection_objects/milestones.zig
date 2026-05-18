const std = @import("std");

const common = @import("common.zig");

const event_json = common.event_json;
const Allocator = common.Allocator;
const SqliteDb = common.SqliteDb;
const ValidatedEnvelope = common.ValidatedEnvelope;
const creationEventWins = common.creationEventWins;
const acceptedCreationInFrontier = common.acceptedCreationInFrontier;
const eventWins = common.eventWins;

pub fn applyMilestoneProjection(allocator: Allocator, db: *SqliteDb, event_hash: []const u8, envelope: ValidatedEnvelope, body: []const u8) !?[]const u8 {
    if (!std.mem.startsWith(u8, envelope.event_type, "milestone.")) return null;

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

    if (std.mem.eql(u8, envelope.event_type, "milestone.created")) {
        if (!(try creationEventWins(db, "milestone.created", envelope.object_id, event_hash))) return "duplicate_object_id";
        const title = event_json.jsonString(payload.get("title")) orelse return "invalid_event_envelope";
        const description = event_json.jsonString(payload.get("description")) orelse "";
        const due_at = event_json.jsonString(payload.get("due_at")) orelse "";
        const state = event_json.jsonString(payload.get("state")) orelse "open";
        try insertMilestoneCreated(db, event_hash, envelope, title, description, due_at, state);
        return null;
    }

    if (!(try acceptedCreationInFrontier(allocator, db, "milestone.created", envelope.object_id, event_hash))) return "object_not_created";

    if (std.mem.eql(u8, envelope.event_type, "milestone.updated")) {
        if (event_json.jsonString(payload.get("title"))) |title| {
            try updateMilestoneScalar(allocator, db, envelope.object_id, title, event_hash, envelope, "title", "title_occurred_at", "title_actor_principal", "title_event_hash");
        }
        if (event_json.jsonString(payload.get("description"))) |description| {
            try updateMilestoneScalar(allocator, db, envelope.object_id, description, event_hash, envelope, "description", "description_occurred_at", "description_actor_principal", "description_event_hash");
        }
        if (event_json.jsonString(payload.get("due_at"))) |due_at| {
            try updateMilestoneScalar(allocator, db, envelope.object_id, due_at, event_hash, envelope, "due_at", "due_at_occurred_at", "due_at_actor_principal", "due_at_event_hash");
        }
        if (event_json.jsonString(payload.get("state"))) |state| {
            try updateMilestoneScalar(allocator, db, envelope.object_id, state, event_hash, envelope, "state", "state_occurred_at", "state_actor_principal", "state_event_hash");
        }
    } else if (std.mem.eql(u8, envelope.event_type, "milestone.state_set")) {
        const state = event_json.jsonString(payload.get("state")) orelse return "invalid_event_envelope";
        try updateMilestoneScalar(allocator, db, envelope.object_id, state, event_hash, envelope, "state", "state_occurred_at", "state_actor_principal", "state_event_hash");
    } else if (std.mem.eql(u8, envelope.event_type, "milestone.deleted")) {
        try deleteMilestone(db, envelope.object_id);
    } else {
        return "unknown_event_type";
    }
    return null;
}

fn insertMilestoneCreated(db: *SqliteDb, event_hash: []const u8, envelope: ValidatedEnvelope, title: []const u8, description: []const u8, due_at: []const u8, state: []const u8) !void {
    var stmt = try db.prepare(
        \\INSERT OR IGNORE INTO milestones(
        \\  id,
        \\  title, title_occurred_at, title_actor_principal, title_event_hash,
        \\  description, description_occurred_at, description_actor_principal, description_event_hash,
        \\  due_at, due_at_occurred_at, due_at_actor_principal, due_at_event_hash,
        \\  state, state_occurred_at, state_actor_principal, state_event_hash,
        \\  created_at, author_principal, author_device
        \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    );
    defer stmt.deinit();
    try stmt.bindText(1, envelope.object_id);
    try stmt.bindText(2, title);
    try stmt.bindText(3, envelope.occurred_at);
    try stmt.bindText(4, envelope.actor_principal);
    try stmt.bindText(5, event_hash);
    try stmt.bindText(6, description);
    try stmt.bindText(7, envelope.occurred_at);
    try stmt.bindText(8, envelope.actor_principal);
    try stmt.bindText(9, event_hash);
    try stmt.bindText(10, due_at);
    try stmt.bindText(11, envelope.occurred_at);
    try stmt.bindText(12, envelope.actor_principal);
    try stmt.bindText(13, event_hash);
    try stmt.bindText(14, state);
    try stmt.bindText(15, envelope.occurred_at);
    try stmt.bindText(16, envelope.actor_principal);
    try stmt.bindText(17, event_hash);
    try stmt.bindText(18, envelope.occurred_at);
    try stmt.bindText(19, envelope.actor_principal);
    try stmt.bindText(20, envelope.actor_device);
    try stmt.stepDone();
}

fn milestoneExists(db: *SqliteDb, milestone_id: []const u8) !bool {
    var stmt = try db.prepare("SELECT 1 FROM milestones WHERE id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, milestone_id);
    return try stmt.step();
}

fn deleteMilestone(db: *SqliteDb, milestone_id: []const u8) !void {
    var stmt = try db.prepare("DELETE FROM milestones WHERE id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, milestone_id);
    try stmt.stepDone();
}

fn updateMilestoneScalar(
    allocator: Allocator,
    db: *SqliteDb,
    milestone_id: []const u8,
    value: []const u8,
    event_hash: []const u8,
    envelope: ValidatedEnvelope,
    comptime value_col: []const u8,
    comptime occurred_at_col: []const u8,
    comptime actor_col: []const u8,
    comptime event_hash_col: []const u8,
) !void {
    var select = try db.prepare("SELECT " ++ occurred_at_col ++ ", " ++ actor_col ++ ", " ++ event_hash_col ++ " FROM milestones WHERE id = ?");
    defer select.deinit();
    try select.bindText(1, milestone_id);
    if (!(try select.step())) return;
    const old_occurred_at = try select.columnTextDup(allocator, 0);
    defer allocator.free(old_occurred_at);
    const old_actor = try select.columnTextDup(allocator, 1);
    defer allocator.free(old_actor);
    const old_event_hash = try select.columnTextDup(allocator, 2);
    defer allocator.free(old_event_hash);

    if (!(try eventWins(allocator, event_hash, old_event_hash))) return;

    var update = try db.prepare("UPDATE milestones SET " ++ value_col ++ " = ?, " ++ occurred_at_col ++ " = ?, " ++ actor_col ++ " = ?, " ++ event_hash_col ++ " = ? WHERE id = ?");
    defer update.deinit();
    try update.bindText(1, value);
    try update.bindText(2, envelope.occurred_at);
    try update.bindText(3, envelope.actor_principal);
    try update.bindText(4, event_hash);
    try update.bindText(5, milestone_id);
    try update.stepDone();
}
