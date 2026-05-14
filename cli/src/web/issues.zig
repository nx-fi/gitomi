const std = @import("std");
const comment_mod = @import("../comment.zig");
const index = @import("../index.zig");
const issue = @import("../issue.zig");
const markdown_render = @import("markdown_render.zig");
const repo_mod = @import("../repo.zig");
const shared = @import("shared.zig");
const util = @import("../util.zig");

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
const createIssueOpenedEvent = issue.createIssueOpenedEvent;
const createIssueProjectEvent = issue.createIssueProjectEvent;
const createIssueStringEvent = issue.createIssueStringEvent;
const ensureIndex = index.ensureIndex;
const commitHref = shared.commitHref;
const issueHref = shared.issueHref;
const pullHref = shared.pullHref;
const sendRedirect = shared.sendRedirect;
const sendPlainResponse = shared.sendPlainResponse;
const sendResponse = shared.sendResponse;
const splitCommaFields = util.splitCommaFields;
const sqlite = index.sqlite;

const IssueStateFilter = enum {
    open,
    closed,
    all,
};

const IssueCounts = struct {
    open: usize = 0,
    closed: usize = 0,
    all: usize = 0,
};

const IssueSort = enum {
    newest,
    oldest,
    updated,
};

const IssueFilters = struct {
    allocator: Allocator,
    state: IssueStateFilter,
    q: ?[]u8 = null,
    author: ?[]u8 = null,
    label: ?[]u8 = null,
    project: ?[]u8 = null,
    milestone: ?[]u8 = null,
    assignee: ?[]u8 = null,
    sort: IssueSort = .newest,

    fn deinit(self: *IssueFilters) void {
        if (self.q) |value| self.allocator.free(value);
        if (self.author) |value| self.allocator.free(value);
        if (self.label) |value| self.allocator.free(value);
        if (self.project) |value| self.allocator.free(value);
        if (self.milestone) |value| self.allocator.free(value);
        if (self.assignee) |value| self.allocator.free(value);
    }
};

const IssueFilterKind = enum {
    author,
    label,
    project,
    milestone,
    assignee,
};

const IssueHrefOverride = struct {
    state: ?IssueStateFilter = null,
    sort: ?IssueSort = null,
    param_name: ?[]const u8 = null,
    param_value: ?[]const u8 = null,
};

const RelationshipKind = enum {
    refs,
    relates_to,
    blocks,
    blocked_by,
    duplicates,
    duplicate_of,
};

