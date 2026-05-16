const std = @import("std");
const git = @import("../git.zig");
const repo_mod = @import("../repo.zig");
const shared = @import("shared.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const appendEmptyState = shared.appendEmptyState;
const appendHtml = shared.appendHtml;
const appendHref = shared.appendHref;
const appendOptionalAttr = shared.appendOptionalAttr;
const appendRepoHeaderShared = shared.appendRepoHeader;
const appendShellEnd = shared.appendShellEnd;
const appendShellStart = shared.appendShellStart;
const appendTemplate = shared.appendTemplate;
const codeHref = shared.codeHref;
const commitHref = shared.commitHref;
const literalHref = shared.literalHref;
const runCommand = git.runCommand;

const max_commit_diff_bytes = 8 * 1024 * 1024;
const commits_default_page_size = 50;
const commits_max_page_size = 100;

const DiffHunkRange = struct {
    old_start: usize,
    new_start: usize,
};

const CommitListEntry = struct {
    full_hash: []u8,
    short_hash: []u8,
    subject: []u8,
    author: []u8,
    email: []u8,
    relative: []u8,
    date: []u8,
    signature_status: []u8,

    fn deinit(self: CommitListEntry, allocator: Allocator) void {
        allocator.free(self.full_hash);
        allocator.free(self.short_hash);
        allocator.free(self.subject);
        allocator.free(self.author);
        allocator.free(self.email);
        allocator.free(self.relative);
        allocator.free(self.date);
        allocator.free(self.signature_status);
    }
};

const BranchRef = struct {
    name: []u8,
    scope: BranchScope,

    fn deinit(self: BranchRef, allocator: Allocator) void {
        allocator.free(self.name);
    }
};

const BranchScope = enum {
    local,
    remote,
};

const CommitDetail = struct {
    full_hash: []u8,
    short_hash: []u8,
    author: []u8,
    email: []u8,
    relative: []u8,
    subject: []u8,
    body: []u8,

    fn deinit(self: CommitDetail, allocator: Allocator) void {
        allocator.free(self.full_hash);
        allocator.free(self.short_hash);
        allocator.free(self.author);
        allocator.free(self.email);
        allocator.free(self.relative);
        allocator.free(self.subject);
        allocator.free(self.body);
    }
};

pub fn renderCommitsPage(allocator: Allocator, repo: Repo, target: []const u8) ![]u8 {
    const query_ref = try queryValueOwned(allocator, target, "ref");
    defer if (query_ref) |value| allocator.free(value);
    const query_path = try queryValueOwned(allocator, target, "path");
    defer if (query_path) |value| allocator.free(value);

    const default_ref = try defaultRef(allocator, repo);
    defer allocator.free(default_ref);
    const ref = if (query_ref) |value| safeRevisionOrDefault(value, default_ref) else default_ref;

    const path = if (query_path) |value|
        normalizedPathOwned(allocator, value) catch try allocator.dupe(u8, "")
    else
        try allocator.dupe(u8, "");
    defer allocator.free(path);
    const pagination = try shared.paginationFromTarget(allocator, target, commits_default_page_size, commits_max_page_size);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "Commits", "commits");

    const commits = try loadCommits(allocator, repo, ref, path, pagination);
    defer freeCommitList(allocator, commits);
    const branches = try loadBranchRefs(allocator, repo);
    defer freeBranchRefs(allocator, branches);
    var reference_resolver = shared.InternalReferenceResolver.init(allocator, repo);
    defer reference_resolver.deinit();

    try appendCommitsHeader(&buf, allocator, ref, path, branches);

    const shown_commits = @min(commits.len, pagination.per_page);
    const has_next_page = commits.len > pagination.per_page;
    if (shown_commits == 0) {
        try buf.appendSlice(allocator, "<section class=\"panel commits-panel\">");
        if (pagination.page > 1) {
            try appendEmptyState(&buf, allocator, "No commits on this page.", "Use the previous page to return to this ref's commit history.");
        } else {
            try appendEmptyState(&buf, allocator, "No commits found.", "This ref has no commit history for the selected path.");
        }
        try buf.appendSlice(allocator, "</section>");
        if (pagination.page > 1) try appendCommitsPagination(&buf, allocator, ref, path, pagination, shown_commits, false);
    } else {
        try appendCommitTimeline(&buf, allocator, &reference_resolver, commits[0..shown_commits]);
        try appendCommitsPagination(&buf, allocator, ref, path, pagination, shown_commits, has_next_page);
    }

    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

pub fn renderCommitPage(allocator: Allocator, repo: Repo, target: []const u8) ![]u8 {
    const query_sha = try queryValueOwned(allocator, target, "sha");
    defer if (query_sha) |value| allocator.free(value);
    const query_context = try queryValueOwned(allocator, target, "context");
    defer if (query_context) |value| allocator.free(value);
    const sha = if (query_sha) |value| safeRevisionOrDefault(value, "HEAD") else "HEAD";
    const diff_context = diffContext(query_context);

    const detail_opt = try loadCommitDetail(allocator, repo, sha);
    if (detail_opt == null) return renderMissingCommitPage(allocator, repo, sha);
    const detail = detail_opt.?;
    defer detail.deinit(allocator);

    const diff = try loadCommitDiff(allocator, repo, sha, diff_context);
    defer if (diff) |bytes| allocator.free(bytes);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var reference_resolver = shared.InternalReferenceResolver.init(allocator, repo);
    defer reference_resolver.deinit();

    try appendShellStart(&buf, allocator, repo, "Commit", "commits");
    try shared.appendDetailBackButton(&buf, allocator, shared.literalHref("/commits"), "Back to commits");
    try appendRepoHeader(&buf, allocator, repo, detail.short_hash);
    try appendTemplate(&buf, allocator,
        \\<section class="panel commit-detail">
        \\  <div class="commit-detail-head">
        \\    <div>
        \\      <p class="eyebrow">Commit</p>
        \\      <h1>
    , .{});
    try shared.appendInternalReferenceLinkedText(&buf, allocator, &reference_resolver, detail.subject);
    try appendTemplate(&buf, allocator,
        \\</h1>
        \\      <p class="commit-full-hash">{full_hash}</p>
        \\    </div>
        \\    <a class="button secondary" href="/commits">History</a>
        \\  </div>
        \\  <div class="commit-meta">
        \\    <strong>{author}</strong><span>{email}</span><span>{relative}</span>
        \\  </div>
    , .{
        .full_hash = detail.full_hash,
        .author = detail.author,
        .email = detail.email,
        .relative = detail.relative,
    });
    if (std.mem.trim(u8, detail.body, " \t\r\n").len != 0) {
        try buf.appendSlice(allocator, "<div class=\"commit-message markdown-body\">");
        try shared.appendMarkdownSource(&buf, allocator, detail.body, .{});
        try buf.appendSlice(allocator, "</div>");
    }
    try buf.appendSlice(allocator, "</section>");

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
    try shared.appendDetailBackButton(&buf, allocator, shared.literalHref("/commits"), "Back to commits");
    try appendRepoHeader(&buf, allocator, repo, "commit");
    try appendEmptyState(&buf, allocator, "Commit not found.", sha);
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn appendCommitsHeader(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    ref: []const u8,
    path: []const u8,
    branches: []const BranchRef,
) !void {
    try appendTemplate(buf, allocator,
        \\<section class="commits-page-head">
        \\  <div>
        \\    <h1>Commits</h1>
    , .{});
    if (path.len != 0) {
        try appendTemplate(buf, allocator,
            \\    <p>History for <code>{path}</code></p>
        , .{ .path = path });
    }
    try appendTemplate(buf, allocator,
        \\  </div>
        \\</section>
        \\<div class="commits-toolbar">
        \\  <form class="commits-branch-form" method="get" action="/commits">
        \\    <label class="root-branch-select-wrap commits-branch-select-wrap" aria-label="Branch">
        \\      <span class="button-icon icon-branch" aria-hidden="true"></span>
        \\      <select class="root-branch-select commits-branch-select" name="ref" onchange="this.form.submit()">
    , .{});
    try appendBranchOptions(buf, allocator, branches, ref);
    try appendTemplate(buf, allocator,
        \\      </select>
        \\      <span class="root-caret" aria-hidden="true"></span>
        \\    </label>
    , .{});
    if (path.len != 0) {
        try appendTemplate(buf, allocator,
            \\    <input type="hidden" name="path" value="{path}">
        , .{ .path = path });
    }
    try appendTemplate(buf, allocator,
        \\  </form>
        \\  <div class="commits-filter-actions">
        \\    <details class="commits-filter-menu" data-popover-menu>
        \\      <summary class="button secondary commits-filter-button"><span class="button-icon icon-users" aria-hidden="true"></span><span>All users</span><span class="root-caret" aria-hidden="true"></span></summary>
        \\      <div class="commits-filter-popover" role="menu"><span class="commits-filter-option selected">All users</span></div>
        \\    </details>
        \\    <details class="commits-filter-menu" data-popover-menu>
        \\      <summary class="button secondary commits-filter-button"><span class="button-icon icon-calendar" aria-hidden="true"></span><span>All time</span><span class="root-caret" aria-hidden="true"></span></summary>
        \\      <div class="commits-filter-popover" role="menu"><span class="commits-filter-option selected">All time</span></div>
        \\    </details>
        \\  </div>
        \\</div>
    , .{});
}

fn appendCommitTimeline(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    reference_resolver: *shared.InternalReferenceResolver,
    commits: []const CommitListEntry,
) !void {
    try buf.appendSlice(allocator, "<div class=\"commits-timeline\">");
    var active_date: ?[]const u8 = null;
    var group_open = false;
    for (commits) |commit| {
        if (active_date == null or !std.mem.eql(u8, active_date.?, commit.date)) {
            if (group_open) try buf.appendSlice(allocator, "</div></section>");
            active_date = commit.date;
            group_open = true;
            try appendTemplate(buf, allocator,
                \\<section class="commit-day">
                \\  <div class="commit-day-marker" aria-hidden="true"></div>
                \\  <h2>Commits on 
            , .{});
            try appendCommitDateLabel(buf, allocator, commit.date);
            try appendTemplate(buf, allocator,
                \\</h2>
                \\  <div class="panel commit-day-list">
            , .{});
        }
        try appendCommitRow(buf, allocator, reference_resolver, commit);
    }
    if (group_open) try buf.appendSlice(allocator, "</div></section>");
    try buf.appendSlice(allocator, "</div>");
}

fn commitsHrefOwned(allocator: Allocator, ref: []const u8, path: []const u8, pagination: shared.Pagination, page: usize) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "/commits");
    var first = true;
    try shared.appendQueryParam(&buf, allocator, &first, "ref", ref);
    if (path.len != 0) try shared.appendQueryParam(&buf, allocator, &first, "path", path);
    try shared.appendPaginationQueryParams(&buf, allocator, &first, pagination, page, commits_default_page_size);
    return buf.toOwnedSlice(allocator);
}

