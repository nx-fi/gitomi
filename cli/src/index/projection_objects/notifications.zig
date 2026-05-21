const std = @import("std");

const common = @import("common.zig");

const event_json = common.event_json;
const Allocator = common.Allocator;
const SqliteDb = common.SqliteDb;
const ValidatedEnvelope = common.ValidatedEnvelope;
const acceptedCreationInFrontier = common.acceptedCreationInFrontier;
const eventWins = common.eventWins;

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
    const principal = event_json.jsonString(payload.get("principal")) orelse return "invalid_event_envelope";

    if (std.mem.eql(u8, envelope.event_type, "notification.subscribed") or
        std.mem.eql(u8, envelope.event_type, "notification.unsubscribed"))
    {
        const target_kind = event_json.jsonString(payload.get("target_kind")) orelse return "invalid_event_envelope";
        const target_id = event_json.jsonString(payload.get("target_id")) orelse return "invalid_event_envelope";
        if (!(try notificationTargetExists(allocator, db, target_kind, target_id, event_hash))) return "object_not_created";
        try upsertNotificationSubscription(
            allocator,
            db,
            principal,
            target_kind,
            target_id,
            std.mem.eql(u8, envelope.event_type, "notification.subscribed"),
            event_json.jsonString(payload.get("reason")) orelse "manual",
            event_hash,
            envelope,
        );
        return null;
    }

    if (std.mem.eql(u8, envelope.event_type, "notification.read")) {
        const read_event_hash = event_json.jsonString(payload.get("event_hash")) orelse return "invalid_event_envelope";
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
        if (event_json.jsonString(payload.get("assignee"))) |assignee| {
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
        if (event_json.jsonString(payload.get("assignee"))) |assignee| {
            try upsertNotificationSubscription(allocator, db, assignee, "pull", envelope.object_id, true, "assignee", event_hash, envelope);
        }
    } else if (std.mem.eql(u8, envelope.event_type, "pull.reviewer_added")) {
        if (event_json.jsonString(payload.get("reviewer"))) |reviewer| {
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
        const parent_kind = event_json.jsonString(payload.get("parent_kind")) orelse return;
        const parent_id = event_json.jsonString(payload.get("parent_id")) orelse return;
        if (!std.mem.eql(u8, parent_kind, "issue") and !std.mem.eql(u8, parent_kind, "pull")) return;

        try upsertNotificationSubscription(allocator, db, envelope.actor_principal, parent_kind, parent_id, true, "commenter", event_hash, envelope);
        if (event_json.jsonString(payload.get("body"))) |comment_body| {
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
        const principal = std.mem.trimEnd(u8, body[start..end], ".");
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
