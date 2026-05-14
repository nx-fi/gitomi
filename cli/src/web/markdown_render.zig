const std = @import("std");

const shared = @import("shared.zig");

const Allocator = std.mem.Allocator;
const appendFmt = shared.appendFmt;
const appendHref = shared.appendHref;
const appendHtml = shared.appendHtml;
const codeHref = shared.codeHref;
const codeHrefWithView = shared.codeHrefWithView;
const rawHref = shared.rawHref;

pub const MarkdownLinkContext = struct {
    ref: []const u8,
    current_path: []const u8,
};

pub const MarkdownOptions = struct {
    link_context: ?MarkdownLinkContext = null,
};

const MarkdownState = struct {
    paragraph_open: bool = false,
    ul_open: bool = false,
    ol_open: bool = false,
    code_open: bool = false,
};

pub fn appendMarkdown(buf: *std.ArrayList(u8), allocator: Allocator, markdown: []const u8) !void {
    try appendMarkdownWithOptions(buf, allocator, markdown, .{});
}

pub fn appendMarkdownWithOptions(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    markdown: []const u8,
    options: MarkdownOptions,
) !void {
    var state = MarkdownState{};
    var markdown_lines: std.ArrayList([]const u8) = .empty;
    defer markdown_lines.deinit(allocator);

    var raw_lines = std.mem.splitScalar(u8, markdown, '\n');
    while (raw_lines.next()) |raw_line| {
        try markdown_lines.append(allocator, std.mem.trimRight(u8, raw_line, "\r"));
    }

    var line_index: usize = 0;
    while (line_index < markdown_lines.items.len) {
        const line = markdown_lines.items[line_index];
        const trimmed = std.mem.trim(u8, line, " \t");

        if (state.code_open) {
            if (isFence(trimmed)) {
                try buf.appendSlice(allocator, "</code></pre>");
                state.code_open = false;
            } else {
                try appendHtml(buf, allocator, line);
                try buf.append(allocator, '\n');
            }
            line_index += 1;
            continue;
        }

        if (isFence(trimmed)) {
            try closeMarkdownFlow(buf, allocator, &state);
            const language = fenceLanguage(trimmed);
            if (std.mem.eql(u8, language, "mermaid")) {
                try buf.appendSlice(allocator, "<pre class=\"mermaid-source\" data-mermaid><code>");
            } else {
                try buf.appendSlice(allocator, "<pre><code class=\"language-");
                try appendLanguageClass(buf, allocator, language);
                try buf.appendSlice(allocator, "\">");
            }
            state.code_open = true;
            line_index += 1;
            continue;
        }

        if (trimmed.len == 0) {
            try closeMarkdownFlow(buf, allocator, &state);
            line_index += 1;
            continue;
        }

        if (isMathBlockStart(trimmed)) {
            try closeMarkdownFlow(buf, allocator, &state);
            line_index = try appendMathBlock(buf, allocator, markdown_lines.items, line_index);
            continue;
        }

        if (isTableStart(markdown_lines.items, line_index)) {
            try closeMarkdownFlow(buf, allocator, &state);
            line_index = try appendMarkdownTable(buf, allocator, markdown_lines.items, line_index, options);
            continue;
        }

        if (headingLevel(trimmed)) |level| {
            try closeMarkdownFlow(buf, allocator, &state);
            const content = std.mem.trim(u8, trimmed[level + 1 ..], " \t");
            try appendFmt(buf, allocator, "<h{d}>", .{level});
            try appendInlineMarkdown(buf, allocator, content, options);
            try appendFmt(buf, allocator, "</h{d}>", .{level});
            line_index += 1;
            continue;
        }

        if (std.mem.eql(u8, trimmed, "---") or std.mem.eql(u8, trimmed, "***")) {
            try closeMarkdownFlow(buf, allocator, &state);
            try buf.appendSlice(allocator, "<hr>");
            line_index += 1;
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, ">")) {
            try closeMarkdownFlow(buf, allocator, &state);
            const quote = std.mem.trim(u8, trimmed[1..], " \t");
            try buf.appendSlice(allocator, "<blockquote><p>");
            try appendInlineMarkdown(buf, allocator, quote, options);
            try buf.appendSlice(allocator, "</p></blockquote>");
            line_index += 1;
            continue;
        }

        if (unorderedItem(trimmed)) |item| {
            try closeParagraph(buf, allocator, &state);
            if (state.ol_open) {
                try buf.appendSlice(allocator, "</ol>");
                state.ol_open = false;
            }
            if (!state.ul_open) {
                try buf.appendSlice(allocator, "<ul>");
                state.ul_open = true;
            }
            try appendMarkdownListItem(buf, allocator, item, options);
            line_index += 1;
            continue;
        }

        if (orderedItem(trimmed)) |item| {
            try closeParagraph(buf, allocator, &state);
            if (state.ul_open) {
                try buf.appendSlice(allocator, "</ul>");
                state.ul_open = false;
            }
            if (!state.ol_open) {
                try buf.appendSlice(allocator, "<ol>");
                state.ol_open = true;
            }
            try appendMarkdownListItem(buf, allocator, item, options);
            line_index += 1;
            continue;
        }

        if (state.ul_open) {
            try buf.appendSlice(allocator, "</ul>");
            state.ul_open = false;
        }
        if (state.ol_open) {
            try buf.appendSlice(allocator, "</ol>");
            state.ol_open = false;
        }
        if (!state.paragraph_open) {
            try buf.appendSlice(allocator, "<p>");
            state.paragraph_open = true;
        } else {
            try buf.append(allocator, ' ');
        }
        try appendInlineMarkdown(buf, allocator, trimmed, options);
        line_index += 1;
    }

    if (state.code_open) {
        try buf.appendSlice(allocator, "</code></pre>");
        state.code_open = false;
    }
    try closeMarkdownFlow(buf, allocator, &state);
}

