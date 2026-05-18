const std = @import("std");
const errors = @import("../errors.zig");
const git = @import("../git.zig");
const io = @import("../io.zig");
const util = @import("../util.zig");
const model = @import("model.zig");
const json_access = @import("json.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const eprint = io.eprint;
const looksLikeUuid = util.looksLikeUuid;
const event_schema = model.event_schema;
const ValidatedEnvelope = model.ValidatedEnvelope;
const jsonString = json_access.jsonString;

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

    if (try validateEnvelopeObject(allocator, root)) |message| {
        defer allocator.free(message);
        try eprint("gt sync: rejecting {s}: {s}\n", .{ commit, message });
        return CliError.UserError;
    }
}

pub fn parseValidatedEnvelope(allocator: Allocator, body: []const u8) !ValidatedEnvelope {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.InvalidEventEnvelope;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidEventEnvelope,
    };

    return try parseValidatedEnvelopeObject(allocator, root);
}

pub fn parseValidatedEnvelopeObject(allocator: Allocator, root: std.json.ObjectMap) !ValidatedEnvelope {
    if (try validateEnvelopeObject(allocator, root)) |message| {
        allocator.free(message);
        return error.InvalidEventEnvelope;
    }

    const repo_id = requiredString(root, "repo_id").?;
    const event_uuid = requiredString(root, "event_uuid").?;
    const event_type = requiredString(root, "event_type").?;
    const idempotency_key = requiredString(root, "idempotency_key").?;
    const seq = root.get("seq").?.integer;
    const occurred_at = requiredString(root, "occurred_at").?;

    const object = requiredObject(root, "object").?;
    const object_kind = requiredString(object, "kind").?;
    const object_id = requiredString(object, "id").?;

    const actor = requiredObject(root, "actor").?;
    const actor_principal = requiredString(actor, "principal").?;
    const actor_device = requiredString(actor, "device").?;

    var owned = util.OwnedSliceList{ .allocator = allocator };
    defer owned.deinit();

    const envelope = ValidatedEnvelope{
        .allocator = allocator,
        .repo_id = try owned.dupe(repo_id),
        .event_uuid = try owned.dupe(event_uuid),
        .event_type = try owned.dupe(event_type),
        .object_kind = try owned.dupe(object_kind),
        .object_id = try owned.dupe(object_id),
        .idempotency_key = try owned.dupe(idempotency_key),
        .actor_principal = try owned.dupe(actor_principal),
        .actor_device = try owned.dupe(actor_device),
        .seq = seq,
        .occurred_at = try owned.dupe(occurred_at),
    };
    owned.release();
    return envelope;
}

pub const ParentHashValidationFailure = enum {
    invalid_event_body,
    invalid_parent_hashes,
    root_anchor_mismatch,
    log_mismatch_first_parent,
    non_root_anchor,
    causal_count_mismatch,
    causal_parent_cap_exceeded,
    related_parent_cap_exceeded,
    causal_git_parent_mismatch,
};

pub fn parentHashValidationMessage(failure: ParentHashValidationFailure) []const u8 {
    return switch (failure) {
        .invalid_event_body => "event body is not valid JSON",
        .invalid_parent_hashes => "parent_hashes must include string log/anchor fields and causal/related arrays",
        .root_anchor_mismatch => "parent_hashes.anchor does not match root genesis parent",
        .log_mismatch_first_parent => "parent_hashes.log does not match first parent",
        .non_root_anchor => "non-root event has parent_hashes.anchor",
        .causal_count_mismatch => "parent_hashes.causal does not match parent count",
        .causal_parent_cap_exceeded => "parent_hashes.causal exceeds v1 causal parent cap",
        .related_parent_cap_exceeded => "parent_hashes.related exceeds v1 related parent cap",
        .causal_git_parent_mismatch => "parent_hashes.causal does not match Git parents",
    };
}

pub fn validateParentHashes(allocator: Allocator, parents: []const u8, body: []const u8) !?ParentHashValidationFailure {
    var parent_list: std.ArrayList([]const u8) = .empty;
    defer parent_list.deinit(allocator);
    var parent_it = std.mem.tokenizeScalar(u8, parents, ' ');
    while (parent_it.next()) |parent| try parent_list.append(allocator, parent);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .invalid_event_body,
    };
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return .invalid_event_body,
    };
    const parent_hashes = switch (root.get("parent_hashes") orelse return .invalid_parent_hashes) {
        .object => |object| object,
        else => return .invalid_parent_hashes,
    };
    const log_hash = switch (parent_hashes.get("log") orelse return .invalid_parent_hashes) {
        .string => |value| value,
        else => return .invalid_parent_hashes,
    };
    const anchor_hash = switch (parent_hashes.get("anchor") orelse return .invalid_parent_hashes) {
        .string => |value| value,
        else => return .invalid_parent_hashes,
    };
    const causal = switch (parent_hashes.get("causal") orelse return .invalid_parent_hashes) {
        .array => |array| array,
        else => return .invalid_parent_hashes,
    };
    const related = switch (parent_hashes.get("related") orelse return .invalid_parent_hashes) {
        .array => |array| array,
        else => return .invalid_parent_hashes,
    };

    const first_parent = if (parent_list.items.len == 0) null else parent_list.items[0];
    if (log_hash.len == 0) {
        if (first_parent == null or anchor_hash.len == 0 or !std.mem.eql(u8, anchor_hash, first_parent.?)) {
            return .root_anchor_mismatch;
        }
    } else {
        if (first_parent == null or !std.mem.eql(u8, log_hash, first_parent.?)) {
            return .log_mismatch_first_parent;
        }
        if (anchor_hash.len != 0) return .non_root_anchor;
    }

    const expected_causal_len = if (parent_list.items.len == 0) 0 else parent_list.items.len - 1;
    if (causal.items.len != expected_causal_len) return .causal_count_mismatch;
    if (causal.items.len > git.max_causal_parents) return .causal_parent_cap_exceeded;
    if (related.items.len > git.max_related_parents) return .related_parent_cap_exceeded;
    for (causal.items, 0..) |item, idx| {
        if (item != .string or !std.mem.eql(u8, item.string, parent_list.items[idx + 1])) return .causal_git_parent_mismatch;
    }
    return null;
}

pub fn validateEnvelopeObject(allocator: Allocator, root: std.json.ObjectMap) !?[]u8 {
    const schema = switch (try requiredEnvelopeString(allocator, root, "$schema", "$schema", false)) {
        .value => |value| value,
        .message => |message| return message,
    };
    if (!std.mem.eql(u8, schema, event_schema)) {
        return try validationMessage(allocator, "$schema must be {s}", .{event_schema});
    }

    _ = switch (try requiredEnvelopeUuid(allocator, root, "repo_id", "repo_id")) {
        .value => |value| value,
        .message => |message| return message,
    };
    _ = switch (try requiredEnvelopeUuid(allocator, root, "event_uuid", "event_uuid")) {
        .value => |value| value,
        .message => |message| return message,
    };
    const event_type = switch (try requiredEnvelopeString(allocator, root, "event_type", "event_type", false)) {
        .value => |value| value,
        .message => |message| return message,
    };
    _ = switch (try requiredEnvelopeUuid(allocator, root, "idempotency_key", "idempotency_key")) {
        .value => |value| value,
        .message => |message| return message,
    };
    const legacy = switch (try requiredEnvelopeObject(allocator, root, "legacy", "legacy")) {
        .value => |value| value,
        .message => |message| return message,
    };
    const payload = switch (try requiredEnvelopeObject(allocator, root, "payload", "payload")) {
        .value => |value| value,
        .message => |message| return message,
    };
    _ = switch (try requiredEnvelopeSeq(allocator, root)) {
        .value => |value| value,
        .message => |message| return message,
    };

    const occurred_at = switch (try requiredEnvelopeString(allocator, root, "occurred_at", "occurred_at", false)) {
        .value => |value| value,
        .message => |message| return message,
    };
    if (!isUtcRfc3339Timestamp(occurred_at)) {
        return try validationMessage(allocator, "occurred_at must be a UTC RFC3339 timestamp", .{});
    }

    const parent_hashes = switch (try requiredEnvelopeObject(allocator, root, "parent_hashes", "parent_hashes")) {
        .value => |value| value,
        .message => |message| return message,
    };
    _ = switch (try requiredEnvelopeString(allocator, parent_hashes, "log", "parent_hashes.log", true)) {
        .value => |value| value,
        .message => |message| return message,
    };
    _ = switch (try requiredEnvelopeString(allocator, parent_hashes, "anchor", "parent_hashes.anchor", true)) {
        .value => |value| value,
        .message => |message| return message,
    };
    if (try validateEnvelopeStringArray(allocator, parent_hashes, "causal", "parent_hashes.causal")) |message| return message;
    if (try validateEnvelopeStringArray(allocator, parent_hashes, "related", "parent_hashes.related")) |message| return message;
    if (arrayLen(parent_hashes, "related") > git.max_related_parents) {
        return try validationMessage(allocator, "parent_hashes.related exceeds v1 related parent cap", .{});
    }

    const object = switch (try requiredEnvelopeObject(allocator, root, "object", "object")) {
        .value => |value| value,
        .message => |message| return message,
    };
    const kind = switch (try requiredEnvelopeString(allocator, object, "kind", "object.kind", false)) {
        .value => |value| value,
        .message => |message| return message,
    };
    if (!isKnownObjectKind(kind)) {
        return try validationMessage(allocator, "unknown object kind '{s}'", .{kind});
    }
    const object_id = switch (try requiredEnvelopeString(allocator, object, "id", "object.id", false)) {
        .value => |value| value,
        .message => |message| return message,
    };
    if (payloadRequirementError(event_type, kind, payload, legacy)) |message| {
        return try allocator.dupe(u8, message);
    }
    if (objectIdRequirementError(event_type, kind, object_id, payload)) |message| {
        return try allocator.dupe(u8, message);
    }

    const actor = switch (try requiredEnvelopeObject(allocator, root, "actor", "actor")) {
        .value => |value| value,
        .message => |message| return message,
    };
    _ = switch (try requiredEnvelopeString(allocator, actor, "principal", "actor.principal", false)) {
        .value => |value| value,
        .message => |message| return message,
    };
    _ = switch (try requiredEnvelopeString(allocator, actor, "device", "actor.device", false)) {
        .value => |value| value,
        .message => |message| return message,
    };

    return null;
}

fn EnvelopeField(comptime T: type) type {
    return union(enum) {
        value: T,
        message: []u8,
    };
}

fn validationMessage(allocator: Allocator, comptime fmt: []const u8, args: anytype) ![]u8 {
    return std.fmt.allocPrint(allocator, fmt, args);
}

