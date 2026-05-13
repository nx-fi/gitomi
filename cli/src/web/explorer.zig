const std = @import("std");
const git = @import("../git.zig");
const repo_mod = @import("../repo.zig");
const shared = @import("shared.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const appendEmptyState = shared.appendEmptyState;
const appendFmt = shared.appendFmt;
const appendHtml = shared.appendHtml;
const appendShellEnd = shared.appendShellEnd;
const appendShellStart = shared.appendShellStart;
const runCommand = git.runCommand;

const max_blob_display_bytes = 512 * 1024;
const max_tree_sidebar_entries = 600;

const TreeEntry = struct {
    mode: []u8,
    kind: []u8,
    oid: []u8,
    size: []u8,
    name: []u8,

    fn deinit(self: TreeEntry, allocator: Allocator) void {
        allocator.free(self.mode);
        allocator.free(self.kind);
        allocator.free(self.oid);
        allocator.free(self.size);
        allocator.free(self.name);
    }
};

const TreeNavEntry = struct {
    kind: []u8,
    path: []u8,

    fn deinit(self: TreeNavEntry, allocator: Allocator) void {
        allocator.free(self.kind);
        allocator.free(self.path);
    }
};

const CommitSummary = struct {
    full_hash: []u8,
    hash: []u8,
    subject: []u8,
    relative: []u8,

    fn deinit(self: CommitSummary, allocator: Allocator) void {
        allocator.free(self.full_hash);
        allocator.free(self.hash);
        allocator.free(self.subject);
        allocator.free(self.relative);
    }
};

pub fn renderCodePage(allocator: Allocator, repo: Repo, target: []const u8) ![]u8 {
    const query_ref = try queryValueOwned(allocator, target, "ref");
    defer if (query_ref) |value| allocator.free(value);
    const query_path = try queryValueOwned(allocator, target, "path");
    defer if (query_path) |value| allocator.free(value);

    const default_ref = try defaultRef(allocator, repo);
    defer allocator.free(default_ref);
    const ref = if (query_ref) |value| blk: {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        break :blk if (trimmed.len == 0) default_ref else trimmed;
    } else default_ref;

    const path = if (query_path) |value|
        normalizedPathOwned(allocator, value) catch return renderMissingPathPage(allocator, repo, ref, value)
    else
        try allocator.dupe(u8, "");
    defer allocator.free(path);

    if (path.len == 0) {
        return renderTreePage(allocator, repo, ref, path);
    }

    const spec = try objectSpec(allocator, ref, path);
    defer allocator.free(spec);
    const kind_owned = try objectType(allocator, repo, spec);
    defer if (kind_owned) |kind| allocator.free(kind);
    const kind = kind_owned orelse return renderMissingPathPage(allocator, repo, ref, path);

    if (std.mem.eql(u8, kind, "blob")) {
        return renderBlobPage(allocator, repo, ref, path, spec);
    }
    if (std.mem.eql(u8, kind, "tree")) {
        return renderTreePage(allocator, repo, ref, path);
    }
    return renderMissingPathPage(allocator, repo, ref, path);
}

fn renderTreePage(allocator: Allocator, repo: Repo, ref: []const u8, path: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "Code", "code");
    try appendRepoHeader(&buf, allocator, repo, ref);
    try appendCodeLayoutStart(&buf, allocator, repo, ref, path);

    const entries_opt = try loadTreeEntries(allocator, repo, ref, path);
    if (entries_opt) |entries| {
        defer freeTreeEntries(allocator, entries);
        const summary_opt = try loadCommitSummary(allocator, repo, ref, path);
        defer if (summary_opt) |summary| summary.deinit(allocator);

        try buf.appendSlice(allocator,
            \\<section class="panel code-panel">
            \\  <div class="code-toolbar">
            \\    <div>
        );
        try appendBreadcrumbs(&buf, allocator, repo, ref, path);
        try buf.appendSlice(allocator,
            \\    </div><div class="file-actions"><a class="button secondary" href="
        );
        try appendCommitsHref(&buf, allocator, ref, path);
        try buf.appendSlice(allocator, "\">History</a></div></div>");
        try appendCommitBar(&buf, allocator, summary_opt);
        try appendTreeListing(&buf, allocator, ref, path, entries);
        try buf.appendSlice(allocator, "</section>");

        try appendReadmePreview(&buf, allocator, repo, ref, path, entries);
    } else {
        try appendEmptyState(&buf, allocator, "No committed files found.", "The selected ref does not point at a readable tree yet.");
    }

    try appendCodeLayoutEnd(&buf, allocator);
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn renderBlobPage(allocator: Allocator, repo: Repo, ref: []const u8, path: []const u8, spec: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "Code", "code");
    try appendRepoHeader(&buf, allocator, repo, ref);
    try appendCodeLayoutStart(&buf, allocator, repo, ref, path);

    const size = try blobSize(allocator, repo, spec);
    const content = if (size != null and size.? <= max_blob_display_bytes)
        try gitMaybe(allocator, repo, &.{ "show", spec }, max_blob_display_bytes + 1)
    else
        null;
    defer if (content) |bytes| allocator.free(bytes);

    try buf.appendSlice(allocator,
        \\<section class="panel code-panel">
        \\  <div class="code-toolbar">
        \\    <div>
    );
    try appendBreadcrumbs(&buf, allocator, repo, ref, path);
    try buf.appendSlice(allocator, "</div><div class=\"file-actions\">");
    if (size) |bytes| try appendFmt(&buf, allocator, "{d} bytes", .{bytes});
    try buf.appendSlice(allocator, "<a class=\"button secondary\" href=\"");
    try appendCommitsHref(&buf, allocator, ref, path);
    try buf.appendSlice(allocator, "\">History</a></div></div>");

    if (content) |bytes| {
        if (containsNul(bytes)) {
            try appendEmptyState(&buf, allocator, "Binary file not displayed.", "This blob contains NUL bytes.");
        } else {
            try appendBlobLines(&buf, allocator, path, bytes);
        }
    } else {
        try appendEmptyState(&buf, allocator, "File too large to display.", "Use Git locally to inspect this blob.");
    }

    try buf.appendSlice(allocator, "</section>");
    try appendCodeLayoutEnd(&buf, allocator);
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn renderMissingPathPage(allocator: Allocator, repo: Repo, ref: []const u8, path: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "Code", "code");
    try appendRepoHeader(&buf, allocator, repo, ref);
    try appendCodeLayoutStart(&buf, allocator, repo, ref, path);
    try appendEmptyState(&buf, allocator, "Path not found.", path);
    try appendCodeLayoutEnd(&buf, allocator);
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn appendRepoHeader(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, ref: []const u8) !void {
    try buf.appendSlice(allocator,
        \\<section class="repo-head">
        \\  <div>
        \\    <p class="eyebrow">Repository</p>
        \\    <h1>
    );
    try appendHtml(buf, allocator, std.fs.path.basename(repo.root));
    try buf.appendSlice(allocator,
        \\</h1>
        \\  </div>
        \\  <div class="repo-actions">
        \\    <span class="branch-pill">
    );
    try appendHtml(buf, allocator, ref);
    try buf.appendSlice(allocator,
        \\</span>
        \\    <a class="button secondary" href="/commits">Commits</a>
        \\    <a class="button secondary" href="/overview">Overview</a>
        \\  </div>
        \\</section>
    );
}

fn appendCodeLayoutStart(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, ref: []const u8, active_path: []const u8) !void {
    try buf.appendSlice(allocator, "<div class=\"code-layout\">");
    try appendTreeSidebar(buf, allocator, repo, ref, active_path);
    try buf.appendSlice(allocator, "<div class=\"code-main\">");
}

fn appendCodeLayoutEnd(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator, "</div></div>");
}