fn isTableStart(lines: []const []const u8, index: usize) bool {
    if (index + 1 >= lines.len) return false;
    const header = std.mem.trim(u8, lines[index], " \t");
    const separator = std.mem.trim(u8, lines[index + 1], " \t");
    return isTableRow(header) and isTableSeparator(separator);
}

fn appendMarkdownTable(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    lines: []const []const u8,
    start: usize,
    options: MarkdownOptions,
) !usize {
    try buf.appendSlice(allocator, "<div class=\"table-wrap markdown-table-wrap\"><table class=\"markdown-table\"><thead>");
    try appendMarkdownTableRow(buf, allocator, lines[start], "th", options);
    try buf.appendSlice(allocator, "</thead>");

    var index = start + 2;
    var body_open = false;
    while (index < lines.len) : (index += 1) {
        const trimmed = std.mem.trim(u8, lines[index], " \t");
        if (!isTableRow(trimmed) or isTableSeparator(trimmed)) break;
        if (!body_open) {
            try buf.appendSlice(allocator, "<tbody>");
            body_open = true;
        }
        try appendMarkdownTableRow(buf, allocator, trimmed, "td", options);
    }
    if (body_open) try buf.appendSlice(allocator, "</tbody>");
    try buf.appendSlice(allocator, "</table></div>");
    return index;
}

fn appendMarkdownTableRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    row: []const u8,
    tag: []const u8,
    options: MarkdownOptions,
) !void {
    try buf.appendSlice(allocator, "<tr>");
    var cells = std.mem.splitScalar(u8, trimTablePipes(row), '|');
    while (cells.next()) |raw_cell| {
        const cell = std.mem.trim(u8, raw_cell, " \t");
        try buf.append(allocator, '<');
        try buf.appendSlice(allocator, tag);
        try buf.append(allocator, '>');
        try appendInlineMarkdown(buf, allocator, cell, options);
        try buf.appendSlice(allocator, "</");
        try buf.appendSlice(allocator, tag);
        try buf.append(allocator, '>');
    }
    try buf.appendSlice(allocator, "</tr>");
}

