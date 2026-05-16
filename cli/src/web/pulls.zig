const std = @import("std");
const comment_mod = @import("../comment.zig");
const event_mod = @import("../event.zig");
const git = @import("../git.zig");
const index = @import("../index.zig");
const issues_page = @import("issues.zig");
const pull = @import("../pull.zig");
const reaction_mod = @import("../reaction.zig");
const repo_mod = @import("../repo.zig");
const shared = @import("shared.zig");
const source_stats = @import("source_stats.zig");
const util = @import("../util.zig");
const work_items = @import("../work_items.zig");

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

const max_pull_diff_bytes = work_items.max_pull_diff_bytes;
const max_merge_blob_bytes = 2 * 1024 * 1024;
const merge_context_radius = 15;

const PullStateFilter = work_items.PullStateFilter;
const PullFilters = work_items.PullListOptions;

const PullDetailTab = enum {
    conversation,
    commits,
    files,
};

const PullCounts = work_items.PullCounts;

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

const PullDetail = work_items.PullDetail;

const PullTabCounts = struct {
    comments: usize = 0,
    commits: ?usize = null,
    files: ?usize = null,
    additions: ?usize = null,
    deletions: ?usize = null,
};

const PullGitRefs = work_items.PullGitRefs;

const PullMergeStatusKind = enum {
    unavailable,
    clean,
    conflicts,
};

const PullMergeStatus = struct {
    kind: PullMergeStatusKind = .unavailable,
    conflict_files: ?[][]u8 = null,
    git_refs: ?PullGitRefs = null,

    fn deinit(self: PullMergeStatus, allocator: Allocator) void {
        if (self.conflict_files) |files| freeConflictFiles(allocator, files);
        if (self.git_refs) |refs| refs.deinit(allocator);
    }

    fn hasConflicts(self: PullMergeStatus) bool {
        return self.kind == .conflicts;
    }
};

const MergeConflictFile = struct {
    path: []u8,
    content: ?[]u8 = null,
    message: ?[]u8 = null,

    fn deinit(self: MergeConflictFile, allocator: Allocator) void {
        allocator.free(self.path);
        if (self.content) |value| allocator.free(value);
        if (self.message) |value| allocator.free(value);
    }

    fn editable(self: MergeConflictFile) bool {
        return self.content != null;
    }
};

const MergeRenderLine = struct {
    line_number: usize,
    text: []const u8,
    group_id: usize = 0,
    kind: []const u8 = "line",
    side: []const u8 = "",
    editable: bool = true,
    visible: bool = false,
};

const FormField = struct {
    name: []u8,
    value: []u8,

    fn deinit(self: FormField, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value);
    }
};

const DiffCommentSide = work_items.DiffCommentSide;
const DiffCommentContext = work_items.DiffCommentContext;

