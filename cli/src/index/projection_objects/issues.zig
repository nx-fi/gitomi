const std = @import("std");

const common = @import("common.zig");
const projects = @import("projects.zig");
const reactions = @import("reactions.zig");

const event_json = common.event_json;
const git = common.git;
const Allocator = common.Allocator;
const SqliteDb = common.SqliteDb;
const ValidatedEnvelope = common.ValidatedEnvelope;
const ProjectedSourceIdentity = common.ProjectedSourceIdentity;
const sourceIdentityFromPayload = common.sourceIdentityFromPayload;
const upsertSourceIdentity = common.upsertSourceIdentity;
const creationEventWins = common.creationEventWins;
const acceptedCreationInFrontier = common.acceptedCreationInFrontier;
const insertLegacyAliasFromEnvelope = common.insertLegacyAliasFromEnvelope;
const eventWins = common.eventWins;
const collectionCountExceeds = common.collectionCountExceeds;
const insertIssueProject = common.insertIssueProject;
const max_projected_labels = common.max_projected_labels;
const max_projected_participants = common.max_projected_participants;
const max_projected_issue_relationships = common.max_projected_issue_relationships;
const max_projected_concurrent_groups = common.max_projected_concurrent_groups;
const projectIdFromPayloadOrName = projects.projectIdFromPayloadOrName;
const insertProjectMembership = projects.insertProjectMembership;
const deleteProjectMembership = projects.deleteProjectMembership;
const setStatusFieldValueIfPresent = projects.setStatusFieldValueIfPresent;
const clearStatusFieldValueIfPresent = projects.clearStatusFieldValueIfPresent;
const applyIssueProjectFieldSet = projects.applyIssueProjectFieldSet;
const applyIssueProjectFieldClear = projects.applyIssueProjectFieldClear;
const insertReaction = reactions.insertReaction;
const deleteReaction = reactions.deleteReaction;
const reactionLimitRejection = reactions.reactionLimitRejection;

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
        const title = event_json.jsonString(payload.get("title")) orelse return "invalid_event_envelope";
        const body_value = event_json.jsonString(payload.get("body")) orelse "";
        const source_identity = sourceIdentityFromPayload(payload);
        try upsertSourceIdentity(db, source_identity);
        try insertIssueOpened(db, event_hash, envelope, title, body_value);
        try upsertIssueMetadata(
            db,
            envelope.object_id,
            source_identity,
            event_json.jsonString(payload.get("milestone")) orelse "",
            event_json.jsonString(payload.get("type")) orelse "",
            event_json.jsonString(payload.get("priority")) orelse "",
            event_json.jsonString(payload.get("status")) orelse "",
            event_hash,
            envelope,
        );
        try insertLegacyAliasFromEnvelope(db, "issue", envelope.object_id, legacy);
        try insertPayloadStringArray(db, payload, "labels", insert_issue_label_sql, envelope.object_id, event_hash);
        try insertPayloadStringArray(db, payload, "assignees", insert_issue_assignee_sql, envelope.object_id, event_hash);
        try insertPayloadIssueProjects(db, payload, "projects", envelope.object_id, event_hash);
        return try issueCollectionLimitRejection(db, envelope.object_id);
    }

    if (!(try acceptedCreationInFrontier(allocator, db, "issue.opened", envelope.object_id, event_hash))) return "object_not_created";
    try insertLegacyAliasFromEnvelope(db, "issue", envelope.object_id, legacy);

    if (std.mem.eql(u8, envelope.event_type, "issue.updated")) {
        if (try applyIssueUpdated(allocator, db, payload, event_hash, envelope)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "issue.title_set")) {
        const title = event_json.jsonString(payload.get("title")) orelse return "invalid_event_envelope";
        try updateIssueScalar(allocator, db, envelope.object_id, title, event_hash, envelope, "title", "title_occurred_at", "title_actor_principal", "title_event_hash");
    } else if (std.mem.eql(u8, envelope.event_type, "issue.body_set")) {
        const body_value = event_json.jsonString(payload.get("body")) orelse return "invalid_event_envelope";
        try updateIssueScalar(allocator, db, envelope.object_id, body_value, event_hash, envelope, "body", "body_occurred_at", "body_actor_principal", "body_event_hash");
    } else if (std.mem.eql(u8, envelope.event_type, "issue.state_set")) {
        const state = event_json.jsonString(payload.get("state")) orelse return "invalid_event_envelope";
        if (std.mem.eql(u8, state, "open") and try issueStatusIsWip(db, envelope.object_id) and try concurrentGroupHasActivePeer(db, envelope.object_id)) {
            return "concurrent_group_busy";
        }
        try updateIssueScalar(allocator, db, envelope.object_id, state, event_hash, envelope, "state", "state_occurred_at", "state_actor_principal", "state_event_hash");
    } else if (std.mem.eql(u8, envelope.event_type, "issue.priority_set")) {
        const priority = event_json.jsonString(payload.get("priority")) orelse return "invalid_event_envelope";
        try updateIssueMetadataScalar(allocator, db, envelope.object_id, priority, event_hash, envelope, "priority", "priority_occurred_at", "priority_actor_principal", "priority_event_hash");
    } else if (std.mem.eql(u8, envelope.event_type, "issue.type_set")) {
        const issue_type = event_json.jsonString(payload.get("type")) orelse return "invalid_event_envelope";
        try updateIssueMetadataScalar(allocator, db, envelope.object_id, issue_type, event_hash, envelope, "issue_type", "issue_type_occurred_at", "issue_type_actor_principal", "issue_type_event_hash");
    } else if (std.mem.eql(u8, envelope.event_type, "issue.status_set")) {
        const status = event_json.jsonString(payload.get("status")) orelse return "invalid_event_envelope";
        if (std.mem.eql(u8, status, "WIP") and try issueStateIsOpen(db, envelope.object_id) and try concurrentGroupHasActivePeer(db, envelope.object_id)) {
            return "concurrent_group_busy";
        }
        try updateIssueMetadataScalar(allocator, db, envelope.object_id, status, event_hash, envelope, "status", "status_occurred_at", "status_actor_principal", "status_event_hash");
    } else if (std.mem.eql(u8, envelope.event_type, "issue.label_added")) {
        const label = event_json.jsonString(payload.get("label")) orelse return "invalid_event_envelope";
        try insertIssueCollectionValue(db, insert_issue_label_sql, envelope.object_id, label, event_hash);
        if (try issueCollectionLimitRejection(db, envelope.object_id)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "issue.label_removed")) {
        const label = event_json.jsonString(payload.get("label")) orelse return "invalid_event_envelope";
        try deleteIssueCollectionValue(allocator, db, "SELECT add_hash FROM issue_labels WHERE issue_id = ? AND label = ?", "DELETE FROM issue_labels WHERE issue_id = ? AND label = ? AND add_hash = ?", envelope.object_id, label, event_hash);
    } else if (std.mem.eql(u8, envelope.event_type, "issue.assignee_added")) {
        const assignee = event_json.jsonString(payload.get("assignee")) orelse return "invalid_event_envelope";
        try insertIssueCollectionValue(db, insert_issue_assignee_sql, envelope.object_id, assignee, event_hash);
        if (try issueCollectionLimitRejection(db, envelope.object_id)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "issue.assignee_removed")) {
        const assignee = event_json.jsonString(payload.get("assignee")) orelse return "invalid_event_envelope";
        try deleteIssueCollectionValue(allocator, db, "SELECT add_hash FROM issue_assignees WHERE issue_id = ? AND assignee = ?", "DELETE FROM issue_assignees WHERE issue_id = ? AND assignee = ? AND add_hash = ?", envelope.object_id, assignee, event_hash);
    } else if (std.mem.eql(u8, envelope.event_type, "issue.milestone_set")) {
        const milestone = event_json.jsonString(payload.get("milestone")) orelse return "invalid_event_envelope";
        try upsertIssueMilestone(db, envelope.object_id, milestone);
    } else if (std.mem.eql(u8, envelope.event_type, "issue.project_added")) {
        const project = event_json.jsonString(payload.get("project")) orelse return "invalid_event_envelope";
        const column = event_json.jsonString(payload.get("column")) orelse return "invalid_event_envelope";
        try insertIssueProject(db, envelope.object_id, project, column, event_hash);
        if (try projectIdFromPayloadOrName(allocator, db, payload, project)) |project_id| {
            defer allocator.free(project_id);
            try insertProjectMembership(db, project_id, envelope.object_id, event_hash, envelope);
            try setStatusFieldValueIfPresent(allocator, db, project_id, envelope.object_id, column, event_hash, envelope);
        }
        if (try issueCollectionLimitRejection(db, envelope.object_id)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "issue.project_removed")) {
        const project = event_json.jsonString(payload.get("project")) orelse return "invalid_event_envelope";
        const column = event_json.jsonString(payload.get("column")) orelse return "invalid_event_envelope";
        try deleteIssueProject(allocator, db, envelope.object_id, project, column, event_hash);
        if (try projectIdFromPayloadOrName(allocator, db, payload, project)) |project_id| {
            defer allocator.free(project_id);
            try deleteProjectMembership(allocator, db, project_id, envelope.object_id, event_hash);
            try clearStatusFieldValueIfPresent(allocator, db, project_id, envelope.object_id, event_hash);
        }
    } else if (std.mem.eql(u8, envelope.event_type, "issue.relationship_added")) {
        if (try applyIssueRelationshipAdded(allocator, db, payload, event_hash, envelope)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "issue.relationship_removed")) {
        if (try applyIssueRelationshipRemoved(allocator, db, payload, event_hash, envelope)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "issue.concurrent_group_added")) {
        const group = event_json.jsonString(payload.get("group")) orelse return "invalid_event_envelope";
        if (std.mem.trim(u8, group, " \t\r\n").len == 0) return "invalid_event_envelope";
        try insertIssueConcurrentGroup(db, envelope.object_id, group, event_hash, envelope);
        if (try concurrentGroupBusy(db, group)) return "concurrent_group_busy";
        if (try issueCollectionLimitRejection(db, envelope.object_id)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "issue.concurrent_group_removed")) {
        const group = event_json.jsonString(payload.get("group")) orelse return "invalid_event_envelope";
        if (std.mem.trim(u8, group, " \t\r\n").len == 0) return "invalid_event_envelope";
        try deleteIssueConcurrentGroup(allocator, db, envelope.object_id, group, event_hash);
    } else if (std.mem.eql(u8, envelope.event_type, "issue.project_field_set")) {
        if (try applyIssueProjectFieldSet(allocator, db, envelope.object_id, payload, event_hash, envelope)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "issue.project_field_cleared")) {
        if (try applyIssueProjectFieldClear(allocator, db, envelope.object_id, payload, event_hash)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "issue.reaction_added")) {
        const emoji = event_json.jsonString(payload.get("emoji")) orelse return "invalid_event_envelope";
        try insertReaction(db, "issue", envelope.object_id, emoji, envelope.actor_principal, event_hash, envelope.occurred_at);
        if (try reactionLimitRejection(db, "issue", envelope.object_id)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "issue.reaction_removed")) {
        const emoji = event_json.jsonString(payload.get("emoji")) orelse return "invalid_event_envelope";
        try deleteReaction(allocator, db, "issue", envelope.object_id, emoji, envelope.actor_principal, event_hash, payload);
    }
    return null;
}