fn requiredEnvelopeObject(allocator: Allocator, object: std.json.ObjectMap, key: []const u8, label: []const u8) !EnvelopeField(std.json.ObjectMap) {
    const value = object.get(key) orelse {
        return .{ .message = try validationMessage(allocator, "missing {s}", .{label}) };
    };
    return switch (value) {
        .object => |child| .{ .value = child },
        else => .{ .message = try validationMessage(allocator, "{s} must be an object", .{label}) },
    };
}

fn requiredEnvelopeString(allocator: Allocator, object: std.json.ObjectMap, key: []const u8, label: []const u8, allow_empty: bool) !EnvelopeField([]const u8) {
    const value = object.get(key) orelse {
        return .{ .message = try validationMessage(allocator, "missing {s}", .{label}) };
    };
    const string = switch (value) {
        .string => |s| s,
        else => return .{ .message = try validationMessage(allocator, "{s} must be a string", .{label}) },
    };
    if (!allow_empty and string.len == 0) {
        return .{ .message = try validationMessage(allocator, "{s} must not be empty", .{label}) };
    }
    return .{ .value = string };
}

fn requiredEnvelopeUuid(allocator: Allocator, object: std.json.ObjectMap, key: []const u8, label: []const u8) !EnvelopeField([]const u8) {
    const field = try requiredEnvelopeString(allocator, object, key, label, false);
    const value = switch (field) {
        .value => |string| string,
        .message => |message| return .{ .message = message },
    };
    if (!looksLikeUuid(value)) {
        return .{ .message = try validationMessage(allocator, "{s} must be a UUID", .{label}) };
    }
    return .{ .value = value };
}

fn requiredEnvelopeSeq(allocator: Allocator, object: std.json.ObjectMap) !EnvelopeField(i64) {
    const value = object.get("seq") orelse return .{ .message = try validationMessage(allocator, "missing seq", .{}) };
    return switch (value) {
        .integer => |seq| if (seq >= 0)
            .{ .value = seq }
        else
            .{ .message = try validationMessage(allocator, "seq must be a non-negative integer", .{}) },
        else => .{ .message = try validationMessage(allocator, "seq must be a non-negative integer", .{}) },
    };
}

pub fn isUtcRfc3339Timestamp(value: []const u8) bool {
    if (value.len < 20) return false;
    if (!allDigits(value[0..4])) return false;
    if (value[4] != '-' or value[7] != '-' or value[10] != 'T' or value[13] != ':' or value[16] != ':') return false;
    if (!allDigits(value[5..7]) or !allDigits(value[8..10]) or !allDigits(value[11..13]) or !allDigits(value[14..16]) or !allDigits(value[17..19])) return false;

    const month = parseTwoDigits(value[5..7]);
    const day = parseTwoDigits(value[8..10]);
    const hour = parseTwoDigits(value[11..13]);
    const minute = parseTwoDigits(value[14..16]);
    const second = parseTwoDigits(value[17..19]);

    if (month < 1 or month > 12) return false;
    if (day < 1 or day > daysInMonth(parseFourDigits(value[0..4]), month)) return false;
    if (hour > 23 or minute > 59 or second > 59) return false;

    if (value[19] == 'Z') return value.len == 20;
    if (value[19] != '.') return false;
    if (value.len < 22 or value[value.len - 1] != 'Z') return false;
    return allDigits(value[20 .. value.len - 1]);
}

fn allDigits(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn parseTwoDigits(value: []const u8) u8 {
    return (value[0] - '0') * 10 + (value[1] - '0');
}

fn parseFourDigits(value: []const u8) u16 {
    return @as(u16, value[0] - '0') * 1000 +
        @as(u16, value[1] - '0') * 100 +
        @as(u16, value[2] - '0') * 10 +
        @as(u16, value[3] - '0');
}

fn daysInMonth(year: u16, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

fn isLeapYear(year: u16) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}

fn validateEnvelopeStringArray(allocator: Allocator, object: std.json.ObjectMap, key: []const u8, label: []const u8) !?[]u8 {
    const value = object.get(key) orelse return try validationMessage(allocator, "missing {s}", .{label});
    const array = switch (value) {
        .array => |items| items,
        else => return try validationMessage(allocator, "{s} must be an array of strings", .{label}),
    };
    for (array.items) |item| {
        if (item != .string) return try validationMessage(allocator, "{s} must be an array of strings", .{label});
    }
    return null;
}

pub fn isKnownObjectKind(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "issue") or
        std.mem.eql(u8, kind, "pull") or
        std.mem.eql(u8, kind, "project") or
        std.mem.eql(u8, kind, "milestone") or
        std.mem.eql(u8, kind, "label") or
        std.mem.eql(u8, kind, "comment") or
        std.mem.eql(u8, kind, "notification") or
        std.mem.eql(u8, kind, "acl") or
        std.mem.eql(u8, kind, "identity") or
        std.mem.eql(u8, kind, "action");
}

pub fn isKnownRole(role: []const u8) bool {
    return roleRank(role) != 0;
}

pub fn roleRank(role: []const u8) u8 {
    if (std.mem.eql(u8, role, "reader")) return 1;
    if (std.mem.eql(u8, role, "reporter")) return 2;
    if (std.mem.eql(u8, role, "contributor")) return 3;
    if (std.mem.eql(u8, role, "maintainer")) return 4;
    if (std.mem.eql(u8, role, "owner")) return 5;
    return 0;
}

pub fn roleAtLeast(actual: []const u8, required: []const u8) bool {
    return roleRank(actual) >= roleRank(required) and roleRank(required) != 0;
}

