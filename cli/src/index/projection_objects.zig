const std = @import("std");

const event_mod = @import("../event.zig");
const git = @import("../git.zig");
const ordering = @import("projection_ordering.zig");
const sqlite_db = @import("sqlite_db.zig");

const Allocator = std.mem.Allocator;
const SqliteDb = sqlite_db.SqliteDb;
const ValidatedEnvelope = event_mod.ValidatedEnvelope;
const eventInFrontier = ordering.eventInFrontier;
const eventWins = ordering.eventWins;

const max_projected_labels: usize = 256;
const max_projected_participants: usize = 128;
const max_projected_project_columns: usize = 128;
const max_projected_reaction_emojis: usize = 64;
const max_projected_reaction_actors: usize = 1024;

fn creationEventWins(db: *SqliteDb, event_type: []const u8, object_id: []const u8, event_hash: []const u8) !bool {
    var stmt = try db.prepare("SELECT event_hash FROM events WHERE event_type = ? AND object_id = ? ORDER BY event_hash DESC LIMIT 1");
    defer stmt.deinit();
    try stmt.bindText(1, event_type);
    try stmt.bindText(2, object_id);
    if (!(try stmt.step())) return false;
    const winner = try stmt.columnTextDup(db.allocator, 0);
    defer db.allocator.free(winner);
    return std.mem.eql(u8, winner, event_hash);
}

pub fn applyIssueProjection(allocator: Allocator, db: *SqliteDb, event_hash: []const u8, envelope: ValidatedEnvelope, body: []const u8) !?[]const u8 {
    if (!std.mem.startsWith(u8, envelope.event_type, "issue.")) return null;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return "invalid_event_envelope",
    };
    const payload_value = root.get("payload") orelse return "invalid_event_envelope";
    const payload = switch (payload_value) {
        .object => |object| object,
        else => return "invalid_event_envelope",
    };
    const legacy = switch (root.get("legacy") orelse return "invalid_event_envelope") {
        .object => |object| object,
        else => return "invalid_event_envelope",
    };

    if (std.mem.eql(u8, envelope.event_type, "issue.opened")) {
        if (!(try creationEventWins(db, "issue.opened", envelope.object_id, event_hash))) return "duplicate_object_id";
        const title = event_mod.jsonString(payload.get("title")) orelse return "invalid_event_envelope";
        const body_value = event_mod.jsonString(payload.get("body")) orelse "";
        try insertIssueOpened(db, event_hash, envelope, title, body_value);
        try upsertIssueMetadata(db, envelope.object_id, event_mod.jsonString(payload.get("source_author")) orelse "", event_mod.jsonString(payload.get("milestone")) orelse "");
        try insertLegacyAliasFromEnvelope(db, "issue", envelope.object_id, legacy);
        try insertPayloadStringArray(db, payload, "labels", insert_issue_label_sql, envelope.object_id, event_hash);
        try insertPayloadStringArray(db, payload, "assignees", insert_issue_assignee_sql, envelope.object_id, event_hash);
        try insertPayloadIssueProjects(db, payload, "projects", envelope.object_id, event_hash);
        return try issueCollectionLimitRejection(db, envelope.object_id);
    }

    if (!(try issueExists(db, envelope.object_id))) return "object_not_created";

    if (std.mem.eql(u8, envelope.event_type, "issue.updated")) {
        if (try applyIssueUpdated(allocator, db, payload, event_hash, envelope)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "issue.title_set")) {
        const title = event_mod.jsonString(payload.get("title")) orelse return "invalid_event_envelope";
        try updateIssueScalar(allocator, db, envelope.object_id, title, event_hash, envelope, "title", "title_occurred_at", "title_actor_principal", "title_event_hash");
    } else if (std.mem.eql(u8, envelope.event_type, "issue.body_set")) {
        const body_value = event_mod.jsonString(payload.get("body")) orelse return "invalid_event_envelope";
        try updateIssueScalar(allocator, db, envelope.object_id, body_value, event_hash, envelope, "body", "body_occurred_at", "body_actor_principal", "body_event_hash");
    } else if (std.mem.eql(u8, envelope.event_type, "issue.state_set")) {
        const state = event_mod.jsonString(payload.get("state")) orelse return "invalid_event_envelope";
        try updateIssueScalar(allocator, db, envelope.object_id, state, event_hash, envelope, "state", "state_occurred_at", "state_actor_principal", "state_event_hash");
    } else if (std.mem.eql(u8, envelope.event_type, "issue.label_added")) {
        const label = event_mod.jsonString(payload.get("label")) orelse return "invalid_event_envelope";
        try insertIssueCollectionValue(db, insert_issue_label_sql, envelope.object_id, label, event_hash);
        if (try issueCollectionLimitRejection(db, envelope.object_id)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "issue.label_removed")) {
        const label = event_mod.jsonString(payload.get("label")) orelse return "invalid_event_envelope";
        try deleteIssueCollectionValue(allocator, db, "SELECT add_hash FROM issue_labels WHERE issue_id = ? AND label = ?", "DELETE FROM issue_labels WHERE issue_id = ? AND label = ? AND add_hash = ?", envelope.object_id, label, event_hash);
    } else if (std.mem.eql(u8, envelope.event_type, "issue.assignee_added")) {
        const assignee = event_mod.jsonString(payload.get("assignee")) orelse return "invalid_event_envelope";
        try insertIssueCollectionValue(db, insert_issue_assignee_sql, envelope.object_id, assignee, event_hash);
        if (try issueCollectionLimitRejection(db, envelope.object_id)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "issue.assignee_removed")) {
        const assignee = event_mod.jsonString(payload.get("assignee")) orelse return "invalid_event_envelope";
        try deleteIssueCollectionValue(allocator, db, "SELECT add_hash FROM issue_assignees WHERE issue_id = ? AND assignee = ?", "DELETE FROM issue_assignees WHERE issue_id = ? AND assignee = ? AND add_hash = ?", envelope.object_id, assignee, event_hash);
    } else if (std.mem.eql(u8, envelope.event_type, "issue.milestone_set")) {
        const milestone = event_mod.jsonString(payload.get("milestone")) orelse return "invalid_event_envelope";
        try upsertIssueMilestone(db, envelope.object_id, milestone);
    } else if (std.mem.eql(u8, envelope.event_type, "issue.project_added")) {
        const project = event_mod.jsonString(payload.get("project")) orelse return "invalid_event_envelope";
        const column = event_mod.jsonString(payload.get("column")) orelse return "invalid_event_envelope";
        try insertIssueProject(db, envelope.object_id, project, column, event_hash);
        if (try issueCollectionLimitRejection(db, envelope.object_id)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "issue.project_removed")) {
        const project = event_mod.jsonString(payload.get("project")) orelse return "invalid_event_envelope";
        const column = event_mod.jsonString(payload.get("column")) orelse return "invalid_event_envelope";
        try deleteIssueProject(allocator, db, envelope.object_id, project, column, event_hash);
    } else if (std.mem.eql(u8, envelope.event_type, "issue.reaction_added")) {
        const emoji = event_mod.jsonString(payload.get("emoji")) orelse return "invalid_event_envelope";
        try insertReaction(db, "issue", envelope.object_id, emoji, envelope.actor_principal, event_hash, envelope.occurred_at);
        if (try reactionLimitRejection(db, "issue", envelope.object_id)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "issue.reaction_removed")) {
        const emoji = event_mod.jsonString(payload.get("emoji")) orelse return "invalid_event_envelope";
        try deleteReaction(allocator, db, "issue", envelope.object_id, emoji, envelope.actor_principal, event_hash, payload);
    }
    return null;
}