fn appendTreeSidebar(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, ref: []const u8, active_path: []const u8) !void {
    const entries_opt = try loadTreeNavEntries(allocator, repo, ref);
    defer if (entries_opt) |entries| freeTreeNavEntries(allocator, entries);

    try buf.appendSlice(allocator,
        \\<aside class="panel tree-sidebar">
        \\  <div class="tree-sidebar-head">Files</div>
        \\  <nav class="tree-nav">
        \\    <a class="tree-link
    );
    if (active_path.len == 0) try buf.appendSlice(allocator, " active");
    try buf.appendSlice(allocator, "\" style=\"--depth: 0\" href=\"");
    try appendCodeHref(buf, allocator, ref, "");
    try buf.appendSlice(allocator, "\"><span class=\"file-icon dir\" aria-hidden=\"true\"></span><span class=\"tree-name\">");
    try appendHtml(buf, allocator, std.fs.path.basename(repo.root));
    try buf.appendSlice(allocator, "</span></a>");

    if (entries_opt) |entries| {
        for (entries) |entry| {
            const depth = pathDepth(entry.path) + 1;
            const active = std.mem.eql(u8, active_path, entry.path);
            const ancestor = std.mem.eql(u8, entry.kind, "tree") and isAncestorPath(entry.path, active_path);

            try buf.appendSlice(allocator, "<a class=\"tree-link");
            if (active) try buf.appendSlice(allocator, " active");
            if (ancestor) try buf.appendSlice(allocator, " ancestor");
            try buf.appendSlice(allocator, "\" style=\"--depth: ");
            try appendFmt(buf, allocator, "{d}", .{depth});
            try buf.appendSlice(allocator, "\" href=\"");
            try appendCodeHref(buf, allocator, ref, entry.path);
            try buf.appendSlice(allocator, "\"><span class=\"file-icon ");
            try appendHtml(buf, allocator, if (std.mem.eql(u8, entry.kind, "tree")) "dir" else "file");
            try buf.appendSlice(allocator, "\" aria-hidden=\"true\"></span><span class=\"tree-name\">");
            try appendHtml(buf, allocator, baseName(entry.path));
            try buf.appendSlice(allocator, "</span></a>");
        }

        if (entries.len == max_tree_sidebar_entries) {
            try buf.appendSlice(allocator, "<p class=\"tree-note\">Tree truncated.</p>");
        }
    } else {
        try buf.appendSlice(allocator, "<p class=\"tree-note\">No files to show.</p>");
    }

    try buf.appendSlice(allocator, "</nav></aside>");
}