fn isTableRow(trimmed: []const u8) bool {
    return trimmed.len != 0 and std.mem.indexOfScalar(u8, trimmed, '|') != null;
}

fn isTableSeparator(trimmed: []const u8) bool {
    const row = trimTablePipes(trimmed);
    if (row.len == 0) return false;

    var cells = std.mem.splitScalar(u8, row, '|');
    var count: usize = 0;
    var has_hyphen = false;
    while (cells.next()) |raw_cell| {
        const cell = std.mem.trim(u8, raw_cell, " \t");
        if (cell.len == 0) return false;
        for (cell) |c| {
            switch (c) {
                '-' => has_hyphen = true,
                ':' => {},
                else => return false,
            }
        }
        count += 1;
    }
    return count > 0 and has_hyphen;
}

fn trimTablePipes(row: []const u8) []const u8 {
    var value = std.mem.trim(u8, row, " \t");
    if (value.len != 0 and value[0] == '|') {
        value = std.mem.trimLeft(u8, value[1..], " \t");
    }
    if (value.len != 0 and value[value.len - 1] == '|') {
        value = std.mem.trimRight(u8, value[0 .. value.len - 1], " \t");
    }
    return value;
}

fn isMathBlockStart(trimmed: []const u8) bool {
    return std.mem.startsWith(u8, trimmed, "$$");
}

fn appendMathBlock(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    lines: []const []const u8,
    start: usize,
) !usize {
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(allocator);

    var index = start + 1;
    var closed = false;
    const first = std.mem.trim(u8, lines[start], " \t");
    const rest = std.mem.trimLeft(u8, first[2..], " \t");
    if (rest.len != 0) {
        if (std.mem.indexOf(u8, rest, "$$")) |end| {
            try content.appendSlice(allocator, std.mem.trimRight(u8, rest[0..end], " \t"));
            closed = true;
        } else {
            try content.appendSlice(allocator, rest);
        }
    }

    while (!closed and index < lines.len) {
        const line = lines[index];
        if (std.mem.indexOf(u8, line, "$$")) |end| {
            const before = std.mem.trimRight(u8, line[0..end], " \t");
            if (content.items.len != 0 and before.len != 0) try content.append(allocator, '\n');
            try content.appendSlice(allocator, before);
            closed = true;
            index += 1;
            break;
        }
        if (content.items.len != 0) try content.append(allocator, '\n');
        try content.appendSlice(allocator, line);
        index += 1;
    }

    try buf.appendSlice(allocator, "<div class=\"math-block\" data-latex-display>");
    try appendHtml(buf, allocator, std.mem.trim(u8, content.items, " \t\r\n"));
    try buf.appendSlice(allocator, "</div>");
    return index;
}

fn closeMarkdownFlow(buf: *std.ArrayList(u8), allocator: Allocator, state: *MarkdownState) !void {
    try closeParagraph(buf, allocator, state);
    if (state.ul_open) {
        try buf.appendSlice(allocator, "</ul>");
        state.ul_open = false;
    }
    if (state.ol_open) {
        try buf.appendSlice(allocator, "</ol>");
        state.ol_open = false;
    }
}

fn closeParagraph(buf: *std.ArrayList(u8), allocator: Allocator, state: *MarkdownState) !void {
    if (state.paragraph_open) {
        try buf.appendSlice(allocator, "</p>");
        state.paragraph_open = false;
    }
}

const TaskListItem = struct {
    checked: bool,
    content: []const u8,
};

fn appendMarkdownListItem(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    item: []const u8,
    options: MarkdownOptions,
) !void {
    if (taskListItem(item)) |task| {
        try buf.appendSlice(allocator, "<li class=\"task-list-item\"><input class=\"task-list-checkbox\" type=\"checkbox\" disabled");
        if (task.checked) try buf.appendSlice(allocator, " checked");
        try buf.appendSlice(allocator, ">");
        if (task.content.len != 0) {
            try buf.append(allocator, ' ');
            try appendInlineMarkdown(buf, allocator, task.content, options);
        }
        try buf.appendSlice(allocator, "</li>");
        return;
    }

    try buf.appendSlice(allocator, "<li>");
    try appendInlineMarkdown(buf, allocator, item, options);
    try buf.appendSlice(allocator, "</li>");
}