const ResolvedConflictFile = struct {
    path: []const u8,
    content: []const u8,
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
    const counts = try work_items.loadPullCounts(&db);
    var filters = try pullFiltersFromTarget(allocator, target, requested_filter orelse .open);
    defer pullFiltersDeinit(allocator, &filters);

    try appendShellStart(&buf, allocator, repo, "Pull Requests", "pulls");
    try appendPullsToolbar(&buf, allocator, filters);
    try buf.appendSlice(allocator, "<section class=\"panel pulls-panel\">");
    try appendPullsListHeader(&buf, allocator, filters, counts);

    var stmt = try work_items.preparePullListStmt(allocator, &db, filters);
    defer stmt.deinit();

    var shown: usize = 0;
    while (try stmt.step()) {
        const row = try work_items.pullListRowFromStmt(allocator, &stmt);
        defer row.deinit(allocator);
        const task_summary = shared.markdownTaskSummary(row.body);
        try appendPullListRow(&buf, allocator, &db, row.id, row.title, row.state, row.author, row.opened_at, row.state_at, row.base_ref, row.head_ref, row.draft, row.comment_count, row.legacy_number, task_summary);
        shown += 1;
    }

    if (shown == 0) {
        if (work_items.hasRestrictivePullFilters(filters)) {
            try appendEmptyState(&buf, allocator, "No matching pull requests.", "Change or clear filters to widen the pull request list.");
        } else switch (filters.state) {
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

fn pullFiltersFromTarget(allocator: Allocator, target: []const u8, default_state: PullStateFilter) !PullFilters {
    var filters = PullFilters{ .state = default_state };
    errdefer pullFiltersDeinit(allocator, &filters);

    if (try queryTextFilterOwned(allocator, target, "q")) |query| {
        defer allocator.free(query);
        var parsed = try work_items.parsePullSearchQuery(allocator, query);
        defer parsed.deinit(allocator);
        if (parsed.state) |state| filters.state = state;
        if (parsed.q) |search| {
            filters.q = search;
            parsed.q = null;
        }
    }
    return filters;
}

fn pullFiltersDeinit(allocator: Allocator, filters: *PullFilters) void {
    if (filters.q) |query| allocator.free(query);
}

fn pullDetailTabFromTarget(allocator: Allocator, target: []const u8) !PullDetailTab {
    const tab_value = try queryValueOwned(allocator, target, "tab");
    defer if (tab_value) |value| allocator.free(value);
    const value = tab_value orelse return .conversation;
    if (std.mem.eql(u8, value, "commits")) return .commits;
    if (std.mem.eql(u8, value, "files")) return .files;
    return .conversation;
}

fn appendPullsToolbar(buf: *std.ArrayList(u8), allocator: Allocator, filters: PullFilters) !void {
    const query = try pullSearchInputValue(allocator, filters);
    defer allocator.free(query);
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
        .query = query,
        .state = work_items.pullStateValue(filters.state),
    });
}

fn pullSearchInputValue(allocator: Allocator, filters: PullFilters) ![]u8 {
    const prefix = work_items.pullSearchQuery(filters.state);
    if (filters.q) |query| return std.fmt.allocPrint(allocator, "{s} {s}", .{ prefix, query });
    return std.fmt.allocPrint(allocator, "{s} ", .{prefix});
}

fn appendPullsListHeader(buf: *std.ArrayList(u8), allocator: Allocator, filters: PullFilters, counts: PullCounts) !void {
    try buf.appendSlice(allocator,
        \\<header class="pulls-list-head issues-list-head">
        \\  <div class="issues-select-all"><input type="checkbox" aria-label="Select all pull requests" disabled></div>
        \\  <nav class="issues-state-tabs" aria-label="Pull request state">
    );
    try appendPullStateTab(buf, allocator, "Open", counts.open, .open, filters, "issue-open-icon");
    try appendPullStateTab(buf, allocator, "Merged", counts.merged, .merged, filters, "pull-merged-icon");
    try appendPullStateTab(buf, allocator, "Closed", counts.closed, .closed, filters, "pull-closed-icon");
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
    filters: PullFilters,
    icon_class: []const u8,
) !void {
    try appendTemplate(buf, allocator,
        \\<a class="{classes}" href="
    , .{
        .classes = shared.classes("issues-state-tab", &.{shared.class("active", tab_filter == filters.state)}),
    });
    try appendPullsHref(buf, allocator, filters, tab_filter);
    try appendTemplate(buf, allocator,
        \\"><span class="issue-tab-icon {icon_class}" aria-hidden="true"></span><span>{label}</span><span class="issue-count-badge">{count}</span></a>
    , .{
        .icon_class = icon_class,
        .label = label,
        .count = count,
    });
}

fn appendPullsHref(buf: *std.ArrayList(u8), allocator: Allocator, filters: PullFilters, state: PullStateFilter) !void {
    try buf.appendSlice(allocator, "/pulls?state=");
    try shared.appendUrlEncoded(buf, allocator, work_items.pullStateValue(state));
    if (filters.q) |query| {
        try buf.appendSlice(allocator, "&amp;q=");
        try shared.appendUrlEncoded(buf, allocator, query);
    }
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
    task_summary: shared.MarkdownTaskSummary,
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
    if (task_summary.hasTasks()) {
        try buf.append(allocator, ' ');
        try shared.appendMarkdownTaskProgress(buf, allocator, task_summary);
    }
    try buf.appendSlice(allocator, "</p><p class=\"pull-branch-line\">");
    try appendPullBranchLink(buf, allocator, head_ref);
    try buf.appendSlice(allocator, "<span aria-hidden=\"true\">-&gt;</span>");
    try appendPullBranchLink(buf, allocator, base_ref);
    try buf.appendSlice(allocator,
        \\</p></div>
        \\  <div class="issue-row-side">
    );
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

    const detail = (try work_items.loadPullDetail(allocator, &db, pull_id)) orelse return renderPullNotFound(allocator, repo, raw_ref);
    defer detail.deinit(allocator);
    const tab = try pullDetailTabFromTarget(allocator, target);

    var pull_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const pull_ref = util.shortObjectRef(&pull_ref_buf, detail.id);
    const tab_counts = try loadPullTabCounts(allocator, repo, &db, detail);
    const merge_status = try loadPullMergeStatus(allocator, repo, detail);
    defer merge_status.deinit(allocator);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, detail.title, "pulls");
    try buf.appendSlice(allocator, "<section class=\"pull-detail issue-page\">");
    try appendPullPageHeader(&buf, allocator, detail, pull_ref, tab_counts, merge_status);
    try appendPullTabs(&buf, allocator, pull_ref, tab, tab_counts);
    try appendTemplate(&buf, allocator,
        \\<div class="issue-conversation-layout pull-conversation-layout">
        \\  <div class="pull-tab-content">
    , .{});
    const current_actor = try shared.currentPrincipalOwned(allocator, repo);
    defer if (current_actor) |actor| allocator.free(actor);
    const current_role = if (current_actor) |actor| try index.effectiveWriteRoleForPrincipal(allocator, repo, actor) else null;
    defer if (current_role) |role| allocator.free(role);
    const can_edit_pull = currentActorCanEditAuthor(current_actor, current_role, detail.author_principal);
    switch (tab) {
        .conversation => try appendPullConversation(&buf, allocator, &db, detail, raw_ref, current_actor, can_edit_pull, merge_status),
        .commits => try appendPullCommits(&buf, allocator, repo, detail),
        .files => try appendPullFiles(&buf, allocator, repo, detail, raw_ref),
    }
    try buf.appendSlice(allocator, "</div><aside class=\"issue-meta-sidebar pull-sidebar\">");
    try appendPullSidebar(&buf, allocator, repo, &db, detail, pull_ref);
    try buf.appendSlice(allocator, "</aside></div></section>");
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
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

pub fn renderPullMergeEditorPage(allocator: Allocator, repo: Repo, raw_ref: []const u8, target: []const u8, error_message: ?[]const u8) ![]u8 {
    if (try shared.renderIndexingPageIfStale(allocator, repo, "Resolve Conflicts", "pulls", target)) |body| return body;
    try index.ensureIndex(allocator, repo);
    const pull_id = index.resolvePullId(allocator, repo, raw_ref) catch {
        return renderPullNotFound(allocator, repo, raw_ref);
    };
    defer allocator.free(pull_id);

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    const detail = (try work_items.loadPullDetail(allocator, &db, pull_id)) orelse return renderPullNotFound(allocator, repo, raw_ref);
    defer detail.deinit(allocator);

    const merge_status = try loadPullMergeStatus(allocator, repo, detail);
    defer merge_status.deinit(allocator);

    var pull_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const pull_ref = util.shortObjectRef(&pull_ref_buf, detail.id);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "Resolve Conflicts", "pulls");
    if (!merge_status.hasConflicts()) {
        try appendMergeEditorEmptyState(&buf, allocator, raw_ref, "No merge conflicts detected.", "This pull request is not currently reporting file conflicts in the local repository.");
        try appendShellEnd(&buf, allocator);
        return buf.toOwnedSlice(allocator);
    }

    const conflict_files = merge_status.conflict_files orelse &[_][]u8{};
    const files = try loadMergeConflictFiles(allocator, repo, detail, conflict_files);
    defer freeMergeConflictFiles(allocator, files);

    try appendMergeEditor(&buf, allocator, detail, raw_ref, pull_ref, files, error_message);
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn appendMergeEditorEmptyState(buf: *std.ArrayList(u8), allocator: Allocator, raw_ref: []const u8, title: []const u8, detail: []const u8) !void {
    try buf.appendSlice(allocator, "<section class=\"panel merge-editor-empty\">");
    try appendEmptyState(buf, allocator, title, detail);
    try buf.appendSlice(allocator, "<div class=\"form-actions\"><a class=\"button secondary\" href=\"/pulls/");
    try shared.appendUrlEncoded(buf, allocator, raw_ref);
    try buf.appendSlice(allocator, "\">Back to pull request</a></div></section>");
}

fn appendMergeEditor(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    detail: PullDetail,
    raw_ref: []const u8,
    pull_ref: []const u8,
    files: []const MergeConflictFile,
    error_message: ?[]const u8,
) !void {
    const editable = mergeEditorEditable(files);
    const total_conflicts = mergeEditorConflictCount(files);
    try appendTemplate(buf, allocator,
        \\<form class="merge-editor" data-merge-editor data-merge-unsupported="{unsupported}" data-merge-total-conflicts="{total_conflicts}" method="post" action="/pulls/
    , .{
        .unsupported = !editable,
        .total_conflicts = total_conflicts,
    });
    try shared.appendUrlEncoded(buf, allocator, raw_ref);
    try appendTemplate(buf, allocator,
        \\/conflicts">
        \\  <header class="merge-editor-head">
        \\    <div class="merge-editor-title">
        \\      <a class="merge-editor-back" href="/pulls/{pull_ref}" aria-label="Back to pull request"></a>
        \\      <div>
        \\        <h1>Resolving conflicts between <code>{head_ref}</code> and <code>{base_ref}</code></h1>
        \\        <p>Committing changes to <code>{head_ref}</code></p>
        \\      </div>
        \\    </div>
        \\    <div class="merge-editor-actions">
        \\      <div class="merge-editor-progress" aria-live="polite">
        \\        <span class="merge-editor-count" data-merge-progress>0 of {total_conflicts} conflicts resolved</span>
        \\        <span class="merge-editor-progress-bar" aria-hidden="true"><span data-merge-progress-bar></span></span>
        \\      </div>
        \\      <button class="button secondary merge-editor-step" type="button" data-merge-prev><span class="button-icon icon-chevron-up" aria-hidden="true"></span><span>Previous</span></button>
        \\      <button class="button secondary merge-editor-step" type="button" data-merge-next><span class="button-icon icon-chevron-down" aria-hidden="true"></span><span>Next</span></button>
        \\      <button class="button primary merge-editor-submit" type="submit" data-merge-submit disabled><span class="button-icon icon-check" aria-hidden="true"></span><span data-merge-submit-label>Commit resolution</span></button>
        \\    </div>
        \\  </header>
    , .{
        .pull_ref = pull_ref,
        .head_ref = detail.head_ref,
        .base_ref = detail.base_ref,
        .file_count = files.len,
        .file_word = if (files.len == 1) "conflicting file" else "conflicting files",
        .total_conflicts = total_conflicts,
    });

    if (error_message) |message| {
        try appendTemplate(buf, allocator, "<div class=\"flash error merge-editor-flash\">{message}</div>", .{ .message = message });
    }

    if (!editable) {
        try buf.appendSlice(allocator, "<div class=\"flash warning merge-editor-flash\">At least one conflict cannot be edited in the web resolver. Resolve unsupported conflicts from the command line.</div>");
    }

    try appendTemplate(buf, allocator,
        \\  <input type="hidden" name="file_count" value="{file_count}">
        \\  <div class="merge-editor-layout">
        \\    <aside class="merge-editor-sidebar">
        \\      <strong>{file_count} {file_word}</strong>
        \\      <nav aria-label="Conflicting files">
    , .{
        .file_count = files.len,
        .file_word = if (files.len == 1) "file" else "files",
    });
    for (files, 0..) |file, index_value| {
        try appendTemplate(buf, allocator,
            \\<a class="{classes}" href="#merge-file-{index}" data-merge-file-link data-file-index="{index}"><span class="pull-conflict-file-icon" aria-hidden="true"></span><span class="merge-editor-file-name">{path}</span><span class="merge-editor-file-meta" data-merge-link-status>
        , .{
            .classes = shared.classes("merge-editor-file-link", &.{shared.class("is-unsupported", !file.editable())}),
            .index = index_value,
            .path = file.path,
        });
        try appendMergeFileNavStatus(buf, allocator, file);
        try buf.appendSlice(allocator, "</span></a>");
    }
    try buf.appendSlice(allocator,
        \\      </nav>
        \\    </aside>
        \\    <div class="merge-editor-files">
    );
    for (files, 0..) |file, index_value| {
        try appendMergeEditorFile(buf, allocator, file, index_value);
    }
    try buf.appendSlice(allocator, "</div></div></form>");
}

fn mergeEditorEditable(files: []const MergeConflictFile) bool {
    if (files.len == 0) return false;
    for (files) |file| {
        if (!file.editable()) return false;
    }
    return true;
}

fn mergeEditorConflictCount(files: []const MergeConflictFile) usize {
    var count: usize = 0;
    for (files) |file| count += mergeFileConflictCount(file);
    return count;
}

fn mergeFileConflictCount(file: MergeConflictFile) usize {
    const content = file.content orelse return 0;
    return countConflictGroups(content);
}

fn countConflictGroups(content: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (std.mem.startsWith(u8, line, "<<<<<<<")) count += 1;
    }
    return count;
}

fn appendMergeFileNavStatus(buf: *std.ArrayList(u8), allocator: Allocator, file: MergeConflictFile) !void {
    if (!file.editable()) {
        try buf.appendSlice(allocator, "Unsupported");
        return;
    }
    const count = mergeFileConflictCount(file);
    try appendTemplate(buf, allocator, "{count} {label}", .{
        .count = count,
        .label = if (count == 1) "conflict" else "conflicts",
    });
}

fn appendMergeFileStatus(buf: *std.ArrayList(u8), allocator: Allocator, file: MergeConflictFile) !void {
    if (!file.editable()) {
        try buf.appendSlice(allocator, "Unsupported");
        return;
    }
    const count = mergeFileConflictCount(file);
    if (count == 0) {
        try buf.appendSlice(allocator, "Resolved");
        return;
    }
    try appendTemplate(buf, allocator, "{count} unresolved", .{ .count = count });
}

fn appendMergeEditorFile(buf: *std.ArrayList(u8), allocator: Allocator, file: MergeConflictFile, index_value: usize) !void {
    const language = source_stats.languageForPath(file.path);
    try appendTemplate(buf, allocator,
        \\<section class="{classes}" id="merge-file-{index}" data-merge-file data-file-index="{index}">
        \\  <header class="merge-file-head">
        \\    <div><span class="pull-conflict-file-icon" aria-hidden="true"></span><strong>{path}</strong></div>
        \\    <span class="merge-file-status" data-merge-file-status>
    , .{
        .classes = shared.classes("panel merge-file-editor", &.{shared.class("is-unsupported", !file.editable())}),
        .index = index_value,
        .path = file.path,
    });
    try appendMergeFileStatus(buf, allocator, file);
    try appendTemplate(buf, allocator,
        \\</span>
        \\  </header>
        \\  <input type="hidden" name="path_{index}" value="{path}">
    , .{
        .index = index_value,
        .path = file.path,
    });

    if (file.content) |content| {
        try appendTemplate(buf, allocator,
            \\  <textarea class="merge-content-field" name="content_{index}" data-merge-content>{content}</textarea>
            \\  <div class="merge-code" data-merge-code data-merge-language="{language}">
        , .{
            .index = index_value,
            .content = content,
            .language = language,
        });
        try appendMergeConflictContent(buf, allocator, language, content);
        try buf.appendSlice(allocator, "</div>");
    } else {
        try appendTemplate(buf, allocator,
            \\<div class="merge-unsupported-message"><strong>This conflict is not editable in the web resolver.</strong><p>{message}</p></div>
        , .{ .message = file.message orelse "The file could not be loaded as a text conflict." });
    }
    try buf.appendSlice(allocator, "</section>");
}