fn appendTreeListing(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    ref: []const u8,
    path: []const u8,
    entries: []const TreeEntry,
) !void {
    try buf.appendSlice(allocator,
        \\<div class="file-list">
        \\  <div class="file-row file-row-head"><span>Name</span><span>Mode</span><span>Size</span></div>
    );

    if (path.len != 0) {
        try buf.appendSlice(allocator, "<div class=\"file-row\"><a class=\"file-name\" href=\"");
        try appendCodeHref(buf, allocator, ref, parentPath(path));
        try buf.appendSlice(allocator, "\"><span class=\"file-icon dir\" aria-hidden=\"true\"></span>..</a><span></span><span></span></div>");
    }

    for (entries) |entry| {
        const child_path = try childPath(allocator, path, entry.name);
        defer allocator.free(child_path);

        try buf.appendSlice(allocator, "<div class=\"file-row\"><a class=\"file-name\" href=\"");
        try appendCodeHref(buf, allocator, ref, child_path);
        try buf.appendSlice(allocator, "\"><span class=\"file-icon ");
        try appendHtml(buf, allocator, if (std.mem.eql(u8, entry.kind, "tree")) "dir" else "file");
        try buf.appendSlice(allocator, "\" aria-hidden=\"true\"></span>");
        try appendHtml(buf, allocator, entry.name);
        try buf.appendSlice(allocator, "</a><span><code>");
        try appendHtml(buf, allocator, entry.mode);
        try buf.appendSlice(allocator, "</code></span><span class=\"file-size\">");
        if (std.mem.eql(u8, entry.kind, "blob")) {
            try appendSize(buf, allocator, entry.size);
        }
        try buf.appendSlice(allocator, "</span></div>");
    }

    if (entries.len == 0) {
        try appendEmptyState(buf, allocator, "Empty directory.", "This tree has no entries.");
    }

    try buf.appendSlice(allocator, "</div>");
}

