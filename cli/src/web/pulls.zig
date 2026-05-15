const std = @import("std");
const comment_mod = @import("../comment.zig");
const git = @import("../git.zig");
const index = @import("../index.zig");
const issues_page = @import("issues.zig");
const markdown_render = @import("markdown_render.zig");
const pull = @import("../pull.zig");
const reaction_mod = @import("../reaction.zig");
const repo_mod = @import("../repo.zig");
const shared = @import("shared.zig");
const util = @import("../util.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const SqliteDb = index.SqliteDb;
const appendEmptyState = shared.appendEmptyState;
const appendHref = shared.appendHref;
const appendOptionalAttr = shared.appendOptionalAttr;
const appendPill = shared.appendPill;
const appendSectionHead = shared.appendSectionHead;
const appendShellEnd = shared.appendShellEnd;
const appendShellStart = shared.appendShellStart;
const appendRelativeTime = shared.appendRelativeTime;
const appendTemplate = shared.appendTemplate;
const commitHref = shared.commitHref;
const createCommentAddedEvent = comment_mod.createCommentAddedEvent;
const createCommentReplyEvent = comment_mod.createCommentReplyEvent;
const createReactionEvent = reaction_mod.createReactionEvent;
const literalHref = shared.literalHref;
const pullHref = shared.pullHref;
const runCommand = git.runCommand;
const sendRedirect = shared.sendRedirect;
const sendPlainResponse = shared.sendPlainResponse;
const sendResponse = shared.sendResponse;
const sqlite = index.sqlite;

const max_pull_diff_bytes = 8 * 1024 * 1024;

const PullStateFilter = enum {
    open,
    merged,
    closed,
    all,
};

const PullDetailTab = enum {
    conversation,
    commits,
    files,
};

const PullCounts = struct {
    open: usize = 0,
    merged: usize = 0,
    closed: usize = 0,
    all: usize = 0,
};

const ReactionChoice = struct {
    value: []const u8,
    label: []const u8,
    title: []const u8,
};

const ReactionSummary = struct {
    emoji: []u8,
    count: i64,
    reacted: bool,

    fn deinit(self: *ReactionSummary, allocator: Allocator) void {
        allocator.free(self.emoji);
    }
};

const reaction_choices = [_]ReactionChoice{
    .{ .value = "\xF0\x9F\x91\x8D", .label = "\xF0\x9F\x91\x8D", .title = "Thumbs up" },
    .{ .value = "\xF0\x9F\x91\x8E", .label = "\xF0\x9F\x91\x8E", .title = "Thumbs down" },
    .{ .value = "\xF0\x9F\x98\x84", .label = "\xF0\x9F\x98\x84", .title = "Laugh" },
    .{ .value = "\xF0\x9F\x8E\x89", .label = "\xF0\x9F\x8E\x89", .title = "Hooray" },
    .{ .value = "\xF0\x9F\x98\x95", .label = "\xF0\x9F\x98\x95", .title = "Confused" },
    .{ .value = "\xE2\x9D\xA4\xEF\xB8\x8F", .label = "\xE2\x9D\xA4\xEF\xB8\x8F", .title = "Heart" },
    .{ .value = "\xF0\x9F\x9A\x80", .label = "\xF0\x9F\x9A\x80", .title = "Rocket" },
    .{ .value = "\xF0\x9F\x91\x80", .label = "\xF0\x9F\x91\x80", .title = "Eyes" },
};

const PullDetail = struct {
    id: []u8,
    title: []u8,
    state: []u8,
    author_principal: []u8,
    author_device: []u8,
    source_author: []u8,
    opened_at: []u8,
    state_occurred_at: []u8,
    state_actor_principal: []u8,
    body: []u8,
    base_ref: []u8,
    head_ref: []u8,
    draft: bool,
    merge_oid: []u8,
    target_oid: []u8,
    legacy_number: i64,
    commit_count: ?usize,
    changed_files: ?usize,
    additions: ?usize,
    deletions: ?usize,

    fn deinit(self: PullDetail, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        allocator.free(self.state);
        allocator.free(self.author_principal);
        allocator.free(self.author_device);
        allocator.free(self.source_author);
        allocator.free(self.opened_at);
        allocator.free(self.state_occurred_at);
        allocator.free(self.state_actor_principal);
        allocator.free(self.body);
        allocator.free(self.base_ref);
        allocator.free(self.head_ref);
        allocator.free(self.merge_oid);
        allocator.free(self.target_oid);
    }
};

const PullTabCounts = struct {
    comments: usize = 0,
    commits: ?usize = null,
    files: ?usize = null,
    additions: ?usize = null,
    deletions: ?usize = null,
};

const PullCommit = struct {
    full_hash: []u8,
    short_hash: []u8,
    author: []u8,
    relative: []u8,
    subject: []u8,

    fn deinit(self: PullCommit, allocator: Allocator) void {
        allocator.free(self.full_hash);
        allocator.free(self.short_hash);
        allocator.free(self.author);
        allocator.free(self.relative);
        allocator.free(self.subject);
    }
};

const DiffHunkRange = struct {
    old_start: usize,
    new_start: usize,
};

pub fn renderPullsPage(allocator: Allocator, repo: Repo, target: []const u8) ![]u8 {
    if (try shared.renderIndexingPageIfStale(allocator, repo, "Pull Requests", "pulls", target)) |body| return body;
    try index.ensureIndex(allocator, repo);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    const requested_filter = try pullStateFilterFromTarget(allocator, target);
    const counts = try loadPullCounts(&db);
    const filter = requested_filter orelse .open;

    try appendShellStart(&buf, allocator, repo, "Pull Requests", "pulls");
    try appendPullsToolbar(&buf, allocator, filter);
    try buf.appendSlice(allocator, "<section class=\"panel pulls-panel\">");
    try appendPullsListHeader(&buf, allocator, filter, counts);

    var stmt = try db.prepare(pullListSql(filter));
    defer stmt.deinit();

    var shown: usize = 0;
    while (try stmt.step()) {
        const id = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(id);
        const title = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(title);
        const state = try stmt.columnTextDup(allocator, 2);
        defer allocator.free(state);
        const author = try stmt.columnTextDup(allocator, 3);
        defer allocator.free(author);
        const opened_at = try stmt.columnTextDup(allocator, 4);
        defer allocator.free(opened_at);
        const state_at = try stmt.columnTextDup(allocator, 5);
        defer allocator.free(state_at);
        const base_ref = try stmt.columnTextDup(allocator, 6);
        defer allocator.free(base_ref);
        const head_ref = try stmt.columnTextDup(allocator, 7);
        defer allocator.free(head_ref);
        const draft = stmt.columnInt(8) != 0;
        const comment_count = @as(usize, @intCast(stmt.columnInt64(9)));
        const legacy_number = stmt.columnInt64(10);

        try appendPullListRow(&buf, allocator, &db, id, title, state, author, opened_at, state_at, base_ref, head_ref, draft, comment_count, legacy_number);
        shown += 1;
    }

    if (shown == 0) {
        switch (filter) {
            .open => try appendEmptyState(&buf, allocator, "No open pull requests.", "Create a pull request from a branch with proposed changes."),
            .merged => try appendEmptyState(&buf, allocator, "No merged pull requests.", "Merged pull requests will appear here after a pull.merged event is accepted."),
            .closed => try appendEmptyState(&buf, allocator, "No closed pull requests.", "Closed pull requests are pull requests that were closed without being merged."),
            .all => try appendEmptyState(&buf, allocator, "No pull requests yet.", "Open the first pull request from the web UI or with gt pr create."),
        }
    }

    try buf.appendSlice(allocator, "</section>");
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn pullStateFilterFromTarget(allocator: Allocator, target: []const u8) !?PullStateFilter {
    const state_value = try queryValueOwned(allocator, target, "state");
    defer if (state_value) |value| allocator.free(value);
    const value = state_value orelse return null;
    if (std.mem.eql(u8, value, "open")) return .open;
    if (std.mem.eql(u8, value, "merged")) return .merged;
    if (std.mem.eql(u8, value, "closed")) return .closed;
    if (std.mem.eql(u8, value, "all")) return .all;
    return null;
}

fn pullDetailTabFromTarget(allocator: Allocator, target: []const u8) !PullDetailTab {
    const tab_value = try queryValueOwned(allocator, target, "tab");
    defer if (tab_value) |value| allocator.free(value);
    const value = tab_value orelse return .conversation;
    if (std.mem.eql(u8, value, "commits")) return .commits;
    if (std.mem.eql(u8, value, "files")) return .files;
    return .conversation;
}

fn pullListSql(filter: PullStateFilter) []const u8 {
    const select =
        \\SELECT p.id, p.title, p.state, COALESCE(NULLIF(pm.source_author, ''), p.author_principal), p.opened_at, p.state_occurred_at,
        \\       p.base_ref, p.head_ref, p.draft,
        \\       (SELECT COUNT(*) FROM comments c WHERE c.parent_kind = 'pull' AND c.parent_id = p.id),
        \\       COALESCE(a.number, 0)
        \\FROM pulls p
        \\LEFT JOIN legacy_aliases a
        \\  ON a.provider = 'github' AND a.object_kind = 'pull' AND a.object_id = p.id
        \\LEFT JOIN pull_metadata pm ON pm.pull_id = p.id
    ;
    return switch (filter) {
        .open => select ++
            \\ WHERE p.state = 'open'
            \\ ORDER BY p.opened_at DESC, p.id DESC
        ,
        .merged => select ++
            \\ WHERE p.state = 'merged'
            \\ ORDER BY p.state_occurred_at DESC, p.opened_at DESC, p.id DESC
        ,
        .closed => select ++
            \\ WHERE p.state = 'closed'
            \\ ORDER BY p.state_occurred_at DESC, p.opened_at DESC, p.id DESC
        ,
        .all => select ++
            \\ ORDER BY p.state_occurred_at DESC, p.opened_at DESC, p.id DESC
        ,
    };
}

fn loadPullCounts(db: *SqliteDb) !PullCounts {
    var counts: PullCounts = .{};
    var stmt = try db.prepare("SELECT state, COUNT(*) FROM pulls GROUP BY state");
    defer stmt.deinit();
    while (try stmt.step()) {
        const state = try stmt.columnTextDup(db.allocator, 0);
        defer db.allocator.free(state);
        const count = @as(usize, @intCast(stmt.columnInt64(1)));
        counts.all += count;
        if (std.mem.eql(u8, state, "open")) {
            counts.open = count;
        } else if (std.mem.eql(u8, state, "merged")) {
            counts.merged = count;
        } else if (std.mem.eql(u8, state, "closed")) {
            counts.closed = count;
        }
    }
    return counts;
}

fn appendPullsToolbar(buf: *std.ArrayList(u8), allocator: Allocator, filter: PullStateFilter) !void {
    try appendTemplate(buf, allocator,
        \\<div class="pulls-toolbar issues-toolbar">
        \\  <form class="issues-search" action="/pulls" method="get">
        \\    <span class="issues-search-icon" aria-hidden="true"></span>
        \\    <input type="search" name="q" value="{query}" aria-label="Search pull requests">
        \\    <input type="hidden" name="state" value="{state}">
        \\  </form>
        \\  <div class="issues-toolbar-actions">
        \\    <button class="button secondary issue-tool-button" type="button" disabled><span class="button-icon icon-labels" aria-hidden="true"></span><span>Labels</span></button>
        \\    <button class="button secondary issue-tool-button" type="button" disabled><span class="button-icon icon-reviewers" aria-hidden="true"></span><span>Reviewers</span></button>
        \\    <a class="button primary" href="/new-pull">New pull request</a>
        \\  </div>
        \\</div>
    , .{
        .query = pullSearchQuery(filter),
        .state = pullStateValue(filter),
    });
}

fn appendPullsListHeader(buf: *std.ArrayList(u8), allocator: Allocator, filter: PullStateFilter, counts: PullCounts) !void {
    try buf.appendSlice(allocator,
        \\<header class="pulls-list-head issues-list-head">
        \\  <div class="issues-select-all"><input type="checkbox" aria-label="Select all pull requests" disabled></div>
        \\  <nav class="issues-state-tabs" aria-label="Pull request state">
    );
    try appendPullStateTab(buf, allocator, "Open", counts.open, .open, filter, "issue-open-icon");
    try appendPullStateTab(buf, allocator, "Merged", counts.merged, .merged, filter, "pull-merged-icon");
    try appendPullStateTab(buf, allocator, "Closed", counts.closed, .closed, filter, "pull-closed-icon");
    try buf.appendSlice(allocator,
        \\  </nav>
        \\  <div class="issues-filter-menus">
        \\    <button type="button" disabled>Author</button>
        \\    <button type="button" disabled>Labels</button>
        \\    <button type="button" disabled>Reviewers</button>
        \\    <button type="button" disabled>Assignees</button>
        \\    <button type="button" disabled>Newest</button>
        \\  </div>
        \\</header>
    );
}

fn appendPullStateTab(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    label: []const u8,
    count: usize,
    tab_filter: PullStateFilter,
    active_filter: PullStateFilter,
    icon_class: []const u8,
) !void {
    try appendTemplate(buf, allocator,
        \\<a class="{classes}" href="/pulls?state={state}"><span class="issue-tab-icon {icon_class}" aria-hidden="true"></span><span>{label}</span><span class="issue-count-badge">{count}</span></a>
    , .{
        .classes = shared.classes("issues-state-tab", &.{shared.class("active", tab_filter == active_filter)}),
        .state = pullStateValue(tab_filter),
        .icon_class = icon_class,
        .label = label,
        .count = count,
    });
}

fn appendPullListRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    id: []const u8,
    title: []const u8,
    state: []const u8,
    author: []const u8,
    opened_at: []const u8,
    state_at: []const u8,
    base_ref: []const u8,
    head_ref: []const u8,
    draft: bool,
    comment_count: usize,
    legacy_number: i64,
) !void {
    var pull_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const pull_ref = util.shortObjectRef(&pull_ref_buf, id);
    try appendTemplate(buf, allocator,
        \\<article class="pull-list-row issue-list-row is-{state}">
        \\  <div class="issue-select-cell"><input type="checkbox" aria-label="Select pull request {id}" disabled></div>
        \\  <div class="issue-state-cell"><span class="issue-state-icon pull-state-icon {state}" title="{state}" aria-label="{state}"></span></div>
        \\  <div class="issue-row-content">
        \\    <div class="issue-row-title-line"><a class="issue-row-title" href="{href}">{title}</a>
    , .{
        .state = state,
        .id = pull_ref,
        .href = pullHref(pull_ref),
        .title = title,
    });
    if (draft) try buf.appendSlice(allocator, "<span class=\"issue-label label-default\">Draft</span>");
    try appendPullRowCollection(buf, allocator, db, "SELECT DISTINCT label FROM pull_labels WHERE pull_id = ? ORDER BY label", id, "issue-row-labels", true);
    try appendTemplate(buf, allocator,
        \\</div><p class="issue-row-meta">#{id}
    , .{ .id = pull_ref });
    if (legacy_number > 0) {
        try buf.appendSlice(allocator, " / GitHub ");
        try appendLegacyPullLink(buf, allocator, legacy_number);
    }
    try appendTemplate(buf, allocator,
        \\ by {author} {verb}
    , .{
        .author = author,
        .verb = if (std.mem.eql(u8, state, "open")) "opened" else "was updated",
    });
    try buf.append(allocator, ' ');
    try appendRelativeTime(buf, allocator, if (std.mem.eql(u8, state, "open")) opened_at else state_at);
    try appendTemplate(buf, allocator,
        \\</p><p class="pull-branch-line"><span>{head_ref}</span><span aria-hidden="true">-&gt;</span><span>{base_ref}</span></p></div>
        \\  <div class="issue-row-side">
    , .{
        .head_ref = head_ref,
        .base_ref = base_ref,
    });
    try appendPullRowCollection(buf, allocator, db, "SELECT DISTINCT reviewer FROM pull_reviewers WHERE pull_id = ? ORDER BY reviewer", id, "issue-row-assignees", false);
    if (comment_count > 0) {
        try appendTemplate(buf, allocator,
            \\<span class="issue-comments" title="Comments"><span class="issue-comments-icon" aria-hidden="true"></span>{comment_count}</span>
        , .{ .comment_count = comment_count });
    }
    try appendAvatar(buf, allocator, author, "issue-author-avatar");
    try buf.appendSlice(allocator,
        \\  </div>
        \\</article>
    );
}

fn appendPullRowCollection(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    comptime sql_text: []const u8,
    pull_id: []const u8,
    wrapper_class: []const u8,
    labels: bool,
) !void {
    var stmt = try db.prepare(sql_text);
    defer stmt.deinit();
    try stmt.bindText(1, pull_id);
    var shown = false;
    while (try stmt.step()) {
        const value = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(value);
        if (!shown) {
            try appendTemplate(buf, allocator, "<span class=\"{wrapper_class}\">", .{ .wrapper_class = wrapper_class });
            shown = true;
        }
        if (labels) {
            try appendLabel(buf, allocator, value);
        } else {
            try appendAvatar(buf, allocator, value, "");
        }
    }
    if (shown) try buf.appendSlice(allocator, "</span>");
}

pub fn renderPullDetailPage(allocator: Allocator, repo: Repo, raw_ref: []const u8, target: []const u8) ![]u8 {
    if (try shared.renderIndexingPageIfStale(allocator, repo, "Pull Request", "pulls", target)) |body| return body;
    try index.ensureIndex(allocator, repo);
    const pull_id = index.resolvePullId(allocator, repo, raw_ref) catch {
        return renderPullNotFound(allocator, repo, raw_ref);
    };
    defer allocator.free(pull_id);

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    const detail = (try loadPullDetail(allocator, &db, pull_id)) orelse return renderPullNotFound(allocator, repo, raw_ref);
    defer detail.deinit(allocator);
    const tab = try pullDetailTabFromTarget(allocator, target);

    var pull_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const pull_ref = util.shortObjectRef(&pull_ref_buf, detail.id);
    const tab_counts = try loadPullTabCounts(allocator, repo, &db, detail);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, detail.title, "pulls");
    try buf.appendSlice(allocator, "<section class=\"pull-detail issue-page\">");
    try appendPullPageHeader(&buf, allocator, detail, pull_ref, tab_counts);
    try appendPullTabs(&buf, allocator, pull_ref, tab, tab_counts);
    try appendTemplate(&buf, allocator,
        \\<div class="issue-conversation-layout pull-conversation-layout">
        \\  <div class="pull-tab-content">
    , .{});
    const current_actor = try shared.currentPrincipalOwned(allocator, repo);
    defer if (current_actor) |actor| allocator.free(actor);
    switch (tab) {
        .conversation => try appendPullConversation(&buf, allocator, &db, detail, raw_ref, current_actor),
        .commits => try appendPullCommits(&buf, allocator, repo, detail),
        .files => try appendPullFiles(&buf, allocator, repo, detail),
    }
    try buf.appendSlice(allocator, "</div><aside class=\"issue-meta-sidebar pull-sidebar\">");
    try appendPullSidebar(&buf, allocator, repo, &db, detail, pull_ref);
    try buf.appendSlice(allocator, "</aside></div></section>");
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn loadPullDetail(allocator: Allocator, db: *SqliteDb, pull_id: []const u8) !?PullDetail {
    var stmt = try db.prepare(
        \\SELECT p.id, p.title, p.state, p.author_principal, p.author_device, p.opened_at, p.body,
        \\       p.base_ref, p.head_ref, p.draft, p.merge_oid, p.target_oid, COALESCE(a.number, 0),
        \\       p.state_occurred_at, p.state_actor_principal,
        \\       COALESCE(pm.source_author, ''), COALESCE(pm.commit_count, -1), COALESCE(pm.changed_files, -1),
        \\       COALESCE(pm.additions, -1), COALESCE(pm.deletions, -1)
        \\FROM pulls p
        \\LEFT JOIN legacy_aliases a
        \\  ON a.provider = 'github' AND a.object_kind = 'pull' AND a.object_id = p.id
        \\LEFT JOIN pull_metadata pm ON pm.pull_id = p.id
        \\WHERE p.id = ?
    );
    defer stmt.deinit();
    try stmt.bindText(1, pull_id);
    if (!(try stmt.step())) return null;
    return .{
        .id = try stmt.columnTextDup(allocator, 0),
        .title = try stmt.columnTextDup(allocator, 1),
        .state = try stmt.columnTextDup(allocator, 2),
        .author_principal = try stmt.columnTextDup(allocator, 3),
        .author_device = try stmt.columnTextDup(allocator, 4),
        .source_author = try stmt.columnTextDup(allocator, 15),
        .opened_at = try stmt.columnTextDup(allocator, 5),
        .state_occurred_at = try stmt.columnTextDup(allocator, 13),
        .state_actor_principal = try stmt.columnTextDup(allocator, 14),
        .body = try stmt.columnTextDup(allocator, 6),
        .base_ref = try stmt.columnTextDup(allocator, 7),
        .head_ref = try stmt.columnTextDup(allocator, 8),
        .draft = stmt.columnInt(9) != 0,
        .merge_oid = try stmt.columnTextDup(allocator, 10),
        .target_oid = try stmt.columnTextDup(allocator, 11),
        .legacy_number = stmt.columnInt64(12),
        .commit_count = optionalCount(stmt.columnInt64(16)),
        .changed_files = optionalCount(stmt.columnInt64(17)),
        .additions = optionalCount(stmt.columnInt64(18)),
        .deletions = optionalCount(stmt.columnInt64(19)),
    };
}

fn renderPullNotFound(allocator: Allocator, repo: Repo, raw_ref: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try appendShellStart(&buf, allocator, repo, "Pull Request Not Found", "pulls");
    const detail = try std.fmt.allocPrint(allocator, "No pull request matches {s}.", .{raw_ref});
    defer allocator.free(detail);
    try appendEmptyState(&buf, allocator, "Pull request not found.", detail);
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn loadPullTabCounts(allocator: Allocator, repo: Repo, db: *SqliteDb, detail: PullDetail) !PullTabCounts {
    var counts: PullTabCounts = .{};
    var comments = try db.prepare("SELECT COUNT(*) FROM comments WHERE parent_kind = 'pull' AND parent_id = ?");
    defer comments.deinit();
    try comments.bindText(1, detail.id);
    if (try comments.step()) counts.comments = @as(usize, @intCast(comments.columnInt64(0)));
    counts.commits = detail.commit_count;
    counts.files = detail.changed_files;
    counts.additions = detail.additions;
    counts.deletions = detail.deletions;

    const git_counts = try loadPullGitTabCounts(allocator, repo, detail.base_ref, detail.head_ref);
    if (git_counts.commits) |value| counts.commits = value;
    if (git_counts.files) |value| counts.files = value;
    return counts;
}

fn loadPullGitTabCounts(allocator: Allocator, repo: Repo, base_ref: []const u8, head_ref: []const u8) !PullTabCounts {
    var counts: PullTabCounts = .{};
    const merge_base = try loadMergeBase(allocator, repo, base_ref, head_ref);
    defer if (merge_base) |value| allocator.free(value);
    const base = merge_base orelse return counts;

    const range = try std.fmt.allocPrint(allocator, "{s}..{s}", .{ base, head_ref });
    defer allocator.free(range);
    if (try gitMaybe(allocator, repo, &.{ "rev-list", "--count", range }, 64 * 1024)) |raw_count| {
        defer allocator.free(raw_count);
        const trimmed = std.mem.trim(u8, raw_count, " \t\r\n");
        counts.commits = std.fmt.parseUnsigned(usize, trimmed, 10) catch null;
    }

    if (try gitMaybe(allocator, repo, &.{ "diff", "--name-only", "--find-renames", base, head_ref }, max_pull_diff_bytes)) |raw_files| {
        defer allocator.free(raw_files);
        var files: usize = 0;
        var lines = std.mem.splitScalar(u8, raw_files, '\n');
        while (lines.next()) |raw_line| {
            if (std.mem.trim(u8, raw_line, " \t\r\n").len != 0) files += 1;
        }
        counts.files = files;
    }

    return counts;
}

fn appendPullPageHeader(buf: *std.ArrayList(u8), allocator: Allocator, detail: PullDetail, pull_ref: []const u8, counts: PullTabCounts) !void {
    try appendTemplate(buf, allocator,
        \\<header class="issue-page-head pull-page-head">
        \\  <div class="issue-title-line">
        \\    <h1><span>{title}</span> <span class="issue-page-number">
    , .{ .title = detail.title });
    try appendPullDisplayRef(buf, allocator, detail, pull_ref);
    try appendTemplate(buf, allocator,
        \\</span></h1>
        \\    <div class="issue-page-actions">
        \\      <a class="button secondary" href="/pulls">Back to PRs</a>
        \\      <a class="button primary" href="/new-pull">New pull request</a>
        \\      <button class="issue-copy-button" type="button" disabled aria-label="Copy pull request link"><span class="button-icon icon-copy" aria-hidden="true"></span></button>
        \\    </div>
        \\  </div>
        \\  <div class="issue-status-line pull-status-line">
    , .{});
    try appendPullStateBadge(buf, allocator, detail.state, detail.draft);
    try appendPullHeaderSummary(buf, allocator, detail, counts);
    try buf.appendSlice(allocator, "</div></header>");
}

fn appendPullDisplayRef(buf: *std.ArrayList(u8), allocator: Allocator, detail: PullDetail, pull_ref: []const u8) !void {
    try buf.append(allocator, '#');
    if (detail.legacy_number > 0) {
        try std.fmt.format(buf.writer(allocator), "{d}", .{detail.legacy_number});
    } else {
        try shared.appendHtml(buf, allocator, pull_ref);
    }
}

fn appendPullHeaderSummary(buf: *std.ArrayList(u8), allocator: Allocator, detail: PullDetail, counts: PullTabCounts) !void {
    if (std.mem.eql(u8, detail.state, "merged")) {
        try appendTemplate(buf, allocator,
            \\<span><strong>{actor}</strong> merged 
        , .{
            .actor = if (detail.state_actor_principal.len != 0) detail.state_actor_principal else detail.author_principal,
        });
        try appendPullCommitSummary(buf, allocator, counts.commits);
        try appendTemplate(buf, allocator,
            \\ into <code>{base_ref}</code> from <code>{head_ref}</code>
        , .{
            .base_ref = detail.base_ref,
            .head_ref = detail.head_ref,
        });
        try buf.append(allocator, ' ');
        try appendRelativeTime(buf, allocator, detail.state_occurred_at);
        try buf.appendSlice(allocator, "</span>");
        return;
    }

    if (std.mem.eql(u8, detail.state, "closed")) {
        try appendTemplate(buf, allocator,
            \\<span><strong>{actor}</strong> closed this pull request
        , .{ .actor = if (detail.state_actor_principal.len != 0) detail.state_actor_principal else detail.author_principal });
        try buf.append(allocator, ' ');
        try appendRelativeTime(buf, allocator, detail.state_occurred_at);
        try buf.appendSlice(allocator, "</span>");
        return;
    }

    try appendTemplate(buf, allocator,
        \\<span><strong>{author}</strong> wants to merge 
    , .{
        .author = pullDisplayAuthor(detail),
    });
    try appendPullCommitSummary(buf, allocator, counts.commits);
    try appendTemplate(buf, allocator,
        \\ into <code>{base_ref}</code> from <code>{head_ref}</code></span>
    , .{
        .base_ref = detail.base_ref,
        .head_ref = detail.head_ref,
    });
}

fn pullDisplayAuthor(detail: PullDetail) []const u8 {
    return if (detail.source_author.len != 0) detail.source_author else detail.author_principal;
}

fn optionalCount(value: i64) ?usize {
    return if (value >= 0) @intCast(value) else null;
}

fn appendPullCommitSummary(buf: *std.ArrayList(u8), allocator: Allocator, count: ?usize) !void {
    const value = count orelse {
        try buf.appendSlice(allocator, "changes");
        return;
    };
    try appendTemplate(buf, allocator, "{commit_count} {commit_word}", .{
        .commit_count = value,
        .commit_word = commitWord(value),
    });
}

fn appendPullStateBadge(buf: *std.ArrayList(u8), allocator: Allocator, state: []const u8, draft: bool) !void {
    const badge_state = if (draft and std.mem.eql(u8, state, "open")) "draft" else state;
    try appendTemplate(buf, allocator,
        \\<span class="issue-state-badge pull-state-badge is-{state}"><span class="issue-state-mark" aria-hidden="true"></span>{label}</span>
    , .{
        .state = badge_state,
        .label = pullStateLabel(badge_state),
    });
}

fn pullStateLabel(state: []const u8) []const u8 {
    if (std.mem.eql(u8, state, "open")) return "Open";
    if (std.mem.eql(u8, state, "merged")) return "Merged";
    if (std.mem.eql(u8, state, "closed")) return "Closed";
    if (std.mem.eql(u8, state, "draft")) return "Draft";
    return state;
}

fn appendPullTabs(buf: *std.ArrayList(u8), allocator: Allocator, pull_ref: []const u8, active: PullDetailTab, counts: PullTabCounts) !void {
    try buf.appendSlice(allocator, "<nav class=\"view-tabs pull-tabs\" aria-label=\"Pull request view\">");
    try appendPullTab(buf, allocator, pull_ref, "Conversation", .conversation, active, counts.comments);
    try appendPullTabOptionalCount(buf, allocator, pull_ref, "Commits", .commits, active, counts.commits);
    try appendPullTabOptionalCount(buf, allocator, pull_ref, "Files changed", .files, active, counts.files);
    try buf.appendSlice(allocator, "</nav>");
}

fn appendPullTabOptionalCount(buf: *std.ArrayList(u8), allocator: Allocator, pull_ref: []const u8, label: []const u8, tab: PullDetailTab, active: PullDetailTab, count: ?usize) !void {
    try appendPullTabStart(buf, allocator, pull_ref, label, tab, active);
    if (count) |value| try appendTemplate(buf, allocator, "<span class=\"issue-count-badge\">{count}</span>", .{ .count = value });
    try buf.appendSlice(allocator, "</a>");
}

fn appendPullTab(buf: *std.ArrayList(u8), allocator: Allocator, pull_ref: []const u8, label: []const u8, tab: PullDetailTab, active: PullDetailTab, count: usize) !void {
    try appendPullTabStart(buf, allocator, pull_ref, label, tab, active);
    try appendTemplate(buf, allocator, "<span class=\"issue-count-badge\">{count}</span>", .{ .count = count });
    try buf.appendSlice(allocator, "</a>");
}

fn appendPullTabStart(buf: *std.ArrayList(u8), allocator: Allocator, pull_ref: []const u8, label: []const u8, tab: PullDetailTab, active: PullDetailTab) !void {
    try appendTemplate(buf, allocator,
        \\<a class="{classes}" href="/pulls/{pull_ref}{suffix}"><span class="pull-tab-icon {icon}" aria-hidden="true"></span><span>{label}</span>
    , .{
        .classes = shared.classes("", &.{shared.class("active", tab == active)}),
        .pull_ref = pull_ref,
        .suffix = pullTabSuffix(tab),
        .label = label,
        .icon = pullTabIconClass(tab),
    });
}

fn pullTabSuffix(tab: PullDetailTab) []const u8 {
    return switch (tab) {
        .conversation => "",
        .commits => "?tab=commits",
        .files => "?tab=files",
    };
}

fn pullTabIconClass(tab: PullDetailTab) []const u8 {
    return switch (tab) {
        .conversation => "pull-tab-conversation-icon",
        .commits => "pull-tab-commits-icon",
        .files => "pull-tab-files-icon",
    };
}

fn appendPullFacts(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, db: *SqliteDb, detail: PullDetail, pull_ref: []const u8) !void {
    try buf.appendSlice(allocator, "<aside class=\"pull-sidebar\"><dl class=\"facts issue-facts\">");
    try buf.appendSlice(allocator, "<div><dt>Status</dt><dd>");
    try appendPullStatePill(buf, allocator, detail.state, detail.draft);
    try appendTemplate(buf, allocator,
        \\</dd></div><div><dt>ID</dt><dd><code>{id}</code></dd></div><div><dt>Opened</dt><dd>
    , .{
        .id = detail.id,
    });
    try appendRelativeTime(buf, allocator, detail.opened_at);
    try appendTemplate(buf, allocator,
        \\</dd></div><div><dt>Author</dt><dd>{author}/{device}</dd></div><div><dt>Base</dt><dd><code>{base_ref}</code></dd></div><div><dt>Head</dt><dd><code>{head_ref}</code></dd></div>
    , .{
        .author = detail.author_principal,
        .device = detail.author_device,
        .base_ref = detail.base_ref,
        .head_ref = detail.head_ref,
    });
    if (detail.legacy_number > 0) {
        try buf.appendSlice(allocator, "<div><dt>GitHub</dt><dd>");
        try appendLegacyPullLink(buf, allocator, detail.legacy_number);
        try buf.appendSlice(allocator, "</dd></div>");
    }
    if (detail.merge_oid.len != 0) {
        try appendTemplate(buf, allocator, "<div><dt>Merge OID</dt><dd><code>{merge_oid}</code></dd></div>", .{ .merge_oid = detail.merge_oid });
    }
    if (detail.target_oid.len != 0) {
        try appendTemplate(buf, allocator, "<div><dt>Target OID</dt><dd><code>{target_oid}</code></dd></div>", .{ .target_oid = detail.target_oid });
    }
    if (detail.merge_oid.len != 0 or detail.target_oid.len != 0) {
        try buf.appendSlice(allocator, "<div><dt>Local merge</dt><dd>");
        try appendLocalMergeCheck(buf, allocator, repo, detail);
        try buf.appendSlice(allocator, "</dd></div>");
    }
    try appendPullCollectionFact(buf, allocator, db, "Labels", "SELECT DISTINCT label FROM pull_labels WHERE pull_id = ? ORDER BY label", detail.id);
    try appendPullCollectionFact(buf, allocator, db, "Assignees", "SELECT DISTINCT assignee FROM pull_assignees WHERE pull_id = ? ORDER BY assignee", detail.id);
    try appendPullCollectionFact(buf, allocator, db, "Reviewers", "SELECT DISTINCT reviewer FROM pull_reviewers WHERE pull_id = ? ORDER BY reviewer", detail.id);
    try appendTemplate(buf, allocator, "<div><dt>Link</dt><dd><a href=\"/pulls/{pull_ref}\">/pulls/{pull_ref}</a></dd></div>", .{ .pull_ref = pull_ref });
    try buf.appendSlice(allocator, "</dl></aside>");
}

fn appendPullCollectionFact(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, label: []const u8, comptime sql_text: []const u8, pull_id: []const u8) !void {
    try appendTemplate(buf, allocator, "<div><dt>{label}</dt><dd class=\"pill-list\">", .{ .label = label });
    var stmt = try db.prepare(sql_text);
    defer stmt.deinit();
    try stmt.bindText(1, pull_id);
    var shown = false;
    while (try stmt.step()) {
        const value = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(value);
        try appendPill(buf, allocator, value);
        shown = true;
    }
    if (!shown) try buf.appendSlice(allocator, "<span class=\"muted\">None</span>");
    try buf.appendSlice(allocator, "</dd></div>");
}

fn appendPullSidebar(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, db: *SqliteDb, detail: PullDetail, pull_ref: []const u8) !void {
    try appendPullSidebarPeopleSection(buf, allocator, db, "Reviewers", "Manage reviewers", "SELECT DISTINCT reviewer FROM pull_reviewers WHERE pull_id = ? ORDER BY reviewer", detail.id, "No reviewers");
    try appendPullSidebarPeopleSection(buf, allocator, db, "Assignees", "Manage assignees", "SELECT DISTINCT assignee FROM pull_assignees WHERE pull_id = ? ORDER BY assignee", detail.id, "No one assigned");
    try appendPullSidebarLabels(buf, allocator, db, detail.id);
    try appendPullSidebarEmptySection(buf, allocator, "Projects", "Manage projects", "No projects");
    try appendPullSidebarEmptySection(buf, allocator, "Milestone", "Set milestone", "No milestone");
    try appendPullSidebarDevelopment(buf, allocator, repo, detail, pull_ref);
    try appendPullSidebarNotifications(buf, allocator);
    try appendPullSidebarParticipants(buf, allocator, db, detail);
}

fn appendPullSidebarSectionStart(buf: *std.ArrayList(u8), allocator: Allocator, title: []const u8, menu_label: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<section class="issue-sidebar-section"><div class="issue-sidebar-heading"><h2>{title}</h2><button class="pull-sidebar-gear" type="button" disabled aria-label="{menu_label}" title="{menu_label}"><span class="issue-sidebar-menu-icon" aria-hidden="true"></span></button></div>
    , .{
        .title = title,
        .menu_label = menu_label,
    });
}

fn appendPullSidebarSectionEnd(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator, "</section>");
}