const insert_issue_label_sql = "INSERT OR IGNORE INTO issue_labels(issue_id, label, add_hash) VALUES (?, ?, ?)";
const insert_issue_assignee_sql = "INSERT OR IGNORE INTO issue_assignees(issue_id, assignee, add_hash) VALUES (?, ?, ?)";
const insert_issue_project_sql = "INSERT OR IGNORE INTO issue_projects(issue_id, project, column_name, add_hash) VALUES (?, ?, ?, ?)";

fn applyIssueUpdated(
    allocator: Allocator,
    db: *SqliteDb,
    payload: std.json.ObjectMap,
    event_hash: []const u8,
    envelope: ValidatedEnvelope,
) !?[]const u8 {
    if (event_mod.jsonString(payload.get("title"))) |title| {
        try updateIssueScalar(allocator, db, envelope.object_id, title, event_hash, envelope, "title", "title_occurred_at", "title_actor_principal", "title_event_hash");
    }
    if (event_mod.jsonString(payload.get("body"))) |body_value| {
        try updateIssueScalar(allocator, db, envelope.object_id, body_value, event_hash, envelope, "body", "body_occurred_at", "body_actor_principal", "body_event_hash");
    }
    if (event_mod.jsonString(payload.get("state"))) |state| {
        try updateIssueScalar(allocator, db, envelope.object_id, state, event_hash, envelope, "state", "state_occurred_at", "state_actor_principal", "state_event_hash");
    }
    try insertPayloadStringArray(db, payload, "labels_added", insert_issue_label_sql, envelope.object_id, event_hash);
    try insertPayloadStringArray(db, payload, "assignees_added", insert_issue_assignee_sql, envelope.object_id, event_hash);
    try deleteIssuePayloadStringArray(allocator, db, payload, "labels_removed", "SELECT add_hash FROM issue_labels WHERE issue_id = ? AND label = ?", "DELETE FROM issue_labels WHERE issue_id = ? AND label = ? AND add_hash = ?", envelope.object_id, event_hash);
    try deleteIssuePayloadStringArray(allocator, db, payload, "assignees_removed", "SELECT add_hash FROM issue_assignees WHERE issue_id = ? AND assignee = ?", "DELETE FROM issue_assignees WHERE issue_id = ? AND assignee = ? AND add_hash = ?", envelope.object_id, event_hash);
    return try issueCollectionLimitRejection(db, envelope.object_id);
}

