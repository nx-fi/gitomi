const std = @import("std");
const errors = @import("errors.zig");
const io = @import("io.zig");
const json_writer = @import("json_writer.zig");
const repo_mod = @import("repo.zig");
const util = @import("util.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const Config = repo_mod.Config;
const eprint = io.eprint;
const looksLikeUuid = util.looksLikeUuid;
const appendJsonFieldString = json_writer.appendJsonFieldString;
const appendJsonFieldUnsigned = json_writer.appendJsonFieldUnsigned;
const appendJsonFieldStringArray = json_writer.appendJsonFieldStringArray;

pub const event_schema = "urn:gitomi:event:v1";

pub const EventSummary = struct {
    allocator: Allocator,
    event_type: []u8,
    object_kind: []u8,
    object_id: []u8,
    actor_principal: []u8,
    actor_device: []u8,
    seq: ?i64 = null,
    occurred_at: []u8,

    pub fn deinit(self: EventSummary) void {
        self.allocator.free(self.event_type);
        self.allocator.free(self.object_kind);
        self.allocator.free(self.object_id);
        self.allocator.free(self.actor_principal);
        self.allocator.free(self.actor_device);
        self.allocator.free(self.occurred_at);
    }
};

pub fn buildIssueOpenedJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    issue_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    title: []const u8,
    body: []const u8,
    labels: []const []const u8,
    assignees: []const []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.append(allocator, '{');
    try appendJsonFieldString(&buf, allocator, "$schema", event_schema, true);
    try appendJsonFieldString(&buf, allocator, "repo_id", cfg.repo_id, true);
    try appendJsonFieldString(&buf, allocator, "event_uuid", event_uuid, true);
    try appendJsonFieldString(&buf, allocator, "event_type", "issue.opened", true);

    try buf.appendSlice(allocator, "\"object\":{");
    try appendJsonFieldString(&buf, allocator, "kind", "issue", true);
    try appendJsonFieldString(&buf, allocator, "id", issue_id, false);
    try buf.appendSlice(allocator, "},");

    try appendJsonFieldString(&buf, allocator, "idempotency_key", idem, true);

    try buf.appendSlice(allocator, "\"actor\":{");
    try appendJsonFieldString(&buf, allocator, "principal", cfg.principal, true);
    try appendJsonFieldString(&buf, allocator, "device", cfg.device, false);
    try buf.appendSlice(allocator, "},");

    try appendJsonFieldUnsigned(&buf, allocator, "seq", seq, true);
    try appendJsonFieldString(&buf, allocator, "occurred_at", occurred_at, true);
    try buf.appendSlice(allocator, "\"legacy\":{},");

    try buf.appendSlice(allocator, "\"payload\":{");
    try appendJsonFieldString(&buf, allocator, "title", title, true);
    if (body.len != 0) {
        try appendJsonFieldString(&buf, allocator, "body", body, true);
    }
    if (labels.len != 0) {
        try appendJsonFieldStringArray(&buf, allocator, "labels", labels, true);
    }
    if (assignees.len != 0) {
        try appendJsonFieldStringArray(&buf, allocator, "assignees", assignees, true);
    }
    if (buf.items[buf.items.len - 1] == ',') {
        buf.items.len -= 1;
    }
    try buf.appendSlice(allocator, "}}");

    return try buf.toOwnedSlice(allocator);
}

pub fn validateEventEnvelope(allocator: Allocator, commit: []const u8, body: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        try eprint("gt sync: rejecting {s}: event body is not valid JSON\n", .{commit});
        return CliError.UserError;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => {
            try eprint("gt sync: rejecting {s}: event body must be a JSON object\n", .{commit});
            return CliError.UserError;
        },
    };

    try requireJsonStringEq(commit, root, "$schema", event_schema);
    try requireJsonUuid(commit, root, "repo_id");
    try requireJsonUuid(commit, root, "event_uuid");
    _ = try requireJsonString(commit, root, "event_type");
    try requireJsonUuid(commit, root, "idempotency_key");
    _ = try requireJsonObject(commit, root, "legacy");
    _ = try requireJsonObject(commit, root, "payload");

    const seq_value = root.get("seq") orelse {
        try eprint("gt sync: rejecting {s}: missing seq\n", .{commit});
        return CliError.UserError;
    };
    if (seq_value != .integer or seq_value.integer < 0) {
        try eprint("gt sync: rejecting {s}: seq must be a non-negative integer\n", .{commit});
        return CliError.UserError;
    }

    const occurred_at = try requireJsonString(commit, root, "occurred_at");
    if (occurred_at.len == 0 or occurred_at[occurred_at.len - 1] != 'Z') {
        try eprint("gt sync: rejecting {s}: occurred_at must be a UTC RFC3339 timestamp\n", .{commit});
        return CliError.UserError;
    }

    const object = try requireJsonObject(commit, root, "object");
    const kind = try requireJsonString(commit, object, "kind");
    if (!isKnownObjectKind(kind)) {
        try eprint("gt sync: rejecting {s}: unknown object kind '{s}'\n", .{ commit, kind });
        return CliError.UserError;
    }
    try requireJsonUuid(commit, object, "id");

    const actor = try requireJsonObject(commit, root, "actor");
    const principal = try requireJsonString(commit, actor, "principal");
    const device = try requireJsonString(commit, actor, "device");
    if (principal.len == 0 or device.len == 0) {
        try eprint("gt sync: rejecting {s}: actor principal and device are required\n", .{commit});
        return CliError.UserError;
    }
}

