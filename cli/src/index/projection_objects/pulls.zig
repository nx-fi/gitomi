const std = @import("std");

const common = @import("common.zig");
const reactions = @import("reactions.zig");

const event_json = common.event_json;
const git = common.git;
const Allocator = common.Allocator;
const SqliteDb = common.SqliteDb;
const ValidatedEnvelope = common.ValidatedEnvelope;
const sourceIdentityFromPayload = common.sourceIdentityFromPayload;
const upsertSourceIdentity = common.upsertSourceIdentity;
const upsertPullMetadata = common.upsertPullMetadata;
const metadataCount = common.metadataCount;
const creationEventWins = common.creationEventWins;
const acceptedCreationInFrontier = common.acceptedCreationInFrontier;
const insertLegacyAliasFromEnvelope = common.insertLegacyAliasFromEnvelope;
const eventWins = common.eventWins;
const collectionCountExceeds = common.collectionCountExceeds;
const max_projected_labels = common.max_projected_labels;
const max_projected_participants = common.max_projected_participants;
const insertReaction = reactions.insertReaction;
const deleteReaction = reactions.deleteReaction;
const reactionLimitRejection = reactions.reactionLimitRejection;

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
        const title = event_json.jsonString(payload.get("title")) orelse return "invalid_event_envelope";
        const base_ref = event_json.jsonString(payload.get("base_ref")) orelse return "invalid_event_envelope";
        const head_ref = event_json.jsonString(payload.get("head_ref")) orelse return "invalid_event_envelope";
        const body_value = event_json.jsonString(payload.get("body")) orelse "";
        const draft = event_json.jsonBool(payload.get("draft")) orelse false;
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
        const title = event_json.jsonString(payload.get("title")) orelse return "invalid_event_envelope";
        _ = try updatePullScalar(allocator, db, envelope.object_id, title, event_hash, envelope, "title", "title_occurred_at", "title_actor_principal", "title_event_hash");
    } else if (std.mem.eql(u8, envelope.event_type, "pull.body_set")) {
        const body_value = event_json.jsonString(payload.get("body")) orelse return "invalid_event_envelope";
        _ = try updatePullScalar(allocator, db, envelope.object_id, body_value, event_hash, envelope, "body", "body_occurred_at", "body_actor_principal", "body_event_hash");
    } else if (std.mem.eql(u8, envelope.event_type, "pull.state_set")) {
        const state = event_json.jsonString(payload.get("state")) orelse return "invalid_event_envelope";
        if (!stateAllowsPullStateSet(state)) return "invalid_event_envelope";
        _ = try updatePullScalar(allocator, db, envelope.object_id, state, event_hash, envelope, "state", "state_occurred_at", "state_actor_principal", "state_event_hash");
    } else if (std.mem.eql(u8, envelope.event_type, "pull.base_set")) {
        const base_ref = event_json.jsonString(payload.get("base_ref")) orelse return "invalid_event_envelope";
        _ = try updatePullScalar(allocator, db, envelope.object_id, base_ref, event_hash, envelope, "base_ref", "base_occurred_at", "base_actor_principal", "base_event_hash");
    } else if (std.mem.eql(u8, envelope.event_type, "pull.head_set")) {
        const head_ref = event_json.jsonString(payload.get("head_ref")) orelse return "invalid_event_envelope";
        _ = try updatePullScalar(allocator, db, envelope.object_id, head_ref, event_hash, envelope, "head_ref", "head_occurred_at", "head_actor_principal", "head_event_hash");
    } else if (std.mem.eql(u8, envelope.event_type, "pull.label_added")) {
        const label = event_json.jsonString(payload.get("label")) orelse return "invalid_event_envelope";
        try insertPullCollectionValue(db, insert_pull_label_sql, envelope.object_id, label, event_hash);
        if (try pullCollectionLimitRejection(db, envelope.object_id)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "pull.label_removed")) {
        const label = event_json.jsonString(payload.get("label")) orelse return "invalid_event_envelope";
        try deletePullCollectionValue(allocator, db, "SELECT add_hash FROM pull_labels WHERE pull_id = ? AND label = ?", "DELETE FROM pull_labels WHERE pull_id = ? AND label = ? AND add_hash = ?", envelope.object_id, label, event_hash);
    } else if (std.mem.eql(u8, envelope.event_type, "pull.assignee_added")) {
        const assignee = event_json.jsonString(payload.get("assignee")) orelse return "invalid_event_envelope";
        try insertPullCollectionValue(db, insert_pull_assignee_sql, envelope.object_id, assignee, event_hash);
        if (try pullCollectionLimitRejection(db, envelope.object_id)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "pull.assignee_removed")) {
        const assignee = event_json.jsonString(payload.get("assignee")) orelse return "invalid_event_envelope";
        try deletePullCollectionValue(allocator, db, "SELECT add_hash FROM pull_assignees WHERE pull_id = ? AND assignee = ?", "DELETE FROM pull_assignees WHERE pull_id = ? AND assignee = ? AND add_hash = ?", envelope.object_id, assignee, event_hash);
    } else if (std.mem.eql(u8, envelope.event_type, "pull.reviewer_added")) {
        const reviewer = event_json.jsonString(payload.get("reviewer")) orelse return "invalid_event_envelope";
        try insertPullCollectionValue(db, insert_pull_reviewer_sql, envelope.object_id, reviewer, event_hash);
        if (try pullCollectionLimitRejection(db, envelope.object_id)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "pull.reviewer_removed")) {
        const reviewer = event_json.jsonString(payload.get("reviewer")) orelse return "invalid_event_envelope";
        try deletePullCollectionValue(allocator, db, "SELECT add_hash FROM pull_reviewers WHERE pull_id = ? AND reviewer = ?", "DELETE FROM pull_reviewers WHERE pull_id = ? AND reviewer = ? AND add_hash = ?", envelope.object_id, reviewer, event_hash);
    } else if (std.mem.eql(u8, envelope.event_type, "pull.merged")) {
        if (try applyPullMerged(allocator, db, envelope.object_id, payload, event_hash, envelope)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "pull.reaction_added")) {
        const emoji = event_json.jsonString(payload.get("emoji")) orelse return "invalid_event_envelope";
        try insertReaction(db, "pull", envelope.object_id, emoji, envelope.actor_principal, event_hash, envelope.occurred_at);
        if (try reactionLimitRejection(db, "pull", envelope.object_id)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "pull.reaction_removed")) {
        const emoji = event_json.jsonString(payload.get("emoji")) orelse return "invalid_event_envelope";
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
    if (event_json.jsonString(payload.get("title"))) |title| {
        _ = try updatePullScalar(allocator, db, envelope.object_id, title, event_hash, envelope, "title", "title_occurred_at", "title_actor_principal", "title_event_hash");
    }
    if (event_json.jsonString(payload.get("body"))) |body_value| {
        _ = try updatePullScalar(allocator, db, envelope.object_id, body_value, event_hash, envelope, "body", "body_occurred_at", "body_actor_principal", "body_event_hash");
    }
    if (event_json.jsonString(payload.get("state"))) |state| {
        if (!stateAllowsPullStateSet(state)) return "invalid_event_envelope";
        _ = try updatePullScalar(allocator, db, envelope.object_id, state, event_hash, envelope, "state", "state_occurred_at", "state_actor_principal", "state_event_hash");
    }
    if (event_json.jsonString(payload.get("base_ref"))) |base_ref| {
        _ = try updatePullScalar(allocator, db, envelope.object_id, base_ref, event_hash, envelope, "base_ref", "base_occurred_at", "base_actor_principal", "base_event_hash");
    }
    if (event_json.jsonString(payload.get("head_ref"))) |head_ref| {
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
    payload: std.json.ObjectMap,
    event_hash: []const u8,
    envelope: ValidatedEnvelope,
) !?[]const u8 {
    const merge_oid = event_json.jsonString(payload.get("merge_oid")) orelse "";
    const target_oid = event_json.jsonString(payload.get("target_oid")) orelse "";
    if (merge_oid.len == 0 and target_oid.len == 0) return "invalid_merge_oid";

    if (try pullMergeOidRejection(allocator, merge_oid, target_oid, payload)) |reason| return reason;

    if (!(try updatePullScalar(allocator, db, pull_id, "merged", event_hash, envelope, "state", "state_occurred_at", "state_actor_principal", "state_event_hash"))) return null;
    var update = try db.prepare("UPDATE pulls SET merge_oid = ?, target_oid = ? WHERE id = ?");
    defer update.deinit();
    try update.bindText(1, merge_oid);
    try update.bindText(2, target_oid);
    try update.bindText(3, pull_id);
    try update.stepDone();
    return null;
}

pub fn pullMergeOidRejection(allocator: Allocator, merge_oid: []const u8, target_oid: []const u8, payload: std.json.ObjectMap) !?[]const u8 {
    if (merge_oid.len != 0 and !git.isFullOid(merge_oid)) return "invalid_merge_oid";
    if (target_oid.len != 0 and !git.isFullOid(target_oid)) return "invalid_target_oid";
    if (merge_oid.len != 0 and target_oid.len != 0 and !std.mem.eql(u8, merge_oid, target_oid)) return "invalid_target_oid";

    const base_oid = event_json.jsonString(payload.get("base_oid")) orelse "";
    const head_oid = event_json.jsonString(payload.get("head_oid")) orelse "";
    if (base_oid.len != 0 and !git.isFullOid(base_oid)) return "invalid_base_oid";
    if (head_oid.len != 0 and !git.isFullOid(head_oid)) return "invalid_head_oid";

    if (merge_oid.len != 0 and !(try gitCommitExistsQuiet(allocator, merge_oid))) return "invalid_merge_oid";
    if (target_oid.len != 0 and !(try gitCommitExistsQuiet(allocator, target_oid))) return "invalid_target_oid";
    if (base_oid.len != 0 and !(try gitCommitExistsQuiet(allocator, base_oid))) return "invalid_base_oid";
    if (head_oid.len != 0 and !(try gitCommitExistsQuiet(allocator, head_oid))) return "invalid_head_oid";

    const effective_target_oid = if (target_oid.len != 0) target_oid else merge_oid;
    if (base_oid.len != 0 and effective_target_oid.len != 0 and !(try gitIsAncestorQuiet(allocator, base_oid, effective_target_oid))) {
        return "target_oid_not_descendant_of_base";
    }
    if (merge_oid.len != 0 and base_oid.len != 0 and head_oid.len != 0 and !(try mergeCommitHasParentsQuiet(allocator, merge_oid, base_oid, head_oid))) {
        return "merge_oid_parent_mismatch";
    }

    return null;
}

fn gitCommitExistsQuiet(allocator: Allocator, oid: []const u8) !bool {
    const commit_ref = try std.fmt.allocPrint(allocator, "{s}^{{commit}}", .{oid});
    defer allocator.free(commit_ref);
    var result = try git.runCommand(allocator, &.{ "git", "cat-file", "-e", commit_ref }, null, 1024 * 1024);
    defer result.deinit();
    return result.exitCode() == 0;
}

fn gitIsAncestorQuiet(allocator: Allocator, ancestor: []const u8, descendant: []const u8) !bool {
    var result = try git.runCommand(allocator, &.{ "git", "merge-base", "--is-ancestor", ancestor, descendant }, null, 1024 * 1024);
    defer result.deinit();
    return result.exitCode() == 0;
}

fn mergeCommitHasParentsQuiet(allocator: Allocator, merge_oid: []const u8, base_oid: []const u8, head_oid: []const u8) !bool {
    var result = try git.runCommand(allocator, &.{ "git", "cat-file", "-p", merge_oid }, null, 1024 * 1024);
    defer result.deinit();
    if (result.exitCode() != 0) return false;

    var parent_count: usize = 0;
    var has_base = false;
    var has_head = false;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) break;
        if (!std.mem.startsWith(u8, line, "parent ")) continue;
        const parent = line["parent ".len..];
        parent_count += 1;
        if (std.mem.eql(u8, parent, base_oid)) has_base = true;
        if (std.mem.eql(u8, parent, head_oid)) has_head = true;
    }
    return parent_count >= 2 and has_base and has_head;
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

fn stateAllowsPullStateSet(state: []const u8) bool {
    return std.mem.eql(u8, state, "open") or std.mem.eql(u8, state, "closed");
}
