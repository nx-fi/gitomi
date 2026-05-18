const std = @import("std");

const common = @import("projection_objects/common.zig");
const issues = @import("projection_objects/issues.zig");
const projects = @import("projection_objects/projects.zig");
const milestones = @import("projection_objects/milestones.zig");
const labels = @import("projection_objects/labels.zig");
const pulls = @import("projection_objects/pulls.zig");
const comments = @import("projection_objects/comments.zig");
const notifications = @import("projection_objects/notifications.zig");
const index_schema = @import("schema.zig");
const sqlite_db = @import("sqlite_db.zig");

const Allocator = common.Allocator;
const SqliteDb = common.SqliteDb;
const ValidatedEnvelope = common.ValidatedEnvelope;
const upsertSourceIdentity = common.upsertSourceIdentity;
const creationEventWins = common.creationEventWins;
const pullMergeOidRejection = pulls.pullMergeOidRejection;

pub const applyIssueProjection = issues.applyIssueProjection;
pub const applyProjectProjection = projects.applyProjectProjection;
pub const applyMilestoneProjection = milestones.applyMilestoneProjection;
pub const applyLabelProjection = labels.applyLabelProjection;
pub const applyPullProjection = pulls.applyPullProjection;
pub const applyCommentProjection = comments.applyCommentProjection;
pub const applyNotificationProjection = notifications.applyNotificationProjection;
pub const applyNotificationSideEffects = notifications.applyNotificationSideEffects;

test "source identity upsert preserves existing display fields and aliases" {
    const allocator = std.testing.allocator;
    var db = try SqliteDb.open(allocator, ":memory:", sqlite_db.sqlite.SQLITE_OPEN_READWRITE | sqlite_db.sqlite.SQLITE_OPEN_CREATE, true);
    defer db.deinit();
    try index_schema.createIndexSchema(&db);

    try upsertSourceIdentity(&db, .{
        .identity = "github:123",
        .author = "Victim",
        .email = "victim@example.test",
        .avatar_url = "https://avatars.githubusercontent.com/u/123?v=4",
    });
    try upsertSourceIdentity(&db, .{
        .identity = "github:123",
        .author = "Mallory",
        .email = "mallory@example.test",
        .avatar_url = "https://attacker.invalid/avatar.png",
    });

    try expectSourceIdentity(
        &db,
        "github:123",
        "Victim",
        "victim@example.test",
        "https://avatars.githubusercontent.com/u/123?v=4",
    );
    try expectIdentityAlias(&db, "display", "Victim", "github:123");
    try expectIdentityAlias(&db, "email", "victim@example.test", "github:123");
    try expectNoIdentityAlias(&db, "display", "Mallory");
    try expectNoIdentityAlias(&db, "email", "mallory@example.test");

    try upsertSourceIdentity(&db, .{
        .identity = "github:999",
        .author = "Victim",
        .email = "victim@example.test",
        .avatar_url = "https://avatars.githubusercontent.com/u/999?v=4",
    });
    try expectIdentityAlias(&db, "display", "Victim", "github:123");
    try expectIdentityAlias(&db, "email", "victim@example.test", "github:123");
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

test "pull merged rejects syntactic OIDs that are not local commits" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{
        \\  "merge_oid": "0000000000000000000000000000000000000000"
        \\}
    , .{});
    defer parsed.deinit();
    const payload = switch (parsed.value) {
        .object => |object| object,
        else => unreachable,
    };

    const rejected = try pullMergeOidRejection(allocator, "0000000000000000000000000000000000000000", "", payload);
    try std.testing.expect(rejected != null);
    try std.testing.expectEqualStrings("invalid_merge_oid", rejected.?);
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

fn expectSourceIdentity(db: *SqliteDb, id: []const u8, display_name: []const u8, email: []const u8, avatar_url: []const u8) !void {
    var stmt = try db.prepare("SELECT display_name, email, avatar_url FROM identities WHERE id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, id);
    try std.testing.expect(try stmt.step());
    const actual_display_name = try stmt.columnTextDup(std.testing.allocator, 0);
    defer std.testing.allocator.free(actual_display_name);
    const actual_email = try stmt.columnTextDup(std.testing.allocator, 1);
    defer std.testing.allocator.free(actual_email);
    const actual_avatar_url = try stmt.columnTextDup(std.testing.allocator, 2);
    defer std.testing.allocator.free(actual_avatar_url);
    try std.testing.expectEqualStrings(display_name, actual_display_name);
    try std.testing.expectEqualStrings(email, actual_email);
    try std.testing.expectEqualStrings(avatar_url, actual_avatar_url);
}

fn expectIdentityAlias(db: *SqliteDb, kind: []const u8, value: []const u8, identity: []const u8) !void {
    var stmt = try db.prepare("SELECT identity_id FROM identity_aliases WHERE alias_kind = ? AND alias_value = ?");
    defer stmt.deinit();
    try stmt.bindText(1, kind);
    try stmt.bindText(2, value);
    try std.testing.expect(try stmt.step());
    const actual_identity = try stmt.columnTextDup(std.testing.allocator, 0);
    defer std.testing.allocator.free(actual_identity);
    try std.testing.expectEqualStrings(identity, actual_identity);
}

fn expectNoIdentityAlias(db: *SqliteDb, kind: []const u8, value: []const u8) !void {
    var stmt = try db.prepare("SELECT 1 FROM identity_aliases WHERE alias_kind = ? AND alias_value = ?");
    defer stmt.deinit();
    try stmt.bindText(1, kind);
    try stmt.bindText(2, value);
    try std.testing.expect(!(try stmt.step()));
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