fn appendPullSidebarPeopleSection(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    title: []const u8,
    menu_label: []const u8,
    comptime sql_text: []const u8,
    pull_id: []const u8,
    empty_text: []const u8,
) !void {
    try appendPullSidebarSectionStart(buf, allocator, title, menu_label);
    var stmt = try db.prepare(sql_text);
    defer stmt.deinit();
    try stmt.bindText(1, pull_id);
    var shown = false;
    while (try stmt.step()) {
        const person = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(person);
        try appendPullSidebarPerson(buf, allocator, person);
        shown = true;
    }
    if (!shown) try appendTemplate(buf, allocator, "<p class=\"issue-sidebar-empty\">{empty_text}</p>", .{ .empty_text = empty_text });
    try appendPullSidebarSectionEnd(buf, allocator);
}

fn appendPullSidebarLabels(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, pull_id: []const u8) !void {
    try appendPullSidebarSectionStart(buf, allocator, "Labels", "Manage labels");
    var stmt = try db.prepare("SELECT DISTINCT label FROM pull_labels WHERE pull_id = ? ORDER BY label");
    defer stmt.deinit();
    try stmt.bindText(1, pull_id);
    var shown = false;
    while (try stmt.step()) {
        const label = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(label);
        if (!shown) {
            try buf.appendSlice(allocator, "<div class=\"issue-sidebar-labels\">");
            shown = true;
        }
        try appendLabel(buf, allocator, label);
    }
    if (shown) {
        try buf.appendSlice(allocator, "</div>");
    } else {
        try buf.appendSlice(allocator, "<p class=\"issue-sidebar-empty\">None yet</p>");
    }
    try appendPullSidebarSectionEnd(buf, allocator);
}