fn taskListItem(item: []const u8) ?TaskListItem {
    const trimmed = std.mem.trimLeft(u8, item, " \t");
    if (trimmed.len < 3) return null;
    if (trimmed[0] != '[' or trimmed[2] != ']') return null;

    const checked = switch (trimmed[1]) {
        ' ' => false,
        'x', 'X' => true,
        else => return null,
    };

    if (trimmed.len > 3 and trimmed[3] != ' ' and trimmed[3] != '\t') return null;
    return .{
        .checked = checked,
        .content = if (trimmed.len > 3) std.mem.trim(u8, trimmed[3..], " \t") else "",
    };
}

fn appendInlineMarkdown(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    value: []const u8,
    options: MarkdownOptions,
) !void {
    var i: usize = 0;
    while (i < value.len) {
        if (value[i] == '`') {
            if (std.mem.indexOfScalarPos(u8, value, i + 1, '`')) |end| {
                try buf.appendSlice(allocator, "<code>");
                try appendHtml(buf, allocator, value[i + 1 .. end]);
                try buf.appendSlice(allocator, "</code>");
                i = end + 1;
                continue;
            }
        }

        if (value[i] == '$' and (i + 1 >= value.len or value[i + 1] != '$')) {
            if (std.mem.indexOfScalarPos(u8, value, i + 1, '$')) |end| {
                if (end > i + 1 and (end + 1 >= value.len or value[end + 1] != '$')) {
                    try buf.appendSlice(allocator, "<span class=\"math-inline\" data-latex-inline>");
                    try appendHtml(buf, allocator, value[i + 1 .. end]);
                    try buf.appendSlice(allocator, "</span>");
                    i = end + 1;
                    continue;
                }
            }
        }

        if (std.mem.startsWith(u8, value[i..], "**")) {
            if (std.mem.indexOfPos(u8, value, i + 2, "**")) |end| {
                try buf.appendSlice(allocator, "<strong>");
                try appendInlineMarkdown(buf, allocator, value[i + 2 .. end], options);
                try buf.appendSlice(allocator, "</strong>");
                i = end + 2;
                continue;
            }
        }

        if (std.mem.startsWith(u8, value[i..], "![")) {
            if (std.mem.indexOfScalarPos(u8, value, i + 2, ']')) |label_end| {
                if (label_end + 1 < value.len and value[label_end + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, value, label_end + 2, ')')) |href_end| {
                        const href = std.mem.trim(u8, value[label_end + 2 .. href_end], " \t");
                        if (isSafeHref(href)) {
                            try appendMarkdownMedia(buf, allocator, value[i + 2 .. label_end], href, options);
                            i = href_end + 1;
                            continue;
                        }
                    }
                }
            }
        }

        if (value[i] == '[') {
            if (std.mem.indexOfScalarPos(u8, value, i + 1, ']')) |label_end| {
                if (label_end + 1 < value.len and value[label_end + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, value, label_end + 2, ')')) |href_end| {
                        const href = std.mem.trim(u8, value[label_end + 2 .. href_end], " \t");
                        if (isSafeHref(href)) {
                            try buf.appendSlice(allocator, "<a href=\"");
                            try appendMarkdownHref(buf, allocator, href, options);
                            try buf.appendSlice(allocator, "\">");
                            try appendInlineMarkdown(buf, allocator, value[i + 1 .. label_end], options);
                            try buf.appendSlice(allocator, "</a>");
                            i = href_end + 1;
                            continue;
                        }
                    }
                }
            }
        }

        if (value[i] == '&') {
            try buf.appendSlice(allocator, "&amp;");
        } else if (value[i] == '<') {
            try buf.appendSlice(allocator, "&lt;");
        } else if (value[i] == '>') {
            try buf.appendSlice(allocator, "&gt;");
        } else if (value[i] == '"') {
            try buf.appendSlice(allocator, "&quot;");
        } else if (value[i] == '\'') {
            try buf.appendSlice(allocator, "&#39;");
        } else {
            try buf.append(allocator, value[i]);
        }
        i += 1;
    }
}