fn appendMergeConflictContent(buf: *std.ArrayList(u8), allocator: Allocator, language: []const u8, content: []const u8) !void {
    var render_lines: std.ArrayList(MergeRenderLine) = .empty;
    defer render_lines.deinit(allocator);

    var line_number: usize = 1;
    var group_id: usize = 0;
    var side: []const u8 = "";
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (std.mem.startsWith(u8, line, "<<<<<<<")) {
            group_id += 1;
            side = "current";
            try render_lines.append(allocator, .{ .line_number = line_number, .text = line, .group_id = group_id, .kind = "marker", .side = "current", .editable = false });
        } else if (std.mem.startsWith(u8, line, "|||||||")) {
            side = "base";
            try render_lines.append(allocator, .{ .line_number = line_number, .text = line, .group_id = group_id, .kind = "marker", .side = "base", .editable = false });
        } else if (std.mem.startsWith(u8, line, "=======")) {
            side = "incoming";
            try render_lines.append(allocator, .{ .line_number = line_number, .text = line, .group_id = group_id, .kind = "marker", .side = "incoming", .editable = false });
        } else if (std.mem.startsWith(u8, line, ">>>>>>>")) {
            try render_lines.append(allocator, .{ .line_number = line_number, .text = line, .group_id = group_id, .kind = "marker", .side = "incoming", .editable = false });
            side = "";
        } else {
            try render_lines.append(allocator, .{ .line_number = line_number, .text = line, .group_id = group_id, .kind = "line", .side = side, .editable = true });
        }
        line_number += 1;
    }

    markMergeLineVisibility(render_lines.items);
    try appendMergeRenderLines(buf, allocator, language, render_lines.items);
}

fn markMergeLineVisibility(lines: []MergeRenderLine) void {
    var has_conflicts = false;
    for (lines, 0..) |line, index_value| {
        if (line.group_id == 0) continue;
        has_conflicts = true;
        const start = index_value -| merge_context_radius;
        const end = @min(lines.len, index_value + merge_context_radius + 1);
        for (lines[start..end]) |*visible_line| visible_line.visible = true;
    }
    if (!has_conflicts) {
        for (lines) |*line| line.visible = true;
    }
}

fn appendMergeRenderLines(buf: *std.ArrayList(u8), allocator: Allocator, language: []const u8, lines: []const MergeRenderLine) !void {
    var index_value: usize = 0;
    var fold_id: usize = 0;
    while (index_value < lines.len) {
        const line = lines[index_value];
        if (!line.visible) {
            const start = index_value;
            while (index_value < lines.len and !lines[index_value].visible) : (index_value += 1) {}
            fold_id += 1;
            try appendMergeFoldControl(buf, allocator, fold_id, index_value - start);
            for (lines[start..index_value]) |hidden_line| {
                try appendMergeRenderLine(buf, allocator, language, hidden_line, fold_id);
            }
            continue;
        }

        try appendMergeRenderLine(buf, allocator, language, line, 0);
        index_value += 1;
    }
}

fn appendMergeRenderLine(buf: *std.ArrayList(u8), allocator: Allocator, language: []const u8, line: MergeRenderLine, fold_id: usize) !void {
    if (line.group_id != 0 and std.mem.eql(u8, line.kind, "marker") and std.mem.eql(u8, line.side, "current")) {
        try appendMergeConflictActions(buf, allocator, line.group_id);
    }
    try appendMergeLine(buf, allocator, language, line, fold_id);
}

fn appendMergeFoldControl(buf: *std.ArrayList(u8), allocator: Allocator, fold_id: usize, count: usize) !void {
    try appendTemplate(buf, allocator,
        \\<div class="merge-fold" data-merge-fold="{fold_id}"><span class="merge-line-number"></span><button type="button" data-merge-fold-toggle data-merge-fold-target="{fold_id}" data-merge-fold-count="{count}" aria-expanded="false">Show {count} unchanged {label}</button></div>
    , .{
        .fold_id = fold_id,
        .count = count,
        .label = if (count == 1) "line" else "lines",
    });
}

fn appendMergeConflictActions(buf: *std.ArrayList(u8), allocator: Allocator, group_id: usize) !void {
    try appendTemplate(buf, allocator,
        \\<div class="merge-conflict-actions" data-conflict-group="{group_id}" data-conflict-actions>
        \\  <span class="merge-conflict-label">Conflict {group_id}</span>
        \\  <span class="merge-conflict-buttons">
        \\    <button class="merge-action-current" type="button" data-merge-action="current">Use current</button>
        \\    <button class="merge-action-incoming" type="button" data-merge-action="incoming">Use incoming</button>
        \\    <button class="merge-action-both" type="button" data-merge-action="both">Use both</button>
        \\  </span>
        \\</div>
    , .{ .group_id = group_id });
}

fn appendMergeLine(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    language: []const u8,
    line: MergeRenderLine,
    fold_id: usize,
) !void {
    try appendTemplate(buf, allocator,
        \\<div class="{classes}" data-merge-line
    , .{ .classes = shared.classes("merge-line", &.{
        shared.class("merge-marker", std.mem.eql(u8, line.kind, "marker")),
        shared.class("merge-current", std.mem.eql(u8, line.side, "current")),
        shared.class("merge-incoming", std.mem.eql(u8, line.side, "incoming")),
        shared.class("merge-base", std.mem.eql(u8, line.side, "base")),
        shared.class("merge-context", line.group_id == 0 and std.mem.eql(u8, line.kind, "line")),
        shared.class("merge-line-folded", !line.visible),
    }) });
    if (!line.visible) try appendTemplate(buf, allocator, " hidden data-merge-fold-id=\"{fold_id}\"", .{ .fold_id = fold_id });
    if (line.group_id != 0) try appendTemplate(buf, allocator, " data-conflict-group=\"{group_id}\"", .{ .group_id = line.group_id });
    if (line.side.len != 0 and !std.mem.eql(u8, line.kind, "marker")) try appendTemplate(buf, allocator, " data-conflict-side=\"{side}\"", .{ .side = line.side });
    try appendTemplate(buf, allocator,
        \\><span class="merge-line-number">{line_number}</span><code
    , .{ .line_number = line.line_number });
    if (!std.mem.eql(u8, line.kind, "marker")) try appendTemplate(buf, allocator, " class=\"language-{language}\"", .{ .language = language });
    try buf.appendSlice(allocator, " data-merge-line-text");
    if (!std.mem.eql(u8, line.kind, "marker")) try appendTemplate(buf, allocator, " data-original-text=\"{original}\"", .{ .original = line.text });
    if (line.editable and !std.mem.eql(u8, line.kind, "marker")) {
        try buf.appendSlice(allocator, " contenteditable=\"true\" spellcheck=\"false\" role=\"textbox\" aria-label=\"Editable merge line\"");
    }
    try appendTemplate(buf, allocator, ">{line}</code></div>", .{ .line = line.text });
}

fn loadMergeConflictFiles(allocator: Allocator, repo: Repo, detail: PullDetail, conflict_paths: []const []const u8) ![]MergeConflictFile {
    var files: std.ArrayList(MergeConflictFile) = .empty;
    errdefer {
        for (files.items) |file| file.deinit(allocator);
        files.deinit(allocator);
    }

    const git_refs = (try work_items.loadPullGitRefs(allocator, repo, detail)) orelse return try files.toOwnedSlice(allocator);
    defer git_refs.deinit(allocator);

    const merge_base = try work_items.loadMergeBase(allocator, repo, git_refs.base, git_refs.head);
    defer if (merge_base) |value| allocator.free(value);

    for (conflict_paths) |path| {
        try files.append(allocator, try loadMergeConflictFile(allocator, repo, detail, git_refs.base, git_refs.head, merge_base, path));
    }
    return try files.toOwnedSlice(allocator);
}

fn loadMergeConflictFile(
    allocator: Allocator,
    repo: Repo,
    detail: PullDetail,
    base_commit: []const u8,
    head_commit: []const u8,
    merge_base: ?[]const u8,
    path: []const u8,
) !MergeConflictFile {
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);

    if (!isSafeMergePath(path)) {
        return .{
            .path = owned_path,
            .message = try allocator.dupe(u8, "The path is not a safe repository-relative file path."),
        };
    }

    const base_oid = merge_base orelse {
        return .{
            .path = owned_path,
            .message = try allocator.dupe(u8, "The local repository could not find a merge base for this pull request."),
        };
    };

    const current = try loadBlobAtRef(allocator, repo, head_commit, path);
    defer if (current) |value| allocator.free(value);
    const ancestor = try loadBlobAtRef(allocator, repo, base_oid, path);
    defer if (ancestor) |value| allocator.free(value);
    const incoming = try loadBlobAtRef(allocator, repo, base_commit, path);
    defer if (incoming) |value| allocator.free(value);

    if (current == null or ancestor == null or incoming == null) {
        return .{
            .path = owned_path,
            .message = try allocator.dupe(u8, "Deleted-file conflicts are not editable in the web resolver yet."),
        };
    }

    if (containsNul(current.?) or containsNul(ancestor.?) or containsNul(incoming.?)) {
        return .{
            .path = owned_path,
            .message = try allocator.dupe(u8, "Binary conflicts are not editable in the web resolver."),
        };
    }

    const content = (try mergeFileConflictContent(allocator, detail, current.?, ancestor.?, incoming.?)) orelse {
        return .{
            .path = owned_path,
            .message = try allocator.dupe(u8, "Git could not generate a text conflict for this file."),
        };
    };

    return .{
        .path = owned_path,
        .content = content,
    };
}

fn freeMergeConflictFiles(allocator: Allocator, files: []MergeConflictFile) void {
    for (files) |file| file.deinit(allocator);
    allocator.free(files);
}

fn loadBlobAtRef(allocator: Allocator, repo: Repo, ref: []const u8, path: []const u8) !?[]u8 {
    const object = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ ref, path });
    defer allocator.free(object);
    return work_items.gitMaybe(allocator, repo, &.{ "show", object }, max_merge_blob_bytes);
}