pub fn payloadRequirementError(event_type: []const u8, object_kind: []const u8, payload: std.json.ObjectMap, legacy: std.json.ObjectMap) ?[]const u8 {
    if (std.mem.startsWith(u8, event_type, "issue.") and !std.mem.eql(u8, object_kind, "issue")) {
        return "issue event object.kind must be issue";
    }
    if (std.mem.startsWith(u8, event_type, "pull.") and !std.mem.eql(u8, object_kind, "pull")) {
        return "pull event object.kind must be pull";
    }
    if (std.mem.startsWith(u8, event_type, "project.") and !std.mem.eql(u8, object_kind, "project")) {
        return "project event object.kind must be project";
    }
    if (std.mem.startsWith(u8, event_type, "milestone.") and !std.mem.eql(u8, object_kind, "milestone")) {
        return "milestone event object.kind must be milestone";
    }
    if (std.mem.startsWith(u8, event_type, "label.") and !std.mem.eql(u8, object_kind, "label")) {
        return "label event object.kind must be label";
    }
    if (std.mem.startsWith(u8, event_type, "comment.") and !std.mem.eql(u8, object_kind, "comment")) {
        return "comment event object.kind must be comment";
    }
    if (std.mem.startsWith(u8, event_type, "notification.") and !std.mem.eql(u8, object_kind, "notification")) {
        return "notification event object.kind must be notification";
    }
    if (std.mem.startsWith(u8, event_type, "acl.") and !std.mem.eql(u8, object_kind, "acl")) {
        return "acl event object.kind must be acl";
    }
    if (std.mem.startsWith(u8, event_type, "identity.") and !std.mem.eql(u8, object_kind, "identity")) {
        return "identity event object.kind must be identity";
    }
    if (std.mem.startsWith(u8, event_type, "action.") and !std.mem.eql(u8, object_kind, "action")) {
        return "action event object.kind must be action";
    }

    if (isReactionEvent(event_type)) {
        const emoji = jsonString(payload.get("emoji")) orelse return "reaction payload.emoji must be a string";
        if (!validReactionEmoji(emoji)) return "reaction payload.emoji must be a non-empty emoji string";
        if (emoji.len > git.max_payload_atom_bytes) return "reaction payload.emoji exceeds v1 field size limit";
        if (std.mem.endsWith(u8, event_type, ".reaction_removed")) {
            if (!optionalStringArray(payload, "add_hashes")) return "reaction payload.add_hashes must be an array of strings";
            if (!optionalStringArrayWithin(payload, "add_hashes", git.max_payload_collection_items, git.max_payload_ref_bytes)) return "reaction payload.add_hashes exceeds v1 collection limits";
        }
        return null;
    }

    if (std.mem.eql(u8, event_type, "issue.opened")) {
        if (!hasString(payload, "title")) return "issue.opened payload.title must be a string";
        if (!stringWithin(payload, "title", git.max_payload_title_bytes)) return "issue.opened payload.title exceeds v1 title size limit";
        if (!optionalString(payload, "body")) return "issue.opened payload.body must be a string";
        if (!optionalStringWithin(payload, "body", git.max_payload_text_bytes)) return "issue.opened payload.body exceeds v1 text size limit";
        if (!optionalStringArray(payload, "labels")) return "issue.opened payload.labels must be an array of strings";
        if (!optionalStringArrayWithin(payload, "labels", git.max_payload_collection_items, git.max_payload_atom_bytes)) return "issue.opened payload.labels exceeds v1 collection limits";
        if (!optionalStringArray(payload, "assignees")) return "issue.opened payload.assignees must be an array of strings";
        if (!optionalStringArrayWithin(payload, "assignees", git.max_payload_collection_items, git.max_payload_atom_bytes)) return "issue.opened payload.assignees exceeds v1 collection limits";
        if (!optionalStringWithin(payload, "source_author", git.max_payload_atom_bytes)) return "issue.opened payload.source_author exceeds v1 field size limit";
        if (!optionalStringWithin(payload, "source_identity", git.max_payload_ref_bytes)) return "issue.opened payload.source_identity exceeds v1 ref size limit";
        if (!optionalStringWithin(payload, "source_email", git.max_payload_atom_bytes)) return "issue.opened payload.source_email exceeds v1 field size limit";
        if (!optionalStringWithin(payload, "source_avatar_url", git.max_payload_ref_bytes)) return "issue.opened payload.source_avatar_url exceeds v1 ref size limit";
        if (!optionalStringWithin(payload, "milestone", git.max_payload_atom_bytes)) return "issue.opened payload.milestone exceeds v1 field size limit";
        if (!optionalIssueType(payload, "type")) return "issue.opened payload.type must be bug, feature, or task";
        if (!optionalIssuePriority(payload, "priority")) return "issue.opened payload.priority must be P0, P1, P2, or P3";
        if (!optionalIssueStatus(payload, "status")) return "issue.opened payload.status must be Draft, Todo, WIP, Review, Done, or Failed";
        if (!optionalIssueProjectsWithin(payload, "projects", git.max_payload_collection_items, git.max_payload_atom_bytes)) return "issue.opened payload.projects must be project objects within v1 collection limits";
        return null;
    }
    if (std.mem.eql(u8, event_type, "issue.updated")) {
        if (!optionalString(payload, "title")) return "issue.updated payload.title must be a string";
        if (!optionalStringWithin(payload, "title", git.max_payload_title_bytes)) return "issue.updated payload.title exceeds v1 title size limit";
        if (!optionalString(payload, "body")) return "issue.updated payload.body must be a string";
        if (!optionalStringWithin(payload, "body", git.max_payload_text_bytes)) return "issue.updated payload.body exceeds v1 text size limit";
        if (!optionalState(payload, "state", &.{ "open", "closed" })) return "issue.updated payload.state must be open or closed";
        if (!optionalString(payload, "milestone")) return "issue.updated payload.milestone must be a string";
        if (!optionalStringWithin(payload, "milestone", git.max_payload_atom_bytes)) return "issue.updated payload.milestone exceeds v1 field size limit";
        if (!optionalIssueType(payload, "type")) return "issue.updated payload.type must be bug, feature, or task";
        if (!optionalIssuePriority(payload, "priority")) return "issue.updated payload.priority must be P0, P1, P2, or P3";
        if (!optionalIssueStatus(payload, "status")) return "issue.updated payload.status must be Draft, Todo, WIP, Review, Done, or Failed";
        if (!optionalIssueProjectsWithin(payload, "projects", git.max_payload_collection_items, git.max_payload_atom_bytes)) return "issue.updated payload.projects must be project objects within v1 collection limits";
        if (!optionalStringArray(payload, "labels_added")) return "issue.updated payload.labels_added must be an array of strings";
        if (!optionalStringArrayWithin(payload, "labels_added", git.max_payload_collection_items, git.max_payload_atom_bytes)) return "issue.updated payload.labels_added exceeds v1 collection limits";
        if (!optionalStringArray(payload, "labels_removed")) return "issue.updated payload.labels_removed must be an array of strings";
        if (!optionalStringArrayWithin(payload, "labels_removed", git.max_payload_collection_items, git.max_payload_atom_bytes)) return "issue.updated payload.labels_removed exceeds v1 collection limits";
        if (!optionalStringArray(payload, "assignees_added")) return "issue.updated payload.assignees_added must be an array of strings";
        if (!optionalStringArrayWithin(payload, "assignees_added", git.max_payload_collection_items, git.max_payload_atom_bytes)) return "issue.updated payload.assignees_added exceeds v1 collection limits";
        if (!optionalStringArray(payload, "assignees_removed")) return "issue.updated payload.assignees_removed must be an array of strings";
        if (!optionalStringArrayWithin(payload, "assignees_removed", git.max_payload_collection_items, git.max_payload_atom_bytes)) return "issue.updated payload.assignees_removed exceeds v1 collection limits";
        if (!hasAnyKey(payload, &.{ "title", "body", "state", "milestone", "type", "priority", "status", "projects", "labels_added", "labels_removed", "assignees_added", "assignees_removed" }) and !hasIssueLegacyAlias(legacy)) return "issue.updated payload must contain at least one update field";
        return null;
    }
    if (std.mem.eql(u8, event_type, "issue.title_set")) return requirePayloadStringWithin(payload, "issue.title_set", "title", git.max_payload_title_bytes);
    if (std.mem.eql(u8, event_type, "issue.body_set")) return requirePayloadStringWithin(payload, "issue.body_set", "body", git.max_payload_text_bytes);
    if (std.mem.eql(u8, event_type, "issue.state_set")) {
        if (!hasState(payload, "state", &.{ "open", "closed" })) return "issue.state_set payload.state must be open or closed";
        return null;
    }
    if (std.mem.eql(u8, event_type, "issue.priority_set")) {
        if (!hasIssuePriority(payload, "priority")) return "issue.priority_set payload.priority must be P0, P1, P2, or P3";
        return null;
    }
    if (std.mem.eql(u8, event_type, "issue.type_set")) {
        if (!hasIssueType(payload, "type")) return "issue.type_set payload.type must be bug, feature, or task";
        return null;
    }
    if (std.mem.eql(u8, event_type, "issue.status_set")) {
        if (!hasIssueStatus(payload, "status")) return "issue.status_set payload.status must be Draft, Todo, WIP, Review, Done, or Failed";
        return null;
    }
    if (std.mem.eql(u8, event_type, "issue.label_added") or std.mem.eql(u8, event_type, "issue.label_removed")) return requirePayloadStringWithin(payload, event_type, "label", git.max_payload_atom_bytes);
    if (std.mem.eql(u8, event_type, "issue.assignee_added") or std.mem.eql(u8, event_type, "issue.assignee_removed")) return requirePayloadStringWithin(payload, event_type, "assignee", git.max_payload_atom_bytes);
    if (std.mem.eql(u8, event_type, "issue.milestone_set")) return requirePayloadStringWithin(payload, event_type, "milestone", git.max_payload_atom_bytes);
    if (std.mem.eql(u8, event_type, "issue.project_added") or std.mem.eql(u8, event_type, "issue.project_removed")) {
        if (!hasString(payload, "project")) return "issue project event payload.project must be a string";
        if (!stringWithin(payload, "project", git.max_payload_atom_bytes)) return "issue project event payload.project exceeds v1 field size limit";
        if (!hasString(payload, "column")) return "issue project event payload.column must be a string";
        if (!stringWithin(payload, "column", git.max_payload_atom_bytes)) return "issue project event payload.column exceeds v1 field size limit";
        if (!optionalStringWithin(payload, "project_ref", git.max_payload_ref_bytes)) return "issue project event payload.project_ref exceeds v1 ref size limit";
        if (!optionalStringWithin(payload, "column_ref", git.max_payload_atom_bytes)) return "issue project event payload.column_ref exceeds v1 field size limit";
        return null;
    }
    if (std.mem.eql(u8, event_type, "issue.relationship_added") or std.mem.eql(u8, event_type, "issue.relationship_removed")) {
        if (!hasIssueRelationshipKind(payload, "kind")) return "issue relationship event payload.kind must be parent or blocks";
        if (!hasNonEmptyStringWithin(payload, "target_id", git.max_payload_ref_bytes)) return "issue relationship event payload.target_id must be a non-empty string within v1 ref size limit";
        return null;
    }
    if (std.mem.eql(u8, event_type, "issue.concurrent_group_added") or std.mem.eql(u8, event_type, "issue.concurrent_group_removed")) {
        if (!hasNonEmptyStringWithin(payload, "group", git.max_payload_atom_bytes)) return "issue concurrent group event payload.group must be a non-empty string within v1 field size limit";
        return null;
    }
    if (std.mem.eql(u8, event_type, "issue.project_field_set")) {
        if (!hasString(payload, "project_id") and !hasString(payload, "project_ref")) return "issue.project_field_set payload.project_id or payload.project_ref must be a string";
        if (!optionalStringWithin(payload, "project_id", git.max_payload_ref_bytes)) return "issue.project_field_set payload.project_id exceeds v1 ref size limit";
        if (!optionalStringWithin(payload, "project_ref", git.max_payload_ref_bytes)) return "issue.project_field_set payload.project_ref exceeds v1 ref size limit";
        if (!hasString(payload, "field_id") and !hasString(payload, "field_key")) return "issue.project_field_set payload.field_id or payload.field_key must be a string";
        if (!optionalStringWithin(payload, "field_id", git.max_payload_ref_bytes)) return "issue.project_field_set payload.field_id exceeds v1 ref size limit";
        if (!optionalStringWithin(payload, "field_key", git.max_payload_atom_bytes)) return "issue.project_field_set payload.field_key exceeds v1 field size limit";
        if (payload.get("value") == null) return "issue.project_field_set payload.value is required";
        if (!jsonValueWithin(payload.get("value").?, git.max_payload_text_bytes)) return "issue.project_field_set payload.value exceeds v1 value size limit";
        return null;
    }
    if (std.mem.eql(u8, event_type, "issue.project_field_cleared")) {
        if (!hasString(payload, "project_id") and !hasString(payload, "project_ref")) return "issue.project_field_cleared payload.project_id or payload.project_ref must be a string";
        if (!optionalStringWithin(payload, "project_id", git.max_payload_ref_bytes)) return "issue.project_field_cleared payload.project_id exceeds v1 ref size limit";
        if (!optionalStringWithin(payload, "project_ref", git.max_payload_ref_bytes)) return "issue.project_field_cleared payload.project_ref exceeds v1 ref size limit";
        if (!hasString(payload, "field_id") and !hasString(payload, "field_key")) return "issue.project_field_cleared payload.field_id or payload.field_key must be a string";
        if (!optionalStringWithin(payload, "field_id", git.max_payload_ref_bytes)) return "issue.project_field_cleared payload.field_id exceeds v1 ref size limit";
        if (!optionalStringWithin(payload, "field_key", git.max_payload_atom_bytes)) return "issue.project_field_cleared payload.field_key exceeds v1 field size limit";
        return null;
    }

    if (std.mem.eql(u8, event_type, "project.created")) {
        if (!hasString(payload, "name")) return "project.created payload.name must be a string";
        if (!stringWithin(payload, "name", git.max_payload_atom_bytes)) return "project.created payload.name exceeds v1 field size limit";
        if (!optionalStringWithin(payload, "description", git.max_payload_text_bytes)) return "project.created payload.description exceeds v1 text size limit";
        if (!optionalStringWithin(payload, "slug", git.max_payload_atom_bytes)) return "project.created payload.slug exceeds v1 field size limit";
        if (!optionalStringArray(payload, "columns")) return "project.created payload.columns must be an array of strings";
        if (!optionalStringArrayWithin(payload, "columns", git.max_payload_collection_items, git.max_payload_atom_bytes)) return "project.created payload.columns exceeds v1 collection limits";
        return null;
    }
    if (std.mem.eql(u8, event_type, "project.updated")) {
        if (!optionalString(payload, "name")) return "project.updated payload.name must be a string";
        if (!optionalStringWithin(payload, "name", git.max_payload_atom_bytes)) return "project.updated payload.name exceeds v1 field size limit";
        if (!optionalString(payload, "description")) return "project.updated payload.description must be a string";
        if (!optionalStringWithin(payload, "description", git.max_payload_text_bytes)) return "project.updated payload.description exceeds v1 text size limit";
        if (!optionalState(payload, "state", &.{ "open", "closed" })) return "project.updated payload.state must be open or closed";
        if (!optionalProjectStatus(payload, "status")) return "project.updated payload.status must be Backlog, Planned, In Progress, Completed, or Canceled";
        if (!optionalIssuePriority(payload, "priority")) return "project.updated payload.priority must be P0, P1, P2, or P3";
        if (!optionalDateString(payload, "start_at")) return "project.updated payload.start_at must be YYYY-MM-DD";
        if (!optionalDateString(payload, "end_at")) return "project.updated payload.end_at must be YYYY-MM-DD";
        if (!optionalStringArray(payload, "leads_added")) return "project.updated payload.leads_added must be an array of strings";
        if (!optionalStringArrayWithin(payload, "leads_added", git.max_payload_collection_items, git.max_payload_atom_bytes)) return "project.updated payload.leads_added exceeds v1 collection limits";
        if (!optionalStringArray(payload, "leads_removed")) return "project.updated payload.leads_removed must be an array of strings";
        if (!optionalStringArrayWithin(payload, "leads_removed", git.max_payload_collection_items, git.max_payload_atom_bytes)) return "project.updated payload.leads_removed exceeds v1 collection limits";
        if (!optionalStringArray(payload, "members_added")) return "project.updated payload.members_added must be an array of strings";
        if (!optionalStringArrayWithin(payload, "members_added", git.max_payload_collection_items, git.max_payload_atom_bytes)) return "project.updated payload.members_added exceeds v1 collection limits";
        if (!optionalStringArray(payload, "members_removed")) return "project.updated payload.members_removed must be an array of strings";
        if (!optionalStringArrayWithin(payload, "members_removed", git.max_payload_collection_items, git.max_payload_atom_bytes)) return "project.updated payload.members_removed exceeds v1 collection limits";
        if (!optionalStringArray(payload, "labels_added")) return "project.updated payload.labels_added must be an array of strings";
        if (!optionalStringArrayWithin(payload, "labels_added", git.max_payload_collection_items, git.max_payload_atom_bytes)) return "project.updated payload.labels_added exceeds v1 collection limits";
        if (!optionalStringArray(payload, "labels_removed")) return "project.updated payload.labels_removed must be an array of strings";
        if (!optionalStringArrayWithin(payload, "labels_removed", git.max_payload_collection_items, git.max_payload_atom_bytes)) return "project.updated payload.labels_removed exceeds v1 collection limits";
        if (!optionalStringArray(payload, "milestones_added")) return "project.updated payload.milestones_added must be an array of strings";
        if (!optionalStringArrayWithin(payload, "milestones_added", git.max_payload_collection_items, git.max_payload_ref_bytes)) return "project.updated payload.milestones_added exceeds v1 collection limits";
        if (!optionalStringArray(payload, "milestones_removed")) return "project.updated payload.milestones_removed must be an array of strings";
        if (!optionalStringArrayWithin(payload, "milestones_removed", git.max_payload_collection_items, git.max_payload_ref_bytes)) return "project.updated payload.milestones_removed exceeds v1 collection limits";
        if (!optionalProjectUpdateHealth(payload, "update_health")) return "project.updated payload.update_health must be on_track, at_risk, or off_track";
        if (!optionalString(payload, "update_body")) return "project.updated payload.update_body must be a string";
        if (!optionalStringWithin(payload, "update_body", git.max_payload_text_bytes)) return "project.updated payload.update_body exceeds v1 text size limit";
        if (!hasAnyKey(payload, &.{ "name", "description", "state", "status", "priority", "start_at", "end_at", "leads_added", "leads_removed", "members_added", "members_removed", "labels_added", "labels_removed", "milestones_added", "milestones_removed", "update_health", "update_body" })) return "project.updated payload must contain at least one update field";
        return null;
    }
    if (std.mem.eql(u8, event_type, "project.column_added") or std.mem.eql(u8, event_type, "project.column_removed")) {
        if (!hasString(payload, "column")) return "project column event payload.column must be a string";
        if (!stringWithin(payload, "column", git.max_payload_atom_bytes)) return "project column event payload.column exceeds v1 field size limit";
        if (!optionalStringWithin(payload, "column_ref", git.max_payload_atom_bytes)) return "project column event payload.column_ref exceeds v1 field size limit";
        return null;
    }
    if (std.mem.eql(u8, event_type, "project.field_created")) {
        if (!hasUuidString(payload, "field_id")) return "project.field_created payload.field_id must be a UUID string";
        if (!hasString(payload, "key")) return "project.field_created payload.key must be a string";
        if (!stringWithin(payload, "key", git.max_payload_atom_bytes)) return "project.field_created payload.key exceeds v1 field size limit";
        if (!hasString(payload, "name")) return "project.field_created payload.name must be a string";
        if (!stringWithin(payload, "name", git.max_payload_atom_bytes)) return "project.field_created payload.name exceeds v1 field size limit";
        const field_type = jsonString(payload.get("type")) orelse return "project.field_created payload.type must be a string";
        if (!validProjectFieldType(field_type)) return "project.field_created payload.type is not recognized";
        if (!optionalNonNegativeInteger(payload, "position")) return "project.field_created payload.position must be a non-negative integer";
        if (!optionalBool(payload, "required")) return "project.field_created payload.required must be a boolean";
        if (payload.get("default_value")) |value| if (!jsonValueWithin(value, git.max_payload_text_bytes)) return "project.field_created payload.default_value exceeds v1 value size limit";
        if (!optionalState(payload, "state", &.{ "active", "removed" })) return "project.field_created payload.state must be active or removed";
        return null;
    }
    if (std.mem.eql(u8, event_type, "project.field_updated")) {
        if (!hasUuidString(payload, "field_id")) return "project.field_updated payload.field_id must be a UUID string";
        if (!optionalStringWithin(payload, "key", git.max_payload_atom_bytes)) return "project.field_updated payload.key exceeds v1 field size limit";
        if (!optionalStringWithin(payload, "name", git.max_payload_atom_bytes)) return "project.field_updated payload.name exceeds v1 field size limit";
        if (payload.get("type")) |value| {
            const field_type = jsonString(value) orelse return "project.field_updated payload.type must be a string";
            if (!validProjectFieldType(field_type)) return "project.field_updated payload.type is not recognized";
        }
        if (!optionalNonNegativeInteger(payload, "position")) return "project.field_updated payload.position must be a non-negative integer";
        if (!optionalBool(payload, "required")) return "project.field_updated payload.required must be a boolean";
        if (payload.get("default_value")) |value| if (!jsonValueWithin(value, git.max_payload_text_bytes)) return "project.field_updated payload.default_value exceeds v1 value size limit";
        if (!optionalState(payload, "state", &.{ "active", "removed" })) return "project.field_updated payload.state must be active or removed";
        if (!hasAnyKey(payload, &.{ "key", "name", "type", "position", "required", "default_value", "state" })) return "project.field_updated payload must contain at least one update field";
        return null;
    }
    if (std.mem.eql(u8, event_type, "project.field_removed")) {
        if (!hasUuidString(payload, "field_id")) return "project.field_removed payload.field_id must be a UUID string";
        return null;
    }
    if (std.mem.eql(u8, event_type, "project.field_option_added")) {
        if (!hasUuidString(payload, "field_id")) return "project.field_option_added payload.field_id must be a UUID string";
        if (!hasUuidString(payload, "option_id")) return "project.field_option_added payload.option_id must be a UUID string";
        if (!hasString(payload, "name")) return "project.field_option_added payload.name must be a string";
        if (!stringWithin(payload, "name", git.max_payload_atom_bytes)) return "project.field_option_added payload.name exceeds v1 field size limit";
        if (!optionalStringWithin(payload, "color", git.max_payload_atom_bytes)) return "project.field_option_added payload.color exceeds v1 field size limit";
        if (!optionalNonNegativeInteger(payload, "position")) return "project.field_option_added payload.position must be a non-negative integer";
        if (!optionalState(payload, "state", &.{ "active", "removed" })) return "project.field_option_added payload.state must be active or removed";
        return null;
    }
    if (std.mem.eql(u8, event_type, "project.field_option_updated")) {
        if (!hasUuidString(payload, "field_id")) return "project.field_option_updated payload.field_id must be a UUID string";
        if (!hasUuidString(payload, "option_id")) return "project.field_option_updated payload.option_id must be a UUID string";
        if (!optionalStringWithin(payload, "name", git.max_payload_atom_bytes)) return "project.field_option_updated payload.name exceeds v1 field size limit";
        if (!optionalStringWithin(payload, "color", git.max_payload_atom_bytes)) return "project.field_option_updated payload.color exceeds v1 field size limit";
        if (!optionalNonNegativeInteger(payload, "position")) return "project.field_option_updated payload.position must be a non-negative integer";
        if (!optionalState(payload, "state", &.{ "active", "removed" })) return "project.field_option_updated payload.state must be active or removed";
        if (!hasAnyKey(payload, &.{ "name", "color", "position", "state" })) return "project.field_option_updated payload must contain at least one update field";
        return null;
    }
    if (std.mem.eql(u8, event_type, "project.field_option_removed")) {
        if (!hasUuidString(payload, "field_id")) return "project.field_option_removed payload.field_id must be a UUID string";
        if (!hasUuidString(payload, "option_id")) return "project.field_option_removed payload.option_id must be a UUID string";
        return null;
    }
    if (std.mem.eql(u8, event_type, "project.view_created")) {
        if (!hasUuidString(payload, "view_id")) return "project.view_created payload.view_id must be a UUID string";
        if (!hasString(payload, "name")) return "project.view_created payload.name must be a string";
        if (!stringWithin(payload, "name", git.max_payload_atom_bytes)) return "project.view_created payload.name exceeds v1 field size limit";
        const layout = jsonString(payload.get("layout")) orelse return "project.view_created payload.layout must be a string";
        if (!validProjectViewLayout(layout)) return "project.view_created payload.layout is not recognized";
        if (!optionalNonNegativeInteger(payload, "position")) return "project.view_created payload.position must be a non-negative integer";
        if (payload.get("config")) |value| if (!jsonValueWithin(value, git.max_payload_text_bytes)) return "project.view_created payload.config exceeds v1 value size limit";
        if (!optionalState(payload, "state", &.{ "active", "removed" })) return "project.view_created payload.state must be active or removed";
        return null;
    }
    if (std.mem.eql(u8, event_type, "project.view_updated")) {
        if (!hasUuidString(payload, "view_id")) return "project.view_updated payload.view_id must be a UUID string";
        if (!optionalStringWithin(payload, "name", git.max_payload_atom_bytes)) return "project.view_updated payload.name exceeds v1 field size limit";
        if (payload.get("layout")) |value| {
            const layout = jsonString(value) orelse return "project.view_updated payload.layout must be a string";
            if (!validProjectViewLayout(layout)) return "project.view_updated payload.layout is not recognized";
        }
        if (!optionalNonNegativeInteger(payload, "position")) return "project.view_updated payload.position must be a non-negative integer";
        if (payload.get("config")) |value| if (!jsonValueWithin(value, git.max_payload_text_bytes)) return "project.view_updated payload.config exceeds v1 value size limit";
        if (!optionalState(payload, "state", &.{ "active", "removed" })) return "project.view_updated payload.state must be active or removed";
        if (!hasAnyKey(payload, &.{ "name", "layout", "position", "config", "state" })) return "project.view_updated payload must contain at least one update field";
        return null;
    }
    if (std.mem.eql(u8, event_type, "project.view_removed")) {
        if (!hasUuidString(payload, "view_id")) return "project.view_removed payload.view_id must be a UUID string";
        return null;
    }

    if (std.mem.eql(u8, event_type, "milestone.created")) {
        if (!hasString(payload, "title")) return "milestone.created payload.title must be a string";
        if (!stringWithin(payload, "title", git.max_payload_atom_bytes)) return "milestone.created payload.title exceeds v1 field size limit";
        if (!optionalString(payload, "description")) return "milestone.created payload.description must be a string";
        if (!optionalStringWithin(payload, "description", git.max_payload_text_bytes)) return "milestone.created payload.description exceeds v1 text size limit";
        if (!optionalStringWithin(payload, "slug", git.max_payload_atom_bytes)) return "milestone.created payload.slug exceeds v1 field size limit";
        if (!optionalStringWithin(payload, "due_at", git.max_payload_atom_bytes)) return "milestone.created payload.due_at exceeds v1 field size limit";
        if (!optionalState(payload, "state", &.{ "open", "closed" })) return "milestone.created payload.state must be open or closed";
        return null;
    }
    if (std.mem.eql(u8, event_type, "milestone.updated")) {
        if (!optionalString(payload, "title")) return "milestone.updated payload.title must be a string";
        if (!optionalStringWithin(payload, "title", git.max_payload_atom_bytes)) return "milestone.updated payload.title exceeds v1 field size limit";
        if (!optionalString(payload, "description")) return "milestone.updated payload.description must be a string";
        if (!optionalStringWithin(payload, "description", git.max_payload_text_bytes)) return "milestone.updated payload.description exceeds v1 text size limit";
        if (!optionalStringWithin(payload, "due_at", git.max_payload_atom_bytes)) return "milestone.updated payload.due_at exceeds v1 field size limit";
        if (!optionalState(payload, "state", &.{ "open", "closed" })) return "milestone.updated payload.state must be open or closed";
        if (!hasAnyKey(payload, &.{ "title", "description", "due_at", "state" })) return "milestone.updated payload must contain at least one update field";
        return null;
    }
    if (std.mem.eql(u8, event_type, "milestone.state_set")) {
        if (!hasState(payload, "state", &.{ "open", "closed" })) return "milestone.state_set payload.state must be open or closed";
        return null;
    }
    if (std.mem.eql(u8, event_type, "milestone.deleted")) return null;

    if (std.mem.eql(u8, event_type, "label.created")) {
        if (!hasString(payload, "name")) return "label.created payload.name must be a string";
        if (!stringWithin(payload, "name", git.max_payload_atom_bytes)) return "label.created payload.name exceeds v1 field size limit";
        if (!optionalString(payload, "description")) return "label.created payload.description must be a string";
        if (!optionalStringWithin(payload, "description", git.max_payload_text_bytes)) return "label.created payload.description exceeds v1 text size limit";
        if (!optionalLabelColor(payload, "color")) return "label.created payload.color must be a hex color";
        if (!optionalNonNegativeInteger(payload, "priority")) return "label.created payload.priority must be a non-negative integer";
        if (!optionalNonNegativeInteger(payload, "position")) return "label.created payload.position must be a non-negative integer";
        return null;
    }
    if (std.mem.eql(u8, event_type, "label.updated")) {
        if (!optionalString(payload, "name")) return "label.updated payload.name must be a string";
        if (!optionalStringWithin(payload, "name", git.max_payload_atom_bytes)) return "label.updated payload.name exceeds v1 field size limit";
        if (!optionalString(payload, "description")) return "label.updated payload.description must be a string";
        if (!optionalStringWithin(payload, "description", git.max_payload_text_bytes)) return "label.updated payload.description exceeds v1 text size limit";
        if (!optionalLabelColor(payload, "color")) return "label.updated payload.color must be a hex color";
        if (!optionalNonNegativeInteger(payload, "priority")) return "label.updated payload.priority must be a non-negative integer";
        if (!optionalNonNegativeInteger(payload, "position")) return "label.updated payload.position must be a non-negative integer";
        if (!hasAnyKey(payload, &.{ "name", "description", "color", "priority", "position" })) return "label.updated payload must contain at least one update field";
        return null;
    }
    if (std.mem.eql(u8, event_type, "label.deleted")) return null;

    if (std.mem.eql(u8, event_type, "pull.opened")) {
        if (!hasString(payload, "title")) return "pull.opened payload.title must be a string";
        if (!stringWithin(payload, "title", git.max_payload_title_bytes)) return "pull.opened payload.title exceeds v1 title size limit";
        if (!hasString(payload, "base_ref")) return "pull.opened payload.base_ref must be a string";
        if (!stringWithin(payload, "base_ref", git.max_payload_ref_bytes)) return "pull.opened payload.base_ref exceeds v1 ref size limit";
        if (!hasString(payload, "head_ref")) return "pull.opened payload.head_ref must be a string";
        if (!stringWithin(payload, "head_ref", git.max_payload_ref_bytes)) return "pull.opened payload.head_ref exceeds v1 ref size limit";
        if (!optionalString(payload, "body")) return "pull.opened payload.body must be a string";
        if (!optionalStringWithin(payload, "body", git.max_payload_text_bytes)) return "pull.opened payload.body exceeds v1 text size limit";
        if (!optionalBool(payload, "draft")) return "pull.opened payload.draft must be a boolean";
        if (!optionalStringWithin(payload, "source_author", git.max_payload_atom_bytes)) return "pull.opened payload.source_author exceeds v1 field size limit";
        if (!optionalStringWithin(payload, "source_identity", git.max_payload_ref_bytes)) return "pull.opened payload.source_identity exceeds v1 ref size limit";
        if (!optionalStringWithin(payload, "source_email", git.max_payload_atom_bytes)) return "pull.opened payload.source_email exceeds v1 field size limit";
        if (!optionalStringWithin(payload, "source_avatar_url", git.max_payload_ref_bytes)) return "pull.opened payload.source_avatar_url exceeds v1 ref size limit";
        if (!optionalStringArray(payload, "labels")) return "pull.opened payload.labels must be an array of strings";
        if (!optionalStringArrayWithin(payload, "labels", git.max_payload_collection_items, git.max_payload_atom_bytes)) return "pull.opened payload.labels exceeds v1 collection limits";
        if (!optionalStringArray(payload, "assignees")) return "pull.opened payload.assignees must be an array of strings";
        if (!optionalStringArrayWithin(payload, "assignees", git.max_payload_collection_items, git.max_payload_atom_bytes)) return "pull.opened payload.assignees exceeds v1 collection limits";
        if (!optionalStringArray(payload, "reviewers")) return "pull.opened payload.reviewers must be an array of strings";
        if (!optionalStringArrayWithin(payload, "reviewers", git.max_payload_collection_items, git.max_payload_atom_bytes)) return "pull.opened payload.reviewers exceeds v1 collection limits";
        if (!optionalNonNegativeInteger(payload, "commits")) return "pull.opened payload.commits must be a non-negative integer";
        if (!optionalNonNegativeInteger(payload, "changed_files")) return "pull.opened payload.changed_files must be a non-negative integer";
        if (!optionalNonNegativeInteger(payload, "additions")) return "pull.opened payload.additions must be a non-negative integer";
        if (!optionalNonNegativeInteger(payload, "deletions")) return "pull.opened payload.deletions must be a non-negative integer";
        return null;
    }
    if (std.mem.eql(u8, event_type, "pull.updated")) {
        if (!optionalString(payload, "title")) return "pull.updated payload.title must be a string";
        if (!optionalStringWithin(payload, "title", git.max_payload_title_bytes)) return "pull.updated payload.title exceeds v1 title size limit";
        if (!optionalString(payload, "body")) return "pull.updated payload.body must be a string";
        if (!optionalStringWithin(payload, "body", git.max_payload_text_bytes)) return "pull.updated payload.body exceeds v1 text size limit";
        if (!optionalState(payload, "state", &.{ "open", "closed" })) return "pull.updated payload.state must be open or closed";
        if (!optionalString(payload, "base_ref")) return "pull.updated payload.base_ref must be a string";
        if (!optionalStringWithin(payload, "base_ref", git.max_payload_ref_bytes)) return "pull.updated payload.base_ref exceeds v1 ref size limit";
        if (!optionalString(payload, "head_ref")) return "pull.updated payload.head_ref must be a string";
        if (!optionalStringWithin(payload, "head_ref", git.max_payload_ref_bytes)) return "pull.updated payload.head_ref exceeds v1 ref size limit";
        if (!optionalStringArray(payload, "labels_added")) return "pull.updated payload.labels_added must be an array of strings";
        if (!optionalStringArrayWithin(payload, "labels_added", git.max_payload_collection_items, git.max_payload_atom_bytes)) return "pull.updated payload.labels_added exceeds v1 collection limits";
        if (!optionalStringArray(payload, "labels_removed")) return "pull.updated payload.labels_removed must be an array of strings";
        if (!optionalStringArrayWithin(payload, "labels_removed", git.max_payload_collection_items, git.max_payload_atom_bytes)) return "pull.updated payload.labels_removed exceeds v1 collection limits";
        if (!optionalStringArray(payload, "assignees_added")) return "pull.updated payload.assignees_added must be an array of strings";
        if (!optionalStringArrayWithin(payload, "assignees_added", git.max_payload_collection_items, git.max_payload_atom_bytes)) return "pull.updated payload.assignees_added exceeds v1 collection limits";
        if (!optionalStringArray(payload, "assignees_removed")) return "pull.updated payload.assignees_removed must be an array of strings";
        if (!optionalStringArrayWithin(payload, "assignees_removed", git.max_payload_collection_items, git.max_payload_atom_bytes)) return "pull.updated payload.assignees_removed exceeds v1 collection limits";
        if (!optionalStringArray(payload, "reviewers_added")) return "pull.updated payload.reviewers_added must be an array of strings";
        if (!optionalStringArrayWithin(payload, "reviewers_added", git.max_payload_collection_items, git.max_payload_atom_bytes)) return "pull.updated payload.reviewers_added exceeds v1 collection limits";
        if (!optionalStringArray(payload, "reviewers_removed")) return "pull.updated payload.reviewers_removed must be an array of strings";
        if (!optionalStringArrayWithin(payload, "reviewers_removed", git.max_payload_collection_items, git.max_payload_atom_bytes)) return "pull.updated payload.reviewers_removed exceeds v1 collection limits";
        if (!hasAnyKey(payload, &.{ "title", "body", "state", "base_ref", "head_ref", "labels_added", "labels_removed", "assignees_added", "assignees_removed", "reviewers_added", "reviewers_removed" }) and !hasPullLegacyAlias(legacy)) return "pull.updated payload must contain at least one update field";
        return null;
    }
    if (std.mem.eql(u8, event_type, "pull.title_set")) return requirePayloadStringWithin(payload, "pull.title_set", "title", git.max_payload_title_bytes);
    if (std.mem.eql(u8, event_type, "pull.body_set")) return requirePayloadStringWithin(payload, "pull.body_set", "body", git.max_payload_text_bytes);
    if (std.mem.eql(u8, event_type, "pull.state_set")) {
        if (!hasState(payload, "state", &.{ "open", "closed" })) return "pull.state_set payload.state must be open or closed";
        return null;
    }
    if (std.mem.eql(u8, event_type, "pull.base_set")) return requirePayloadStringWithin(payload, "pull.base_set", "base_ref", git.max_payload_ref_bytes);
    if (std.mem.eql(u8, event_type, "pull.head_set")) return requirePayloadStringWithin(payload, "pull.head_set", "head_ref", git.max_payload_ref_bytes);
    if (std.mem.eql(u8, event_type, "pull.label_added") or std.mem.eql(u8, event_type, "pull.label_removed")) return requirePayloadStringWithin(payload, event_type, "label", git.max_payload_atom_bytes);
    if (std.mem.eql(u8, event_type, "pull.assignee_added") or std.mem.eql(u8, event_type, "pull.assignee_removed")) return requirePayloadStringWithin(payload, event_type, "assignee", git.max_payload_atom_bytes);
    if (std.mem.eql(u8, event_type, "pull.reviewer_added") or std.mem.eql(u8, event_type, "pull.reviewer_removed")) return requirePayloadStringWithin(payload, event_type, "reviewer", git.max_payload_atom_bytes);
    if (std.mem.eql(u8, event_type, "pull.merged")) {
        if (!hasString(payload, "merge_oid") and !hasString(payload, "target_oid")) return "pull.merged payload.merge_oid or payload.target_oid must be a string";
        if (!optionalStringWithin(payload, "merge_oid", git.max_payload_ref_bytes)) return "pull.merged payload.merge_oid exceeds v1 ref size limit";
        if (!optionalStringWithin(payload, "target_oid", git.max_payload_ref_bytes)) return "pull.merged payload.target_oid exceeds v1 ref size limit";
        if (!optionalStringWithin(payload, "base_oid", git.max_payload_ref_bytes)) return "pull.merged payload.base_oid exceeds v1 ref size limit";
        if (!optionalStringWithin(payload, "head_oid", git.max_payload_ref_bytes)) return "pull.merged payload.head_oid exceeds v1 ref size limit";
        if (!optionalStringWithin(payload, "remote", git.max_payload_atom_bytes)) return "pull.merged payload.remote exceeds v1 field size limit";
        if (!optionalStringWithin(payload, "remote_ref", git.max_payload_ref_bytes)) return "pull.merged payload.remote_ref exceeds v1 ref size limit";
        return null;
    }

    if (std.mem.eql(u8, event_type, "comment.added")) {
        if (!hasString(payload, "parent_kind")) return "comment.added payload.parent_kind must be a string";
        if (!stringWithin(payload, "parent_kind", git.max_payload_atom_bytes)) return "comment.added payload.parent_kind exceeds v1 field size limit";
        if (!hasString(payload, "parent_id")) return "comment.added payload.parent_id must be a string";
        if (!stringWithin(payload, "parent_id", git.max_payload_ref_bytes)) return "comment.added payload.parent_id exceeds v1 field size limit";
        if (!optionalStringWithin(payload, "source_author", git.max_payload_atom_bytes)) return "comment.added payload.source_author exceeds v1 field size limit";
        if (!optionalStringWithin(payload, "source_identity", git.max_payload_ref_bytes)) return "comment.added payload.source_identity exceeds v1 ref size limit";
        if (!optionalStringWithin(payload, "source_email", git.max_payload_atom_bytes)) return "comment.added payload.source_email exceeds v1 field size limit";
        if (!optionalStringWithin(payload, "source_avatar_url", git.max_payload_ref_bytes)) return "comment.added payload.source_avatar_url exceeds v1 ref size limit";
        if (!optionalStringWithin(payload, "reply_parent_id", git.max_payload_ref_bytes)) return "comment.added payload.reply_parent_id exceeds v1 field size limit";
        if (!optionalStringWithin(payload, "reply_parent_hash", git.max_payload_ref_bytes)) return "comment.added payload.reply_parent_hash exceeds v1 field size limit";
        if (!hasString(payload, "body")) return "comment.added payload.body must be a string";
        if (!stringWithin(payload, "body", git.max_payload_text_bytes)) return "comment.added payload.body exceeds v1 text size limit";
        return null;
    }
    if (std.mem.eql(u8, event_type, "comment.body_set")) return requirePayloadStringWithin(payload, "comment.body_set", "body", git.max_payload_text_bytes);
    if (std.mem.eql(u8, event_type, "comment.redacted")) {
        if (!optionalString(payload, "reason")) return "comment.redacted payload.reason must be a string";
        if (!optionalStringWithin(payload, "reason", git.max_payload_text_bytes)) return "comment.redacted payload.reason exceeds v1 text size limit";
        return null;
    }

    if (std.mem.eql(u8, event_type, "notification.subscribed") or std.mem.eql(u8, event_type, "notification.unsubscribed")) {
        if (!hasString(payload, "principal")) return "notification subscription payload.principal must be a string";
        if (!stringWithin(payload, "principal", git.max_payload_atom_bytes)) return "notification subscription payload.principal exceeds v1 field size limit";
        const target_kind = jsonString(payload.get("target_kind")) orelse return "notification subscription payload.target_kind must be a string";
        if (!std.mem.eql(u8, target_kind, "issue") and !std.mem.eql(u8, target_kind, "pull")) return "notification subscription payload.target_kind must be issue or pull";
        if (!hasUuidString(payload, "target_id")) return "notification subscription payload.target_id must be a UUID string";
        if (!optionalStringWithin(payload, "reason", git.max_payload_atom_bytes)) return "notification subscription payload.reason exceeds v1 field size limit";
        return null;
    }
    if (std.mem.eql(u8, event_type, "notification.read")) {
        if (!hasString(payload, "principal")) return "notification.read payload.principal must be a string";
        if (!stringWithin(payload, "principal", git.max_payload_atom_bytes)) return "notification.read payload.principal exceeds v1 field size limit";
        if (!hasNonEmptyStringWithin(payload, "event_hash", git.max_payload_ref_bytes)) return "notification.read payload.event_hash must be a non-empty string within v1 ref size limit";
        return null;
    }
    if (std.mem.eql(u8, event_type, "notification.read_all")) {
        if (!hasString(payload, "principal")) return "notification.read_all payload.principal must be a string";
        if (!stringWithin(payload, "principal", git.max_payload_atom_bytes)) return "notification.read_all payload.principal exceeds v1 field size limit";
        return null;
    }

    if (std.mem.eql(u8, event_type, "acl.role_granted") or std.mem.eql(u8, event_type, "acl.role_revoked")) {
        if (!hasString(payload, "principal")) return "acl role event payload.principal must be a string";
        if (!stringWithin(payload, "principal", git.max_payload_atom_bytes)) return "acl role event payload.principal exceeds v1 field size limit";
        if (!hasString(payload, "role")) return "acl role event payload.role must be a string";
        if (!stringWithin(payload, "role", git.max_payload_atom_bytes)) return "acl role event payload.role exceeds v1 field size limit";
        return null;
    }

    if (std.mem.eql(u8, event_type, "acl.delegation_granted") or std.mem.eql(u8, event_type, "acl.delegation_revoked")) {
        if (!hasString(payload, "principal")) return "acl delegation event payload.principal must be a string";
        if (!stringWithin(payload, "principal", git.max_payload_atom_bytes)) return "acl delegation event payload.principal exceeds v1 field size limit";
        if (!hasString(payload, "device")) return "acl delegation event payload.device must be a string";
        if (!stringWithin(payload, "device", git.max_payload_atom_bytes)) return "acl delegation event payload.device exceeds v1 field size limit";
        if (!hasString(payload, "capability")) return "acl delegation event payload.capability must be a string";
        if (!stringWithin(payload, "capability", git.max_payload_atom_bytes)) return "acl delegation event payload.capability exceeds v1 field size limit";
        if (!hasString(payload, "scope")) return "acl delegation event payload.scope must be a string";
        if (!stringWithin(payload, "scope", git.max_payload_ref_bytes)) return "acl delegation event payload.scope exceeds v1 field size limit";
        if (std.mem.eql(u8, event_type, "acl.delegation_granted")) {
            const signing_key = objectValue(payload, "signing_key") orelse return "acl.delegation_granted payload.signing_key must be an object";
            if (!hasString(signing_key, "public_key")) return "acl.delegation_granted payload.signing_key.public_key must be a string";
            if (!stringWithin(signing_key, "public_key", git.max_payload_key_bytes)) return "acl.delegation_granted payload.signing_key.public_key exceeds v1 key size limit";
            if (!hasString(signing_key, "fingerprint")) return "acl.delegation_granted payload.signing_key.fingerprint must be a string";
            if (!stringWithin(signing_key, "fingerprint", git.max_payload_atom_bytes)) return "acl.delegation_granted payload.signing_key.fingerprint exceeds v1 field size limit";
            if (!optionalString(signing_key, "scheme")) return "acl.delegation_granted payload.signing_key.scheme must be a string";
            if (!optionalStringWithin(signing_key, "scheme", git.max_payload_atom_bytes)) return "acl.delegation_granted payload.signing_key.scheme exceeds v1 field size limit";
        }
        return null;
    }

    if (std.mem.eql(u8, event_type, "identity.device_added")) {
        if (!hasString(payload, "principal")) return "identity device event payload.principal must be a string";
        if (!stringWithin(payload, "principal", git.max_payload_atom_bytes)) return "identity device event payload.principal exceeds v1 field size limit";
        if (!hasString(payload, "device")) return "identity device event payload.device must be a string";
        if (!stringWithin(payload, "device", git.max_payload_atom_bytes)) return "identity device event payload.device exceeds v1 field size limit";
        const signing_key = objectValue(payload, "signing_key") orelse return "identity.device_added payload.signing_key must be an object";
        if (!hasString(signing_key, "public_key")) return "identity.device_added payload.signing_key.public_key must be a string";
        if (!stringWithin(signing_key, "public_key", git.max_payload_key_bytes)) return "identity.device_added payload.signing_key.public_key exceeds v1 key size limit";
        if (!hasString(signing_key, "fingerprint")) return "identity.device_added payload.signing_key.fingerprint must be a string";
        if (!stringWithin(signing_key, "fingerprint", git.max_payload_atom_bytes)) return "identity.device_added payload.signing_key.fingerprint exceeds v1 field size limit";
        if (!optionalString(signing_key, "scheme")) return "identity.device_added payload.signing_key.scheme must be a string";
        if (!optionalStringWithin(signing_key, "scheme", git.max_payload_atom_bytes)) return "identity.device_added payload.signing_key.scheme exceeds v1 field size limit";
        return null;
    }

    if (std.mem.eql(u8, event_type, "identity.device_revoked")) {
        if (!hasString(payload, "principal")) return "identity device event payload.principal must be a string";
        if (!stringWithin(payload, "principal", git.max_payload_atom_bytes)) return "identity device event payload.principal exceeds v1 field size limit";
        if (!hasString(payload, "device")) return "identity device event payload.device must be a string";
        if (!stringWithin(payload, "device", git.max_payload_atom_bytes)) return "identity device event payload.device exceeds v1 field size limit";
        return null;
    }

    if (std.mem.eql(u8, event_type, "action.run_requested")) {
        if (!hasString(payload, "workflow")) return "action.run_requested payload.workflow must be a string";
        if (!stringWithin(payload, "workflow", git.max_payload_atom_bytes)) return "action.run_requested payload.workflow exceeds v1 field size limit";
        if (!hasString(payload, "target_ref") and !hasString(payload, "target_oid")) return "action.run_requested payload.target_ref or payload.target_oid must be a string";
        if (!optionalStringWithin(payload, "target_ref", git.max_payload_ref_bytes)) return "action.run_requested payload.target_ref exceeds v1 ref size limit";
        if (!optionalStringWithin(payload, "target_oid", git.max_payload_ref_bytes)) return "action.run_requested payload.target_oid exceeds v1 ref size limit";
        if (!optionalStringWithin(payload, "event_name", git.max_payload_atom_bytes)) return "action.run_requested payload.event_name exceeds v1 field size limit";
        if (!optionalStringWithin(payload, "gitomi_event_type", git.max_payload_atom_bytes)) return "action.run_requested payload.gitomi_event_type exceeds v1 field size limit";
        return null;
    }
    if (std.mem.eql(u8, event_type, "action.run_completed")) {
        if (!hasString(payload, "run_id")) return "action.run_completed payload.run_id must be a string";
        if (!stringWithin(payload, "run_id", git.max_payload_ref_bytes)) return "action.run_completed payload.run_id exceeds v1 field size limit";
        if (!hasString(payload, "conclusion")) return "action.run_completed payload.conclusion must be a string";
        if (!stringWithin(payload, "conclusion", git.max_payload_atom_bytes)) return "action.run_completed payload.conclusion exceeds v1 field size limit";
        const conclusion = jsonString(payload.get("conclusion")) orelse return "action.run_completed payload.conclusion must be a string";
        if (!isActionConclusion(conclusion)) return "action.run_completed payload.conclusion is not a recognized conclusion";
        if (!hasString(payload, "target_ref") and !hasString(payload, "target_oid")) return "action.run_completed payload.target_ref or payload.target_oid must be a string";
        if (!optionalStringWithin(payload, "target_ref", git.max_payload_ref_bytes)) return "action.run_completed payload.target_ref exceeds v1 ref size limit";
        if (!optionalStringWithin(payload, "target_oid", git.max_payload_ref_bytes)) return "action.run_completed payload.target_oid exceeds v1 ref size limit";
        if (!optionalStringWithin(payload, "workflow", git.max_payload_atom_bytes)) return "action.run_completed payload.workflow exceeds v1 field size limit";
        if (!optionalStringWithin(payload, "event_name", git.max_payload_atom_bytes)) return "action.run_completed payload.event_name exceeds v1 field size limit";
        if (!optionalStringWithin(payload, "diagnostics_ref", git.max_payload_ref_bytes)) return "action.run_completed payload.diagnostics_ref exceeds v1 ref size limit";
        if (!optionalStringWithin(payload, "diagnostics_oid", git.max_payload_ref_bytes)) return "action.run_completed payload.diagnostics_oid exceeds v1 ref size limit";
        if (!optionalObjectWithin(payload, "outputs", git.max_event_body_bytes)) return "action.run_completed payload.outputs must be an object within v1 size limits";
        if (!optionalArrayWithin(payload, "published_events", git.max_event_body_bytes)) return "action.run_completed payload.published_events must be an array within v1 size limits";
        return null;
    }

    return null;
}

