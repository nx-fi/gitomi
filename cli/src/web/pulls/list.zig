const std = @import("std");
const index = @import("../../index.zig");
const repo_mod = @import("../../repo.zig");
const util = @import("../../util.zig");
const work_items = @import("../../work_items.zig");
const issues_page = @import("../issues.zig");
const shared = @import("../shared.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const SqliteDb = index.SqliteDb;
const appendEmptyState = shared.appendEmptyState;
const appendRelativeTime = shared.appendRelativeTime;
const appendShellEnd = shared.appendShellEnd;
const appendShellStart = shared.appendShellStart;
const appendTemplate = shared.appendTemplate;
const pullHref = shared.pullHref;
const sqlite = index.sqlite;

const PullStateFilter = work_items.PullStateFilter;
const PullFilters = work_items.PullListOptions;
const PullCounts = work_items.PullCounts;
const PullSort = work_items.PullSort;

const pulls_default_page_size = 25;
const pulls_max_page_size = 100;

const PullFilterKind = enum {
    author,
    label,
    reviewer,
    assignee,
};

const PullHrefOverride = struct {
    state: ?PullStateFilter = null,
    sort: ?PullSort = null,
    param_name: ?[]const u8 = null,
    param_value: ?[]const u8 = null,
    page: ?usize = null,
    per_page: ?usize = null,
};

pub fn renderPullsPage(allocator: Allocator, repo: Repo, target: []const u8) ![]u8 {
    if (try shared.renderIndexingPageIfStale(allocator, repo, "Pull Requests", "pulls", target)) |body| return body;
    try index.ensureIndex(allocator, repo);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var legacy_links = shared.loadLegacyRemoteLinks(allocator, repo);
    defer legacy_links.deinit(allocator);

    const requested_filter = try pullStateFilterFromTarget(allocator, target);
    const counts = try work_items.loadPullCounts(&db);
    var filters = try pullFiltersFromTarget(allocator, target, requested_filter orelse .open);
    defer pullFiltersDeinit(allocator, &filters);
    const pagination = try shared.paginationFromTarget(allocator, target, pulls_default_page_size, pulls_max_page_size);
    filters.limit = pagination.queryLimit();
    filters.offset = pagination.offset();

    try appendShellStart(&buf, allocator, repo, "Pull Requests", "pulls");
    try appendPullsToolbar(&buf, allocator, filters);
    try buf.appendSlice(allocator, "<section class=\"panel pulls-panel\">");
    try appendPullsListHeader(&buf, allocator, &db, filters, counts);

    var stmt = try work_items.preparePullListStmt(allocator, &db, filters);
    defer stmt.deinit();
    var local_display_identity = try shared.loadLocalDisplayIdentity(allocator);
    defer local_display_identity.deinit();

    var shown: usize = 0;
    var has_next_page = false;
    while (try stmt.step()) {
        if (shown >= pagination.per_page) {
            has_next_page = true;
            break;
        }
        const row = try work_items.pullListRowFromStmt(allocator, &stmt);
        defer row.deinit(allocator);
        const task_summary = shared.markdownTaskSummary(row.body);
        const author = local_display_identity.displayNameFor(row.author);
        try appendPullListRow(&buf, allocator, &db, &legacy_links, row.id, row.title, row.state, author, row.author_avatar_url, row.opened_at, row.state_at, row.base_ref, row.head_ref, row.draft, row.comment_count, task_summary);
        shown += 1;
    }

    if (shown == 0) {
        if (pagination.page > 1) {
            try appendEmptyState(&buf, allocator, "No pull requests on this page.", "Use the previous page or change filters to return to matching pull requests.");
        } else if (work_items.hasRestrictivePullFilters(filters)) {
            try appendEmptyState(&buf, allocator, "No matching pull requests.", "Change or clear filters to widen the pull request list.");
        } else switch (filters.state) {
            .open => try appendEmptyState(&buf, allocator, "No open pull requests.", "Create a pull request from a branch with proposed changes."),
            .merged => try appendEmptyState(&buf, allocator, "No merged pull requests.", "Merged pull requests will appear here after a pull.merged event is accepted."),
            .closed => try appendEmptyState(&buf, allocator, "No closed pull requests.", "Closed pull requests are pull requests that were closed without being merged."),
            .all => try appendEmptyState(&buf, allocator, "No pull requests yet.", "Open the first pull request from the web UI or with gt pr create."),
        }
    }

    if (shown != 0 or pagination.page > 1) {
        try appendPullsPagination(&buf, allocator, filters, pagination, shown, has_next_page);
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

    filters.author = try queryTextFilterOwned(allocator, target, "author");
    filters.label = try queryTextFilterOwned(allocator, target, "label");
    filters.assignee = try queryTextFilterOwned(allocator, target, "assignee");
    filters.reviewer = try queryTextFilterOwned(allocator, target, "reviewer");
    filters.base = try queryTextFilterOwned(allocator, target, "base");
    filters.head = try queryTextFilterOwned(allocator, target, "head");
    filters.sort = try pullSortFromTarget(allocator, target);

    if (try queryTextFilterOwned(allocator, target, "q")) |query| {
        defer allocator.free(query);
        var parsed = try work_items.parsePullSearchQuery(allocator, query);
        defer parsed.deinit(allocator);
        if (parsed.state) |state| filters.state = state;
        if (parsed.sort) |sort| filters.sort = sort;
        takePullFilterValue(allocator, &filters.q, &parsed.q);
        takePullFilterValue(allocator, &filters.author, &parsed.author);
        takePullFilterValue(allocator, &filters.label, &parsed.label);
        takePullFilterValue(allocator, &filters.assignee, &parsed.assignee);
        takePullFilterValue(allocator, &filters.reviewer, &parsed.reviewer);
        takePullFilterValue(allocator, &filters.base, &parsed.base);
        takePullFilterValue(allocator, &filters.head, &parsed.head);
    }
    return filters;
}

fn pullSortFromTarget(allocator: Allocator, target: []const u8) !PullSort {
    const sort_value = try queryValueOwned(allocator, target, "sort");
    defer if (sort_value) |value| allocator.free(value);
    const value = sort_value orelse return .newest;
    return work_items.pullSortFromValue(value) orelse .newest;
}

fn pullFiltersDeinit(allocator: Allocator, filters: *PullFilters) void {
    if (filters.q) |query| allocator.free(query);
    if (filters.author) |value| allocator.free(value);
    if (filters.label) |value| allocator.free(value);
    if (filters.assignee) |value| allocator.free(value);
    if (filters.reviewer) |value| allocator.free(value);
    if (filters.base) |value| allocator.free(value);
    if (filters.head) |value| allocator.free(value);
}

fn takePullFilterValue(allocator: Allocator, slot: *?[]const u8, source: *?[]u8) void {
    if (source.*) |value| {
        if (slot.*) |previous| allocator.free(previous);
        slot.* = value;
        source.* = null;
    }
}

fn appendPullsToolbar(buf: *std.ArrayList(u8), allocator: Allocator, filters: PullFilters) !void {
    const query = try pullSearchInputValue(allocator, filters);
    defer allocator.free(query);
    try appendTemplate(buf, allocator,
        \\<div class="pulls-toolbar issues-toolbar">
        \\  <form class="issues-search" action="/pulls" method="get">
        \\    <span class="issues-search-icon" aria-hidden="true"></span>
        \\    <input type="search" name="q" value="{query}" aria-label="Search pull requests">
        \\  </form>
        \\  <div class="issues-toolbar-actions">
        \\    <a class="button secondary issue-tool-button" href="/settings/labels"><span class="button-icon icon-labels" aria-hidden="true"></span><span>Labels</span></a>
        \\    <a class="button secondary issue-tool-button" href="/milestones"><span class="button-icon icon-milestones" aria-hidden="true"></span><span>Milestones</span></a>
        \\    <a class="button primary" href="/new-pull">New pull request</a>
        \\  </div>
        \\</div>
    , .{
        .query = query,
    });
}

fn pullSearchInputValue(allocator: Allocator, filters: PullFilters) ![]u8 {
    return work_items.pullFilterQueryOwned(allocator, filters);
}

fn appendPullsListHeader(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, filters: PullFilters, counts: PullCounts) !void {
    try buf.appendSlice(allocator,
        \\<header class="pulls-list-head issues-list-head">
        \\  <div class="issues-select-all"><input type="checkbox" aria-label="Select all pull requests" disabled></div>
        \\  <nav class="issues-state-tabs" aria-label="Pull request state">
    );
    try appendPullStateTab(buf, allocator, "Open", counts.open, .open, filters, pullStateIconClass(.open));
    try appendPullStateTab(buf, allocator, "Merged", counts.merged, .merged, filters, pullStateIconClass(.merged));
    try appendPullStateTab(buf, allocator, "Closed", counts.closed, .closed, filters, pullStateIconClass(.closed));
    try buf.appendSlice(allocator,
        \\  </nav>
        \\  <div class="issues-filter-menus">
    );
    try appendPullFilterMenu(buf, allocator, db, filters, .author);
    try appendPullFilterMenu(buf, allocator, db, filters, .label);
    try appendPullFilterMenu(buf, allocator, db, filters, .reviewer);
    try appendPullFilterMenu(buf, allocator, db, filters, .assignee);
    try appendPullSortMenu(buf, allocator, filters);
    try buf.appendSlice(allocator,
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
    try appendPullsHref(buf, allocator, filters, .{ .state = tab_filter });
    try appendTemplate(buf, allocator,
        \\"><span class="issue-tab-icon {icon_class}" aria-hidden="true"></span><span>{label}</span><span class="issue-count-badge">{count}</span></a>
    , .{
        .icon_class = icon_class,
        .label = label,
        .count = count,
    });
}

fn pullStateIconClass(state: PullStateFilter) []const u8 {
    return switch (state) {
        .open, .all => "pull-open-icon",
        .merged => "pull-merged-icon",
        .closed => "pull-closed-icon",
    };
}

fn appendPullFilterMenu(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    filters: PullFilters,
    kind: PullFilterKind,
) !void {
    const active = pullFilterValue(filters, kind);
    try appendTemplate(buf, allocator,
        \\<details{classes} data-popover-menu><summary>{label}
    , .{
        .classes = shared.classAttr("issues-filter-menu", &.{shared.class("active", active != null)}),
        .label = pullFilterLabel(kind),
    });
    if (active) |value| {
        try appendTemplate(buf, allocator, ": {value}", .{ .value = value });
    }
    try buf.appendSlice(allocator,
        \\</summary><div class="issues-filter-popover" role="menu">
    );
    try appendPullFilterMenuLink(buf, allocator, filters, kind, null, pullFilterAllLabel(kind), null, active == null);

    var stmt = try db.prepare(pullFilterOptionsSql(kind));
    defer stmt.deinit();
    var shown = false;
    while (try stmt.step()) {
        const value = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(value);
        const count = @as(usize, @intCast(stmt.columnInt64(1)));
        try appendPullFilterMenuLink(
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

fn appendPullFilterMenuLink(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    filters: PullFilters,
    kind: PullFilterKind,
    value: ?[]const u8,
    label: []const u8,
    count: ?usize,
    selected: bool,
) !void {
    try appendTemplate(buf, allocator,
        \\<a class="{classes}" role="menuitem" href="
    , .{ .classes = shared.classes("issues-filter-option", &.{shared.class("selected", selected)}) });
    try appendPullsHref(buf, allocator, filters, .{
        .param_name = pullFilterParamName(kind),
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

fn appendPullSortMenu(buf: *std.ArrayList(u8), allocator: Allocator, filters: PullFilters) !void {
    try appendTemplate(buf, allocator,
        \\<details{classes} data-popover-menu><summary>{label}</summary><div class="issues-filter-popover" role="menu">
    , .{
        .classes = shared.classAttr("issues-filter-menu", &.{shared.class("active", filters.sort != .newest)}),
        .label = pullSortLabel(filters.sort),
    });
    try appendPullSortMenuLink(buf, allocator, filters, .newest);
    try appendPullSortMenuLink(buf, allocator, filters, .oldest);
    try appendPullSortMenuLink(buf, allocator, filters, .updated);
    try buf.appendSlice(allocator, "</div></details>");
}

fn appendPullSortMenuLink(buf: *std.ArrayList(u8), allocator: Allocator, filters: PullFilters, sort: PullSort) !void {
    try appendTemplate(buf, allocator,
        \\<a class="{classes}" role="menuitem" href="
    , .{ .classes = shared.classes("issues-filter-option", &.{shared.class("selected", filters.sort == sort)}) });
    try appendPullsHref(buf, allocator, filters, .{ .sort = sort });
    try appendTemplate(buf, allocator,
        \\"><span>{label}</span></a>
    , .{ .label = pullSortLabel(sort) });
}

fn pullFilterValue(filters: PullFilters, kind: PullFilterKind) ?[]const u8 {
    return switch (kind) {
        .author => filters.author,
        .label => filters.label,
        .reviewer => filters.reviewer,
        .assignee => filters.assignee,
    };
}

fn pullFilterLabel(kind: PullFilterKind) []const u8 {
    return switch (kind) {
        .author => "Author",
        .label => "Labels",
        .reviewer => "Reviewers",
        .assignee => "Assignees",
    };
}

fn pullFilterAllLabel(kind: PullFilterKind) []const u8 {
    return switch (kind) {
        .author => "Any author",
        .label => "Any label",
        .reviewer => "Any reviewer",
        .assignee => "Anyone",
    };
}

fn pullFilterParamName(kind: PullFilterKind) []const u8 {
    return switch (kind) {
        .author => "author",
        .label => "label",
        .reviewer => "reviewer",
        .assignee => "assignee",
    };
}

fn pullSortLabel(sort: PullSort) []const u8 {
    return switch (sort) {
        .newest => "Newest",
        .oldest => "Oldest",
        .updated => "Recently updated",
    };
}

fn pullFilterOptionsSql(kind: PullFilterKind) []const u8 {
    return switch (kind) {
        .author =>
        \\SELECT author, COUNT(*)
        \\FROM (
        \\  SELECT p.id, COALESCE(NULLIF(pm.source_author, ''), NULLIF(sp.display_name, ''), p.author_principal) AS author
        \\  FROM pulls p
        \\  LEFT JOIN pull_metadata pm ON pm.pull_id = p.id
        \\  LEFT JOIN identities sp ON sp.id = pm.source_identity
        \\)
        \\WHERE author <> ''
        \\GROUP BY author
        \\ORDER BY lower(author), author
        ,
        .label =>
        \\SELECT pl.label, COUNT(DISTINCT pl.pull_id)
        \\FROM pull_labels pl
        \\LEFT JOIN label_definitions ld ON ld.name = pl.label
        \\GROUP BY pl.label
        \\ORDER BY CASE WHEN MAX(ld.id) IS NULL THEN 1 ELSE 0 END,
        \\         MIN(ld.priority),
        \\         lower(pl.label),
        \\         pl.label
        ,
        .reviewer =>
        \\SELECT reviewer, COUNT(DISTINCT pull_id)
        \\FROM pull_reviewers
        \\GROUP BY reviewer
        \\ORDER BY lower(reviewer), reviewer
        ,
        .assignee =>
        \\SELECT assignee, COUNT(DISTINCT pull_id)
        \\FROM pull_assignees
        \\GROUP BY assignee
        \\ORDER BY lower(assignee), assignee
        ,
    };
}

fn appendPullsHref(buf: *std.ArrayList(u8), allocator: Allocator, filters: PullFilters, override: PullHrefOverride) !void {
    try buf.appendSlice(allocator, "/pulls");
    var first = true;
    try shared.appendQueryParam(buf, allocator, &first, "state", work_items.pullStateValue(override.state orelse filters.state));
    if (pullHrefValue(filters, override, "q")) |value| try shared.appendQueryParam(buf, allocator, &first, "q", value);
    if (pullHrefValue(filters, override, "author")) |value| try shared.appendQueryParam(buf, allocator, &first, "author", value);
    if (pullHrefValue(filters, override, "label")) |value| try shared.appendQueryParam(buf, allocator, &first, "label", value);
    if (pullHrefValue(filters, override, "assignee")) |value| try shared.appendQueryParam(buf, allocator, &first, "assignee", value);
    if (pullHrefValue(filters, override, "reviewer")) |value| try shared.appendQueryParam(buf, allocator, &first, "reviewer", value);
    if (pullHrefValue(filters, override, "base")) |value| try shared.appendQueryParam(buf, allocator, &first, "base", value);
    if (pullHrefValue(filters, override, "head")) |value| try shared.appendQueryParam(buf, allocator, &first, "head", value);

    const sort = override.sort orelse filters.sort;
    if (sort != .newest) try shared.appendQueryParam(buf, allocator, &first, "sort", work_items.pullSortValue(sort));
    if (override.page) |page| {
        const pagination = shared.Pagination{
            .page = page,
            .per_page = override.per_page orelse pulls_default_page_size,
        };
        try shared.appendPaginationQueryParams(buf, allocator, &first, pagination, page, pulls_default_page_size);
    }
}

fn pullHrefValue(filters: PullFilters, override: PullHrefOverride, name: []const u8) ?[]const u8 {
    if (override.param_name) |param| {
        if (std.mem.eql(u8, param, name)) return override.param_value;
    }
    if (std.mem.eql(u8, name, "q")) return filters.q;
    if (std.mem.eql(u8, name, "author")) return filters.author;
    if (std.mem.eql(u8, name, "label")) return filters.label;
    if (std.mem.eql(u8, name, "assignee")) return filters.assignee;
    if (std.mem.eql(u8, name, "reviewer")) return filters.reviewer;
    if (std.mem.eql(u8, name, "base")) return filters.base;
    if (std.mem.eql(u8, name, "head")) return filters.head;
    return null;
}

fn pullsHrefOwned(allocator: Allocator, filters: PullFilters, pagination: shared.Pagination, page: usize) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try appendPullsHref(&buf, allocator, filters, .{
        .page = page,
        .per_page = pagination.per_page,
    });
    return buf.toOwnedSlice(allocator);
}

fn appendPullsPagination(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    filters: PullFilters,
    pagination: shared.Pagination,
    shown: usize,
    has_next_page: bool,
) !void {
    const previous_href = if (pagination.page > 1) try pullsHrefOwned(allocator, filters, pagination, pagination.page - 1) else null;
    defer if (previous_href) |href| allocator.free(href);
    const next_href = if (has_next_page) try pullsHrefOwned(allocator, filters, pagination, pagination.page + 1) else null;
    defer if (next_href) |href| allocator.free(href);
    const summary = try shared.paginationSummaryOwned(allocator, pagination, shown, null);
    defer allocator.free(summary);
    try shared.appendPaginationNav(buf, allocator, "Pull request pages", summary, previous_href, next_href);
}

fn appendPullListRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    legacy_links: *const shared.LegacyRemoteLinks,
    id: []const u8,
    title: []const u8,
    state: []const u8,
    author: []const u8,
    author_avatar_url: []const u8,
    opened_at: []const u8,
    state_at: []const u8,
    base_ref: []const u8,
    head_ref: []const u8,
    draft: bool,
    comment_count: usize,
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
    try buf.appendSlice(allocator, "</div><p class=\"issue-row-meta\">");
    try shared.appendPullReferenceText(buf, allocator, pull_ref);
    var legacy_ref = try shared.loadLegacyReference(allocator, db, "pull", id);
    defer if (legacy_ref) |*value| value.deinit(allocator);
    if (legacy_ref) |value| {
        try buf.appendSlice(allocator, " / ");
        try shared.appendLegacyPullReference(buf, allocator, legacy_links, value.provider, value.number);
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
    try appendAvatar(buf, allocator, author, author_avatar_url, "issue-author-avatar");
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
            try appendAvatar(buf, allocator, value, "", "");
        }
    }
    if (shown) try buf.appendSlice(allocator, "</span>");
}

fn appendPullBranchLink(buf: *std.ArrayList(u8), allocator: Allocator, ref: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<a class="pull-branch-link" href="{href}"><code>{ref}</code></a>
    , .{
        .href = shared.codeHref(ref, ""),
        .ref = ref,
    });
}

fn appendLabel(buf: *std.ArrayList(u8), allocator: Allocator, label: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<span class="issue-label {kind}">{label}</span>
    , .{
        .kind = labelKind(label),
        .label = label,
    });
}

fn appendAvatar(buf: *std.ArrayList(u8), allocator: Allocator, name: []const u8, avatar_url: []const u8, extra_class: []const u8) !void {
    try shared.appendAvatarWithUrl(buf, allocator, name, avatar_url, extra_class);
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

test "pulls toolbar links management pages" {
    var filters = PullFilters{
        .state = .open,
    };
    defer pullFiltersDeinit(std.testing.allocator, &filters);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendPullsToolbar(&buf, std.testing.allocator, filters);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "href=\"/settings/labels\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<span>Labels</span></a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "href=\"/milestones\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<span>Milestones</span></a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Reviewers") == null);
}

test "pull state tabs use pull request icons" {
    try std.testing.expectEqualStrings("pull-open-icon", pullStateIconClass(.open));
    try std.testing.expectEqualStrings("pull-merged-icon", pullStateIconClass(.merged));
    try std.testing.expectEqualStrings("pull-closed-icon", pullStateIconClass(.closed));
}
