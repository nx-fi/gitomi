const std = @import("std");
const Allocator = std.mem.Allocator;

pub const JsonRootKind = enum {
    any,
    object,
    array,
};

pub fn appendJsonFieldString(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    key: []const u8,
    value: []const u8,
    comma: bool,
) !void {
    try appendJsonString(buf, allocator, key);
    try buf.append(allocator, ':');
    try appendJsonString(buf, allocator, value);
    if (comma) try buf.append(allocator, ',');
}

pub fn appendJsonFieldUnsigned(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    key: []const u8,
    value: u64,
    comma: bool,
) !void {
    try appendJsonString(buf, allocator, key);
    try buf.append(allocator, ':');
    try @import("compat").appendPrint(allocator, buf, "{d}", .{value});
    if (comma) try buf.append(allocator, ',');
}

pub fn appendJsonFieldStringArray(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    key: []const u8,
    values: []const []const u8,
    comma: bool,
) !void {
    try appendJsonString(buf, allocator, key);
    try buf.appendSlice(allocator, ":[");
    for (values, 0..) |value, idx| {
        if (idx != 0) try buf.append(allocator, ',');
        try appendJsonString(buf, allocator, value);
    }
    try buf.append(allocator, ']');
    if (comma) try buf.append(allocator, ',');
}

pub fn appendJsonString(buf: *std.ArrayList(u8), allocator: Allocator, value: []const u8) !void {
    try buf.append(allocator, '"');
    for (value) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            0x08 => try buf.appendSlice(allocator, "\\b"),
            0x0c => try buf.appendSlice(allocator, "\\f"),
            0x00...0x07, 0x0b, 0x0e...0x1f => {
                var escape_buf: [6]u8 = undefined;
                _ = std.fmt.bufPrint(&escape_buf, "\\u{x:0>4}", .{c}) catch unreachable;
                try buf.appendSlice(allocator, &escape_buf);
            },
            else => try buf.append(allocator, c),
        }
    }
    try buf.append(allocator, '"');
}

pub fn canonicalizeJsonValue(allocator: Allocator, bytes: []const u8, root_kind: JsonRootKind) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer parsed.deinit();

    if (!jsonRootKindMatches(parsed.value, root_kind)) return null;
    return try stringifyJsonValue(allocator, parsed.value);
}

pub fn requireCanonicalJsonValue(allocator: Allocator, bytes: []const u8, root_kind: JsonRootKind) ![]u8 {
    return (try canonicalizeJsonValue(allocator, bytes, root_kind)) orelse error.InvalidJsonValue;
}

pub fn stringifyJsonValue(allocator: Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return try out.toOwnedSlice();
}

fn jsonRootKindMatches(value: std.json.Value, root_kind: JsonRootKind) bool {
    return switch (root_kind) {
        .any => true,
        .object => switch (value) {
            .object => true,
            else => false,
        },
        .array => switch (value) {
            .array => true,
            else => false,
        },
    };
}

pub fn appendJsonFieldBool(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    key: []const u8,
    value: bool,
    comma: bool,
) !void {
    try appendJsonString(buf, allocator, key);
    try buf.append(allocator, ':');
    try buf.appendSlice(allocator, if (value) "true" else "false");
    if (comma) try buf.append(allocator, ',');
}

pub fn appendJsonFieldInteger(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    key: []const u8,
    value: i64,
    comma: bool,
) !void {
    try appendJsonString(buf, allocator, key);
    try buf.append(allocator, ':');
    try @import("compat").appendPrint(allocator, buf, "{d}", .{value});
    if (comma) try buf.append(allocator, ',');
}

test "json string escaping handles control characters" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendJsonString(&buf, std.testing.allocator, "a\n\"b\\");
    try std.testing.expectEqualStrings("\"a\\n\\\"b\\\\\"", buf.items);
}

test "canonical json values must be complete values with expected root type" {
    const canonical = try canonicalizeJsonValue(std.testing.allocator, " { \"ok\" : true } ", .object) orelse unreachable;
    defer std.testing.allocator.free(canonical);
    try std.testing.expectEqualStrings("{\"ok\":true}", canonical);

    const injected = try canonicalizeJsonValue(std.testing.allocator, "{}},\"conclusion\":\"success\",\"pad\":{", .object);
    try std.testing.expect(injected == null);

    const wrong_root = try canonicalizeJsonValue(std.testing.allocator, "[]", .object);
    try std.testing.expect(wrong_root == null);
}
