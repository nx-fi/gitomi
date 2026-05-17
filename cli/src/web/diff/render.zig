const std = @import("std");
const shared = @import("../shared.zig");

const Allocator = std.mem.Allocator;
const appendEmptyState = shared.appendEmptyState;
const appendHref = shared.appendHref;
const appendOptionalAttr = shared.appendOptionalAttr;
const appendTemplate = shared.appendTemplate;
const commitHref = shared.commitHref;

const max_context = 200;

pub const ExpandConfig = struct {
    commit_hash: []const u8,
    context: usize,
};

pub const Options = struct {
    empty_message: []const u8,
    expand: ?ExpandConfig = null,
};

const DiffHunkRange = struct {
    old_start: usize,
    new_start: usize,
};

pub fn append(buf: *std.ArrayList(u8), allocator: Allocator, diff: []const u8, options: Options) !void {
    if (std.mem.trim(u8, diff, " \t\r\n").len == 0) {
        try appendEmptyState(buf, allocator, "No file changes.", options.empty_message);
        return;
    }

    var in_file = false;
    var file_index: usize = 0;
    var current_file_index: usize = 0;
    var rendered_lines: usize = 0;
    var old_line: ?usize = null;
    var new_line: ?usize = null;
    var lines = std.mem.splitScalar(u8, diff, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (std.mem.startsWith(u8, line, "diff --git ")) {
            if (in_file) try buf.appendSlice(allocator, "</div></section>");
            in_file = true;
            current_file_index = file_index;
            file_index += 1;
            rendered_lines = 0;
            old_line = null;
            new_line = null;
            try appendDiffFileStart(buf, allocator, current_file_index, diffFileTitle(line));
            continue;
        } else if (!in_file) {
            in_file = true;
            current_file_index = file_index;
            file_index += 1;
            rendered_lines = 0;
            old_line = null;
            new_line = null;
            try appendDiffFileStart(buf, allocator, current_file_index, "Patch");
        }

        if (parseHunkHeader(line)) |range| {
            if (options.expand) |expand| {
                if (rendered_lines == 0) {
                    if (range.old_start > 1 or range.new_start > 1) {
                        try appendDiffExpandRow(buf, allocator, expand, current_file_index, "Expand from file start");
                    }
                } else {
                    try appendDiffExpandRow(buf, allocator, expand, current_file_index, "Expand hidden lines");
                }
            }
            old_line = range.old_start;
            new_line = range.new_start;
            try appendDiffLine(buf, allocator, line, "hunk", null, null);
            rendered_lines += 1;
            continue;
        }

        const class = diffLineClass(line);
        if (std.mem.eql(u8, class, "add")) {
            try appendDiffLine(buf, allocator, line, class, null, new_line);
            if (new_line) |value| new_line = value + 1;
        } else if (std.mem.eql(u8, class, "del")) {
            try appendDiffLine(buf, allocator, line, class, old_line, null);
            if (old_line) |value| old_line = value + 1;
        } else if (std.mem.eql(u8, class, "context")) {
            try appendDiffLine(buf, allocator, line, class, old_line, new_line);
            if (old_line) |value| old_line = value + 1;
            if (new_line) |value| new_line = value + 1;
        } else {
            try appendDiffLine(buf, allocator, line, class, null, null);
        }
        rendered_lines += 1;
    }

    if (in_file) try buf.appendSlice(allocator, "</div></section>");
}

fn appendDiffFileStart(buf: *std.ArrayList(u8), allocator: Allocator, file_index: usize, title: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<section class="panel diff-file" id="diff-file-{file_index}" data-diff-file data-diff-file-index="{file_index}" data-diff-file-path="{title}"><div class="diff-file-head"><strong>{title}</strong></div><div class="diff-lines">
    , .{
        .file_index = file_index,
        .title = title,
    });
}

fn appendDiffExpandRow(buf: *std.ArrayList(u8), allocator: Allocator, expand: ExpandConfig, file_index: usize, label: []const u8) !void {
    try buf.appendSlice(allocator, "<div class=\"diff-row diff-expand\" data-diff-row data-diff-kind=\"expand\"><span></span><span></span>");
    if (expand.context < max_context) {
        try buf.appendSlice(allocator, "<a data-diff-expand href=\"");
        try appendCommitHrefWithContext(buf, allocator, expand.commit_hash, @min(expand.context * 4, @as(usize, max_context)), file_index);
        try appendTemplate(buf, allocator, "\">{label}</a>", .{ .label = label });
    } else {
        try buf.appendSlice(allocator, "<span>Maximum context shown</span>");
    }
    try buf.appendSlice(allocator, "</div>");
}

