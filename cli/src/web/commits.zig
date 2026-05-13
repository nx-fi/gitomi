const std = @import("std");
const git = @import("../git.zig");
const repo_mod = @import("../repo.zig");
const shared = @import("shared.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const appendEmptyState = shared.appendEmptyState;
const appendHtml = shared.appendHtml;
const appendShellEnd = shared.appendShellEnd;
const appendShellStart = shared.appendShellStart;
const runCommand = git.runCommand;

const max_commit_diff_bytes = 8 * 1024 * 1024;

const DiffHunkRange = struct {
    old_start: usize,
    new_start: usize,
};

const CommitListEntry = struct {
    full_hash: []u8,
    short_hash: []u8,
    subject: []u8,
    author: []u8,
    relative: []u8,

    fn deinit(self: CommitListEntry, allocator: Allocator) void {
        allocator.free(self.full_hash);
        allocator.free(self.short_hash);
        allocator.free(self.subject);
        allocator.free(self.author);
        allocator.free(self.relative);
    }
};

const CommitDetail = struct {
    full_hash: []u8,
    short_hash: []u8,
    author: []u8,
    email: []u8,
    relative: []u8,
    subject: []u8,

    fn deinit(self: CommitDetail, allocator: Allocator) void {
        allocator.free(self.full_hash);
        allocator.free(self.short_hash);
        allocator.free(self.author);
        allocator.free(self.email);
        allocator.free(self.relative);
        allocator.free(self.subject);
    }
};

pub fn renderCommitsPage(allocator: Allocator, repo: Repo, target: []const u8) ![]u8 {
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
        normalizedPathOwned(allocator, value) catch try allocator.dupe(u8, "")
    else
        try allocator.dupe(u8, "");
    defer allocator.free(path);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "Commits", "commits");
    try appendRepoHeader(&buf, allocator, repo, ref);

    const commits = try loadCommits(allocator, repo, ref, path);
    defer freeCommitList(allocator, commits);

    try buf.appendSlice(allocator,
        \\<section class="panel commits-panel">
        \\  <div class="section-head">
        \\    <div>
        \\      <p class="eyebrow">History</p>
        \\      <h1>
    );
    if (path.len == 0) {
        try buf.appendSlice(allocator, "Recent commits");
    } else {
        try buf.appendSlice(allocator, "Commits for ");
        try appendHtml(&buf, allocator, path);
    }
    try buf.appendSlice(allocator,
        \\</h1>
        \\    </div>
        \\    <a class="button secondary" href="
    );
    try appendCodeHref(&buf, allocator, ref, path);
    try buf.appendSlice(allocator,
        \\">Code</a>
        \\  </div>
        \\  <div class="commit-list">
    );

    for (commits) |commit| {
        try buf.appendSlice(allocator, "<article class=\"commit-row\"><div><a class=\"commit-title\" href=\"");
        try appendCommitHref(&buf, allocator, commit.full_hash);
        try buf.appendSlice(allocator, "\">");
        try appendHtml(&buf, allocator, commit.subject);
        try buf.appendSlice(allocator, "</a><p>");
        try appendHtml(&buf, allocator, commit.author);
        try buf.appendSlice(allocator, " committed ");
        try appendHtml(&buf, allocator, commit.relative);
        try buf.appendSlice(allocator, "</p></div><a class=\"commit-sha\" href=\"");
        try appendCommitHref(&buf, allocator, commit.full_hash);
        try buf.appendSlice(allocator, "\"><code>");
        try appendHtml(&buf, allocator, commit.short_hash);
        try buf.appendSlice(allocator, "</code></a></article>");
    }

    if (commits.len == 0) {
        try appendEmptyState(&buf, allocator, "No commits found.", "This ref has no commit history for the selected path.");
    }

    try buf.appendSlice(allocator, "</div></section>");
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

pub fn renderCommitPage(allocator: Allocator, repo: Repo, target: []const u8) ![]u8 {
    const query_sha = try queryValueOwned(allocator, target, "sha");
    defer if (query_sha) |value| allocator.free(value);
    const query_context = try queryValueOwned(allocator, target, "context");
    defer if (query_context) |value| allocator.free(value);
    const sha = if (query_sha) |value| blk: {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        break :blk if (trimmed.len == 0) "HEAD" else trimmed;
    } else "HEAD";
    const diff_context = diffContext(query_context);

    const detail_opt = try loadCommitDetail(allocator, repo, sha);
    if (detail_opt == null) return renderMissingCommitPage(allocator, repo, sha);
    const detail = detail_opt.?;
    defer detail.deinit(allocator);

    const diff = try loadCommitDiff(allocator, repo, sha, diff_context);
    defer if (diff) |bytes| allocator.free(bytes);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "Commit", "commits");
    try appendRepoHeader(&buf, allocator, repo, detail.short_hash);
    try buf.appendSlice(allocator,
        \\<section class="panel commit-detail">
        \\  <div class="commit-detail-head">
        \\    <div>
        \\      <p class="eyebrow">Commit</p>
        \\      <h1>
    );
    try appendHtml(&buf, allocator, detail.subject);
    try buf.appendSlice(allocator,
        \\</h1>
        \\      <p class="commit-full-hash">
    );
    try appendHtml(&buf, allocator, detail.full_hash);
    try buf.appendSlice(allocator,
        \\</p>
        \\    </div>
        \\    <a class="button secondary" href="/commits">History</a>
        \\  </div>
        \\  <div class="commit-meta">
        \\    <strong>
    );
    try appendHtml(&buf, allocator, detail.author);
    try buf.appendSlice(allocator, "</strong><span>");
    try appendHtml(&buf, allocator, detail.email);
    try buf.appendSlice(allocator, "</span><span>");
    try appendHtml(&buf, allocator, detail.relative);
    try buf.appendSlice(allocator, "</span></div></section>");

    try buf.appendSlice(allocator,
        \\<section class="diff-section">
        \\  <div class="section-head">
        \\    <div>
        \\      <p class="eyebrow">Changes</p>
        \\      <h1>Diff</h1>
        \\    </div>
        \\  </div>
    );
    if (diff) |bytes| {
        try appendDiff(&buf, allocator, sha, diff_context, bytes);
    } else {
        try appendEmptyState(&buf, allocator, "Diff not available.", "Git could not render a patch for this commit.");
    }
    try buf.appendSlice(allocator, "</section>");

    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn renderMissingCommitPage(allocator: Allocator, repo: Repo, sha: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try appendShellStart(&buf, allocator, repo, "Commit Not Found", "commits");
    try appendRepoHeader(&buf, allocator, repo, "commit");
    try appendEmptyState(&buf, allocator, "Commit not found.", sha);
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
        \\    <a class="button secondary" href="/">Code</a>
        \\    <a class="button secondary" href="/overview">Overview</a>
        \\  </div>
        \\</section>
    );
}