fn appendMarkdownMedia(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    alt: []const u8,
    href: []const u8,
    options: MarkdownOptions,
) !void {
    if (isVideoHref(href)) {
        try buf.appendSlice(allocator, "<video class=\"markdown-media\" controls preload=\"metadata\"><source src=\"");
        try appendMarkdownMediaSrc(buf, allocator, href, options);
        if (mediaContentTypeForHref(href)) |content_type| {
            try buf.appendSlice(allocator, "\" type=\"");
            try appendHtml(buf, allocator, content_type);
        }
        try buf.appendSlice(allocator, "\">");
        try appendHtml(buf, allocator, alt);
        try buf.appendSlice(allocator, "</video>");
        return;
    }

    try buf.appendSlice(allocator, "<img class=\"markdown-media\" src=\"");
    try appendMarkdownMediaSrc(buf, allocator, href, options);
    try buf.appendSlice(allocator, "\" alt=\"");
    try appendHtml(buf, allocator, alt);
    try buf.appendSlice(allocator, "\">");
}

fn appendMarkdownMediaSrc(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    href: []const u8,
    options: MarkdownOptions,
) !void {
    if (options.link_context) |context| {
        if (try appendRepositoryRawHref(buf, allocator, href, context)) return;
    }
    try appendHtml(buf, allocator, href);
}

fn appendMarkdownHref(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    href: []const u8,
    options: MarkdownOptions,
) !void {
    if (options.link_context) |context| {
        if (try appendRepositoryHref(buf, allocator, href, context)) return;
    }
    try appendHtml(buf, allocator, href);
}

fn appendRepositoryHref(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    href: []const u8,
    context: MarkdownLinkContext,
) !bool {
    if (!isRepositoryRelativeHref(href)) return false;

    const href_path = hrefPathPart(href);
    if (href_path.len == 0 and !std.mem.eql(u8, href, "/")) return false;

    const decoded_path = percentDecodeUrlPath(allocator, href_path) catch |err| switch (err) {
        error.InvalidUrlEncoding => return false,
        else => return err,
    };
    defer allocator.free(decoded_path);

    const target_path = (try resolveRepositoryPathOwned(allocator, context.current_path, decoded_path)) orelse return false;
    defer allocator.free(target_path);

    try appendHref(buf, allocator, if (isMarkdownPath(target_path))
        codeHrefWithView(context.ref, target_path, "preview")
    else
        codeHref(context.ref, target_path));
    const fragment = hrefFragmentPart(href);
    if (fragment.len != 0) try appendHtml(buf, allocator, fragment);
    return true;
}

fn appendRepositoryRawHref(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    href: []const u8,
    context: MarkdownLinkContext,
) !bool {
    if (!isRepositoryRelativeHref(href)) return false;

    const href_path = hrefPathPart(href);
    if (href_path.len == 0 and !std.mem.eql(u8, href, "/")) return false;

    const decoded_path = percentDecodeUrlPath(allocator, href_path) catch |err| switch (err) {
        error.InvalidUrlEncoding => return false,
        else => return err,
    };
    defer allocator.free(decoded_path);

    const target_path = (try resolveRepositoryPathOwned(allocator, context.current_path, decoded_path)) orelse return false;
    defer allocator.free(target_path);

    try appendHref(buf, allocator, rawHref(context.ref, target_path));
    const fragment = hrefFragmentPart(href);
    if (fragment.len != 0) try appendHtml(buf, allocator, fragment);
    return true;
}

fn isRepositoryRelativeHref(href: []const u8) bool {
    if (href.len == 0) return false;
    if (href[0] == '#' or href[0] == '?') return false;
    if (std.mem.startsWith(u8, href, "//")) return false;
    return !hasUriScheme(href);
}