fn isReactionEvent(event_type: []const u8) bool {
    return std.mem.eql(u8, event_type, "issue.reaction_added") or
        std.mem.eql(u8, event_type, "issue.reaction_removed") or
        std.mem.eql(u8, event_type, "pull.reaction_added") or
        std.mem.eql(u8, event_type, "pull.reaction_removed") or
        std.mem.eql(u8, event_type, "comment.reaction_added") or
        std.mem.eql(u8, event_type, "comment.reaction_removed");
}

fn validReactionEmoji(value: []const u8) bool {
    if (std.mem.trim(u8, value, " \t\r\n").len == 0) return false;
    for (value) |c| {
        if (c < 0x20) return false;
    }
    return true;
}

fn hasUuidString(payload: std.json.ObjectMap, key: []const u8) bool {
    const value = jsonString(payload.get(key)) orelse return false;
    return looksLikeUuid(value);
}

fn validProjectFieldType(value: []const u8) bool {
    return std.mem.eql(u8, value, "text") or
        std.mem.eql(u8, value, "number") or
        std.mem.eql(u8, value, "date") or
        std.mem.eql(u8, value, "boolean") or
        std.mem.eql(u8, value, "single_select") or
        std.mem.eql(u8, value, "multi_select") or
        std.mem.eql(u8, value, "user") or
        std.mem.eql(u8, value, "issue_ref");
}