fn appendCommitHrefWithContext(buf: *std.ArrayList(u8), allocator: Allocator, hash: []const u8, context: usize, file_index: usize) !void {
    try appendHref(buf, allocator, commitHref(hash));
    try buf.appendSlice(allocator, "&amp;context=");
    try std.fmt.format(buf.writer(allocator), "{d}", .{context});
    try buf.appendSlice(allocator, "#diff-file-");
    try std.fmt.format(buf.writer(allocator), "{d}", .{file_index});
}

fn appendDiffLine(buf: *std.ArrayList(u8), allocator: Allocator, line: []const u8, class: []const u8, old_line: ?usize, new_line: ?usize) !void {
    try appendTemplate(buf, allocator,
        \\<div class="diff-row {class}" data-diff-row data-diff-kind="{class}"
    , .{ .class = class });
    try appendOptionalAttr(buf, allocator, "data-diff-old", old_line);
    try appendOptionalAttr(buf, allocator, "data-diff-new", new_line);
    try buf.appendSlice(allocator, "><span class=\"diff-num old\">");
    try appendLineNumber(buf, allocator, old_line);
    try buf.appendSlice(allocator, "</span><span class=\"diff-num new\">");
    try appendLineNumber(buf, allocator, new_line);
    try appendTemplate(buf, allocator,
        \\</span><code class="diff-code">{line}</code></div>
    , .{ .line = line });
}

fn appendLineNumber(buf: *std.ArrayList(u8), allocator: Allocator, line_number: ?usize) !void {
    if (line_number) |value| {
        if (value != 0) try std.fmt.format(buf.writer(allocator), "{d}", .{value});
    }
}

fn diffLineClass(line: []const u8) []const u8 {
    if (std.mem.startsWith(u8, line, "@@")) return "hunk";
    if (std.mem.startsWith(u8, line, "+") and !std.mem.startsWith(u8, line, "+++")) return "add";
    if (std.mem.startsWith(u8, line, "-") and !std.mem.startsWith(u8, line, "---")) return "del";
    if (std.mem.startsWith(u8, line, "diff --git ") or
        std.mem.startsWith(u8, line, "index ") or
        std.mem.startsWith(u8, line, "new file mode ") or
        std.mem.startsWith(u8, line, "deleted file mode ") or
        std.mem.startsWith(u8, line, "similarity index ") or
        std.mem.startsWith(u8, line, "rename from ") or
        std.mem.startsWith(u8, line, "rename to ") or
        std.mem.startsWith(u8, line, "---") or
        std.mem.startsWith(u8, line, "+++") or
        std.mem.startsWith(u8, line, "Binary files "))
    {
        return "meta";
    }
    return "context";
}

fn parseHunkHeader(line: []const u8) ?DiffHunkRange {
    if (!std.mem.startsWith(u8, line, "@@")) return null;
    const minus = std.mem.indexOfScalar(u8, line, '-') orelse return null;
    const plus = std.mem.indexOfScalarPos(u8, line, minus + 1, '+') orelse return null;
    return .{
        .old_start = parseHunkStart(line[minus + 1 .. plus]) orelse return null,
        .new_start = parseHunkStart(line[plus + 1 ..]) orelse return null,
    };
}

fn parseHunkStart(value: []const u8) ?usize {
    const trimmed = std.mem.trim(u8, value, " ");
    if (trimmed.len == 0) return null;
    const end = std.mem.indexOfAny(u8, trimmed, ", ") orelse trimmed.len;
    return std.fmt.parseUnsigned(usize, trimmed[0..end], 10) catch null;
}

fn diffFileTitle(line: []const u8) []const u8 {
    const marker = " b/";
    if (std.mem.lastIndexOf(u8, line, marker)) |index| return line[index + marker.len ..];

    var parts = std.mem.splitScalar(u8, line, ' ');
    _ = parts.next();
    _ = parts.next();
    _ = parts.next();
    const b = parts.next() orelse return line;
    return if (std.mem.startsWith(u8, b, "b/")) b[2..] else b;
}

test "web diff renderer renders line classes" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try append(
        &buf,
        std.testing.allocator,
        "diff --git a/a.zig b/a.zig\n@@ -2 +2 @@\n-old\n+new\n",
        .{
            .empty_message = "This commit does not contain a patch to display.",
            .expand = .{ .commit_hash = "abc123", .context = 3 },
        },
    );
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "diff-file") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "diff-row hunk") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "diff-row del") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "diff-row add") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "diff-num old\">2") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "diff-num new\">2") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "id=\"diff-file-0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "data-diff-row data-diff-kind=\"del\" data-diff-old=\"2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "data-diff-expand href=\"/commit?sha=abc123&amp;context=12#diff-file-0\"") != null);
}
