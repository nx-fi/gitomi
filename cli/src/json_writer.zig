const std = @import("std");
const Allocator = std.mem.Allocator;

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
    const raw = try std.fmt.allocPrint(allocator, "{d}", .{value});
    defer allocator.free(raw);
    try buf.appendSlice(allocator, raw);
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
                const escaped = try std.fmt.allocPrint(allocator, "\\u{x:0>4}", .{c});
                defer allocator.free(escaped);
                try buf.appendSlice(allocator, escaped);
            },
            else => try buf.append(allocator, c),
        }
    }
    try buf.append(allocator, '"');
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
    const raw = try std.fmt.allocPrint(allocator, "{d}", .{value});
    defer allocator.free(raw);
    try buf.appendSlice(allocator, raw);
    if (comma) try buf.append(allocator, ',');
}

test "json string escaping handles control characters" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendJsonString(&buf, std.testing.allocator, "a\n\"b\\");
    try std.testing.expectEqualStrings("\"a\\n\\\"b\\\\\"", buf.items);
}
