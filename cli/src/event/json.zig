const std = @import("std");

const Allocator = std.mem.Allocator;

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