const ResolvedObjectRef = struct {
    allocator: Allocator,
    object_kind: []const u8,
    object_id: []u8,
    title: []u8,
    legacy_number: i64,

    fn deinit(self: *ResolvedObjectRef) void {
        self.allocator.free(self.object_id);
        self.allocator.free(self.title);
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
    const counts = try loadIssueCounts(&db);
    const default_state = requested_filter orelse if (counts.open == 0 and counts.closed > 0) IssueStateFilter.closed else IssueStateFilter.open;
    var filters = try issueFiltersFromTarget(allocator, target, default_state);
    defer filters.deinit();

    try appendShellStart(&buf, allocator, repo, "Issues", "issues");
    try appendIssuesToolbar(&buf, allocator, filters);
    try buf.appendSlice(allocator, "<section class=\"panel issues-panel\">");
    try appendIssuesListHeader(&buf, allocator, &db, filters, counts);

    const sql = try issueListSql(allocator, filters);
    defer allocator.free(sql);
    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    const search_pattern = if (filters.q) |query| try sqliteLikePatternOwned(allocator, query) else null;
    defer if (search_pattern) |pattern| allocator.free(pattern);
    try bindIssueListFilters(&stmt, filters, search_pattern);

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
        const milestone = try stmt.columnTextDup(allocator, 6);
        defer allocator.free(milestone);
        const comment_count = @as(usize, @intCast(stmt.columnInt64(7)));
        const legacy_number = stmt.columnInt64(8);

        try appendIssueListRow(&buf, allocator, &db, id, title, state, author, opened_at, state_at, milestone, comment_count, legacy_number);
        shown += 1;
    }

    if (shown == 0) {
        if (hasRestrictiveIssueFilters(filters)) {
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
        if (std.mem.eql(u8, query, issueSearchQuery(default_state))) {
            allocator.free(query);
        } else {
            filters.q = query;
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

fn issueListSql(allocator: Allocator, filters: IssueFilters) ![]u8 {
    var sql: std.ArrayList(u8) = .empty;
    errdefer sql.deinit(allocator);

    try sql.appendSlice(allocator,
        \\SELECT i.id, i.title, i.state,
        \\       COALESCE(NULLIF(m.source_author, ''), i.author_principal),
        \\       i.opened_at, i.state_occurred_at, COALESCE(m.milestone, ''),
        \\       (SELECT COUNT(*) FROM comments c WHERE c.parent_kind = 'issue' AND c.parent_id = i.id),
        \\       COALESCE(a.number, 0)
        \\FROM issues i
        \\LEFT JOIN issue_metadata m ON m.issue_id = i.id
        \\LEFT JOIN legacy_aliases a
        \\  ON a.provider = 'github' AND a.object_kind = 'issue' AND a.object_id = i.id
    );

    var conditions: usize = 0;
    if (filters.state != .all) try appendIssueListCondition(&sql, allocator, &conditions, "i.state = ?");
    if (filters.q != null) {
        try appendIssueListCondition(&sql, allocator, &conditions,
            \\(i.title LIKE ? ESCAPE '\' OR i.body LIKE ? ESCAPE '\' OR COALESCE(NULLIF(m.source_author, ''), i.author_principal) LIKE ? ESCAPE '\' OR EXISTS (SELECT 1 FROM comments c WHERE c.parent_kind = 'issue' AND c.parent_id = i.id AND c.body LIKE ? ESCAPE '\'))
        );
    }
    if (filters.author != null) try appendIssueListCondition(&sql, allocator, &conditions, "COALESCE(NULLIF(m.source_author, ''), i.author_principal) = ?");
    if (filters.label != null) try appendIssueListCondition(&sql, allocator, &conditions, "EXISTS (SELECT 1 FROM issue_labels il WHERE il.issue_id = i.id AND il.label = ?)");
    if (filters.project != null) try appendIssueListCondition(&sql, allocator, &conditions, "EXISTS (SELECT 1 FROM issue_projects ip WHERE ip.issue_id = i.id AND ip.project = ?)");
    if (filters.milestone != null) try appendIssueListCondition(&sql, allocator, &conditions, "COALESCE(m.milestone, '') = ?");
    if (filters.assignee != null) try appendIssueListCondition(&sql, allocator, &conditions, "EXISTS (SELECT 1 FROM issue_assignees ia WHERE ia.issue_id = i.id AND ia.assignee = ?)");

    try sql.appendSlice(allocator, switch (filters.sort) {
        .newest => "\nORDER BY i.opened_at DESC, i.id DESC",
        .oldest => "\nORDER BY i.opened_at ASC, i.id ASC",
        .updated => "\nORDER BY i.state_occurred_at DESC, i.opened_at DESC, i.id DESC",
    });
    return sql.toOwnedSlice(allocator);
}

fn appendIssueListCondition(sql: *std.ArrayList(u8), allocator: Allocator, conditions: *usize, condition: []const u8) !void {
    try sql.appendSlice(allocator, if (conditions.* == 0) "\nWHERE " else "\n  AND ");
    try sql.appendSlice(allocator, condition);
    conditions.* += 1;
}

fn bindIssueListFilters(stmt: *index.SqliteStmt, filters: IssueFilters, search_pattern: ?[]const u8) !void {
    var idx: c_int = 1;
    if (filters.state != .all) {
        try stmt.bindText(idx, issueStateValue(filters.state));
        idx += 1;
    }
    if (search_pattern) |pattern| {
        try stmt.bindText(idx, pattern);
        idx += 1;
        try stmt.bindText(idx, pattern);
        idx += 1;
        try stmt.bindText(idx, pattern);
        idx += 1;
        try stmt.bindText(idx, pattern);
        idx += 1;
    }
    if (filters.author) |value| {
        try stmt.bindText(idx, value);
        idx += 1;
    }
    if (filters.label) |value| {
        try stmt.bindText(idx, value);
        idx += 1;
    }
    if (filters.project) |value| {
        try stmt.bindText(idx, value);
        idx += 1;
    }
    if (filters.milestone) |value| {
        try stmt.bindText(idx, value);
        idx += 1;
    }
    if (filters.assignee) |value| {
        try stmt.bindText(idx, value);
        idx += 1;
    }
}

fn sqliteLikePatternOwned(allocator: Allocator, value: []const u8) ![]u8 {
    var pattern: std.ArrayList(u8) = .empty;
    errdefer pattern.deinit(allocator);
    try pattern.append(allocator, '%');
    for (value) |c| {
        if (c == '%' or c == '_' or c == '\\') try pattern.append(allocator, '\\');
        try pattern.append(allocator, c);
    }
    try pattern.append(allocator, '%');
    return pattern.toOwnedSlice(allocator);
}

fn hasRestrictiveIssueFilters(filters: IssueFilters) bool {
    return filters.q != null or
        filters.author != null or
        filters.label != null or
        filters.project != null or
        filters.milestone != null or
        filters.assignee != null;
}

fn loadIssueCounts(db: *SqliteDb) !IssueCounts {
    var counts: IssueCounts = .{};
    var stmt = try db.prepare("SELECT state, COUNT(*) FROM issues GROUP BY state");
    defer stmt.deinit();
    while (try stmt.step()) {
        const state = try stmt.columnTextDup(db.allocator, 0);
        defer db.allocator.free(state);
        const count = @as(usize, @intCast(stmt.columnInt64(1)));
        counts.all += count;
        if (std.mem.eql(u8, state, "open")) {
            counts.open = count;
        } else if (std.mem.eql(u8, state, "closed")) {
            counts.closed = count;
        }
    }
    return counts;
}

fn appendIssuesToolbar(buf: *std.ArrayList(u8), allocator: Allocator, filters: IssueFilters) !void {
    try appendTemplate(buf, allocator,
        \\<div class="issues-toolbar">
        \\  <form class="issues-search" action="/issues" method="get">
        \\    <span class="issues-search-icon" aria-hidden="true"></span>
        \\    <input type="search" name="q" value="{query}" aria-label="Search issues">
        \\    <input type="hidden" name="state" value="{state}">
    , .{
        .query = filters.q orelse issueSearchQuery(filters.state),
        .state = issueStateValue(filters.state),
    });
    try appendIssueFilterHiddenInputs(buf, allocator, filters);
    try buf.appendSlice(allocator,
        \\  </form>
        \\  <div class="issues-toolbar-actions">
        \\    <button class="button secondary issue-tool-button" type="button" disabled><span class="button-icon icon-labels" aria-hidden="true"></span><span>Labels</span></button>
        \\    <button class="button secondary issue-tool-button" type="button" disabled><span class="button-icon icon-milestones" aria-hidden="true"></span><span>Milestones</span></button>
        \\    <a class="button primary" href="/new-issue">New issue</a>
        \\  </div>
        \\</div>
    );
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
        , .{ .sort = issueSortValue(filters.sort) });
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
        \\<details{classes}><summary>{label}
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
        \\<details{classes}><summary>{label}</summary><div class="issues-filter-popover" role="menu">
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
    try appendIssuesHrefParam(buf, allocator, &first, "state", issueStateValue(override.state orelse filters.state));
    if (filterHrefValue(filters, override, "q")) |value| try appendIssuesHrefParam(buf, allocator, &first, "q", value);
    if (filterHrefValue(filters, override, "author")) |value| try appendIssuesHrefParam(buf, allocator, &first, "author", value);
    if (filterHrefValue(filters, override, "label")) |value| try appendIssuesHrefParam(buf, allocator, &first, "label", value);
    if (filterHrefValue(filters, override, "project")) |value| try appendIssuesHrefParam(buf, allocator, &first, "project", value);
    if (filterHrefValue(filters, override, "milestone")) |value| try appendIssuesHrefParam(buf, allocator, &first, "milestone", value);
    if (filterHrefValue(filters, override, "assignee")) |value| try appendIssuesHrefParam(buf, allocator, &first, "assignee", value);

    const sort = override.sort orelse filters.sort;
    if (sort != .newest) try appendIssuesHrefParam(buf, allocator, &first, "sort", issueSortValue(sort));
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
    try appendTemplate(buf, allocator,
        \\<span class="issue-avatar {extra_class}" title="{name}" aria-label="{name}">
    , .{
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

fn issueSearchQuery(filter: IssueStateFilter) []const u8 {
    return switch (filter) {
        .open => "is:issue state:open",
        .closed => "is:issue state:closed",
        .all => "is:issue",
    };
}

fn issueStateValue(filter: IssueStateFilter) []const u8 {
    return switch (filter) {
        .open => "open",
        .closed => "closed",
        .all => "all",
    };
}

fn issueSortValue(sort: IssueSort) []const u8 {
    return switch (sort) {
        .newest => "newest",
        .oldest => "oldest",
        .updated => "updated",
    };
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

    var stmt = try db.prepare(
        \\SELECT i.id, i.title, i.state, i.author_principal, i.opened_at, i.body,
        \\       COALESCE(m.source_author, ''), COALESCE(m.milestone, ''), COALESCE(a.number, 0),
        \\       i.state_occurred_at,
        \\       (SELECT COUNT(*) FROM comments c WHERE c.parent_kind = 'issue' AND c.parent_id = i.id)
        \\FROM issues i
        \\LEFT JOIN issue_metadata m ON m.issue_id = i.id
        \\LEFT JOIN legacy_aliases a
        \\  ON a.provider = 'github' AND a.object_kind = 'issue' AND a.object_id = i.id
        \\WHERE i.id = ?
    );
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    if (!(try stmt.step())) return renderIssueNotFound(allocator, repo, raw_ref);

    const id = try stmt.columnTextDup(allocator, 0);
    defer allocator.free(id);
    const title = try stmt.columnTextDup(allocator, 1);
    defer allocator.free(title);
    const state = try stmt.columnTextDup(allocator, 2);
    defer allocator.free(state);
    const author_principal = try stmt.columnTextDup(allocator, 3);
    defer allocator.free(author_principal);
    const opened_at = try stmt.columnTextDup(allocator, 4);
    defer allocator.free(opened_at);
    const body = try stmt.columnTextDup(allocator, 5);
    defer allocator.free(body);
    const source_author = try stmt.columnTextDup(allocator, 6);
    defer allocator.free(source_author);
    const milestone = try stmt.columnTextDup(allocator, 7);
    defer allocator.free(milestone);
    const legacy_number = stmt.columnInt64(8);
    const state_at = try stmt.columnTextDup(allocator, 9);
    defer allocator.free(state_at);
    const comment_count = @as(usize, @intCast(stmt.columnInt64(10)));

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const display_author = if (source_author.len != 0) source_author else author_principal;

    try appendShellStart(&buf, allocator, repo, title, "issues");
    try buf.appendSlice(allocator, "<section class=\"issue-page\">");
    try appendIssuePageHeader(&buf, allocator, id, title, state, display_author, opened_at, state_at, comment_count, legacy_number);
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
    try appendRelativeTime(&buf, allocator, opened_at);
    try buf.appendSlice(allocator, "</span></div>");
    try appendIssueActionMenu(&buf, allocator, "issue-description", body, body.len != 0, false);
    try appendTemplate(&buf, allocator,
        \\          </header>
        \\          <div class="markdown-body">
    , .{});
    if (body.len == 0) {
        try buf.appendSlice(allocator, "<p class=\"muted\">No description provided.</p>");
    } else {
        try markdown_render.appendMarkdown(&buf, allocator, body);
    }
    try buf.appendSlice(allocator,
        \\          </div>
        \\        </article>
        \\      </div>
    );
    try appendIssueComments(&buf, allocator, &db, id);
    try appendIssueCommentForm(&buf, allocator, raw_ref, comment_error, comment_value);
    try buf.appendSlice(allocator, "    </div><aside class=\"issue-meta-sidebar\">");
    try appendIssueSidebar(&buf, allocator, &db, raw_ref, id, display_author, milestone, body);
    try buf.appendSlice(allocator, "</aside></div></section>");
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn appendIssuePageHeader(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    issue_id: []const u8,
    title: []const u8,
    state: []const u8,
    author: []const u8,
    opened_at: []const u8,
    state_at: []const u8,
    comment_count: usize,
    legacy_number: i64,
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
        \\        <button class="button secondary" type="button" disabled>Edit</button>
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

fn appendLegacyIssueLink(buf: *std.ArrayList(u8), allocator: Allocator, legacy_number: i64) !void {
    const issue_ref = try std.fmt.allocPrint(allocator, "{d}", .{legacy_number});
    defer allocator.free(issue_ref);
    try shared.appendIssueReferenceLink(buf, allocator, issue_ref);
}

fn appendIssueComments(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, issue_id: []const u8) !void {
    var stmt = try db.prepare(
        \\SELECT id, body, redacted, COALESCE(NULLIF(source_author, ''), author_principal), created_at, reply_parent_id, reply_parent_hash
        \\FROM comments
        \\WHERE parent_kind = 'issue' AND parent_id = ?
        \\ORDER BY created_at, id
    );
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
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

        const is_reply = reply_parent_id.len != 0 or reply_parent_hash.len != 0;
        try appendTemplate(buf, allocator,
            \\<div class="{classes}" id="{anchor}"><div class="issue-timeline-avatar">
        , .{
            .classes = shared.classes("issue-timeline-item", &.{shared.class("is-reply", is_reply)}),
            .anchor = anchor,
        });
        try appendIssueAvatar(buf, allocator, author, "issue-detail-avatar");
        try appendTemplate(buf, allocator,
            \\</div><article class="issue-comment-box"><header class="issue-comment-head"><div><strong>{author}</strong><span>commented
        , .{
            .author = author,
        });
        try buf.append(allocator, ' ');
        try appendRelativeTime(buf, allocator, created_at);
        try buf.appendSlice(allocator, "</span></div>");
        try appendIssueActionMenu(buf, allocator, anchor, body, !redacted and body.len != 0, false);
        try buf.appendSlice(allocator, "</header>");
        if (reply_parent_id.len != 0 or reply_parent_hash.len != 0) {
            try buf.appendSlice(allocator, "<p class=\"reply-note\">Reply to ");
            if (reply_parent_id.len != 0) {
                try appendTemplate(buf, allocator, "#{reply_parent_id}", .{
                    .reply_parent_id = reply_parent_id[0..@min(reply_parent_id.len, 7)],
                });
            } else {
                try appendTemplate(buf, allocator, "{reply_parent_hash}", .{
                    .reply_parent_hash = reply_parent_hash[0..@min(reply_parent_hash.len, 12)],
                });
            }
            try buf.appendSlice(allocator, "</p>");
        }
        try buf.appendSlice(allocator, "<div class=\"markdown-body\">");
        if (redacted) {
            try buf.appendSlice(allocator, "<p class=\"muted\">Comment redacted.</p>");
        } else {
            try markdown_render.appendMarkdown(buf, allocator, body);
        }
        try buf.appendSlice(allocator, "</div></article></div>");
    }
}

fn appendIssueActionMenu(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    anchor: []const u8,
    markdown: []const u8,
    markdown_available: bool,
    edit_available: bool,
) !void {
    try appendTemplate(buf, allocator,
        \\<details class="issue-action-menu" data-issue-menu data-issue-anchor="{anchor}">
        \\  <summary class="issue-kebab-button" aria-label="Comment actions" title="Comment actions"></summary>
        \\  <template data-issue-markdown>{markdown}</template>
        \\  <div class="issue-action-popover" role="menu">
    , .{
        .anchor = anchor,
        .markdown = markdown,
    });
    try appendIssueActionMenuItem(buf, allocator, "copy-link", "issue-menu-icon-link", "Copy link", false);
    try appendIssueActionMenuItem(buf, allocator, "copy-markdown", "issue-menu-icon-markdown", "Copy Markdown", !markdown_available);
    try appendIssueActionMenuItem(buf, allocator, "quote-reply", "issue-menu-icon-quote", "Quote reply", !markdown_available);
    try buf.appendSlice(allocator, "<div class=\"issue-action-divider\" role=\"separator\"></div>");
    try appendIssueActionMenuItem(buf, allocator, "edit", "issue-menu-icon-edit", "Edit", !edit_available);
    try buf.appendSlice(allocator, "</div></details>");
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
    error_message: ?[]const u8,
    body_value: []const u8,
) !void {
    try buf.appendSlice(allocator,
        \\<div class="issue-timeline-item issue-comment-form-item">
        \\  <div class="issue-timeline-avatar"><span class="issue-avatar issue-detail-avatar issue-comment-form-avatar" title="Current user" aria-label="Current user">Y</span></div>
        \\  <form class="issue-comment-box issue-comment-form" method="post" action="/issues/
    );
    try shared.appendUrlEncoded(buf, allocator, raw_ref);
    try appendTemplate(buf, allocator,
        \\/comments">
        \\    <textarea name="body" rows="5" placeholder="Leave a comment" required>{body_value}</textarea>
    , .{ .body_value = body_value });
    if (error_message) |message| {
        try appendTemplate(buf, allocator,
            \\    <p class="issue-comment-error">{message}</p>
        , .{ .message = message });
    }
    try buf.appendSlice(allocator,
        \\    <div class="issue-comment-form-actions">
        \\      <button class="button primary" type="submit">Comment</button>
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
    try appendIssueSidebarText(buf, allocator, "Type", "No type");
    try appendIssueSidebarProjects(buf, allocator, db, raw_ref, issue_id);
    try appendIssueSidebarMilestone(buf, allocator, raw_ref, milestone);
    try appendIssueSidebarRelationships(buf, allocator, db, issue_id, body);
    try appendIssueSidebarDevelopment(buf, allocator, db, issue_id);
    try appendIssueSidebarNotifications(buf, allocator);
    try appendIssueSidebarParticipants(buf, allocator, db, issue_id, author);
}

fn appendIssueSidebarAssignees(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, raw_ref: []const u8, issue_id: []const u8) !void {
    try appendIssueSidebarSectionStart(buf, allocator, "Assignees");
    var stmt = try db.prepare("SELECT DISTINCT assignee FROM issue_assignees WHERE issue_id = ? ORDER BY assignee");
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    var shown = false;
    while (try stmt.step()) {
        const assignee = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(assignee);
        try appendIssueSidebarPerson(buf, allocator, raw_ref, assignee);
        shown = true;
    }
    if (!shown) try buf.appendSlice(allocator, "<p class=\"issue-sidebar-empty\">No one assigned</p>");
    try appendIssueSidebarSingleInputForm(buf, allocator, raw_ref, "add-assignee", "value", "Add assignee", "Assignee");
    try appendIssueSidebarSectionEnd(buf, allocator);
}

fn appendIssueSidebarLabels(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, raw_ref: []const u8, issue_id: []const u8) !void {
    try appendIssueSidebarSectionStart(buf, allocator, "Labels");
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
        try appendIssueSidebarLabel(buf, allocator, raw_ref, label);
    }
    if (shown) {
        try buf.appendSlice(allocator, "</div>");
    } else {
        try buf.appendSlice(allocator, "<p class=\"issue-sidebar-empty\">None yet</p>");
    }
    try appendIssueSidebarSingleInputForm(buf, allocator, raw_ref, "add-label", "value", "Add label", "Label");
    try appendIssueSidebarSectionEnd(buf, allocator);
}

fn appendIssueSidebarProjects(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, raw_ref: []const u8, issue_id: []const u8) !void {
    try appendIssueSidebarSectionStart(buf, allocator, "Projects");
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
        try buf.appendSlice(allocator, "</span>");
        try appendIssueSidebarRemoveProjectForm(buf, allocator, raw_ref, project, column);
        try buf.appendSlice(allocator, "</span>");
        shown = true;
    }
    if (!shown) try buf.appendSlice(allocator, "<p class=\"issue-sidebar-empty\">No projects</p>");
    try appendIssueSidebarProjectForm(buf, allocator, raw_ref);
    try appendIssueSidebarSectionEnd(buf, allocator);
}

fn appendIssueSidebarMilestone(buf: *std.ArrayList(u8), allocator: Allocator, raw_ref: []const u8, milestone: []const u8) !void {
    try appendIssueSidebarSectionStart(buf, allocator, "Milestone");
    if (milestone.len == 0) {
        try buf.appendSlice(allocator, "<p class=\"issue-sidebar-empty\">No milestone</p>");
    } else {
        try buf.appendSlice(allocator, "<span class=\"issue-sidebar-token\"><span class=\"issue-sidebar-pill\">");
        try shared.appendHtml(buf, allocator, milestone);
        try buf.appendSlice(allocator, "</span>");
        try appendIssueSidebarRemoveValueForm(buf, allocator, raw_ref, "clear-milestone", "Clear milestone");
        try buf.appendSlice(allocator, "</span>");
    }
    try appendIssueSidebarSingleInputForm(buf, allocator, raw_ref, "set-milestone", "milestone", "Set milestone", "Milestone");
    try appendIssueSidebarSectionEnd(buf, allocator);
}

fn appendIssueSidebarRelationships(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, issue_id: []const u8, body: []const u8) !void {
    try appendIssueSidebarSectionStart(buf, allocator, "Relationships");
    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var keys = seen.keyIterator();
        while (keys.next()) |key| allocator.free(key.*);
        seen.deinit();
    }
    var shown = false;
    try appendRelationshipDirectivesFromText(buf, allocator, db, issue_id, body, &seen, &shown);

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
        try appendRelationshipDirectivesFromText(buf, allocator, db, issue_id, comment_body, &seen, &shown);
    }

    if (!shown) try buf.appendSlice(allocator, "<p class=\"issue-sidebar-empty\">None yet</p>");
    try appendIssueSidebarSectionEnd(buf, allocator);
}

fn appendIssueSidebarDevelopment(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, issue_id: []const u8) !void {
    try appendIssueSidebarSectionStart(buf, allocator, "Development");
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

fn appendIssueSidebarText(buf: *std.ArrayList(u8), allocator: Allocator, title: []const u8, value: []const u8) !void {
    try appendIssueSidebarSectionStart(buf, allocator, title);
    try appendTemplate(buf, allocator, "<p class=\"issue-sidebar-empty\">{value}</p>", .{ .value = value });
    try appendIssueSidebarSectionEnd(buf, allocator);
}

fn appendIssueSidebarSectionStart(buf: *std.ArrayList(u8), allocator: Allocator, title: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<section class="issue-sidebar-section"><h2>{title}</h2>
    , .{ .title = title });
}

fn appendIssueSidebarSectionEnd(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator, "</section>");
}

fn appendIssueSidebarPerson(buf: *std.ArrayList(u8), allocator: Allocator, raw_ref: []const u8, name: []const u8) !void {
    try buf.appendSlice(allocator, "<div class=\"issue-sidebar-person issue-sidebar-person-editable\">");
    try appendIssueAvatar(buf, allocator, name, "");
    try appendTemplate(buf, allocator, "<span>{name}</span>", .{ .name = name });
    try appendIssueSidebarRemoveNamedValueForm(buf, allocator, raw_ref, "remove-assignee", "value", name, "Remove assignee");
    try buf.appendSlice(allocator, "</div>");
}

fn appendIssueSidebarLabel(buf: *std.ArrayList(u8), allocator: Allocator, raw_ref: []const u8, label: []const u8) !void {
    try buf.appendSlice(allocator, "<span class=\"issue-sidebar-token\">");
    try appendIssueLabel(buf, allocator, label);
    try appendIssueSidebarRemoveNamedValueForm(buf, allocator, raw_ref, "remove-label", "value", label, "Remove label");
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
    try buf.appendSlice(allocator, "<form class=\"issue-sidebar-add-form\" method=\"post\" action=\"");
    try appendIssueSidebarAction(buf, allocator, raw_ref);
    try appendTemplate(buf, allocator,
        \\"><input type="hidden" name="action" value="{action}"><input name="{input_name}" placeholder="{placeholder}" aria-label="{placeholder}"><button type="submit">{button_label}</button></form>
    , .{
        .action = action,
        .input_name = input_name,
        .placeholder = placeholder,
        .button_label = button_label,
    });
}

fn appendIssueSidebarProjectForm(buf: *std.ArrayList(u8), allocator: Allocator, raw_ref: []const u8) !void {
    try buf.appendSlice(allocator, "<form class=\"issue-sidebar-add-form issue-sidebar-project-form\" method=\"post\" action=\"");
    try appendIssueSidebarAction(buf, allocator, raw_ref);
    try buf.appendSlice(allocator,
        \\"><input type="hidden" name="action" value="add-project"><input name="project" placeholder="Project" aria-label="Project"><input name="column" placeholder="Column" aria-label="Column"><button type="submit">Add project</button></form>
    );
}

fn appendIssueSidebarRemoveProjectForm(buf: *std.ArrayList(u8), allocator: Allocator, raw_ref: []const u8, project: []const u8, column: []const u8) !void {
    try buf.appendSlice(allocator, "<form class=\"issue-sidebar-remove-form\" method=\"post\" action=\"");
    try appendIssueSidebarAction(buf, allocator, raw_ref);
    try appendTemplate(buf, allocator,
        \\"><input type="hidden" name="action" value="remove-project"><input type="hidden" name="project" value="{project}"><input type="hidden" name="column" value="{column}"><button type="submit" aria-label="Remove project">x</button></form>
    , .{
        .project = project,
        .column = column,
    });
}

fn appendIssueSidebarRemoveValueForm(buf: *std.ArrayList(u8), allocator: Allocator, raw_ref: []const u8, action: []const u8, label: []const u8) !void {
    try buf.appendSlice(allocator, "<form class=\"issue-sidebar-remove-form\" method=\"post\" action=\"");
    try appendIssueSidebarAction(buf, allocator, raw_ref);
    try appendTemplate(buf, allocator,
        \\"><input type="hidden" name="action" value="{action}"><button type="submit" aria-label="{label}">x</button></form>
    , .{
        .action = action,
        .label = label,
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
        \\"><input type="hidden" name="action" value="{action}"><input type="hidden" name="{input_name}" value="{value}"><button type="submit" aria-label="{label}">x</button></form>
    , .{
        .action = action,
        .input_name = input_name,
        .value = value,
        .label = label,
    });
}

fn appendIssueSidebarAction(buf: *std.ArrayList(u8), allocator: Allocator, raw_ref: []const u8) !void {
    try buf.appendSlice(allocator, "/issues/");
    try shared.appendUrlEncoded(buf, allocator, raw_ref);
    try buf.appendSlice(allocator, "/sidebar");
}

fn appendRelationshipDirectivesFromText(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    issue_id: []const u8,
    text: []const u8,
    seen: *std.StringHashMap(void),
    shown: *bool,
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
            defer target.deinit();
            if (std.mem.eql(u8, target.object_kind, "issue") and std.mem.eql(u8, target.object_id, issue_id)) continue;
            try appendRelationshipTarget(buf, allocator, kind, target, seen, shown);
        }
    }
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

fn relationshipKindLabel(kind: RelationshipKind) []const u8 {
    return switch (kind) {
        .refs => "references",
        .relates_to => "relates to",
        .blocks => "blocks",
        .blocked_by => "blocked by",
        .duplicates => "duplicates",
        .duplicate_of => "duplicate of",
    };
}

fn appendRelationshipTarget(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    kind: RelationshipKind,
    target: ResolvedObjectRef,
    seen: *std.StringHashMap(void),
    shown: *bool,
) !void {
    const key = try std.fmt.allocPrint(allocator, "{s}\x1f{s}\x1f{s}", .{ @tagName(kind), target.object_kind, target.object_id });
    errdefer allocator.free(key);
    const entry = try seen.getOrPut(key);
    if (entry.found_existing) {
        allocator.free(key);
        return;
    }
    entry.value_ptr.* = {};

    var object_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const object_ref = util.shortObjectRef(&object_ref_buf, target.object_id);
    try buf.appendSlice(allocator, "<a class=\"issue-sidebar-link-row\" href=\"");
    if (std.mem.eql(u8, target.object_kind, "pull")) {
        try shared.appendHref(buf, allocator, pullHref(object_ref));
    } else {
        try shared.appendHref(buf, allocator, issueHref(object_ref));
    }
    try appendTemplate(buf, allocator,
        \\"><span class="issue-sidebar-row-kind">{relation}</span><span class="issue-sidebar-row-ref">
    , .{ .relation = relationshipKindLabel(kind) });
    if (std.mem.eql(u8, target.object_kind, "pull")) try buf.appendSlice(allocator, "PR ");
    try buf.append(allocator, '#');
    if (target.legacy_number > 0) {
        try std.fmt.format(buf.writer(allocator), "{d}", .{target.legacy_number});
    } else {
        try shared.appendHtml(buf, allocator, object_ref);
    }
    try appendTemplate(buf, allocator,
        \\</span><span class="issue-sidebar-row-title">{title}</span></a>
    , .{ .title = target.title });
    shown.* = true;
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
        \\SELECT p.id, p.title, COALESCE(a.number, 0)
        \\FROM pulls p
        \\LEFT JOIN legacy_aliases a
        \\  ON a.provider = 'github' AND a.object_kind = 'pull' AND a.object_id = p.id
        \\WHERE p.id = ?
    else
        \\SELECT i.id, i.title, COALESCE(a.number, 0)
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
        .legacy_number = stmt.columnInt64(2),
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
        createIssueProjectEvent(allocator, issue_id, project_value, column_value, add) catch {
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
    const body_owned = (try formValueOwned(allocator, form_body, "body")) orelse try allocator.dupe(u8, "");
    defer allocator.free(body_owned);

    const body = std.mem.trim(u8, body_owned, " \t\r\n");
    if (body.len == 0) {
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

    const sql = try issueListSql(std.testing.allocator, filters);
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

test "web issue titles come from issue opened subjects" {
    try std.testing.expectEqualStrings("Indexed issue", issueTitleFromSubject("issue.opened #018f000 Indexed issue"));
    try std.testing.expectEqualStrings("custom subject", issueTitleFromSubject("custom subject"));
}