fn appendCommitsPagination(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    ref: []const u8,
    path: []const u8,
    pagination: shared.Pagination,
    shown: usize,
    has_next_page: bool,
) !void {
    const previous_href = if (pagination.page > 1) try commitsHrefOwned(allocator, ref, path, pagination, pagination.page - 1) else null;
    defer if (previous_href) |href| allocator.free(href);
    const next_href = if (has_next_page) try commitsHrefOwned(allocator, ref, path, pagination, pagination.page + 1) else null;
    defer if (next_href) |href| allocator.free(href);
    const summary = try shared.paginationSummaryOwned(allocator, pagination, shown, null);
    defer allocator.free(summary);
    try shared.appendPaginationNav(buf, allocator, "Commit pages", summary, previous_href, next_href);
}

fn appendCommitRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    reference_resolver: *shared.InternalReferenceResolver,
    commit: CommitListEntry,
) !void {
    const commit_href = commitHref(commit.full_hash);
    const code_href = codeHref(commit.full_hash, "");
    try appendTemplate(buf, allocator,
        \\<article class="commit-row commit-list-row">
        \\  <div class="commit-main">
        \\    <div class="commit-title-line"><span class="commit-title">
    , .{ .commit_href = commit_href });
    try shared.appendInternalReferenceLinkedTextWithDefaultHref(buf, allocator, reference_resolver, commit.subject, commit_href);
    try appendTemplate(buf, allocator,
        \\</span></div>
        \\    <p class="commit-meta-line">
    , .{});
    try shared.appendAvatar(buf, allocator, commit.author, "commit-avatar");
    try appendTemplate(buf, allocator,
        \\<span>{author} committed {relative}</span></p>
        \\  </div>
        \\  <div class="commit-row-actions">
    , .{
        .author = commit.author,
        .relative = commit.relative,
    });
    if (isVerifiedSignature(commit.signature_status)) {
        try buf.appendSlice(allocator, "<span class=\"commit-verified\">Verified</span>");
    }
    try appendTemplate(buf, allocator,
        \\    <a class="commit-sha" href="{commit_href}">{short_hash}</a>
        \\    <button class="commit-icon-action" type="button" data-copy-text="{full_hash}" aria-label="Copy commit hash" title="Copy commit hash"><span class="button-icon icon-copy" aria-hidden="true"></span></button>
        \\    <a class="commit-icon-action" href="{code_href}" aria-label="Browse code at commit" title="Browse code at commit"><span class="button-icon icon-code" aria-hidden="true"></span></a>
        \\  </div>
        \\</article>
    , .{
        .commit_href = commit_href,
        .code_href = code_href,
        .short_hash = commit.short_hash,
        .full_hash = commit.full_hash,
    });
}