fn appendPullSidebarEmptySection(buf: *std.ArrayList(u8), allocator: Allocator, title: []const u8, menu_label: []const u8, empty_text: []const u8) !void {
    try appendPullSidebarSectionStart(buf, allocator, title, menu_label);
    try appendTemplate(buf, allocator, "<p class=\"issue-sidebar-empty\">{empty_text}</p>", .{ .empty_text = empty_text });
    try appendPullSidebarSectionEnd(buf, allocator);
}

fn appendPullSidebarDevelopment(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, detail: PullDetail, pull_ref: []const u8) !void {
    try appendPullSidebarSectionStart(buf, allocator, "Development", "Link development");
    try appendTemplate(buf, allocator,
        \\<p class="issue-sidebar-empty">Successfully merging this pull request may close linked issues.</p>
        \\<div class="pull-sidebar-branches"><span><strong>Base</strong><code>{base_ref}</code></span><span><strong>Head</strong><code>{head_ref}</code></span></div>
    , .{
        .base_ref = detail.base_ref,
        .head_ref = detail.head_ref,
    });
    if (detail.commit_count != null or detail.changed_files != null or detail.additions != null or detail.deletions != null) {
        try buf.appendSlice(allocator, "<div class=\"pull-sidebar-metrics\">");
        if (detail.commit_count) |count| try appendTemplate(buf, allocator, "<span>{count} {word}</span>", .{ .count = count, .word = commitWord(count) });
        if (detail.changed_files) |count| try appendTemplate(buf, allocator, "<span>{count} changed {word}</span>", .{ .count = count, .word = if (count == 1) "file" else "files" });
        if (detail.additions != null or detail.deletions != null) {
            try appendTemplate(buf, allocator, "<span><strong>+{additions}</strong> <em>-{deletions}</em></span>", .{
                .additions = detail.additions orelse 0,
                .deletions = detail.deletions orelse 0,
            });
        }
        try buf.appendSlice(allocator, "</div>");
    }
    if (detail.merge_oid.len != 0) {
        try appendTemplate(buf, allocator,
            \\<a class="issue-sidebar-link-row" href="{href}"><span class="issue-sidebar-row-kind">merge</span><code>{short_oid}</code></a>
        , .{
            .href = commitHref(detail.merge_oid),
            .short_oid = detail.merge_oid[0..@min(detail.merge_oid.len, 12)],
        });
    }
    if (detail.target_oid.len != 0) {
        try appendTemplate(buf, allocator,
            \\<a class="issue-sidebar-link-row" href="{href}"><span class="issue-sidebar-row-kind">target</span><code>{short_oid}</code></a>
        , .{
            .href = commitHref(detail.target_oid),
            .short_oid = detail.target_oid[0..@min(detail.target_oid.len, 12)],
        });
    }
    if (detail.merge_oid.len != 0 or detail.target_oid.len != 0) {
        try buf.appendSlice(allocator, "<p class=\"pull-sidebar-note\">");
        try appendLocalMergeCheck(buf, allocator, repo, detail);
        try buf.appendSlice(allocator, "</p>");
    }
    try appendTemplate(buf, allocator, "<p class=\"pull-sidebar-note\"><a href=\"/pulls/{pull_ref}\">/pulls/{pull_ref}</a></p>", .{ .pull_ref = pull_ref });
    try appendPullSidebarSectionEnd(buf, allocator);
}

