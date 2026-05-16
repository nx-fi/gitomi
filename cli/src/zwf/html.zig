const std = @import("std");
const json_writer = @import("../json_writer.zig");

const Allocator = std.mem.Allocator;

pub const TrustedHtml = struct {
    value: []const u8,
};

pub fn trustedHtml(value: []const u8) TrustedHtml {
    return .{ .value = value };
}

pub const JsonString = struct {
    value: []const u8,
};

pub fn jsonString(value: []const u8) JsonString {
    return .{ .value = value };
}

pub const GroupedUnsigned = struct {
    value: u64,
};

pub fn groupedUnsigned(value: u64) GroupedUnsigned {
    return .{ .value = value };
}

pub const Percent = struct {
    value: u64,
    total: u64,
};

pub fn percent(value: u64, total: u64) Percent {
    return .{ .value = value, .total = total };
}

pub const Class = struct {
    name: []const u8,
    enabled: bool = true,
};

pub const ClassList = struct {
    base: []const u8,
    extra: []const Class = &.{},
};

pub const ClassAttr = struct {
    value: ClassList,
};

pub fn class(name: []const u8, enabled: bool) Class {
    return .{ .name = name, .enabled = enabled };
}

pub fn classes(base: []const u8, extra: []const Class) ClassList {
    return .{ .base = base, .extra = extra };
}

pub fn classAttr(base: []const u8, extra: []const Class) ClassAttr {
    return .{ .value = classes(base, extra) };
}

pub const HtmlBuilder = struct {
    allocator: Allocator,
    buf: std.ArrayList(u8) = .empty,

    pub fn init(allocator: Allocator) HtmlBuilder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *HtmlBuilder) void {
        self.buf.deinit(self.allocator);
    }

    pub fn append(self: *HtmlBuilder, value: []const u8) !void {
        try self.buf.appendSlice(self.allocator, value);
    }

    pub fn text(self: *HtmlBuilder, value: []const u8) !void {
        try appendHtml(&self.buf, self.allocator, value);
    }

    pub fn template(self: *HtmlBuilder, comptime markup: []const u8, values: anytype) !void {
        try appendTemplate(&self.buf, self.allocator, markup, values);
    }

    pub fn toOwnedSlice(self: *HtmlBuilder) ![]u8 {
        return self.buf.toOwnedSlice(self.allocator);
    }
};

pub fn appendHtml(buf: *std.ArrayList(u8), allocator: Allocator, value: []const u8) !void {
    for (value) |c| {
        switch (c) {
            '&' => try buf.appendSlice(allocator, "&amp;"),
            '<' => try buf.appendSlice(allocator, "&lt;"),
            '>' => try buf.appendSlice(allocator, "&gt;"),
            '"' => try buf.appendSlice(allocator, "&quot;"),
            '\'' => try buf.appendSlice(allocator, "&#39;"),
            else => try buf.append(allocator, c),
        }
    }
}

pub fn appendTemplate(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    comptime template: []const u8,
    values: anytype,
) !void {
    @setEvalBranchQuota(10_000);
    comptime var cursor: usize = 0;
    inline while (cursor < template.len) {
        comptime var token = cursor;
        inline while (token < template.len and template[token] != '{' and template[token] != '}') : (token += 1) {}

        if (token > cursor) try buf.appendSlice(allocator, template[cursor..token]);
        if (token == template.len) {
            cursor = token;
            continue;
        }

        if (template[token] == '{') {
            if (token + 1 < template.len and template[token + 1] == '{') {
                try buf.append(allocator, '{');
                cursor = token + 2;
                continue;
            }

            comptime var end = token + 1;
            inline while (end < template.len and template[end] != '}') : (end += 1) {
                if (template[end] == '{') @compileError("nested HTML template placeholder");
            }
            if (end == template.len) @compileError("unclosed HTML template placeholder");
            if (end == token + 1) @compileError("empty HTML template placeholder");

            try appendTemplateValue(buf, allocator, @field(values, template[token + 1 .. end]));
            cursor = end + 1;
            continue;
        }

        if (token + 1 < template.len and template[token + 1] == '}') {
            try buf.append(allocator, '}');
            cursor = token + 2;
            continue;
        }
        @compileError("unescaped closing brace in HTML template");
    }
}

