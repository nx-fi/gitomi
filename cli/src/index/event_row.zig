const std = @import("std");

const io = @import("../io.zig");
const json_writer = @import("../json_writer.zig");
const sqlite_db = @import("sqlite_db.zig");
const util = @import("../util.zig");

const Allocator = std.mem.Allocator;
const SqliteStmt = sqlite_db.SqliteStmt;
const appendJsonFieldBool = json_writer.appendJsonFieldBool;
const appendJsonFieldInteger = json_writer.appendJsonFieldInteger;
const appendJsonFieldString = json_writer.appendJsonFieldString;
const appendJsonString = json_writer.appendJsonString;
const out = io.out;

pub const IndexedEvent = struct {
    ref: []const u8,
    commit: []const u8,
    event_hash: []const u8,
    tree: []const u8,
    subject: []const u8,
    empty_tree: bool,
    valid_json: bool,
    event_type: []const u8,
    object_kind: []const u8,
    object_id: []const u8,
    actor_principal: []const u8,
    actor_device: []const u8,
    seq: ?i64,
    occurred_at: []const u8,
    domain_status: []const u8,
    rejection_reason: []const u8,
    body: []const u8,
};

pub fn indexedEventFromStmt(allocator: Allocator, stmt: *SqliteStmt) !IndexedEvent {
    var ref: ?[]u8 = try stmt.columnTextDup(allocator, 0);
    errdefer if (ref) |value| allocator.free(value);
    var commit: ?[]u8 = try stmt.columnTextDup(allocator, 1);
    errdefer if (commit) |value| allocator.free(value);
    var event_hash: ?[]u8 = try stmt.columnTextDup(allocator, 2);
    errdefer if (event_hash) |value| allocator.free(value);
    var tree: ?[]u8 = try stmt.columnTextDup(allocator, 3);
    errdefer if (tree) |value| allocator.free(value);
    var subject: ?[]u8 = try stmt.columnTextDup(allocator, 4);
    errdefer if (subject) |value| allocator.free(value);
    var event_type: ?[]u8 = try stmt.columnTextDup(allocator, 7);
    errdefer if (event_type) |value| allocator.free(value);
    var object_kind: ?[]u8 = try stmt.columnTextDup(allocator, 8);
    errdefer if (object_kind) |value| allocator.free(value);
    var object_id: ?[]u8 = try stmt.columnTextDup(allocator, 9);
    errdefer if (object_id) |value| allocator.free(value);
    var actor_principal: ?[]u8 = try stmt.columnTextDup(allocator, 10);
    errdefer if (actor_principal) |value| allocator.free(value);
    var actor_device: ?[]u8 = try stmt.columnTextDup(allocator, 11);
    errdefer if (actor_device) |value| allocator.free(value);
    var occurred_at: ?[]u8 = try stmt.columnTextDup(allocator, 13);
    errdefer if (occurred_at) |value| allocator.free(value);
    var domain_status: ?[]u8 = try stmt.columnTextDup(allocator, 14);
    errdefer if (domain_status) |value| allocator.free(value);
    var rejection_reason: ?[]u8 = try stmt.columnTextDup(allocator, 15);
    errdefer if (rejection_reason) |value| allocator.free(value);
    var body: ?[]u8 = try stmt.columnTextDup(allocator, 16);
    errdefer if (body) |value| allocator.free(value);

    const event = IndexedEvent{
        .ref = ref.?,
        .commit = commit.?,
        .event_hash = event_hash.?,
        .tree = tree.?,
        .subject = subject.?,
        .empty_tree = stmt.columnInt(5) != 0,
        .valid_json = stmt.columnInt(6) != 0,
        .event_type = event_type.?,
        .object_kind = object_kind.?,
        .object_id = object_id.?,
        .actor_principal = actor_principal.?,
        .actor_device = actor_device.?,
        .seq = if (stmt.columnIsNull(12)) null else stmt.columnInt64(12),
        .occurred_at = occurred_at.?,
        .domain_status = domain_status.?,
        .rejection_reason = rejection_reason.?,
        .body = body.?,
    };
    ref = null;
    commit = null;
    event_hash = null;
    tree = null;
    subject = null;
    event_type = null;
    object_kind = null;
    object_id = null;
    actor_principal = null;
    actor_device = null;
    occurred_at = null;
    domain_status = null;
    rejection_reason = null;
    body = null;
    return event;
}

pub fn freeIndexedEvent(allocator: Allocator, event: IndexedEvent) void {
    allocator.free(event.ref);
    allocator.free(event.commit);
    allocator.free(event.event_hash);
    allocator.free(event.tree);
    allocator.free(event.subject);
    allocator.free(event.event_type);
    allocator.free(event.object_kind);
    allocator.free(event.object_id);
    allocator.free(event.actor_principal);
    allocator.free(event.actor_device);
    allocator.free(event.occurred_at);
    allocator.free(event.domain_status);
    allocator.free(event.rejection_reason);
    allocator.free(event.body);
}