fn insertIssueOpened(db: *SqliteDb, event_hash: []const u8, envelope: ValidatedEnvelope, title: []const u8, body: []const u8) !void {
    var stmt = try db.prepare(
        \\INSERT OR IGNORE INTO issues(
        \\  id,
        \\  title, title_occurred_at, title_actor_principal, title_event_hash,
        \\  body, body_occurred_at, body_actor_principal, body_event_hash,
        \\  state, state_occurred_at, state_actor_principal, state_event_hash,
        \\  opened_at, author_principal, author_device
        \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    );
    defer stmt.deinit();
    try stmt.bindText(1, envelope.object_id);
    try stmt.bindText(2, title);
    try stmt.bindText(3, envelope.occurred_at);
    try stmt.bindText(4, envelope.actor_principal);
    try stmt.bindText(5, event_hash);
    try stmt.bindText(6, body);
    try stmt.bindText(7, envelope.occurred_at);
    try stmt.bindText(8, envelope.actor_principal);
    try stmt.bindText(9, event_hash);
    try stmt.bindText(10, "open");
    try stmt.bindText(11, envelope.occurred_at);
    try stmt.bindText(12, envelope.actor_principal);
    try stmt.bindText(13, event_hash);
    try stmt.bindText(14, envelope.occurred_at);
    try stmt.bindText(15, envelope.actor_principal);
    try stmt.bindText(16, envelope.actor_device);
    try stmt.stepDone();
}

fn upsertIssueMetadata(db: *SqliteDb, issue_id: []const u8, source_author: []const u8, milestone: []const u8) !void {
    var stmt = try db.prepare(
        \\INSERT INTO issue_metadata(issue_id, source_author, milestone)
        \\VALUES (?, ?, ?)
        \\ON CONFLICT(issue_id) DO UPDATE SET
        \\  source_author = excluded.source_author,
        \\  milestone = excluded.milestone
    );
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    try stmt.bindText(2, source_author);
    try stmt.bindText(3, milestone);
    try stmt.stepDone();
}

fn upsertIssueMilestone(db: *SqliteDb, issue_id: []const u8, milestone: []const u8) !void {
    var stmt = try db.prepare(
        \\INSERT INTO issue_metadata(issue_id, source_author, milestone)
        \\VALUES (?, '', ?)
        \\ON CONFLICT(issue_id) DO UPDATE SET milestone = excluded.milestone
    );
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    try stmt.bindText(2, milestone);
    try stmt.stepDone();
}

fn insertLegacyAliasFromEnvelope(db: *SqliteDb, object_kind: []const u8, object_id: []const u8, legacy: std.json.ObjectMap) !void {
    const key = if (std.mem.eql(u8, object_kind, "issue"))
        "github_issue_number"
    else if (std.mem.eql(u8, object_kind, "pull"))
        "github_pull_number"
    else
        return;
    const number = event_mod.jsonInteger(legacy.get(key)) orelse return;
    if (number <= 0) return;

    var stmt = try db.prepare(
        \\INSERT OR IGNORE INTO legacy_aliases(provider, object_kind, object_id, number)
        \\VALUES ('github', ?, ?, ?)
    );
    defer stmt.deinit();
    try stmt.bindText(1, object_kind);
    try stmt.bindText(2, object_id);
    try stmt.bindInt64(3, number);
    try stmt.stepDone();
}

fn issueExists(db: *SqliteDb, issue_id: []const u8) !bool {
    var stmt = try db.prepare("SELECT 1 FROM issues WHERE id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    return try stmt.step();
}

fn updateIssueScalar(
    allocator: Allocator,
    db: *SqliteDb,
    issue_id: []const u8,
    value: []const u8,
    event_hash: []const u8,
    envelope: ValidatedEnvelope,
    comptime value_col: []const u8,
    comptime occurred_at_col: []const u8,
    comptime actor_col: []const u8,
    comptime event_hash_col: []const u8,
) !void {
    var select = try db.prepare("SELECT " ++ occurred_at_col ++ ", " ++ actor_col ++ ", " ++ event_hash_col ++ " FROM issues WHERE id = ?");
    defer select.deinit();
    try select.bindText(1, issue_id);
    if (!(try select.step())) return;
    const old_occurred_at = try select.columnTextDup(allocator, 0);
    defer allocator.free(old_occurred_at);
    const old_actor = try select.columnTextDup(allocator, 1);
    defer allocator.free(old_actor);
    const old_event_hash = try select.columnTextDup(allocator, 2);
    defer allocator.free(old_event_hash);

    if (!(try eventWins(allocator, event_hash, old_event_hash))) {
        return;
    }

    var update = try db.prepare("UPDATE issues SET " ++ value_col ++ " = ?, " ++ occurred_at_col ++ " = ?, " ++ actor_col ++ " = ?, " ++ event_hash_col ++ " = ? WHERE id = ?");
    defer update.deinit();
    try update.bindText(1, value);
    try update.bindText(2, envelope.occurred_at);
    try update.bindText(3, envelope.actor_principal);
    try update.bindText(4, event_hash);
    try update.bindText(5, issue_id);
    try update.stepDone();
}

fn insertPayloadStringArray(
    db: *SqliteDb,
    payload: std.json.ObjectMap,
    key: []const u8,
    comptime sql_text: []const u8,
    issue_id: []const u8,
    event_hash: []const u8,
) !void {
    const value = payload.get(key) orelse return;
    const array = switch (value) {
        .array => |items| items,
        else => return,
    };
    for (array.items) |item| {
        if (item != .string) continue;
        try insertIssueCollectionValue(db, sql_text, issue_id, item.string, event_hash);
    }
}

fn deleteIssuePayloadStringArray(
    allocator: Allocator,
    db: *SqliteDb,
    payload: std.json.ObjectMap,
    key: []const u8,
    comptime select_sql: []const u8,
    comptime delete_sql: []const u8,
    issue_id: []const u8,
    event_hash: []const u8,
) !void {
    const value = payload.get(key) orelse return;
    const array = switch (value) {
        .array => |items| items,
        else => return,
    };
    for (array.items) |item| {
        if (item != .string) continue;
        try deleteIssueCollectionValue(allocator, db, select_sql, delete_sql, issue_id, item.string, event_hash);
    }
}

fn insertIssueCollectionValue(db: *SqliteDb, comptime sql_text: []const u8, issue_id: []const u8, value: []const u8, event_hash: []const u8) !void {
    var stmt = try db.prepare(sql_text);
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    try stmt.bindText(2, value);
    try stmt.bindText(3, event_hash);
    try stmt.stepDone();
}

fn insertPayloadIssueProjects(
    db: *SqliteDb,
    payload: std.json.ObjectMap,
    key: []const u8,
    issue_id: []const u8,
    event_hash: []const u8,
) !void {
    const value = payload.get(key) orelse return;
    const array = switch (value) {
        .array => |items| items,
        else => return,
    };
    for (array.items) |item| {
        const project = switch (item) {
            .object => |map| map,
            else => continue,
        };
        const project_name = event_mod.jsonString(project.get("project")) orelse continue;
        const column = event_mod.jsonString(project.get("column")) orelse "";
        try insertIssueProject(db, issue_id, project_name, column, event_hash);
    }
}

fn insertIssueProject(db: *SqliteDb, issue_id: []const u8, project: []const u8, column: []const u8, event_hash: []const u8) !void {
    if (std.mem.trim(u8, project, " \t\r\n").len == 0) return;
    var stmt = try db.prepare(insert_issue_project_sql);
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    try stmt.bindText(2, project);
    try stmt.bindText(3, column);
    try stmt.bindText(4, event_hash);
    try stmt.stepDone();
}

fn deleteIssueProject(
    allocator: Allocator,
    db: *SqliteDb,
    issue_id: []const u8,
    project: []const u8,
    column: []const u8,
    remove_hash: []const u8,
) !void {
    var select = try db.prepare("SELECT add_hash FROM issue_projects WHERE issue_id = ? AND project = ? AND column_name = ?");
    defer select.deinit();
    try select.bindText(1, issue_id);
    try select.bindText(2, project);
    try select.bindText(3, column);
    while (try select.step()) {
        const add_hash = try select.columnTextDup(allocator, 0);
        defer allocator.free(add_hash);
        if (!(try git.isAncestor(allocator, add_hash, remove_hash))) continue;
        var delete = try db.prepare("DELETE FROM issue_projects WHERE issue_id = ? AND project = ? AND column_name = ? AND add_hash = ?");
        defer delete.deinit();
        try delete.bindText(1, issue_id);
        try delete.bindText(2, project);
        try delete.bindText(3, column);
        try delete.bindText(4, add_hash);
        try delete.stepDone();
    }
}

fn deleteIssueCollectionValue(
    allocator: Allocator,
    db: *SqliteDb,
    comptime select_sql: []const u8,
    comptime delete_sql: []const u8,
    issue_id: []const u8,
    value: []const u8,
    remove_hash: []const u8,
) !void {
    var select = try db.prepare(select_sql);
    defer select.deinit();
    try select.bindText(1, issue_id);
    try select.bindText(2, value);
    while (try select.step()) {
        const add_hash = try select.columnTextDup(allocator, 0);
        defer allocator.free(add_hash);
        if (!(try git.isAncestor(allocator, add_hash, remove_hash))) continue;
        var delete = try db.prepare(delete_sql);
        defer delete.deinit();
        try delete.bindText(1, issue_id);
        try delete.bindText(2, value);
        try delete.bindText(3, add_hash);
        try delete.stepDone();
    }
}

fn issueCollectionLimitRejection(db: *SqliteDb, issue_id: []const u8) !?[]const u8 {
    if (try collectionCountExceeds(db, "SELECT COUNT(DISTINCT label) FROM issue_labels WHERE issue_id = ?", issue_id, max_projected_labels)) {
        return "collection_limit_exceeded";
    }
    if (try collectionCountExceeds(db, "SELECT COUNT(DISTINCT assignee) FROM issue_assignees WHERE issue_id = ?", issue_id, max_projected_participants)) {
        return "collection_limit_exceeded";
    }
    if (try collectionCountExceeds(db, "SELECT COUNT(DISTINCT project || char(31) || column_name) FROM issue_projects WHERE issue_id = ?", issue_id, max_projected_labels)) {
        return "collection_limit_exceeded";
    }
    return null;
}

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
        const name = event_mod.jsonString(payload.get("name")) orelse return "invalid_event_envelope";
        const description = event_mod.jsonString(payload.get("description")) orelse "";
        const state = event_mod.jsonString(payload.get("state")) orelse "open";
        try insertProjectCreated(db, event_hash, envelope, name, description, state);
        try insertPayloadProjectColumns(db, payload, envelope.object_id, event_hash);
        return try projectColumnLimitRejection(db, envelope.object_id);
    }

    if (!(try projectExists(db, envelope.object_id))) return "object_not_created";

    if (std.mem.eql(u8, envelope.event_type, "project.updated")) {
        if (event_mod.jsonString(payload.get("name"))) |name| {
            try updateProjectScalar(allocator, db, envelope.object_id, name, event_hash, envelope, "name", "name_occurred_at", "name_actor_principal", "name_event_hash");
        }
        if (event_mod.jsonString(payload.get("description"))) |description| {
            try updateProjectScalar(allocator, db, envelope.object_id, description, event_hash, envelope, "description", "description_occurred_at", "description_actor_principal", "description_event_hash");
        }
        if (event_mod.jsonString(payload.get("state"))) |state| {
            try updateProjectScalar(allocator, db, envelope.object_id, state, event_hash, envelope, "state", "state_occurred_at", "state_actor_principal", "state_event_hash");
        }
    } else if (std.mem.eql(u8, envelope.event_type, "project.column_added")) {
        const column = event_mod.jsonString(payload.get("column")) orelse return "invalid_event_envelope";
        try insertProjectColumn(db, envelope.object_id, column, event_hash);
        if (try projectColumnLimitRejection(db, envelope.object_id)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "project.column_removed")) {
        const column = event_mod.jsonString(payload.get("column")) orelse return "invalid_event_envelope";
        try deleteProjectColumn(allocator, db, envelope.object_id, column, event_hash);
    }
    return null;
}

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
        const title = event_mod.jsonString(payload.get("title")) orelse return "invalid_event_envelope";
        const description = event_mod.jsonString(payload.get("description")) orelse "";
        const due_at = event_mod.jsonString(payload.get("due_at")) orelse "";
        const state = event_mod.jsonString(payload.get("state")) orelse "open";
        try insertMilestoneCreated(db, event_hash, envelope, title, description, due_at, state);
        return null;
    }

    if (!(try milestoneExists(db, envelope.object_id))) return "object_not_created";

    if (std.mem.eql(u8, envelope.event_type, "milestone.updated")) {
        if (event_mod.jsonString(payload.get("title"))) |title| {
            try updateMilestoneScalar(allocator, db, envelope.object_id, title, event_hash, envelope, "title", "title_occurred_at", "title_actor_principal", "title_event_hash");
        }
        if (event_mod.jsonString(payload.get("description"))) |description| {
            try updateMilestoneScalar(allocator, db, envelope.object_id, description, event_hash, envelope, "description", "description_occurred_at", "description_actor_principal", "description_event_hash");
        }
        if (event_mod.jsonString(payload.get("due_at"))) |due_at| {
            try updateMilestoneScalar(allocator, db, envelope.object_id, due_at, event_hash, envelope, "due_at", "due_at_occurred_at", "due_at_actor_principal", "due_at_event_hash");
        }
        if (event_mod.jsonString(payload.get("state"))) |state| {
            try updateMilestoneScalar(allocator, db, envelope.object_id, state, event_hash, envelope, "state", "state_occurred_at", "state_actor_principal", "state_event_hash");
        }
    } else if (std.mem.eql(u8, envelope.event_type, "milestone.state_set")) {
        const state = event_mod.jsonString(payload.get("state")) orelse return "invalid_event_envelope";
        try updateMilestoneScalar(allocator, db, envelope.object_id, state, event_hash, envelope, "state", "state_occurred_at", "state_actor_principal", "state_event_hash");
    }
    return null;
}