fn loadCommits(allocator: Allocator, repo: Repo, ref: []const u8, path: []const u8) ![]CommitListEntry {
    const format = "--format=%H%x09%h%x09%s%x09%an%x09%cr";
    const raw_opt = if (path.len == 0)
        try gitMaybe(allocator, repo, &.{ "log", "-50", format, ref }, git.max_git_output)
    else blk: {
        const pathspec = try std.fmt.allocPrint(allocator, ":(top){s}", .{path});
        defer allocator.free(pathspec);
        break :blk try gitMaybe(allocator, repo, &.{ "log", "-50", format, ref, "--", pathspec }, git.max_git_output);
    };
    const raw = raw_opt orelse try allocator.dupe(u8, "");
    defer allocator.free(raw);

    var commits: std.ArrayList(CommitListEntry) = .empty;
    errdefer {
        for (commits.items) |commit| commit.deinit(allocator);
        commits.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trimRight(u8, line_raw, "\r");
        if (line.len == 0) continue;
        var cols = std.mem.splitScalar(u8, line, '\t');
        try commits.append(allocator, .{
            .full_hash = try allocator.dupe(u8, cols.next() orelse ""),
            .short_hash = try allocator.dupe(u8, cols.next() orelse ""),
            .subject = try allocator.dupe(u8, cols.next() orelse ""),
            .author = try allocator.dupe(u8, cols.next() orelse ""),
            .relative = try allocator.dupe(u8, cols.next() orelse ""),
        });
    }

    return try commits.toOwnedSlice(allocator);
}

fn loadCommitDetail(allocator: Allocator, repo: Repo, sha: []const u8) !?CommitDetail {
    const raw = try gitMaybe(allocator, repo, &.{ "show", "-s", "--format=%H%x09%h%x09%an%x09%ae%x09%cr%x09%s", sha }, 1024 * 1024) orelse return null;
    defer allocator.free(raw);
    const line = std.mem.trim(u8, raw, " \t\r\n");
    if (line.len == 0) return null;
    var cols = std.mem.splitScalar(u8, line, '\t');
    return .{
        .full_hash = try allocator.dupe(u8, cols.next() orelse ""),
        .short_hash = try allocator.dupe(u8, cols.next() orelse ""),
        .author = try allocator.dupe(u8, cols.next() orelse ""),
        .email = try allocator.dupe(u8, cols.next() orelse ""),
        .relative = try allocator.dupe(u8, cols.next() orelse ""),
        .subject = try allocator.dupe(u8, cols.next() orelse ""),
    };
}

fn loadCommitDiff(allocator: Allocator, repo: Repo, sha: []const u8, context: usize) !?[]u8 {
    const unified = try std.fmt.allocPrint(allocator, "--unified={d}", .{context});
    defer allocator.free(unified);
    return gitMaybe(allocator, repo, &.{
        "show",
        "--pretty=format:",
        "--no-ext-diff",
        "--find-renames",
        "--patch",
        unified,
        sha,
    }, max_commit_diff_bytes);
}