pub fn appendIndexedEventJson(buf: *std.ArrayList(u8), allocator: Allocator, event: IndexedEvent) !void {
    try buf.append(allocator, '{');
    try appendJsonFieldString(buf, allocator, "ref", event.ref, true);
    try appendJsonFieldString(buf, allocator, "commit", event.commit, true);
    try appendJsonFieldString(buf, allocator, "event_hash", event.event_hash, true);
    try appendJsonFieldString(buf, allocator, "tree", event.tree, true);
    try appendJsonFieldString(buf, allocator, "subject", event.subject, true);
    try appendJsonFieldBool(buf, allocator, "empty_tree", event.empty_tree, true);
    try appendJsonFieldBool(buf, allocator, "valid_json", event.valid_json, true);
    try appendJsonFieldString(buf, allocator, "domain_status", event.domain_status, event.rejection_reason.len != 0 or event.valid_json);
    if (event.rejection_reason.len != 0) {
        try appendJsonFieldString(buf, allocator, "rejection_reason", event.rejection_reason, event.valid_json);
    }
    if (event.valid_json) {
        try appendJsonFieldString(buf, allocator, "event_type", event.event_type, true);
        try appendJsonFieldString(buf, allocator, "object_kind", event.object_kind, true);
        try appendJsonFieldString(buf, allocator, "object_id", event.object_id, true);
        try appendJsonFieldString(buf, allocator, "actor_principal", event.actor_principal, true);
        try appendJsonFieldString(buf, allocator, "actor_device", event.actor_device, true);
        if (event.seq) |seq| try appendJsonFieldInteger(buf, allocator, "seq", seq, true);
        const has_run_completed_payload = std.mem.eql(u8, event.event_type, "action.run_completed");
        try appendJsonFieldString(buf, allocator, "occurred_at", event.occurred_at, true);
        _ = try appendEventMetadataJsonFields(buf, allocator, event.body);
        if (has_run_completed_payload) {
            const wrote_payload = try appendRunCompletedPayloadJsonFields(buf, allocator, event.body);
            if (!wrote_payload and buf.items[buf.items.len - 1] == ',') {
                buf.items.len -= 1;
            }
        }
    }
    if (buf.items[buf.items.len - 1] == ',') {
        buf.items.len -= 1;
    }
    try buf.append(allocator, '}');
}

fn appendEventMetadataJsonFields(buf: *std.ArrayList(u8), allocator: Allocator, body: []const u8) !bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return false;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return false,
    };

    const legacy = switch (root.get("legacy") orelse return false) {
        .object => |object| object,
        else => return false,
    };

    var wrote = false;
    try buf.appendSlice(allocator, "\"metadata\":{");
    try appendMetadataIntegerField(buf, allocator, &wrote, "github_issue_number", legacy.get("github_issue_number"));
    try appendMetadataIntegerField(buf, allocator, &wrote, "github_issue_id", legacy.get("github_issue_id"));
    try appendMetadataIntegerField(buf, allocator, &wrote, "github_pull_number", legacy.get("github_pull_number"));
    try appendMetadataIntegerField(buf, allocator, &wrote, "github_pull_id", legacy.get("github_pull_id"));
    try appendMetadataIntegerField(buf, allocator, &wrote, "github_project_id", legacy.get("github_project_id"));
    try appendMetadataIntegerField(buf, allocator, &wrote, "github_milestone_id", legacy.get("github_milestone_id"));
    try appendMetadataIntegerField(buf, allocator, &wrote, "gitlab_issue_iid", legacy.get("gitlab_issue_iid"));
    try appendMetadataIntegerField(buf, allocator, &wrote, "gitlab_merge_request_iid", legacy.get("gitlab_merge_request_iid"));
    if (!wrote) {
        buf.items.len -= "\"metadata\":{".len;
        return false;
    }
    try buf.appendSlice(allocator, "},");
    return true;
}

fn appendMetadataIntegerField(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    wrote_any: *bool,
    key: []const u8,
    value: ?std.json.Value,
) !void {
    const actual = switch (value orelse return) {
        .integer => |integer| integer,
        else => return,
    };
    if (actual <= 0) return;
    if (wrote_any.*) try buf.append(allocator, ',');
    try appendJsonString(buf, allocator, key);
    try buf.append(allocator, ':');
    try buf.writer(allocator).print("{d}", .{actual});
    wrote_any.* = true;
}

