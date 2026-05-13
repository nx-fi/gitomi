const std = @import("std");

const shared = @import("shared.zig");

const Allocator = std.mem.Allocator;
const appendFmt = shared.appendFmt;
const appendHtml = shared.appendHtml;

const MarkdownState = struct {
    paragraph_open: bool = false,
    ul_open: bool = false,
    ol_open: bool = false,
    code_open: bool = false,
};

pub fn appendMarkdown(buf: *std.ArrayList(u8), allocator: Allocator, markdown: []const u8) !void {
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
            line_index = try appendMarkdownTable(buf, allocator, markdown_lines.items, line_index);
            continue;
        }

        if (headingLevel(trimmed)) |level| {
            try closeMarkdownFlow(buf, allocator, &state);
            const content = std.mem.trim(u8, trimmed[level + 1 ..], " \t");
            try appendFmt(buf, allocator, "<h{d}>", .{level});
            try appendInlineMarkdown(buf, allocator, content);
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
            try appendInlineMarkdown(buf, allocator, quote);
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
            try buf.appendSlice(allocator, "<li>");
            try appendInlineMarkdown(buf, allocator, item);
            try buf.appendSlice(allocator, "</li>");
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
            try buf.appendSlice(allocator, "<li>");
            try appendInlineMarkdown(buf, allocator, item);
            try buf.appendSlice(allocator, "</li>");
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
        try appendInlineMarkdown(buf, allocator, trimmed);
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
) !usize {
    try buf.appendSlice(allocator, "<div class=\"table-wrap markdown-table-wrap\"><table class=\"markdown-table\"><thead>");
    try appendMarkdownTableRow(buf, allocator, lines[start], "th");
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
        try appendMarkdownTableRow(buf, allocator, trimmed, "td");
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
) !void {
    try buf.appendSlice(allocator, "<tr>");
    var cells = std.mem.splitScalar(u8, trimTablePipes(row), '|');
    while (cells.next()) |raw_cell| {
        const cell = std.mem.trim(u8, raw_cell, " \t");
        try buf.append(allocator, '<');
        try buf.appendSlice(allocator, tag);
        try buf.append(allocator, '>');
        try appendInlineMarkdown(buf, allocator, cell);
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

fn appendInlineMarkdown(buf: *std.ArrayList(u8), allocator: Allocator, value: []const u8) !void {
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
                try appendInlineMarkdown(buf, allocator, value[i + 2 .. end]);
                try buf.appendSlice(allocator, "</strong>");
                i = end + 2;
                continue;
            }
        }

        if (value[i] == '[') {
            if (std.mem.indexOfScalarPos(u8, value, i + 1, ']')) |label_end| {
                if (label_end + 1 < value.len and value[label_end + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, value, label_end + 2, ')')) |href_end| {
                        const href = std.mem.trim(u8, value[label_end + 2 .. href_end], " \t");
                        if (isSafeHref(href)) {
                            try buf.appendSlice(allocator, "<a href=\"");
                            try appendHtml(buf, allocator, href);
                            try buf.appendSlice(allocator, "\">");
                            try appendInlineMarkdown(buf, allocator, value[i + 1 .. label_end]);
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

test "web markdown renderer handles preview blocks" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendMarkdown(
        &buf,
        std.testing.allocator,
        "# Title\n\nA **bold** [link](docs/readme.md) with $x^2$.\n\n| Name | Value |\n| --- | --- |\n| Alpha | **1** |\n\n$$\n\\frac{a}{b}\n$$\n\n```zig\nconst x = 1;\n```\n\n```mermaid\ngraph TD\nA[Start] --> B[Done]\n```\n",
    );
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<h1>Title</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<strong>bold</strong>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<a href=\"docs/readme.md\">link</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<table class=\"markdown-table\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "data-latex-inline") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "data-latex-display") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<pre><code class=\"language-zig\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<pre class=\"mermaid-source\" data-mermaid><code>") != null);
}