fn appendCommitBar(buf: *std.ArrayList(u8), allocator: Allocator, summary_opt: ?CommitSummary) !void {
    try buf.appendSlice(allocator, "<div class=\"commit-bar\">");
    if (summary_opt) |summary| {
        try buf.appendSlice(allocator, "<a class=\"commit-hash\" href=\"");
        try appendCommitHref(buf, allocator, summary.full_hash);
        try buf.appendSlice(allocator, "\"><code>");
        try appendHtml(buf, allocator, summary.hash);
        try buf.appendSlice(allocator, "</code></a><strong><a href=\"");
        try appendCommitHref(buf, allocator, summary.full_hash);
        try buf.appendSlice(allocator, "\">");
        try appendHtml(buf, allocator, summary.subject);
        try buf.appendSlice(allocator, "</a></strong><span>");
        try appendHtml(buf, allocator, summary.relative);
        try buf.appendSlice(allocator, "</span>");
    } else {
        try buf.appendSlice(allocator, "<strong>No commits yet</strong><span>This ref has no history to summarize.</span>");
    }
    try buf.appendSlice(allocator, "</div>");
}

fn appendBreadcrumbs(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, ref: []const u8, path: []const u8) !void {
    try buf.appendSlice(allocator, "<nav class=\"breadcrumbs\"><a href=\"");
    try appendCodeHref(buf, allocator, ref, "");
    try buf.appendSlice(allocator, "\">");
    try appendHtml(buf, allocator, std.fs.path.basename(repo.root));
    try buf.appendSlice(allocator, "</a>");

    if (path.len != 0) {
        var built: std.ArrayList(u8) = .empty;
        defer built.deinit(allocator);
        var parts = std.mem.splitScalar(u8, path, '/');
        while (parts.next()) |part| {
            if (part.len == 0) continue;
            if (built.items.len != 0) try built.append(allocator, '/');
            try built.appendSlice(allocator, part);
            try buf.appendSlice(allocator, "<span>/</span>");
            if (built.items.len == path.len) {
                try buf.appendSlice(allocator, "<strong>");
                try appendHtml(buf, allocator, part);
                try buf.appendSlice(allocator, "</strong>");
            } else {
                try buf.appendSlice(allocator, "<a href=\"");
                try appendCodeHref(buf, allocator, ref, built.items);
                try buf.appendSlice(allocator, "\">");
                try appendHtml(buf, allocator, part);
                try buf.appendSlice(allocator, "</a>");
            }
        }
    }

    try buf.appendSlice(allocator, "</nav>");
}

fn appendBlobLines(buf: *std.ArrayList(u8), allocator: Allocator, path: []const u8, content: []const u8) !void {
    const language = languageForPath(path);
    try buf.appendSlice(allocator, "<ol class=\"blob-lines\">");
    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_no: usize = 1;
    while (lines.next()) |line| : (line_no += 1) {
        try buf.appendSlice(allocator, "<li id=\"L");
        try appendFmt(buf, allocator, "{d}", .{line_no});
        try buf.appendSlice(allocator, "\"><a class=\"line-num\" href=\"#L");
        try appendFmt(buf, allocator, "{d}", .{line_no});
        try buf.appendSlice(allocator, "\">");
        try appendFmt(buf, allocator, "{d}", .{line_no});
        try buf.appendSlice(allocator, "</a><code class=\"language-");
        try appendHtml(buf, allocator, language);
        try buf.appendSlice(allocator, "\">");
        try appendHtml(buf, allocator, line);
        try buf.appendSlice(allocator, "</code></li>");
    }
    if (content.len == 0) {
        try buf.appendSlice(allocator, "<li id=\"L1\"><a class=\"line-num\" href=\"#L1\">1</a><code class=\"language-");
        try appendHtml(buf, allocator, language);
        try buf.appendSlice(allocator, "\"></code></li>");
    }
    try buf.appendSlice(allocator, "</ol>");
}