fn appendRunCompletedPayloadJsonFields(buf: *std.ArrayList(u8), allocator: Allocator, body: []const u8) !bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        try appendJsonString(buf, allocator, "payload_unavailable");
        try buf.appendSlice(allocator, ":true");
        return true;
    };
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => {
            try appendJsonString(buf, allocator, "payload_unavailable");
            try buf.appendSlice(allocator, ":true");
            return true;
        },
    };
    const payload = switch (root.get("payload") orelse return false) {
        .object => |object| object,
        else => return false,
    };
    var wrote = false;
    if (payload.get("diagnostics_ref")) |value| {
        if (value == .string) {
            try appendJsonFieldString(buf, allocator, "diagnostics_ref", value.string, true);
            wrote = true;
        }
    }
    if (payload.get("diagnostics_oid")) |value| {
        if (value == .string) {
            try appendJsonFieldString(buf, allocator, "diagnostics_oid", value.string, false);
            wrote = true;
        }
    }
    if (wrote and buf.items[buf.items.len - 1] == ',') {
        buf.items.len -= 1;
    }
    return wrote;
}

pub fn printIndexedEvent(event: IndexedEvent) !void {
    const short = event.commit[0..@min(event.commit.len, 12)];

    if (event.valid_json) {
        var object_ref_buf: [util.short_object_ref_len]u8 = undefined;
        const object_ref = if (event.object_id.len == 0) "" else util.shortObjectRef(&object_ref_buf, event.object_id);
        try out("{s} {s} {s} #{s} {s}{s}{s}\n", .{
            short,
            event.ref,
            event.event_type,
            object_ref,
            event.subject,
            if (std.mem.eql(u8, event.domain_status, "rejected")) " rejected:" else "",
            if (std.mem.eql(u8, event.domain_status, "rejected")) event.rejection_reason else "",
        });
    } else {
        try out("{s} {s} invalid-event {s}\n", .{ short, event.ref, event.subject });
    }
}

test "indexed event json carries projection fields" {
    const event = IndexedEvent{
        .ref = "refs/gitomi/inbox/alice/laptop",
        .commit = "0123456789abcdef0123456789abcdef01234567",
        .event_hash = "0123456789abcdef0123456789abcdef01234567",
        .tree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904",
        .subject = "issue.opened #018f000 Indexed",
        .empty_tree = true,
        .valid_json = true,
        .event_type = "issue.opened",
        .object_kind = "issue",
        .object_id = "018f0000-0000-7000-8000-000000000002",
        .actor_principal = "alice",
        .actor_device = "laptop",
        .seq = 7,
        .occurred_at = "2026-05-13T18:30:59Z",
        .domain_status = "accepted",
        .rejection_reason = "",
        .body = "{}",
    };

    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(std.testing.allocator);
    try appendIndexedEventJson(&line, std.testing.allocator, event);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line.items, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("refs/gitomi/inbox/alice/laptop", root.get("ref").?.string);
    try std.testing.expectEqual(true, root.get("empty_tree").?.bool);
    try std.testing.expectEqual(true, root.get("valid_json").?.bool);
    try std.testing.expectEqualStrings("accepted", root.get("domain_status").?.string);
    try std.testing.expectEqualStrings("issue.opened", root.get("event_type").?.string);
    try std.testing.expectEqual(@as(i64, 7), root.get("seq").?.integer);
}

test "indexed event json carries provider metadata" {
    const event = IndexedEvent{
        .ref = "refs/gitomi/inbox/import-bot/github",
        .commit = "0123456789abcdef0123456789abcdef01234567",
        .event_hash = "0123456789abcdef0123456789abcdef01234567",
        .tree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904",
        .subject = "issue.updated #018f000 GitHub #88 alias",
        .empty_tree = true,
        .valid_json = true,
        .event_type = "issue.updated",
        .object_kind = "issue",
        .object_id = "018f0000-0000-7000-8000-000000000002",
        .actor_principal = "import-bot",
        .actor_device = "github",
        .seq = 9,
        .occurred_at = "2026-05-13T18:30:59Z",
        .domain_status = "accepted",
        .rejection_reason = "",
        .body = "{\"legacy\":{\"github_issue_number\":88,\"github_issue_id\":880088},\"payload\":{}}",
    };

    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(std.testing.allocator);
    try appendIndexedEventJson(&line, std.testing.allocator, event);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line.items, .{});
    defer parsed.deinit();
    const metadata = parsed.value.object.get("metadata").?.object;
    try std.testing.expectEqual(@as(i64, 88), metadata.get("github_issue_number").?.integer);
    try std.testing.expectEqual(@as(i64, 880088), metadata.get("github_issue_id").?.integer);
}