fn appendRepoHeader(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, ref: []const u8) !void {
    try appendRepoHeaderShared(buf, allocator, repo, ref, &.{
        .{ .label = "Code", .href = literalHref("/") },
    });
}

fn loadCommits(allocator: Allocator, repo: Repo, ref: []const u8, path: []const u8, pagination: shared.Pagination) ![]CommitListEntry {
    const format = "--format=%H%x1f%h%x1f%s%x1f%an%x1f%ae%x1f%cr%x1f%ad%x1f%G?%x1e";
    const max_count = try std.fmt.allocPrint(allocator, "--max-count={d}", .{pagination.queryLimit()});
    defer allocator.free(max_count);
    const skip = try std.fmt.allocPrint(allocator, "--skip={d}", .{pagination.offset()});
    defer allocator.free(skip);
    const raw_opt = if (path.len == 0)
        try gitMaybe(allocator, repo, &.{ "log", max_count, skip, "--date=short", format, "--end-of-options", ref }, git.max_git_output)
    else blk: {
        const pathspec = try std.fmt.allocPrint(allocator, ":(top){s}", .{path});
        defer allocator.free(pathspec);
        break :blk try gitMaybe(allocator, repo, &.{ "log", max_count, skip, "--date=short", format, "--end-of-options", ref, "--", pathspec }, git.max_git_output);
    };
    const raw = raw_opt orelse try allocator.dupe(u8, "");
    defer allocator.free(raw);

    var commits: std.ArrayList(CommitListEntry) = .empty;
    errdefer {
        for (commits.items) |commit| commit.deinit(allocator);
        commits.deinit(allocator);
    }

    var records = std.mem.splitScalar(u8, raw, 0x1e);
    while (records.next()) |record_raw| {
        const record = std.mem.trim(u8, record_raw, "\r\n");
        if (record.len == 0) continue;
        var cols = std.mem.splitScalar(u8, record, 0x1f);
        try commits.append(allocator, .{
            .full_hash = try allocator.dupe(u8, cols.next() orelse ""),
            .short_hash = try allocator.dupe(u8, cols.next() orelse ""),
            .subject = try allocator.dupe(u8, cols.next() orelse ""),
            .author = try allocator.dupe(u8, cols.next() orelse ""),
            .email = try allocator.dupe(u8, cols.next() orelse ""),
            .relative = try allocator.dupe(u8, cols.next() orelse ""),
            .date = try allocator.dupe(u8, cols.next() orelse ""),
            .signature_status = try allocator.dupe(u8, cols.next() orelse ""),
        });
    }

    return try commits.toOwnedSlice(allocator);
}