fn mergeFileConflictContent(
    allocator: Allocator,
    detail: PullDetail,
    current: []const u8,
    ancestor: []const u8,
    incoming: []const u8,
) !?[]u8 {
    const tmp_dir = try tempPath(allocator, "gitomi-merge-file");
    defer allocator.free(tmp_dir);
    try std.fs.cwd().makePath(tmp_dir);
    defer std.fs.deleteTreeAbsolute(tmp_dir) catch {};

    const current_path = try std.fs.path.join(allocator, &.{ tmp_dir, "current" });
    defer allocator.free(current_path);
    const ancestor_path = try std.fs.path.join(allocator, &.{ tmp_dir, "ancestor" });
    defer allocator.free(ancestor_path);
    const incoming_path = try std.fs.path.join(allocator, &.{ tmp_dir, "incoming" });
    defer allocator.free(incoming_path);

    try writeFileBytes(current_path, current);
    try writeFileBytes(ancestor_path, ancestor);
    try writeFileBytes(incoming_path, incoming);

    const current_label = try std.fmt.allocPrint(allocator, "{s} (Current change)", .{detail.head_ref});
    defer allocator.free(current_label);
    const incoming_label = try std.fmt.allocPrint(allocator, "{s} (Incoming change)", .{detail.base_ref});
    defer allocator.free(incoming_label);

    var result = try runCommand(allocator, &.{
        "git",
        "merge-file",
        "-p",
        "-L",
        current_label,
        "-L",
        "merge base",
        "-L",
        incoming_label,
        current_path,
        ancestor_path,
        incoming_path,
    }, null, max_merge_blob_bytes * 3);
    if (result.exitCode()) |code| {
        if (mergeFileProducedContent(code)) {
            const stdout = result.stdout;
            allocator.free(result.stderr);
            return stdout;
        }
    }
    result.deinit();
    return null;
}

fn mergeFileProducedContent(exit_code: u8) bool {
    // git merge-file returns the conflict count on successful text merges, capped at 127.
    return exit_code <= 127;
}

fn containsNul(value: []const u8) bool {
    return std.mem.indexOfScalar(u8, value, 0) != null;
}

fn isSafeMergePath(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or std.mem.indexOfScalar(u8, path, 0) != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".git")) return false;
    }
    return true;
}

fn tempPath(allocator: Allocator, prefix: []const u8) ![]u8 {
    const id = try util.newUuidV7(allocator);
    defer allocator.free(id);
    return std.fmt.allocPrint(allocator, "/tmp/{s}-{s}", .{ prefix, id });
}

fn writeFileBytes(path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
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

    const git_counts = try loadPullGitTabCounts(allocator, repo, detail);
    if (git_counts.commits) |value| counts.commits = value;
    if (git_counts.files) |value| counts.files = value;
    return counts;
}

fn loadPullGitTabCounts(allocator: Allocator, repo: Repo, detail: PullDetail) !PullTabCounts {
    var counts: PullTabCounts = .{};
    const git_refs = (try work_items.loadPullGitRefs(allocator, repo, detail)) orelse return counts;
    defer git_refs.deinit(allocator);

    const merge_base = try work_items.loadMergeBase(allocator, repo, git_refs.base, git_refs.head);
    defer if (merge_base) |value| allocator.free(value);
    const base = merge_base orelse return counts;

    const range = try std.fmt.allocPrint(allocator, "{s}..{s}", .{ base, git_refs.head });
    defer allocator.free(range);
    if (try work_items.gitMaybe(allocator, repo, &.{ "rev-list", "--count", range }, 64 * 1024)) |raw_count| {
        defer allocator.free(raw_count);
        const trimmed = std.mem.trim(u8, raw_count, " \t\r\n");
        counts.commits = std.fmt.parseUnsigned(usize, trimmed, 10) catch null;
    }

    if (try work_items.gitMaybe(allocator, repo, &.{ "diff", "--name-only", "--find-renames", base, git_refs.head }, max_pull_diff_bytes)) |raw_files| {
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

fn appendPullPageHeader(buf: *std.ArrayList(u8), allocator: Allocator, detail: PullDetail, pull_ref: []const u8, counts: PullTabCounts, merge_status: PullMergeStatus) !void {
    try appendTemplate(buf, allocator,
        \\<header class="issue-page-head pull-page-head">
        \\  <div class="issue-title-line">
        \\    <h1><span>{title}</span> <span class="issue-page-number">
    , .{ .title = detail.title });
    try appendPullDisplayRef(buf, allocator, detail, pull_ref);
    try appendTemplate(buf, allocator,
        \\</span></h1>
        \\    <div class="issue-page-actions">
    , .{});
    if (merge_status.hasConflicts()) {
        try appendTemplate(buf, allocator,
            \\      <a class="button secondary pull-conflicts-button" href="/pulls/{pull_ref}/conflicts"><span class="button-icon icon-conflict" aria-hidden="true"></span><span>Resolve conflicts</span></a>
        , .{ .pull_ref = pull_ref });
    }
    try buf.appendSlice(allocator,
        \\      <button class="issue-copy-button" type="button" disabled aria-label="Copy pull request link"><span class="button-icon icon-copy" aria-hidden="true"></span></button>
        \\    </div>
        \\  </div>
        \\  <div class="issue-status-line pull-status-line">
    );
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
        try buf.appendSlice(allocator, " into ");
        try appendPullBranchLink(buf, allocator, detail.base_ref);
        try buf.appendSlice(allocator, " from ");
        try appendPullBranchLink(buf, allocator, detail.head_ref);
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
    try buf.appendSlice(allocator, " into ");
    try appendPullBranchLink(buf, allocator, detail.base_ref);
    try buf.appendSlice(allocator, " from ");
    try appendPullBranchLink(buf, allocator, detail.head_ref);
    try buf.appendSlice(allocator, "</span>");
}

fn appendPullBranchLink(buf: *std.ArrayList(u8), allocator: Allocator, ref: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<a class="pull-branch-link" href="{href}"><code>{ref}</code></a>
    , .{
        .href = shared.codeHref(ref, ""),
        .ref = ref,
    });
}

fn pullDisplayAuthor(detail: PullDetail) []const u8 {
    return detail.displayAuthor();
}

fn currentActorCanEditAuthor(current_actor: ?[]const u8, current_role: ?[]const u8, author: []const u8) bool {
    const role = current_role orelse return false;
    if (event_mod.roleAtLeast(role, "maintainer")) return true;
    const actor = current_actor orelse return false;
    return event_mod.roleAtLeast(role, "contributor") and std.mem.eql(u8, actor, author);
}

fn currentActorCanEditInRepo(allocator: Allocator, repo: Repo, author: []const u8) !bool {
    const current_actor = try shared.currentPrincipalOwned(allocator, repo);
    defer if (current_actor) |actor| allocator.free(actor);
    const current_role = if (current_actor) |actor| try index.effectiveWriteRoleForPrincipal(allocator, repo, actor) else null;
    defer if (current_role) |role| allocator.free(role);
    return currentActorCanEditAuthor(current_actor, current_role, author);
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
    try appendPullTabDiffstat(buf, allocator, counts);
    try buf.appendSlice(allocator, "</nav>");
}

fn appendPullTabDiffstat(buf: *std.ArrayList(u8), allocator: Allocator, counts: PullTabCounts) !void {
    if (counts.additions == null and counts.deletions == null) return;

    const additions = counts.additions orelse 0;
    const deletions = counts.deletions orelse 0;
    try appendTemplate(buf, allocator,
        \\<span class="pull-tab-diffstat" aria-label="{additions} additions and {deletions} deletions"><strong>+{additions}</strong><em>-{deletions}</em><span class="pull-tab-diffstat-bars" aria-hidden="true">
    , .{
        .additions = additions,
        .deletions = deletions,
    });

    const total = additions + deletions;
    const bar_count: usize = 5;
    var add_bars: usize = 0;
    if (total > 0 and additions > 0) {
        add_bars = (additions * bar_count + total - 1) / total;
        if (add_bars > bar_count) add_bars = bar_count;
    }
    var del_bars: usize = 0;
    if (total > 0 and deletions > 0) {
        del_bars = bar_count - add_bars;
        if (del_bars == 0) del_bars = 1;
    }
    if (add_bars + del_bars > bar_count) {
        if (add_bars >= del_bars) {
            add_bars = bar_count - del_bars;
        } else {
            del_bars = bar_count - add_bars;
        }
    }

    var i: usize = 0;
    while (i < bar_count) : (i += 1) {
        const class_name = if (i < add_bars) "is-add" else if (i < add_bars + del_bars) "is-del" else "is-empty";
        try appendTemplate(buf, allocator, "<i class=\"{class_name}\"></i>", .{ .class_name = class_name });
    }
    try buf.appendSlice(allocator, "</span></span>");
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
        \\</dd></div><div><dt>Author</dt><dd>{author}/{device}</dd></div><div><dt>Base</dt><dd>
    , .{
        .author = detail.author_principal,
        .device = detail.author_device,
    });
    try appendPullBranchLink(buf, allocator, detail.base_ref);
    try buf.appendSlice(allocator, "</dd></div><div><dt>Head</dt><dd>");
    try appendPullBranchLink(buf, allocator, detail.head_ref);
    try buf.appendSlice(allocator, "</dd></div>");
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
    try buf.appendSlice(allocator,
        \\<p class="issue-sidebar-empty">Successfully merging this pull request may close linked issues.</p>
        \\<div class="pull-sidebar-branches"><span><strong>Base</strong>
    );
    try appendPullBranchLink(buf, allocator, detail.base_ref);
    try buf.appendSlice(allocator, "</span><span><strong>Head</strong>");
    try appendPullBranchLink(buf, allocator, detail.head_ref);
    try buf.appendSlice(allocator, "</span></div>");
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
    can_edit_pull: bool,
    merge_status: PullMergeStatus,
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
    try issues_page.appendIssueActionMenu(buf, allocator, "pull-description", "", detail.body, detail.body.len != 0, "");
    try buf.appendSlice(allocator,
        \\</header>
        \\  <div class="markdown-body"
    );
    if (can_edit_pull) {
        try buf.appendSlice(allocator, " data-checklist-owner=\"pull\" data-checklist-update-action=\"/pulls/");
        try shared.appendUrlEncoded(buf, allocator, raw_ref);
        try buf.appendSlice(allocator, "/checklist\"");
    }
    try buf.appendSlice(allocator, ">");
    if (detail.body.len == 0) {
        try buf.appendSlice(allocator, "<p class=\"muted\">No description provided.</p>");
    } else {
        try shared.appendMarkdownSource(buf, allocator, detail.body, .{});
    }
    try buf.appendSlice(allocator, "</div>");
    try appendPullReactionBar(buf, allocator, db, "pull", detail.id, raw_ref, "", current_actor);
    try buf.appendSlice(allocator, "</article></div>");
    try appendPullComments(buf, allocator, db, raw_ref, detail.id, current_actor);
    try appendPullMergeabilityTimeline(buf, allocator, raw_ref, merge_status);
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
    var stmt = try work_items.prepareCommentsStmt(db, "pull", pull_id);
    defer stmt.deinit();
    while (try stmt.step()) {
        const row = try work_items.commentRowFromStmt(allocator, &stmt);
        defer row.deinit(allocator);
        const anchor = try std.fmt.allocPrint(allocator, "comment-{s}", .{row.id[0..@min(row.id.len, 7)]});
        defer allocator.free(anchor);
        var comment_ref_buf: [util.short_object_ref_len]u8 = undefined;
        const comment_ref = util.shortObjectRef(&comment_ref_buf, row.id);
        const comment_ref_value = try std.fmt.allocPrint(allocator, "comment:{s}", .{comment_ref});
        defer allocator.free(comment_ref_value);

        try appendTemplate(buf, allocator,
            \\<div class="{classes}" id="{anchor}"><div class="issue-timeline-avatar">
        , .{
            .classes = shared.classes("issue-timeline-item", &.{shared.class("is-reply", row.isReply())}),
            .anchor = anchor,
        });
        try appendAvatar(buf, allocator, row.display_author, "issue-detail-avatar");
        try appendTemplate(buf, allocator,
            \\</div><article class="issue-comment-box comment-card"><header class="issue-comment-head"><div><strong>{author}</strong><span>commented
        , .{
            .author = row.display_author,
        });
        try buf.append(allocator, ' ');
        try appendRelativeTime(buf, allocator, row.created_at);
        try buf.appendSlice(allocator, "</span></div>");
        try issues_page.appendIssueActionMenu(buf, allocator, anchor, comment_ref_value, row.body, !row.redacted and row.body.len != 0, "");
        try buf.appendSlice(allocator, "</header>");
        if (row.isReply()) {
            try buf.appendSlice(allocator, "<p class=\"reply-note\">Reply to ");
            if (row.reply_parent_id.len != 0) {
                var reply_ref_buf: [util.short_object_ref_len]u8 = undefined;
                const reply_ref = util.shortObjectRef(&reply_ref_buf, row.reply_parent_id);
                try appendTemplate(buf, allocator, "comment:{reply_ref}", .{ .reply_ref = reply_ref });
            } else {
                try appendTemplate(buf, allocator, "{reply_parent_hash}", .{ .reply_parent_hash = row.reply_parent_hash[0..@min(row.reply_parent_hash.len, 12)] });
            }
            try buf.appendSlice(allocator, "</p>");
        }
        try buf.appendSlice(allocator, "<div class=\"markdown-body\">");
        if (row.redacted) {
            try buf.appendSlice(allocator, "<p class=\"muted\">Comment redacted.</p>");
        } else {
            try shared.appendMarkdownSource(buf, allocator, row.body, .{});
        }
        try buf.appendSlice(allocator, "</div>");
        try appendPullReactionBar(buf, allocator, db, "comment", row.id, raw_ref, comment_ref_value, current_actor);
        try buf.appendSlice(allocator, "</article></div>");
    }
}