fn appendReadmePreview(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    repo: Repo,
    ref: []const u8,
    path: []const u8,
    entries: []const TreeEntry,
) !void {
    const readme = findReadme(entries) orelse return;
    const readme_path = try childPath(allocator, path, readme);
    defer allocator.free(readme_path);
    const spec = try objectSpec(allocator, ref, readme_path);
    defer allocator.free(spec);
    const content = try gitMaybe(allocator, repo, &.{ "show", spec }, max_blob_display_bytes + 1) orelse return;
    defer allocator.free(content);
    if (containsNul(content)) return;

    try buf.appendSlice(allocator,
        \\<section class="panel readme-panel">
        \\  <div class="section-head"><h2>
    );
    try appendHtml(buf, allocator, readme);
    try buf.appendSlice(allocator, "</h2></div><div class=\"readme-body markdown-body\">");
    try appendMarkdown(buf, allocator, content);
    try buf.appendSlice(allocator, "</div></section>");
}

const MarkdownState = struct {
    paragraph_open: bool = false,
    ul_open: bool = false,
    ol_open: bool = false,
    code_open: bool = false,
};

fn appendMarkdown(buf: *std.ArrayList(u8), allocator: Allocator, markdown: []const u8) !void {
    var state = MarkdownState{};
    var lines = std.mem.splitScalar(u8, markdown, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");

        if (state.code_open) {
            if (isFence(trimmed)) {
                try buf.appendSlice(allocator, "</code></pre>");
                state.code_open = false;
            } else {
                try appendHtml(buf, allocator, line);
                try buf.append(allocator, '\n');
            }
            continue;
        }

        if (isFence(trimmed)) {
            try closeMarkdownFlow(buf, allocator, &state);
            const language = fenceLanguage(trimmed);
            try buf.appendSlice(allocator, "<pre><code class=\"language-");
            try appendLanguageClass(buf, allocator, language);
            try buf.appendSlice(allocator, "\">");
            state.code_open = true;
            continue;
        }

        if (trimmed.len == 0) {
            try closeMarkdownFlow(buf, allocator, &state);
            continue;
        }

        if (headingLevel(trimmed)) |level| {
            try closeMarkdownFlow(buf, allocator, &state);
            const content = std.mem.trim(u8, trimmed[level + 1 ..], " \t");
            try appendFmt(buf, allocator, "<h{d}>", .{level});
            try appendInlineMarkdown(buf, allocator, content);
            try appendFmt(buf, allocator, "</h{d}>", .{level});
            continue;
        }

        if (std.mem.eql(u8, trimmed, "---") or std.mem.eql(u8, trimmed, "***")) {
            try closeMarkdownFlow(buf, allocator, &state);
            try buf.appendSlice(allocator, "<hr>");
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, ">")) {
            try closeMarkdownFlow(buf, allocator, &state);
            const quote = std.mem.trim(u8, trimmed[1..], " \t");
            try buf.appendSlice(allocator, "<blockquote><p>");
            try appendInlineMarkdown(buf, allocator, quote);
            try buf.appendSlice(allocator, "</p></blockquote>");
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
    }

    if (state.code_open) {
        try buf.appendSlice(allocator, "</code></pre>");
        state.code_open = false;
    }
    try closeMarkdownFlow(buf, allocator, &state);
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

fn loadTreeEntries(allocator: Allocator, repo: Repo, ref: []const u8, path: []const u8) !?[]TreeEntry {
    const spec = try objectSpec(allocator, ref, path);
    defer allocator.free(spec);
    const raw = try gitMaybe(allocator, repo, &.{ "ls-tree", "-z", "-l", spec }, git.max_git_output) orelse return null;
    defer allocator.free(raw);

    var entries: std.ArrayList(TreeEntry) = .empty;
    errdefer {
        for (entries.items) |entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }

    var records = std.mem.splitScalar(u8, raw, 0);
    while (records.next()) |record| {
        if (record.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, record, '\t') orelse continue;
        const meta = record[0..tab];
        const name = record[tab + 1 ..];
        var fields = std.mem.tokenizeScalar(u8, meta, ' ');
        const mode = fields.next() orelse continue;
        const kind = fields.next() orelse continue;
        const oid = fields.next() orelse continue;
        const size = fields.next() orelse "";
        try entries.append(allocator, .{
            .mode = try allocator.dupe(u8, mode),
            .kind = try allocator.dupe(u8, kind),
            .oid = try allocator.dupe(u8, oid),
            .size = try allocator.dupe(u8, size),
            .name = try allocator.dupe(u8, name),
        });
    }

    return try entries.toOwnedSlice(allocator);
}

fn loadCommitSummary(allocator: Allocator, repo: Repo, ref: []const u8, path: []const u8) !?CommitSummary {
    const format = "--format=%H%x09%h%x09%s%x09%cr";
    const raw = if (path.len == 0)
        try gitMaybe(allocator, repo, &.{ "log", "-1", format, ref }, 1024 * 1024)
    else blk: {
        const pathspec = try std.fmt.allocPrint(allocator, ":(top){s}", .{path});
        defer allocator.free(pathspec);
        break :blk try gitMaybe(allocator, repo, &.{ "log", "-1", format, ref, "--", pathspec }, 1024 * 1024);
    };
    const text = raw orelse return null;
    defer allocator.free(text);

    const line = std.mem.trim(u8, text, " \t\r\n");
    if (line.len == 0) return null;
    var cols = std.mem.splitScalar(u8, line, '\t');
    return .{
        .full_hash = try allocator.dupe(u8, cols.next() orelse ""),
        .hash = try allocator.dupe(u8, cols.next() orelse ""),
        .subject = try allocator.dupe(u8, cols.next() orelse ""),
        .relative = try allocator.dupe(u8, cols.next() orelse ""),
    };
}

fn loadTreeNavEntries(allocator: Allocator, repo: Repo, ref: []const u8) !?[]TreeNavEntry {
    const raw = try gitMaybe(allocator, repo, &.{ "ls-tree", "-z", "-r", "-t", ref }, git.max_git_output) orelse return null;
    defer allocator.free(raw);

    var entries: std.ArrayList(TreeNavEntry) = .empty;
    errdefer {
        for (entries.items) |entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }

    var records = std.mem.splitScalar(u8, raw, 0);
    while (records.next()) |record| {
        if (record.len == 0) continue;
        if (entries.items.len >= max_tree_sidebar_entries) break;
        const tab = std.mem.indexOfScalar(u8, record, '\t') orelse continue;
        const meta = record[0..tab];
        const path = record[tab + 1 ..];
        var fields = std.mem.tokenizeScalar(u8, meta, ' ');
        _ = fields.next() orelse continue;
        const kind = fields.next() orelse continue;
        try entries.append(allocator, .{
            .kind = try allocator.dupe(u8, kind),
            .path = try allocator.dupe(u8, path),
        });
    }

    return try entries.toOwnedSlice(allocator);
}

fn objectType(allocator: Allocator, repo: Repo, spec: []const u8) !?[]u8 {
    const raw = try gitMaybe(allocator, repo, &.{ "cat-file", "-t", spec }, 1024) orelse return null;
    return try trimOwned(allocator, raw);
}

fn blobSize(allocator: Allocator, repo: Repo, spec: []const u8) !?usize {
    const raw = try gitMaybe(allocator, repo, &.{ "cat-file", "-s", spec }, 1024) orelse return null;
    defer allocator.free(raw);
    const text = std.mem.trim(u8, raw, " \t\r\n");
    if (text.len == 0) return null;
    return std.fmt.parseUnsigned(usize, text, 10) catch null;
}

fn defaultRef(allocator: Allocator, repo: Repo) ![]u8 {
    const branch_raw = try gitMaybe(allocator, repo, &.{ "branch", "--show-current" }, 512 * 1024);
    if (branch_raw) |raw| {
        defer allocator.free(raw);
        const branch = std.mem.trim(u8, raw, " \t\r\n");
        if (branch.len != 0) return allocator.dupe(u8, branch);
    }
    return allocator.dupe(u8, "HEAD");
}

fn objectSpec(allocator: Allocator, ref: []const u8, path: []const u8) ![]u8 {
    if (path.len == 0) return allocator.dupe(u8, ref);
    return std.fmt.allocPrint(allocator, "{s}:{s}", .{ ref, path });
}

fn childPath(allocator: Allocator, parent: []const u8, name: []const u8) ![]u8 {
    if (parent.len == 0) return allocator.dupe(u8, name);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent, name });
}

