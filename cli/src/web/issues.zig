const std = @import("std");
const comment_mod = @import("../comment.zig");
const event_mod = @import("../event.zig");
const index = @import("../index.zig");
const issue = @import("../issue.zig");
const reaction_mod = @import("../reaction.zig");
const repo_mod = @import("../repo.zig");
const shared = @import("shared.zig");
const util = @import("../util.zig");
const work_items = @import("../work_items.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const SqliteDb = index.SqliteDb;
const appendEmptyState = shared.appendEmptyState;
const appendSectionHead = shared.appendSectionHead;
const appendShellEnd = shared.appendShellEnd;
const appendShellStart = shared.appendShellStart;
const appendRelativeTime = shared.appendRelativeTime;
const appendTemplate = shared.appendTemplate;
const createCommentAddedEvent = comment_mod.createCommentAddedEvent;
const createCommentBodySetEvent = comment_mod.createCommentBodySetEvent;
const createCommentReplyEvent = comment_mod.createCommentReplyEvent;
const createIssueOpenedEvent = issue.createIssueOpenedEvent;
const createIssueProjectEvent = issue.createIssueProjectEvent;
const createIssueStringEvent = issue.createIssueStringEvent;
const createIssueUpdatedEvent = issue.createIssueUpdatedEvent;
const createReactionEvent = reaction_mod.createReactionEvent;
const ensureIndex = index.ensureIndex;
const commitHref = shared.commitHref;
const issueHref = shared.issueHref;
const pullHref = shared.pullHref;
const sendRedirect = shared.sendRedirect;
const sendPlainResponse = shared.sendPlainResponse;
const sendResponse = shared.sendResponse;
const splitCommaFields = util.splitCommaFields;
const sqlite = index.sqlite;

const IssueStateFilter = work_items.IssueStateFilter;
const IssueCounts = work_items.IssueCounts;
const IssueSort = work_items.IssueSort;
const IssueFilters = work_items.IssueListOptions;

const IssueFilterKind = enum {
    author,
    label,
    project,
    milestone,
    assignee,
};

const issue_sidebar_csrf_field = "csrf_token";
const issue_sidebar_csrf_token_len = 64;

var issue_sidebar_csrf_mutex: std.Thread.Mutex = .{};
var issue_sidebar_csrf_ready = false;
var issue_sidebar_csrf_token: [issue_sidebar_csrf_token_len]u8 = undefined;

fn issueSidebarCsrfToken() []const u8 {
    issue_sidebar_csrf_mutex.lock();
    defer issue_sidebar_csrf_mutex.unlock();

    if (!issue_sidebar_csrf_ready) {
        var random_bytes: [issue_sidebar_csrf_token_len / 2]u8 = undefined;
        std.crypto.random.bytes(&random_bytes);
        const hex = "0123456789abcdef";
        for (random_bytes, 0..) |byte, i| {
            issue_sidebar_csrf_token[i * 2] = hex[@as(usize, byte >> 4)];
            issue_sidebar_csrf_token[i * 2 + 1] = hex[@as(usize, byte & 0x0f)];
        }
        issue_sidebar_csrf_ready = true;
    }

    return issue_sidebar_csrf_token[0..];
}

fn validateIssueSidebarCsrf(allocator: Allocator, stream: std.net.Stream, form_body: []const u8) !bool {
    const token_owned = (try formValueOwned(allocator, form_body, issue_sidebar_csrf_field)) orelse {
        try sendPlainResponse(allocator, stream, 403, "Forbidden", "Invalid sidebar form token\n");
        return false;
    };
    defer allocator.free(token_owned);

    const token = std.mem.trim(u8, token_owned, " \t\r\n");
    if (!std.mem.eql(u8, token, issueSidebarCsrfToken())) {
        try sendPlainResponse(allocator, stream, 403, "Forbidden", "Invalid sidebar form token\n");
        return false;
    }
    return true;
}

const IssueHrefOverride = struct {
    state: ?IssueStateFilter = null,
    sort: ?IssueSort = null,
    param_name: ?[]const u8 = null,
    param_value: ?[]const u8 = null,
};

const IssueProjectSummary = struct {
    project: []const u8,
    column: []const u8,
};

const RelationshipKind = enum {
    refs,
    relates_to,
    blocks,
    blocked_by,
    duplicates,
    duplicate_of,
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

const ResolvedObjectRef = struct {
    allocator: Allocator,
    object_kind: []const u8,
    object_id: []u8,
    title: []u8,
    state: []u8,
    legacy_number: i64,

    fn deinit(self: *ResolvedObjectRef) void {
        self.allocator.free(self.object_id);
        self.allocator.free(self.title);
        self.allocator.free(self.state);
    }
};

const RelationshipItem = struct {
    kind: RelationshipKind,
    target: ResolvedObjectRef,

    fn deinit(self: *RelationshipItem) void {
        self.target.deinit();
    }
};

pub fn renderIssuesPage(allocator: Allocator, repo: Repo, target: []const u8) ![]u8 {
    if (try shared.renderIndexingPageIfStale(allocator, repo, "Issues", "issues", target)) |body| return body;
    try ensureIndex(allocator, repo);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    const requested_filter = try issueStateFilterFromTarget(allocator, target);
    const counts = try work_items.loadIssueCounts(&db);
    const default_state = requested_filter orelse if (counts.open == 0 and counts.closed > 0) IssueStateFilter.closed else IssueStateFilter.open;
    var filters = try issueFiltersFromTarget(allocator, target, default_state);
    defer filters.deinit();

    try appendShellStart(&buf, allocator, repo, "Issues", "issues");
    try appendIssuesToolbar(&buf, allocator, filters);
    try buf.appendSlice(allocator, "<section class=\"panel issues-panel\">");
    try appendIssuesListHeader(&buf, allocator, &db, filters, counts);

    var stmt = try work_items.prepareIssueListStmt(allocator, &db, filters);
    defer stmt.deinit();

    var shown: usize = 0;
    while (try stmt.step()) {
        const row = try work_items.issueListRowFromStmt(allocator, &stmt);
        defer row.deinit(allocator);
        const task_summary = shared.markdownTaskSummary(row.body);
        try appendIssueListRow(&buf, allocator, &db, row.id, row.title, row.state, row.author, row.opened_at, row.state_at, row.milestone, row.comment_count, row.legacy_number, task_summary);
        shown += 1;
    }

    if (shown == 0) {
        if (work_items.hasRestrictiveIssueFilters(filters)) {
            try appendEmptyState(&buf, allocator, "No matching issues.", "Change or clear filters to widen the issue list.");
        } else switch (filters.state) {
            .open => try appendEmptyState(&buf, allocator, "No open issues.", "Closed issues are available from the Closed tab."),
            .closed => try appendEmptyState(&buf, allocator, "No closed issues.", "Open issues are available from the Open tab."),
            .all => try appendEmptyState(&buf, allocator, "No issues yet.", "Create the first local issue from this browser UI or with gt issue open."),
        }
    }

    try buf.appendSlice(allocator, "</section>");
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn issueStateFilterFromTarget(allocator: Allocator, target: []const u8) !?IssueStateFilter {
    const state_value = try queryValueOwned(allocator, target, "state");
    defer if (state_value) |value| allocator.free(value);
    const value = state_value orelse return null;
    if (std.mem.eql(u8, value, "open")) return .open;
    if (std.mem.eql(u8, value, "closed")) return .closed;
    if (std.mem.eql(u8, value, "all")) return .all;
    return null;
}

fn issueFiltersFromTarget(allocator: Allocator, target: []const u8, default_state: IssueStateFilter) !IssueFilters {
    var filters = IssueFilters{
        .allocator = allocator,
        .state = default_state,
    };
    errdefer filters.deinit();

    if (try queryTextFilterOwned(allocator, target, "q")) |query| {
        defer allocator.free(query);
        var parsed = try work_items.parseIssueSearchQuery(allocator, query);
        defer parsed.deinit(allocator);
        if (parsed.state) |state| filters.state = state;
        if (parsed.q) |search| {
            filters.q = search;
            parsed.q = null;
        }
    }
    filters.author = try queryTextFilterOwned(allocator, target, "author");
    filters.label = try queryTextFilterOwned(allocator, target, "label");
    filters.project = try queryTextFilterOwned(allocator, target, "project");
    filters.milestone = try queryTextFilterOwned(allocator, target, "milestone");
    filters.assignee = try queryTextFilterOwned(allocator, target, "assignee");
    filters.sort = try issueSortFromTarget(allocator, target);
    return filters;
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

fn issueSortFromTarget(allocator: Allocator, target: []const u8) !IssueSort {
    const sort_value = try queryValueOwned(allocator, target, "sort");
    defer if (sort_value) |value| allocator.free(value);
    const value = sort_value orelse return .newest;
    if (std.mem.eql(u8, value, "oldest")) return .oldest;
    if (std.mem.eql(u8, value, "updated")) return .updated;
    return .newest;
}

fn appendIssuesToolbar(buf: *std.ArrayList(u8), allocator: Allocator, filters: IssueFilters) !void {
    const query = try issueSearchInputValue(allocator, filters);
    defer allocator.free(query);
    try appendTemplate(buf, allocator,
        \\<div class="issues-toolbar">
        \\  <form class="issues-search" action="/issues" method="get">
        \\    <span class="issues-search-icon" aria-hidden="true"></span>
        \\    <input type="search" name="q" value="{query}" aria-label="Search issues">
        \\    <input type="hidden" name="state" value="{state}">
    , .{
        .query = query,
        .state = work_items.issueStateValue(filters.state),
    });
    try appendIssueFilterHiddenInputs(buf, allocator, filters);
    try buf.appendSlice(allocator,
        \\  </form>
        \\  <div class="issues-toolbar-actions">
        \\    <button class="button secondary issue-tool-button" type="button" disabled><span class="button-icon icon-labels" aria-hidden="true"></span><span>Labels</span></button>
        \\    <a class="button secondary issue-tool-button" href="/projects#milestones"><span class="button-icon icon-milestones" aria-hidden="true"></span><span>Milestones</span></a>
        \\    <a class="button primary" href="/new-issue">New issue</a>
        \\  </div>
        \\</div>
    );
}

fn issueSearchInputValue(allocator: Allocator, filters: IssueFilters) ![]u8 {
    const prefix = work_items.issueSearchQuery(filters.state);
    if (filters.q) |query| return std.fmt.allocPrint(allocator, "{s} {s}", .{ prefix, query });
    return std.fmt.allocPrint(allocator, "{s} ", .{prefix});
}

fn appendIssueFilterHiddenInputs(buf: *std.ArrayList(u8), allocator: Allocator, filters: IssueFilters) !void {
    try appendHiddenInputIfPresent(buf, allocator, "author", filters.author);
    try appendHiddenInputIfPresent(buf, allocator, "label", filters.label);
    try appendHiddenInputIfPresent(buf, allocator, "project", filters.project);
    try appendHiddenInputIfPresent(buf, allocator, "milestone", filters.milestone);
    try appendHiddenInputIfPresent(buf, allocator, "assignee", filters.assignee);
    if (filters.sort != .newest) {
        try appendTemplate(buf, allocator,
            \\    <input type="hidden" name="sort" value="{sort}">
        , .{ .sort = work_items.issueSortValue(filters.sort) });
    }
}

fn appendHiddenInputIfPresent(buf: *std.ArrayList(u8), allocator: Allocator, name: []const u8, value: ?[]const u8) !void {
    if (value) |payload| {
        try appendTemplate(buf, allocator,
            \\    <input type="hidden" name="{name}" value="{value}">
        , .{
            .name = name,
            .value = payload,
        });
    }
}

fn appendIssuesListHeader(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, filters: IssueFilters, counts: IssueCounts) !void {
    try buf.appendSlice(allocator,
        \\<header class="issues-list-head">
        \\  <div class="issues-select-all"><input type="checkbox" aria-label="Select all issues" disabled></div>
        \\  <nav class="issues-state-tabs" aria-label="Issue state">
    );
    try appendIssueStateTab(buf, allocator, "Open", counts.open, .open, filters, "issue-open-icon");
    try appendIssueStateTab(buf, allocator, "Closed", counts.closed, .closed, filters, "issue-closed-icon");
    try buf.appendSlice(allocator,
        \\  </nav>
        \\  <div class="issues-filter-menus">
    );
    try appendIssueFilterMenu(buf, allocator, db, filters, .author);
    try appendIssueFilterMenu(buf, allocator, db, filters, .label);
    try appendIssueFilterMenu(buf, allocator, db, filters, .project);
    try appendIssueFilterMenu(buf, allocator, db, filters, .milestone);
    try appendIssueFilterMenu(buf, allocator, db, filters, .assignee);
    try appendIssueSortMenu(buf, allocator, filters);
    try buf.appendSlice(allocator,
        \\  </div>
        \\</header>
    );
}

fn appendIssueStateTab(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    label: []const u8,
    count: usize,
    tab_filter: IssueStateFilter,
    filters: IssueFilters,
    icon_class: []const u8,
) !void {
    try appendTemplate(buf, allocator,
        \\<a class="{classes}" href="
    , .{
        .classes = shared.classes("issues-state-tab", &.{shared.class("active", tab_filter == filters.state)}),
    });
    try appendIssuesHref(buf, allocator, filters, .{ .state = tab_filter });
    try appendTemplate(buf, allocator,
        \\"><span class="issue-tab-icon {icon_class}" aria-hidden="true"></span><span>{label}</span><span class="issue-count-badge">{count}</span></a>
    , .{
        .icon_class = icon_class,
        .label = label,
        .count = count,
    });
}

fn appendIssueFilterMenu(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    filters: IssueFilters,
    kind: IssueFilterKind,
) !void {
    const active = issueFilterValue(filters, kind);
    try appendTemplate(buf, allocator,
        \\<details{classes} data-popover-menu><summary>{label}
    , .{
        .classes = shared.classAttr("issues-filter-menu", &.{shared.class("active", active != null)}),
        .label = issueFilterLabel(kind),
    });
    if (active) |value| {
        try appendTemplate(buf, allocator, ": {value}", .{ .value = value });
    }
    try buf.appendSlice(allocator,
        \\</summary><div class="issues-filter-popover" role="menu">
    );
    try appendIssueFilterMenuLink(buf, allocator, filters, kind, null, issueFilterAllLabel(kind), null, active == null);

    var stmt = try db.prepare(issueFilterOptionsSql(kind));
    defer stmt.deinit();
    var shown = false;
    while (try stmt.step()) {
        const value = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(value);
        const count = @as(usize, @intCast(stmt.columnInt64(1)));
        try appendIssueFilterMenuLink(
            buf,
            allocator,
            filters,
            kind,
            value,
            value,
            count,
            active != null and std.mem.eql(u8, active.?, value),
        );
        shown = true;
    }
    if (!shown) {
        try appendTemplate(buf, allocator,
            \\<span class="issues-filter-empty">No values</span>
        , .{});
    }
    try buf.appendSlice(allocator, "</div></details>");
}

fn appendIssueFilterMenuLink(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    filters: IssueFilters,
    kind: IssueFilterKind,
    value: ?[]const u8,
    label: []const u8,
    count: ?usize,
    selected: bool,
) !void {
    try appendTemplate(buf, allocator,
        \\<a class="{classes}" role="menuitem" href="
    , .{ .classes = shared.classes("issues-filter-option", &.{shared.class("selected", selected)}) });
    try appendIssuesHref(buf, allocator, filters, .{
        .param_name = issueFilterParamName(kind),
        .param_value = value,
    });
    try appendTemplate(buf, allocator,
        \\"><span>{label}</span>
    , .{ .label = label });
    if (count) |value_count| {
        try appendTemplate(buf, allocator,
            \\<small>{count}</small>
        , .{ .count = value_count });
    }
    try buf.appendSlice(allocator, "</a>");
}

fn appendIssueSortMenu(buf: *std.ArrayList(u8), allocator: Allocator, filters: IssueFilters) !void {
    try appendTemplate(buf, allocator,
        \\<details{classes} data-popover-menu><summary>{label}</summary><div class="issues-filter-popover" role="menu">
    , .{
        .classes = shared.classAttr("issues-filter-menu", &.{shared.class("active", filters.sort != .newest)}),
        .label = issueSortLabel(filters.sort),
    });
    try appendIssueSortMenuLink(buf, allocator, filters, .newest);
    try appendIssueSortMenuLink(buf, allocator, filters, .oldest);
    try appendIssueSortMenuLink(buf, allocator, filters, .updated);
    try buf.appendSlice(allocator, "</div></details>");
}

fn appendIssueSortMenuLink(buf: *std.ArrayList(u8), allocator: Allocator, filters: IssueFilters, sort: IssueSort) !void {
    try appendTemplate(buf, allocator,
        \\<a class="{classes}" role="menuitem" href="
    , .{ .classes = shared.classes("issues-filter-option", &.{shared.class("selected", filters.sort == sort)}) });
    try appendIssuesHref(buf, allocator, filters, .{ .sort = sort });
    try appendTemplate(buf, allocator,
        \\"><span>{label}</span></a>
    , .{ .label = issueSortLabel(sort) });
}

fn issueFilterValue(filters: IssueFilters, kind: IssueFilterKind) ?[]const u8 {
    return switch (kind) {
        .author => filters.author,
        .label => filters.label,
        .project => filters.project,
        .milestone => filters.milestone,
        .assignee => filters.assignee,
    };
}

fn issueFilterLabel(kind: IssueFilterKind) []const u8 {
    return switch (kind) {
        .author => "Author",
        .label => "Labels",
        .project => "Projects",
        .milestone => "Milestones",
        .assignee => "Assignees",
    };
}

fn issueFilterAllLabel(kind: IssueFilterKind) []const u8 {
    return switch (kind) {
        .author => "Any author",
        .label => "Any label",
        .project => "Any project",
        .milestone => "Any milestone",
        .assignee => "Anyone",
    };
}

fn issueFilterParamName(kind: IssueFilterKind) []const u8 {
    return switch (kind) {
        .author => "author",
        .label => "label",
        .project => "project",
        .milestone => "milestone",
        .assignee => "assignee",
    };
}

fn issueFilterOptionsSql(kind: IssueFilterKind) []const u8 {
    return switch (kind) {
        .author =>
        \\SELECT author, COUNT(*)
        \\FROM (
        \\  SELECT i.id, COALESCE(NULLIF(m.source_author, ''), i.author_principal) AS author
        \\  FROM issues i
        \\  LEFT JOIN issue_metadata m ON m.issue_id = i.id
        \\)
        \\WHERE author <> ''
        \\GROUP BY author
        \\ORDER BY lower(author), author
        ,
        .label =>
        \\SELECT label, COUNT(DISTINCT issue_id)
        \\FROM issue_labels
        \\GROUP BY label
        \\ORDER BY lower(label), label
        ,
        .project =>
        \\SELECT project, COUNT(DISTINCT issue_id)
        \\FROM issue_projects
        \\GROUP BY project
        \\ORDER BY lower(project), project
        ,
        .milestone =>
        \\SELECT milestone, COUNT(*)
        \\FROM issue_metadata
        \\WHERE milestone <> ''
        \\GROUP BY milestone
        \\ORDER BY lower(milestone), milestone
        ,
        .assignee =>
        \\SELECT assignee, COUNT(DISTINCT issue_id)
        \\FROM issue_assignees
        \\GROUP BY assignee
        \\ORDER BY lower(assignee), assignee
        ,
    };
}

fn appendIssuesHref(buf: *std.ArrayList(u8), allocator: Allocator, filters: IssueFilters, override: IssueHrefOverride) !void {
    try buf.appendSlice(allocator, "/issues");
    var first = true;
    try appendIssuesHrefParam(buf, allocator, &first, "state", work_items.issueStateValue(override.state orelse filters.state));
    if (filterHrefValue(filters, override, "q")) |value| try appendIssuesHrefParam(buf, allocator, &first, "q", value);
    if (filterHrefValue(filters, override, "author")) |value| try appendIssuesHrefParam(buf, allocator, &first, "author", value);
    if (filterHrefValue(filters, override, "label")) |value| try appendIssuesHrefParam(buf, allocator, &first, "label", value);
    if (filterHrefValue(filters, override, "project")) |value| try appendIssuesHrefParam(buf, allocator, &first, "project", value);
    if (filterHrefValue(filters, override, "milestone")) |value| try appendIssuesHrefParam(buf, allocator, &first, "milestone", value);
    if (filterHrefValue(filters, override, "assignee")) |value| try appendIssuesHrefParam(buf, allocator, &first, "assignee", value);

    const sort = override.sort orelse filters.sort;
    if (sort != .newest) try appendIssuesHrefParam(buf, allocator, &first, "sort", work_items.issueSortValue(sort));
}

fn filterHrefValue(filters: IssueFilters, override: IssueHrefOverride, name: []const u8) ?[]const u8 {
    if (override.param_name) |param| {
        if (std.mem.eql(u8, param, name)) return override.param_value;
    }
    if (std.mem.eql(u8, name, "q")) return filters.q;
    if (std.mem.eql(u8, name, "author")) return filters.author;
    if (std.mem.eql(u8, name, "label")) return filters.label;
    if (std.mem.eql(u8, name, "project")) return filters.project;
    if (std.mem.eql(u8, name, "milestone")) return filters.milestone;
    if (std.mem.eql(u8, name, "assignee")) return filters.assignee;
    return null;
}

fn appendIssuesHrefParam(buf: *std.ArrayList(u8), allocator: Allocator, first: *bool, name: []const u8, value: []const u8) !void {
    try buf.appendSlice(allocator, if (first.*) "?" else "&amp;");
    first.* = false;
    try shared.appendUrlEncoded(buf, allocator, name);
    try buf.append(allocator, '=');
    try shared.appendUrlEncoded(buf, allocator, value);
}

fn appendIssueListRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    id: []const u8,
    title: []const u8,
    state: []const u8,
    author: []const u8,
    opened_at: []const u8,
    state_at: []const u8,
    milestone: []const u8,
    comment_count: usize,
    legacy_number: i64,
    task_summary: shared.MarkdownTaskSummary,
) !void {
    var issue_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const issue_ref = util.shortObjectRef(&issue_ref_buf, id);
    const closed = std.mem.eql(u8, state, "closed");
    try appendTemplate(buf, allocator,
        \\<article class="issue-list-row is-{state}">
        \\  <div class="issue-select-cell"><input type="checkbox" aria-label="Select issue {id}" disabled></div>
        \\  <div class="issue-state-cell"><span class="issue-state-icon {state}" title="{state}" aria-label="{state}"></span></div>
        \\  <div class="issue-row-content">
        \\    <div class="issue-row-title-line"><a class="issue-row-title" href="{href}">{title}</a>
    , .{
        .state = state,
        .id = issue_ref,
        .href = issueHref(issue_ref),
        .title = title,
    });
    try appendIssueRowLabels(buf, allocator, db, id);
    try appendTemplate(buf, allocator,
        \\</div><p class="issue-row-meta">#{id}
    , .{
        .id = issue_ref,
    });
    if (legacy_number > 0) {
        try buf.appendSlice(allocator, " / GitHub ");
        try appendLegacyIssueLink(buf, allocator, legacy_number);
    }
    try appendTemplate(buf, allocator,
        \\ by {author} {verb}
    , .{
        .author = author,
        .verb = if (closed) "was closed" else "opened",
    });
    try buf.append(allocator, ' ');
    try appendRelativeTime(buf, allocator, if (closed) state_at else opened_at);
    if (task_summary.hasTasks()) {
        try buf.append(allocator, ' ');
        try shared.appendMarkdownTaskProgress(buf, allocator, task_summary);
    }
    try buf.appendSlice(allocator,
        \\</p></div>
        \\  <div class="issue-row-side">
    );
    if (milestone.len != 0) {
        try appendTemplate(buf, allocator,
            \\<span class="issue-row-milestone" title="Milestone"><span class="issue-milestone-icon" aria-hidden="true"></span>{milestone}</span>
        , .{ .milestone = milestone });
    }
    try appendIssueAssignees(buf, allocator, db, id);
    if (comment_count > 0) {
        try appendTemplate(buf, allocator,
            \\<span class="issue-comments" title="Comments"><span class="issue-comments-icon" aria-hidden="true"></span>{comment_count}</span>
        , .{ .comment_count = comment_count });
    }
    try appendIssueAvatar(buf, allocator, author, "issue-author-avatar");
    try buf.appendSlice(allocator,
        \\  </div>
        \\</article>
    );
}

fn appendIssueRowLabels(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, issue_id: []const u8) !void {
    var stmt = try db.prepare("SELECT DISTINCT label FROM issue_labels WHERE issue_id = ? ORDER BY label");
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    var shown = false;
    while (try stmt.step()) {
        const label = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(label);
        if (!shown) {
            try buf.appendSlice(allocator, "<span class=\"issue-row-labels\">");
            shown = true;
        }
        try appendIssueLabel(buf, allocator, label);
    }
    if (shown) try buf.appendSlice(allocator, "</span>");
}

fn appendIssueLabel(buf: *std.ArrayList(u8), allocator: Allocator, label: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<span class="issue-label {kind}">{label}</span>
    , .{
        .kind = issueLabelKind(label),
        .label = label,
    });
}

fn appendIssueAssignees(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, issue_id: []const u8) !void {
    var stmt = try db.prepare("SELECT DISTINCT assignee FROM issue_assignees WHERE issue_id = ? ORDER BY assignee");
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    var shown = false;
    while (try stmt.step()) {
        const assignee = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(assignee);
        if (!shown) {
            try buf.appendSlice(allocator, "<span class=\"issue-row-assignees\">");
            shown = true;
        }
        try appendIssueAvatar(buf, allocator, assignee, "");
    }
    if (shown) try buf.appendSlice(allocator, "</span>");
}

fn appendIssueAvatar(buf: *std.ArrayList(u8), allocator: Allocator, name: []const u8, extra_class: []const u8) !void {
    try shared.appendAvatar(buf, allocator, name, extra_class);
}

fn issueSortLabel(sort: IssueSort) []const u8 {
    return switch (sort) {
        .newest => "Newest",
        .oldest => "Oldest",
        .updated => "Recently updated",
    };
}

fn issueLabelKind(label: []const u8) []const u8 {
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

pub fn renderIssueDetailPage(allocator: Allocator, repo: Repo, raw_ref: []const u8) ![]u8 {
    return renderIssueDetailPageWithCommentForm(allocator, repo, raw_ref, null, "");
}

fn renderIssueDetailPageWithCommentForm(
    allocator: Allocator,
    repo: Repo,
    raw_ref: []const u8,
    comment_error: ?[]const u8,
    comment_value: []const u8,
) ![]u8 {
    const return_target = try std.fmt.allocPrint(allocator, "/issues/{s}", .{raw_ref});
    defer allocator.free(return_target);
    if (try shared.renderIndexingPageIfStale(allocator, repo, "Issue", "issues", return_target)) |body| return body;
    try ensureIndex(allocator, repo);
    const issue_id = index.resolveIssueId(allocator, repo, raw_ref) catch {
        return renderIssueNotFound(allocator, repo, raw_ref);
    };
    defer allocator.free(issue_id);

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    const detail = (try work_items.loadIssueDetail(allocator, &db, issue_id)) orelse return renderIssueNotFound(allocator, repo, raw_ref);
    defer detail.deinit(allocator);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const display_author = detail.displayAuthor();
    const current_actor = try shared.currentPrincipalOwned(allocator, repo);
    defer if (current_actor) |actor| allocator.free(actor);
    const current_role = if (current_actor) |actor| try index.effectiveWriteRoleForPrincipal(allocator, repo, actor) else null;
    defer if (current_role) |role| allocator.free(role);
    const can_edit_issue = currentActorCanEditAuthor(current_actor, current_role, detail.author_principal);
    const issue_edit_href = if (can_edit_issue) try issueEditHrefOwned(allocator, raw_ref, null) else "";
    defer if (can_edit_issue) allocator.free(issue_edit_href);

    try appendShellStart(&buf, allocator, repo, detail.title, "issues");
    try buf.appendSlice(allocator, "<section class=\"issue-page\">");
    try appendIssuePageHeader(&buf, allocator, raw_ref, detail.id, detail.title, detail.state, display_author, detail.opened_at, detail.state_occurred_at, detail.comment_count, detail.legacy_number, can_edit_issue);
    try appendTemplate(&buf, allocator,
        \\  <div class="issue-conversation-layout">
        \\    <div class="issue-conversation">
        \\      <div class="issue-timeline-item">
        \\        <div class="issue-timeline-avatar">
    , .{});
    try appendIssueAvatar(&buf, allocator, display_author, "issue-detail-avatar");
    try appendTemplate(&buf, allocator,
        \\        </div>
        \\        <article class="issue-comment-box" id="issue-description">
        \\          <header class="issue-comment-head">
        \\            <div><strong>{author}</strong><span>opened
    , .{
        .author = display_author,
    });
    try buf.append(allocator, ' ');
    try appendRelativeTime(&buf, allocator, detail.opened_at);
    try buf.appendSlice(allocator, "</span></div>");
    try appendIssueActionMenu(&buf, allocator, "issue-description", "", detail.body, detail.body.len != 0, issue_edit_href);
    try buf.appendSlice(allocator,
        \\          </header>
        \\          <div class="markdown-body"
    );
    if (can_edit_issue) {
        try buf.appendSlice(allocator, " data-checklist-owner=\"issue\" data-checklist-update-action=\"/issues/");
        try shared.appendUrlEncoded(&buf, allocator, raw_ref);
        try buf.appendSlice(allocator, "/checklist\"");
    }
    try buf.appendSlice(allocator, ">");
    if (detail.body.len == 0) {
        try buf.appendSlice(allocator, "<p class=\"muted\">No description provided.</p>");
    } else {
        try shared.appendMarkdownSource(&buf, allocator, detail.body, .{});
    }
    try buf.appendSlice(allocator,
        \\          </div>
    );
    try appendReactionBar(&buf, allocator, &db, "issue", detail.id, raw_ref, "", current_actor);
    try buf.appendSlice(allocator,
        \\        </article>
        \\      </div>
    );
    try appendIssueComments(&buf, allocator, &db, raw_ref, detail.id, current_actor, current_role);
    try appendIssueTimelineEvents(&buf, allocator, &db, detail.id);
    try appendIssueCommentForm(&buf, allocator, raw_ref, detail.state, current_actor, comment_error, comment_value);
    try buf.appendSlice(allocator, "    </div><aside class=\"issue-meta-sidebar\">");
    try appendIssueSidebar(&buf, allocator, &db, raw_ref, detail.id, display_author, detail.milestone, detail.body);
    try buf.appendSlice(allocator, "</aside></div></section>");
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn appendIssuePageHeader(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_ref: []const u8,
    issue_id: []const u8,
    title: []const u8,
    state: []const u8,
    author: []const u8,
    opened_at: []const u8,
    state_at: []const u8,
    comment_count: usize,
    legacy_number: i64,
    can_edit: bool,
) !void {
    try appendTemplate(buf, allocator,
        \\  <header class="issue-page-head">
        \\    <div class="issue-title-line">
        \\      <h1><span>{title}</span> <span class="issue-page-number">
    , .{ .title = title });
    try appendIssueDisplayRef(buf, allocator, issue_id, legacy_number);
    try appendTemplate(buf, allocator,
        \\</span></h1>
        \\      <div class="issue-page-actions">
    , .{});
    if (can_edit) {
        try buf.appendSlice(allocator, "        <a class=\"button secondary\" href=\"/issues/");
        try shared.appendUrlEncoded(buf, allocator, raw_ref);
        try buf.appendSlice(allocator, "/edit\">Edit</a>\n");
    } else {
        try buf.appendSlice(allocator, "        <button class=\"button secondary\" type=\"button\" disabled>Edit</button>\n");
    }
    try appendTemplate(buf, allocator,
        \\
        \\        <a class="button primary" href="/new-issue">New issue</a>
        \\        <button class="issue-copy-button" type="button" disabled aria-label="Copy issue link"><span class="button-icon icon-copy" aria-hidden="true"></span></button>
        \\      </div>
        \\    </div>
        \\    <div class="issue-status-line">
    , .{});
    try appendIssueStateBadge(buf, allocator, state);
    try appendTemplate(buf, allocator,
        \\      <span><strong>{author}</strong> opened this issue
    , .{
        .author = author,
    });
    try buf.append(allocator, ' ');
    try appendRelativeTime(buf, allocator, opened_at);
    if (std.mem.eql(u8, state, "closed")) {
        try buf.appendSlice(allocator, " and closed it ");
        try appendRelativeTime(buf, allocator, state_at);
    }
    try appendTemplate(buf, allocator,
        \\ · {comment_count} {comment_word}</span>
        \\    </div>
        \\  </header>
    , .{
        .comment_count = comment_count,
        .comment_word = commentWord(comment_count),
    });
}

fn appendIssueDisplayRef(buf: *std.ArrayList(u8), allocator: Allocator, issue_id: []const u8, legacy_number: i64) !void {
    try buf.append(allocator, '#');
    if (legacy_number > 0) {
        try std.fmt.format(buf.writer(allocator), "{d}", .{legacy_number});
        return;
    }

    var issue_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const issue_ref = util.shortObjectRef(&issue_ref_buf, issue_id);
    try shared.appendHtml(buf, allocator, issue_ref);
}

fn appendIssueStateBadge(buf: *std.ArrayList(u8), allocator: Allocator, state: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<span class="issue-state-badge is-{state}"><span class="issue-state-mark" aria-hidden="true"></span>{label}</span>
    , .{
        .state = state,
        .label = issueStateLabel(state),
    });
}

fn issueStateLabel(state: []const u8) []const u8 {
    if (std.mem.eql(u8, state, "open")) return "Open";
    if (std.mem.eql(u8, state, "closed")) return "Closed";
    return state;
}

fn commentWord(count: usize) []const u8 {
    return if (count == 1) "comment" else "comments";
}

fn renderIssueNotFound(allocator: Allocator, repo: Repo, raw_ref: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try appendShellStart(&buf, allocator, repo, "Issue Not Found", "issues");
    const detail = try std.fmt.allocPrint(allocator, "No issue matches {s}.", .{raw_ref});
    defer allocator.free(detail);
    try appendEmptyState(&buf, allocator, "Issue not found.", detail);
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

pub fn renderIssueEditPage(allocator: Allocator, repo: Repo, raw_ref: []const u8, target: []const u8) ![]u8 {
    const target_ref_owned = try queryValueOwned(allocator, target, "target");
    defer if (target_ref_owned) |value| allocator.free(value);
    const target_ref = if (target_ref_owned) |value| std.mem.trim(u8, value, " \t\r\n") else "issue";
    if (target_ref.len == 0 or std.mem.eql(u8, target_ref, "issue")) {
        return renderIssueEditIssuePage(allocator, repo, raw_ref, null, null, null);
    }
    return renderIssueEditCommentPage(allocator, repo, raw_ref, target_ref, null, null);
}

fn renderIssueEditIssuePage(
    allocator: Allocator,
    repo: Repo,
    raw_ref: []const u8,
    error_message: ?[]const u8,
    title_override: ?[]const u8,
    body_override: ?[]const u8,
) ![]u8 {
    try ensureIndex(allocator, repo);
    const issue_id = index.resolveIssueId(allocator, repo, raw_ref) catch {
        return renderIssueNotFound(allocator, repo, raw_ref);
    };
    defer allocator.free(issue_id);

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var stmt = try db.prepare("SELECT title, body, author_principal FROM issues WHERE id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    if (!(try stmt.step())) return renderIssueNotFound(allocator, repo, raw_ref);

    const title = try stmt.columnTextDup(allocator, 0);
    defer allocator.free(title);
    const body = try stmt.columnTextDup(allocator, 1);
    defer allocator.free(body);
    const author_principal = try stmt.columnTextDup(allocator, 2);
    defer allocator.free(author_principal);

    if (!(try currentActorCanEditInRepo(allocator, repo, author_principal))) {
        return renderIssueEditAccessDenied(allocator, repo, raw_ref, "Edit issue", "You do not have permission to edit this issue.");
    }

    return renderIssueEditIssueForm(
        allocator,
        repo,
        raw_ref,
        error_message,
        title_override orelse title,
        body_override orelse body,
    );
}

fn renderIssueEditIssueForm(
    allocator: Allocator,
    repo: Repo,
    raw_ref: []const u8,
    error_message: ?[]const u8,
    title_value: []const u8,
    body_value: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "Edit Issue", "issues");
    try buf.appendSlice(allocator, "<section class=\"panel form-panel\">");
    try appendSectionHead(&buf, allocator, "Issues", "Edit Issue", null);
    if (error_message) |message| {
        try appendTemplate(&buf, allocator, "<div class=\"flash error\">{message}</div>", .{ .message = message });
    }
    try buf.appendSlice(allocator, "<form method=\"post\" action=\"/issues/");
    try shared.appendUrlEncoded(&buf, allocator, raw_ref);
    try buf.appendSlice(allocator, "/edit\" class=\"issue-form\">");
    try appendTemplate(&buf, allocator,
        \\<input type="hidden" name="target_ref" value="issue">
        \\<label>Title<input name="title" value="{title_value}" autofocus required></label>
        \\<label>Body</label>
    , .{ .title_value = title_value });
    try shared.appendMarkdownEditor(&buf, allocator, .{
        .rows = 10,
        .placeholder = "Update issue description",
        .value = body_value,
        .required = false,
    });
    try buf.appendSlice(allocator, "<div class=\"form-actions\">");
    try appendIssueCancelLink(&buf, allocator, raw_ref, null);
    try buf.appendSlice(allocator, "<button class=\"button primary\" type=\"submit\">Save changes</button></div></form></section>");
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn renderIssueEditCommentPage(
    allocator: Allocator,
    repo: Repo,
    raw_ref: []const u8,
    target_ref: []const u8,
    error_message: ?[]const u8,
    body_override: ?[]const u8,
) ![]u8 {
    try ensureIndex(allocator, repo);
    const issue_id = index.resolveIssueId(allocator, repo, raw_ref) catch {
        return renderIssueNotFound(allocator, repo, raw_ref);
    };
    defer allocator.free(issue_id);
    const comment_id = index.resolveCommentId(allocator, repo, target_ref) catch {
        return renderIssueEditAccessDenied(allocator, repo, raw_ref, "Edit comment", "Comment not found.");
    };
    defer allocator.free(comment_id);
    var parent = try index.commentParentInfo(allocator, repo, comment_id);
    defer parent.deinit();
    if (!std.mem.eql(u8, parent.parent_kind, "issue") or !std.mem.eql(u8, parent.parent_id, issue_id)) {
        return renderIssueEditAccessDenied(allocator, repo, raw_ref, "Edit comment", "Comment is not in this issue.");
    }

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var stmt = try db.prepare("SELECT body, redacted, author_principal FROM comments WHERE id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, comment_id);
    if (!(try stmt.step())) return renderIssueEditAccessDenied(allocator, repo, raw_ref, "Edit comment", "Comment not found.");

    const body = try stmt.columnTextDup(allocator, 0);
    defer allocator.free(body);
    const redacted = stmt.columnInt(1) != 0;
    const author_principal = try stmt.columnTextDup(allocator, 2);
    defer allocator.free(author_principal);
    if (redacted or !(try currentActorCanEditInRepo(allocator, repo, author_principal))) {
        return renderIssueEditAccessDenied(allocator, repo, raw_ref, "Edit comment", "You do not have permission to edit this comment.");
    }

    var comment_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const comment_ref = util.shortObjectRef(&comment_ref_buf, comment_id);
    const comment_ref_value = try std.fmt.allocPrint(allocator, "comment:{s}", .{comment_ref});
    defer allocator.free(comment_ref_value);
    const anchor = try std.fmt.allocPrint(allocator, "comment-{s}", .{comment_ref});
    defer allocator.free(anchor);
    return renderIssueEditCommentForm(
        allocator,
        repo,
        raw_ref,
        comment_ref_value,
        anchor,
        error_message,
        body_override orelse body,
    );
}

fn renderIssueEditCommentForm(
    allocator: Allocator,
    repo: Repo,
    raw_ref: []const u8,
    target_ref: []const u8,
    anchor: []const u8,
    error_message: ?[]const u8,
    body_value: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "Edit Comment", "issues");
    try buf.appendSlice(allocator, "<section class=\"panel form-panel\">");
    try appendSectionHead(&buf, allocator, "Issues", "Edit Comment", null);
    if (error_message) |message| {
        try appendTemplate(&buf, allocator, "<div class=\"flash error\">{message}</div>", .{ .message = message });
    }
    try buf.appendSlice(allocator, "<form method=\"post\" action=\"/issues/");
    try shared.appendUrlEncoded(&buf, allocator, raw_ref);
    try buf.appendSlice(allocator, "/edit\" class=\"issue-form\">");
    try appendTemplate(&buf, allocator,
        \\<input type="hidden" name="target_ref" value="{target_ref}">
        \\<label>Comment</label>
    , .{ .target_ref = target_ref });
    try shared.appendMarkdownEditor(&buf, allocator, .{
        .rows = 10,
        .placeholder = "Update comment",
        .value = body_value,
        .required = false,
    });
    try buf.appendSlice(allocator, "<div class=\"form-actions\">");
    try appendIssueCancelLink(&buf, allocator, raw_ref, anchor);
    try buf.appendSlice(allocator, "<button class=\"button primary\" type=\"submit\">Save changes</button></div></form></section>");
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn renderIssueEditAccessDenied(allocator: Allocator, repo: Repo, raw_ref: []const u8, title: []const u8, message: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try appendShellStart(&buf, allocator, repo, title, "issues");
    try buf.appendSlice(allocator, "<section class=\"panel form-panel\">");
    try appendSectionHead(&buf, allocator, "Issues", title, null);
    try appendTemplate(&buf, allocator, "<div class=\"flash error\">{message}</div><div class=\"form-actions\">", .{ .message = message });
    try appendIssueCancelLink(&buf, allocator, raw_ref, null);
    try buf.appendSlice(allocator, "</div></section>");
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn appendIssueCancelLink(buf: *std.ArrayList(u8), allocator: Allocator, raw_ref: []const u8, anchor: ?[]const u8) !void {
    try buf.appendSlice(allocator, "<a class=\"button secondary\" href=\"/issues/");
    try shared.appendUrlEncoded(buf, allocator, raw_ref);
    if (anchor) |value| {
        try buf.append(allocator, '#');
        try shared.appendHtml(buf, allocator, value);
    }
    try buf.appendSlice(allocator, "\">Cancel</a>");
}

fn currentActorCanEditInRepo(allocator: Allocator, repo: Repo, author: []const u8) !bool {
    const current_actor = try shared.currentPrincipalOwned(allocator, repo);
    defer if (current_actor) |actor| allocator.free(actor);
    const current_role = if (current_actor) |actor| try index.effectiveWriteRoleForPrincipal(allocator, repo, actor) else null;
    defer if (current_role) |role| allocator.free(role);
    return currentActorCanEditAuthor(current_actor, current_role, author);
}

fn appendLegacyIssueLink(buf: *std.ArrayList(u8), allocator: Allocator, legacy_number: i64) !void {
    const issue_ref = try std.fmt.allocPrint(allocator, "{d}", .{legacy_number});
    defer allocator.free(issue_ref);
    try shared.appendIssueReferenceLink(buf, allocator, issue_ref);
}

fn appendIssueComments(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    raw_ref: []const u8,
    issue_id: []const u8,
    current_actor: ?[]const u8,
    current_role: ?[]const u8,
) !void {
    var stmt = try work_items.prepareCommentsStmt(db, "issue", issue_id);
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
        const can_edit_comment = !row.redacted and currentActorCanEditAuthor(current_actor, current_role, row.author_principal);
        const comment_edit_href = if (can_edit_comment) try issueEditHrefOwned(allocator, raw_ref, comment_ref_value) else "";
        defer if (can_edit_comment) allocator.free(comment_edit_href);

        try appendTemplate(buf, allocator,
            \\<div class="{classes}" id="{anchor}"><div class="issue-timeline-avatar">
        , .{
            .classes = shared.classes("issue-timeline-item", &.{shared.class("is-reply", row.isReply())}),
            .anchor = anchor,
        });
        try appendIssueAvatar(buf, allocator, row.display_author, "issue-detail-avatar");
        try appendTemplate(buf, allocator,
            \\</div><article class="issue-comment-box"><header class="issue-comment-head"><div><strong>{author}</strong><span>commented
        , .{
            .author = row.display_author,
        });
        try buf.append(allocator, ' ');
        try appendRelativeTime(buf, allocator, row.created_at);
        try buf.appendSlice(allocator, "</span></div>");
        try appendIssueActionMenu(buf, allocator, anchor, comment_ref_value, row.body, !row.redacted and row.body.len != 0, comment_edit_href);
        try buf.appendSlice(allocator, "</header>");
        if (row.isReply()) {
            try buf.appendSlice(allocator, "<p class=\"reply-note\">Reply to ");
            if (row.reply_parent_id.len != 0) {
                try appendTemplate(buf, allocator, "#{reply_parent_id}", .{
                    .reply_parent_id = row.reply_parent_id[0..@min(row.reply_parent_id.len, 7)],
                });
            } else {
                try appendTemplate(buf, allocator, "{reply_parent_hash}", .{
                    .reply_parent_hash = row.reply_parent_hash[0..@min(row.reply_parent_hash.len, 12)],
                });
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
        try appendReactionBar(buf, allocator, db, "comment", row.id, raw_ref, comment_ref_value, current_actor);
        try buf.appendSlice(allocator, "</article></div>");
    }
}

fn appendIssueTimelineEvents(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    issue_id: []const u8,
) !void {
    var stmt = try work_items.prepareTimelineStmt(db, "issue", issue_id);
    defer stmt.deinit();

    while (try stmt.step()) {
        const row = try work_items.timelineEventFromStmt(allocator, &stmt);
        defer row.deinit(allocator);
        try appendIssueTimelineEvent(buf, allocator, row.event_type, row.actor_principal, row.occurred_at, row.body, row.event_hash);
    }
}

fn appendIssueTimelineEvent(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    event_type: []const u8,
    actor: []const u8,
    occurred_at: []const u8,
    body: []const u8,
    event_hash: []const u8,
) !void {
    const anchor = event_hash[0..@min(event_hash.len, 12)];
    try appendTemplate(buf, allocator,
        \\<div class="issue-timeline-item issue-event-item" id="event-{anchor}">
        \\  <div class="issue-timeline-avatar"><span class="issue-event-icon {icon_class}" aria-hidden="true"></span></div>
        \\  <div class="issue-event-content"><strong>{actor}</strong>
    , .{
        .anchor = anchor,
        .icon_class = issueTimelineEventIcon(event_type, body),
        .actor = actor,
    });
    try buf.append(allocator, ' ');
    try appendIssueTimelineEventMessage(buf, allocator, event_type, body);
    try buf.append(allocator, ' ');
    try appendRelativeTime(buf, allocator, occurred_at);
    try buf.appendSlice(allocator, "</div></div>");
}

fn issueTimelineEventIcon(event_type: []const u8, body: []const u8) []const u8 {
    if (std.mem.eql(u8, event_type, "issue.state_set")) {
        if (issueEventPayloadStringEquals(body, "state", "closed")) return "is-closed";
        if (issueEventPayloadStringEquals(body, "state", "open")) return "is-open";
        return "is-state";
    }
    if (std.mem.eql(u8, event_type, "issue.updated")) {
        if (issueEventPayloadStringEquals(body, "state", "closed")) return "is-closed";
        if (issueEventPayloadStringEquals(body, "state", "open")) return "is-open";
        return "is-edit";
    }
    if (std.mem.indexOf(u8, event_type, "label") != null) return "is-label";
    if (std.mem.indexOf(u8, event_type, "assignee") != null) return "is-assignee";
    if (std.mem.indexOf(u8, event_type, "milestone") != null) return "is-milestone";
    if (std.mem.indexOf(u8, event_type, "project") != null) return "is-project";
    return "is-edit";
}

fn appendIssueTimelineEventMessage(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    event_type: []const u8,
    body: []const u8,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        try appendTemplate(buf, allocator, "recorded <code>{event_type}</code>", .{ .event_type = event_type });
        return;
    };
    defer parsed.deinit();
    const payload = issueEventPayload(parsed.value) orelse {
        try appendTemplate(buf, allocator, "recorded <code>{event_type}</code>", .{ .event_type = event_type });
        return;
    };

    if (std.mem.eql(u8, event_type, "issue.title_set")) {
        try buf.appendSlice(allocator, "changed the title");
    } else if (std.mem.eql(u8, event_type, "issue.body_set")) {
        try buf.appendSlice(allocator, "edited the description");
    } else if (std.mem.eql(u8, event_type, "issue.state_set")) {
        try appendIssueStateTimelineMessage(buf, allocator, event_mod.jsonString(payload.get("state")) orelse "");
    } else if (std.mem.eql(u8, event_type, "issue.label_added")) {
        try buf.appendSlice(allocator, "added ");
        try appendIssueLabel(buf, allocator, event_mod.jsonString(payload.get("label")) orelse "label");
    } else if (std.mem.eql(u8, event_type, "issue.label_removed")) {
        try buf.appendSlice(allocator, "removed ");
        try appendIssueLabel(buf, allocator, event_mod.jsonString(payload.get("label")) orelse "label");
    } else if (std.mem.eql(u8, event_type, "issue.assignee_added")) {
        try appendTemplate(buf, allocator, "assigned <span class=\"issue-event-value\">{assignee}</span>", .{
            .assignee = event_mod.jsonString(payload.get("assignee")) orelse "someone",
        });
    } else if (std.mem.eql(u8, event_type, "issue.assignee_removed")) {
        try appendTemplate(buf, allocator, "unassigned <span class=\"issue-event-value\">{assignee}</span>", .{
            .assignee = event_mod.jsonString(payload.get("assignee")) orelse "someone",
        });
    } else if (std.mem.eql(u8, event_type, "issue.milestone_set")) {
        try appendIssueMilestoneTimelineMessage(buf, allocator, event_mod.jsonString(payload.get("milestone")) orelse "");
    } else if (std.mem.eql(u8, event_type, "issue.project_added")) {
        try appendIssueProjectTimelineMessage(buf, allocator, "added this to", .{
            .project = event_mod.jsonString(payload.get("project")) orelse "project",
            .column = event_mod.jsonString(payload.get("column")) orelse "",
        });
    } else if (std.mem.eql(u8, event_type, "issue.project_removed")) {
        try appendIssueProjectTimelineMessage(buf, allocator, "removed this from", .{
            .project = event_mod.jsonString(payload.get("project")) orelse "project",
            .column = event_mod.jsonString(payload.get("column")) orelse "",
        });
    } else if (std.mem.eql(u8, event_type, "issue.updated")) {
        try appendIssueUpdatedTimelineMessage(buf, allocator, payload);
    } else {
        try appendTemplate(buf, allocator, "recorded <code>{event_type}</code>", .{ .event_type = event_type });
    }
}

fn issueEventPayload(value: std.json.Value) ?std.json.ObjectMap {
    const root = switch (value) {
        .object => |object| object,
        else => return null,
    };
    const payload_value = root.get("payload") orelse return null;
    return switch (payload_value) {
        .object => |object| object,
        else => null,
    };
}

fn issueEventPayloadStringEquals(body: []const u8, key: []const u8, expected: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, body, .{}) catch return false;
    defer parsed.deinit();
    const payload = issueEventPayload(parsed.value) orelse return false;
    const value = event_mod.jsonString(payload.get(key)) orelse return false;
    return std.mem.eql(u8, value, expected);
}

fn appendIssueStateTimelineMessage(buf: *std.ArrayList(u8), allocator: Allocator, state: []const u8) !void {
    if (std.mem.eql(u8, state, "closed")) {
        try buf.appendSlice(allocator, "closed this as completed");
    } else if (std.mem.eql(u8, state, "open")) {
        try buf.appendSlice(allocator, "reopened this");
    } else {
        try appendTemplate(buf, allocator, "changed state to <span class=\"issue-event-value\">{state}</span>", .{ .state = state });
    }
}

fn appendIssueMilestoneTimelineMessage(buf: *std.ArrayList(u8), allocator: Allocator, milestone: []const u8) !void {
    if (milestone.len == 0) {
        try buf.appendSlice(allocator, "cleared the milestone");
    } else {
        try appendTemplate(buf, allocator, "set milestone to <span class=\"issue-sidebar-pill\">{milestone}</span>", .{ .milestone = milestone });
    }
}

fn appendIssueProjectTimelineMessage(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    verb: []const u8,
    project: IssueProjectSummary,
) !void {
    try appendTemplate(buf, allocator, "{verb} <span class=\"issue-sidebar-pill\">{project}", .{
        .verb = verb,
        .project = project.project,
    });
    if (project.column.len != 0) {
        try appendTemplate(buf, allocator, " / {column}", .{ .column = project.column });
    }
    try buf.appendSlice(allocator, "</span>");
}

fn appendIssueUpdatedTimelineMessage(buf: *std.ArrayList(u8), allocator: Allocator, payload: std.json.ObjectMap) !void {
    if (event_mod.jsonString(payload.get("state"))) |state| {
        try appendIssueStateTimelineMessage(buf, allocator, state);
    } else if (event_mod.jsonString(payload.get("milestone"))) |milestone| {
        try appendIssueMilestoneTimelineMessage(buf, allocator, milestone);
    } else if (firstStringFromJsonArray(payload, "labels_added")) |label| {
        try buf.appendSlice(allocator, "added ");
        try appendIssueLabel(buf, allocator, label);
    } else if (firstStringFromJsonArray(payload, "labels_removed")) |label| {
        try buf.appendSlice(allocator, "removed ");
        try appendIssueLabel(buf, allocator, label);
    } else if (firstStringFromJsonArray(payload, "assignees_added")) |assignee| {
        try appendTemplate(buf, allocator, "assigned <span class=\"issue-event-value\">{assignee}</span>", .{ .assignee = assignee });
    } else if (firstStringFromJsonArray(payload, "assignees_removed")) |assignee| {
        try appendTemplate(buf, allocator, "unassigned <span class=\"issue-event-value\">{assignee}</span>", .{ .assignee = assignee });
    } else if (firstProjectFromJsonArray(payload, "projects")) |project| {
        try appendIssueProjectTimelineMessage(buf, allocator, "added this to", project);
    } else if (payload.get("title") != null) {
        try buf.appendSlice(allocator, "changed the title");
    } else if (payload.get("body") != null) {
        try buf.appendSlice(allocator, "edited the description");
    } else {
        try buf.appendSlice(allocator, "updated this issue");
    }
}

fn firstStringFromJsonArray(payload: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = payload.get(key) orelse return null;
    const array = switch (value) {
        .array => |items| items,
        else => return null,
    };
    for (array.items) |item| {
        if (item == .string) return item.string;
    }
    return null;
}

fn firstProjectFromJsonArray(payload: std.json.ObjectMap, key: []const u8) ?IssueProjectSummary {
    const value = payload.get(key) orelse return null;
    const array = switch (value) {
        .array => |items| items,
        else => return null,
    };
    for (array.items) |item| {
        const object = switch (item) {
            .object => |project| project,
            else => continue,
        };
        return .{
            .project = event_mod.jsonString(object.get("project")) orelse "project",
            .column = event_mod.jsonString(object.get("column")) orelse "",
        };
    }
    return null;
}

fn appendReactionBar(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    object_kind: []const u8,
    object_id: []const u8,
    raw_issue_ref: []const u8,
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

    try appendReactionPicker(buf, allocator, raw_issue_ref, object_kind, target_ref, reactions.items);
    for (reactions.items) |item| {
        try appendReactionButton(buf, allocator, raw_issue_ref, object_kind, target_ref, item.emoji, item.emoji, item.count, item.reacted);
    }
    try buf.appendSlice(allocator, "</div>");
}

fn appendReactionPicker(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_issue_ref: []const u8,
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
        try appendReactionChoiceButton(buf, allocator, raw_issue_ref, object_kind, target_ref, choice, reactionWasSelected(reactions, choice.value));
    }
    try buf.appendSlice(allocator, "</div></details>");
}

fn appendReactionChoiceButton(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_issue_ref: []const u8,
    object_kind: []const u8,
    target_ref: []const u8,
    choice: ReactionChoice,
    reacted: bool,
) !void {
    try appendReactionFormOpen(buf, allocator, raw_issue_ref, "reaction-choice-form", if (reacted) "remove-reaction" else "add-reaction", object_kind, target_ref, choice.value);
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

fn appendReactionButton(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_issue_ref: []const u8,
    object_kind: []const u8,
    target_ref: []const u8,
    emoji_value: []const u8,
    emoji_label: []const u8,
    count: i64,
    reacted: bool,
) !void {
    try appendReactionFormOpen(buf, allocator, raw_issue_ref, "reaction-form", if (reacted) "remove-reaction" else "add-reaction", object_kind, target_ref, emoji_value);
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

fn appendReactionFormOpen(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_issue_ref: []const u8,
    form_class: []const u8,
    action: []const u8,
    object_kind: []const u8,
    target_ref: []const u8,
    emoji_value: []const u8,
) !void {
    try appendTemplate(buf, allocator, "<form class=\"{form_class}\" method=\"post\" action=\"/issues/", .{ .form_class = form_class });
    try shared.appendUrlEncoded(buf, allocator, raw_issue_ref);
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

fn reactionWasSelected(reactions: []const ReactionSummary, emoji: []const u8) bool {
    for (reactions) |item| {
        if (std.mem.eql(u8, item.emoji, emoji)) return item.reacted;
    }
    return false;
}

pub fn appendIssueActionMenu(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    anchor: []const u8,
    reply_ref: []const u8,
    markdown: []const u8,
    markdown_available: bool,
    edit_href: []const u8,
) !void {
    try appendTemplate(buf, allocator,
        \\<details class="issue-action-menu" data-popover-menu data-issue-menu data-issue-anchor="{anchor}" data-issue-reply-ref="{reply_ref}" data-issue-edit-href="{edit_href}">
        \\  <summary class="issue-kebab-button" aria-label="Comment actions" title="Comment actions"></summary>
        \\  <template data-issue-markdown>{markdown}</template>
        \\  <div class="issue-action-popover" role="menu">
    , .{
        .anchor = anchor,
        .reply_ref = reply_ref,
        .edit_href = edit_href,
        .markdown = markdown,
    });
    try appendIssueActionMenuItem(buf, allocator, "copy-link", "issue-menu-icon-link", "Copy link", false);
    try appendIssueActionMenuItem(buf, allocator, "copy-markdown", "issue-menu-icon-markdown", "Copy Markdown", !markdown_available);
    try appendIssueActionMenuItem(buf, allocator, "quote-reply", "issue-menu-icon-quote", "Quote reply", !markdown_available);
    try buf.appendSlice(allocator, "<div class=\"issue-action-divider\" role=\"separator\"></div>");
    try appendIssueActionMenuItem(buf, allocator, "edit", "issue-menu-icon-edit", "Edit", edit_href.len == 0);
    try buf.appendSlice(allocator, "</div></details>");
}

fn currentActorCanEditAuthor(current_actor: ?[]const u8, current_role: ?[]const u8, author: []const u8) bool {
    const role = current_role orelse return false;
    if (event_mod.roleAtLeast(role, "maintainer")) return true;
    const actor = current_actor orelse return false;
    return event_mod.roleAtLeast(role, "contributor") and std.mem.eql(u8, actor, author);
}

fn issueEditHrefOwned(allocator: Allocator, raw_ref: []const u8, target_ref: ?[]const u8) ![]u8 {
    var href: std.ArrayList(u8) = .empty;
    errdefer href.deinit(allocator);
    try href.appendSlice(allocator, "/issues/");
    try shared.appendUrlEncoded(&href, allocator, raw_ref);
    try href.appendSlice(allocator, "/edit");
    if (target_ref) |target| {
        try href.appendSlice(allocator, "?target=");
        try shared.appendUrlEncoded(&href, allocator, target);
    }
    return href.toOwnedSlice(allocator);
}

fn appendIssueActionMenuItem(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    action: []const u8,
    icon_class: []const u8,
    label: []const u8,
    disabled: bool,
) !void {
    try appendTemplate(buf, allocator,
        \\<button type="button" role="menuitem" data-issue-action="{action}"
    , .{ .action = action });
    if (disabled) try buf.appendSlice(allocator, " disabled");
    try appendTemplate(buf, allocator,
        \\><span class="issue-menu-icon {icon_class}" aria-hidden="true"></span><span data-issue-menu-label>{label}</span></button>
    , .{
        .icon_class = icon_class,
        .label = label,
    });
}

fn appendIssueCommentForm(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_ref: []const u8,
    state: []const u8,
    current_actor: ?[]const u8,
    error_message: ?[]const u8,
    body_value: []const u8,
) !void {
    try buf.appendSlice(allocator,
        \\<div class="issue-timeline-item issue-comment-form-item">
    );
    try buf.appendSlice(allocator, "  <div class=\"issue-timeline-avatar\">");
    try appendIssueAvatar(buf, allocator, current_actor orelse "Current user", "issue-detail-avatar issue-comment-form-avatar");
    try buf.appendSlice(allocator, "</div>");
    try buf.appendSlice(allocator,
        \\  <form class="issue-comment-box issue-comment-form" method="post" action="/issues/
    );
    try shared.appendUrlEncoded(buf, allocator, raw_ref);
    try appendTemplate(buf, allocator,
        \\/comments">
        \\    <input type="hidden" name="reply_parent_ref" value="" data-reply-parent-ref>
    , .{});
    try shared.appendMarkdownEditor(buf, allocator, .{ .value = body_value });
    if (error_message) |message| {
        try appendTemplate(buf, allocator,
            \\    <p class="issue-comment-error">{message}</p>
        , .{ .message = message });
    }
    const state_action = if (std.mem.eql(u8, state, "closed")) "reopen-issue" else "close-issue";
    const state_label = if (std.mem.eql(u8, state, "closed")) "Reopen issue" else "Close issue";
    const state_class = if (std.mem.eql(u8, state, "closed")) "primary is-reopen" else "secondary is-close";
    try buf.appendSlice(allocator,
        \\    <div class="issue-comment-form-actions">
        \\      <button class="button secondary" type="submit" name="action" value="comment">Comment</button>
    );
    try appendTemplate(buf, allocator,
        \\      <button class="button {state_class} issue-state-submit" type="submit" name="action" value="{state_action}" formnovalidate>{state_label}</button>
    , .{
        .state_class = state_class,
        .state_action = state_action,
        .state_label = state_label,
    });
    try buf.appendSlice(allocator,
        \\    </div>
        \\  </form>
        \\</div>
    );
}

fn appendIssueSidebar(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    raw_ref: []const u8,
    issue_id: []const u8,
    author: []const u8,
    milestone: []const u8,
    body: []const u8,
) !void {
    try appendIssueSidebarAssignees(buf, allocator, db, raw_ref, issue_id);
    try appendIssueSidebarLabels(buf, allocator, db, raw_ref, issue_id);
    try appendIssueSidebarType(buf, allocator);
    try appendIssueSidebarProjects(buf, allocator, db, raw_ref, issue_id);
    try appendIssueSidebarMilestone(buf, allocator, db, raw_ref, milestone);
    try appendIssueSidebarRelationships(buf, allocator, db, issue_id, body);
    try appendIssueSidebarDevelopment(buf, allocator, db, issue_id);
    try appendIssueSidebarNotifications(buf, allocator);
    try appendIssueSidebarParticipants(buf, allocator, db, issue_id, author);
}

fn appendIssueSidebarAssignees(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, raw_ref: []const u8, issue_id: []const u8) !void {
    try appendIssueSidebarEditableSectionStart(buf, allocator, "Assignees", "Add assignees");
    try appendIssueSidebarAssigneeMenu(buf, allocator, db, raw_ref, issue_id);
    try appendIssueSidebarEditableSectionBodyStart(buf, allocator);
    var stmt = try db.prepare("SELECT DISTINCT assignee FROM issue_assignees WHERE issue_id = ? ORDER BY assignee");
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    var shown = false;
    while (try stmt.step()) {
        const assignee = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(assignee);
        try appendIssueSidebarPerson(buf, allocator, assignee);
        shown = true;
    }
    if (!shown) try buf.appendSlice(allocator, "<p class=\"issue-sidebar-empty\">No one assigned</p>");
    try appendIssueSidebarSectionEnd(buf, allocator);
}

fn appendIssueSidebarLabels(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, raw_ref: []const u8, issue_id: []const u8) !void {
    try appendIssueSidebarEditableSectionStart(buf, allocator, "Labels", "Apply labels to this issue");
    try appendIssueSidebarLabelsMenu(buf, allocator, db, raw_ref, issue_id);
    try appendIssueSidebarEditableSectionBodyStart(buf, allocator);
    var stmt = try db.prepare("SELECT DISTINCT label FROM issue_labels WHERE issue_id = ? ORDER BY label");
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    var shown = false;
    while (try stmt.step()) {
        const label = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(label);
        if (!shown) {
            try buf.appendSlice(allocator, "<div class=\"issue-sidebar-labels\">");
            shown = true;
        }
        try appendIssueSidebarLabel(buf, allocator, label);
    }
    if (shown) {
        try buf.appendSlice(allocator, "</div>");
    } else {
        try buf.appendSlice(allocator, "<p class=\"issue-sidebar-empty\">None yet</p>");
    }
    try appendIssueSidebarSectionEnd(buf, allocator);
}

fn appendIssueSidebarType(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try appendIssueSidebarEditableSectionStart(buf, allocator, "Type", "Select issue type");
    try appendIssueSidebarMenuFilter(buf, allocator, "Filter types");
    try appendIssueSidebarMenuGroupStart(buf, allocator, "Available types");
    try appendIssueSidebarTypeOption(buf, allocator, "Bug", "An unexpected problem or behavior", "bug");
    try appendIssueSidebarTypeOption(buf, allocator, "Feature", "A request, idea, or new functionality", "feature");
    try appendIssueSidebarTypeOption(buf, allocator, "Task", "A specific piece of work", "task");
    try appendIssueSidebarMenuGroupEnd(buf, allocator);
    try appendIssueSidebarEditableSectionBodyStart(buf, allocator);
    try buf.appendSlice(allocator, "<p class=\"issue-sidebar-empty\">No type</p>");
    try appendIssueSidebarSectionEnd(buf, allocator);
}

fn appendIssueSidebarProjects(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, raw_ref: []const u8, issue_id: []const u8) !void {
    try appendIssueSidebarEditableSectionStart(buf, allocator, "Projects", "Select projects");
    try appendIssueSidebarProjectsMenu(buf, allocator, db, raw_ref, issue_id);
    try appendIssueSidebarEditableSectionBodyStart(buf, allocator);
    var stmt = try db.prepare(
        \\SELECT DISTINCT project, column_name
        \\FROM issue_projects
        \\WHERE issue_id = ?
        \\ORDER BY project, column_name
    );
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    var shown = false;
    while (try stmt.step()) {
        const project = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(project);
        const column = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(column);
        try buf.appendSlice(allocator, "<span class=\"issue-sidebar-token issue-sidebar-project-token\"><span class=\"issue-sidebar-pill\">");
        try appendTemplate(buf, allocator, "{project}", .{ .project = project });
        if (column.len != 0) try appendTemplate(buf, allocator, " / {column}", .{ .column = column });
        try buf.appendSlice(allocator, "</span></span>");
        shown = true;
    }
    if (!shown) try buf.appendSlice(allocator, "<p class=\"issue-sidebar-empty\">No projects</p>");
    try appendIssueSidebarSectionEnd(buf, allocator);
}

fn appendIssueSidebarMilestone(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, raw_ref: []const u8, milestone: []const u8) !void {
    try appendIssueSidebarEditableSectionStart(buf, allocator, "Milestone", "Set milestone");
    try appendIssueSidebarMilestoneMenu(buf, allocator, db, raw_ref, milestone);
    try appendIssueSidebarEditableSectionBodyStart(buf, allocator);
    if (milestone.len == 0) {
        try buf.appendSlice(allocator, "<p class=\"issue-sidebar-empty\">No milestone</p>");
    } else {
        try buf.appendSlice(allocator, "<span class=\"issue-sidebar-token\"><span class=\"issue-sidebar-pill\">");
        try shared.appendHtml(buf, allocator, milestone);
        try buf.appendSlice(allocator, "</span></span>");
    }
    try appendIssueSidebarSectionEnd(buf, allocator);
}

fn appendIssueSidebarRelationships(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, issue_id: []const u8, body: []const u8) !void {
    try appendIssueSidebarEditableSectionStart(buf, allocator, "Relationships", "Add relationship");
    try appendIssueSidebarRelationshipsMenu(buf, allocator);
    try appendIssueSidebarEditableSectionBodyStart(buf, allocator);
    var relationships: std.ArrayList(RelationshipItem) = .empty;
    defer {
        for (relationships.items) |*item| item.deinit();
        relationships.deinit(allocator);
    }
    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var keys = seen.keyIterator();
        while (keys.next()) |key| allocator.free(key.*);
        seen.deinit();
    }
    try collectRelationshipDirectivesFromText(allocator, db, issue_id, body, &seen, &relationships);

    var stmt = try db.prepare(
        \\SELECT body
        \\FROM comments
        \\WHERE parent_kind = 'issue'
        \\  AND parent_id = ?
        \\  AND redacted = 0
        \\ORDER BY created_at, id
    );
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    while (try stmt.step()) {
        const comment_body = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(comment_body);
        try collectRelationshipDirectivesFromText(allocator, db, issue_id, comment_body, &seen, &relationships);
    }

    if (relationships.items.len == 0) {
        try buf.appendSlice(allocator, "<p class=\"issue-sidebar-empty\">None yet</p>");
    } else {
        try appendRelationshipGroups(buf, allocator, relationships.items);
    }
    try appendIssueSidebarSectionEnd(buf, allocator);
}

fn appendIssueSidebarDevelopment(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, issue_id: []const u8) !void {
    try appendIssueSidebarEditableSectionStart(buf, allocator, "Development", "Link development");
    try appendIssueSidebarDevelopmentMenu(buf, allocator, db);
    try appendIssueSidebarEditableSectionBodyStart(buf, allocator);
    var stmt = try db.prepare(
        \\SELECT commit_oid
        \\FROM commit_references
        \\WHERE object_kind = 'issue' AND object_id = ?
        \\ORDER BY commit_oid
        \\LIMIT 8
    );
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    var shown = false;
    while (try stmt.step()) {
        const commit_oid = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(commit_oid);
        try appendTemplate(buf, allocator,
            \\<a class="issue-sidebar-link-row" href="{href}"><span class="issue-sidebar-row-kind">commit</span><code>{short_oid}</code></a>
        , .{
            .href = commitHref(commit_oid),
            .short_oid = commit_oid[0..@min(commit_oid.len, 12)],
        });
        shown = true;
    }
    if (!shown) try buf.appendSlice(allocator, "<p class=\"issue-sidebar-empty\">No linked branches or pull requests.</p>");
    try appendIssueSidebarSectionEnd(buf, allocator);
}

fn appendIssueSidebarParticipants(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, issue_id: []const u8, author: []const u8) !void {
    try appendIssueSidebarSectionStart(buf, allocator, "Participants");
    try buf.appendSlice(allocator, "<div class=\"issue-participants\">");
    try appendIssueAvatar(buf, allocator, author, "");
    var stmt = try db.prepare("SELECT DISTINCT assignee FROM issue_assignees WHERE issue_id = ? AND assignee <> ? ORDER BY assignee");
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    try stmt.bindText(2, author);
    while (try stmt.step()) {
        const assignee = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(assignee);
        try appendIssueAvatar(buf, allocator, assignee, "");
    }
    try buf.appendSlice(allocator, "</div>");
    try appendIssueSidebarSectionEnd(buf, allocator);
}

fn appendIssueSidebarNotifications(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try appendIssueSidebarSectionStart(buf, allocator, "Notifications");
    try buf.appendSlice(allocator,
        \\<button class="button secondary issue-sidebar-full-button" type="button" disabled>Subscribe</button>
    );
    try appendIssueSidebarSectionEnd(buf, allocator);
}

fn appendIssueSidebarAssigneeMenu(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, raw_ref: []const u8, issue_id: []const u8) !void {
    try appendIssueSidebarSingleInputForm(buf, allocator, raw_ref, "add-assignee", "value", "Add assignee", "Filter assignees");
    try appendIssueSidebarMenuGroupStart(buf, allocator, "Assigned");
    var selected = try db.prepare("SELECT DISTINCT assignee FROM issue_assignees WHERE issue_id = ? ORDER BY lower(assignee), assignee");
    defer selected.deinit();
    try selected.bindText(1, issue_id);
    var shown = false;
    while (try selected.step()) {
        const assignee = try selected.columnTextDup(allocator, 0);
        defer allocator.free(assignee);
        try appendIssueSidebarAssigneeActionRow(buf, allocator, raw_ref, "remove-assignee", assignee, true);
        shown = true;
    }
    if (!shown) try appendIssueSidebarMenuEmpty(buf, allocator, "No assignees selected.");
    try appendIssueSidebarMenuGroupEnd(buf, allocator);

    try appendIssueSidebarMenuGroupStart(buf, allocator, "Suggestions");
    var suggestions = try db.prepare(
        \\SELECT DISTINCT assignee
        \\FROM (
        \\  SELECT assignee AS assignee FROM issue_assignees
        \\  UNION
        \\  SELECT COALESCE(NULLIF(m.source_author, ''), i.author_principal) AS assignee
        \\  FROM issues i
        \\  LEFT JOIN issue_metadata m ON m.issue_id = i.id
        \\)
        \\WHERE assignee <> ''
        \\  AND assignee NOT IN (SELECT assignee FROM issue_assignees WHERE issue_id = ?)
        \\ORDER BY lower(assignee), assignee
        \\LIMIT 20
    );
    defer suggestions.deinit();
    try suggestions.bindText(1, issue_id);
    shown = false;
    while (try suggestions.step()) {
        const assignee = try suggestions.columnTextDup(allocator, 0);
        defer allocator.free(assignee);
        try appendIssueSidebarAssigneeActionRow(buf, allocator, raw_ref, "add-assignee", assignee, false);
        shown = true;
    }
    if (!shown) try appendIssueSidebarMenuEmpty(buf, allocator, "No assignee suggestions.");
    try appendIssueSidebarMenuGroupEnd(buf, allocator);
}

fn appendIssueSidebarLabelsMenu(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, raw_ref: []const u8, issue_id: []const u8) !void {
    try appendIssueSidebarSingleInputForm(buf, allocator, raw_ref, "add-label", "value", "Add label", "Filter labels");
    try appendIssueSidebarMenuGroupStart(buf, allocator, "Selected labels");
    var selected = try db.prepare("SELECT DISTINCT label FROM issue_labels WHERE issue_id = ? ORDER BY lower(label), label");
    defer selected.deinit();
    try selected.bindText(1, issue_id);
    var shown = false;
    while (try selected.step()) {
        const label = try selected.columnTextDup(allocator, 0);
        defer allocator.free(label);
        try appendIssueSidebarLabelActionRow(buf, allocator, raw_ref, "remove-label", label, true);
        shown = true;
    }
    if (!shown) try appendIssueSidebarMenuEmpty(buf, allocator, "No labels selected.");
    try appendIssueSidebarMenuGroupEnd(buf, allocator);

    try appendIssueSidebarMenuGroupStart(buf, allocator, "Suggestions");
    var suggestions = try db.prepare(
        \\SELECT DISTINCT label
        \\FROM issue_labels
        \\WHERE label NOT IN (SELECT label FROM issue_labels WHERE issue_id = ?)
        \\ORDER BY lower(label), label
        \\LIMIT 24
    );
    defer suggestions.deinit();
    try suggestions.bindText(1, issue_id);
    shown = false;
    while (try suggestions.step()) {
        const label = try suggestions.columnTextDup(allocator, 0);
        defer allocator.free(label);
        try appendIssueSidebarLabelActionRow(buf, allocator, raw_ref, "add-label", label, false);
        shown = true;
    }
    if (!shown) try appendIssueSidebarMenuEmpty(buf, allocator, "No label suggestions.");
    try appendIssueSidebarMenuGroupEnd(buf, allocator);
}

fn appendIssueSidebarProjectsMenu(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, raw_ref: []const u8, issue_id: []const u8) !void {
    try appendIssueSidebarProjectForm(buf, allocator, raw_ref);
    try appendIssueSidebarMenuGroupStart(buf, allocator, "Selected projects");
    var selected = try db.prepare(
        \\SELECT DISTINCT project, column_name
        \\FROM issue_projects
        \\WHERE issue_id = ?
        \\ORDER BY lower(project), lower(column_name), project, column_name
    );
    defer selected.deinit();
    try selected.bindText(1, issue_id);
    var shown = false;
    while (try selected.step()) {
        const project = try selected.columnTextDup(allocator, 0);
        defer allocator.free(project);
        const column = try selected.columnTextDup(allocator, 1);
        defer allocator.free(column);
        try appendIssueSidebarProjectActionRow(buf, allocator, raw_ref, "remove-project", project, column, true);
        shown = true;
    }
    if (!shown) try appendIssueSidebarMenuEmpty(buf, allocator, "No projects selected.");
    try appendIssueSidebarMenuGroupEnd(buf, allocator);

    try appendIssueSidebarMenuGroupStart(buf, allocator, "Suggestions");
    var suggestions = try db.prepare(
        \\SELECT DISTINCT candidate.project, candidate.column_name
        \\FROM (
        \\  SELECT p.name AS project, pc.column_name AS column_name
        \\  FROM projects p
        \\  JOIN project_columns pc ON pc.project_id = p.id
        \\  WHERE p.state <> 'closed'
        \\  UNION
        \\  SELECT project, column_name FROM issue_projects
        \\) AS candidate
        \\WHERE candidate.project <> ''
        \\  AND candidate.column_name <> ''
        \\  AND NOT EXISTS (
        \\    SELECT 1 FROM issue_projects ip
        \\    WHERE ip.issue_id = ?
        \\      AND ip.project = candidate.project
        \\      AND ip.column_name = candidate.column_name
        \\  )
        \\ORDER BY lower(candidate.project), lower(candidate.column_name), candidate.project, candidate.column_name
        \\LIMIT 20
    );
    defer suggestions.deinit();
    try suggestions.bindText(1, issue_id);
    shown = false;
    while (try suggestions.step()) {
        const project = try suggestions.columnTextDup(allocator, 0);
        defer allocator.free(project);
        const column = try suggestions.columnTextDup(allocator, 1);
        defer allocator.free(column);
        try appendIssueSidebarProjectActionRow(buf, allocator, raw_ref, "add-project", project, column, false);
        shown = true;
    }
    if (!shown) try appendIssueSidebarMenuEmpty(buf, allocator, "No project suggestions.");
    try appendIssueSidebarMenuGroupEnd(buf, allocator);
}

fn appendIssueSidebarMilestoneMenu(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, raw_ref: []const u8, milestone: []const u8) !void {
    try appendIssueSidebarSingleInputForm(buf, allocator, raw_ref, "set-milestone", "milestone", "Set milestone", "Filter milestones");
    try appendIssueSidebarMenuGroupStart(buf, allocator, "Selected milestone");
    if (milestone.len == 0) {
        try appendIssueSidebarMenuEmpty(buf, allocator, "No milestone selected.");
    } else {
        try appendIssueSidebarMilestoneActionRow(buf, allocator, raw_ref, milestone, true);
    }
    try appendIssueSidebarMenuGroupEnd(buf, allocator);

    try appendIssueSidebarMenuGroupStart(buf, allocator, "Suggestions");
    var suggestions = try db.prepare(
        \\SELECT DISTINCT candidate.milestone
        \\FROM (
        \\  SELECT title AS milestone FROM milestones WHERE state <> 'closed'
        \\  UNION
        \\  SELECT milestone FROM issue_metadata WHERE milestone <> ''
        \\) AS candidate
        \\WHERE candidate.milestone <> ''
        \\  AND candidate.milestone <> ?
        \\ORDER BY lower(candidate.milestone), candidate.milestone
        \\LIMIT 20
    );
    defer suggestions.deinit();
    try suggestions.bindText(1, milestone);
    var shown = false;
    while (try suggestions.step()) {
        const candidate = try suggestions.columnTextDup(allocator, 0);
        defer allocator.free(candidate);
        try appendIssueSidebarMilestoneActionRow(buf, allocator, raw_ref, candidate, false);
        shown = true;
    }
    if (!shown) try appendIssueSidebarMenuEmpty(buf, allocator, "No milestone suggestions.");
    try appendIssueSidebarMenuGroupEnd(buf, allocator);
}

fn appendIssueSidebarRelationshipsMenu(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator, "<div class=\"issue-sidebar-command-list\">");
    try appendIssueSidebarCommand(buf, allocator, "Add parent", "Alt P");
    try appendIssueSidebarCommand(buf, allocator, "Mark as blocked by", "B B");
    try appendIssueSidebarCommand(buf, allocator, "Mark as blocking", "B X");
    try appendIssueSidebarCommand(buf, allocator, "Add security alert", "");
    try buf.appendSlice(allocator, "</div>");
}

fn appendIssueSidebarDevelopmentMenu(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb) !void {
    try appendIssueSidebarMenuFilter(buf, allocator, "Search pull requests");
    try appendIssueSidebarMenuGroupStart(buf, allocator, "Open pull requests");
    var stmt = try db.prepare(
        \\SELECT p.id, p.title, COALESCE(a.number, 0)
        \\FROM pulls p
        \\LEFT JOIN legacy_aliases a
        \\  ON a.provider = 'github' AND a.object_kind = 'pull' AND a.object_id = p.id
        \\WHERE p.state = 'open'
        \\ORDER BY p.opened_at DESC
        \\LIMIT 12
    );
    defer stmt.deinit();
    var shown = false;
    while (try stmt.step()) {
        const pull_id = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(pull_id);
        const title = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(title);
        const legacy_number = stmt.columnInt64(2);
        try appendIssueSidebarPullChoice(buf, allocator, pull_id, title, legacy_number);
        shown = true;
    }
    if (!shown) try appendIssueSidebarMenuEmpty(buf, allocator, "No open pull requests.");
    try appendIssueSidebarMenuGroupEnd(buf, allocator);
}

fn appendIssueSidebarSectionStart(buf: *std.ArrayList(u8), allocator: Allocator, title: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<section class="issue-sidebar-section"><div class="issue-sidebar-heading"><h2>{title}</h2></div>
    , .{ .title = title });
}

fn appendIssueSidebarEditableSectionStart(buf: *std.ArrayList(u8), allocator: Allocator, title: []const u8, menu_label: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<section class="issue-sidebar-section"><div class="issue-sidebar-heading"><h2>{title}</h2><details class="issue-sidebar-menu" data-popover-menu data-issue-sidebar-menu><summary aria-label="{menu_label}" title="{menu_label}"><span class="issue-sidebar-menu-icon" aria-hidden="true"></span></summary><div class="issue-sidebar-popover" role="dialog" aria-label="{menu_label}"><div class="issue-sidebar-popover-title">{menu_label}</div>
    , .{
        .title = title,
        .menu_label = menu_label,
    });
}

fn appendIssueSidebarEditableSectionBodyStart(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator, "</div></details></div>");
}

fn appendIssueSidebarSectionEnd(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator, "</section>");
}

fn appendIssueSidebarPerson(buf: *std.ArrayList(u8), allocator: Allocator, name: []const u8) !void {
    try buf.appendSlice(allocator, "<div class=\"issue-sidebar-person\">");
    try appendIssueAvatar(buf, allocator, name, "");
    try appendTemplate(buf, allocator, "<span>{name}</span>", .{ .name = name });
    try buf.appendSlice(allocator, "</div>");
}

fn appendIssueSidebarLabel(buf: *std.ArrayList(u8), allocator: Allocator, label: []const u8) !void {
    try buf.appendSlice(allocator, "<span class=\"issue-sidebar-token\">");
    try appendIssueLabel(buf, allocator, label);
    try buf.appendSlice(allocator, "</span>");
}

fn appendIssueSidebarSingleInputForm(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_ref: []const u8,
    action: []const u8,
    input_name: []const u8,
    button_label: []const u8,
    placeholder: []const u8,
) !void {
    try buf.appendSlice(allocator, "<form class=\"issue-sidebar-add-form issue-sidebar-menu-form\" method=\"post\" action=\"");
    try appendIssueSidebarAction(buf, allocator, raw_ref);
    try appendTemplate(buf, allocator,
        \\"><input type="hidden" name="csrf_token" value="{csrf_token}"><input type="hidden" name="action" value="{action}"><label class="issue-sidebar-menu-input"><span aria-hidden="true"></span><input name="{input_name}" placeholder="{placeholder}" aria-label="{placeholder}" autocomplete="off" data-issue-sidebar-filter></label><button type="submit">{button_label}</button></form>
    , .{
        .action = action,
        .input_name = input_name,
        .placeholder = placeholder,
        .button_label = button_label,
        .csrf_token = issueSidebarCsrfToken(),
    });
}

fn appendIssueSidebarProjectForm(buf: *std.ArrayList(u8), allocator: Allocator, raw_ref: []const u8) !void {
    try buf.appendSlice(allocator, "<form class=\"issue-sidebar-add-form issue-sidebar-project-form issue-sidebar-menu-form\" method=\"post\" action=\"");
    try appendIssueSidebarAction(buf, allocator, raw_ref);
    try appendTemplate(buf, allocator,
        \\"><input type="hidden" name="csrf_token" value="{csrf_token}"><input type="hidden" name="action" value="add-project"><label class="issue-sidebar-menu-input"><span aria-hidden="true"></span><input name="project" placeholder="Filter projects" aria-label="Project" autocomplete="off" data-issue-sidebar-filter></label><input name="column" placeholder="Column" aria-label="Column" autocomplete="off"><button type="submit">Add project</button></form>
    , .{ .csrf_token = issueSidebarCsrfToken() });
}

fn appendIssueSidebarMenuFilter(buf: *std.ArrayList(u8), allocator: Allocator, placeholder: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<label class="issue-sidebar-menu-input issue-sidebar-menu-filter"><span aria-hidden="true"></span><input placeholder="{placeholder}" aria-label="{placeholder}" autocomplete="off" data-issue-sidebar-filter></label>
    , .{ .placeholder = placeholder });
}

fn appendIssueSidebarMenuGroupStart(buf: *std.ArrayList(u8), allocator: Allocator, title: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<div class="issue-sidebar-menu-group"><div class="issue-sidebar-menu-group-title">{title}</div>
    , .{ .title = title });
}