pub fn requireJsonObject(commit: []const u8, object: std.json.ObjectMap, key: []const u8) !std.json.ObjectMap {
    const value = object.get(key) orelse {
        try eprint("gt sync: rejecting {s}: missing {s}\n", .{ commit, key });
        return CliError.UserError;
    };
    return switch (value) {
        .object => |child| child,
        else => {
            try eprint("gt sync: rejecting {s}: {s} must be an object\n", .{ commit, key });
            return CliError.UserError;
        },
    };
}

pub fn requireJsonString(commit: []const u8, object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse {
        try eprint("gt sync: rejecting {s}: missing {s}\n", .{ commit, key });
        return CliError.UserError;
    };
    const string = switch (value) {
        .string => |s| s,
        else => {
            try eprint("gt sync: rejecting {s}: {s} must be a string\n", .{ commit, key });
            return CliError.UserError;
        },
    };
    if (string.len == 0) {
        try eprint("gt sync: rejecting {s}: {s} must not be empty\n", .{ commit, key });
        return CliError.UserError;
    }
    return string;
}

pub fn requireJsonStringEq(commit: []const u8, object: std.json.ObjectMap, key: []const u8, expected: []const u8) !void {
    const value = try requireJsonString(commit, object, key);
    if (!std.mem.eql(u8, value, expected)) {
        try eprint("gt sync: rejecting {s}: {s} must be {s}\n", .{ commit, key, expected });
        return CliError.UserError;
    }
}

pub fn requireJsonUuid(commit: []const u8, object: std.json.ObjectMap, key: []const u8) !void {
    const value = try requireJsonString(commit, object, key);
    if (!looksLikeUuid(value)) {
        try eprint("gt sync: rejecting {s}: {s} must be a UUID\n", .{ commit, key });
        return CliError.UserError;
    }
}

pub fn isKnownObjectKind(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "issue") or
        std.mem.eql(u8, kind, "pull") or
        std.mem.eql(u8, kind, "comment") or
        std.mem.eql(u8, kind, "acl") or
        std.mem.eql(u8, kind, "identity") or
        std.mem.eql(u8, kind, "action");
}

pub fn parseEventSummary(allocator: Allocator, body: []const u8) ?EventSummary {
    return parseEventSummaryInner(allocator, body) catch null;
}