fn parentPath(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "";
    return path[0..slash];
}

fn baseName(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

fn pathDepth(path: []const u8) usize {
    var depth: usize = 0;
    for (path) |c| {
        if (c == '/') depth += 1;
    }
    return depth;
}

fn isAncestorPath(parent: []const u8, path: []const u8) bool {
    if (parent.len == 0 or path.len <= parent.len) return false;
    return std.mem.startsWith(u8, path, parent) and path[parent.len] == '/';
}

fn findReadme(entries: []const TreeEntry) ?[]const u8 {
    const names = [_][]const u8{ "README.md", "README", "Readme.md", "readme.md" };
    for (names) |wanted| {
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.kind, "blob") and std.mem.eql(u8, entry.name, wanted)) return entry.name;
        }
    }
    return null;
}

fn languageForPath(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".zig")) return "zig";
    if (std.mem.endsWith(u8, path, ".js")) return "javascript";
    if (std.mem.endsWith(u8, path, ".mjs")) return "javascript";
    if (std.mem.endsWith(u8, path, ".ts")) return "typescript";
    if (std.mem.endsWith(u8, path, ".sh")) return "bash";
    if (std.mem.endsWith(u8, path, ".bash")) return "bash";
    if (std.mem.endsWith(u8, path, ".json")) return "json";
    if (std.mem.endsWith(u8, path, ".toml")) return "toml";
    if (std.mem.endsWith(u8, path, ".yaml")) return "yaml";
    if (std.mem.endsWith(u8, path, ".yml")) return "yaml";
    if (std.mem.endsWith(u8, path, ".css")) return "css";
    if (std.mem.endsWith(u8, path, ".html")) return "html";
    if (std.mem.endsWith(u8, path, ".xml")) return "xml";
    if (std.mem.endsWith(u8, path, ".sql")) return "sql";
    if (std.mem.endsWith(u8, path, ".rs")) return "rust";
    if (std.mem.endsWith(u8, path, ".py")) return "python";
    if (std.mem.endsWith(u8, path, ".md")) return "markdown";
    if (std.mem.endsWith(u8, path, "Makefile")) return "bash";
    return "plaintext";
}