fn appendPullSidebarNotifications(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try appendPullSidebarSectionStart(buf, allocator, "Notifications", "Customize notifications");
    try buf.appendSlice(allocator,
        \\<button class="button secondary issue-sidebar-full-button" type="button" disabled>Subscribe</button>
        \\<p class="issue-sidebar-empty">You're receiving notifications because you modified this pull request.</p>
    );
    try appendPullSidebarSectionEnd(buf, allocator);
}

fn appendPullSidebarParticipants(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, detail: PullDetail) !void {
    try appendPullSidebarSectionStart(buf, allocator, "Participants", "Manage participants");
    try buf.appendSlice(allocator, "<div class=\"issue-participants\">");
    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var keys = seen.keyIterator();
        while (keys.next()) |key| allocator.free(key.*);
        seen.deinit();
    }
    try appendPullSidebarParticipant(buf, allocator, &seen, pullDisplayAuthor(detail));
    try appendPullSidebarParticipantQuery(buf, allocator, db, &seen, "SELECT DISTINCT assignee FROM pull_assignees WHERE pull_id = ? ORDER BY assignee", detail.id);
    try appendPullSidebarParticipantQuery(buf, allocator, db, &seen, "SELECT DISTINCT reviewer FROM pull_reviewers WHERE pull_id = ? ORDER BY reviewer", detail.id);
    try buf.appendSlice(allocator, "</div>");
    try appendPullSidebarSectionEnd(buf, allocator);
}