fn loadBranchRefs(allocator: Allocator, repo: Repo) ![]BranchRef {
    const raw = try gitMaybe(allocator, repo, &.{ "for-each-ref", "--format=%(refname)%09%(refname:short)", "refs/heads", "refs/remotes" }, git.max_git_output) orelse {
        return allocator.alloc(BranchRef, 0);
    };
    defer allocator.free(raw);

    var branches: std.ArrayList(BranchRef) = .empty;
    errdefer {
        for (branches.items) |branch| branch.deinit(allocator);
        branches.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        var cols = std.mem.splitScalar(u8, trimmed, '\t');
        const full_ref = cols.next() orelse continue;
        const name = cols.next() orelse continue;
        if (std.mem.endsWith(u8, full_ref, "/HEAD")) continue;
        const scope = branchScopeForFullRef(full_ref) orelse continue;
        try branches.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .scope = scope,
        });
    }
    std.mem.sort(BranchRef, branches.items, {}, struct {
        fn lessThan(_: void, a: BranchRef, b: BranchRef) bool {
            if (a.scope != b.scope) return @intFromEnum(a.scope) < @intFromEnum(b.scope);
            return std.ascii.lessThanIgnoreCase(a.name, b.name);
        }
    }.lessThan);
    return branches.toOwnedSlice(allocator);
}