fn appendIssueSidebarMenuGroupEnd(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator, "</div>");
}

fn appendIssueSidebarMenuEmpty(buf: *std.ArrayList(u8), allocator: Allocator, message: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<p class="issue-sidebar-menu-empty" data-sidebar-filter-text="">{message}</p>
    , .{ .message = message });
}

fn appendIssueSidebarAssigneeActionRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_ref: []const u8,
    action: []const u8,
    assignee: []const u8,
    selected: bool,
) !void {
    try appendIssueSidebarValueActionFormStart(buf, allocator, raw_ref, action, "value", assignee, assignee, selected);
    try appendIssueAvatar(buf, allocator, assignee, "");
    try appendTemplate(buf, allocator, "<span class=\"issue-sidebar-picker-primary\">{assignee}</span></button></form>", .{
        .assignee = assignee,
    });
}

fn appendIssueSidebarLabelActionRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_ref: []const u8,
    action: []const u8,
    label: []const u8,
    selected: bool,
) !void {
    try appendIssueSidebarValueActionFormStart(buf, allocator, raw_ref, action, "value", label, label, selected);
    try appendIssueLabel(buf, allocator, label);
    try buf.appendSlice(allocator, "</button></form>");
}

fn appendIssueSidebarMilestoneActionRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_ref: []const u8,
    milestone: []const u8,
    selected: bool,
) !void {
    if (selected) {
        try buf.appendSlice(allocator, "<form class=\"issue-sidebar-picker-form\" method=\"post\" action=\"");
        try appendIssueSidebarAction(buf, allocator, raw_ref);
        try appendTemplate(buf, allocator,
            \\"><input type="hidden" name="csrf_token" value="{csrf_token}"><input type="hidden" name="action" value="clear-milestone"><button class="issue-sidebar-picker-row is-selected" type="submit" data-sidebar-filter-text="{milestone}"><span class="issue-sidebar-picker-check" aria-hidden="true"></span><span class="issue-milestone-icon" aria-hidden="true"></span><span class="issue-sidebar-picker-primary">{milestone}</span></button></form>
        , .{
            .milestone = milestone,
            .csrf_token = issueSidebarCsrfToken(),
        });
        return;
    }

    try buf.appendSlice(allocator, "<form class=\"issue-sidebar-picker-form\" method=\"post\" action=\"");
    try appendIssueSidebarAction(buf, allocator, raw_ref);
    try appendTemplate(buf, allocator,
        \\"><input type="hidden" name="csrf_token" value="{csrf_token}"><input type="hidden" name="action" value="set-milestone"><input type="hidden" name="milestone" value="{milestone}"><button class="issue-sidebar-picker-row" type="submit" data-sidebar-filter-text="{milestone}"><span class="issue-sidebar-picker-check" aria-hidden="true"></span><span class="issue-milestone-icon" aria-hidden="true"></span><span class="issue-sidebar-picker-primary">{milestone}</span></button></form>
    , .{
        .milestone = milestone,
        .csrf_token = issueSidebarCsrfToken(),
    });
}

fn appendIssueSidebarProjectActionRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_ref: []const u8,
    action: []const u8,
    project: []const u8,
    column: []const u8,
    selected: bool,
) !void {
    const state_class: []const u8 = if (selected) " is-selected" else "";
    try buf.appendSlice(allocator, "<form class=\"issue-sidebar-picker-form\" method=\"post\" action=\"");
    try appendIssueSidebarAction(buf, allocator, raw_ref);
    try appendTemplate(buf, allocator,
        \\"><input type="hidden" name="csrf_token" value="{csrf_token}"><input type="hidden" name="action" value="{action}"><input type="hidden" name="project" value="{project}"><input type="hidden" name="column" value="{column}"><button class="issue-sidebar-picker-row{state_class}" type="submit" data-sidebar-filter-text="{project} {column}"><span class="issue-sidebar-picker-check" aria-hidden="true"></span><span class="issue-sidebar-project-icon" aria-hidden="true"></span><span class="issue-sidebar-picker-text"><span class="issue-sidebar-picker-primary">{project}</span><span class="issue-sidebar-picker-secondary">{column}</span></span></button></form>
    , .{
        .action = action,
        .project = project,
        .column = column,
        .state_class = state_class,
        .csrf_token = issueSidebarCsrfToken(),
    });
}