fn normalizedPathOwned(allocator: Allocator, raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n/");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var parts = std.mem.splitScalar(u8, trimmed, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) return error.InvalidPath;
        if (out.items.len != 0) try out.append(allocator, '/');
        try out.appendSlice(allocator, part);
    }
    return out.toOwnedSlice(allocator);
}

fn queryValueOwned(allocator: Allocator, target: []const u8, wanted_key: []const u8) !?[]u8 {
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var pairs = std.mem.splitScalar(u8, target[query_start + 1 ..], '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const raw_key = pair[0..eq];
        const raw_value = if (eq < pair.len) pair[eq + 1 ..] else "";
        const key = try percentDecode(allocator, raw_key);
        defer allocator.free(key);
        if (!std.mem.eql(u8, key, wanted_key)) continue;
        return try percentDecode(allocator, raw_value);
    }
    return null;
}

fn percentDecode(allocator: Allocator, value: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        switch (value[i]) {
            '+' => try buf.append(allocator, ' '),
            '%' => {
                if (i + 2 >= value.len) return error.InvalidUrlEncoding;
                const hi = hexValue(value[i + 1]) orelse return error.InvalidUrlEncoding;
                const lo = hexValue(value[i + 2]) orelse return error.InvalidUrlEncoding;
                try buf.append(allocator, (hi << 4) | lo);
                i += 2;
            },
            else => |c| try buf.append(allocator, c),
        }
    }

    return buf.toOwnedSlice(allocator);
}

fn appendCodeHref(buf: *std.ArrayList(u8), allocator: Allocator, ref: []const u8, path: []const u8) !void {
    try buf.appendSlice(allocator, "/code?ref=");
    try appendUrlEncoded(buf, allocator, ref);
    if (path.len != 0) {
        try buf.appendSlice(allocator, "&path=");
        try appendUrlEncoded(buf, allocator, path);
    }
}