fn appendPullSidebarParticipantQuery(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    seen: *std.StringHashMap(void),
    comptime sql_text: []const u8,
    pull_id: []const u8,
) !void {
    var stmt = try db.prepare(sql_text);
    defer stmt.deinit();
    try stmt.bindText(1, pull_id);
    while (try stmt.step()) {
        const person = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(person);
        try appendPullSidebarParticipant(buf, allocator, seen, person);
    }
}

fn appendPullSidebarParticipant(buf: *std.ArrayList(u8), allocator: Allocator, seen: *std.StringHashMap(void), person: []const u8) !void {
    if (person.len == 0 or seen.contains(person)) return;
    const key = try allocator.dupe(u8, person);
    errdefer allocator.free(key);
    try seen.put(key, {});
    try appendAvatar(buf, allocator, person, "");
}

fn appendPullSidebarPerson(buf: *std.ArrayList(u8), allocator: Allocator, name: []const u8) !void {
    try buf.appendSlice(allocator, "<div class=\"issue-sidebar-person\">");
    try appendAvatar(buf, allocator, name, "");
    try appendTemplate(buf, allocator, "<span>{name}</span></div>", .{ .name = name });
}

fn appendPullConversation(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    detail: PullDetail,
    raw_ref: []const u8,
    current_actor: ?[]const u8,
) !void {
    try appendTemplate(buf, allocator,
        \\<div class="issue-conversation pull-conversation">
        \\  <div class="issue-timeline-item">
        \\    <div class="issue-timeline-avatar">
    , .{});
    try appendAvatar(buf, allocator, pullDisplayAuthor(detail), "issue-detail-avatar");
    try appendTemplate(buf, allocator,
        \\    </div>
        \\    <article class="issue-comment-box pull-card" id="pull-description">
        \\      <header class="issue-comment-head"><div><strong>{author}</strong><span>opened
    , .{ .author = pullDisplayAuthor(detail) });
    try buf.append(allocator, ' ');
    try appendRelativeTime(buf, allocator, detail.opened_at);
    try appendTemplate(buf, allocator,
        \\</span></div>
    , .{});
    try issues_page.appendIssueActionMenu(buf, allocator, "pull-description", "", detail.body, detail.body.len != 0, false);
    try appendTemplate(buf, allocator,
        \\</header>
        \\  <div class="markdown-body">
    , .{});
    if (detail.body.len == 0) {
        try buf.appendSlice(allocator, "<p class=\"muted\">No description provided.</p>");
    } else {
        try markdown_render.appendMarkdown(buf, allocator, detail.body);
    }
    try buf.appendSlice(allocator, "</div>");
    try appendPullReactionBar(buf, allocator, db, "pull", detail.id, raw_ref, "", current_actor);
    try buf.appendSlice(allocator, "</article></div>");
    try appendPullComments(buf, allocator, db, raw_ref, detail.id, current_actor);
    try appendPullResolutionTimeline(buf, allocator, detail);
    try appendPullCommentForm(buf, allocator, raw_ref, current_actor);
    try buf.appendSlice(allocator, "</div>");
}

fn appendPullComments(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    raw_ref: []const u8,
    pull_id: []const u8,
    current_actor: ?[]const u8,
) !void {
    var stmt = try db.prepare(
        \\SELECT id, body, redacted, COALESCE(NULLIF(source_author, ''), author_principal), created_at, reply_parent_id, reply_parent_hash
        \\FROM comments
        \\WHERE parent_kind = 'pull' AND parent_id = ?
        \\ORDER BY created_at, id
    );
    defer stmt.deinit();
    try stmt.bindText(1, pull_id);
    while (try stmt.step()) {
        const id = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(id);
        const body = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(body);
        const redacted = stmt.columnInt(2) != 0;
        const author = try stmt.columnTextDup(allocator, 3);
        defer allocator.free(author);
        const created_at = try stmt.columnTextDup(allocator, 4);
        defer allocator.free(created_at);
        const reply_parent_id = try stmt.columnTextDup(allocator, 5);
        defer allocator.free(reply_parent_id);
        const reply_parent_hash = try stmt.columnTextDup(allocator, 6);
        defer allocator.free(reply_parent_hash);
        const anchor = try std.fmt.allocPrint(allocator, "comment-{s}", .{id[0..@min(id.len, 7)]});
        defer allocator.free(anchor);
        var comment_ref_buf: [util.short_object_ref_len]u8 = undefined;
        const comment_ref = util.shortObjectRef(&comment_ref_buf, id);
        const comment_ref_value = try std.fmt.allocPrint(allocator, "comment:{s}", .{comment_ref});
        defer allocator.free(comment_ref_value);

        const is_reply = reply_parent_id.len != 0 or reply_parent_hash.len != 0;
        try appendTemplate(buf, allocator,
            \\<div class="{classes}" id="{anchor}"><div class="issue-timeline-avatar">
        , .{
            .classes = shared.classes("issue-timeline-item", &.{shared.class("is-reply", is_reply)}),
            .anchor = anchor,
        });
        try appendAvatar(buf, allocator, author, "issue-detail-avatar");
        try appendTemplate(buf, allocator,
            \\</div><article class="issue-comment-box comment-card"><header class="issue-comment-head"><div><strong>{author}</strong><span>commented
        , .{
            .author = author,
        });
        try buf.append(allocator, ' ');
        try appendRelativeTime(buf, allocator, created_at);
        try buf.appendSlice(allocator, "</span></div>");
        try issues_page.appendIssueActionMenu(buf, allocator, anchor, comment_ref_value, body, !redacted and body.len != 0, false);
        try buf.appendSlice(allocator, "</header>");
        if (reply_parent_id.len != 0 or reply_parent_hash.len != 0) {
            try buf.appendSlice(allocator, "<p class=\"reply-note\">Reply to ");
            if (reply_parent_id.len != 0) {
                var reply_ref_buf: [util.short_object_ref_len]u8 = undefined;
                const reply_ref = util.shortObjectRef(&reply_ref_buf, reply_parent_id);
                try appendTemplate(buf, allocator, "comment:{reply_ref}", .{ .reply_ref = reply_ref });
            } else {
                try appendTemplate(buf, allocator, "{reply_parent_hash}", .{ .reply_parent_hash = reply_parent_hash[0..@min(reply_parent_hash.len, 12)] });
            }
            try buf.appendSlice(allocator, "</p>");
        }
        try buf.appendSlice(allocator, "<div class=\"markdown-body\">");
        if (redacted) {
            try buf.appendSlice(allocator, "<p class=\"muted\">Comment redacted.</p>");
        } else {
            try markdown_render.appendMarkdown(buf, allocator, body);
        }
        try buf.appendSlice(allocator, "</div>");
        try appendPullReactionBar(buf, allocator, db, "comment", id, raw_ref, comment_ref_value, current_actor);
        try buf.appendSlice(allocator, "</article></div>");
    }
}