fn appendBranchOptions(buf: *std.ArrayList(u8), allocator: Allocator, branches: []const BranchRef, selected_ref: []const u8) !void {
    var found_selected = false;
    for (branches) |branch| {
        const selected = std.mem.eql(u8, branch.name, selected_ref);
        found_selected = found_selected or selected;
        try appendTemplate(buf, allocator,
            \\<option value="{name}"{selected_attr}>{name}</option>
        , .{
            .name = branch.name,
            .selected_attr = shared.trustedHtml(if (selected) " selected" else ""),
        });
    }
    if (!found_selected) {
        try appendTemplate(buf, allocator,
            \\<option value="{name}" selected>{name}</option>
        , .{ .name = selected_ref });
    }
}

fn branchScopeForFullRef(ref: []const u8) ?BranchScope {
    if (std.mem.startsWith(u8, ref, "refs/heads/")) return .local;
    if (std.mem.startsWith(u8, ref, "refs/remotes/")) return .remote;
    return null;
}

fn isVerifiedSignature(status: []const u8) bool {
    const trimmed = std.mem.trim(u8, status, " \t\r\n");
    return trimmed.len != 0 and trimmed[0] == 'G';
}

fn appendCommitDateLabel(buf: *std.ArrayList(u8), allocator: Allocator, date: []const u8) !void {
    if (date.len >= 10 and date[4] == '-' and date[7] == '-') {
        const year = std.fmt.parseUnsigned(u16, date[0..4], 10) catch null;
        const month = std.fmt.parseUnsigned(u8, date[5..7], 10) catch null;
        const day = std.fmt.parseUnsigned(u8, date[8..10], 10) catch null;
        if (year != null and month != null and day != null and month.? >= 1 and month.? <= 12 and day.? >= 1) {
            try std.fmt.format(buf.writer(allocator), "{s} {d}, {d}", .{ monthName(month.?), day.?, year.? });
            return;
        }
    }
    if (date.len == 0) {
        try buf.appendSlice(allocator, "Unknown date");
    } else {
        try appendHtml(buf, allocator, date);
    }
}

fn monthName(month: u8) []const u8 {
    return switch (month) {
        1 => "January",
        2 => "February",
        3 => "March",
        4 => "April",
        5 => "May",
        6 => "June",
        7 => "July",
        8 => "August",
        9 => "September",
        10 => "October",
        11 => "November",
        12 => "December",
        else => "Unknown",
    };
}

fn loadCommitDetail(allocator: Allocator, repo: Repo, sha: []const u8) !?CommitDetail {
    const raw = try gitMaybe(allocator, repo, &.{ "show", "-s", "--format=%H%x00%h%x00%an%x00%ae%x00%cr%x00%s%x00%b", "--end-of-options", sha }, 1024 * 1024) orelse return null;
    defer allocator.free(raw);
    const record = std.mem.trimRight(u8, raw, "\r\n");
    if (record.len == 0) return null;
    var cols = std.mem.splitScalar(u8, record, 0);
    return .{
        .full_hash = try allocator.dupe(u8, cols.next() orelse ""),
        .short_hash = try allocator.dupe(u8, cols.next() orelse ""),
        .author = try allocator.dupe(u8, cols.next() orelse ""),
        .email = try allocator.dupe(u8, cols.next() orelse ""),
        .relative = try allocator.dupe(u8, cols.next() orelse ""),
        .subject = try allocator.dupe(u8, cols.next() orelse ""),
        .body = try allocator.dupe(u8, cols.next() orelse ""),
    };
}

fn loadCommitDiff(allocator: Allocator, repo: Repo, sha: []const u8, context: usize) !?[]u8 {
    const unified = try std.fmt.allocPrint(allocator, "--unified={d}", .{context});
    defer allocator.free(unified);

    const first_parent = try std.fmt.allocPrint(allocator, "{s}^1", .{sha});
    defer allocator.free(first_parent);

    if (try gitMaybe(allocator, repo, &.{
        "diff",
        "--no-ext-diff",
        "--find-renames",
        "--patch",
        unified,
        "--end-of-options",
        first_parent,
        sha,
    }, max_commit_diff_bytes)) |diff| {
        return diff;
    }

    return gitMaybe(allocator, repo, &.{
        "show",
        "--pretty=format:",
        "--no-ext-diff",
        "--find-renames",
        "--patch",
        unified,
        "--end-of-options",
        sha,
    }, max_commit_diff_bytes);
}