fn appendIssueSidebarValueActionFormStart(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_ref: []const u8,
    action: []const u8,
    input_name: []const u8,
    value: []const u8,
    filter_text: []const u8,
    selected: bool,
) !void {
    const state_class: []const u8 = if (selected) " is-selected" else "";
    try buf.appendSlice(allocator, "<form class=\"issue-sidebar-picker-form\" method=\"post\" action=\"");
    try appendIssueSidebarAction(buf, allocator, raw_ref);
    try appendTemplate(buf, allocator,
        \\"><input type="hidden" name="csrf_token" value="{csrf_token}"><input type="hidden" name="action" value="{action}"><input type="hidden" name="{input_name}" value="{value}"><button class="issue-sidebar-picker-row{state_class}" type="submit" data-sidebar-filter-text="{filter_text}"><span class="issue-sidebar-picker-check" aria-hidden="true"></span>
    , .{
        .action = action,
        .input_name = input_name,
        .value = value,
        .filter_text = filter_text,
        .state_class = state_class,
        .csrf_token = issueSidebarCsrfToken(),
    });
}

fn appendIssueSidebarTypeOption(buf: *std.ArrayList(u8), allocator: Allocator, title: []const u8, description: []const u8, kind: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<div class="issue-sidebar-picker-row issue-sidebar-static-row" data-sidebar-filter-text="{title} {description}"><span class="issue-type-dot issue-type-{kind}" aria-hidden="true"></span><span class="issue-sidebar-picker-text"><span class="issue-sidebar-picker-primary">{title}</span><span class="issue-sidebar-picker-secondary">{description}</span></span></div>
    , .{
        .title = title,
        .description = description,
        .kind = kind,
    });
}