fn validProjectViewLayout(value: []const u8) bool {
    return std.mem.eql(u8, value, "table") or
        std.mem.eql(u8, value, "board") or
        std.mem.eql(u8, value, "roadmap");
}

fn optionalIssuePriority(object: std.json.ObjectMap, key: []const u8) bool {
    if (object.get(key) == null) return true;
    return hasIssuePriority(object, key);
}

fn hasIssuePriority(object: std.json.ObjectMap, key: []const u8) bool {
    const value = jsonString(object.get(key)) orelse return false;
    return std.mem.eql(u8, value, "P0") or
        std.mem.eql(u8, value, "P1") or
        std.mem.eql(u8, value, "P2") or
        std.mem.eql(u8, value, "P3");
}

fn optionalIssueType(object: std.json.ObjectMap, key: []const u8) bool {
    if (object.get(key) == null) return true;
    return hasIssueType(object, key);
}

fn hasIssueType(object: std.json.ObjectMap, key: []const u8) bool {
    const value = jsonString(object.get(key)) orelse return false;
    return std.mem.eql(u8, value, "bug") or
        std.mem.eql(u8, value, "feature") or
        std.mem.eql(u8, value, "task");
}

fn optionalIssueStatus(object: std.json.ObjectMap, key: []const u8) bool {
    if (object.get(key) == null) return true;
    return hasIssueStatus(object, key);
}