fn appendDiff(buf: *std.ArrayList(u8), allocator: Allocator, sha: []const u8, context: usize, diff: []const u8) !void {
    if (std.mem.trim(u8, diff, " \t\r\n").len == 0) {
        try appendEmptyState(buf, allocator, "No file changes.", "This commit does not contain a patch to display.");
        return;
    }

    var in_file = false;
    var rendered_lines: usize = 0;
    var old_line: ?usize = null;
    var new_line: ?usize = null;
    var lines = std.mem.splitScalar(u8, diff, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (std.mem.startsWith(u8, line, "diff --git ")) {
            if (in_file) try buf.appendSlice(allocator, "</div></section>");
            in_file = true;
            rendered_lines = 0;
            old_line = null;
            new_line = null;
            try buf.appendSlice(allocator, "<section class=\"panel diff-file\"><div class=\"diff-file-head\"><strong>");
            try appendHtml(buf, allocator, diffFileTitle(line));
            try buf.appendSlice(allocator, "</strong></div><div class=\"diff-lines\">");
            continue;
        } else if (!in_file) {
            in_file = true;
            rendered_lines = 0;
            old_line = null;
            new_line = null;
            try buf.appendSlice(allocator, "<section class=\"panel diff-file\"><div class=\"diff-file-head\"><strong>Patch</strong></div><div class=\"diff-lines\">");
        }

        if (parseHunkHeader(line)) |range| {
            if (rendered_lines == 0) {
                if (range.old_start > 1 or range.new_start > 1) {
                    try appendDiffExpandRow(buf, allocator, sha, context, "Expand from file start");
                }
            } else {
                try appendDiffExpandRow(buf, allocator, sha, context, "Expand hidden lines");
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

fn appendDiffExpandRow(buf: *std.ArrayList(u8), allocator: Allocator, sha: []const u8, context: usize, label: []const u8) !void {
    try buf.appendSlice(allocator, "<div class=\"diff-row diff-expand\"><span></span><span></span>");
    if (context < 200) {
        try buf.appendSlice(allocator, "<a href=\"");
        try appendCommitHrefWithContext(buf, allocator, sha, @min(context * 4, @as(usize, 200)));
        try buf.appendSlice(allocator, "\">");
        try appendHtml(buf, allocator, label);
        try buf.appendSlice(allocator, "</a>");
    } else {
        try buf.appendSlice(allocator, "<span>Maximum context shown</span>");
    }
    try buf.appendSlice(allocator, "</div>");
}

fn appendDiffLine(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    line: []const u8,
    class: []const u8,
    old_line: ?usize,
    new_line: ?usize,
) !void {
    try buf.appendSlice(allocator, "<div class=\"diff-row ");
    try appendHtml(buf, allocator, class);
    try buf.appendSlice(allocator, "\"><span class=\"diff-num old\">");
    try appendLineNumber(buf, allocator, old_line);
    try buf.appendSlice(allocator, "</span><span class=\"diff-num new\">");
    try appendLineNumber(buf, allocator, new_line);
    try buf.appendSlice(allocator, "</span><code class=\"diff-code\">");
    try appendHtml(buf, allocator, line);
    try buf.appendSlice(allocator, "</code></div>");
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
    var end: usize = 0;
    while (end < value.len and std.ascii.isDigit(value[end])) : (end += 1) {}
    if (end == 0) return null;
    return std.fmt.parseUnsigned(usize, value[0..end], 10) catch null;
}

fn diffContext(query_context: ?[]u8) usize {
    const raw = query_context orelse return 3;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return 3;
    const parsed = std.fmt.parseUnsigned(usize, trimmed, 10) catch return 3;
    return @min(@max(parsed, @as(usize, 3)), @as(usize, 200));
}

fn diffFileTitle(line: []const u8) []const u8 {
    const marker = " b/";
    if (std.mem.lastIndexOf(u8, line, marker)) |index| return line[index + marker.len ..];
    return line;
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

fn appendCommitHref(buf: *std.ArrayList(u8), allocator: Allocator, hash: []const u8) !void {
    try buf.appendSlice(allocator, "/commit?sha=");
    try appendUrlEncoded(buf, allocator, hash);
}

fn appendCommitHrefWithContext(buf: *std.ArrayList(u8), allocator: Allocator, hash: []const u8, context: usize) !void {
    try appendCommitHref(buf, allocator, hash);
    try buf.appendSlice(allocator, "&context=");
    try std.fmt.format(buf.writer(allocator), "{d}", .{context});
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

fn freeCommitList(allocator: Allocator, commits: []CommitListEntry) void {
    for (commits) |commit| commit.deinit(allocator);
    allocator.free(commits);
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

test "web commits renders diff line classes" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendDiff(
        &buf,
        std.testing.allocator,
        "abc123",
        3,
        "diff --git a/a.zig b/a.zig\n@@ -1 +1 @@\n-old\n+new\n",
    );
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "diff-file") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "diff-row hunk") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "diff-row del") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "diff-row add") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "diff-num old\">1") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "diff-num new\">1") != null);
}