fn hasUriScheme(value: []const u8) bool {
    if (value.len == 0 or !std.ascii.isAlphabetic(value[0])) return false;
    var i: usize = 1;
    while (i < value.len) : (i += 1) {
        switch (value[i]) {
            ':' => return true,
            '/', '?', '#' => return false,
            'A'...'Z', 'a'...'z', '0'...'9', '+', '-', '.' => {},
            else => return false,
        }
    }
    return false;
}

fn hrefPathPart(href: []const u8) []const u8 {
    const query = std.mem.indexOfScalar(u8, href, '?') orelse href.len;
    const fragment = std.mem.indexOfScalar(u8, href, '#') orelse href.len;
    return href[0..@min(query, fragment)];
}

fn hrefFragmentPart(href: []const u8) []const u8 {
    const fragment = std.mem.indexOfScalar(u8, href, '#') orelse return "";
    return href[fragment..];
}

fn resolveRepositoryPathOwned(
    allocator: Allocator,
    current_path: []const u8,
    href_path: []const u8,
) !?[]u8 {
    var segments: std.ArrayList([]const u8) = .empty;
    defer segments.deinit(allocator);

    const root_relative = std.mem.startsWith(u8, href_path, "/");
    if (!root_relative) {
        try appendPathSegments(&segments, allocator, parentPath(current_path));
    }

    var parts = std.mem.splitScalar(u8, std.mem.trim(u8, href_path, "/"), '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (segments.items.len == 0) return null;
            _ = segments.pop();
            continue;
        }
        try segments.append(allocator, part);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (segments.items, 0..) |segment, index| {
        if (index != 0) try out.append(allocator, '/');
        try out.appendSlice(allocator, segment);
    }
    return try out.toOwnedSlice(allocator);
}

fn appendPathSegments(
    segments: *std.ArrayList([]const u8),
    allocator: Allocator,
    path: []const u8,
) !void {
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        try segments.append(allocator, part);
    }
}

fn percentDecodeUrlPath(allocator: Allocator, value: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        if (value[i] == '%') {
            if (i + 2 >= value.len) return error.InvalidUrlEncoding;
            const hi = hexValue(value[i + 1]) orelse return error.InvalidUrlEncoding;
            const lo = hexValue(value[i + 2]) orelse return error.InvalidUrlEncoding;
            try buf.append(allocator, (hi << 4) | lo);
            i += 2;
        } else {
            try buf.append(allocator, value[i]);
        }
    }

    return try buf.toOwnedSlice(allocator);
}

fn parentPath(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "";
    return path[0..slash];
}

fn baseName(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

fn isMarkdownPath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".md") or
        std.mem.endsWith(u8, path, ".markdown") or
        std.ascii.eqlIgnoreCase(baseName(path), "README");
}

fn isVideoHref(href: []const u8) bool {
    const path = hrefPathPart(href);
    return endsWithIgnoreCase(path, ".mp4") or
        endsWithIgnoreCase(path, ".m4v") or
        endsWithIgnoreCase(path, ".webm") or
        endsWithIgnoreCase(path, ".ogv") or
        endsWithIgnoreCase(path, ".ogg") or
        endsWithIgnoreCase(path, ".mov");
}

fn mediaContentTypeForHref(href: []const u8) ?[]const u8 {
    const path = hrefPathPart(href);
    if (endsWithIgnoreCase(path, ".mp4") or endsWithIgnoreCase(path, ".m4v")) return "video/mp4";
    if (endsWithIgnoreCase(path, ".webm")) return "video/webm";
    if (endsWithIgnoreCase(path, ".ogv") or endsWithIgnoreCase(path, ".ogg")) return "video/ogg";
    if (endsWithIgnoreCase(path, ".mov")) return "video/quicktime";
    if (endsWithIgnoreCase(path, ".svg")) return "image/svg+xml";
    if (endsWithIgnoreCase(path, ".jpg") or endsWithIgnoreCase(path, ".jpeg")) return "image/jpeg";
    if (endsWithIgnoreCase(path, ".png")) return "image/png";
    if (endsWithIgnoreCase(path, ".gif")) return "image/gif";
    if (endsWithIgnoreCase(path, ".webp")) return "image/webp";
    return null;
}

