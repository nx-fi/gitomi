const std = @import("std");
const json_writer = @import("../../json_writer.zig");

const Allocator = std.mem.Allocator;
const appendJsonString = json_writer.appendJsonString;

pub const Href = union(enum) {
    literal: []const u8,
    code: PathHref,
    raw: PathHref,
    commits: PathHref,
    blame: PathHref,
    commit: []const u8,
    issue: []const u8,
    pull: []const u8,
};

pub const PathHref = struct {
    ref: []const u8,
    path: []const u8 = "",
    view: ?[]const u8 = null,
};

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

pub const TrustedHtml = struct {
    value: []const u8,
};

pub const JsonString = struct {
    value: []const u8,
};

pub const GroupedUnsigned = struct {
    value: u64,
};

pub const Percent = struct {
    value: u64,
    total: u64,
};

pub fn literalHref(value: []const u8) Href {
    return .{ .literal = value };
}

pub fn codeHref(ref: []const u8, path: []const u8) Href {
    return .{ .code = .{ .ref = ref, .path = path } };
}

pub fn codeHrefWithView(ref: []const u8, path: []const u8, view: []const u8) Href {
    return .{ .code = .{ .ref = ref, .path = path, .view = view } };
}

pub fn rawHref(ref: []const u8, path: []const u8) Href {
    return .{ .raw = .{ .ref = ref, .path = path } };
}

pub fn commitsHref(ref: []const u8, path: []const u8) Href {
    return .{ .commits = .{ .ref = ref, .path = path } };
}

pub fn blameHref(ref: []const u8, path: []const u8) Href {
    return .{ .blame = .{ .ref = ref, .path = path } };
}

pub fn commitHref(hash: []const u8) Href {
    return .{ .commit = hash };
}

pub fn issueHref(issue_ref: []const u8) Href {
    return .{ .issue = issue_ref };
}

pub fn pullHref(pull_ref: []const u8) Href {
    return .{ .pull = pull_ref };
}

pub fn class(name: []const u8, enabled: bool) Class {
    return .{ .name = name, .enabled = enabled };
}

pub fn classes(base: []const u8, extra: []const Class) ClassList {
    return .{ .base = base, .extra = extra };
}

pub fn classAttr(base: []const u8, extra: []const Class) ClassAttr {
    return .{ .value = classes(base, extra) };
}

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

pub fn trustedHtml(value: []const u8) TrustedHtml {
    return .{ .value = value };
}

pub fn jsonString(value: []const u8) JsonString {
    return .{ .value = value };
}

pub fn groupedUnsigned(value: u64) GroupedUnsigned {
    return .{ .value = value };
}

pub fn percent(value: u64, total: u64) Percent {
    return .{ .value = value, .total = total };
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
    if (T == TrustedHtml) {
        try buf.appendSlice(allocator, value.value);
        return;
    }
    if (T == Href) {
        try appendHref(buf, allocator, value);
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
        try appendJsonString(buf, allocator, value.value);
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

pub fn appendHref(buf: *std.ArrayList(u8), allocator: Allocator, href: Href) !void {
    switch (href) {
        .literal => |value| try appendHtml(buf, allocator, value),
        .code => |value| try appendPathHref(buf, allocator, "/code", value),
        .raw => |value| try appendPathHref(buf, allocator, "/raw", value),
        .commits => |value| try appendPathHref(buf, allocator, "/commits", value),
        .blame => |value| try appendPathHref(buf, allocator, "/blame", value),
        .commit => |hash| {
            try buf.appendSlice(allocator, "/commit?sha=");
            try appendUrlEncoded(buf, allocator, hash);
        },
        .issue => |issue_ref| {
            try buf.appendSlice(allocator, "/issues/");
            try appendUrlEncoded(buf, allocator, issue_ref);
        },
        .pull => |pull_ref| {
            try buf.appendSlice(allocator, "/pulls/");
            try appendUrlEncoded(buf, allocator, pull_ref);
        },
    }
}

pub fn appendOptionalAttr(buf: *std.ArrayList(u8), allocator: Allocator, comptime name: []const u8, value: anytype) !void {
    if (value) |payload| {
        try buf.append(allocator, ' ');
        try buf.appendSlice(allocator, name);
        try buf.appendSlice(allocator, "=\"");
        try appendTemplateValue(buf, allocator, payload);
        try buf.append(allocator, '"');
    }
}

fn appendPathHref(buf: *std.ArrayList(u8), allocator: Allocator, route: []const u8, href: PathHref) !void {
    try buf.appendSlice(allocator, route);
    try buf.appendSlice(allocator, "?ref=");
    try appendUrlEncoded(buf, allocator, href.ref);
    if (href.path.len != 0) {
        try buf.appendSlice(allocator, "&amp;path=");
        try appendUrlEncoded(buf, allocator, href.path);
    }
    if (href.view) |view| {
        try buf.appendSlice(allocator, "&amp;view=");
        try appendUrlEncoded(buf, allocator, view);
    }
}

pub fn appendUrlEncoded(buf: *std.ArrayList(u8), allocator: Allocator, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~' or c == '/') {
            try buf.append(allocator, c);
        } else {
            try buf.append(allocator, '%');
            try buf.append(allocator, hex[c >> 4]);
            try buf.append(allocator, hex[c & 0x0f]);
        }
    }
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

pub fn appendFmt(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try buf.appendSlice(allocator, text);
}