fn appendIssueSidebarCommand(buf: *std.ArrayList(u8), allocator: Allocator, label: []const u8, shortcut: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<button type="button" disabled><span>{label}</span>
    , .{ .label = label });
    if (shortcut.len != 0) {
        var parts = std.mem.tokenizeScalar(u8, shortcut, ' ');
        try buf.appendSlice(allocator, "<span class=\"issue-sidebar-command-keys\">");
        while (parts.next()) |part| {
            try appendTemplate(buf, allocator, "<kbd>{part}</kbd>", .{ .part = part });
        }
        try buf.appendSlice(allocator, "</span>");
    }
    try buf.appendSlice(allocator, "</button>");
}

fn appendIssueSidebarPullChoice(buf: *std.ArrayList(u8), allocator: Allocator, pull_id: []const u8, title: []const u8, legacy_number: i64) !void {
    var pull_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const pull_ref = util.shortObjectRef(&pull_ref_buf, pull_id);
    const number_text = try pullNumberText(allocator, pull_ref, legacy_number);
    defer allocator.free(number_text);

    try buf.appendSlice(allocator, "<a class=\"issue-sidebar-picker-row issue-sidebar-link-choice\" href=\"");
    try shared.appendHref(buf, allocator, pullHref(pull_ref));
    try appendTemplate(buf, allocator,
        \\" data-sidebar-filter-text="{title} {number_text}"><span class="issue-sidebar-picker-check" aria-hidden="true"></span><span class="issue-sidebar-pr-icon" aria-hidden="true"></span><span class="issue-sidebar-picker-text"><span class="issue-sidebar-picker-primary">{title}</span><span class="issue-sidebar-picker-secondary">{number_text}</span></span></a>
    , .{
        .title = title,
        .number_text = number_text,
    });
}

