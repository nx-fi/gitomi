const std = @import("std");
const zwf_html = @import("../../zwf/html.zig");

const Allocator = std.mem.Allocator;

pub const TrustedHtml = zwf_html.TrustedHtml;
pub const JsonString = zwf_html.JsonString;
pub const GroupedUnsigned = zwf_html.GroupedUnsigned;
pub const Percent = zwf_html.Percent;
pub const Class = zwf_html.Class;
pub const ClassList = zwf_html.ClassList;
pub const ClassAttr = zwf_html.ClassAttr;

pub const trustedHtml = zwf_html.trustedHtml;
pub const jsonString = zwf_html.jsonString;
pub const groupedUnsigned = zwf_html.groupedUnsigned;
pub const percent = zwf_html.percent;
pub const class = zwf_html.class;
pub const classes = zwf_html.classes;
pub const classAttr = zwf_html.classAttr;
pub const appendHtml = zwf_html.appendHtml;
pub const appendTemplate = zwf_html.appendTemplate;

pub const Href = union(enum) {
    literal: []const u8,
    code: PathHref,
    raw: PathHref,
    commits: PathHref,
    blame: PathHref,
    commit: []const u8,
    issue: []const u8,
    pull: []const u8,

    pub fn appendHtmlValue(self: Href, buf: *std.ArrayList(u8), allocator: Allocator) !void {
        try appendHref(buf, allocator, self);
    }
};

pub const PathHref = struct {
    ref: []const u8,
    path: []const u8 = "",
    view: ?[]const u8 = null,
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
        try zwf_html.appendTemplateValue(buf, allocator, payload);
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
