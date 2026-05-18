const std = @import("std");

const common = @import("common.zig");
const reactions = @import("reactions.zig");

const event_json = common.event_json;
const Allocator = common.Allocator;
const SqliteDb = common.SqliteDb;
const ValidatedEnvelope = common.ValidatedEnvelope;
const ProjectedSourceIdentity = common.ProjectedSourceIdentity;
const sourceIdentityFromPayload = common.sourceIdentityFromPayload;
const upsertSourceIdentity = common.upsertSourceIdentity;
const creationEventWins = common.creationEventWins;
const acceptedCreationInFrontier = common.acceptedCreationInFrontier;
const acceptedCreationHashInFrontier = common.acceptedCreationHashInFrontier;
const eventWins = common.eventWins;
const insertReaction = reactions.insertReaction;
const deleteReaction = reactions.deleteReaction;
const reactionLimitRejection = reactions.reactionLimitRejection;

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
        const parent_kind = event_json.jsonString(payload.get("parent_kind")) orelse return "invalid_event_envelope";
        const parent_id = event_json.jsonString(payload.get("parent_id")) orelse return "invalid_event_envelope";
        if (std.mem.eql(u8, parent_kind, "issue")) {
            if (!(try acceptedCreationInFrontier(allocator, db, "issue.opened", parent_id, event_hash))) return "parent_not_created";
        } else if (std.mem.eql(u8, parent_kind, "pull")) {
            if (!(try acceptedCreationInFrontier(allocator, db, "pull.opened", parent_id, event_hash))) return "parent_not_created";
        }
        const comment_body = event_json.jsonString(payload.get("body")) orelse return "invalid_event_envelope";
        const source_author = event_json.jsonString(payload.get("source_author")) orelse "";
        const reply_parent_hash = event_json.jsonString(payload.get("reply_parent_hash")) orelse "";
        const reply_parent_id = try commentReplyParentId(allocator, db, event_json.jsonString(payload.get("reply_parent_id")) orelse "", reply_parent_hash);
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
        const comment_body = event_json.jsonString(payload.get("body")) orelse return "invalid_event_envelope";
        if (try updateCommentBody(allocator, db, envelope.object_id, comment_body, event_hash, envelope)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "comment.redacted")) {
        if (!(try acceptedCreationInFrontier(allocator, db, "comment.added", envelope.object_id, event_hash))) return "object_not_created";
        try redactComment(allocator, db, envelope.object_id, event_hash, envelope);
    } else if (std.mem.eql(u8, envelope.event_type, "comment.reaction_added")) {
        if (!(try acceptedCreationInFrontier(allocator, db, "comment.added", envelope.object_id, event_hash))) return "object_not_created";
        const emoji = event_json.jsonString(payload.get("emoji")) orelse return "invalid_event_envelope";
        try insertReaction(db, "comment", envelope.object_id, emoji, envelope.actor_principal, event_hash, envelope.occurred_at);
        if (try reactionLimitRejection(db, "comment", envelope.object_id)) |reason| return reason;
    } else if (std.mem.eql(u8, envelope.event_type, "comment.reaction_removed")) {
        if (!(try acceptedCreationInFrontier(allocator, db, "comment.added", envelope.object_id, event_hash))) return "object_not_created";
        const emoji = event_json.jsonString(payload.get("emoji")) orelse return "invalid_event_envelope";
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