fn pullNumberText(allocator: Allocator, pull_ref: []const u8, legacy_number: i64) ![]u8 {
    if (legacy_number > 0) return try std.fmt.allocPrint(allocator, "#{d}", .{legacy_number});
    return try std.fmt.allocPrint(allocator, "#{s}", .{pull_ref});
}

fn appendIssueSidebarRemoveProjectForm(buf: *std.ArrayList(u8), allocator: Allocator, raw_ref: []const u8, project: []const u8, column: []const u8) !void {
    try buf.appendSlice(allocator, "<form class=\"issue-sidebar-remove-form\" method=\"post\" action=\"");
    try appendIssueSidebarAction(buf, allocator, raw_ref);
    try appendTemplate(buf, allocator,
        \\"><input type="hidden" name="csrf_token" value="{csrf_token}"><input type="hidden" name="action" value="remove-project"><input type="hidden" name="project" value="{project}"><input type="hidden" name="column" value="{column}"><button type="submit" aria-label="Remove project">x</button></form>
    , .{
        .project = project,
        .column = column,
        .csrf_token = issueSidebarCsrfToken(),
    });
}

fn appendIssueSidebarRemoveValueForm(buf: *std.ArrayList(u8), allocator: Allocator, raw_ref: []const u8, action: []const u8, label: []const u8) !void {
    try buf.appendSlice(allocator, "<form class=\"issue-sidebar-remove-form\" method=\"post\" action=\"");
    try appendIssueSidebarAction(buf, allocator, raw_ref);
    try appendTemplate(buf, allocator,
        \\"><input type="hidden" name="csrf_token" value="{csrf_token}"><input type="hidden" name="action" value="{action}"><button type="submit" aria-label="{label}">x</button></form>
    , .{
        .action = action,
        .label = label,
        .csrf_token = issueSidebarCsrfToken(),
    });
}

fn appendIssueSidebarRemoveNamedValueForm(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_ref: []const u8,
    action: []const u8,
    input_name: []const u8,
    value: []const u8,
    label: []const u8,
) !void {
    try buf.appendSlice(allocator, "<form class=\"issue-sidebar-remove-form\" method=\"post\" action=\"");
    try appendIssueSidebarAction(buf, allocator, raw_ref);
    try appendTemplate(buf, allocator,
        \\"><input type="hidden" name="csrf_token" value="{csrf_token}"><input type="hidden" name="action" value="{action}"><input type="hidden" name="{input_name}" value="{value}"><button type="submit" aria-label="{label}">x</button></form>
    , .{
        .action = action,
        .input_name = input_name,
        .value = value,
        .label = label,
        .csrf_token = issueSidebarCsrfToken(),
    });
}

fn appendIssueSidebarAction(buf: *std.ArrayList(u8), allocator: Allocator, raw_ref: []const u8) !void {
    try buf.appendSlice(allocator, "/issues/");
    try shared.appendUrlEncoded(buf, allocator, raw_ref);
    try buf.appendSlice(allocator, "/sidebar");
}

fn collectRelationshipDirectivesFromText(
    allocator: Allocator,
    db: *SqliteDb,
    issue_id: []const u8,
    text: []const u8,
    seen: *std.StringHashMap(void),
    relationships: *std.ArrayList(RelationshipItem),
) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        const separator = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const kind = relationshipKindFromKey(std.mem.trim(u8, line[0..separator], " \t\r\n")) orelse continue;
        var tokens = std.mem.tokenizeAny(u8, line[separator + 1 ..], " \t\r\n,");
        while (tokens.next()) |raw_token| {
            const token = trimRelationshipToken(raw_token);
            if (token.len == 0) continue;
            var target = (try resolveRelationshipTarget(allocator, db, token)) orelse continue;
            if (std.mem.eql(u8, target.object_kind, "issue") and std.mem.eql(u8, target.object_id, issue_id)) {
                target.deinit();
                continue;
            }
            try collectRelationshipTarget(allocator, kind, target, seen, relationships);
        }
    }
}

fn collectRelationshipTarget(
    allocator: Allocator,
    kind: RelationshipKind,
    target: ResolvedObjectRef,
    seen: *std.StringHashMap(void),
    relationships: *std.ArrayList(RelationshipItem),
) !void {
    errdefer {
        var cleanup = target;
        cleanup.deinit();
    }

    const key = try std.fmt.allocPrint(allocator, "{s}\x1f{s}\x1f{s}", .{ @tagName(kind), target.object_kind, target.object_id });
    errdefer allocator.free(key);
    const entry = try seen.getOrPut(key);
    if (entry.found_existing) {
        allocator.free(key);
        var duplicate = target;
        duplicate.deinit();
        return;
    }
    entry.value_ptr.* = {};
    errdefer _ = seen.remove(key);
    try relationships.append(allocator, .{ .kind = kind, .target = target });
}

fn trimRelationshipToken(raw: []const u8) []const u8 {
    return std.mem.trim(u8, raw, " \t\r\n.,;()[]{}<>\"'`");
}

fn relationshipKindFromKey(key: []const u8) ?RelationshipKind {
    if (asciiEqlIgnoreCase(key, "Refs")) return .refs;
    if (asciiEqlIgnoreCase(key, "Relates-To") or asciiEqlIgnoreCase(key, "Related-To")) return .relates_to;
    if (asciiEqlIgnoreCase(key, "Blocks")) return .blocks;
    if (asciiEqlIgnoreCase(key, "Blocked-By")) return .blocked_by;
    if (asciiEqlIgnoreCase(key, "Duplicates")) return .duplicates;
    if (asciiEqlIgnoreCase(key, "Duplicate-Of")) return .duplicate_of;
    return null;
}

fn relationshipGroupTitle(kind: RelationshipKind, object_kind: []const u8) []const u8 {
    const is_pull = std.mem.eql(u8, object_kind, "pull");
    return switch (kind) {
        .refs => if (is_pull) "Referenced pull request" else "Referenced issue",
        .relates_to => if (is_pull) "Related pull request" else "Related issue",
        .blocks => if (is_pull) "Blocking pull request" else "Blocking issue",
        .blocked_by => if (is_pull) "Blocked by pull request" else "Blocked by issue",
        .duplicates => if (is_pull) "Duplicate pull request" else "Duplicate issue",
        .duplicate_of => if (is_pull) "Original pull request" else "Original issue",
    };
}

fn appendRelationshipGroups(buf: *std.ArrayList(u8), allocator: Allocator, relationships: []const RelationshipItem) !void {
    try buf.appendSlice(allocator, "<div class=\"issue-relationships\">");
    inline for (.{ RelationshipKind.blocked_by, .blocks, .duplicate_of, .duplicates, .relates_to, .refs }) |kind| {
        try appendRelationshipGroup(buf, allocator, relationships, kind, "issue");
        try appendRelationshipGroup(buf, allocator, relationships, kind, "pull");
    }
    try buf.appendSlice(allocator, "</div>");
}

fn appendRelationshipGroup(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    relationships: []const RelationshipItem,
    kind: RelationshipKind,
    object_kind: []const u8,
) !void {
    var shown = false;
    for (relationships) |item| {
        if (item.kind != kind or !std.mem.eql(u8, item.target.object_kind, object_kind)) continue;
        if (!shown) {
            try appendTemplate(buf, allocator,
                \\<div class="issue-relationship-group"><div class="issue-relationship-group-title">{title}</div><div class="issue-relationship-list">
            , .{ .title = relationshipGroupTitle(kind, object_kind) });
            shown = true;
        }
        try appendRelationshipRow(buf, allocator, item.target);
    }
    if (shown) try buf.appendSlice(allocator, "</div></div>");
}

fn appendRelationshipRow(buf: *std.ArrayList(u8), allocator: Allocator, target: ResolvedObjectRef) !void {
    const is_pull = std.mem.eql(u8, target.object_kind, "pull");
    var object_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const object_ref = util.shortObjectRef(&object_ref_buf, target.object_id);
    try buf.appendSlice(allocator, "<a class=\"issue-relationship-row\" href=\"");
    try appendRelationshipTargetHref(buf, allocator, target, object_ref);
    try appendTemplate(buf, allocator,
        \\" aria-label="{kind} {title}">
        \\  <span class="{icon_classes}" aria-hidden="true"></span>
        \\  <span class="issue-relationship-main"><span class="issue-relationship-title">{title}</span><span class="issue-relationship-ref">
    , .{
        .kind = if (is_pull) "Pull request" else "Issue",
        .title = target.title,
        .icon_classes = shared.classes("issue-relationship-icon", &.{
            shared.class("is-issue", !is_pull),
            shared.class("is-pull", is_pull),
            shared.class("is-open", std.mem.eql(u8, target.state, "open")),
            shared.class("is-closed", std.mem.eql(u8, target.state, "closed")),
            shared.class("is-merged", std.mem.eql(u8, target.state, "merged")),
        }),
    });
    try appendRelationshipDisplayRef(buf, allocator, target, object_ref);
    try appendTemplate(buf, allocator,
        \\</span></span><span class="{badge_classes}">{state}</span></a>
    , .{
        .badge_classes = shared.classes("issue-relationship-badge", &.{
            shared.class("is-open", std.mem.eql(u8, target.state, "open")),
            shared.class("is-closed", std.mem.eql(u8, target.state, "closed")),
            shared.class("is-merged", std.mem.eql(u8, target.state, "merged")),
        }),
        .state = relationshipStateLabel(target.state),
    });
}

fn appendRelationshipTargetHref(buf: *std.ArrayList(u8), allocator: Allocator, target: ResolvedObjectRef, object_ref: []const u8) !void {
    if (target.legacy_number > 0) {
        const number_ref = try std.fmt.allocPrint(allocator, "{d}", .{target.legacy_number});
        defer allocator.free(number_ref);
        try shared.appendHref(buf, allocator, if (std.mem.eql(u8, target.object_kind, "pull")) pullHref(number_ref) else issueHref(number_ref));
        return;
    }
    try shared.appendHref(buf, allocator, if (std.mem.eql(u8, target.object_kind, "pull")) pullHref(object_ref) else issueHref(object_ref));
}

fn appendRelationshipDisplayRef(buf: *std.ArrayList(u8), allocator: Allocator, target: ResolvedObjectRef, object_ref: []const u8) !void {
    if (std.mem.eql(u8, target.object_kind, "pull")) try buf.appendSlice(allocator, "PR ");
    try buf.append(allocator, '#');
    if (target.legacy_number > 0) {
        try std.fmt.format(buf.writer(allocator), "{d}", .{target.legacy_number});
    } else {
        try shared.appendHtml(buf, allocator, object_ref);
    }
}

