const std = @import("std");
const model = @import("model.zig");
const json_access = @import("json.zig");

const Allocator = std.mem.Allocator;
const EventSummary = model.EventSummary;
const dupeJsonString = json_access.dupeJsonString;
const jsonInteger = json_access.jsonInteger;

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