fn hasIssueStatus(object: std.json.ObjectMap, key: []const u8) bool {
    const value = jsonString(object.get(key)) orelse return false;
    return std.mem.eql(u8, value, "Draft") or
        std.mem.eql(u8, value, "Todo") or
        std.mem.eql(u8, value, "WIP") or
        std.mem.eql(u8, value, "Review") or
        std.mem.eql(u8, value, "Done") or
        std.mem.eql(u8, value, "Failed");
}

fn optionalProjectStatus(object: std.json.ObjectMap, key: []const u8) bool {
    if (object.get(key) == null) return true;
    return hasProjectStatus(object, key);
}

fn hasProjectStatus(object: std.json.ObjectMap, key: []const u8) bool {
    const value = jsonString(object.get(key)) orelse return false;
    return std.mem.eql(u8, value, "Backlog") or
        std.mem.eql(u8, value, "Planned") or
        std.mem.eql(u8, value, "In Progress") or
        std.mem.eql(u8, value, "Completed") or
        std.mem.eql(u8, value, "Canceled");
}

fn optionalProjectUpdateHealth(object: std.json.ObjectMap, key: []const u8) bool {
    if (object.get(key) == null) return true;
    return hasProjectUpdateHealth(object, key);
}

fn hasProjectUpdateHealth(object: std.json.ObjectMap, key: []const u8) bool {
    const value = jsonString(object.get(key)) orelse return false;
    return std.mem.eql(u8, value, "on_track") or
        std.mem.eql(u8, value, "at_risk") or
        std.mem.eql(u8, value, "off_track");
}