pub fn parseEventSummaryInner(allocator: Allocator, body: []const u8) !EventSummary {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidEventJson,
    };

    var event_type: ?[]u8 = try dupeJsonString(allocator, object.get("event_type"));
    errdefer if (event_type) |value| allocator.free(value);
    var object_kind: ?[]u8 = try allocator.dupe(u8, "");
    errdefer if (object_kind) |value| allocator.free(value);
    var object_id: ?[]u8 = try allocator.dupe(u8, "");
    errdefer if (object_id) |value| allocator.free(value);
    var actor_principal: ?[]u8 = try allocator.dupe(u8, "");
    errdefer if (actor_principal) |value| allocator.free(value);
    var actor_device: ?[]u8 = try allocator.dupe(u8, "");
    errdefer if (actor_device) |value| allocator.free(value);
    var occurred_at: ?[]u8 = try dupeJsonString(allocator, object.get("occurred_at"));
    errdefer if (occurred_at) |value| allocator.free(value);

    var summary = EventSummary{
        .allocator = allocator,
        .event_type = event_type.?,
        .object_kind = object_kind.?,
        .object_id = object_id.?,
        .actor_principal = actor_principal.?,
        .actor_device = actor_device.?,
        .seq = jsonInteger(object.get("seq")),
        .occurred_at = occurred_at.?,
    };
    event_type = null;
    object_kind = null;
    object_id = null;
    actor_principal = null;
    actor_device = null;
    occurred_at = null;
    errdefer summary.deinit();

    if (object.get("object")) |obj_value| {
        if (obj_value == .object) {
            var next_object_kind: ?[]u8 = try dupeJsonString(allocator, obj_value.object.get("kind"));
            errdefer if (next_object_kind) |value| allocator.free(value);
            var next_object_id: ?[]u8 = try dupeJsonString(allocator, obj_value.object.get("id"));
            errdefer if (next_object_id) |value| allocator.free(value);
            allocator.free(summary.object_kind);
            summary.object_kind = next_object_kind.?;
            next_object_kind = null;
            allocator.free(summary.object_id);
            summary.object_id = next_object_id.?;
            next_object_id = null;
        }
    }

    if (object.get("actor")) |actor_value| {
        if (actor_value == .object) {
            var next_actor_principal: ?[]u8 = try dupeJsonString(allocator, actor_value.object.get("principal"));
            errdefer if (next_actor_principal) |value| allocator.free(value);
            var next_actor_device: ?[]u8 = try dupeJsonString(allocator, actor_value.object.get("device"));
            errdefer if (next_actor_device) |value| allocator.free(value);
            allocator.free(summary.actor_principal);
            summary.actor_principal = next_actor_principal.?;
            next_actor_principal = null;
            allocator.free(summary.actor_device);
            summary.actor_device = next_actor_device.?;
            next_actor_device = null;
        }
    }

    return summary;
}

pub fn jsonString(value: ?std.json.Value) ?[]const u8 {
    if (value) |v| {
        return switch (v) {
            .string => |s| s,
            else => null,
        };
    }
    return null;
}

pub fn jsonBool(value: ?std.json.Value) ?bool {
    if (value) |v| {
        return switch (v) {
            .bool => |b| b,
            else => null,
        };
    }
    return null;
}

pub fn dupeJsonString(allocator: Allocator, value: ?std.json.Value) ![]u8 {
    return allocator.dupe(u8, jsonString(value) orelse "");
}

pub fn jsonInteger(value: ?std.json.Value) ?i64 {
    if (value) |v| {
        return switch (v) {
            .integer => |i| i,
            else => null,
        };
    }
    return null;
}

test "issue opened event json contains required envelope fields" {
    var cfg = Config{
        .allocator = std.testing.allocator,
        .repo_id = try std.testing.allocator.dupe(u8, "018f0000-0000-7000-8000-000000000001"),
        .principal = try std.testing.allocator.dupe(u8, "alice"),
        .device = try std.testing.allocator.dupe(u8, "laptop"),
        .seq = 0,
    };
    defer cfg.deinit();

    const labels = [_][]const u8{"bug"};
    const assignees = [_][]const u8{"alice"};
    const body = try buildIssueOpenedJson(
        std.testing.allocator,
        cfg,
        1,
        "018f0000-0000-7000-8000-000000000002",
        "018f0000-0000-7000-8000-000000000003",
        "018f0000-0000-7000-8000-000000000004",
        "2026-05-13T18:30:59Z",
        "Smoke",
        "Body",
        &labels,
        &assignees,
    );
    defer std.testing.allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings(event_schema, root.get("$schema").?.string);
    try std.testing.expectEqualStrings("issue.opened", root.get("event_type").?.string);
    try std.testing.expectEqual(@as(i64, 1), root.get("seq").?.integer);
    try std.testing.expectEqualStrings("issue", root.get("object").?.object.get("kind").?.string);
    try std.testing.expectEqualStrings("Smoke", root.get("payload").?.object.get("title").?.string);
}

test "issue opened event json passes envelope validation" {
    var cfg = Config{
        .allocator = std.testing.allocator,
        .repo_id = try std.testing.allocator.dupe(u8, "018f0000-0000-7000-8000-000000000001"),
        .principal = try std.testing.allocator.dupe(u8, "alice"),
        .device = try std.testing.allocator.dupe(u8, "laptop"),
        .seq = 0,
    };
    defer cfg.deinit();

    const body = try buildIssueOpenedJson(
        std.testing.allocator,
        cfg,
        1,
        "018f0000-0000-7000-8000-000000000002",
        "018f0000-0000-7000-8000-000000000003",
        "018f0000-0000-7000-8000-000000000004",
        "2026-05-13T18:30:59Z",
        "Smoke",
        "",
        &.{},
        &.{},
    );
    defer std.testing.allocator.free(body);

    try validateEventEnvelope(std.testing.allocator, "test-commit", body);
}