fn isFence(trimmed: []const u8) bool {
    return std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~");
}

fn fenceLanguage(trimmed: []const u8) []const u8 {
    if (trimmed.len <= 3) return "";
    var rest = std.mem.trim(u8, trimmed[3..], " \t");
    if (rest.len == 0) return "";
    const end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
    rest = rest[0..end];
    if (std.mem.eql(u8, rest, "zig")) return "zig";
    if (std.mem.eql(u8, rest, "js")) return "javascript";
    if (std.mem.eql(u8, rest, "javascript")) return "javascript";
    if (std.mem.eql(u8, rest, "ts")) return "typescript";
    if (std.mem.eql(u8, rest, "typescript")) return "typescript";
    if (std.mem.eql(u8, rest, "sh")) return "bash";
    if (std.mem.eql(u8, rest, "bash")) return "bash";
    if (std.mem.eql(u8, rest, "json")) return "json";
    if (std.mem.eql(u8, rest, "toml")) return "toml";
    if (std.mem.eql(u8, rest, "yaml")) return "yaml";
    if (std.mem.eql(u8, rest, "yml")) return "yaml";
    if (std.mem.eql(u8, rest, "css")) return "css";
    if (std.mem.eql(u8, rest, "html")) return "html";
    if (std.mem.eql(u8, rest, "xml")) return "xml";
    if (std.mem.eql(u8, rest, "sql")) return "sql";
    if (std.mem.eql(u8, rest, "sol")) return "solidity";
    if (std.mem.eql(u8, rest, "solidity")) return "solidity";
    if (std.mem.eql(u8, rest, "tla")) return "tla";
    if (std.mem.eql(u8, rest, "tla+")) return "tla";
    if (std.mem.eql(u8, rest, "tlaplus")) return "tla";
    if (std.mem.eql(u8, rest, "mermaid")) return "mermaid";
    if (std.mem.eql(u8, rest, "mmd")) return "mermaid";
    if (std.mem.eql(u8, rest, "rs")) return "rust";
    if (std.mem.eql(u8, rest, "rust")) return "rust";
    if (std.mem.eql(u8, rest, "py")) return "python";
    if (std.mem.eql(u8, rest, "python")) return "python";
    return "plaintext";
}

fn appendLanguageClass(buf: *std.ArrayList(u8), allocator: Allocator, language: []const u8) !void {
    if (language.len == 0) {
        try buf.appendSlice(allocator, "plaintext");
    } else {
        try appendHtml(buf, allocator, language);
    }
}

fn headingLevel(trimmed: []const u8) ?usize {
    var level: usize = 0;
    while (level < trimmed.len and level < 6 and trimmed[level] == '#') : (level += 1) {}
    if (level == 0 or level >= trimmed.len or trimmed[level] != ' ') return null;
    return level;
}

fn unorderedItem(trimmed: []const u8) ?[]const u8 {
    if (trimmed.len < 3) return null;
    if ((trimmed[0] == '-' or trimmed[0] == '*') and trimmed[1] == ' ') {
        return std.mem.trim(u8, trimmed[2..], " \t");
    }
    return null;
}

fn orderedItem(trimmed: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < trimmed.len and std.ascii.isDigit(trimmed[i])) : (i += 1) {}
    if (i == 0 or i + 1 >= trimmed.len) return null;
    if (trimmed[i] != '.' or trimmed[i + 1] != ' ') return null;
    return std.mem.trim(u8, trimmed[i + 2 ..], " \t");
}

