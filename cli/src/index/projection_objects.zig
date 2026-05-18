const std = @import("std");

const event_mod = @import("../event.zig");
const git = @import("../git.zig");
const index_schema = @import("schema.zig");
const json_writer = @import("../json_writer.zig");
const ordering = @import("projection_ordering.zig");
const sqlite_db = @import("sqlite_db.zig");
const util = @import("../util.zig");

const Allocator = std.mem.Allocator;
const SqliteDb = sqlite_db.SqliteDb;
const ValidatedEnvelope = event_mod.ValidatedEnvelope;
const eventInFrontier = ordering.eventInFrontier;
const eventWins = ordering.eventWins;

const max_projected_labels: usize = 256;
const max_projected_participants: usize = 128;
const max_projected_issue_relationships: usize = 512;
const max_projected_concurrent_groups: usize = 128;
const max_projected_project_columns: usize = 128;
const max_projected_project_milestones: usize = 256;
const max_projected_project_fields: usize = 128;
const max_projected_project_field_options: usize = 512;
const max_projected_project_views: usize = 64;
const default_project_status = "Planned";
const max_projected_reaction_emojis: usize = 64;
const max_projected_reaction_actors: usize = 1024;

const ProjectedSourceIdentity = struct {
    identity: []const u8,
    author: []const u8,
    email: []const u8,
    avatar_url: []const u8,
};

fn sourceIdentityFromPayload(payload: std.json.ObjectMap) ProjectedSourceIdentity {
    return .{
        .identity = event_mod.jsonString(payload.get("source_identity")) orelse "",
        .author = event_mod.jsonString(payload.get("source_author")) orelse "",
        .email = event_mod.jsonString(payload.get("source_email")) orelse "",
        .avatar_url = event_mod.jsonString(payload.get("source_avatar_url")) orelse "",
    };
}