fn appendPullResolutionTimeline(buf: *std.ArrayList(u8), allocator: Allocator, detail: PullDetail) !void {
    if (!std.mem.eql(u8, detail.state, "merged") and !std.mem.eql(u8, detail.state, "closed")) return;
    const merged = std.mem.eql(u8, detail.state, "merged");
    const merge_display_oid = if (detail.merge_oid.len != 0) detail.merge_oid else detail.target_oid;

    try appendTemplate(buf, allocator,
        \\<div class="issue-timeline-item pull-event-item">
        \\  <div class="issue-timeline-avatar"><span class="pull-timeline-icon is-{state}" aria-hidden="true"></span></div>
        \\  <div class="pull-event-text"><span><strong>{actor}</strong> {verb}
    , .{
        .state = detail.state,
        .actor = if (detail.state_actor_principal.len != 0) detail.state_actor_principal else detail.author_principal,
        .verb = if (merged and merge_display_oid.len != 0) "merged commit" else if (merged) "merged this pull request" else "closed this pull request",
    });
    if (merged and merge_display_oid.len != 0) {
        try appendTemplate(buf, allocator,
            \\ <a href="{href}"><code>{short_oid}</code></a> into <code>{base_ref}</code>
        , .{
            .href = commitHref(merge_display_oid),
            .short_oid = merge_display_oid[0..@min(merge_display_oid.len, 12)],
            .base_ref = detail.base_ref,
        });
    }
    try buf.append(allocator, ' ');
    try appendRelativeTime(buf, allocator, detail.state_occurred_at);
    try buf.appendSlice(allocator, "</span>");
    if (merged) {
        try buf.appendSlice(allocator, "<button class=\"button secondary pull-revert-button\" type=\"button\" disabled>Revert</button>");
    }
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
        .title = if (merged) "Pull request successfully merged and closed" else "Pull request closed",
        .body = if (merged) "You're all set - the branch has been merged." else "This pull request was closed without being merged.",
    });
}

fn appendPullMergeabilityTimeline(buf: *std.ArrayList(u8), allocator: Allocator, raw_ref: []const u8, merge_status: PullMergeStatus) !void {
    if (!merge_status.hasConflicts()) return;
    try buf.appendSlice(allocator,
        \\<div class="issue-timeline-item pull-mergeability-item" id="pull-mergeability">
        \\  <div class="issue-timeline-avatar"><span class="pull-mergeability-icon is-conflicts" aria-hidden="true"></span></div>
        \\  <div class="pull-mergeability-box is-conflicts">
        \\    <div class="pull-mergeability-head">
        \\      <div>
        \\        <h2>This branch has conflicts that must be resolved</h2>
        \\        <p>Resolve these files in the web editor, then commit the resolution back to the pull request branch.</p>
        \\      </div>
        \\      <a class="button secondary pull-mergeability-action" href="/pulls/
    );
    try shared.appendUrlEncoded(buf, allocator, raw_ref);
    try buf.appendSlice(allocator,
        \\/conflicts">Resolve conflicts</a>
        \\    </div>
    );
    if (merge_status.conflict_files) |conflict_files| {
        if (conflict_files.len == 0) {
            try buf.appendSlice(allocator, "<p class=\"pull-mergeability-empty\">Git reported merge conflicts, but did not return file names.</p>");
        } else {
            try buf.appendSlice(allocator, "<ul class=\"pull-conflict-file-list\">");
            for (conflict_files) |file| {
                try appendTemplate(buf, allocator,
                    \\<li><span class="pull-conflict-file-icon" aria-hidden="true"></span><code>{file}</code></li>
                , .{ .file = file });
            }
            try buf.appendSlice(allocator, "</ul>");
        }
    } else {
        try buf.appendSlice(allocator, "<p class=\"pull-mergeability-empty\">Git reported merge conflicts, but did not return file names.</p>");
    }
    try buf.appendSlice(allocator, "</div></div>");
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
    );
    try shared.appendMarkdownEditor(buf, allocator, .{});
    try buf.appendSlice(allocator,
        \\  <div class="issue-comment-form-actions">
        \\    <button class="button primary" type="submit">Comment</button>
        \\  </div>
        \\</form>
        \\</div>
    );
}