fn appendCommitsHref(buf: *std.ArrayList(u8), allocator: Allocator, ref: []const u8, path: []const u8) !void {
    try buf.appendSlice(allocator, "/commits?ref=");
    try appendUrlEncoded(buf, allocator, ref);
    if (path.len != 0) {
        try buf.appendSlice(allocator, "&path=");
        try appendUrlEncoded(buf, allocator, path);
    }
}

fn appendCommitHref(buf: *std.ArrayList(u8), allocator: Allocator, hash: []const u8) !void {
    try buf.appendSlice(allocator, "/commit?sha=");
    try appendUrlEncoded(buf, allocator, hash);
}

fn appendUrlEncoded(buf: *std.ArrayList(u8), allocator: Allocator, value: []const u8) !void {
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

fn appendSize(buf: *std.ArrayList(u8), allocator: Allocator, raw: []const u8) !void {
    const size = std.fmt.parseUnsigned(usize, raw, 10) catch {
        try appendHtml(buf, allocator, raw);
        return;
    };
    if (size >= 1024 * 1024) {
        const whole = size / (1024 * 1024);
        const tenth = (size % (1024 * 1024)) * 10 / (1024 * 1024);
        try appendFmt(buf, allocator, "{d}.{d} MB", .{ whole, tenth });
    } else if (size >= 1024) {
        const whole = size / 1024;
        const tenth = (size % 1024) * 10 / 1024;
        try appendFmt(buf, allocator, "{d}.{d} KB", .{ whole, tenth });
    } else {
        try appendFmt(buf, allocator, "{d} B", .{size});
    }
}

fn containsNul(bytes: []const u8) bool {
    return std.mem.indexOfScalar(u8, bytes, 0) != null;
}

fn trimOwned(allocator: Allocator, raw: []u8) ![]u8 {
    defer allocator.free(raw);
    return allocator.dupe(u8, std.mem.trim(u8, raw, " \t\r\n"));
}

fn freeTreeEntries(allocator: Allocator, entries: []TreeEntry) void {
    for (entries) |entry| entry.deinit(allocator);
    allocator.free(entries);
}

fn freeTreeNavEntries(allocator: Allocator, entries: []TreeNavEntry) void {
    for (entries) |entry| entry.deinit(allocator);
    allocator.free(entries);
}

fn gitMaybe(allocator: Allocator, repo: Repo, git_args: []const []const u8, max_output_bytes: usize) !?[]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    try argv.append(allocator, "-C");
    try argv.append(allocator, repo.root);
    for (git_args) |arg| try argv.append(allocator, arg);

    var result = try runCommand(allocator, argv.items, null, max_output_bytes);
    if (result.exitCode() == 0) {
        const stdout = result.stdout;
        allocator.free(result.stderr);
        return stdout;
    }

    result.deinit();
    return null;
}

fn hexValue(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

test "web explorer normalizes paths" {
    const path = try normalizedPathOwned(std.testing.allocator, "/src//main.zig/");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("src/main.zig", path);
    try std.testing.expectError(error.InvalidPath, normalizedPathOwned(std.testing.allocator, "../secret"));
}

test "web explorer encodes code links" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendCodeHref(&buf, std.testing.allocator, "feature/test", "src/a b.zig");
    try std.testing.expectEqualStrings("/code?ref=feature/test&path=src/a%20b.zig", buf.items);
}

test "web explorer renders markdown preview blocks" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendMarkdown(
        &buf,
        std.testing.allocator,
        "# Title\n\nA **bold** [link](docs/readme.md).\n\n```zig\nconst x = 1;\n```\n",
    );
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<h1>Title</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<strong>bold</strong>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<a href=\"docs/readme.md\">link</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<pre><code class=\"language-zig\">") != null);
}

test "web explorer maps file paths to highlight languages" {
    try std.testing.expectEqualStrings("zig", languageForPath("src/main.zig"));
    try std.testing.expectEqualStrings("markdown", languageForPath("README.md"));
    try std.testing.expectEqualStrings("plaintext", languageForPath("LICENSE"));
}