fn appendPullResolutionTimeline(buf: *std.ArrayList(u8), allocator: Allocator, detail: PullDetail) !void {
    if (!std.mem.eql(u8, detail.state, "merged") and !std.mem.eql(u8, detail.state, "closed")) return;

    try appendTemplate(buf, allocator,
        \\<div class="issue-timeline-item pull-event-item">
        \\  <div class="issue-timeline-avatar"><span class="pull-timeline-icon is-{state}" aria-hidden="true"></span></div>
        \\  <div class="pull-event-text"><strong>{actor}</strong> {verb} this pull request
    , .{
        .state = detail.state,
        .actor = if (detail.state_actor_principal.len != 0) detail.state_actor_principal else detail.author_principal,
        .verb = if (std.mem.eql(u8, detail.state, "merged")) "merged" else "closed",
    });
    if (std.mem.eql(u8, detail.state, "merged") and detail.merge_oid.len != 0) {
        try appendTemplate(buf, allocator,
            \\ with commit <a href="{href}"><code>{short_oid}</code></a>
        , .{
            .href = commitHref(detail.merge_oid),
            .short_oid = detail.merge_oid[0..@min(detail.merge_oid.len, 12)],
        });
    }
    try buf.append(allocator, ' ');
    try appendRelativeTime(buf, allocator, detail.state_occurred_at);
    try buf.appendSlice(allocator, "</div></div>");

    try appendTemplate(buf, allocator,
        \\<div class="issue-timeline-item pull-resolution-item">
        \\  <div class="issue-timeline-avatar"><span class="pull-timeline-icon is-{state}" aria-hidden="true"></span></div>
        \\  <div class="pull-resolution-box">
        \\    <h2>{title}</h2>
        \\    <p>{body}</p>
        \\  </div>
        \\</div>
    , .{
        .state = detail.state,
        .title = if (std.mem.eql(u8, detail.state, "merged")) "Pull request successfully merged and closed" else "Pull request closed",
        .body = if (std.mem.eql(u8, detail.state, "merged")) "The branch has been merged into the base ref." else "This pull request was closed without being merged.",
    });
}

fn appendPullReactionBar(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    object_kind: []const u8,
    object_id: []const u8,
    raw_pull_ref: []const u8,
    target_ref: []const u8,
    current_actor: ?[]const u8,
) !void {
    var reactions: std.ArrayList(ReactionSummary) = .empty;
    defer {
        for (reactions.items) |*item| item.deinit(allocator);
        reactions.deinit(allocator);
    }

    try buf.appendSlice(allocator, "<div class=\"reaction-bar\">");
    var stmt = try db.prepare(
        \\SELECT emoji, COUNT(DISTINCT actor_principal),
        \\       SUM(CASE WHEN actor_principal = ? THEN 1 ELSE 0 END)
        \\FROM reactions
        \\WHERE object_kind = ? AND object_id = ?
        \\GROUP BY emoji
        \\ORDER BY MIN(created_at), emoji
    );
    defer stmt.deinit();
    try stmt.bindText(1, current_actor orelse "");
    try stmt.bindText(2, object_kind);
    try stmt.bindText(3, object_id);

    while (try stmt.step()) {
        const emoji = try stmt.columnTextDup(allocator, 0);
        const count = stmt.columnInt64(1);
        const reacted = current_actor != null and stmt.columnInt64(2) > 0;
        errdefer allocator.free(emoji);
        try reactions.append(allocator, .{
            .emoji = emoji,
            .count = count,
            .reacted = reacted,
        });
    }

    try appendPullReactionPicker(buf, allocator, raw_pull_ref, object_kind, target_ref, reactions.items);
    for (reactions.items) |item| {
        try appendPullReactionButton(buf, allocator, raw_pull_ref, object_kind, target_ref, item.emoji, item.emoji, item.count, item.reacted);
    }
    try buf.appendSlice(allocator, "</div>");
}

fn appendPullReactionPicker(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_pull_ref: []const u8,
    object_kind: []const u8,
    target_ref: []const u8,
    reactions: []const ReactionSummary,
) !void {
    try buf.appendSlice(allocator,
        \\<details class="reaction-picker" data-popover-menu>
        \\  <summary class="reaction-add-button" aria-label="Add reaction" title="Add reaction"><span class="reaction-add-icon" aria-hidden="true"></span></summary>
        \\  <div class="reaction-popover" role="menu" aria-label="Add reaction">
    );
    for (reaction_choices) |choice| {
        try appendPullReactionChoiceButton(buf, allocator, raw_pull_ref, object_kind, target_ref, choice, pullReactionWasSelected(reactions, choice.value));
    }
    try buf.appendSlice(allocator, "</div></details>");
}

fn appendPullReactionChoiceButton(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_pull_ref: []const u8,
    object_kind: []const u8,
    target_ref: []const u8,
    choice: ReactionChoice,
    reacted: bool,
) !void {
    try appendPullReactionFormOpen(buf, allocator, raw_pull_ref, "reaction-choice-form", if (reacted) "remove-reaction" else "add-reaction", object_kind, target_ref, choice.value);
    try appendTemplate(buf, allocator,
        \\<button{class_attr} type="submit" role="menuitem" aria-pressed="{pressed}" title="{title}"><span class="reaction-emoji">
    , .{
        .class_attr = shared.classAttr("reaction-choice-button", &.{
            shared.class("selected", reacted),
            shared.class("is-selected", reacted),
        }),
        .pressed = reacted,
        .title = if (reacted) "Remove your reaction" else choice.title,
    });
    try shared.appendHtml(buf, allocator, choice.label);
    try buf.appendSlice(allocator, "</span></button></form>");
}

fn appendPullReactionButton(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_pull_ref: []const u8,
    object_kind: []const u8,
    target_ref: []const u8,
    emoji_value: []const u8,
    emoji_label: []const u8,
    count: i64,
    reacted: bool,
) !void {
    try appendPullReactionFormOpen(buf, allocator, raw_pull_ref, "reaction-form", if (reacted) "remove-reaction" else "add-reaction", object_kind, target_ref, emoji_value);
    try appendTemplate(buf, allocator,
        \\<button{class_attr} type="submit" aria-pressed="{pressed}" title="{title}"><span class="reaction-emoji">
    , .{
        .class_attr = shared.classAttr("reaction-button", &.{
            shared.class("selected", reacted),
            shared.class("is-selected", reacted),
        }),
        .pressed = reacted,
        .title = if (reacted) "Remove your reaction" else "Add reaction",
    });
    try shared.appendHtml(buf, allocator, emoji_label);
    try appendTemplate(buf, allocator, "</span><span class=\"reaction-count\">{count}</span></button></form>", .{ .count = count });
}

fn appendPullReactionFormOpen(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_pull_ref: []const u8,
    form_class: []const u8,
    action: []const u8,
    object_kind: []const u8,
    target_ref: []const u8,
    emoji_value: []const u8,
) !void {
    try appendTemplate(buf, allocator, "<form class=\"{form_class}\" method=\"post\" action=\"/pulls/", .{ .form_class = form_class });
    try shared.appendUrlEncoded(buf, allocator, raw_pull_ref);
    try appendTemplate(buf, allocator,
        \\/comments"><input type="hidden" name="action" value="{action}"><input type="hidden" name="target_kind" value="{object_kind}">
    , .{
        .action = action,
        .object_kind = object_kind,
    });
    if (target_ref.len != 0) {
        try appendTemplate(buf, allocator,
            \\<input type="hidden" name="target_ref" value="{target_ref}">
        , .{ .target_ref = target_ref });
    }
    try appendTemplate(buf, allocator,
        \\<input type="hidden" name="emoji" value="{emoji_value}">
    , .{ .emoji_value = emoji_value });
}

fn pullReactionWasSelected(reactions: []const ReactionSummary, emoji: []const u8) bool {
    for (reactions) |item| {
        if (std.mem.eql(u8, item.emoji, emoji)) return item.reacted;
    }
    return false;
}

fn appendPullCommentForm(buf: *std.ArrayList(u8), allocator: Allocator, raw_ref: []const u8, current_actor: ?[]const u8) !void {
    try buf.appendSlice(allocator,
        \\<div class="issue-timeline-item issue-comment-form-item">
        \\  <div class="issue-timeline-avatar">
    );
    try appendAvatar(buf, allocator, current_actor orelse "Current user", "issue-detail-avatar issue-comment-form-avatar");
    try buf.appendSlice(allocator,
        \\  </div>
        \\  <form class="issue-comment-box issue-comment-form" method="post" action="/pulls/
    );
    try shared.appendUrlEncoded(buf, allocator, raw_ref);
    try buf.appendSlice(allocator,
        \\/comments">
        \\  <input type="hidden" name="reply_parent_ref" value="" data-reply-parent-ref>
        \\  <textarea name="body" rows="5" placeholder="Leave a comment" required></textarea>
        \\  <div class="issue-comment-form-actions">
        \\    <button class="button primary" type="submit">Comment</button>
        \\  </div>
        \\</form>
        \\</div>
    );
}

fn appendPullCommits(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, detail: PullDetail) !void {
    const commits_opt = try loadPullCommits(allocator, repo, detail.base_ref, detail.head_ref);
    const commits = commits_opt orelse {
        if (detail.commit_count) |count| {
            const detail_text = try std.fmt.allocPrint(allocator, "GitHub reported {d} {s}. Fetch or create the base and head refs locally to inspect the commit list.", .{ count, commitWord(count) });
            defer allocator.free(detail_text);
            try appendEmptyState(buf, allocator, "Commit range unavailable.", detail_text);
        } else {
            try appendEmptyState(buf, allocator, "Commit range unavailable.", "Fetch or create the base and head refs locally to inspect this pull request.");
        }
        return;
    };
    defer freePullCommits(allocator, commits);
    if (commits.len == 0) {
        try appendEmptyState(buf, allocator, "No commits in this range.", "The head ref currently has no commits ahead of the merge base.");
        return;
    }
    try buf.appendSlice(allocator, "<section class=\"panel commits-panel\"><div class=\"commit-list\">");
    for (commits) |commit| {
        try appendTemplate(buf, allocator,
            \\<article class="commit-row pull-commit-row"><div><a class="commit-title" href="{href}">{subject}</a><p>{author} committed {relative}</p></div><code class="commit-sha">{short_hash}</code></article>
        , .{
            .href = commitHref(commit.full_hash),
            .subject = commit.subject,
            .author = commit.author,
            .relative = commit.relative,
            .short_hash = commit.short_hash,
        });
    }
    try buf.appendSlice(allocator, "</div></section>");
}