fn appendPullCommits(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, detail: PullDetail) !void {
    const commits_opt = try loadPullCommits(allocator, repo, detail);
    const commits = commits_opt orelse {
        if (detail.commit_count) |count| {
            const hint = try pullGitDataFetchHint(allocator, detail);
            defer allocator.free(hint);
            const detail_text = try std.fmt.allocPrint(allocator, "GitHub reported {d} {s}. {s}", .{ count, commitWord(count), hint });
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

fn appendPullFiles(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, detail: PullDetail, raw_ref: []const u8) !void {
    const diff_opt = try work_items.loadPullDiff(allocator, repo, detail, 3);
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
    try buf.appendSlice(allocator, "<section class=\"diff-section pull-diff-section\" data-diff-review-action=\"/pulls/");
    try shared.appendUrlEncoded(buf, allocator, raw_ref);
    try buf.appendSlice(allocator, "/comments\">");
    try appendPullDiff(buf, allocator, diff);
    try buf.appendSlice(allocator, "</section>");
}

fn pullImportedFileSummary(allocator: Allocator, detail: PullDetail) ![]u8 {
    const file_count = detail.changed_files orelse 0;
    const additions = detail.additions orelse 0;
    const deletions = detail.deletions orelse 0;
    const hint = try pullGitDataFetchHint(allocator, detail);
    defer allocator.free(hint);
    if (detail.additions != null or detail.deletions != null) {
        return std.fmt.allocPrint(allocator, "GitHub reported {d} changed {s} with +{d} -{d}. {s}", .{ file_count, if (file_count == 1) "file" else "files", additions, deletions, hint });
    }
    return std.fmt.allocPrint(allocator, "GitHub reported {d} changed {s}. {s}", .{ file_count, if (file_count == 1) "file" else "files", hint });
}

fn pullGitDataFetchHint(allocator: Allocator, detail: PullDetail) ![]u8 {
    if (detail.legacy_number > 0) {
        return std.fmt.allocPrint(
            allocator,
            "Fetch the PR head with `git fetch origin pull/{d}/head:refs/remotes/origin/pr/{d}`, then reload this page.",
            .{ detail.legacy_number, detail.legacy_number },
        );
    }
    return allocator.dupe(u8, "Fetch or create the base and head refs locally, then reload this page.");
}

fn loadPullCommits(allocator: Allocator, repo: Repo, detail: PullDetail) !?[]PullCommit {
    const git_refs = (try work_items.loadPullGitRefs(allocator, repo, detail)) orelse return null;
    defer git_refs.deinit(allocator);

    const merge_base = try work_items.loadMergeBase(allocator, repo, git_refs.base, git_refs.head);
    defer if (merge_base) |value| allocator.free(value);
    const base = merge_base orelse return null;
    const range = try std.fmt.allocPrint(allocator, "{s}..{s}", .{ base, git_refs.head });
    defer allocator.free(range);
    const raw = try work_items.gitMaybe(allocator, repo, &.{ "log", "--reverse", "--format=%H%x00%h%x00%an%x00%cr%x00%s", range }, git.max_git_output) orelse return null;
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

fn resolveGithubPullHeadCommit(allocator: Allocator, repo: Repo, number: i64) !?[]u8 {
    if (try resolveFormattedGithubPullRef(allocator, repo, "refs/remotes/origin/pr/{d}", number)) |oid| return oid;
    if (try resolveFormattedGithubPullRef(allocator, repo, "refs/remotes/origin/pull/{d}/head", number)) |oid| return oid;
    if (try resolveFormattedGithubPullRef(allocator, repo, "refs/pull/{d}/head", number)) |oid| return oid;
    if (try resolveFormattedGithubPullRef(allocator, repo, "refs/gitomi/github/pull/{d}/head", number)) |oid| return oid;
    return null;
}

fn resolveFormattedGithubPullRef(allocator: Allocator, repo: Repo, comptime pattern: []const u8, number: i64) !?[]u8 {
    const ref = try std.fmt.allocPrint(allocator, pattern, .{number});
    defer allocator.free(ref);
    return try resolveGitCommit(allocator, repo, ref);
}

fn resolvePullGitCommit(allocator: Allocator, repo: Repo, raw_ref: []const u8, prefer_remote: bool) !?[]u8 {
    if (prefer_remote and isBranchShorthand(raw_ref)) {
        const remote_ref = try std.fmt.allocPrint(allocator, "refs/remotes/origin/{s}", .{raw_ref});
        defer allocator.free(remote_ref);
        if (try resolveGitCommit(allocator, repo, remote_ref)) |oid| return oid;
    }

    if (try resolveGitCommit(allocator, repo, raw_ref)) |oid| return oid;

    if (!prefer_remote and isBranchShorthand(raw_ref)) {
        const remote_ref = try std.fmt.allocPrint(allocator, "refs/remotes/origin/{s}", .{raw_ref});
        defer allocator.free(remote_ref);
        if (try resolveGitCommit(allocator, repo, remote_ref)) |oid| return oid;
    }

    return null;
}

fn resolveGitCommit(allocator: Allocator, repo: Repo, ref: []const u8) !?[]u8 {
    const commit_ref = try std.fmt.allocPrint(allocator, "{s}^{{commit}}", .{ref});
    defer allocator.free(commit_ref);
    const raw = try work_items.gitMaybe(allocator, repo, &.{ "rev-parse", "--verify", "--quiet", commit_ref }, 1024 * 1024) orelse return null;
    defer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

fn isBranchShorthand(ref: []const u8) bool {
    if (ref.len == 0) return false;
    if (std.mem.startsWith(u8, ref, "refs/")) return false;
    if (std.mem.startsWith(u8, ref, "origin/")) return false;
    if (std.mem.startsWith(u8, ref, "-")) return false;
    if (std.mem.endsWith(u8, ref, ".lock")) return false;
    if (std.mem.indexOf(u8, ref, "..") != null) return false;
    if (std.mem.indexOf(u8, ref, "//") != null) return false;
    if (std.mem.indexOf(u8, ref, "@{") != null) return false;
    if (std.mem.indexOfAny(u8, ref, " \t\r\n\x00:^~?*[\\") != null) return false;
    return true;
}

fn loadPullMergeStatus(allocator: Allocator, repo: Repo, detail: PullDetail) !PullMergeStatus {
    if (!std.mem.eql(u8, detail.state, "open")) return .{ .kind = .unavailable };

    const git_refs = (try work_items.loadPullGitRefs(allocator, repo, detail)) orelse return .{ .kind = .unavailable };
    errdefer git_refs.deinit(allocator);

    const merge_base = try work_items.loadMergeBase(allocator, repo, git_refs.base, git_refs.head);
    defer if (merge_base) |value| allocator.free(value);
    if (merge_base == null) {
        git_refs.deinit(allocator);
        return .{ .kind = .unavailable };
    }

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{
        "git",
        "-C",
        repo.root,
        "merge-tree",
        "--write-tree",
        "--name-only",
        "--no-messages",
        "-z",
        git_refs.head,
        git_refs.base,
    });

    var result = try runCommand(allocator, argv.items, null, max_pull_diff_bytes);
    defer result.deinit();
    if (result.exitCode() == 0) return .{ .kind = .clean, .git_refs = git_refs };
    if (result.exitCode() != 1) {
        git_refs.deinit(allocator);
        return .{ .kind = .unavailable };
    }

    const conflict_files = try parseMergeTreeConflictFiles(allocator, result.stdout);
    errdefer freeConflictFiles(allocator, conflict_files);
    if (conflict_files.len == 0) {
        freeConflictFiles(allocator, conflict_files);
        git_refs.deinit(allocator);
        return .{ .kind = .unavailable };
    }
    return .{
        .kind = .conflicts,
        .conflict_files = conflict_files,
        .git_refs = git_refs,
    };
}

fn parseMergeTreeConflictFiles(allocator: Allocator, raw: []const u8) ![][]u8 {
    var files: std.ArrayList([]u8) = .empty;
    errdefer {
        for (files.items) |file| allocator.free(file);
        files.deinit(allocator);
    }

    var parts = std.mem.splitScalar(u8, raw, 0);
    _ = parts.next();
    while (parts.next()) |raw_path| {
        const path = std.mem.trim(u8, raw_path, " \t\r\n");
        if (path.len == 0 or conflictFileAlreadyListed(files.items, path)) continue;
        const owned = try allocator.dupe(u8, path);
        files.append(allocator, owned) catch |err| {
            allocator.free(owned);
            return err;
        };
    }
    return try files.toOwnedSlice(allocator);
}

fn conflictFileAlreadyListed(files: []const []const u8, path: []const u8) bool {
    for (files) |file| {
        if (std.mem.eql(u8, file, path)) return true;
    }
    return false;
}

fn freeConflictFiles(allocator: Allocator, files: [][]u8) void {
    for (files) |file| allocator.free(file);
    allocator.free(files);
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
    try shared.appendAvatar(buf, allocator, name, extra_class);
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

pub fn handlePullConflictPost(allocator: Allocator, repo: Repo, stream: std.net.Stream, raw_ref: []const u8, form_body: []const u8) !void {
    try index.ensureIndex(allocator, repo);
    const pull_id = index.resolvePullId(allocator, repo, raw_ref) catch {
        try sendPlainResponse(allocator, stream, 404, "Not Found", "Pull request not found\n");
        return;
    };
    defer allocator.free(pull_id);

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    const detail = (try work_items.loadPullDetail(allocator, &db, pull_id)) orelse {
        try sendPlainResponse(allocator, stream, 404, "Not Found", "Pull request not found\n");
        return;
    };
    defer detail.deinit(allocator);

    const merge_status = try loadPullMergeStatus(allocator, repo, detail);
    defer merge_status.deinit(allocator);
    if (!merge_status.hasConflicts()) {
        try sendMergeEditorError(allocator, repo, stream, raw_ref, 409, "Conflict", "This pull request no longer reports merge conflicts.");
        return;
    }

    const conflict_files = merge_status.conflict_files orelse {
        try sendMergeEditorError(allocator, repo, stream, raw_ref, 409, "Conflict", "Git did not return the conflicting file list.");
        return;
    };

    const fields = try parseFormFieldsOwned(allocator, form_body);
    defer freeFormFields(allocator, fields);

    var resolved: std.ArrayList(ResolvedConflictFile) = .empty;
    defer resolved.deinit(allocator);
    for (conflict_files, 0..) |path, index_value| {
        const path_name = try std.fmt.allocPrint(allocator, "path_{d}", .{index_value});
        defer allocator.free(path_name);
        const content_name = try std.fmt.allocPrint(allocator, "content_{d}", .{index_value});
        defer allocator.free(content_name);

        const submitted_path = findFormField(fields, path_name) orelse {
            try sendMergeEditorError(allocator, repo, stream, raw_ref, 422, "Unprocessable Entity", "A conflict file path was missing from the submitted resolution.");
            return;
        };
        if (!std.mem.eql(u8, submitted_path, path)) {
            try sendMergeEditorError(allocator, repo, stream, raw_ref, 422, "Unprocessable Entity", "The submitted conflict file list did not match the current merge conflicts.");
            return;
        }

        const content = findFormField(fields, content_name) orelse {
            try sendMergeEditorError(allocator, repo, stream, raw_ref, 422, "Unprocessable Entity", "Every conflicting file must be editable before the web resolver can commit.");
            return;
        };
        if (contentHasConflictMarkers(content)) {
            try sendMergeEditorError(allocator, repo, stream, raw_ref, 422, "Unprocessable Entity", "Resolve every conflict marker before committing the resolution.");
            return;
        }
        try resolved.append(allocator, .{ .path = path, .content = content });
    }

    const git_refs = merge_status.git_refs orelse {
        try sendMergeEditorError(allocator, repo, stream, raw_ref, 409, "Conflict", "Git did not return the pull request refs.");
        return;
    };

    const merge_commit = commitPullConflictResolution(allocator, repo, detail, git_refs, raw_ref, resolved.items) catch |err| {
        const message = mergeCommitErrorMessage(err) orelse return err;
        try sendMergeEditorError(allocator, repo, stream, raw_ref, 422, "Unprocessable Entity", message);
        return;
    };
    defer allocator.free(merge_commit);

    const location = try std.fmt.allocPrint(allocator, "/pulls/{s}", .{raw_ref});
    defer allocator.free(location);
    try sendRedirect(allocator, stream, location);
}

pub fn handlePullChecklistPost(allocator: Allocator, repo: Repo, stream: std.net.Stream, raw_ref: []const u8, form_body: []const u8) !void {
    try index.ensureIndex(allocator, repo);
    const pull_id = index.resolvePullId(allocator, repo, raw_ref) catch {
        try sendPlainResponse(allocator, stream, 404, "Not Found", "Pull request not found\n");
        return;
    };
    defer allocator.free(pull_id);

    const body_owned = (try issues_page.formValueOwned(allocator, form_body, "body")) orelse {
        try sendPlainResponse(allocator, stream, 400, "Bad Request", "Missing body\n");
        return;
    };
    defer allocator.free(body_owned);

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var stmt = try db.prepare("SELECT body, author_principal FROM pulls WHERE id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, pull_id);
    if (!(try stmt.step())) {
        try sendPlainResponse(allocator, stream, 404, "Not Found", "Pull request not found\n");
        return;
    }
    const current_body = try stmt.columnTextDup(allocator, 0);
    defer allocator.free(current_body);
    const author_principal = try stmt.columnTextDup(allocator, 1);
    defer allocator.free(author_principal);
    if (!(try currentActorCanEditInRepo(allocator, repo, author_principal))) {
        try sendPlainResponse(allocator, stream, 403, "Forbidden", "Forbidden\n");
        return;
    }
    if (std.mem.eql(u8, body_owned, current_body)) {
        try sendResponse(allocator, stream, 204, "No Content", "text/plain", "", null);
        return;
    }

    pull.createPullUpdatedEvent(allocator, pull_id, .{ .body = body_owned }) catch {
        try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not update checklist\n");
        return;
    };
    try sendResponse(allocator, stream, 204, "No Content", "text/plain", "", null);
}

fn sendMergeEditorError(
    allocator: Allocator,
    repo: Repo,
    stream: std.net.Stream,
    raw_ref: []const u8,
    status: u16,
    reason: []const u8,
    message: []const u8,
) !void {
    const target = try std.fmt.allocPrint(allocator, "/pulls/{s}/conflicts", .{raw_ref});
    defer allocator.free(target);
    const body = try renderPullMergeEditorPage(allocator, repo, raw_ref, target, message);
    defer allocator.free(body);
    try sendResponse(allocator, stream, status, reason, "text/html", body, null);
}

pub fn handlePullCommentPost(allocator: Allocator, repo: Repo, stream: std.net.Stream, raw_ref: []const u8, form_body: []const u8) !void {
    const fields = try parseFormFieldsOwned(allocator, form_body);
    defer freeFormFields(allocator, fields);

    if (findFormField(fields, "action")) |raw_action| {
        const action = std.mem.trim(u8, raw_action, " \t\r\n");
        if (std.mem.eql(u8, action, "add-reaction") or std.mem.eql(u8, action, "remove-reaction")) {
            try index.ensureIndex(allocator, repo);
            const pull_id = index.resolvePullId(allocator, repo, raw_ref) catch {
                try sendPlainResponse(allocator, stream, 404, "Not Found", "Pull request not found\n");
                return;
            };
            defer allocator.free(pull_id);

            const raw_emoji = findFormField(fields, "emoji") orelse {
                try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Emoji is required\n");
                return;
            };
            const emoji = std.mem.trim(u8, raw_emoji, " \t\r\n");
            if (emoji.len == 0) {
                try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Emoji is required\n");
                return;
            }

            const target_kind = std.mem.trim(u8, findFormField(fields, "target_kind") orelse "pull", " \t\r\n");
            const add = std.mem.eql(u8, action, "add-reaction");
            if (std.mem.eql(u8, target_kind, "pull")) {
                createReactionEvent(allocator, "pull", pull_id, emoji, add) catch {
                    try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not update reaction\n");
                    return;
                };
            } else if (std.mem.eql(u8, target_kind, "comment")) {
                const target_ref = findFormField(fields, "target_ref") orelse {
                    try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Comment target is required\n");
                    return;
                };
                const comment_id = index.resolveCommentId(allocator, repo, target_ref) catch {
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

    const body_value = findFormField(fields, "body") orelse "";
    const body = std.mem.trim(u8, body_value, " \t\r\n");
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

    const reply_ref = std.mem.trim(u8, findFormField(fields, "reply_parent_ref") orelse "", " \t\r\n");
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
        createCommentReplyEvent(allocator, "pull", pull_id, reply_parent_id, parent.add_hash, body_value) catch {
            try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not add the reply\n");
            return;
        };
    } else {
        const diff_context = parseDiffCommentContext(fields) catch {
            try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Diff comment target is invalid\n");
            return;
        };
        const comment_body_owned = if (diff_context) |context| try work_items.formatDiffCommentBody(allocator, context, body_value) else null;
        defer if (comment_body_owned) |value| allocator.free(value);
        const comment_body = comment_body_owned orelse body_value;

        createCommentAddedEvent(allocator, "pull", pull_id, comment_body) catch {
            try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not add the comment\n");
            return;
        };
    }

    const location = try std.fmt.allocPrint(allocator, "/pulls/{s}", .{raw_ref});
    defer allocator.free(location);
    try sendRedirect(allocator, stream, location);
}

fn queryTextFilterOwned(allocator: Allocator, target: []const u8, name: []const u8) !?[]u8 {
    const owned = try queryValueOwned(allocator, target, name) orelse return null;
    const trimmed = std.mem.trim(u8, owned, " \t\r\n");
    if (trimmed.len == 0) {
        allocator.free(owned);
        return null;
    }
    if (trimmed.ptr == owned.ptr and trimmed.len == owned.len) return owned;
    const result = try allocator.dupe(u8, trimmed);
    allocator.free(owned);
    return result;
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

fn parseFormFieldsOwned(allocator: Allocator, body: []const u8) ![]FormField {
    var fields: std.ArrayList(FormField) = .empty;
    errdefer {
        for (fields.items) |field| field.deinit(allocator);
        fields.deinit(allocator);
    }

    var pairs = std.mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const raw_key = pair[0..eq];
        const raw_value = if (eq < pair.len) pair[eq + 1 ..] else "";
        const key = try issues_page.percentDecodeForm(allocator, raw_key);
        errdefer allocator.free(key);
        const value = try issues_page.percentDecodeForm(allocator, raw_value);
        errdefer allocator.free(value);
        try fields.append(allocator, .{ .name = key, .value = value });
    }
    return try fields.toOwnedSlice(allocator);
}

fn freeFormFields(allocator: Allocator, fields: []FormField) void {
    for (fields) |field| field.deinit(allocator);
    allocator.free(fields);
}

fn findFormField(fields: []const FormField, name: []const u8) ?[]const u8 {
    for (fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return field.value;
    }
    return null;
}

fn parseDiffCommentContext(fields: []const FormField) !?DiffCommentContext {
    const raw_file = findFormField(fields, "diff_file");
    const raw_side = findFormField(fields, "diff_side");
    const raw_start = findFormField(fields, "diff_start");
    const raw_end = findFormField(fields, "diff_end");

    if (raw_file == null and raw_side == null and raw_start == null and raw_end == null) return null;
    if (raw_file == null or raw_side == null or raw_start == null or raw_end == null) return error.InvalidDiffCommentContext;

    const file = std.mem.trim(u8, raw_file.?, " \t\r\n");
    if (!work_items.validateDiffCommentPath(file)) return error.InvalidDiffCommentContext;

    const side_name = std.mem.trim(u8, raw_side.?, " \t\r\n");
    const side: DiffCommentSide = if (std.mem.eql(u8, side_name, "old"))
        .old
    else if (std.mem.eql(u8, side_name, "new"))
        .new
    else
        return error.InvalidDiffCommentContext;

    const start_line = parseDiffCommentLine(raw_start.?) orelse return error.InvalidDiffCommentContext;
    const end_line = parseDiffCommentLine(raw_end.?) orelse return error.InvalidDiffCommentContext;
    if (end_line < start_line) return error.InvalidDiffCommentContext;

    return .{
        .file = file,
        .side = side,
        .start_line = start_line,
        .end_line = end_line,
    };
}

fn parseDiffCommentLine(value: []const u8) ?usize {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;
    const parsed = std.fmt.parseUnsigned(usize, trimmed, 10) catch return null;
    return if (parsed == 0) null else parsed;
}

fn contentHasConflictMarkers(content: []const u8) bool {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, "\r");
        if (std.mem.startsWith(u8, trimmed, "<<<<<<<")) return true;
        if (std.mem.startsWith(u8, trimmed, "|||||||")) return true;
        if (std.mem.eql(u8, trimmed, "=======")) return true;
        if (std.mem.startsWith(u8, trimmed, ">>>>>>>")) return true;
    }
    return false;
}

fn commitPullConflictResolution(
    allocator: Allocator,
    repo: Repo,
    detail: PullDetail,
    git_refs: PullGitRefs,
    raw_ref: []const u8,
    resolved_files: []const ResolvedConflictFile,
) ![]u8 {
    if (resolved_files.len == 0) return error.NoConflictResolutions;
    const update_ref = try localHeadUpdateRef(allocator, repo, detail.head_ref);
    defer allocator.free(update_ref);

    const old_head_raw = try gitCheckedAt(allocator, repo.root, &.{ "rev-parse", "--verify", update_ref }, 1024 * 1024);
    defer allocator.free(old_head_raw);
    const old_head = try allocator.dupe(u8, std.mem.trim(u8, old_head_raw, " \t\r\n"));
    defer allocator.free(old_head);
    if (old_head.len == 0) return error.NoLocalHeadBranch;
    if (!std.mem.eql(u8, old_head, git_refs.head)) return error.PullHeadChanged;

    const tmp_worktree = try tempPath(allocator, "gitomi-merge-worktree");
    defer allocator.free(tmp_worktree);
    var worktree_created = false;
    defer {
        if (worktree_created) {
            var remove_result = gitRunAt(allocator, repo.root, &.{ "worktree", "remove", "--force", tmp_worktree }, 1024 * 1024) catch null;
            if (remove_result) |*result| result.deinit();
        }
        std.fs.deleteTreeAbsolute(tmp_worktree) catch {};
    }

    const worktree_add_raw = try gitCheckedAt(allocator, repo.root, &.{ "worktree", "add", "--detach", tmp_worktree, old_head }, git.max_git_output);
    allocator.free(worktree_add_raw);
    worktree_created = true;

    var merge_result = try gitRunAt(allocator, tmp_worktree, &.{ "merge", "--no-ff", "--no-commit", git_refs.base }, git.max_git_output);
    defer merge_result.deinit();
    if (merge_result.exitCode()) |code| {
        if (code != 0 and code != 1) return error.MergePreparationFailed;
    } else {
        return error.MergePreparationFailed;
    }

    for (resolved_files) |file| {
        if (!isSafeMergePath(file.path)) return error.UnsafeConflictPath;
        const absolute_path = try std.fs.path.join(allocator, &.{ tmp_worktree, file.path });
        defer allocator.free(absolute_path);
        try writeFileBytes(absolute_path, file.content);
        const add_raw = try gitCheckedAt(allocator, tmp_worktree, &.{ "add", "--", file.path }, git.max_git_output);
        allocator.free(add_raw);
    }

    const unmerged_raw = try gitCheckedAt(allocator, tmp_worktree, &.{ "diff", "--name-only", "--diff-filter=U" }, git.max_git_output);
    defer allocator.free(unmerged_raw);
    if (std.mem.trim(u8, unmerged_raw, " \t\r\n").len != 0) return error.UnresolvedConflicts;

    const message = try std.fmt.allocPrint(allocator, "Resolve merge conflicts for PR {s}", .{raw_ref});
    defer allocator.free(message);
    const commit_output = try gitCheckedAt(allocator, tmp_worktree, &.{ "commit", "-m", message }, git.max_git_output);
    allocator.free(commit_output);

    const commit_raw = try gitCheckedAt(allocator, tmp_worktree, &.{ "rev-parse", "HEAD" }, 1024 * 1024);
    defer allocator.free(commit_raw);
    const commit_oid = try allocator.dupe(u8, std.mem.trim(u8, commit_raw, " \t\r\n"));
    errdefer allocator.free(commit_oid);
    if (commit_oid.len == 0) return error.MergeCommitFailed;

    const update_output = try gitCheckedAt(allocator, repo.root, &.{ "update-ref", update_ref, commit_oid, old_head }, git.max_git_output);
    allocator.free(update_output);
    return commit_oid;
}

fn localHeadUpdateRef(allocator: Allocator, repo: Repo, head_ref: []const u8) ![]u8 {
    const symbolic_raw = gitCheckedAt(allocator, repo.root, &.{ "rev-parse", "--symbolic-full-name", "--verify", head_ref }, 1024 * 1024) catch |err| switch (err) {
        error.GitFailed => return error.NoLocalHeadBranch,
        else => return err,
    };
    defer allocator.free(symbolic_raw);
    const symbolic = std.mem.trim(u8, symbolic_raw, " \t\r\n");
    if (!std.mem.startsWith(u8, symbolic, "refs/heads/")) return error.NoLocalHeadBranch;
    return allocator.dupe(u8, symbolic);
}

fn mergeCommitErrorMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.NoLocalHeadBranch => "The pull request head must be a local branch before the web resolver can update it.",
        error.NoConflictResolutions => "No conflict resolutions were submitted.",
        error.PullHeadChanged => "The local pull request head no longer matches the conflicts shown by the web resolver. Refresh the page and try again.",
        error.UnsafeConflictPath => "A conflicting path is not safe to write from the web resolver.",
        error.MergePreparationFailed => "Git could not prepare a merge worktree for this pull request.",
        error.UnresolvedConflicts => "Git still reports unresolved conflicts after applying the submitted files.",
        error.MergeCommitFailed => "Git could not create the merge-resolution commit.",
        error.GitFailed => "Git could not commit the resolution. Check the repository state and signing configuration.",
        else => null,
    };
}

fn gitRunAt(allocator: Allocator, root: []const u8, git_args: []const []const u8, max_output_bytes: usize) !git.RunOutput {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    try argv.append(allocator, "-C");
    try argv.append(allocator, root);
    for (git_args) |arg| try argv.append(allocator, arg);
    return runCommand(allocator, argv.items, null, max_output_bytes);
}

fn gitCheckedAt(allocator: Allocator, root: []const u8, git_args: []const []const u8, max_output_bytes: usize) ![]u8 {
    var result = try gitRunAt(allocator, root, git_args, max_output_bytes);
    if (result.exitCode() == 0) {
        const stdout = result.stdout;
        allocator.free(result.stderr);
        return stdout;
    }
    result.deinit();
    return error.GitFailed;
}

fn freePullCommits(allocator: Allocator, commits: []PullCommit) void {
    for (commits) |commit| commit.deinit(allocator);
    allocator.free(commits);
}

test "parse merge-tree conflict file names" {
    const raw = "b8424e5199eed14e5e0c4fa9a3668f146ef44ae9\x00cli/src/github.zig\x00cli/src/sync.zig\x00";
    const files = try parseMergeTreeConflictFiles(std.testing.allocator, raw);
    defer freeConflictFiles(std.testing.allocator, files);

    try std.testing.expectEqual(@as(usize, 2), files.len);
    try std.testing.expectEqualStrings("cli/src/github.zig", files[0]);
    try std.testing.expectEqualStrings("cli/src/sync.zig", files[1]);
}

test "parse merge-tree conflict file names skips duplicates and empty records" {
    const raw = "tree\x00a.zig\x00\x00a.zig\x00b.zig\x00";
    const files = try parseMergeTreeConflictFiles(std.testing.allocator, raw);
    defer freeConflictFiles(std.testing.allocator, files);

    try std.testing.expectEqual(@as(usize, 2), files.len);
    try std.testing.expectEqualStrings("a.zig", files[0]);
    try std.testing.expectEqualStrings("b.zig", files[1]);
}

test "parse merge-tree conflict file names returns empty for git errors without paths" {
    const files = try parseMergeTreeConflictFiles(std.testing.allocator, "");
    defer freeConflictFiles(std.testing.allocator, files);

    try std.testing.expectEqual(@as(usize, 0), files.len);
}

test "parse diff comment context from form fields" {
    const fields = try parseFormFieldsOwned(std.testing.allocator, "diff_file=cli%2Fsrc%2Fpulls.zig&diff_side=new&diff_start=139&diff_end=151");
    defer freeFormFields(std.testing.allocator, fields);

    const context = (try parseDiffCommentContext(fields)).?;
    try std.testing.expectEqualStrings("cli/src/pulls.zig", context.file);
    try std.testing.expectEqual(DiffCommentSide.new, context.side);
    try std.testing.expectEqual(@as(usize, 139), context.start_line);
    try std.testing.expectEqual(@as(usize, 151), context.end_line);
}

test "format diff comment body includes file and line range" {
    const body = try work_items.formatDiffCommentBody(std.testing.allocator, .{
        .file = "cli/src/pulls.zig",
        .side = .new,
        .start_line = 139,
        .end_line = 151,
    }, "Looks good.");
    defer std.testing.allocator.free(body);

    try std.testing.expectEqualStrings(
        "Review comment on `cli/src/pulls.zig` (new lines 139-151).\n\nLooks good.",
        body,
    );
}

test "content conflict marker detection" {
    try std.testing.expect(contentHasConflictMarkers("a\n<<<<<<< head\nb\n=======\nc\n>>>>>>> main\n"));
    try std.testing.expect(!contentHasConflictMarkers("const divider = \"=======\";\n"));
}

test "merge editor counts conflict groups" {
    try std.testing.expectEqual(@as(usize, 2), countConflictGroups(
        \\<<<<<<< ours
        \\a
        \\=======
        \\b
        \\>>>>>>> theirs
        \\ok
        \\<<<<<<< ours
        \\c
        \\=======
        \\d
        \\>>>>>>> theirs
    ));
    try std.testing.expectEqual(@as(usize, 0), countConflictGroups("const divider = \"=======\";\n"));
}

test "merge editor visibility keeps radius around conflicts" {
    var lines: [40]MergeRenderLine = undefined;
    for (&lines, 0..) |*line, index_value| {
        line.* = .{ .line_number = index_value + 1, .text = "" };
    }
    lines[20].group_id = 1;

    markMergeLineVisibility(&lines);

    try std.testing.expect(!lines[4].visible);
    try std.testing.expect(lines[5].visible);
    try std.testing.expect(lines[20].visible);
    try std.testing.expect(lines[35].visible);
    try std.testing.expect(!lines[36].visible);
}

test "merge editor renders distant context folded" {
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(std.testing.allocator);
    for (0..20) |index_value| {
        try std.fmt.format(content.writer(std.testing.allocator), "before {d}\n", .{index_value});
    }
    try content.appendSlice(std.testing.allocator,
        \\<<<<<<< ours
        \\current
        \\=======
        \\incoming
        \\>>>>>>> theirs
        \\
    );
    for (0..20) |index_value| {
        try std.fmt.format(content.writer(std.testing.allocator), "after {d}\n", .{index_value});
    }

    var html: std.ArrayList(u8) = .empty;
    defer html.deinit(std.testing.allocator);
    try appendMergeConflictContent(&html, std.testing.allocator, "zig", content.items);

    try std.testing.expect(std.mem.indexOf(u8, html.items, "data-merge-fold-toggle") != null);
    try std.testing.expect(std.mem.indexOf(u8, html.items, "hidden data-merge-fold-id") != null);
}

test "merge-file conflict counts are treated as generated content" {
    try std.testing.expect(mergeFileProducedContent(0));
    try std.testing.expect(mergeFileProducedContent(1));
    try std.testing.expect(mergeFileProducedContent(2));
    try std.testing.expect(mergeFileProducedContent(127));
    try std.testing.expect(!mergeFileProducedContent(128));
    try std.testing.expect(!mergeFileProducedContent(255));
}

test "merge editor path safety" {
    try std.testing.expect(isSafeMergePath("src/main.zig"));
    try std.testing.expect(!isSafeMergePath("../main.zig"));
    try std.testing.expect(!isSafeMergePath("/tmp/main.zig"));
    try std.testing.expect(!isSafeMergePath("src/.git/config"));
}