fn relationshipStateLabel(state: []const u8) []const u8 {
    if (std.mem.eql(u8, state, "open")) return "Open";
    if (std.mem.eql(u8, state, "closed")) return "Closed";
    if (std.mem.eql(u8, state, "merged")) return "Merged";
    return state;
}

fn resolveRelationshipTarget(allocator: Allocator, db: *SqliteDb, token: []const u8) !?ResolvedObjectRef {
    if (std.mem.startsWith(u8, token, "#")) {
        return try resolveUntypedRelationshipTarget(allocator, db, token[1..]);
    }
    if (asciiStartsWithIgnoreCase(token, "issue:")) {
        return try resolveSpecificRelationshipTarget(allocator, db, "issue", stripOptionalHash(token["issue:".len..]));
    }
    if (asciiStartsWithIgnoreCase(token, "pr:")) {
        return try resolveSpecificRelationshipTarget(allocator, db, "pull", stripOptionalHash(token["pr:".len..]));
    }
    if (asciiStartsWithIgnoreCase(token, "pull:")) {
        return try resolveSpecificRelationshipTarget(allocator, db, "pull", stripOptionalHash(token["pull:".len..]));
    }
    return null;
}

fn resolveUntypedRelationshipTarget(allocator: Allocator, db: *SqliteDb, value: []const u8) !?ResolvedObjectRef {
    var issue_target = try resolveSpecificRelationshipTarget(allocator, db, "issue", value);
    errdefer if (issue_target) |*target| target.deinit();
    var pull_target = try resolveSpecificRelationshipTarget(allocator, db, "pull", value);
    if (issue_target != null and pull_target != null) {
        issue_target.?.deinit();
        pull_target.?.deinit();
        return null;
    }
    if (issue_target) |target| return target;
    return pull_target;
}

fn resolveSpecificRelationshipTarget(allocator: Allocator, db: *SqliteDb, object_kind: []const u8, raw_value: []const u8) !?ResolvedObjectRef {
    const value = std.mem.trim(u8, raw_value, " \t\r\n");
    if (value.len == 0) return null;
    if (util.looksLikeUuid(value)) return try lookupResolvedObjectById(allocator, db, object_kind, value);
    if (util.isObjectRefPrefix(value)) return try lookupResolvedObjectByHashRef(allocator, db, object_kind, value);
    if (parsePositiveDecimal(value)) |number| return try lookupResolvedLegacyObject(allocator, db, object_kind, number);
    return null;
}

fn lookupResolvedObjectById(allocator: Allocator, db: *SqliteDb, object_kind: []const u8, object_id: []const u8) !?ResolvedObjectRef {
    const sql_text: []const u8 = if (std.mem.eql(u8, object_kind, "pull"))
        \\SELECT p.id, p.title, p.state, COALESCE(a.number, 0)
        \\FROM pulls p
        \\LEFT JOIN legacy_aliases a
        \\  ON a.provider = 'github' AND a.object_kind = 'pull' AND a.object_id = p.id
        \\WHERE p.id = ?
    else
        \\SELECT i.id, i.title, i.state, COALESCE(a.number, 0)
        \\FROM issues i
        \\LEFT JOIN legacy_aliases a
        \\  ON a.provider = 'github' AND a.object_kind = 'issue' AND a.object_id = i.id
        \\WHERE i.id = ?
    ;
    var stmt = try db.prepare(sql_text);
    defer stmt.deinit();
    try stmt.bindText(1, object_id);
    if (!(try stmt.step())) return null;
    return .{
        .allocator = allocator,
        .object_kind = object_kind,
        .object_id = try stmt.columnTextDup(allocator, 0),
        .title = try stmt.columnTextDup(allocator, 1),
        .state = try stmt.columnTextDup(allocator, 2),
        .legacy_number = stmt.columnInt64(3),
    };
}

fn lookupResolvedObjectByHashRef(allocator: Allocator, db: *SqliteDb, object_kind: []const u8, value: []const u8) !?ResolvedObjectRef {
    const sql_text: []const u8 = if (std.mem.eql(u8, object_kind, "pull"))
        "SELECT id FROM pulls ORDER BY id"
    else
        "SELECT id FROM issues ORDER BY id";
    var stmt = try db.prepare(sql_text);
    defer stmt.deinit();

    var matched_id: ?[]u8 = null;
    errdefer if (matched_id) |id| allocator.free(id);
    while (try stmt.step()) {
        const candidate_id = try stmt.columnTextDup(allocator, 0);
        errdefer allocator.free(candidate_id);
        var ref_buf: [util.max_object_ref_len]u8 = undefined;
        const candidate_ref = util.objectRefPrefix(ref_buf[0..value.len], candidate_id);
        if (!asciiEqlIgnoreCase(candidate_ref, value)) {
            allocator.free(candidate_id);
            continue;
        }
        if (matched_id != null) {
            allocator.free(candidate_id);
            allocator.free(matched_id.?);
            return null;
        }
        matched_id = candidate_id;
    }
    const id = matched_id orelse return null;
    defer allocator.free(id);
    return try lookupResolvedObjectById(allocator, db, object_kind, id);
}

fn lookupResolvedLegacyObject(allocator: Allocator, db: *SqliteDb, object_kind: []const u8, number: i64) !?ResolvedObjectRef {
    var stmt = try db.prepare(
        \\SELECT object_id
        \\FROM legacy_aliases
        \\WHERE provider = 'github'
        \\  AND object_kind = ?
        \\  AND number = ?
    );
    defer stmt.deinit();
    try stmt.bindText(1, object_kind);
    try stmt.bindInt64(2, number);
    if (!(try stmt.step())) return null;
    const object_id = try stmt.columnTextDup(allocator, 0);
    defer allocator.free(object_id);
    return try lookupResolvedObjectById(allocator, db, object_kind, object_id);
}

fn stripOptionalHash(value: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "#")) return trimmed[1..];
    return trimmed;
}

fn asciiStartsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and asciiEqlIgnoreCase(value[0..prefix.len], prefix);
}

fn parsePositiveDecimal(value: []const u8) ?i64 {
    if (value.len == 0) return null;
    for (value) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    const number = std.fmt.parseInt(i64, value, 10) catch return null;
    return if (number > 0) number else null;
}

pub fn handleIssueSidebarPost(allocator: Allocator, repo: Repo, stream: std.net.Stream, raw_ref: []const u8, form_body: []const u8) !void {
    if (!(try validateIssueSidebarCsrf(allocator, stream, form_body))) return;

    try ensureIndex(allocator, repo);
    const issue_id = index.resolveIssueId(allocator, repo, raw_ref) catch {
        try sendPlainResponse(allocator, stream, 404, "Not Found", "Issue not found\n");
        return;
    };
    defer allocator.free(issue_id);

    const action_owned = (try formValueOwned(allocator, form_body, "action")) orelse {
        try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Missing sidebar action\n");
        return;
    };
    defer allocator.free(action_owned);
    const action = std.mem.trim(u8, action_owned, " \t\r\n");

    if (std.mem.eql(u8, action, "add-label") or std.mem.eql(u8, action, "remove-label")) {
        const value_owned = try requiredSidebarValue(allocator, stream, form_body, "value", "Label is required.");
        const value = value_owned orelse return;
        defer allocator.free(value);
        const event_type: []const u8 = if (std.mem.eql(u8, action, "add-label")) "issue.label_added" else "issue.label_removed";
        if (!(try writeSidebarStringEventOrFail(allocator, stream, issue_id, event_type, "label", value))) return;
    } else if (std.mem.eql(u8, action, "add-assignee") or std.mem.eql(u8, action, "remove-assignee")) {
        const value_owned = try requiredSidebarValue(allocator, stream, form_body, "value", "Assignee is required.");
        const value = value_owned orelse return;
        defer allocator.free(value);
        const event_type: []const u8 = if (std.mem.eql(u8, action, "add-assignee")) "issue.assignee_added" else "issue.assignee_removed";
        if (!(try writeSidebarStringEventOrFail(allocator, stream, issue_id, event_type, "assignee", value))) return;
    } else if (std.mem.eql(u8, action, "set-milestone")) {
        const milestone_owned = (try formValueOwned(allocator, form_body, "milestone")) orelse try allocator.dupe(u8, "");
        defer allocator.free(milestone_owned);
        const milestone = std.mem.trim(u8, milestone_owned, " \t\r\n");
        if (!(try writeSidebarStringEventOrFail(allocator, stream, issue_id, "issue.milestone_set", "milestone", milestone))) return;
    } else if (std.mem.eql(u8, action, "clear-milestone")) {
        if (!(try writeSidebarStringEventOrFail(allocator, stream, issue_id, "issue.milestone_set", "milestone", ""))) return;
    } else if (std.mem.eql(u8, action, "add-project") or std.mem.eql(u8, action, "remove-project")) {
        const project_owned = try requiredSidebarValue(allocator, stream, form_body, "project", "Project is required.");
        const project_value = project_owned orelse return;
        defer allocator.free(project_value);
        const add = std.mem.eql(u8, action, "add-project");
        const column_value = if (add) blk: {
            const column_owned = try requiredSidebarValue(allocator, stream, form_body, "column", "Column is required.");
            break :blk column_owned orelse return;
        } else blk: {
            const column_owned = (try formValueOwned(allocator, form_body, "column")) orelse try allocator.dupe(u8, "");
            defer allocator.free(column_owned);
            break :blk try allocator.dupe(u8, std.mem.trim(u8, column_owned, " \t\r\n"));
        };
        defer allocator.free(column_value);
        createIssueProjectEvent(allocator, issue_id, project_value, column_value, null, null, add) catch {
            try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not update issue project placement\n");
            return;
        };
    } else {
        try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Unknown sidebar action\n");
        return;
    }

    const location = try std.fmt.allocPrint(allocator, "/issues/{s}", .{raw_ref});
    defer allocator.free(location);
    try sendRedirect(allocator, stream, location);
}

pub fn handleIssueEditPost(allocator: Allocator, repo: Repo, stream: std.net.Stream, raw_ref: []const u8, form_body: []const u8) !void {
    try ensureIndex(allocator, repo);
    const issue_id = index.resolveIssueId(allocator, repo, raw_ref) catch {
        const page = try renderIssueNotFound(allocator, repo, raw_ref);
        defer allocator.free(page);
        try sendResponse(allocator, stream, 404, "Not Found", "text/html", page, null);
        return;
    };
    defer allocator.free(issue_id);

    const target_ref_owned = (try formValueOwned(allocator, form_body, "target_ref")) orelse try allocator.dupe(u8, "issue");
    defer allocator.free(target_ref_owned);
    const target_ref = std.mem.trim(u8, target_ref_owned, " \t\r\n");
    if (target_ref.len == 0 or std.mem.eql(u8, target_ref, "issue")) {
        try handleIssueBodyEditPost(allocator, repo, stream, raw_ref, issue_id, form_body);
        return;
    }
    try handleCommentBodyEditPost(allocator, repo, stream, raw_ref, issue_id, target_ref, form_body);
}

fn handleIssueBodyEditPost(
    allocator: Allocator,
    repo: Repo,
    stream: std.net.Stream,
    raw_ref: []const u8,
    issue_id: []const u8,
    form_body: []const u8,
) !void {
    const title_owned = (try formValueOwned(allocator, form_body, "title")) orelse try allocator.dupe(u8, "");
    defer allocator.free(title_owned);
    const body_owned = (try formValueOwned(allocator, form_body, "body")) orelse try allocator.dupe(u8, "");
    defer allocator.free(body_owned);
    const title = std.mem.trim(u8, title_owned, " \t\r\n");
    if (title.len == 0) {
        const page = try renderIssueEditIssuePage(allocator, repo, raw_ref, "Title is required.", title_owned, body_owned);
        defer allocator.free(page);
        try sendResponse(allocator, stream, 422, "Unprocessable Entity", "text/html", page, null);
        return;
    }

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var stmt = try db.prepare("SELECT title, body, author_principal FROM issues WHERE id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    if (!(try stmt.step())) {
        const page = try renderIssueNotFound(allocator, repo, raw_ref);
        defer allocator.free(page);
        try sendResponse(allocator, stream, 404, "Not Found", "text/html", page, null);
        return;
    }
    const current_title = try stmt.columnTextDup(allocator, 0);
    defer allocator.free(current_title);
    const current_body = try stmt.columnTextDup(allocator, 1);
    defer allocator.free(current_body);
    const author_principal = try stmt.columnTextDup(allocator, 2);
    defer allocator.free(author_principal);
    if (!(try currentActorCanEditInRepo(allocator, repo, author_principal))) {
        const page = try renderIssueEditAccessDenied(allocator, repo, raw_ref, "Edit issue", "You do not have permission to edit this issue.");
        defer allocator.free(page);
        try sendResponse(allocator, stream, 403, "Forbidden", "text/html", page, null);
        return;
    }

    var update: event_mod.IssueUpdate = .{};
    if (!std.mem.eql(u8, title, current_title)) update.title = title;
    if (!std.mem.eql(u8, body_owned, current_body)) update.body = body_owned;
    if (!update.hasChanges()) {
        const location = try std.fmt.allocPrint(allocator, "/issues/{s}", .{raw_ref});
        defer allocator.free(location);
        try sendRedirect(allocator, stream, location);
        return;
    }

    createIssueUpdatedEvent(allocator, issue_id, update) catch {
        const page = try renderIssueEditIssuePage(allocator, repo, raw_ref, "Could not save the issue. Check that Gitomi is initialized and Git commit signing is configured.", title, body_owned);
        defer allocator.free(page);
        try sendResponse(allocator, stream, 500, "Internal Server Error", "text/html", page, null);
        return;
    };

    const location = try std.fmt.allocPrint(allocator, "/issues/{s}", .{raw_ref});
    defer allocator.free(location);
    try sendRedirect(allocator, stream, location);
}