fn insertProjectCreated(db: *SqliteDb, event_hash: []const u8, envelope: ValidatedEnvelope, name: []const u8, description: []const u8, state: []const u8) !void {
    var stmt = try db.prepare(
        \\INSERT OR IGNORE INTO projects(
        \\  id,
        \\  name, name_occurred_at, name_actor_principal, name_event_hash,
        \\  description, description_occurred_at, description_actor_principal, description_event_hash,
        \\  state, state_occurred_at, state_actor_principal, state_event_hash,
        \\  created_at, author_principal, author_device
        \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
    try stmt.bindText(10, state);
    try stmt.bindText(11, envelope.occurred_at);
    try stmt.bindText(12, envelope.actor_principal);
    try stmt.bindText(13, event_hash);
    try stmt.bindText(14, envelope.occurred_at);
    try stmt.bindText(15, envelope.actor_principal);
    try stmt.bindText(16, envelope.actor_device);
    try stmt.stepDone();
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

fn insertPayloadProjectColumns(db: *SqliteDb, payload: std.json.ObjectMap, project_id: []const u8, event_hash: []const u8) !void {
    const value = payload.get("columns") orelse return;
    const array = switch (value) {
        .array => |items| items,
        else => return,
    };
    for (array.items) |item| {
        if (item != .string) continue;
        try insertProjectColumn(db, project_id, item.string, event_hash);
    }
}

fn insertProjectColumn(db: *SqliteDb, project_id: []const u8, column: []const u8, event_hash: []const u8) !void {
    if (std.mem.trim(u8, column, " \t\r\n").len == 0) return;
    var stmt = try db.prepare("INSERT OR IGNORE INTO project_columns(project_id, column_name, add_hash) VALUES (?, ?, ?)");
    defer stmt.deinit();
    try stmt.bindText(1, project_id);
    try stmt.bindText(2, column);
    try stmt.bindText(3, event_hash);
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

pub fn applyPullProjection(allocator: Allocator, db: *SqliteDb, event_hash: []const u8, envelope: ValidatedEnvelope, body: []const u8) !?[]const u8 {
    if (!std.mem.startsWith(u8, envelope.event_type, "pull.")) return null;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return "invalid_event_envelope",
    };
    const payload_value = root.get("payload") orelse return "invalid_event_envelope";
    const payload = switch (payload_value) {
        .object => |object| object,
        else => return "invalid_event_envelope",
    };
    const legacy = switch (root.get("legacy") orelse return "invalid_event_envelope") {
        .object => |object| object,
        else => return "invalid_event_envelope",
    };

    if (std.mem.eql(u8, envelope.event_type, "pull.opened")) {
        if (!(try creationEventWins(db, "pull.opened", envelope.object_id, event_hash))) return "duplicate_object_id";
        const title = event_mod.jsonString(payload.get("title")) orelse return "invalid_event_envelope";
        const base_ref = event_mod.jsonString(payload.get("base_ref")) orelse return "invalid_event_envelope";
        const head_ref = event_mod.jsonString(payload.get("head_ref")) orelse return "invalid_event_envelope";
        const body_value = event_mod.jsonString(payload.get("body")) orelse "";
        const draft = event_mod.jsonBool(payload.get("draft")) orelse false;
        try insertPullOpened(db, event_hash, envelope, title, body_value, base_ref, head_ref, draft);
        try insertLegacyAliasFromEnvelope(db, "pull", envelope.object_id, legacy);
        return null;
    }

    if (!(try pullExists(db, envelope.object_id))) return "object_not_created";

    if (std.mem.eql(u8, envelope.event_type, "pull.updated")) {
        if (try applyPullUpdated(allocator, db, payload, event_hash, envelope)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "pull.title_set")) {
        const title = event_mod.jsonString(payload.get("title")) orelse return "invalid_event_envelope";
        _ = try updatePullScalar(allocator, db, envelope.object_id, title, event_hash, envelope, "title", "title_occurred_at", "title_actor_principal", "title_event_hash");
    } else if (std.mem.eql(u8, envelope.event_type, "pull.body_set")) {
        const body_value = event_mod.jsonString(payload.get("body")) orelse return "invalid_event_envelope";
        _ = try updatePullScalar(allocator, db, envelope.object_id, body_value, event_hash, envelope, "body", "body_occurred_at", "body_actor_principal", "body_event_hash");
    } else if (std.mem.eql(u8, envelope.event_type, "pull.state_set")) {
        const state = event_mod.jsonString(payload.get("state")) orelse return "invalid_event_envelope";
        if (!stateAllowsPullStateSet(state)) return "invalid_event_envelope";
        _ = try updatePullScalar(allocator, db, envelope.object_id, state, event_hash, envelope, "state", "state_occurred_at", "state_actor_principal", "state_event_hash");
    } else if (std.mem.eql(u8, envelope.event_type, "pull.base_set")) {
        const base_ref = event_mod.jsonString(payload.get("base_ref")) orelse return "invalid_event_envelope";
        _ = try updatePullScalar(allocator, db, envelope.object_id, base_ref, event_hash, envelope, "base_ref", "base_occurred_at", "base_actor_principal", "base_event_hash");
    } else if (std.mem.eql(u8, envelope.event_type, "pull.head_set")) {
        const head_ref = event_mod.jsonString(payload.get("head_ref")) orelse return "invalid_event_envelope";
        _ = try updatePullScalar(allocator, db, envelope.object_id, head_ref, event_hash, envelope, "head_ref", "head_occurred_at", "head_actor_principal", "head_event_hash");
    } else if (std.mem.eql(u8, envelope.event_type, "pull.label_added")) {
        const label = event_mod.jsonString(payload.get("label")) orelse return "invalid_event_envelope";
        try insertPullCollectionValue(db, insert_pull_label_sql, envelope.object_id, label, event_hash);
        if (try pullCollectionLimitRejection(db, envelope.object_id)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "pull.label_removed")) {
        const label = event_mod.jsonString(payload.get("label")) orelse return "invalid_event_envelope";
        try deletePullCollectionValue(allocator, db, "SELECT add_hash FROM pull_labels WHERE pull_id = ? AND label = ?", "DELETE FROM pull_labels WHERE pull_id = ? AND label = ? AND add_hash = ?", envelope.object_id, label, event_hash);
    } else if (std.mem.eql(u8, envelope.event_type, "pull.assignee_added")) {
        const assignee = event_mod.jsonString(payload.get("assignee")) orelse return "invalid_event_envelope";
        try insertPullCollectionValue(db, insert_pull_assignee_sql, envelope.object_id, assignee, event_hash);
        if (try pullCollectionLimitRejection(db, envelope.object_id)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "pull.assignee_removed")) {
        const assignee = event_mod.jsonString(payload.get("assignee")) orelse return "invalid_event_envelope";
        try deletePullCollectionValue(allocator, db, "SELECT add_hash FROM pull_assignees WHERE pull_id = ? AND assignee = ?", "DELETE FROM pull_assignees WHERE pull_id = ? AND assignee = ? AND add_hash = ?", envelope.object_id, assignee, event_hash);
    } else if (std.mem.eql(u8, envelope.event_type, "pull.reviewer_added")) {
        const reviewer = event_mod.jsonString(payload.get("reviewer")) orelse return "invalid_event_envelope";
        try insertPullCollectionValue(db, insert_pull_reviewer_sql, envelope.object_id, reviewer, event_hash);
        if (try pullCollectionLimitRejection(db, envelope.object_id)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "pull.reviewer_removed")) {
        const reviewer = event_mod.jsonString(payload.get("reviewer")) orelse return "invalid_event_envelope";
        try deletePullCollectionValue(allocator, db, "SELECT add_hash FROM pull_reviewers WHERE pull_id = ? AND reviewer = ?", "DELETE FROM pull_reviewers WHERE pull_id = ? AND reviewer = ? AND add_hash = ?", envelope.object_id, reviewer, event_hash);
    } else if (std.mem.eql(u8, envelope.event_type, "pull.merged")) {
        try applyPullMerged(allocator, db, envelope.object_id, event_mod.jsonString(payload.get("merge_oid")) orelse "", event_mod.jsonString(payload.get("target_oid")) orelse "", event_hash, envelope);
    } else if (std.mem.eql(u8, envelope.event_type, "pull.reaction_added")) {
        const emoji = event_mod.jsonString(payload.get("emoji")) orelse return "invalid_event_envelope";
        try insertReaction(db, "pull", envelope.object_id, emoji, envelope.actor_principal, event_hash, envelope.occurred_at);
        if (try reactionLimitRejection(db, "pull", envelope.object_id)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "pull.reaction_removed")) {
        const emoji = event_mod.jsonString(payload.get("emoji")) orelse return "invalid_event_envelope";
        try deleteReaction(allocator, db, "pull", envelope.object_id, emoji, envelope.actor_principal, event_hash, payload);
    }
    return null;
}

const insert_pull_label_sql = "INSERT OR IGNORE INTO pull_labels(pull_id, label, add_hash) VALUES (?, ?, ?)";
const insert_pull_assignee_sql = "INSERT OR IGNORE INTO pull_assignees(pull_id, assignee, add_hash) VALUES (?, ?, ?)";
const insert_pull_reviewer_sql = "INSERT OR IGNORE INTO pull_reviewers(pull_id, reviewer, add_hash) VALUES (?, ?, ?)";

fn applyPullUpdated(
    allocator: Allocator,
    db: *SqliteDb,
    payload: std.json.ObjectMap,
    event_hash: []const u8,
    envelope: ValidatedEnvelope,
) !?[]const u8 {
    if (event_mod.jsonString(payload.get("title"))) |title| {
        _ = try updatePullScalar(allocator, db, envelope.object_id, title, event_hash, envelope, "title", "title_occurred_at", "title_actor_principal", "title_event_hash");
    }
    if (event_mod.jsonString(payload.get("body"))) |body_value| {
        _ = try updatePullScalar(allocator, db, envelope.object_id, body_value, event_hash, envelope, "body", "body_occurred_at", "body_actor_principal", "body_event_hash");
    }
    if (event_mod.jsonString(payload.get("state"))) |state| {
        if (!stateAllowsPullStateSet(state)) return "invalid_event_envelope";
        _ = try updatePullScalar(allocator, db, envelope.object_id, state, event_hash, envelope, "state", "state_occurred_at", "state_actor_principal", "state_event_hash");
    }
    if (event_mod.jsonString(payload.get("base_ref"))) |base_ref| {
        _ = try updatePullScalar(allocator, db, envelope.object_id, base_ref, event_hash, envelope, "base_ref", "base_occurred_at", "base_actor_principal", "base_event_hash");
    }
    if (event_mod.jsonString(payload.get("head_ref"))) |head_ref| {
        _ = try updatePullScalar(allocator, db, envelope.object_id, head_ref, event_hash, envelope, "head_ref", "head_occurred_at", "head_actor_principal", "head_event_hash");
    }
    try insertPullPayloadStringArray(db, payload, "labels_added", insert_pull_label_sql, envelope.object_id, event_hash);
    try insertPullPayloadStringArray(db, payload, "assignees_added", insert_pull_assignee_sql, envelope.object_id, event_hash);
    try insertPullPayloadStringArray(db, payload, "reviewers_added", insert_pull_reviewer_sql, envelope.object_id, event_hash);
    try deletePullPayloadStringArray(allocator, db, payload, "labels_removed", "SELECT add_hash FROM pull_labels WHERE pull_id = ? AND label = ?", "DELETE FROM pull_labels WHERE pull_id = ? AND label = ? AND add_hash = ?", envelope.object_id, event_hash);
    try deletePullPayloadStringArray(allocator, db, payload, "assignees_removed", "SELECT add_hash FROM pull_assignees WHERE pull_id = ? AND assignee = ?", "DELETE FROM pull_assignees WHERE pull_id = ? AND assignee = ? AND add_hash = ?", envelope.object_id, event_hash);
    try deletePullPayloadStringArray(allocator, db, payload, "reviewers_removed", "SELECT add_hash FROM pull_reviewers WHERE pull_id = ? AND reviewer = ?", "DELETE FROM pull_reviewers WHERE pull_id = ? AND reviewer = ? AND add_hash = ?", envelope.object_id, event_hash);
    return try pullCollectionLimitRejection(db, envelope.object_id);
}

fn insertPullOpened(
    db: *SqliteDb,
    event_hash: []const u8,
    envelope: ValidatedEnvelope,
    title: []const u8,
    body: []const u8,
    base_ref: []const u8,
    head_ref: []const u8,
    draft: bool,
) !void {
    var stmt = try db.prepare(
        \\INSERT OR IGNORE INTO pulls(
        \\  id,
        \\  title, title_occurred_at, title_actor_principal, title_event_hash,
        \\  body, body_occurred_at, body_actor_principal, body_event_hash,
        \\  state, state_occurred_at, state_actor_principal, state_event_hash,
        \\  base_ref, base_occurred_at, base_actor_principal, base_event_hash,
        \\  head_ref, head_occurred_at, head_actor_principal, head_event_hash,
        \\  draft, merge_oid, target_oid,
        \\  opened_at, author_principal, author_device
        \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    );
    defer stmt.deinit();
    try stmt.bindText(1, envelope.object_id);
    try stmt.bindText(2, title);
    try stmt.bindText(3, envelope.occurred_at);
    try stmt.bindText(4, envelope.actor_principal);
    try stmt.bindText(5, event_hash);
    try stmt.bindText(6, body);
    try stmt.bindText(7, envelope.occurred_at);
    try stmt.bindText(8, envelope.actor_principal);
    try stmt.bindText(9, event_hash);
    try stmt.bindText(10, "open");
    try stmt.bindText(11, envelope.occurred_at);
    try stmt.bindText(12, envelope.actor_principal);
    try stmt.bindText(13, event_hash);
    try stmt.bindText(14, base_ref);
    try stmt.bindText(15, envelope.occurred_at);
    try stmt.bindText(16, envelope.actor_principal);
    try stmt.bindText(17, event_hash);
    try stmt.bindText(18, head_ref);
    try stmt.bindText(19, envelope.occurred_at);
    try stmt.bindText(20, envelope.actor_principal);
    try stmt.bindText(21, event_hash);
    try stmt.bindInt(22, if (draft) 1 else 0);
    try stmt.bindText(23, "");
    try stmt.bindText(24, "");
    try stmt.bindText(25, envelope.occurred_at);
    try stmt.bindText(26, envelope.actor_principal);
    try stmt.bindText(27, envelope.actor_device);
    try stmt.stepDone();
}

fn pullExists(db: *SqliteDb, pull_id: []const u8) !bool {
    var stmt = try db.prepare("SELECT 1 FROM pulls WHERE id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, pull_id);
    return try stmt.step();
}

fn updatePullScalar(
    allocator: Allocator,
    db: *SqliteDb,
    pull_id: []const u8,
    value: []const u8,
    event_hash: []const u8,
    envelope: ValidatedEnvelope,
    comptime value_col: []const u8,
    comptime occurred_at_col: []const u8,
    comptime actor_col: []const u8,
    comptime event_hash_col: []const u8,
) !bool {
    var select = try db.prepare("SELECT " ++ occurred_at_col ++ ", " ++ actor_col ++ ", " ++ event_hash_col ++ " FROM pulls WHERE id = ?");
    defer select.deinit();
    try select.bindText(1, pull_id);
    if (!(try select.step())) return false;
    const old_occurred_at = try select.columnTextDup(allocator, 0);
    defer allocator.free(old_occurred_at);
    const old_actor = try select.columnTextDup(allocator, 1);
    defer allocator.free(old_actor);
    const old_event_hash = try select.columnTextDup(allocator, 2);
    defer allocator.free(old_event_hash);

    if (!(try eventWins(allocator, event_hash, old_event_hash))) {
        return false;
    }

    var update = try db.prepare("UPDATE pulls SET " ++ value_col ++ " = ?, " ++ occurred_at_col ++ " = ?, " ++ actor_col ++ " = ?, " ++ event_hash_col ++ " = ? WHERE id = ?");
    defer update.deinit();
    try update.bindText(1, value);
    try update.bindText(2, envelope.occurred_at);
    try update.bindText(3, envelope.actor_principal);
    try update.bindText(4, event_hash);
    try update.bindText(5, pull_id);
    try update.stepDone();
    return true;
}

fn applyPullMerged(
    allocator: Allocator,
    db: *SqliteDb,
    pull_id: []const u8,
    merge_oid: []const u8,
    target_oid: []const u8,
    event_hash: []const u8,
    envelope: ValidatedEnvelope,
) !void {
    if (!(try updatePullScalar(allocator, db, pull_id, "merged", event_hash, envelope, "state", "state_occurred_at", "state_actor_principal", "state_event_hash"))) return;
    var update = try db.prepare("UPDATE pulls SET merge_oid = ?, target_oid = ? WHERE id = ?");
    defer update.deinit();
    try update.bindText(1, merge_oid);
    try update.bindText(2, target_oid);
    try update.bindText(3, pull_id);
    try update.stepDone();
}

fn insertPullCollectionValue(db: *SqliteDb, comptime sql_text: []const u8, pull_id: []const u8, value: []const u8, event_hash: []const u8) !void {
    var stmt = try db.prepare(sql_text);
    defer stmt.deinit();
    try stmt.bindText(1, pull_id);
    try stmt.bindText(2, value);
    try stmt.bindText(3, event_hash);
    try stmt.stepDone();
}

fn insertPullPayloadStringArray(
    db: *SqliteDb,
    payload: std.json.ObjectMap,
    key: []const u8,
    comptime sql_text: []const u8,
    pull_id: []const u8,
    event_hash: []const u8,
) !void {
    const value = payload.get(key) orelse return;
    const array = switch (value) {
        .array => |items| items,
        else => return,
    };
    for (array.items) |item| {
        if (item != .string) continue;
        try insertPullCollectionValue(db, sql_text, pull_id, item.string, event_hash);
    }
}

fn deletePullPayloadStringArray(
    allocator: Allocator,
    db: *SqliteDb,
    payload: std.json.ObjectMap,
    key: []const u8,
    comptime select_sql: []const u8,
    comptime delete_sql: []const u8,
    pull_id: []const u8,
    event_hash: []const u8,
) !void {
    const value = payload.get(key) orelse return;
    const array = switch (value) {
        .array => |items| items,
        else => return,
    };
    for (array.items) |item| {
        if (item != .string) continue;
        try deletePullCollectionValue(allocator, db, select_sql, delete_sql, pull_id, item.string, event_hash);
    }
}

fn deletePullCollectionValue(
    allocator: Allocator,
    db: *SqliteDb,
    comptime select_sql: []const u8,
    comptime delete_sql: []const u8,
    pull_id: []const u8,
    value: []const u8,
    remove_hash: []const u8,
) !void {
    var select = try db.prepare(select_sql);
    defer select.deinit();
    try select.bindText(1, pull_id);
    try select.bindText(2, value);
    while (try select.step()) {
        const add_hash = try select.columnTextDup(allocator, 0);
        defer allocator.free(add_hash);
        if (!(try git.isAncestor(allocator, add_hash, remove_hash))) continue;
        var delete = try db.prepare(delete_sql);
        defer delete.deinit();
        try delete.bindText(1, pull_id);
        try delete.bindText(2, value);
        try delete.bindText(3, add_hash);
        try delete.stepDone();
    }
}

fn pullCollectionLimitRejection(db: *SqliteDb, pull_id: []const u8) !?[]const u8 {
    if (try collectionCountExceeds(db, "SELECT COUNT(DISTINCT label) FROM pull_labels WHERE pull_id = ?", pull_id, max_projected_labels)) {
        return "collection_limit_exceeded";
    }
    if (try collectionCountExceeds(db, "SELECT COUNT(DISTINCT assignee) FROM pull_assignees WHERE pull_id = ?", pull_id, max_projected_participants)) {
        return "collection_limit_exceeded";
    }
    if (try collectionCountExceeds(db, "SELECT COUNT(DISTINCT reviewer) FROM pull_reviewers WHERE pull_id = ?", pull_id, max_projected_participants)) {
        return "collection_limit_exceeded";
    }
    return null;
}

fn collectionCountExceeds(db: *SqliteDb, comptime sql_text: []const u8, object_id: []const u8, max_count: usize) !bool {
    var stmt = try db.prepare(sql_text);
    defer stmt.deinit();
    try stmt.bindText(1, object_id);
    if (!(try stmt.step())) return false;
    return stmt.columnInt64(0) > @as(i64, @intCast(max_count));
}

fn stateAllowsPullStateSet(state: []const u8) bool {
    return std.mem.eql(u8, state, "open") or std.mem.eql(u8, state, "closed");
}

pub fn applyCommentProjection(allocator: Allocator, db: *SqliteDb, event_hash: []const u8, envelope: ValidatedEnvelope, body: []const u8) !?[]const u8 {
    if (!std.mem.startsWith(u8, envelope.event_type, "comment.")) return null;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return "invalid_event_envelope",
    };
    const payload_value = root.get("payload") orelse return "invalid_event_envelope";
    const payload = switch (payload_value) {
        .object => |object| object,
        else => return "invalid_event_envelope",
    };

    if (std.mem.eql(u8, envelope.event_type, "comment.added")) {
        if (!(try creationEventWins(db, "comment.added", envelope.object_id, event_hash))) return "duplicate_object_id";
        const parent_kind = event_mod.jsonString(payload.get("parent_kind")) orelse return "invalid_event_envelope";
        const parent_id = event_mod.jsonString(payload.get("parent_id")) orelse return "invalid_event_envelope";
        if (std.mem.eql(u8, parent_kind, "issue")) {
            if (!(try issueExists(db, parent_id))) return "parent_not_created";
        } else if (std.mem.eql(u8, parent_kind, "pull")) {
            if (!(try pullExists(db, parent_id))) return "parent_not_created";
        }
        const comment_body = event_mod.jsonString(payload.get("body")) orelse return "invalid_event_envelope";
        const source_author = event_mod.jsonString(payload.get("source_author")) orelse "";
        const reply_parent_hash = event_mod.jsonString(payload.get("reply_parent_hash")) orelse "";
        const reply_parent_id = try commentReplyParentId(allocator, db, event_mod.jsonString(payload.get("reply_parent_id")) orelse "", reply_parent_hash);
        defer allocator.free(reply_parent_id);
        if (reply_parent_hash.len != 0 and reply_parent_id.len == 0) return "parent_not_created";
        if (reply_parent_id.len != 0 and !(try commentInParent(db, reply_parent_id, parent_kind, parent_id))) return "parent_not_created";
        if (reply_parent_id.len != 0 and reply_parent_hash.len != 0 and !(try commentCreationHashMatches(db, reply_parent_id, reply_parent_hash))) return "parent_not_created";
        try insertCommentAdded(db, event_hash, envelope, parent_kind, parent_id, comment_body, source_author, reply_parent_id, reply_parent_hash);
    } else if (std.mem.eql(u8, envelope.event_type, "comment.body_set")) {
        if (!(try commentExists(db, envelope.object_id))) return "object_not_created";
        const comment_body = event_mod.jsonString(payload.get("body")) orelse return "invalid_event_envelope";
        try updateCommentBody(allocator, db, envelope.object_id, comment_body, event_hash, envelope);
    } else if (std.mem.eql(u8, envelope.event_type, "comment.redacted")) {
        if (!(try commentExists(db, envelope.object_id))) return "object_not_created";
        try redactComment(allocator, db, envelope.object_id, event_hash, envelope);
    } else if (std.mem.eql(u8, envelope.event_type, "comment.reaction_added")) {
        if (!(try commentExists(db, envelope.object_id))) return "object_not_created";
        const emoji = event_mod.jsonString(payload.get("emoji")) orelse return "invalid_event_envelope";
        try insertReaction(db, "comment", envelope.object_id, emoji, envelope.actor_principal, event_hash, envelope.occurred_at);
        if (try reactionLimitRejection(db, "comment", envelope.object_id)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "comment.reaction_removed")) {
        if (!(try commentExists(db, envelope.object_id))) return "object_not_created";
        const emoji = event_mod.jsonString(payload.get("emoji")) orelse return "invalid_event_envelope";
        try deleteReaction(allocator, db, "comment", envelope.object_id, emoji, envelope.actor_principal, event_hash, payload);
    }
    return null;
}

fn insertCommentAdded(
    db: *SqliteDb,
    event_hash: []const u8,
    envelope: ValidatedEnvelope,
    parent_kind: []const u8,
    parent_id: []const u8,
    body: []const u8,
    source_author: []const u8,
    reply_parent_id: []const u8,
    reply_parent_hash: []const u8,
) !void {
    var stmt = try db.prepare(
        \\INSERT OR IGNORE INTO comments(
        \\  id, parent_kind, parent_id,
        \\  body, body_occurred_at, body_actor_principal, body_event_hash,
        \\  redacted, redacted_at, redacted_actor_principal, redacted_event_hash,
        \\  created_at, author_principal, author_device,
        \\  source_author, reply_parent_id, reply_parent_hash
        \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    );
    defer stmt.deinit();
    try stmt.bindText(1, envelope.object_id);
    try stmt.bindText(2, parent_kind);
    try stmt.bindText(3, parent_id);
    try stmt.bindText(4, body);
    try stmt.bindText(5, envelope.occurred_at);
    try stmt.bindText(6, envelope.actor_principal);
    try stmt.bindText(7, event_hash);
    try stmt.bindInt(8, 0);
    try stmt.bindText(9, "");
    try stmt.bindText(10, "");
    try stmt.bindText(11, "");
    try stmt.bindText(12, envelope.occurred_at);
    try stmt.bindText(13, envelope.actor_principal);
    try stmt.bindText(14, envelope.actor_device);
    try stmt.bindText(15, source_author);
    try stmt.bindText(16, reply_parent_id);
    try stmt.bindText(17, reply_parent_hash);
    try stmt.stepDone();
}

fn commentReplyParentId(allocator: Allocator, db: *SqliteDb, payload_parent_id: []const u8, reply_parent_hash: []const u8) ![]u8 {
    if (payload_parent_id.len != 0) return allocator.dupe(u8, payload_parent_id);
    if (reply_parent_hash.len == 0) return allocator.dupe(u8, "");

    var stmt = try db.prepare(
        \\SELECT object_id
        \\FROM events
        \\WHERE event_hash = ?
        \\  AND event_type = 'comment.added'
        \\  AND domain_status = 'accepted'
        \\LIMIT 1
    );
    defer stmt.deinit();
    try stmt.bindText(1, reply_parent_hash);
    if (!(try stmt.step())) return allocator.dupe(u8, "");
    return try stmt.columnTextDup(allocator, 0);
}

fn commentExists(db: *SqliteDb, comment_id: []const u8) !bool {
    var stmt = try db.prepare("SELECT 1 FROM comments WHERE id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, comment_id);
    return try stmt.step();
}

fn commentInParent(db: *SqliteDb, comment_id: []const u8, parent_kind: []const u8, parent_id: []const u8) !bool {
    var stmt = try db.prepare("SELECT 1 FROM comments WHERE id = ? AND parent_kind = ? AND parent_id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, comment_id);
    try stmt.bindText(2, parent_kind);
    try stmt.bindText(3, parent_id);
    return try stmt.step();
}

fn commentCreationHashMatches(db: *SqliteDb, comment_id: []const u8, event_hash: []const u8) !bool {
    var stmt = try db.prepare(
        \\SELECT 1
        \\FROM events
        \\WHERE object_id = ?
        \\  AND event_type = 'comment.added'
        \\  AND event_hash = ?
        \\  AND domain_status = 'accepted'
        \\LIMIT 1
    );
    defer stmt.deinit();
    try stmt.bindText(1, comment_id);
    try stmt.bindText(2, event_hash);
    return try stmt.step();
}

fn updateCommentBody(allocator: Allocator, db: *SqliteDb, comment_id: []const u8, body: []const u8, event_hash: []const u8, envelope: ValidatedEnvelope) !void {
    var select = try db.prepare("SELECT body_occurred_at, body_actor_principal, body_event_hash FROM comments WHERE id = ?");
    defer select.deinit();
    try select.bindText(1, comment_id);
    if (!(try select.step())) return;
    const old_occurred_at = try select.columnTextDup(allocator, 0);
    defer allocator.free(old_occurred_at);
    const old_actor = try select.columnTextDup(allocator, 1);
    defer allocator.free(old_actor);
    const old_event_hash = try select.columnTextDup(allocator, 2);
    defer allocator.free(old_event_hash);

    if (!(try eventWins(allocator, event_hash, old_event_hash))) {
        return;
    }

    var update = try db.prepare("UPDATE comments SET body = ?, body_occurred_at = ?, body_actor_principal = ?, body_event_hash = ? WHERE id = ?");
    defer update.deinit();
    try update.bindText(1, body);
    try update.bindText(2, envelope.occurred_at);
    try update.bindText(3, envelope.actor_principal);
    try update.bindText(4, event_hash);
    try update.bindText(5, comment_id);
    try update.stepDone();
}

fn redactComment(allocator: Allocator, db: *SqliteDb, comment_id: []const u8, event_hash: []const u8, envelope: ValidatedEnvelope) !void {
    var select = try db.prepare("SELECT redacted, redacted_event_hash FROM comments WHERE id = ?");
    defer select.deinit();
    try select.bindText(1, comment_id);
    if (try select.step()) {
        const was_redacted = select.columnInt(0) != 0;
        const old_hash = try select.columnTextDup(allocator, 1);
        defer allocator.free(old_hash);
        if (was_redacted and !(try eventWins(allocator, event_hash, old_hash))) return;
    }
    var update = try db.prepare(
        \\UPDATE comments
        \\SET redacted = 1, redacted_at = ?, redacted_actor_principal = ?, redacted_event_hash = ?
        \\WHERE id = ?
    );
    defer update.deinit();
    try update.bindText(1, envelope.occurred_at);
    try update.bindText(2, envelope.actor_principal);
    try update.bindText(3, event_hash);
    try update.bindText(4, comment_id);
    try update.stepDone();
}

fn insertReaction(
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

fn deleteReaction(
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

fn reactionLimitRejection(db: *SqliteDb, object_kind: []const u8, object_id: []const u8) !?[]const u8 {
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