fn appendTemplateValue(buf: *std.ArrayList(u8), allocator: Allocator, value: anytype) !void {
    const T = @TypeOf(value);
    if (hasAppendHtmlValue(T)) {
        try T.appendHtmlValue(value, buf, allocator);
        return;
    }
    if (T == TrustedHtml) {
        try buf.appendSlice(allocator, value.value);
        return;
    }
    if (T == ClassList) {
        try appendClassValue(buf, allocator, value);
        return;
    }
    if (T == ClassAttr) {
        try appendClassAttrValue(buf, allocator, value);
        return;
    }
    if (T == JsonString) {
        try json_writer.appendJsonString(buf, allocator, value.value);
        return;
    }
    if (T == GroupedUnsigned) {
        try appendGroupedUnsigned(buf, allocator, value.value);
        return;
    }
    if (T == Percent) {
        try appendPercent(buf, allocator, value.value, value.total);
        return;
    }

    switch (@typeInfo(T)) {
        .pointer => |info| switch (info.size) {
            .one, .slice => {
                const slice: []const u8 = value;
                try appendHtml(buf, allocator, slice);
            },
            .many, .c => {
                const slice: [:0]const u8 = std.mem.span(value);
                try appendHtml(buf, allocator, slice);
            },
        },
        .array => {
            const slice: []const u8 = &value;
            try appendHtml(buf, allocator, slice);
        },
        .bool => try buf.appendSlice(allocator, if (value) "true" else "false"),
        .int, .comptime_int => try std.fmt.format(buf.writer(allocator), "{d}", .{value}),
        .float, .comptime_float => try std.fmt.format(buf.writer(allocator), "{d}", .{value}),
        .@"enum", .enum_literal => try appendHtml(buf, allocator, @tagName(value)),
        .optional => if (value) |payload| try appendTemplateValue(buf, allocator, payload),
        else => @compileError("unsupported HTML template value type: " ++ @typeName(T)),
    }
}

fn hasAppendHtmlValue(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => @hasDecl(T, "appendHtmlValue"),
        else => false,
    };
}

fn appendClassValue(buf: *std.ArrayList(u8), allocator: Allocator, value: ClassList) !void {
    var wrote = false;
    if (value.base.len != 0) {
        try appendHtml(buf, allocator, value.base);
        wrote = true;
    }
    for (value.extra) |item| {
        if (!item.enabled) continue;
        if (wrote) try buf.append(allocator, ' ');
        try appendHtml(buf, allocator, item.name);
        wrote = true;
    }
}

fn appendClassAttrValue(buf: *std.ArrayList(u8), allocator: Allocator, attr: ClassAttr) !void {
    if (!classListHasValue(attr.value)) return;
    try buf.appendSlice(allocator, " class=\"");
    try appendClassValue(buf, allocator, attr.value);
    try buf.append(allocator, '"');
}

fn classListHasValue(value: ClassList) bool {
    if (value.base.len != 0) return true;
    for (value.extra) |item| {
        if (item.enabled) return true;
    }
    return false;
}

fn appendGroupedUnsigned(buf: *std.ArrayList(u8), allocator: Allocator, value: u64) !void {
    var digits: [20]u8 = undefined;
    const text = try std.fmt.bufPrint(&digits, "{d}", .{value});
    for (text, 0..) |c, i| {
        if (i != 0 and (text.len - i) % 3 == 0) try buf.append(allocator, ',');
        try buf.append(allocator, c);
    }
}

fn appendPercent(buf: *std.ArrayList(u8), allocator: Allocator, value: u64, total: u64) !void {
    const tenths = percentTenths(value, total);
    try std.fmt.format(buf.writer(allocator), "{d}.{d}%", .{ tenths / 10, tenths % 10 });
}

fn percentTenths(value: u64, total: u64) u64 {
    if (total == 0) return 0;
    const scaled = (@as(u128, value) * 1000 + @as(u128, total) / 2) / @as(u128, total);
    return @intCast(@min(scaled, 1000));
}

test "template escapes HTML by default and allows trusted HTML" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendTemplate(&buf, std.testing.allocator, "<p>{text} {trusted}</p>", .{
        .text = "<tag>",
        .trusted = trustedHtml("<strong>ok</strong>"),
    });

    try std.testing.expectEqualStrings("<p>&lt;tag&gt; <strong>ok</strong></p>", buf.items);
}