fn hasIssueRelationshipKind(object: std.json.ObjectMap, key: []const u8) bool {
    const value = jsonString(object.get(key)) orelse return false;
    return std.mem.eql(u8, value, "parent") or std.mem.eql(u8, value, "blocks");
}

fn jsonValueWithin(value: std.json.Value, max_bytes: usize) bool {
    return jsonValueApproxLen(value) <= max_bytes;
}

fn jsonValueApproxLen(value: std.json.Value) usize {
    return switch (value) {
        .null => 4,
        .bool => 5,
        .integer => 32,
        .float => 32,
        .number_string => |number| number.len,
        .string => |string| string.len + 2,
        .array => |array| blk: {
            var total: usize = 2;
            for (array.items) |item| total += jsonValueApproxLen(item) + 1;
            break :blk total;
        },
        .object => |object| blk: {
            var total: usize = 2;
            var it = object.iterator();
            while (it.next()) |entry| {
                total += entry.key_ptr.*.len + 3 + jsonValueApproxLen(entry.value_ptr.*);
            }
            break :blk total;
        },
    };
}

pub fn objectIdRequirementError(event_type: []const u8, object_kind: []const u8, object_id: []const u8, payload: std.json.ObjectMap) ?[]const u8 {
    if (std.mem.startsWith(u8, event_type, "issue.") and std.mem.eql(u8, object_kind, "issue")) {
        if (!looksLikeUuid(object_id)) return "issue event object.id must be a UUID";
        return null;
    }
    if (std.mem.startsWith(u8, event_type, "pull.") and std.mem.eql(u8, object_kind, "pull")) {
        if (!looksLikeUuid(object_id)) return "pull event object.id must be a UUID";
        return null;
    }
    if (std.mem.startsWith(u8, event_type, "project.") and std.mem.eql(u8, object_kind, "project")) {
        if (!looksLikeUuid(object_id)) return "project event object.id must be a UUID";
        return null;
    }
    if (std.mem.startsWith(u8, event_type, "milestone.") and std.mem.eql(u8, object_kind, "milestone")) {
        if (!looksLikeUuid(object_id)) return "milestone event object.id must be a UUID";
        return null;
    }
    if (std.mem.startsWith(u8, event_type, "label.") and std.mem.eql(u8, object_kind, "label")) {
        if (!looksLikeUuid(object_id)) return "label event object.id must be a UUID";
        return null;
    }
    if (std.mem.startsWith(u8, event_type, "comment.") and std.mem.eql(u8, object_kind, "comment")) {
        if (!looksLikeUuid(object_id)) return "comment event object.id must be a UUID";
        return null;
    }
    if (std.mem.startsWith(u8, event_type, "notification.") and std.mem.eql(u8, object_kind, "notification")) {
        if (!looksLikeUuid(object_id)) return "notification event object.id must be a UUID";
        return null;
    }
    if (std.mem.startsWith(u8, event_type, "acl.") and std.mem.eql(u8, object_kind, "acl")) {
        const principal = jsonString(payload.get("principal")) orelse return "acl event payload.principal must be a string";
        if (!std.mem.startsWith(u8, object_id, "acl:")) return "acl event object.id must be acl:<principal>";
        if (!std.mem.eql(u8, object_id["acl:".len..], principal)) return "acl event object.id must match payload.principal";
        return null;
    }
    if (std.mem.startsWith(u8, event_type, "identity.") and std.mem.eql(u8, object_kind, "identity")) {
        const principal = jsonString(payload.get("principal")) orelse return "identity event payload.principal must be a string";
        const device = jsonString(payload.get("device")) orelse return "identity event payload.device must be a string";
        if (!std.mem.startsWith(u8, object_id, "identity:")) return "identity event object.id must be identity:<principal>:<device>";
        const rest = object_id["identity:".len..];
        const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return "identity event object.id must be identity:<principal>:<device>";
        if (!std.mem.eql(u8, rest[0..colon], principal)) return "identity event object.id must match payload.principal";
        if (!std.mem.eql(u8, rest[colon + 1 ..], device)) return "identity event object.id must match payload.device";
        return null;
    }
    if (std.mem.eql(u8, event_type, "action.run_requested") and std.mem.eql(u8, object_kind, "action")) {
        if (!looksLikeUuid(object_id)) return "action.run_requested object.id must be a run UUID";
        return null;
    }
    if (std.mem.eql(u8, event_type, "action.run_completed") and std.mem.eql(u8, object_kind, "action")) {
        if (!looksLikeUuid(object_id)) return "action.run_completed object.id must be a run UUID";
        const run_id = jsonString(payload.get("run_id")) orelse return "action.run_completed payload.run_id must be a string";
        if (!std.mem.eql(u8, object_id, run_id)) return "action.run_completed object.id must equal payload.run_id";
        return null;
    }
    return null;
}