fn appendDiff(buf: *std.ArrayList(u8), allocator: Allocator, sha: []const u8, context: usize, diff: []const u8) !void {
    if (std.mem.trim(u8, diff, " \t\r\n").len == 0) {
        try appendEmptyState(buf, allocator, "No file changes.", "This commit does not contain a patch to display.");
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
            if (rendered_lines == 0) {
                if (range.old_start > 1 or range.new_start > 1) {
                    try appendDiffExpandRow(buf, allocator, sha, context, current_file_index, "Expand from file start");
                }
            } else {
                try appendDiffExpandRow(buf, allocator, sha, context, current_file_index, "Expand hidden lines");
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

fn appendDiffExpandRow(buf: *std.ArrayList(u8), allocator: Allocator, sha: []const u8, context: usize, file_index: usize, label: []const u8) !void {
    try buf.appendSlice(allocator, "<div class=\"diff-row diff-expand\" data-diff-row data-diff-kind=\"expand\"><span></span><span></span>");
    if (context < 200) {
        try buf.appendSlice(allocator, "<a data-diff-expand href=\"");
        try appendCommitHrefWithContext(buf, allocator, sha, @min(context * 4, @as(usize, 200)), file_index);
        try appendTemplate(buf, allocator, "\">{label}</a>", .{ .label = label });
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

fn safeRevisionOrDefault(raw: []const u8, default: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] == '-') return default;
    return trimmed;
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

fn appendCommitHrefWithContext(buf: *std.ArrayList(u8), allocator: Allocator, hash: []const u8, context: usize, file_index: usize) !void {
    try appendHref(buf, allocator, commitHref(hash));
    try buf.appendSlice(allocator, "&amp;context=");
    try std.fmt.format(buf.writer(allocator), "{d}", .{context});
    try buf.appendSlice(allocator, "#diff-file-");
    try std.fmt.format(buf.writer(allocator), "{d}", .{file_index});
}

fn freeCommitList(allocator: Allocator, commits: []CommitListEntry) void {
    for (commits) |commit| commit.deinit(allocator);
    allocator.free(commits);
}

fn freeBranchRefs(allocator: Allocator, branches: []BranchRef) void {
    for (branches) |branch| branch.deinit(allocator);
    allocator.free(branches);
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

test "web commits rejects option-like revisions" {
    try std.testing.expectEqualStrings("main", safeRevisionOrDefault("  main\n", "HEAD"));
    try std.testing.expectEqualStrings("HEAD", safeRevisionOrDefault("", "HEAD"));
    try std.testing.expectEqualStrings("HEAD", safeRevisionOrDefault(" --output=/tmp/gitomi-poc", "HEAD"));
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
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "id=\"diff-file-0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "data-diff-row data-diff-kind=\"del\" data-diff-old=\"1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "data-diff-expand href=\"/commit?sha=abc123&amp;context=12#diff-file-0\"") != null);
}

test "web commits row links subject to commit and code icon to tree" {
    const allocator = std.testing.allocator;
    var commit = CommitListEntry{
        .full_hash = try allocator.dupe(u8, "abc123def456"),
        .short_hash = try allocator.dupe(u8, "abc123d"),
        .subject = try allocator.dupe(u8, "Fix #42 <escape>"),
        .author = try allocator.dupe(u8, "Ada"),
        .email = try allocator.dupe(u8, "ada@example.test"),
        .relative = try allocator.dupe(u8, "2 minutes ago"),
        .date = try allocator.dupe(u8, "2026-05-15"),
        .signature_status = try allocator.dupe(u8, "G"),
    };
    defer commit.deinit(allocator);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try appendCommitRow(&buf, allocator, commit);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<a class=\"commit-title\" href=\"/commit?sha=abc123def456\">Fix #42 &lt;escape&gt;</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<a class=\"commit-icon-action\" href=\"/code?ref=abc123def456\" aria-label=\"Browse code at commit\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "href=\"/issues/42\"") == null);
}