fn isSafeHref(href: []const u8) bool {
    if (href.len == 0) return false;
    const lower_prefix_len = @min(href.len, 12);
    const prefix = href[0..lower_prefix_len];
    return !startsWithIgnoreCase(prefix, "javascript:") and
        !startsWithIgnoreCase(prefix, "data:");
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    if (value.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn endsWithIgnoreCase(value: []const u8, suffix: []const u8) bool {
    if (value.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(value[value.len - suffix.len ..], suffix);
}

fn hexValue(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

test "web markdown renderer handles preview blocks" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendMarkdown(
        &buf,
        std.testing.allocator,
        "# Title\n\nA **bold** [link](docs/readme.md) with $x^2$.\n\n| Name | Value |\n| --- | --- |\n| Alpha | **1** |\n\n$$\n\\frac{a}{b}\n$$\n\n```zig\nconst x = 1;\n```\n\n```solidity\ncontract Token {}\n```\n\n```tla\n---- MODULE Spec ----\n====\n```\n\n```mermaid\ngraph TD\nA[Start] --> B[Done]\n```\n",
    );
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<h1>Title</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<strong>bold</strong>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<a href=\"docs/readme.md\">link</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<table class=\"markdown-table\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "data-latex-inline") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "data-latex-display") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<pre><code class=\"language-zig\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<pre><code class=\"language-solidity\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<pre><code class=\"language-tla\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<pre class=\"mermaid-source\" data-mermaid><code>") != null);
}

test "web markdown renderer handles task list checkboxes" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendMarkdown(
        &buf,
        std.testing.allocator,
        "- [ ] `database.url` dedicated PostgreSQL 18+ instance\n- [x] done\n- [X] also done\n- [y] plain item\n1. [ ] ordered task\n",
    );
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<li class=\"task-list-item\"><input class=\"task-list-checkbox\" type=\"checkbox\" disabled> <code>database.url</code> dedicated PostgreSQL 18+ instance</li>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<li class=\"task-list-item\"><input class=\"task-list-checkbox\" type=\"checkbox\" disabled checked> done</li>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<li class=\"task-list-item\"><input class=\"task-list-checkbox\" type=\"checkbox\" disabled checked> also done</li>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<li>[y] plain item</li>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<ol><li class=\"task-list-item\"><input class=\"task-list-checkbox\" type=\"checkbox\" disabled> ordered task</li></ol>") != null);
}

test "web markdown renderer rewrites repository relative links" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendMarkdownWithOptions(
        &buf,
        std.testing.allocator,
        "[peer](guide.md) [parent](../README.md#intro) [root](/spec/01_PRODUCT.md) [space](My%20File.md) [anchor](#local) [external](https://example.com/x)",
        .{
            .link_context = .{
                .ref = "feature/test",
                .current_path = "docs/intro.md",
            },
        },
    );
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<a href=\"/code?ref=feature/test&path=docs/guide.md&view=preview\">peer</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<a href=\"/code?ref=feature/test&path=README.md&view=preview#intro\">parent</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<a href=\"/code?ref=feature/test&path=spec/01_PRODUCT.md&view=preview\">root</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<a href=\"/code?ref=feature/test&path=docs/My%20File.md&view=preview\">space</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<a href=\"#local\">anchor</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<a href=\"https://example.com/x\">external</a>") != null);
}

test "web markdown renderer embeds repository relative media" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendMarkdownWithOptions(
        &buf,
        std.testing.allocator,
        "![Diagram](../assets/diagram.svg)\n\n![Clip](media/clip.mp4)\n\n![Remote](https://example.com/demo.webp)",
        .{
            .link_context = .{
                .ref = "feature/test",
                .current_path = "docs/intro.md",
            },
        },
    );
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<img class=\"markdown-media\" src=\"/raw?ref=feature/test&path=assets/diagram.svg\" alt=\"Diagram\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<video class=\"markdown-media\" controls preload=\"metadata\"><source src=\"/raw?ref=feature/test&path=docs/media/clip.mp4\" type=\"video/mp4\">Clip</video>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<img class=\"markdown-media\" src=\"https://example.com/demo.webp\" alt=\"Remote\">") != null);
}