fn appendPullFiles(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, detail: PullDetail) !void {
    const diff_opt = try loadPullDiff(allocator, repo, detail.base_ref, detail.head_ref, 3);
    const diff = diff_opt orelse {
        if (detail.changed_files != null or detail.additions != null or detail.deletions != null) {
            const detail_text = try pullImportedFileSummary(allocator, detail);
            defer allocator.free(detail_text);
            try appendEmptyState(buf, allocator, "File changes unavailable.", detail_text);
        } else {
            try appendEmptyState(buf, allocator, "File changes unavailable.", "Fetch or create the base and head refs locally to inspect this pull request.");
        }
        return;
    };
    defer allocator.free(diff);
    try buf.appendSlice(allocator, "<section class=\"diff-section pull-diff-section\">");
    try appendPullDiff(buf, allocator, diff);
    try buf.appendSlice(allocator, "</section>");
}

fn pullImportedFileSummary(allocator: Allocator, detail: PullDetail) ![]u8 {
    const file_count = detail.changed_files orelse 0;
    const additions = detail.additions orelse 0;
    const deletions = detail.deletions orelse 0;
    if (detail.additions != null or detail.deletions != null) {
        return std.fmt.allocPrint(allocator, "GitHub reported {d} changed {s} with +{d} -{d}. Fetch or create the base and head refs locally to inspect the patch.", .{ file_count, if (file_count == 1) "file" else "files", additions, deletions });
    }
    return std.fmt.allocPrint(allocator, "GitHub reported {d} changed {s}. Fetch or create the base and head refs locally to inspect the patch.", .{ file_count, if (file_count == 1) "file" else "files" });
}

fn loadPullCommits(allocator: Allocator, repo: Repo, base_ref: []const u8, head_ref: []const u8) !?[]PullCommit {
    const merge_base = try loadMergeBase(allocator, repo, base_ref, head_ref);
    defer if (merge_base) |value| allocator.free(value);
    const base = merge_base orelse return null;
    const range = try std.fmt.allocPrint(allocator, "{s}..{s}", .{ base, head_ref });
    defer allocator.free(range);
    const raw = try gitMaybe(allocator, repo, &.{ "log", "--reverse", "--format=%H%x00%h%x00%an%x00%cr%x00%s", range }, git.max_git_output) orelse return null;
    defer allocator.free(raw);

    var commits: std.ArrayList(PullCommit) = .empty;
    errdefer {
        for (commits.items) |commit| commit.deinit(allocator);
        commits.deinit(allocator);
    }
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (line.len == 0) continue;
        var cols = std.mem.splitScalar(u8, line, 0);
        try commits.append(allocator, .{
            .full_hash = try allocator.dupe(u8, cols.next() orelse ""),
            .short_hash = try allocator.dupe(u8, cols.next() orelse ""),
            .author = try allocator.dupe(u8, cols.next() orelse ""),
            .relative = try allocator.dupe(u8, cols.next() orelse ""),
            .subject = try allocator.dupe(u8, cols.next() orelse ""),
        });
    }
    return try commits.toOwnedSlice(allocator);
}

fn loadPullDiff(allocator: Allocator, repo: Repo, base_ref: []const u8, head_ref: []const u8, context: usize) !?[]u8 {
    const merge_base = try loadMergeBase(allocator, repo, base_ref, head_ref);
    defer if (merge_base) |value| allocator.free(value);
    const base = merge_base orelse return null;
    const unified = try std.fmt.allocPrint(allocator, "--unified={d}", .{context});
    defer allocator.free(unified);
    return gitMaybe(allocator, repo, &.{ "diff", "--no-ext-diff", "--find-renames", "--patch", unified, base, head_ref }, max_pull_diff_bytes);
}

fn loadMergeBase(allocator: Allocator, repo: Repo, base_ref: []const u8, head_ref: []const u8) !?[]u8 {
    const raw = try gitMaybe(allocator, repo, &.{ "merge-base", base_ref, head_ref }, 1024 * 1024) orelse return null;
    defer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

fn appendPullDiff(buf: *std.ArrayList(u8), allocator: Allocator, diff: []const u8) !void {
    if (std.mem.trim(u8, diff, " \t\r\n").len == 0) {
        try appendEmptyState(buf, allocator, "No file changes.", "The head ref currently has no patch ahead of the merge base.");
        return;
    }

    var in_file = false;
    var file_index: usize = 0;
    var old_line: ?usize = null;
    var new_line: ?usize = null;
    var lines = std.mem.splitScalar(u8, diff, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (std.mem.startsWith(u8, line, "diff --git ")) {
            if (in_file) try buf.appendSlice(allocator, "</div></section>");
            in_file = true;
            old_line = null;
            new_line = null;
            try appendTemplate(buf, allocator,
                \\<section class="panel diff-file" id="diff-file-{file_index}" data-diff-file data-diff-file-index="{file_index}" data-diff-file-path="{title}"><div class="diff-file-head"><strong>{title}</strong></div><div class="diff-lines">
            , .{
                .file_index = file_index,
                .title = diffFileTitle(line),
            });
            file_index += 1;
            continue;
        } else if (!in_file) {
            in_file = true;
            try appendTemplate(buf, allocator,
                \\<section class="panel diff-file" id="diff-file-0" data-diff-file data-diff-file-index="0" data-diff-file-path="Patch"><div class="diff-file-head"><strong>Patch</strong></div><div class="diff-lines">
            , .{});
            file_index = 1;
        }

        if (parseHunkHeader(line)) |range| {
            old_line = range.old_start;
            new_line = range.new_start;
            try appendDiffLine(buf, allocator, line, "hunk", null, null);
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
    }
    if (in_file) try buf.appendSlice(allocator, "</div></section>");
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
    try appendTemplate(buf, allocator, "</span><code class=\"diff-code\">{line}</code></div>", .{ .line = line });
}

fn appendLineNumber(buf: *std.ArrayList(u8), allocator: Allocator, line_number: ?usize) !void {
    if (line_number) |value| if (value != 0) try std.fmt.format(buf.writer(allocator), "{d}", .{value});
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
    var parts = std.mem.splitScalar(u8, line, ' ');
    _ = parts.next();
    _ = parts.next();
    _ = parts.next();
    const b = parts.next() orelse return line;
    return if (std.mem.startsWith(u8, b, "b/")) b[2..] else b;
}

fn appendLocalMergeCheck(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, detail: PullDetail) !void {
    const oid = if (detail.target_oid.len != 0) detail.target_oid else detail.merge_oid;
    const status = try localContainsOid(allocator, repo, oid, detail.base_ref);
    if (status) |contains| {
        try buf.appendSlice(allocator, if (contains) "Confirmed in base ref" else "Not confirmed in base ref");
    } else {
        try buf.appendSlice(allocator, "Unavailable");
    }
}

fn localContainsOid(allocator: Allocator, repo: Repo, oid: []const u8, base_ref: []const u8) !?bool {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "git", "-C", repo.root, "merge-base", "--is-ancestor", oid, base_ref });
    var result = try runCommand(allocator, argv.items, null, 1024 * 1024);
    defer result.deinit();
    if (result.exitCode()) |code| {
        if (code == 0) return true;
        if (code == 1) return false;
    }
    return null;
}

fn appendPullStatePill(buf: *std.ArrayList(u8), allocator: Allocator, state: []const u8, draft: bool) !void {
    if (draft and std.mem.eql(u8, state, "open")) {
        try buf.appendSlice(allocator, "<span class=\"state draft\">draft</span>");
        return;
    }
    try appendTemplate(buf, allocator, "<span class=\"state {state}\">{state}</span>", .{ .state = state });
}

fn appendLabel(buf: *std.ArrayList(u8), allocator: Allocator, label: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<span class="issue-label {kind}">{label}</span>
    , .{
        .kind = labelKind(label),
        .label = label,
    });
}

fn appendAvatar(buf: *std.ArrayList(u8), allocator: Allocator, name: []const u8, extra_class: []const u8) !void {
    try appendTemplate(buf, allocator, "<span class=\"issue-avatar {extra_class}\" title=\"{name}\" aria-label=\"{name}\">", .{
        .extra_class = extra_class,
        .name = name,
    });
    var initial_buf = [_]u8{'?'};
    for (name) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            initial_buf[0] = std.ascii.toUpper(c);
            break;
        }
    }
    try shared.appendHtml(buf, allocator, initial_buf[0..]);
    try buf.appendSlice(allocator, "</span>");
}

fn appendLegacyPullLink(buf: *std.ArrayList(u8), allocator: Allocator, legacy_number: i64) !void {
    const pull_ref = try std.fmt.allocPrint(allocator, "{d}", .{legacy_number});
    defer allocator.free(pull_ref);
    try buf.appendSlice(allocator, "<a href=\"");
    try appendHref(buf, allocator, pullHref(pull_ref));
    try buf.appendSlice(allocator, "\">#");
    try shared.appendHtml(buf, allocator, pull_ref);
    try buf.appendSlice(allocator, "</a>");
}

fn labelKind(label: []const u8) []const u8 {
    if (asciiEqlIgnoreCase(label, "bug")) return "label-bug";
    if (asciiEqlIgnoreCase(label, "enhancement") or asciiEqlIgnoreCase(label, "feature") or asciiEqlIgnoreCase(label, "feat")) return "label-enhancement";
    if (asciiEqlIgnoreCase(label, "docs") or asciiEqlIgnoreCase(label, "documentation")) return "label-docs";
    if (asciiEqlIgnoreCase(label, "question")) return "label-question";
    if (asciiEqlIgnoreCase(label, "security")) return "label-security";
    return "label-default";
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (std.ascii.toLower(left) != std.ascii.toLower(right)) return false;
    }
    return true;
}