fn requiredObject(object: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .object => |child| child,
        else => null,
    };
}

fn requiredString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    const string = switch (value) {
        .string => |s| s,
        else => return null,
    };
    if (string.len == 0) return null;
    return string;
}

fn requirePayloadString(payload: std.json.ObjectMap, event_type: []const u8, key: []const u8) ?[]const u8 {
    if (hasString(payload, key)) return null;
    if (std.mem.eql(u8, key, "title")) {
        if (std.mem.startsWith(u8, event_type, "issue.")) return "issue payload.title must be a string";
        if (std.mem.startsWith(u8, event_type, "pull.")) return "pull payload.title must be a string";
    }
    if (std.mem.eql(u8, key, "body")) {
        if (std.mem.startsWith(u8, event_type, "issue.")) return "issue payload.body must be a string";
        if (std.mem.startsWith(u8, event_type, "pull.")) return "pull payload.body must be a string";
        if (std.mem.startsWith(u8, event_type, "comment.")) return "comment payload.body must be a string";
    }
    return "event payload is missing a required string field";
}

fn requirePayloadStringWithin(payload: std.json.ObjectMap, event_type: []const u8, key: []const u8, max_bytes: usize) ?[]const u8 {
    if (requirePayloadString(payload, event_type, key)) |message| return message;
    if (!stringWithin(payload, key, max_bytes)) return "event payload string exceeds v1 field size limit";
    return null;
}

fn hasString(object: std.json.ObjectMap, key: []const u8) bool {
    const value = object.get(key) orelse return false;
    return value == .string;
}

fn hasNonEmptyStringWithin(object: std.json.ObjectMap, key: []const u8, max_bytes: usize) bool {
    const value = jsonString(object.get(key)) orelse return false;
    return value.len != 0 and value.len <= max_bytes;
}

fn stringWithin(object: std.json.ObjectMap, key: []const u8, max_bytes: usize) bool {
    const value = jsonString(object.get(key)) orelse return false;
    return value.len <= max_bytes;
}

fn objectValue(object: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .object => |child| child,
        else => null,
    };
}

fn optionalString(object: std.json.ObjectMap, key: []const u8) bool {
    const value = object.get(key) orelse return true;
    return value == .string;
}

fn optionalStringWithin(object: std.json.ObjectMap, key: []const u8, max_bytes: usize) bool {
    const value = object.get(key) orelse return true;
    const string = switch (value) {
        .string => |s| s,
        else => return false,
    };
    return string.len <= max_bytes;
}

fn optionalDateString(object: std.json.ObjectMap, key: []const u8) bool {
    const value = object.get(key) orelse return true;
    const string = switch (value) {
        .string => |s| s,
        else => return false,
    };
    return isDateString(string);
}

fn isDateString(value: []const u8) bool {
    if (value.len == 0) return true;
    if (value.len != 10) return false;
    for (value, 0..) |char, index_value| {
        if (index_value == 4 or index_value == 7) {
            if (char != '-') return false;
        } else if (!std.ascii.isDigit(char)) {
            return false;
        }
    }
    return true;
}

fn optionalObjectWithin(object: std.json.ObjectMap, key: []const u8, max_bytes: usize) bool {
    const value = object.get(key) orelse return true;
    switch (value) {
        .object => return jsonValueWithin(value, max_bytes),
        else => return false,
    }
}

fn optionalArrayWithin(object: std.json.ObjectMap, key: []const u8, max_bytes: usize) bool {
    const value = object.get(key) orelse return true;
    switch (value) {
        .array => return jsonValueWithin(value, max_bytes),
        else => return false,
    }
}

fn optionalLabelColor(object: std.json.ObjectMap, key: []const u8) bool {
    const value = object.get(key) orelse return true;
    const string = switch (value) {
        .string => |s| s,
        else => return false,
    };
    return validLabelColor(string);
}

fn validLabelColor(value: []const u8) bool {
    if (value.len != 7 or value[0] != '#') return false;
    for (value[1..]) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

fn isActionConclusion(value: []const u8) bool {
    return std.mem.eql(u8, value, "success") or
        std.mem.eql(u8, value, "failure") or
        std.mem.eql(u8, value, "cancelled") or
        std.mem.eql(u8, value, "skipped") or
        std.mem.eql(u8, value, "neutral") or
        std.mem.eql(u8, value, "timed_out") or
        std.mem.eql(u8, value, "action_required");
}

fn optionalBool(object: std.json.ObjectMap, key: []const u8) bool {
    const value = object.get(key) orelse return true;
    return value == .bool;
}

fn optionalNonNegativeInteger(object: std.json.ObjectMap, key: []const u8) bool {
    const value = object.get(key) orelse return true;
    const integer = switch (value) {
        .integer => |i| i,
        else => return false,
    };
    return integer >= 0;
}

fn optionalStringArray(object: std.json.ObjectMap, key: []const u8) bool {
    const value = object.get(key) orelse return true;
    const array = switch (value) {
        .array => |items| items,
        else => return false,
    };
    for (array.items) |item| {
        if (item != .string) return false;
    }
    return true;
}

fn optionalStringArrayWithin(object: std.json.ObjectMap, key: []const u8, max_items: usize, max_item_bytes: usize) bool {
    const value = object.get(key) orelse return true;
    const array = switch (value) {
        .array => |items| items,
        else => return false,
    };
    if (array.items.len > max_items) return false;
    for (array.items) |item| {
        if (item != .string or item.string.len > max_item_bytes) return false;
    }
    return true;
}

fn optionalIssueProjectsWithin(object: std.json.ObjectMap, key: []const u8, max_items: usize, max_item_bytes: usize) bool {
    const value = object.get(key) orelse return true;
    const array = switch (value) {
        .array => |items| items,
        else => return false,
    };
    if (array.items.len > max_items) return false;
    for (array.items) |item| {
        const project = switch (item) {
            .object => |map| map,
            else => return false,
        };
        const name = jsonString(project.get("project")) orelse return false;
        const column = jsonString(project.get("column")) orelse return false;
        if (name.len == 0 or name.len > max_item_bytes or column.len > max_item_bytes) return false;
    }
    return true;
}

fn optionalState(object: std.json.ObjectMap, key: []const u8, allowed: []const []const u8) bool {
    if (object.get(key) == null) return true;
    return hasState(object, key, allowed);
}

fn hasAnyKey(object: std.json.ObjectMap, keys: []const []const u8) bool {
    for (keys) |key| {
        if (object.get(key) != null) return true;
    }
    return false;
}

fn hasIssueLegacyAlias(legacy: std.json.ObjectMap) bool {
    return hasPositiveInteger(legacy, "github_issue_number") or hasPositiveInteger(legacy, "gitlab_issue_iid");
}

fn hasPullLegacyAlias(legacy: std.json.ObjectMap) bool {
    return hasPositiveInteger(legacy, "github_pull_number") or hasPositiveInteger(legacy, "gitlab_merge_request_iid");
}

fn hasPositiveInteger(object: std.json.ObjectMap, key: []const u8) bool {
    const value = object.get(key) orelse return false;
    if (value != .integer) return false;
    return value.integer > 0;
}

fn arrayLen(object: std.json.ObjectMap, key: []const u8) usize {
    const value = object.get(key) orelse return 0;
    return switch (value) {
        .array => |items| items.items.len,
        else => 0,
    };
}

fn hasState(object: std.json.ObjectMap, key: []const u8, allowed: []const []const u8) bool {
    const value = jsonString(object.get(key)) orelse return false;
    for (allowed) |candidate| {
        if (std.mem.eql(u8, value, candidate)) return true;
    }
    return false;
}

test "UTC RFC3339 timestamp validation is structural" {
    try std.testing.expect(isUtcRfc3339Timestamp("2026-05-13T18:30:59Z"));
    try std.testing.expect(isUtcRfc3339Timestamp("2026-05-13T18:30:59.123Z"));
    try std.testing.expect(isUtcRfc3339Timestamp("2024-02-29T00:00:00Z"));

    try std.testing.expect(!isUtcRfc3339Timestamp("invalid_date_Z"));
    try std.testing.expect(!isUtcRfc3339Timestamp("2026-02-29T00:00:00Z"));
    try std.testing.expect(!isUtcRfc3339Timestamp("2026-05-13T24:00:00Z"));
    try std.testing.expect(!isUtcRfc3339Timestamp("2026-05-13T18:30:60Z"));
    try std.testing.expect(!isUtcRfc3339Timestamp("2026-05-13T18:30:59+00:00"));
    try std.testing.expect(!isUtcRfc3339Timestamp("2026-05-13 18:30:59Z"));
    try std.testing.expect(!isUtcRfc3339Timestamp("2026-05-13T18:30:59.Z"));
}