const insert_issue_label_sql = "INSERT OR IGNORE INTO issue_labels(issue_id, label, add_hash) VALUES (?, ?, ?)";
const insert_issue_assignee_sql = "INSERT OR IGNORE INTO issue_assignees(issue_id, assignee, add_hash) VALUES (?, ?, ?)";
const insert_issue_relationship_sql = "INSERT OR IGNORE INTO issue_relationships(source_issue_id, relationship, target_issue_id, add_hash, created_at, actor_principal) VALUES (?, ?, ?, ?, ?, ?)";
const insert_issue_concurrent_group_sql = "INSERT OR IGNORE INTO issue_concurrent_groups(issue_id, group_key, add_hash, created_at, actor_principal) VALUES (?, ?, ?, ?, ?)";

fn applyIssueUpdated(
    allocator: Allocator,
    db: *SqliteDb,
    payload: std.json.ObjectMap,
    event_hash: []const u8,
    envelope: ValidatedEnvelope,
) !?[]const u8 {
    if (event_json.jsonString(payload.get("title"))) |title| {
        try updateIssueScalar(allocator, db, envelope.object_id, title, event_hash, envelope, "title", "title_occurred_at", "title_actor_principal", "title_event_hash");
    }
    if (event_json.jsonString(payload.get("body"))) |body_value| {
        try updateIssueScalar(allocator, db, envelope.object_id, body_value, event_hash, envelope, "body", "body_occurred_at", "body_actor_principal", "body_event_hash");
    }
    if (event_json.jsonString(payload.get("state"))) |state| {
        if (std.mem.eql(u8, state, "open") and try issueStatusIsWip(db, envelope.object_id) and try concurrentGroupHasActivePeer(db, envelope.object_id)) {
            return "concurrent_group_busy";
        }
        try updateIssueScalar(allocator, db, envelope.object_id, state, event_hash, envelope, "state", "state_occurred_at", "state_actor_principal", "state_event_hash");
    }
    if (event_json.jsonString(payload.get("milestone"))) |milestone| {
        try upsertIssueMilestone(db, envelope.object_id, milestone);
    }
    if (event_json.jsonString(payload.get("type"))) |issue_type| {
        try updateIssueMetadataScalar(allocator, db, envelope.object_id, issue_type, event_hash, envelope, "issue_type", "issue_type_occurred_at", "issue_type_actor_principal", "issue_type_event_hash");
    }
    if (event_json.jsonString(payload.get("priority"))) |priority| {
        try updateIssueMetadataScalar(allocator, db, envelope.object_id, priority, event_hash, envelope, "priority", "priority_occurred_at", "priority_actor_principal", "priority_event_hash");
    }
    if (event_json.jsonString(payload.get("status"))) |status| {
        if (std.mem.eql(u8, status, "WIP") and try issueStateIsOpen(db, envelope.object_id) and try concurrentGroupHasActivePeer(db, envelope.object_id)) {
            return "concurrent_group_busy";
        }
        try updateIssueMetadataScalar(allocator, db, envelope.object_id, status, event_hash, envelope, "status", "status_occurred_at", "status_actor_principal", "status_event_hash");
    }
    try insertPayloadIssueProjects(db, payload, "projects", envelope.object_id, event_hash);
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

fn upsertIssueMetadata(
    db: *SqliteDb,
    issue_id: []const u8,
    source_identity: ProjectedSourceIdentity,
    milestone: []const u8,
    issue_type: []const u8,
    priority: []const u8,
    status: []const u8,
    event_hash: []const u8,
    envelope: ValidatedEnvelope,
) !void {
    var stmt = try db.prepare(
        \\INSERT INTO issue_metadata(
        \\  issue_id, source_author, source_identity, source_email, source_avatar_url, milestone,
        \\  issue_type, issue_type_occurred_at, issue_type_actor_principal, issue_type_event_hash,
        \\  priority, priority_occurred_at, priority_actor_principal, priority_event_hash,
        \\  status, status_occurred_at, status_actor_principal, status_event_hash
        \\)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(issue_id) DO UPDATE SET
        \\  source_author = excluded.source_author,
        \\  source_identity = excluded.source_identity,
        \\  source_email = excluded.source_email,
        \\  source_avatar_url = excluded.source_avatar_url,
        \\  milestone = excluded.milestone
    );
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    try stmt.bindText(2, source_identity.author);
    try stmt.bindText(3, source_identity.identity);
    try stmt.bindText(4, source_identity.email);
    try stmt.bindText(5, source_identity.avatar_url);
    try stmt.bindText(6, milestone);
    try stmt.bindText(7, issue_type);
    try stmt.bindText(8, envelope.occurred_at);
    try stmt.bindText(9, envelope.actor_principal);
    try stmt.bindText(10, event_hash);
    try stmt.bindText(11, priority);
    try stmt.bindText(12, envelope.occurred_at);
    try stmt.bindText(13, envelope.actor_principal);
    try stmt.bindText(14, event_hash);
    try stmt.bindText(15, status);
    try stmt.bindText(16, envelope.occurred_at);
    try stmt.bindText(17, envelope.actor_principal);
    try stmt.bindText(18, event_hash);
    try stmt.stepDone();
}

fn upsertIssueMilestone(db: *SqliteDb, issue_id: []const u8, milestone: []const u8) !void {
    var stmt = try db.prepare(
        \\INSERT INTO issue_metadata(
        \\  issue_id, source_author, source_identity, source_email, source_avatar_url, milestone,
        \\  issue_type, issue_type_occurred_at, issue_type_actor_principal, issue_type_event_hash,
        \\  priority, priority_occurred_at, priority_actor_principal, priority_event_hash,
        \\  status, status_occurred_at, status_actor_principal, status_event_hash
        \\)
        \\VALUES (?, '', '', '', '', ?, '', '', '', '', '', '', '', '', '', '', '', '')
        \\ON CONFLICT(issue_id) DO UPDATE SET milestone = excluded.milestone
    );
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    try stmt.bindText(2, milestone);
    try stmt.stepDone();
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

fn updateIssueMetadataScalar(
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
    var ensure = try db.prepare(
        \\INSERT OR IGNORE INTO issue_metadata(
        \\  issue_id, source_author, source_identity, source_email, source_avatar_url, milestone,
        \\  issue_type, issue_type_occurred_at, issue_type_actor_principal, issue_type_event_hash,
        \\  priority, priority_occurred_at, priority_actor_principal, priority_event_hash,
        \\  status, status_occurred_at, status_actor_principal, status_event_hash
        \\)
        \\VALUES (?, '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '')
    );
    defer ensure.deinit();
    try ensure.bindText(1, issue_id);
    try ensure.stepDone();

    var select = try db.prepare("SELECT " ++ occurred_at_col ++ ", " ++ actor_col ++ ", " ++ event_hash_col ++ " FROM issue_metadata WHERE issue_id = ?");
    defer select.deinit();
    try select.bindText(1, issue_id);
    if (!(try select.step())) return;
    const old_event_hash = try select.columnTextDup(allocator, 2);
    defer allocator.free(old_event_hash);

    if (old_event_hash.len != 0 and !(try eventWins(allocator, event_hash, old_event_hash))) {
        return;
    }

    var update = try db.prepare("UPDATE issue_metadata SET " ++ value_col ++ " = ?, " ++ occurred_at_col ++ " = ?, " ++ actor_col ++ " = ?, " ++ event_hash_col ++ " = ? WHERE issue_id = ?");
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
        const project_name = event_json.jsonString(project.get("project")) orelse continue;
        const column = event_json.jsonString(project.get("column")) orelse "";
        try insertIssueProject(db, issue_id, project_name, column, event_hash);
    }
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

fn applyIssueRelationshipAdded(
    allocator: Allocator,
    db: *SqliteDb,
    payload: std.json.ObjectMap,
    event_hash: []const u8,
    envelope: ValidatedEnvelope,
) !?[]const u8 {
    const relationship = event_json.jsonString(payload.get("kind")) orelse return "invalid_event_envelope";
    const target_id = event_json.jsonString(payload.get("target_id")) orelse return "invalid_event_envelope";
    if (!isIssueRelationshipKind(relationship)) return "invalid_issue_relationship";
    if (std.mem.eql(u8, envelope.object_id, target_id)) return "invalid_issue_relationship";
    if (!(try acceptedCreationInFrontier(allocator, db, "issue.opened", target_id, event_hash))) return "target_not_created";

    try insertIssueRelationship(db, envelope.object_id, relationship, target_id, event_hash, envelope);
    if (std.mem.eql(u8, relationship, "parent")) {
        if (try issueParentCycleExists(db, envelope.object_id)) return "parent_cycle";
        if (try issueParentCount(db, envelope.object_id) > 1) return "parent_conflict";
    }
    return try issueCollectionLimitRejection(db, envelope.object_id);
}

fn applyIssueRelationshipRemoved(
    allocator: Allocator,
    db: *SqliteDb,
    payload: std.json.ObjectMap,
    event_hash: []const u8,
    envelope: ValidatedEnvelope,
) !?[]const u8 {
    const relationship = event_json.jsonString(payload.get("kind")) orelse return "invalid_event_envelope";
    const target_id = event_json.jsonString(payload.get("target_id")) orelse return "invalid_event_envelope";
    if (!isIssueRelationshipKind(relationship)) return "invalid_issue_relationship";
    try deleteIssueRelationship(allocator, db, envelope.object_id, relationship, target_id, event_hash);
    return null;
}

fn isIssueRelationshipKind(value: []const u8) bool {
    return std.mem.eql(u8, value, "parent") or std.mem.eql(u8, value, "blocks");
}

fn insertIssueRelationship(
    db: *SqliteDb,
    source_issue_id: []const u8,
    relationship: []const u8,
    target_issue_id: []const u8,
    event_hash: []const u8,
    envelope: ValidatedEnvelope,
) !void {
    var stmt = try db.prepare(insert_issue_relationship_sql);
    defer stmt.deinit();
    try stmt.bindText(1, source_issue_id);
    try stmt.bindText(2, relationship);
    try stmt.bindText(3, target_issue_id);
    try stmt.bindText(4, event_hash);
    try stmt.bindText(5, envelope.occurred_at);
    try stmt.bindText(6, envelope.actor_principal);
    try stmt.stepDone();
}

fn deleteIssueRelationship(
    allocator: Allocator,
    db: *SqliteDb,
    source_issue_id: []const u8,
    relationship: []const u8,
    target_issue_id: []const u8,
    remove_hash: []const u8,
) !void {
    var select = try db.prepare(
        \\SELECT add_hash
        \\FROM issue_relationships
        \\WHERE source_issue_id = ?
        \\  AND relationship = ?
        \\  AND target_issue_id = ?
    );
    defer select.deinit();
    try select.bindText(1, source_issue_id);
    try select.bindText(2, relationship);
    try select.bindText(3, target_issue_id);
    while (try select.step()) {
        const add_hash = try select.columnTextDup(allocator, 0);
        defer allocator.free(add_hash);
        if (!(try git.isAncestor(allocator, add_hash, remove_hash))) continue;
        var delete = try db.prepare(
            \\DELETE FROM issue_relationships
            \\WHERE source_issue_id = ?
            \\  AND relationship = ?
            \\  AND target_issue_id = ?
            \\  AND add_hash = ?
        );
        defer delete.deinit();
        try delete.bindText(1, source_issue_id);
        try delete.bindText(2, relationship);
        try delete.bindText(3, target_issue_id);
        try delete.bindText(4, add_hash);
        try delete.stepDone();
    }
}

fn issueParentCycleExists(db: *SqliteDb, source_issue_id: []const u8) !bool {
    var stmt = try db.prepare(
        \\WITH RECURSIVE ancestors(id) AS (
        \\  SELECT target_issue_id
        \\  FROM issue_relationships
        \\  WHERE source_issue_id = ? AND relationship = 'parent'
        \\  UNION
        \\  SELECT r.target_issue_id
        \\  FROM issue_relationships r
        \\  JOIN ancestors a ON a.id = r.source_issue_id
        \\  WHERE r.relationship = 'parent'
        \\)
        \\SELECT 1 FROM ancestors WHERE id = ? LIMIT 1
    );
    defer stmt.deinit();
    try stmt.bindText(1, source_issue_id);
    try stmt.bindText(2, source_issue_id);
    return try stmt.step();
}

fn issueParentCount(db: *SqliteDb, issue_id: []const u8) !i64 {
    var stmt = try db.prepare(
        \\SELECT COUNT(DISTINCT target_issue_id)
        \\FROM issue_relationships
        \\WHERE source_issue_id = ? AND relationship = 'parent'
    );
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    if (!(try stmt.step())) return 0;
    return stmt.columnInt64(0);
}

fn insertIssueConcurrentGroup(
    db: *SqliteDb,
    issue_id: []const u8,
    group: []const u8,
    event_hash: []const u8,
    envelope: ValidatedEnvelope,
) !void {
    if (std.mem.trim(u8, group, " \t\r\n").len == 0) return;
    var stmt = try db.prepare(insert_issue_concurrent_group_sql);
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    try stmt.bindText(2, group);
    try stmt.bindText(3, event_hash);
    try stmt.bindText(4, envelope.occurred_at);
    try stmt.bindText(5, envelope.actor_principal);
    try stmt.stepDone();
}

fn deleteIssueConcurrentGroup(
    allocator: Allocator,
    db: *SqliteDb,
    issue_id: []const u8,
    group: []const u8,
    remove_hash: []const u8,
) !void {
    var select = try db.prepare("SELECT add_hash FROM issue_concurrent_groups WHERE issue_id = ? AND group_key = ?");
    defer select.deinit();
    try select.bindText(1, issue_id);
    try select.bindText(2, group);
    while (try select.step()) {
        const add_hash = try select.columnTextDup(allocator, 0);
        defer allocator.free(add_hash);
        if (!(try git.isAncestor(allocator, add_hash, remove_hash))) continue;
        var delete = try db.prepare("DELETE FROM issue_concurrent_groups WHERE issue_id = ? AND group_key = ? AND add_hash = ?");
        defer delete.deinit();
        try delete.bindText(1, issue_id);
        try delete.bindText(2, group);
        try delete.bindText(3, add_hash);
        try delete.stepDone();
    }
}

fn issueStateIsOpen(db: *SqliteDb, issue_id: []const u8) !bool {
    var stmt = try db.prepare("SELECT state FROM issues WHERE id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    if (!(try stmt.step())) return false;
    const state = try stmt.columnTextDup(db.allocator, 0);
    defer db.allocator.free(state);
    return std.mem.eql(u8, state, "open");
}

fn issueStatusIsWip(db: *SqliteDb, issue_id: []const u8) !bool {
    var stmt = try db.prepare("SELECT status FROM issue_metadata WHERE issue_id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    if (!(try stmt.step())) return false;
    const status = try stmt.columnTextDup(db.allocator, 0);
    defer db.allocator.free(status);
    return std.mem.eql(u8, status, "WIP");
}

fn concurrentGroupHasActivePeer(db: *SqliteDb, issue_id: []const u8) !bool {
    var stmt = try db.prepare(
        \\SELECT 1
        \\FROM issue_concurrent_groups mine
        \\JOIN issue_concurrent_groups peer ON peer.group_key = mine.group_key
        \\JOIN issues i ON i.id = peer.issue_id
        \\JOIN issue_metadata m ON m.issue_id = peer.issue_id
        \\WHERE mine.issue_id = ?
        \\  AND peer.issue_id <> mine.issue_id
        \\  AND i.state = 'open'
        \\  AND m.status = 'WIP'
        \\LIMIT 1
    );
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    return try stmt.step();
}

fn concurrentGroupBusy(db: *SqliteDb, group: []const u8) !bool {
    var stmt = try db.prepare(
        \\SELECT COUNT(DISTINCT g.issue_id)
        \\FROM issue_concurrent_groups g
        \\JOIN issues i ON i.id = g.issue_id
        \\JOIN issue_metadata m ON m.issue_id = g.issue_id
        \\WHERE g.group_key = ?
        \\  AND i.state = 'open'
        \\  AND m.status = 'WIP'
    );
    defer stmt.deinit();
    try stmt.bindText(1, group);
    if (!(try stmt.step())) return false;
    return stmt.columnInt64(0) > 1;
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
    if (try collectionCountExceeds(db, "SELECT COUNT(DISTINCT relationship || char(31) || target_issue_id) FROM issue_relationships WHERE source_issue_id = ?", issue_id, max_projected_issue_relationships)) {
        return "collection_limit_exceeded";
    }
    if (try collectionCountExceeds(db, "SELECT COUNT(DISTINCT group_key) FROM issue_concurrent_groups WHERE issue_id = ?", issue_id, max_projected_concurrent_groups)) {
        return "collection_limit_exceeded";
    }
    return null;
}