fn commitWord(count: usize) []const u8 {
    return if (count == 1) "commit" else "commits";
}

fn pullSearchQuery(filter: PullStateFilter) []const u8 {
    return switch (filter) {
        .open => "is:pr state:open",
        .merged => "is:pr state:merged",
        .closed => "is:pr state:closed",
        .all => "is:pr",
    };
}

fn pullStateValue(filter: PullStateFilter) []const u8 {
    return switch (filter) {
        .open => "open",
        .merged => "merged",
        .closed => "closed",
        .all => "all",
    };
}

pub fn renderPullForm(
    allocator: Allocator,
    repo: Repo,
    error_message: ?[]const u8,
    title_value: []const u8,
    body_value: []const u8,
    base_value: []const u8,
    head_value: []const u8,
    draft: bool,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "New Pull Request", "pulls");
    try buf.appendSlice(allocator, "<section class=\"panel form-panel\">");
    try appendSectionHead(&buf, allocator, "Pull requests", "New Pull Request", null);
    if (error_message) |message| {
        try appendTemplate(&buf, allocator, "<div class=\"flash error\">{message}</div>", .{ .message = message });
    }
    try appendTemplate(&buf, allocator,
        \\  <form method="post" action="/pulls" class="issue-form">
        \\    <label>Title<input name="title" value="{title_value}" autofocus required></label>
        \\    <label>Body<textarea name="body" rows="8">{body_value}</textarea></label>
        \\    <div class="grid two">
        \\      <label>Base ref<input name="base" value="{base_value}" placeholder="main" required></label>
        \\      <label>Head ref<input name="head" value="{head_value}" placeholder="feature-branch" required></label>
        \\    </div>
        \\    <label class="checkbox-label"><input type="checkbox" name="draft" value="1"{draft_checked}> Draft</label>
        \\    <div class="form-actions">
        \\      <a class="button secondary" href="/pulls">Cancel</a>
        \\      <button class="button primary" type="submit">Create pull request</button>
        \\    </div>
        \\  </form>
        \\</section>
    , .{
        .title_value = title_value,
        .body_value = body_value,
        .base_value = base_value,
        .head_value = head_value,
        .draft_checked = if (draft) " checked" else "",
    });
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

pub fn handlePullPost(allocator: Allocator, repo: Repo, stream: std.net.Stream, form_body: []const u8) !void {
    const title_owned = (try issues_page.formValueOwned(allocator, form_body, "title")) orelse try allocator.dupe(u8, "");
    defer allocator.free(title_owned);
    const body_owned = (try issues_page.formValueOwned(allocator, form_body, "body")) orelse try allocator.dupe(u8, "");
    defer allocator.free(body_owned);
    const base_owned = (try issues_page.formValueOwned(allocator, form_body, "base")) orelse try allocator.dupe(u8, "");
    defer allocator.free(base_owned);
    const head_owned = (try issues_page.formValueOwned(allocator, form_body, "head")) orelse try allocator.dupe(u8, "");
    defer allocator.free(head_owned);
    const draft_value = try issues_page.formValueOwned(allocator, form_body, "draft");
    defer if (draft_value) |value| allocator.free(value);
    const draft = draft_value != null;

    const title = std.mem.trim(u8, title_owned, " \t\r\n");
    const base_ref = std.mem.trim(u8, base_owned, " \t\r\n");
    const head_ref = std.mem.trim(u8, head_owned, " \t\r\n");
    if (title.len == 0 or base_ref.len == 0 or head_ref.len == 0) {
        const body = try renderPullForm(
            allocator,
            repo,
            "Title, base ref, and head ref are required.",
            title_owned,
            body_owned,
            base_owned,
            head_owned,
            draft,
        );
        defer allocator.free(body);
        try sendResponse(allocator, stream, 422, "Unprocessable Entity", "text/html", body, null);
        return;
    }

    pull.createPullOpenedEvent(allocator, title, body_owned, base_ref, head_ref, draft) catch {
        const body = try renderPullForm(
            allocator,
            repo,
            "Could not create the pull request. Check that Gitomi is initialized and Git commit signing is configured.",
            title_owned,
            body_owned,
            base_owned,
            head_owned,
            draft,
        );
        defer allocator.free(body);
        try sendResponse(allocator, stream, 500, "Internal Server Error", "text/html", body, null);
        return;
    };

    try sendRedirect(allocator, stream, "/pulls");
}

pub fn handlePullCommentPost(allocator: Allocator, repo: Repo, stream: std.net.Stream, raw_ref: []const u8, form_body: []const u8) !void {
    const action_owned = try issues_page.formValueOwned(allocator, form_body, "action");
    defer if (action_owned) |value| allocator.free(value);
    if (action_owned) |raw_action| {
        const action = std.mem.trim(u8, raw_action, " \t\r\n");
        if (std.mem.eql(u8, action, "add-reaction") or std.mem.eql(u8, action, "remove-reaction")) {
            try index.ensureIndex(allocator, repo);
            const pull_id = index.resolvePullId(allocator, repo, raw_ref) catch {
                try sendPlainResponse(allocator, stream, 404, "Not Found", "Pull request not found\n");
                return;
            };
            defer allocator.free(pull_id);

            const emoji_owned = (try issues_page.formValueOwned(allocator, form_body, "emoji")) orelse {
                try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Emoji is required\n");
                return;
            };
            defer allocator.free(emoji_owned);
            const emoji = std.mem.trim(u8, emoji_owned, " \t\r\n");
            if (emoji.len == 0) {
                try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Emoji is required\n");
                return;
            }

            const target_kind_owned = (try issues_page.formValueOwned(allocator, form_body, "target_kind")) orelse try allocator.dupe(u8, "pull");
            defer allocator.free(target_kind_owned);
            const target_kind = std.mem.trim(u8, target_kind_owned, " \t\r\n");
            const add = std.mem.eql(u8, action, "add-reaction");
            if (std.mem.eql(u8, target_kind, "pull")) {
                createReactionEvent(allocator, "pull", pull_id, emoji, add) catch {
                    try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not update reaction\n");
                    return;
                };
            } else if (std.mem.eql(u8, target_kind, "comment")) {
                const target_ref_owned = (try issues_page.formValueOwned(allocator, form_body, "target_ref")) orelse {
                    try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Comment target is required\n");
                    return;
                };
                defer allocator.free(target_ref_owned);
                const comment_id = index.resolveCommentId(allocator, repo, target_ref_owned) catch {
                    try sendPlainResponse(allocator, stream, 404, "Not Found", "Comment not found\n");
                    return;
                };
                defer allocator.free(comment_id);
                var parent = try index.commentParentInfo(allocator, repo, comment_id);
                defer parent.deinit();
                if (!std.mem.eql(u8, parent.parent_kind, "pull") or !std.mem.eql(u8, parent.parent_id, pull_id)) {
                    try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Comment is not in this pull request\n");
                    return;
                }
                createReactionEvent(allocator, "comment", comment_id, emoji, add) catch {
                    try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not update reaction\n");
                    return;
                };
            } else {
                try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Unknown reaction target\n");
                return;
            }

            const location = try std.fmt.allocPrint(allocator, "/pulls/{s}", .{raw_ref});
            defer allocator.free(location);
            try sendRedirect(allocator, stream, location);
            return;
        }
    }

    const body_owned = (try issues_page.formValueOwned(allocator, form_body, "body")) orelse try allocator.dupe(u8, "");
    defer allocator.free(body_owned);
    const body = std.mem.trim(u8, body_owned, " \t\r\n");
    if (body.len == 0) {
        try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Comment is required\n");
        return;
    }

    try index.ensureIndex(allocator, repo);
    const pull_id = index.resolvePullId(allocator, repo, raw_ref) catch {
        try sendPlainResponse(allocator, stream, 404, "Not Found", "Pull request not found\n");
        return;
    };
    defer allocator.free(pull_id);

    const reply_ref_owned = try issues_page.formValueOwned(allocator, form_body, "reply_parent_ref");
    defer if (reply_ref_owned) |value| allocator.free(value);
    const reply_ref = if (reply_ref_owned) |value| std.mem.trim(u8, value, " \t\r\n") else "";
    if (reply_ref.len != 0) {
        const reply_parent_id = index.resolveCommentId(allocator, repo, reply_ref) catch {
            try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Reply target was not found\n");
            return;
        };
        defer allocator.free(reply_parent_id);
        var parent = try index.commentParentInfo(allocator, repo, reply_parent_id);
        defer parent.deinit();
        if (!std.mem.eql(u8, parent.parent_kind, "pull") or !std.mem.eql(u8, parent.parent_id, pull_id)) {
            try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Reply target is not in this pull request\n");
            return;
        }
        createCommentReplyEvent(allocator, "pull", pull_id, reply_parent_id, parent.add_hash, body_owned) catch {
            try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not add the reply\n");
            return;
        };
    } else {
        createCommentAddedEvent(allocator, "pull", pull_id, body_owned) catch {
            try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not add the comment\n");
            return;
        };
    }

    const location = try std.fmt.allocPrint(allocator, "/pulls/{s}", .{raw_ref});
    defer allocator.free(location);
    try sendRedirect(allocator, stream, location);
}

fn queryValueOwned(allocator: Allocator, target: []const u8, wanted_key: []const u8) !?[]u8 {
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var pairs = std.mem.splitScalar(u8, target[query_start + 1 ..], '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const raw_key = pair[0..eq];
        const raw_value = if (eq < pair.len) pair[eq + 1 ..] else "";
        const key = try issues_page.percentDecodeForm(allocator, raw_key);
        defer allocator.free(key);
        if (!std.mem.eql(u8, key, wanted_key)) continue;
        return try issues_page.percentDecodeForm(allocator, raw_value);
    }
    return null;
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

fn freePullCommits(allocator: Allocator, commits: []PullCommit) void {
    for (commits) |commit| commit.deinit(allocator);
    allocator.free(commits);
}