pub fn handleIssueChecklistPost(allocator: Allocator, repo: Repo, stream: std.net.Stream, raw_ref: []const u8, form_body: []const u8) !void {
    try ensureIndex(allocator, repo);
    const issue_id = index.resolveIssueId(allocator, repo, raw_ref) catch {
        try sendPlainResponse(allocator, stream, 404, "Not Found", "Issue not found\n");
        return;
    };
    defer allocator.free(issue_id);

    const body_owned = (try formValueOwned(allocator, form_body, "body")) orelse {
        try sendPlainResponse(allocator, stream, 400, "Bad Request", "Missing body\n");
        return;
    };
    defer allocator.free(body_owned);

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var stmt = try db.prepare("SELECT body, author_principal FROM issues WHERE id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    if (!(try stmt.step())) {
        try sendPlainResponse(allocator, stream, 404, "Not Found", "Issue not found\n");
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

    createIssueUpdatedEvent(allocator, issue_id, .{ .body = body_owned }) catch {
        try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not update checklist\n");
        return;
    };
    try sendResponse(allocator, stream, 204, "No Content", "text/plain", "", null);
}

fn handleCommentBodyEditPost(
    allocator: Allocator,
    repo: Repo,
    stream: std.net.Stream,
    raw_ref: []const u8,
    issue_id: []const u8,
    target_ref: []const u8,
    form_body: []const u8,
) !void {
    const body_owned = (try formValueOwned(allocator, form_body, "body")) orelse try allocator.dupe(u8, "");
    defer allocator.free(body_owned);
    const comment_id = index.resolveCommentId(allocator, repo, target_ref) catch {
        const page = try renderIssueEditAccessDenied(allocator, repo, raw_ref, "Edit comment", "Comment not found.");
        defer allocator.free(page);
        try sendResponse(allocator, stream, 404, "Not Found", "text/html", page, null);
        return;
    };
    defer allocator.free(comment_id);
    var parent = try index.commentParentInfo(allocator, repo, comment_id);
    defer parent.deinit();
    if (!std.mem.eql(u8, parent.parent_kind, "issue") or !std.mem.eql(u8, parent.parent_id, issue_id)) {
        const page = try renderIssueEditAccessDenied(allocator, repo, raw_ref, "Edit comment", "Comment is not in this issue.");
        defer allocator.free(page);
        try sendResponse(allocator, stream, 422, "Unprocessable Entity", "text/html", page, null);
        return;
    }

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var stmt = try db.prepare("SELECT body, redacted, author_principal FROM comments WHERE id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, comment_id);
    if (!(try stmt.step())) {
        const page = try renderIssueEditAccessDenied(allocator, repo, raw_ref, "Edit comment", "Comment not found.");
        defer allocator.free(page);
        try sendResponse(allocator, stream, 404, "Not Found", "text/html", page, null);
        return;
    }
    const current_body = try stmt.columnTextDup(allocator, 0);
    defer allocator.free(current_body);
    const redacted = stmt.columnInt(1) != 0;
    const author_principal = try stmt.columnTextDup(allocator, 2);
    defer allocator.free(author_principal);
    if (redacted or !(try currentActorCanEditInRepo(allocator, repo, author_principal))) {
        const page = try renderIssueEditAccessDenied(allocator, repo, raw_ref, "Edit comment", "You do not have permission to edit this comment.");
        defer allocator.free(page);
        try sendResponse(allocator, stream, 403, "Forbidden", "text/html", page, null);
        return;
    }

    var comment_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const comment_ref = util.shortObjectRef(&comment_ref_buf, comment_id);
    if (std.mem.eql(u8, body_owned, current_body)) {
        const location = try std.fmt.allocPrint(allocator, "/issues/{s}#comment-{s}", .{ raw_ref, comment_ref });
        defer allocator.free(location);
        try sendRedirect(allocator, stream, location);
        return;
    }

    createCommentBodySetEvent(allocator, comment_id, body_owned) catch {
        const page = try renderIssueEditCommentPage(allocator, repo, raw_ref, target_ref, "Could not save the comment. Check that Gitomi is initialized and Git commit signing is configured.", body_owned);
        defer allocator.free(page);
        try sendResponse(allocator, stream, 500, "Internal Server Error", "text/html", page, null);
        return;
    };

    const location = try std.fmt.allocPrint(allocator, "/issues/{s}#comment-{s}", .{ raw_ref, comment_ref });
    defer allocator.free(location);
    try sendRedirect(allocator, stream, location);
}

fn requiredSidebarValue(allocator: Allocator, stream: std.net.Stream, form_body: []const u8, name: []const u8, message: []const u8) !?[]u8 {
    const owned = (try formValueOwned(allocator, form_body, name)) orelse {
        try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", message);
        return null;
    };
    defer allocator.free(owned);
    const trimmed = std.mem.trim(u8, owned, " \t\r\n");
    if (trimmed.len == 0) {
        try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", message);
        return null;
    }
    return try allocator.dupe(u8, trimmed);
}

fn writeSidebarStringEventOrFail(
    allocator: Allocator,
    stream: std.net.Stream,
    issue_id: []const u8,
    event_type: []const u8,
    payload_key: []const u8,
    payload_value: []const u8,
) !bool {
    createIssueStringEvent(allocator, issue_id, event_type, payload_key, payload_value) catch {
        try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not update issue metadata\n");
        return false;
    };
    return true;
}

pub fn handleIssueCommentPost(allocator: Allocator, repo: Repo, stream: std.net.Stream, raw_ref: []const u8, form_body: []const u8) !void {
    const action_owned = try formValueOwned(allocator, form_body, "action");
    defer if (action_owned) |value| allocator.free(value);
    if (action_owned) |raw_action| {
        const action = std.mem.trim(u8, raw_action, " \t\r\n");
        if (std.mem.eql(u8, action, "add-reaction") or std.mem.eql(u8, action, "remove-reaction")) {
            try ensureIndex(allocator, repo);
            const issue_id = index.resolveIssueId(allocator, repo, raw_ref) catch {
                try sendPlainResponse(allocator, stream, 404, "Not Found", "Issue not found\n");
                return;
            };
            defer allocator.free(issue_id);

            const emoji_owned = (try formValueOwned(allocator, form_body, "emoji")) orelse {
                try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Emoji is required\n");
                return;
            };
            defer allocator.free(emoji_owned);
            const emoji = std.mem.trim(u8, emoji_owned, " \t\r\n");
            if (emoji.len == 0) {
                try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Emoji is required\n");
                return;
            }

            const target_kind_owned = (try formValueOwned(allocator, form_body, "target_kind")) orelse try allocator.dupe(u8, "issue");
            defer allocator.free(target_kind_owned);
            const target_kind = std.mem.trim(u8, target_kind_owned, " \t\r\n");
            const add = std.mem.eql(u8, action, "add-reaction");
            if (std.mem.eql(u8, target_kind, "issue")) {
                createReactionEvent(allocator, "issue", issue_id, emoji, add) catch {
                    try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not update reaction\n");
                    return;
                };
            } else if (std.mem.eql(u8, target_kind, "comment")) {
                const target_ref_owned = (try formValueOwned(allocator, form_body, "target_ref")) orelse {
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
                if (!std.mem.eql(u8, parent.parent_kind, "issue") or !std.mem.eql(u8, parent.parent_id, issue_id)) {
                    try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Comment is not in this issue\n");
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

            const location = try std.fmt.allocPrint(allocator, "/issues/{s}", .{raw_ref});
            defer allocator.free(location);
            try sendRedirect(allocator, stream, location);
            return;
        }
    }

    const submit_action = if (action_owned) |raw_action| std.mem.trim(u8, raw_action, " \t\r\n") else "comment";
    const target_state: ?[]const u8 = if (std.mem.eql(u8, submit_action, "close-issue"))
        "closed"
    else if (std.mem.eql(u8, submit_action, "reopen-issue"))
        "open"
    else
        null;
    if (!std.mem.eql(u8, submit_action, "comment") and target_state == null) {
        try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Unknown issue action\n");
        return;
    }

    const body_owned = (try formValueOwned(allocator, form_body, "body")) orelse try allocator.dupe(u8, "");
    defer allocator.free(body_owned);

    const body = std.mem.trim(u8, body_owned, " \t\r\n");
    if (body.len == 0 and target_state == null) {
        const page = try renderIssueDetailPageWithCommentForm(allocator, repo, raw_ref, "Comment is required.", body_owned);
        defer allocator.free(page);
        try sendResponse(allocator, stream, 422, "Unprocessable Entity", "text/html", page, null);
        return;
    }

    try ensureIndex(allocator, repo);
    const issue_id = index.resolveIssueId(allocator, repo, raw_ref) catch {
        const page = try renderIssueNotFound(allocator, repo, raw_ref);
        defer allocator.free(page);
        try sendResponse(allocator, stream, 404, "Not Found", "text/html", page, null);
        return;
    };
    defer allocator.free(issue_id);

    if (body.len != 0) {
        const reply_ref_owned = try formValueOwned(allocator, form_body, "reply_parent_ref");
        defer if (reply_ref_owned) |value| allocator.free(value);
        const reply_ref = if (reply_ref_owned) |value| std.mem.trim(u8, value, " \t\r\n") else "";
        if (reply_ref.len != 0) {
            const reply_parent_id = index.resolveCommentId(allocator, repo, reply_ref) catch {
                const page = try renderIssueDetailPageWithCommentForm(allocator, repo, raw_ref, "Reply target was not found.", body_owned);
                defer allocator.free(page);
                try sendResponse(allocator, stream, 422, "Unprocessable Entity", "text/html", page, null);
                return;
            };
            defer allocator.free(reply_parent_id);
            var parent = try index.commentParentInfo(allocator, repo, reply_parent_id);
            defer parent.deinit();
            if (!std.mem.eql(u8, parent.parent_kind, "issue") or !std.mem.eql(u8, parent.parent_id, issue_id)) {
                const page = try renderIssueDetailPageWithCommentForm(allocator, repo, raw_ref, "Reply target is not in this issue.", body_owned);
                defer allocator.free(page);
                try sendResponse(allocator, stream, 422, "Unprocessable Entity", "text/html", page, null);
                return;
            }
            createCommentReplyEvent(allocator, "issue", issue_id, reply_parent_id, parent.add_hash, body_owned) catch {
                const page = try renderIssueDetailPageWithCommentForm(
                    allocator,
                    repo,
                    raw_ref,
                    "Could not add the reply. Check that Gitomi is initialized and Git commit signing is configured.",
                    body_owned,
                );
                defer allocator.free(page);
                try sendResponse(allocator, stream, 500, "Internal Server Error", "text/html", page, null);
                return;
            };
        } else {
            createCommentAddedEvent(allocator, "issue", issue_id, body_owned) catch {
                const page = try renderIssueDetailPageWithCommentForm(
                    allocator,
                    repo,
                    raw_ref,
                    "Could not add the comment. Check that Gitomi is initialized and Git commit signing is configured.",
                    body_owned,
                );
                defer allocator.free(page);
                try sendResponse(allocator, stream, 500, "Internal Server Error", "text/html", page, null);
                return;
            };
        }
    }

    if (target_state) |state_value| {
        createIssueStringEvent(allocator, issue_id, "issue.state_set", "state", state_value) catch {
            const page = try renderIssueDetailPageWithCommentForm(
                allocator,
                repo,
                raw_ref,
                if (std.mem.eql(u8, state_value, "closed"))
                    "Could not close the issue. Check that Gitomi is initialized and Git commit signing is configured."
                else
                    "Could not reopen the issue. Check that Gitomi is initialized and Git commit signing is configured.",
                body_owned,
            );
            defer allocator.free(page);
            try sendResponse(allocator, stream, 500, "Internal Server Error", "text/html", page, null);
            return;
        };
    }

    const location = try std.fmt.allocPrint(allocator, "/issues/{s}", .{raw_ref});
    defer allocator.free(location);
    try sendRedirect(allocator, stream, location);
}

pub fn renderIssueForm(
    allocator: Allocator,
    repo: Repo,
    error_message: ?[]const u8,
    title_value: []const u8,
    body_value: []const u8,
    labels_value: []const u8,
    assignees_value: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "New Issue", "issues");
    try buf.appendSlice(allocator, "<section class=\"panel form-panel\">");
    try appendSectionHead(&buf, allocator, "Issues", "New Issue", null);
    if (error_message) |message| {
        try appendTemplate(&buf, allocator,
            \\<div class="flash error">{message}</div>
        , .{ .message = message });
    }
    try appendTemplate(&buf, allocator,
        \\  <form method="post" action="/issues" class="issue-form">
        \\    <label>Title<input name="title" value="{title_value}" autofocus required></label>
        \\    <label>Body<textarea name="body" rows="8">{body_value}</textarea></label>
        \\    <div class="grid two">
        \\      <label>Labels<input name="labels" value="{labels_value}" placeholder="bug, docs"></label>
        \\      <label>Assignees<input name="assignees" value="{assignees_value}" placeholder="alice, bob"></label>
        \\    </div>
        \\    <div class="form-actions">
        \\      <a class="button secondary" href="/issues">Cancel</a>
        \\      <button class="button primary" type="submit">Create issue</button>
        \\    </div>
        \\  </form>
        \\</section>
    , .{
        .title_value = title_value,
        .body_value = body_value,
        .labels_value = labels_value,
        .assignees_value = assignees_value,
    });
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

pub fn renderIssueFormFromTarget(allocator: Allocator, repo: Repo, target: []const u8) ![]u8 {
    const title = try queryValueOwned(allocator, target, "title");
    defer if (title) |value| allocator.free(value);
    const body = try queryValueOwned(allocator, target, "body");
    defer if (body) |value| allocator.free(value);
    const labels = try queryValueOwned(allocator, target, "labels");
    defer if (labels) |value| allocator.free(value);
    const assignees = try queryValueOwned(allocator, target, "assignees");
    defer if (assignees) |value| allocator.free(value);

    return renderIssueForm(
        allocator,
        repo,
        null,
        title orelse "",
        body orelse "",
        labels orelse "",
        assignees orelse "",
    );
}

pub fn handleIssuePost(allocator: Allocator, repo: Repo, stream: std.net.Stream, form_body: []const u8) !void {
    const title_owned = (try formValueOwned(allocator, form_body, "title")) orelse try allocator.dupe(u8, "");
    defer allocator.free(title_owned);
    const body_owned = (try formValueOwned(allocator, form_body, "body")) orelse try allocator.dupe(u8, "");
    defer allocator.free(body_owned);
    const labels_owned = (try formValueOwned(allocator, form_body, "labels")) orelse try allocator.dupe(u8, "");
    defer allocator.free(labels_owned);
    const assignees_owned = (try formValueOwned(allocator, form_body, "assignees")) orelse try allocator.dupe(u8, "");
    defer allocator.free(assignees_owned);

    const title = std.mem.trim(u8, title_owned, " \t\r\n");
    if (title.len == 0) {
        const body = try renderIssueForm(allocator, repo, "Title is required.", title_owned, body_owned, labels_owned, assignees_owned);
        defer allocator.free(body);
        try sendResponse(allocator, stream, 422, "Unprocessable Entity", "text/html", body, null);
        return;
    }

    var labels = try splitCommaFields(allocator, labels_owned);
    defer labels.deinit(allocator);
    var assignees = try splitCommaFields(allocator, assignees_owned);
    defer assignees.deinit(allocator);

    createIssueOpenedEvent(allocator, title, body_owned, labels.items, assignees.items) catch {
        const body = try renderIssueForm(
            allocator,
            repo,
            "Could not create the issue. Check that Gitomi is initialized and Git commit signing is configured.",
            title_owned,
            body_owned,
            labels_owned,
            assignees_owned,
        );
        defer allocator.free(body);
        try sendResponse(allocator, stream, 500, "Internal Server Error", "text/html", body, null);
        return;
    };

    try sendRedirect(allocator, stream, "/issues");
}

pub fn issueTitleFromSubject(subject: []const u8) []const u8 {
    const marker = " #";
    const marker_index = std.mem.indexOf(u8, subject, marker) orelse return subject;
    const after_marker = subject[marker_index + marker.len ..];
    const title_index = std.mem.indexOfScalar(u8, after_marker, ' ') orelse return subject;
    const title = std.mem.trim(u8, after_marker[title_index + 1 ..], " \t\r\n");
    return if (title.len == 0) subject else title;
}

pub fn formValueOwned(allocator: Allocator, body: []const u8, wanted_key: []const u8) !?[]u8 {
    var pairs = std.mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const raw_key = pair[0..eq];
        const raw_value = if (eq < pair.len) pair[eq + 1 ..] else "";
        const key = try percentDecodeForm(allocator, raw_key);
        defer allocator.free(key);
        if (!std.mem.eql(u8, key, wanted_key)) continue;
        return try percentDecodeForm(allocator, raw_value);
    }
    return null;
}

fn queryValueOwned(allocator: Allocator, target: []const u8, wanted_key: []const u8) !?[]u8 {
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var pairs = std.mem.splitScalar(u8, target[query_start + 1 ..], '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const raw_key = pair[0..eq];
        const raw_value = if (eq < pair.len) pair[eq + 1 ..] else "";
        const key = try percentDecodeForm(allocator, raw_key);
        defer allocator.free(key);
        if (!std.mem.eql(u8, key, wanted_key)) continue;
        return try percentDecodeForm(allocator, raw_value);
    }
    return null;
}

pub fn percentDecodeForm(allocator: Allocator, value: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        switch (value[i]) {
            '+' => try buf.append(allocator, ' '),
            '%' => {
                if (i + 2 >= value.len) return error.InvalidFormEncoding;
                const hi = hexValue(value[i + 1]) orelse return error.InvalidFormEncoding;
                const lo = hexValue(value[i + 2]) orelse return error.InvalidFormEncoding;
                try buf.append(allocator, (hi << 4) | lo);
                i += 2;
            },
            else => |c| try buf.append(allocator, c),
        }
    }

    return buf.toOwnedSlice(allocator);
}

pub fn hexValue(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

test "web form decoding handles spaces and escapes" {
    const decoded = try percentDecodeForm(std.testing.allocator, "hello+local%2Fworld%21");
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("hello local/world!", decoded);

    const value = (try formValueOwned(std.testing.allocator, "title=First+issue&labels=bug%2Cdocs", "labels")).?;
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("bug,docs", value);
}

test "issue list SQL includes selected filters" {
    var filters = IssueFilters{
        .allocator = std.testing.allocator,
        .state = .open,
        .q = try std.testing.allocator.dupe(u8, "crash"),
        .label = try std.testing.allocator.dupe(u8, "bug"),
        .assignee = try std.testing.allocator.dupe(u8, "alice"),
        .sort = .updated,
    };
    defer filters.deinit();

    const sql = try work_items.issueListSql(std.testing.allocator, filters);
    defer std.testing.allocator.free(sql);
    try std.testing.expect(std.mem.indexOf(u8, sql, "i.state = ?") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "i.title LIKE ?") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "issue_labels") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "issue_assignees") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "ORDER BY i.state_occurred_at DESC") != null);
}

test "issue filter hrefs preserve and clear parameters" {
    var filters = IssueFilters{
        .allocator = std.testing.allocator,
        .state = .closed,
        .q = try std.testing.allocator.dupe(u8, "crash fix"),
        .label = try std.testing.allocator.dupe(u8, "bug"),
        .sort = .updated,
    };
    defer filters.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendIssuesHref(&buf, std.testing.allocator, filters, .{
        .state = .open,
        .param_name = "label",
        .param_value = null,
    });
    try std.testing.expectEqualStrings("/issues?state=open&q=crash%20fix&amp;sort=updated", buf.items);
}

test "relationship directive keys are case-insensitive" {
    try std.testing.expectEqual(RelationshipKind.blocks, relationshipKindFromKey("blocks").?);
    try std.testing.expectEqual(RelationshipKind.blocked_by, relationshipKindFromKey("Blocked-By").?);
    try std.testing.expectEqual(RelationshipKind.relates_to, relationshipKindFromKey("related-to").?);
    try std.testing.expect(relationshipKindFromKey("mentions") == null);
    try std.testing.expectEqualStrings("#abc123", trimRelationshipToken("(#abc123,"));
}

test "relationship groups render stateful issue rows" {
    var target = ResolvedObjectRef{
        .allocator = std.testing.allocator,
        .object_kind = "issue",
        .object_id = try std.testing.allocator.dupe(u8, "018f0000-0000-7000-8000-000000000010"),
        .title = try std.testing.allocator.dupe(u8, "Parent issue"),
        .state = try std.testing.allocator.dupe(u8, "open"),
        .legacy_number = 1,
    };
    defer target.deinit();

    const relationships = [_]RelationshipItem{.{ .kind = .blocked_by, .target = target }};
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendRelationshipGroups(&buf, std.testing.allocator, relationships[0..]);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Blocked by issue") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "issue-relationship-row") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, ">#1<") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, ">Open<") != null);
}

test "web issue titles come from issue opened subjects" {
    try std.testing.expectEqualStrings("Indexed issue", issueTitleFromSubject("issue.opened #018f000 Indexed issue"));
    try std.testing.expectEqualStrings("custom subject", issueTitleFromSubject("custom subject"));
}