fn upsertSourceIdentity(db: *SqliteDb, source: ProjectedSourceIdentity) !void {
    if (source.identity.len == 0) return;
    const split = std.mem.indexOfScalar(u8, source.identity, ':');
    const provider = if (split) |idx| source.identity[0..idx] else "";
    const provider_user_id = if (split) |idx| source.identity[idx + 1 ..] else source.identity;

    var stmt = try db.prepare(
        \\INSERT INTO identities(id, provider, provider_user_id, display_name, email, avatar_url)
        \\VALUES (?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(id) DO UPDATE SET
        \\  provider = COALESCE(NULLIF(excluded.provider, ''), identities.provider),
        \\  provider_user_id = COALESCE(NULLIF(excluded.provider_user_id, ''), identities.provider_user_id),
        \\  display_name = COALESCE(NULLIF(excluded.display_name, ''), identities.display_name),
        \\  email = COALESCE(NULLIF(excluded.email, ''), identities.email),
        \\  avatar_url = COALESCE(NULLIF(excluded.avatar_url, ''), identities.avatar_url)
    );
    defer stmt.deinit();
    try stmt.bindText(1, source.identity);
    try stmt.bindText(2, provider);
    try stmt.bindText(3, provider_user_id);
    try stmt.bindText(4, source.author);
    try stmt.bindText(5, source.email);
    try stmt.bindText(6, source.avatar_url);
    try stmt.stepDone();

    try upsertIdentityAlias(db, "display", source.author, source.identity);
    try upsertIdentityAlias(db, "email", source.email, source.identity);
}

fn upsertIdentityAlias(db: *SqliteDb, kind: []const u8, value: []const u8, identity: []const u8) !void {
    if (value.len == 0) return;
    var stmt = try db.prepare(
        \\INSERT INTO identity_aliases(alias_kind, alias_value, identity_id)
        \\VALUES (?, ?, ?)
        \\ON CONFLICT(alias_kind, alias_value) DO UPDATE SET identity_id = excluded.identity_id
    );
    defer stmt.deinit();
    try stmt.bindText(1, kind);
    try stmt.bindText(2, value);
    try stmt.bindText(3, identity);
    try stmt.stepDone();
}

fn creationEventWins(db: *SqliteDb, event_type: []const u8, object_id: []const u8, event_hash: []const u8) !bool {
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

fn acceptedCreationInFrontier(
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

fn acceptedCreationHashInFrontier(
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
        const source_identity = sourceIdentityFromPayload(payload);
        try upsertSourceIdentity(db, source_identity);
        try insertIssueOpened(db, event_hash, envelope, title, body_value);
        try upsertIssueMetadata(
            db,
            envelope.object_id,
            source_identity,
            event_mod.jsonString(payload.get("milestone")) orelse "",
            event_mod.jsonString(payload.get("type")) orelse "",
            event_mod.jsonString(payload.get("priority")) orelse "",
            event_mod.jsonString(payload.get("status")) orelse "",
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
        const title = event_mod.jsonString(payload.get("title")) orelse return "invalid_event_envelope";
        try updateIssueScalar(allocator, db, envelope.object_id, title, event_hash, envelope, "title", "title_occurred_at", "title_actor_principal", "title_event_hash");
    } else if (std.mem.eql(u8, envelope.event_type, "issue.body_set")) {
        const body_value = event_mod.jsonString(payload.get("body")) orelse return "invalid_event_envelope";
        try updateIssueScalar(allocator, db, envelope.object_id, body_value, event_hash, envelope, "body", "body_occurred_at", "body_actor_principal", "body_event_hash");
    } else if (std.mem.eql(u8, envelope.event_type, "issue.state_set")) {
        const state = event_mod.jsonString(payload.get("state")) orelse return "invalid_event_envelope";
        if (std.mem.eql(u8, state, "open") and try issueStatusIsWip(db, envelope.object_id) and try concurrentGroupHasActivePeer(db, envelope.object_id)) {
            return "concurrent_group_busy";
        }
        try updateIssueScalar(allocator, db, envelope.object_id, state, event_hash, envelope, "state", "state_occurred_at", "state_actor_principal", "state_event_hash");
    } else if (std.mem.eql(u8, envelope.event_type, "issue.priority_set")) {
        const priority = event_mod.jsonString(payload.get("priority")) orelse return "invalid_event_envelope";
        try updateIssueMetadataScalar(allocator, db, envelope.object_id, priority, event_hash, envelope, "priority", "priority_occurred_at", "priority_actor_principal", "priority_event_hash");
    } else if (std.mem.eql(u8, envelope.event_type, "issue.type_set")) {
        const issue_type = event_mod.jsonString(payload.get("type")) orelse return "invalid_event_envelope";
        try updateIssueMetadataScalar(allocator, db, envelope.object_id, issue_type, event_hash, envelope, "issue_type", "issue_type_occurred_at", "issue_type_actor_principal", "issue_type_event_hash");
    } else if (std.mem.eql(u8, envelope.event_type, "issue.status_set")) {
        const status = event_mod.jsonString(payload.get("status")) orelse return "invalid_event_envelope";
        if (std.mem.eql(u8, status, "WIP") and try issueStateIsOpen(db, envelope.object_id) and try concurrentGroupHasActivePeer(db, envelope.object_id)) {
            return "concurrent_group_busy";
        }
        try updateIssueMetadataScalar(allocator, db, envelope.object_id, status, event_hash, envelope, "status", "status_occurred_at", "status_actor_principal", "status_event_hash");
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
        if (try projectIdFromPayloadOrName(allocator, db, payload, project)) |project_id| {
            defer allocator.free(project_id);
            try insertProjectMembership(db, project_id, envelope.object_id, event_hash, envelope);
            try setStatusFieldValueIfPresent(allocator, db, project_id, envelope.object_id, column, event_hash, envelope);
        }
        if (try issueCollectionLimitRejection(db, envelope.object_id)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "issue.project_removed")) {
        const project = event_mod.jsonString(payload.get("project")) orelse return "invalid_event_envelope";
        const column = event_mod.jsonString(payload.get("column")) orelse return "invalid_event_envelope";
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
        const group = event_mod.jsonString(payload.get("group")) orelse return "invalid_event_envelope";
        if (std.mem.trim(u8, group, " \t\r\n").len == 0) return "invalid_event_envelope";
        try insertIssueConcurrentGroup(db, envelope.object_id, group, event_hash, envelope);
        if (try concurrentGroupBusy(db, group)) return "concurrent_group_busy";
        if (try issueCollectionLimitRejection(db, envelope.object_id)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "issue.concurrent_group_removed")) {
        const group = event_mod.jsonString(payload.get("group")) orelse return "invalid_event_envelope";
        if (std.mem.trim(u8, group, " \t\r\n").len == 0) return "invalid_event_envelope";
        try deleteIssueConcurrentGroup(allocator, db, envelope.object_id, group, event_hash);
    } else if (std.mem.eql(u8, envelope.event_type, "issue.project_field_set")) {
        if (try applyIssueProjectFieldSet(allocator, db, envelope.object_id, payload, event_hash, envelope)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "issue.project_field_cleared")) {
        if (try applyIssueProjectFieldClear(allocator, db, envelope.object_id, payload, event_hash)) |reason| return reason;
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
const insert_issue_relationship_sql = "INSERT OR IGNORE INTO issue_relationships(source_issue_id, relationship, target_issue_id, add_hash, created_at, actor_principal) VALUES (?, ?, ?, ?, ?, ?)";
const insert_issue_concurrent_group_sql = "INSERT OR IGNORE INTO issue_concurrent_groups(issue_id, group_key, add_hash, created_at, actor_principal) VALUES (?, ?, ?, ?, ?)";

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
        if (std.mem.eql(u8, state, "open") and try issueStatusIsWip(db, envelope.object_id) and try concurrentGroupHasActivePeer(db, envelope.object_id)) {
            return "concurrent_group_busy";
        }
        try updateIssueScalar(allocator, db, envelope.object_id, state, event_hash, envelope, "state", "state_occurred_at", "state_actor_principal", "state_event_hash");
    }
    if (event_mod.jsonString(payload.get("milestone"))) |milestone| {
        try upsertIssueMilestone(db, envelope.object_id, milestone);
    }
    if (event_mod.jsonString(payload.get("type"))) |issue_type| {
        try updateIssueMetadataScalar(allocator, db, envelope.object_id, issue_type, event_hash, envelope, "issue_type", "issue_type_occurred_at", "issue_type_actor_principal", "issue_type_event_hash");
    }
    if (event_mod.jsonString(payload.get("priority"))) |priority| {
        try updateIssueMetadataScalar(allocator, db, envelope.object_id, priority, event_hash, envelope, "priority", "priority_occurred_at", "priority_actor_principal", "priority_event_hash");
    }
    if (event_mod.jsonString(payload.get("status"))) |status| {
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

fn upsertPullMetadata(
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

fn metadataCount(payload: std.json.ObjectMap, key: []const u8) i64 {
    const value = event_mod.jsonInteger(payload.get(key)) orelse return -1;
    return if (value >= 0) value else -1;
}

fn insertLegacyAliasFromEnvelope(db: *SqliteDb, object_kind: []const u8, object_id: []const u8, legacy: std.json.ObjectMap) !void {
    if (std.mem.eql(u8, object_kind, "issue")) {
        try insertLegacyAliasField(db, "github", object_kind, object_id, legacy, "github_issue_number");
        try insertLegacyAliasField(db, "gitlab", object_kind, object_id, legacy, "gitlab_issue_iid");
    } else if (std.mem.eql(u8, object_kind, "pull")) {
        try insertLegacyAliasField(db, "github", object_kind, object_id, legacy, "github_pull_number");
        try insertLegacyAliasField(db, "gitlab", object_kind, object_id, legacy, "gitlab_merge_request_iid");
    }
}

fn insertLegacyAliasField(db: *SqliteDb, provider: []const u8, object_kind: []const u8, object_id: []const u8, legacy: std.json.ObjectMap, key: []const u8) !void {
    const number = event_mod.jsonInteger(legacy.get(key)) orelse return;
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

fn applyIssueRelationshipAdded(
    allocator: Allocator,
    db: *SqliteDb,
    payload: std.json.ObjectMap,
    event_hash: []const u8,
    envelope: ValidatedEnvelope,
) !?[]const u8 {
    const relationship = event_mod.jsonString(payload.get("kind")) orelse return "invalid_event_envelope";
    const target_id = event_mod.jsonString(payload.get("target_id")) orelse return "invalid_event_envelope";
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
    const relationship = event_mod.jsonString(payload.get("kind")) orelse return "invalid_event_envelope";
    const target_id = event_mod.jsonString(payload.get("target_id")) orelse return "invalid_event_envelope";
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
        const slug = try projectSlugForCreate(allocator, db, payload, envelope.object_id, name);
        defer allocator.free(slug);
        const description = event_mod.jsonString(payload.get("description")) orelse "";
        const state = event_mod.jsonString(payload.get("state")) orelse "open";
        try insertProjectCreated(db, event_hash, envelope, name, slug, description, state);
        try insertPayloadProjectColumns(allocator, db, payload, envelope.object_id, event_hash);
        if (try projectColumnLimitRejection(db, envelope.object_id)) |reason| return reason;
        return try projectPropertyLimitRejection(db, envelope.object_id);
    }

    if (!(try acceptedCreationInFrontier(allocator, db, "project.created", envelope.object_id, event_hash))) return "object_not_created";

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
        if (event_mod.jsonString(payload.get("status"))) |status| {
            try updateProjectScalar(allocator, db, envelope.object_id, status, event_hash, envelope, "status", "status_occurred_at", "status_actor_principal", "status_event_hash");
        }
        if (event_mod.jsonString(payload.get("priority"))) |priority| {
            try updateProjectScalar(allocator, db, envelope.object_id, priority, event_hash, envelope, "priority", "priority_occurred_at", "priority_actor_principal", "priority_event_hash");
        }
        if (event_mod.jsonString(payload.get("start_at"))) |start_at| {
            try updateProjectScalar(allocator, db, envelope.object_id, start_at, event_hash, envelope, "start_at", "start_at_occurred_at", "start_at_actor_principal", "start_at_event_hash");
        }
        if (event_mod.jsonString(payload.get("end_at"))) |end_at| {
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
        const column = event_mod.jsonString(payload.get("column")) orelse return "invalid_event_envelope";
        const column_ref = try projectColumnRefForAdd(allocator, db, payload, envelope.object_id, column);
        defer allocator.free(column_ref);
        try insertProjectColumn(db, envelope.object_id, column, column_ref, event_hash);
        if (try projectColumnLimitRejection(db, envelope.object_id)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "project.column_removed")) {
        const column = event_mod.jsonString(payload.get("column")) orelse return "invalid_event_envelope";
        try deleteProjectColumn(allocator, db, envelope.object_id, column, event_hash);
    } else if (std.mem.eql(u8, envelope.event_type, "project.field_created")) {
        if (try applyProjectFieldCreated(allocator, db, payload, envelope.object_id, event_hash, envelope)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "project.field_updated")) {
        if (try applyProjectFieldUpdated(allocator, db, payload, envelope.object_id, event_hash, envelope)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "project.field_removed")) {
        const field_id = event_mod.jsonString(payload.get("field_id")) orelse return "invalid_event_envelope";
        try updateProjectFieldState(allocator, db, envelope.object_id, field_id, "removed", event_hash, envelope);
    } else if (std.mem.eql(u8, envelope.event_type, "project.field_option_added")) {
        if (try applyProjectFieldOptionAdded(db, payload, envelope.object_id, event_hash, envelope)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "project.field_option_updated")) {
        if (try applyProjectFieldOptionUpdated(allocator, db, payload, envelope.object_id, event_hash, envelope)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "project.field_option_removed")) {
        const field_id = event_mod.jsonString(payload.get("field_id")) orelse return "invalid_event_envelope";
        const option_id = event_mod.jsonString(payload.get("option_id")) orelse return "invalid_event_envelope";
        try updateProjectFieldOptionState(allocator, db, envelope.object_id, field_id, option_id, "removed", event_hash, envelope);
    } else if (std.mem.eql(u8, envelope.event_type, "project.view_created")) {
        if (try applyProjectViewCreated(allocator, db, payload, envelope.object_id, event_hash, envelope)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "project.view_updated")) {
        if (try applyProjectViewUpdated(allocator, db, payload, envelope.object_id, event_hash, envelope)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "project.view_removed")) {
        const view_id = event_mod.jsonString(payload.get("view_id")) orelse return "invalid_event_envelope";
        try updateProjectViewState(allocator, db, envelope.object_id, view_id, "removed", event_hash, envelope);
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

    if (!(try acceptedCreationInFrontier(allocator, db, "milestone.created", envelope.object_id, event_hash))) return "object_not_created";

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
    } else if (std.mem.eql(u8, envelope.event_type, "milestone.deleted")) {
        try deleteMilestone(db, envelope.object_id);
    } else {
        return "unknown_event_type";
    }
    return null;
}

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
        const name = event_mod.jsonString(payload.get("name")) orelse return "invalid_event_envelope";
        if (std.mem.trim(u8, name, " \t\r\n").len == 0) return "invalid_event_envelope";
        if (try labelNameInUse(db, name, null)) return "duplicate_label_name";
        const description = event_mod.jsonString(payload.get("description")) orelse "";
        const color = event_mod.jsonString(payload.get("color")) orelse "#6e7681";
        const priority = event_mod.jsonInteger(payload.get("priority")) orelse event_mod.jsonInteger(payload.get("position")) orelse 0;
        try insertLabelCreated(db, event_hash, envelope, name, description, color, priority);
        return null;
    }

    if (!(try acceptedCreationInFrontier(allocator, db, "label.created", envelope.object_id, event_hash))) return "object_not_created";

    if (std.mem.eql(u8, envelope.event_type, "label.updated")) {
        if (event_mod.jsonString(payload.get("name"))) |name| {
            if (std.mem.trim(u8, name, " \t\r\n").len == 0) return "invalid_event_envelope";
            if (try labelNameInUse(db, name, envelope.object_id)) return "duplicate_label_name";
            try updateLabelScalar(allocator, db, envelope.object_id, name, event_hash, envelope, "name", "name_occurred_at", "name_actor_principal", "name_event_hash");
        }
        if (event_mod.jsonString(payload.get("description"))) |description| {
            try updateLabelScalar(allocator, db, envelope.object_id, description, event_hash, envelope, "description", "description_occurred_at", "description_actor_principal", "description_event_hash");
        }
        if (event_mod.jsonString(payload.get("color"))) |color| {
            try updateLabelScalar(allocator, db, envelope.object_id, color, event_hash, envelope, "color", "color_occurred_at", "color_actor_principal", "color_event_hash");
        }
        const priority = event_mod.jsonInteger(payload.get("priority")) orelse event_mod.jsonInteger(payload.get("position"));
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
    const raw_slug = event_mod.jsonString(payload.get("slug")) orelse name;
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
    if (event_mod.jsonString(payload.get("column_ref"))) |column_ref| {
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
    const field_id = event_mod.jsonString(payload.get("field_id")) orelse return "invalid_event_envelope";
    const key = event_mod.jsonString(payload.get("key")) orelse return "invalid_event_envelope";
    const name = event_mod.jsonString(payload.get("name")) orelse return "invalid_event_envelope";
    const field_type = event_mod.jsonString(payload.get("type")) orelse return "invalid_event_envelope";
    const position = jsonInteger(payload.get("position")) orelse 0;
    const required = jsonBool(payload.get("required")) orelse false;
    const default_value_json = try jsonValueOrDefaultOwned(allocator, payload.get("default_value"), "null");
    defer allocator.free(default_value_json);
    const state = event_mod.jsonString(payload.get("state")) orelse "active";

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
    const field_id = event_mod.jsonString(payload.get("field_id")) orelse return "invalid_event_envelope";
    var current = try loadProjectField(allocator, db, project_id, field_id) orelse return "object_not_created";
    defer current.deinit(allocator);
    if (!(try eventWins(allocator, event_hash, current.event_hash))) return null;

    const key = event_mod.jsonString(payload.get("key")) orelse current.key;
    const name = event_mod.jsonString(payload.get("name")) orelse current.name;
    const field_type = event_mod.jsonString(payload.get("type")) orelse current.field_type;
    const position = jsonInteger(payload.get("position")) orelse current.position;
    const required = jsonBool(payload.get("required")) orelse current.required;
    const default_value_json = try jsonValueOrDefaultOwned(allocator, payload.get("default_value"), current.default_value_json);
    defer allocator.free(default_value_json);
    const state = event_mod.jsonString(payload.get("state")) orelse current.state;

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
    const field_id = event_mod.jsonString(payload.get("field_id")) orelse return "invalid_event_envelope";
    if (!(try projectFieldExists(db, project_id, field_id))) return "object_not_created";
    const option_id = event_mod.jsonString(payload.get("option_id")) orelse return "invalid_event_envelope";
    const name = event_mod.jsonString(payload.get("name")) orelse return "invalid_event_envelope";
    const color = event_mod.jsonString(payload.get("color")) orelse "";
    const position = jsonInteger(payload.get("position")) orelse 0;
    const state = event_mod.jsonString(payload.get("state")) orelse "active";

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
    const field_id = event_mod.jsonString(payload.get("field_id")) orelse return "invalid_event_envelope";
    const option_id = event_mod.jsonString(payload.get("option_id")) orelse return "invalid_event_envelope";
    var current = try loadProjectFieldOption(allocator, db, project_id, field_id, option_id) orelse return "object_not_created";
    defer current.deinit(allocator);
    if (!(try eventWins(allocator, event_hash, current.event_hash))) return null;
    const name = event_mod.jsonString(payload.get("name")) orelse current.name;
    const color = event_mod.jsonString(payload.get("color")) orelse current.color;
    const position = jsonInteger(payload.get("position")) orelse current.position;
    const state = event_mod.jsonString(payload.get("state")) orelse current.state;

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
    const view_id = event_mod.jsonString(payload.get("view_id")) orelse return "invalid_event_envelope";
    const name = event_mod.jsonString(payload.get("name")) orelse return "invalid_event_envelope";
    const layout = event_mod.jsonString(payload.get("layout")) orelse return "invalid_event_envelope";
    const position = jsonInteger(payload.get("position")) orelse 0;
    const config_json = try jsonValueOrDefaultOwned(allocator, payload.get("config"), "{}");
    defer allocator.free(config_json);
    const state = event_mod.jsonString(payload.get("state")) orelse "active";

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
    const view_id = event_mod.jsonString(payload.get("view_id")) orelse return "invalid_event_envelope";
    var current = try loadProjectView(allocator, db, project_id, view_id) orelse return "object_not_created";
    defer current.deinit(allocator);
    if (!(try eventWins(allocator, event_hash, current.event_hash))) return null;
    const name = event_mod.jsonString(payload.get("name")) orelse current.name;
    const layout = event_mod.jsonString(payload.get("layout")) orelse current.layout;
    const position = jsonInteger(payload.get("position")) orelse current.position;
    const config_json = try jsonValueOrDefaultOwned(allocator, payload.get("config"), current.config_json);
    defer allocator.free(config_json);
    const state = event_mod.jsonString(payload.get("state")) orelse current.state;

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

fn applyIssueProjectFieldSet(
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

fn applyIssueProjectFieldClear(
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

fn insertProjectMembership(db: *SqliteDb, project_id: []const u8, issue_id: []const u8, event_hash: []const u8, envelope: ValidatedEnvelope) !void {
    var stmt = try db.prepare("INSERT OR IGNORE INTO project_memberships(project_id, issue_id, add_hash, created_at, actor_principal) VALUES (?, ?, ?, ?, ?)");
    defer stmt.deinit();
    try stmt.bindText(1, project_id);
    try stmt.bindText(2, issue_id);
    try stmt.bindText(3, event_hash);
    try stmt.bindText(4, envelope.occurred_at);
    try stmt.bindText(5, envelope.actor_principal);
    try stmt.stepDone();
}

fn deleteProjectMembership(allocator: Allocator, db: *SqliteDb, project_id: []const u8, issue_id: []const u8, remove_hash: []const u8) !void {
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
    if (event_mod.jsonString(payload.get("project_id"))) |project_id| {
        if (try projectExists(db, project_id)) return try allocator.dupe(u8, project_id);
        return null;
    }
    if (event_mod.jsonString(payload.get("project_ref"))) |project_ref| {
        return try resolveProjectIdInDb(allocator, db, project_ref);
    }
    return null;
}

fn projectIdFromPayloadOrName(allocator: Allocator, db: *SqliteDb, payload: std.json.ObjectMap, project_name: []const u8) !?[]u8 {
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
    if (event_mod.jsonString(payload.get("field_id"))) |field_id| {
        if (try projectFieldExists(db, project_id, field_id)) return try allocator.dupe(u8, field_id);
        return null;
    }
    if (event_mod.jsonString(payload.get("field_key"))) |field_key| {
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

fn setStatusFieldValueIfPresent(allocator: Allocator, db: *SqliteDb, project_id: []const u8, issue_id: []const u8, value: []const u8, event_hash: []const u8, envelope: ValidatedEnvelope) !void {
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

fn clearStatusFieldValueIfPresent(allocator: Allocator, db: *SqliteDb, project_id: []const u8, issue_id: []const u8, event_hash: []const u8) !void {
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

fn jsonValueOrDefaultOwned(allocator: Allocator, value: ?std.json.Value, default_json: []const u8) ![]u8 {
    if (value) |actual| return try jsonValueOwned(allocator, actual);
    return try allocator.dupe(u8, default_json);
}

fn jsonValueOwned(allocator: Allocator, value: std.json.Value) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try appendJsonValue(&buf, allocator, value);
    return try buf.toOwnedSlice(allocator);
}

fn appendJsonValue(buf: *std.ArrayList(u8), allocator: Allocator, value: std.json.Value) !void {
    switch (value) {
        .null => try buf.appendSlice(allocator, "null"),
        .bool => |boolean| try buf.appendSlice(allocator, if (boolean) "true" else "false"),
        .integer => |integer| try std.fmt.format(buf.writer(allocator), "{d}", .{integer}),
        .float => |number| try std.fmt.format(buf.writer(allocator), "{d}", .{number}),
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

fn jsonStringValueOwned(allocator: Allocator, value: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try json_writer.appendJsonString(&buf, allocator, value);
    return try buf.toOwnedSlice(allocator);
}

fn jsonInteger(value: ?std.json.Value) ?i64 {
    const actual = value orelse return null;
    return switch (actual) {
        .integer => |integer| integer,
        else => null,
    };
}

fn jsonBool(value: ?std.json.Value) ?bool {
    const actual = value orelse return null;
    return switch (actual) {
        .bool => |boolean| boolean,
        else => null,
    };
}

fn isUuidPrefix(value: []const u8) bool {
    if (value.len < 1 or value.len > 36) return false;
    for (value) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F') or c == '-';
        if (!ok) return false;
    }
    return true;
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
        const source_identity = sourceIdentityFromPayload(payload);
        try upsertSourceIdentity(db, source_identity);
        try insertPullOpened(db, event_hash, envelope, title, body_value, base_ref, head_ref, draft);
        try upsertPullMetadata(
            db,
            envelope.object_id,
            source_identity,
            metadataCount(payload, "commits"),
            metadataCount(payload, "changed_files"),
            metadataCount(payload, "additions"),
            metadataCount(payload, "deletions"),
        );
        try insertLegacyAliasFromEnvelope(db, "pull", envelope.object_id, legacy);
        try insertPullPayloadStringArray(db, payload, "labels", insert_pull_label_sql, envelope.object_id, event_hash);
        try insertPullPayloadStringArray(db, payload, "assignees", insert_pull_assignee_sql, envelope.object_id, event_hash);
        try insertPullPayloadStringArray(db, payload, "reviewers", insert_pull_reviewer_sql, envelope.object_id, event_hash);
        return try pullCollectionLimitRejection(db, envelope.object_id);
    }

    if (!(try acceptedCreationInFrontier(allocator, db, "pull.opened", envelope.object_id, event_hash))) return "object_not_created";
    try insertLegacyAliasFromEnvelope(db, "pull", envelope.object_id, legacy);

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
            if (!(try acceptedCreationInFrontier(allocator, db, "issue.opened", parent_id, event_hash))) return "parent_not_created";
        } else if (std.mem.eql(u8, parent_kind, "pull")) {
            if (!(try acceptedCreationInFrontier(allocator, db, "pull.opened", parent_id, event_hash))) return "parent_not_created";
        }
        const comment_body = event_mod.jsonString(payload.get("body")) orelse return "invalid_event_envelope";
        const source_author = event_mod.jsonString(payload.get("source_author")) orelse "";
        const reply_parent_hash = event_mod.jsonString(payload.get("reply_parent_hash")) orelse "";
        const reply_parent_id = try commentReplyParentId(allocator, db, event_mod.jsonString(payload.get("reply_parent_id")) orelse "", reply_parent_hash);
        defer allocator.free(reply_parent_id);
        if (reply_parent_hash.len != 0 and reply_parent_id.len == 0) return "parent_not_created";
        if (reply_parent_id.len != 0 and !(try acceptedCreationInFrontier(allocator, db, "comment.added", reply_parent_id, event_hash))) return "parent_not_created";
        if (reply_parent_id.len != 0 and !(try commentInParent(db, reply_parent_id, parent_kind, parent_id))) return "parent_not_created";
        if (reply_parent_id.len != 0 and reply_parent_hash.len != 0 and !(try acceptedCreationHashInFrontier(allocator, db, "comment.added", reply_parent_id, reply_parent_hash, event_hash))) return "parent_not_created";
        const source_identity = sourceIdentityFromPayload(payload);
        try upsertSourceIdentity(db, source_identity);
        try insertCommentAdded(db, event_hash, envelope, parent_kind, parent_id, comment_body, source_author, source_identity, reply_parent_id, reply_parent_hash);
    } else if (std.mem.eql(u8, envelope.event_type, "comment.body_set")) {
        if (!(try acceptedCreationInFrontier(allocator, db, "comment.added", envelope.object_id, event_hash))) return "object_not_created";
        const comment_body = event_mod.jsonString(payload.get("body")) orelse return "invalid_event_envelope";
        if (try updateCommentBody(allocator, db, envelope.object_id, comment_body, event_hash, envelope)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "comment.redacted")) {
        if (!(try acceptedCreationInFrontier(allocator, db, "comment.added", envelope.object_id, event_hash))) return "object_not_created";
        try redactComment(allocator, db, envelope.object_id, event_hash, envelope);
    } else if (std.mem.eql(u8, envelope.event_type, "comment.reaction_added")) {
        if (!(try acceptedCreationInFrontier(allocator, db, "comment.added", envelope.object_id, event_hash))) return "object_not_created";
        const emoji = event_mod.jsonString(payload.get("emoji")) orelse return "invalid_event_envelope";
        try insertReaction(db, "comment", envelope.object_id, emoji, envelope.actor_principal, event_hash, envelope.occurred_at);
        if (try reactionLimitRejection(db, "comment", envelope.object_id)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "comment.reaction_removed")) {
        if (!(try acceptedCreationInFrontier(allocator, db, "comment.added", envelope.object_id, event_hash))) return "object_not_created";
        const emoji = event_mod.jsonString(payload.get("emoji")) orelse return "invalid_event_envelope";
        try deleteReaction(allocator, db, "comment", envelope.object_id, emoji, envelope.actor_principal, event_hash, payload);
    }
    return null;
}

pub fn applyNotificationProjection(allocator: Allocator, db: *SqliteDb, event_hash: []const u8, envelope: ValidatedEnvelope, body: []const u8) !?[]const u8 {
    if (!std.mem.startsWith(u8, envelope.event_type, "notification.")) return null;

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
    const principal = event_mod.jsonString(payload.get("principal")) orelse return "invalid_event_envelope";

    if (std.mem.eql(u8, envelope.event_type, "notification.subscribed") or
        std.mem.eql(u8, envelope.event_type, "notification.unsubscribed"))
    {
        const target_kind = event_mod.jsonString(payload.get("target_kind")) orelse return "invalid_event_envelope";
        const target_id = event_mod.jsonString(payload.get("target_id")) orelse return "invalid_event_envelope";
        if (!(try notificationTargetExists(allocator, db, target_kind, target_id, event_hash))) return "object_not_created";
        try upsertNotificationSubscription(
            allocator,
            db,
            principal,
            target_kind,
            target_id,
            std.mem.eql(u8, envelope.event_type, "notification.subscribed"),
            event_mod.jsonString(payload.get("reason")) orelse "manual",
            event_hash,
            envelope,
        );
        return null;
    }

    if (std.mem.eql(u8, envelope.event_type, "notification.read")) {
        const read_event_hash = event_mod.jsonString(payload.get("event_hash")) orelse return "invalid_event_envelope";
        try markNotificationRead(db, principal, read_event_hash, event_hash, envelope.occurred_at);
        return null;
    }

    if (std.mem.eql(u8, envelope.event_type, "notification.read_all")) {
        try markAllNotificationsRead(db, principal, event_hash, envelope.occurred_at);
        return null;
    }

    return "unknown_event_type";
}

pub fn applyNotificationSideEffects(allocator: Allocator, db: *SqliteDb, event_hash: []const u8, envelope: ValidatedEnvelope, body: []const u8) !void {
    if (std.mem.startsWith(u8, envelope.event_type, "notification.") or
        std.mem.startsWith(u8, envelope.event_type, "acl.") or
        std.mem.startsWith(u8, envelope.event_type, "identity."))
    {
        return;
    }

    if (std.mem.startsWith(u8, envelope.event_type, "comment.")) {
        try applyCommentNotificationSideEffects(allocator, db, event_hash, envelope, body);
        return;
    }

    if (!std.mem.eql(u8, envelope.object_kind, "issue") and !std.mem.eql(u8, envelope.object_kind, "pull")) return;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return,
    };
    const payload = switch (root.get("payload") orelse return) {
        .object => |object| object,
        else => return,
    };

    if (std.mem.eql(u8, envelope.event_type, "issue.opened")) {
        try upsertNotificationSubscription(allocator, db, envelope.actor_principal, "issue", envelope.object_id, true, "author", event_hash, envelope);
        try subscribePayloadStringArray(allocator, db, payload, "assignees", "issue", envelope.object_id, "assignee", event_hash, envelope);
    } else if (std.mem.eql(u8, envelope.event_type, "issue.updated")) {
        try subscribePayloadStringArray(allocator, db, payload, "assignees_added", "issue", envelope.object_id, "assignee", event_hash, envelope);
    } else if (std.mem.eql(u8, envelope.event_type, "issue.assignee_added")) {
        if (event_mod.jsonString(payload.get("assignee"))) |assignee| {
            try upsertNotificationSubscription(allocator, db, assignee, "issue", envelope.object_id, true, "assignee", event_hash, envelope);
        }
    } else if (std.mem.eql(u8, envelope.event_type, "pull.opened")) {
        try upsertNotificationSubscription(allocator, db, envelope.actor_principal, "pull", envelope.object_id, true, "author", event_hash, envelope);
        try subscribePayloadStringArray(allocator, db, payload, "assignees", "pull", envelope.object_id, "assignee", event_hash, envelope);
        try subscribePayloadStringArray(allocator, db, payload, "reviewers", "pull", envelope.object_id, "reviewer", event_hash, envelope);
    } else if (std.mem.eql(u8, envelope.event_type, "pull.updated")) {
        try subscribePayloadStringArray(allocator, db, payload, "assignees_added", "pull", envelope.object_id, "assignee", event_hash, envelope);
        try subscribePayloadStringArray(allocator, db, payload, "reviewers_added", "pull", envelope.object_id, "reviewer", event_hash, envelope);
    } else if (std.mem.eql(u8, envelope.event_type, "pull.assignee_added")) {
        if (event_mod.jsonString(payload.get("assignee"))) |assignee| {
            try upsertNotificationSubscription(allocator, db, assignee, "pull", envelope.object_id, true, "assignee", event_hash, envelope);
        }
    } else if (std.mem.eql(u8, envelope.event_type, "pull.reviewer_added")) {
        if (event_mod.jsonString(payload.get("reviewer"))) |reviewer| {
            try upsertNotificationSubscription(allocator, db, reviewer, "pull", envelope.object_id, true, "reviewer", event_hash, envelope);
        }
    }

    try publishNotificationEvent(db, event_hash, envelope.object_kind, envelope.object_id, envelope.event_type, envelope.actor_principal, envelope.occurred_at);
}

fn applyCommentNotificationSideEffects(allocator: Allocator, db: *SqliteDb, event_hash: []const u8, envelope: ValidatedEnvelope, body: []const u8) !void {
    if (std.mem.eql(u8, envelope.event_type, "comment.added")) {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |object| object,
            else => return,
        };
        const payload = switch (root.get("payload") orelse return) {
            .object => |object| object,
            else => return,
        };
        const parent_kind = event_mod.jsonString(payload.get("parent_kind")) orelse return;
        const parent_id = event_mod.jsonString(payload.get("parent_id")) orelse return;
        if (!std.mem.eql(u8, parent_kind, "issue") and !std.mem.eql(u8, parent_kind, "pull")) return;

        try upsertNotificationSubscription(allocator, db, envelope.actor_principal, parent_kind, parent_id, true, "commenter", event_hash, envelope);
        if (event_mod.jsonString(payload.get("body"))) |comment_body| {
            try subscribeMentionedPrincipals(allocator, db, comment_body, parent_kind, parent_id, event_hash, envelope);
        }
        try publishNotificationEvent(db, event_hash, parent_kind, parent_id, envelope.event_type, envelope.actor_principal, envelope.occurred_at);
        return;
    }

    if (try commentParentForNotification(allocator, db, envelope.object_id)) |parent| {
        var owned_parent = parent;
        defer owned_parent.deinit(allocator);
        try publishNotificationEvent(db, event_hash, owned_parent.kind, owned_parent.id, envelope.event_type, envelope.actor_principal, envelope.occurred_at);
    }
}

fn notificationTargetExists(allocator: Allocator, db: *SqliteDb, target_kind: []const u8, target_id: []const u8, before_event_hash: []const u8) !bool {
    if (std.mem.eql(u8, target_kind, "issue")) {
        return try acceptedCreationInFrontier(allocator, db, "issue.opened", target_id, before_event_hash);
    }
    if (std.mem.eql(u8, target_kind, "pull")) {
        return try acceptedCreationInFrontier(allocator, db, "pull.opened", target_id, before_event_hash);
    }
    return false;
}

fn upsertNotificationSubscription(
    allocator: Allocator,
    db: *SqliteDb,
    principal: []const u8,
    object_kind: []const u8,
    object_id: []const u8,
    active: bool,
    reason: []const u8,
    event_hash: []const u8,
    envelope: ValidatedEnvelope,
) !void {
    if (std.mem.trim(u8, principal, " \t\r\n").len == 0) return;
    if (!std.mem.eql(u8, object_kind, "issue") and !std.mem.eql(u8, object_kind, "pull")) return;

    var select = try db.prepare(
        \\SELECT update_event_hash
        \\FROM notification_subscriptions
        \\WHERE principal = ? AND object_kind = ? AND object_id = ?
    );
    defer select.deinit();
    try select.bindText(1, principal);
    try select.bindText(2, object_kind);
    try select.bindText(3, object_id);
    if (try select.step()) {
        const old_event_hash = try select.columnTextDup(allocator, 0);
        defer allocator.free(old_event_hash);
        if (!(try eventWins(allocator, event_hash, old_event_hash))) return;
    }

    var stmt = try db.prepare(
        \\INSERT INTO notification_subscriptions(principal, object_kind, object_id, active, reason, updated_at, update_event_hash)
        \\VALUES (?, ?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(principal, object_kind, object_id) DO UPDATE SET
        \\  active = excluded.active,
        \\  reason = excluded.reason,
        \\  updated_at = excluded.updated_at,
        \\  update_event_hash = excluded.update_event_hash
    );
    defer stmt.deinit();
    try stmt.bindText(1, principal);
    try stmt.bindText(2, object_kind);
    try stmt.bindText(3, object_id);
    try stmt.bindInt(4, if (active) 1 else 0);
    try stmt.bindText(5, if (reason.len == 0) "manual" else reason);
    try stmt.bindText(6, envelope.occurred_at);
    try stmt.bindText(7, event_hash);
    try stmt.stepDone();
}

fn subscribePayloadStringArray(
    allocator: Allocator,
    db: *SqliteDb,
    payload: std.json.ObjectMap,
    key: []const u8,
    object_kind: []const u8,
    object_id: []const u8,
    reason: []const u8,
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
        try upsertNotificationSubscription(allocator, db, item.string, object_kind, object_id, true, reason, event_hash, envelope);
    }
}

fn subscribeMentionedPrincipals(
    allocator: Allocator,
    db: *SqliteDb,
    body: []const u8,
    object_kind: []const u8,
    object_id: []const u8,
    event_hash: []const u8,
    envelope: ValidatedEnvelope,
) !void {
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    var index: usize = 0;
    while (index < body.len) : (index += 1) {
        if (body[index] != '@') continue;
        if (index > 0 and isMentionPrincipalChar(body[index - 1])) continue;
        const start = index + 1;
        if (start >= body.len or !isMentionPrincipalChar(body[start])) continue;
        var end = start;
        var has_alnum = false;
        while (end < body.len and isMentionPrincipalChar(body[end])) : (end += 1) {
            if (std.ascii.isAlphanumeric(body[end])) has_alnum = true;
        }
        if (!has_alnum) continue;
        const principal = std.mem.trimRight(u8, body[start..end], ".");
        if (principal.len == 0) continue;
        if (!seen.contains(principal)) {
            try seen.put(principal, {});
            try upsertNotificationSubscription(allocator, db, principal, object_kind, object_id, true, "mentioned", event_hash, envelope);
        }
        index = end;
    }
}

fn isMentionPrincipalChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.';
}

fn publishNotificationEvent(
    db: *SqliteDb,
    event_hash: []const u8,
    object_kind: []const u8,
    object_id: []const u8,
    event_type: []const u8,
    actor_principal: []const u8,
    occurred_at: []const u8,
) !void {
    if (!std.mem.eql(u8, object_kind, "issue") and !std.mem.eql(u8, object_kind, "pull")) return;
    var stmt = try db.prepare(
        \\INSERT OR IGNORE INTO notification_inbox(
        \\  principal, event_hash, object_kind, object_id, event_type, actor_principal,
        \\  occurred_at, reason, read_at, read_event_hash
        \\)
        \\SELECT principal, ?, ?, ?, ?, ?, ?, reason, '', ''
        \\FROM notification_subscriptions
        \\WHERE object_kind = ?
        \\  AND object_id = ?
        \\  AND active != 0
        \\  AND principal != ?
    );
    defer stmt.deinit();
    try stmt.bindText(1, event_hash);
    try stmt.bindText(2, object_kind);
    try stmt.bindText(3, object_id);
    try stmt.bindText(4, event_type);
    try stmt.bindText(5, actor_principal);
    try stmt.bindText(6, occurred_at);
    try stmt.bindText(7, object_kind);
    try stmt.bindText(8, object_id);
    try stmt.bindText(9, actor_principal);
    try stmt.stepDone();
}

fn markNotificationRead(db: *SqliteDb, principal: []const u8, read_event_hash: []const u8, event_hash: []const u8, read_at: []const u8) !void {
    var stmt = try db.prepare(
        \\UPDATE notification_inbox
        \\SET read_at = ?, read_event_hash = ?
        \\WHERE principal = ?
        \\  AND event_hash = ?
        \\  AND read_at = ''
    );
    defer stmt.deinit();
    try stmt.bindText(1, read_at);
    try stmt.bindText(2, event_hash);
    try stmt.bindText(3, principal);
    try stmt.bindText(4, read_event_hash);
    try stmt.stepDone();
}

fn markAllNotificationsRead(db: *SqliteDb, principal: []const u8, event_hash: []const u8, read_at: []const u8) !void {
    var stmt = try db.prepare(
        \\UPDATE notification_inbox
        \\SET read_at = ?, read_event_hash = ?
        \\WHERE principal = ?
        \\  AND read_at = ''
    );
    defer stmt.deinit();
    try stmt.bindText(1, read_at);
    try stmt.bindText(2, event_hash);
    try stmt.bindText(3, principal);
    try stmt.stepDone();
}

const NotificationParent = struct {
    kind: []u8,
    id: []u8,

    fn deinit(self: *NotificationParent, allocator: Allocator) void {
        allocator.free(self.kind);
        allocator.free(self.id);
    }
};

fn commentParentForNotification(allocator: Allocator, db: *SqliteDb, comment_id: []const u8) !?NotificationParent {
    var stmt = try db.prepare("SELECT parent_kind, parent_id FROM comments WHERE id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, comment_id);
    if (!(try stmt.step())) return null;
    return .{
        .kind = try stmt.columnTextDup(allocator, 0),
        .id = try stmt.columnTextDup(allocator, 1),
    };
}

fn insertCommentAdded(
    db: *SqliteDb,
    event_hash: []const u8,
    envelope: ValidatedEnvelope,
    parent_kind: []const u8,
    parent_id: []const u8,
    body: []const u8,
    source_author: []const u8,
    source_identity: ProjectedSourceIdentity,
    reply_parent_id: []const u8,
    reply_parent_hash: []const u8,
) !void {
    var stmt = try db.prepare(
        \\INSERT OR IGNORE INTO comments(
        \\  id, parent_kind, parent_id,
        \\  body, body_occurred_at, body_actor_principal, body_event_hash,
        \\  redacted, redacted_at, redacted_actor_principal, redacted_event_hash,
        \\  created_at, author_principal, author_device,
        \\  source_author, source_identity, source_email, source_avatar_url,
        \\  reply_parent_id, reply_parent_hash
        \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
    try stmt.bindText(16, source_identity.identity);
    try stmt.bindText(17, source_identity.email);
    try stmt.bindText(18, source_identity.avatar_url);
    try stmt.bindText(19, reply_parent_id);
    try stmt.bindText(20, reply_parent_hash);
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

fn commentInParent(db: *SqliteDb, comment_id: []const u8, parent_kind: []const u8, parent_id: []const u8) !bool {
    var stmt = try db.prepare("SELECT 1 FROM comments WHERE id = ? AND parent_kind = ? AND parent_id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, comment_id);
    try stmt.bindText(2, parent_kind);
    try stmt.bindText(3, parent_id);
    return try stmt.step();
}

fn updateCommentBody(allocator: Allocator, db: *SqliteDb, comment_id: []const u8, body: []const u8, event_hash: []const u8, envelope: ValidatedEnvelope) !?[]const u8 {
    var select = try db.prepare("SELECT redacted, body_occurred_at, body_actor_principal, body_event_hash FROM comments WHERE id = ?");
    defer select.deinit();
    try select.bindText(1, comment_id);
    if (!(try select.step())) return null;
    if (select.columnInt(0) != 0) return "object_redacted";
    const old_occurred_at = try select.columnTextDup(allocator, 1);
    defer allocator.free(old_occurred_at);
    const old_actor = try select.columnTextDup(allocator, 2);
    defer allocator.free(old_actor);
    const old_event_hash = try select.columnTextDup(allocator, 3);
    defer allocator.free(old_event_hash);

    if (!(try eventWins(allocator, event_hash, old_event_hash))) {
        return null;
    }

    var update = try db.prepare("UPDATE comments SET body = ?, body_occurred_at = ?, body_actor_principal = ?, body_event_hash = ? WHERE id = ?");
    defer update.deinit();
    try update.bindText(1, body);
    try update.bindText(2, envelope.occurred_at);
    try update.bindText(3, envelope.actor_principal);
    try update.bindText(4, event_hash);
    try update.bindText(5, comment_id);
    try update.stepDone();
    return null;
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
        \\SET body = '', redacted = 1, redacted_at = ?, redacted_actor_principal = ?, redacted_event_hash = ?
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

test "creation duplicate winner ignores rejected creation events" {
    const allocator = std.testing.allocator;
    var db = try SqliteDb.open(allocator, ":memory:", sqlite_db.sqlite.SQLITE_OPEN_READWRITE | sqlite_db.sqlite.SQLITE_OPEN_CREATE, true);
    defer db.deinit();
    try index_schema.createIndexSchema(&db);

    try insertTestEvent(&db, "z-rejected", "issue.opened", "issue", "issue-1", "rejected");
    try insertTestEvent(&db, "a-current", "issue.opened", "issue", "issue-1", "pending");

    try std.testing.expect(try creationEventWins(&db, "issue.opened", "issue-1", "a-current"));

    try insertTestEvent(&db, "accepted-winner", "issue.opened", "issue", "issue-2", "accepted");
    try insertTestEvent(&db, "pending-loser", "issue.opened", "issue", "issue-2", "pending");
    try std.testing.expect(!(try creationEventWins(&db, "issue.opened", "issue-2", "pending-loser")));
}

test "issue updates require an accepted creation event in frontier" {
    const allocator = std.testing.allocator;
    var db = try SqliteDb.open(allocator, ":memory:", sqlite_db.sqlite.SQLITE_OPEN_READWRITE | sqlite_db.sqlite.SQLITE_OPEN_CREATE, true);
    defer db.deinit();
    try index_schema.createIndexSchema(&db);
    try insertProjectedIssue(&db, "issue-1", "alice");

    var envelope = try testEnvelope(allocator, "issue.title_set", "issue", "issue-1", "alice", "laptop");
    defer envelope.deinit();
    const body =
        \\{
        \\  "payload": {
        \\    "title": "New title"
        \\  },
        \\  "legacy": {}
        \\}
    ;

    const rejected = try applyIssueProjection(allocator, &db, "edit-event", envelope, body);
    try std.testing.expect(rejected != null);
    try std.testing.expectEqualStrings("object_not_created", rejected.?);
    try expectIssueTitle(allocator, &db, "issue-1", "Old title");

    try insertTestEvent(&db, "", "issue.opened", "issue", "issue-1", "accepted");
    const accepted = try applyIssueProjection(allocator, &db, "edit-event", envelope, body);
    try std.testing.expect(accepted == null);
    try expectIssueTitle(allocator, &db, "issue-1", "New title");
}

test "notification side effects subscribe and publish issue conversation events" {
    const allocator = std.testing.allocator;
    var db = try SqliteDb.open(allocator, ":memory:", sqlite_db.sqlite.SQLITE_OPEN_READWRITE | sqlite_db.sqlite.SQLITE_OPEN_CREATE, true);
    defer db.deinit();
    try index_schema.createIndexSchema(&db);

    var issue_envelope = try testEnvelope(allocator, "issue.opened", "issue", "issue-1", "alice", "laptop");
    defer issue_envelope.deinit();
    const issue_body =
        \\{
        \\  "payload": {
        \\    "title": "Inbox",
        \\    "assignees": ["bob"]
        \\  },
        \\  "legacy": {}
        \\}
    ;
    try applyNotificationSideEffects(allocator, &db, "event-open", issue_envelope, issue_body);
    try expectNotificationSubscription(&db, "alice", "issue", "issue-1", true, "author");
    try expectNotificationSubscription(&db, "bob", "issue", "issue-1", true, "assignee");
    try expectNotificationInboxRead(&db, "bob", "event-open", false);
    try expectNoNotificationInbox(&db, "alice", "event-open");

    var comment_envelope = try testEnvelope(allocator, "comment.added", "comment", "comment-1", "carol", "phone");
    defer comment_envelope.deinit();
    const comment_body =
        \\{
        \\  "payload": {
        \\    "parent_kind": "issue",
        \\    "parent_id": "issue-1",
        \\    "body": "Looping in @dave."
        \\  },
        \\  "legacy": {}
        \\}
    ;
    try applyNotificationSideEffects(allocator, &db, "event-comment", comment_envelope, comment_body);
    try expectNotificationSubscription(&db, "carol", "issue", "issue-1", true, "commenter");
    try expectNotificationSubscription(&db, "dave", "issue", "issue-1", true, "mentioned");
    try expectNotificationInboxRead(&db, "alice", "event-comment", false);
    try expectNotificationInboxRead(&db, "bob", "event-comment", false);
    try expectNotificationInboxRead(&db, "dave", "event-comment", false);
    try expectNoNotificationInbox(&db, "carol", "event-comment");

    var read_envelope = try testEnvelope(allocator, "notification.read", "notification", "notification-1", "dave", "laptop");
    defer read_envelope.deinit();
    const read_body =
        \\{
        \\  "payload": {
        \\    "principal": "dave",
        \\    "event_hash": "event-comment"
        \\  },
        \\  "legacy": {}
        \\}
    ;
    try std.testing.expect(try applyNotificationProjection(allocator, &db, "read-event", read_envelope, read_body) == null);
    try expectNotificationInboxRead(&db, "dave", "event-comment", true);
}

fn testEnvelope(
    allocator: Allocator,
    event_type: []const u8,
    object_kind: []const u8,
    object_id: []const u8,
    actor_principal: []const u8,
    actor_device: []const u8,
) !ValidatedEnvelope {
    return .{
        .allocator = allocator,
        .repo_id = try allocator.dupe(u8, "repo"),
        .event_uuid = try allocator.dupe(u8, "018f0000-0000-7000-8000-000000000000"),
        .event_type = try allocator.dupe(u8, event_type),
        .object_kind = try allocator.dupe(u8, object_kind),
        .object_id = try allocator.dupe(u8, object_id),
        .idempotency_key = try allocator.dupe(u8, "idem"),
        .actor_principal = try allocator.dupe(u8, actor_principal),
        .actor_device = try allocator.dupe(u8, actor_device),
        .seq = 1,
        .occurred_at = try allocator.dupe(u8, "2026-05-16T00:00:00Z"),
    };
}

fn insertTestEvent(
    db: *SqliteDb,
    event_hash: []const u8,
    event_type: []const u8,
    object_kind: []const u8,
    object_id: []const u8,
    domain_status: []const u8,
) !void {
    var stmt = try db.prepare(
        \\INSERT INTO events(
        \\  ref, "commit", event_hash, tree, subject, body, empty_tree, valid_json,
        \\  event_type, object_kind, object_id, actor_principal, actor_device, seq, occurred_at,
        \\  domain_status, rejection_reason
        \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    );
    defer stmt.deinit();
    try stmt.bindText(1, "refs/gitomi/inbox/alice/laptop");
    try stmt.bindText(2, event_hash);
    try stmt.bindText(3, event_hash);
    try stmt.bindText(4, "");
    try stmt.bindText(5, event_type);
    try stmt.bindText(6, "{}");
    try stmt.bindInt(7, 0);
    try stmt.bindInt(8, 1);
    try stmt.bindText(9, event_type);
    try stmt.bindText(10, object_kind);
    try stmt.bindText(11, object_id);
    try stmt.bindText(12, "alice");
    try stmt.bindText(13, "laptop");
    try stmt.bindInt64(14, 1);
    try stmt.bindText(15, "2026-05-16T00:00:00Z");
    try stmt.bindText(16, domain_status);
    try stmt.bindText(17, "");
    try stmt.stepDone();
}

fn insertProjectedIssue(db: *SqliteDb, issue_id: []const u8, author: []const u8) !void {
    var stmt = try db.prepare(
        \\INSERT INTO issues(
        \\  id,
        \\  title, title_occurred_at, title_actor_principal, title_event_hash,
        \\  body, body_occurred_at, body_actor_principal, body_event_hash,
        \\  state, state_occurred_at, state_actor_principal, state_event_hash,
        \\  opened_at, author_principal, author_device
        \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    );
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    try stmt.bindText(2, "Old title");
    try stmt.bindText(3, "2026-05-16T00:00:00Z");
    try stmt.bindText(4, author);
    try stmt.bindText(5, "");
    try stmt.bindText(6, "");
    try stmt.bindText(7, "2026-05-16T00:00:00Z");
    try stmt.bindText(8, author);
    try stmt.bindText(9, "");
    try stmt.bindText(10, "open");
    try stmt.bindText(11, "2026-05-16T00:00:00Z");
    try stmt.bindText(12, author);
    try stmt.bindText(13, "");
    try stmt.bindText(14, "2026-05-16T00:00:00Z");
    try stmt.bindText(15, author);
    try stmt.bindText(16, "laptop");
    try stmt.stepDone();
}

fn expectIssueTitle(allocator: Allocator, db: *SqliteDb, issue_id: []const u8, expected: []const u8) !void {
    var stmt = try db.prepare("SELECT title FROM issues WHERE id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    try std.testing.expect(try stmt.step());
    const title = try stmt.columnTextDup(allocator, 0);
    defer allocator.free(title);
    try std.testing.expectEqualStrings(expected, title);
}

fn expectNotificationSubscription(db: *SqliteDb, principal: []const u8, object_kind: []const u8, object_id: []const u8, active: bool, reason: []const u8) !void {
    var stmt = try db.prepare(
        \\SELECT active, reason
        \\FROM notification_subscriptions
        \\WHERE principal = ? AND object_kind = ? AND object_id = ?
    );
    defer stmt.deinit();
    try stmt.bindText(1, principal);
    try stmt.bindText(2, object_kind);
    try stmt.bindText(3, object_id);
    try std.testing.expect(try stmt.step());
    try std.testing.expectEqual(@as(i64, if (active) 1 else 0), stmt.columnInt64(0));
    const actual_reason = try stmt.columnTextDup(std.testing.allocator, 1);
    defer std.testing.allocator.free(actual_reason);
    try std.testing.expectEqualStrings(reason, actual_reason);
}

fn expectNotificationInboxRead(db: *SqliteDb, principal: []const u8, event_hash: []const u8, read: bool) !void {
    var stmt = try db.prepare(
        \\SELECT read_at
        \\FROM notification_inbox
        \\WHERE principal = ? AND event_hash = ?
    );
    defer stmt.deinit();
    try stmt.bindText(1, principal);
    try stmt.bindText(2, event_hash);
    try std.testing.expect(try stmt.step());
    const read_at = try stmt.columnTextDup(std.testing.allocator, 0);
    defer std.testing.allocator.free(read_at);
    if (read) {
        try std.testing.expect(read_at.len != 0);
    } else {
        try std.testing.expectEqualStrings("", read_at);
    }
}

fn expectNoNotificationInbox(db: *SqliteDb, principal: []const u8, event_hash: []const u8) !void {
    var stmt = try db.prepare(
        \\SELECT 1
        \\FROM notification_inbox
        \\WHERE principal = ? AND event_hash = ?
    );
    defer stmt.deinit();
    try stmt.bindText(1, principal);
    try stmt.bindText(2, event_hash);
    try std.testing.expect(!(try stmt.step()));
}
