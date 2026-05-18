const std = @import("std");
const index = @import("../../index.zig");
const repo_mod = @import("../../repo.zig");
const shared = @import("../shared.zig");
const util = @import("../../util.zig");
const work_items = @import("../../work_items.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const SqliteDb = index.SqliteDb;
const Button = shared.Button;
const appendEmptyState = shared.appendEmptyState;
const appendRelativeTime = shared.appendRelativeTime;
const appendSectionHead = shared.appendSectionHead;
const appendShellEnd = shared.appendShellEnd;
const appendShellStart = shared.appendShellStart;
const appendTemplate = shared.appendTemplate;
const issueHref = shared.issueHref;
const literalHref = shared.literalHref;
const sqlite = index.sqlite;

const IssueStateFilter = work_items.IssueStateFilter;
const IssueCounts = work_items.IssueCounts;
const IssueSort = work_items.IssueSort;
const IssueFilters = work_items.IssueListOptions;

const issues_default_page_size = 25;
const issues_max_page_size = 100;

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
    page: ?usize = null,
    per_page: ?usize = null,
};

pub fn renderIssuesPage(allocator: Allocator, repo: Repo, target: []const u8) ![]u8 {
    if (try shared.renderIndexingPageIfStale(allocator, repo, "Issues", "issues", target)) |body| return body;
    try index.ensureIndex(allocator, repo);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var legacy_links = shared.loadLegacyRemoteLinks(allocator, repo);
    defer legacy_links.deinit(allocator);

    const requested_filter = try issueStateFilterFromTarget(allocator, target);
    const counts = try work_items.loadIssueCounts(&db);
    const default_state = requested_filter orelse if (counts.open == 0 and counts.closed > 0) IssueStateFilter.closed else IssueStateFilter.open;
    var filters = try issueFiltersFromTarget(allocator, target, default_state);
    defer filters.deinit();
    const pagination = try shared.paginationFromTarget(allocator, target, issues_default_page_size, issues_max_page_size);
    filters.limit = pagination.queryLimit();
    filters.offset = pagination.offset();

    try appendShellStart(&buf, allocator, repo, "Issues", "issues");
    try shared.appendWorkItemsLayoutStart(&buf, allocator, "issues");
    try buf.appendSlice(allocator, "<section class=\"panel issues-panel work-items-panel\">");
    try appendSectionHead(&buf, allocator, "Issues", "Issues", Button{
        .label = "New issue",
        .href = literalHref("/new-issue"),
        .kind = "primary",
    });
    try appendIssuesToolbar(&buf, allocator, &db, filters);
    try appendIssuesListHeader(&buf, allocator, filters, counts);

    var stmt = try work_items.prepareIssueListStmt(allocator, &db, filters);
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
        const row = try work_items.issueListRowFromStmt(allocator, &stmt);
        defer row.deinit(allocator);
        const task_summary = shared.markdownTaskSummary(row.body);
        const author = local_display_identity.displayNameFor(row.author);
        try appendIssueListRow(&buf, allocator, &db, &legacy_links, row.id, row.title, row.state, author, row.author_avatar_url, row.opened_at, row.state_at, row.milestone, row.issue_type, row.priority, row.comment_count, task_summary);
        shown += 1;
    }

    if (shown == 0) {
        if (pagination.page > 1) {
            try appendEmptyState(&buf, allocator, "No issues on this page.", "Use the previous page or change filters to return to matching issues.");
        } else if (work_items.hasRestrictiveIssueFilters(filters)) {
            try appendEmptyState(&buf, allocator, "No matching issues.", "Change or clear filters to widen the issue list.");
        } else switch (filters.state) {
            .open => try appendEmptyState(&buf, allocator, "No open issues.", "Closed issues are available from the Closed tab."),
            .closed => try appendEmptyState(&buf, allocator, "No closed issues.", "Open issues are available from the Open tab."),
            .all => try appendEmptyState(&buf, allocator, "No issues yet.", "Create the first local issue from this browser UI or with gt issue open."),
        }
    }

    if (shown != 0 or pagination.page > 1) {
        try appendIssuesPagination(&buf, allocator, filters, pagination, shown, has_next_page);
    }

    try buf.appendSlice(allocator, "</section>");
    try shared.appendWorkItemsLayoutEnd(&buf, allocator);
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

    filters.author = try queryTextFilterOwned(allocator, target, "author");
    filters.label = try queryTextFilterOwned(allocator, target, "label");
    filters.project = try queryTextFilterOwned(allocator, target, "project");
    filters.milestone = try queryTextFilterOwned(allocator, target, "milestone");
    filters.assignee = try queryTextFilterOwned(allocator, target, "assignee");
    filters.sort = try issueSortFromTarget(allocator, target);

    if (try queryTextFilterOwned(allocator, target, "q")) |query| {
        defer allocator.free(query);
        var parsed = try work_items.parseIssueSearchQuery(allocator, query);
        defer parsed.deinit(allocator);
        if (parsed.state) |state| filters.state = state;
        if (parsed.sort) |sort| filters.sort = sort;
        takeIssueFilterValue(&filters, &filters.q, &parsed.q);
        takeIssueFilterValue(&filters, &filters.author, &parsed.author);
        takeIssueFilterValue(&filters, &filters.label, &parsed.label);
        takeIssueFilterValue(&filters, &filters.project, &parsed.project);
        takeIssueFilterValue(&filters, &filters.milestone, &parsed.milestone);
        takeIssueFilterValue(&filters, &filters.assignee, &parsed.assignee);
    }
    return filters;
}

fn takeIssueFilterValue(filters: *IssueFilters, slot: *?[]u8, source: *?[]u8) void {
    if (source.*) |value| {
        if (slot.*) |previous| filters.allocator.free(previous);
        slot.* = value;
        source.* = null;
    }
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

fn appendIssuesToolbar(buf: *std.ArrayList(u8), allocator: Allocator, db: ?*SqliteDb, filters: IssueFilters) !void {
    const query = filters.q orelse "";
    try appendTemplate(buf, allocator,
        \\<div class="issues-toolbar work-items-toolbar">
        \\  <form class="issues-search" action="/issues" method="get">
        \\    <span class="issues-search-icon" aria-hidden="true"></span>
        \\    <input type="search" name="q" value="{query}" placeholder="Search issues" aria-label="Search issues">
    , .{
        .query = query,
    });
    try appendHiddenIssueSearchFilters(buf, allocator, filters);
    try buf.appendSlice(allocator,
        \\  </form>
    );
    if (db) |database| {
        try buf.appendSlice(allocator,
            \\  <div class="work-items-toolbar-actions">
        );
        try appendIssueFiltersPopover(buf, allocator, database, filters);
        try buf.appendSlice(allocator,
            \\  </div>
        );
    }
    try appendIssueSearchChips(buf, allocator, filters);
    try buf.appendSlice(allocator,
        \\</div>
    );
}

fn appendIssuesListHeader(buf: *std.ArrayList(u8), allocator: Allocator, filters: IssueFilters, counts: IssueCounts) !void {
    try buf.appendSlice(allocator,
        \\<header class="issues-list-head">
        \\  <nav class="issues-state-tabs" aria-label="Issue state">
    );
    try appendIssueStateTab(buf, allocator, "Open", counts.open, .open, filters, "issue-open-icon");
    try appendIssueStateTab(buf, allocator, "Closed", counts.closed, .closed, filters, "issue-closed-icon");
    try buf.appendSlice(allocator,
        \\  </nav>
        \\</header>
    );
}

fn appendHiddenIssueSearchFilters(buf: *std.ArrayList(u8), allocator: Allocator, filters: IssueFilters) !void {
    try appendHiddenIssueFilter(buf, allocator, "state", work_items.issueStateValue(filters.state));
    try appendHiddenIssueFilter(buf, allocator, "author", filters.author);
    try appendHiddenIssueFilter(buf, allocator, "label", filters.label);
    try appendHiddenIssueFilter(buf, allocator, "project", filters.project);
    try appendHiddenIssueFilter(buf, allocator, "milestone", filters.milestone);
    try appendHiddenIssueFilter(buf, allocator, "assignee", filters.assignee);
    if (filters.sort != .newest) try appendHiddenIssueFilter(buf, allocator, "sort", work_items.issueSortValue(filters.sort));
}

fn appendHiddenIssueFilter(buf: *std.ArrayList(u8), allocator: Allocator, name: []const u8, value: ?[]const u8) !void {
    const filter_value = value orelse return;
    try appendTemplate(buf, allocator,
        \\    <input type="hidden" name="{name}" value="{value}">
    , .{
        .name = name,
        .value = filter_value,
    });
}

fn appendIssueSearchChips(buf: *std.ArrayList(u8), allocator: Allocator, filters: IssueFilters) !void {
    if (!hasIssueSearchChips(filters)) return;
    try buf.appendSlice(allocator, "<div class=\"work-item-search-chips\" aria-label=\"Active filters\">");
    if (filters.state == .all) {
        try appendIssueStateChip(buf, allocator, filters, "State", issueStateFilterLabel(.all), .open);
    }
    if (filters.author) |value| try appendIssueFilterChip(buf, allocator, filters, "Author", value, "author");
    if (filters.label) |value| try appendIssueFilterChip(buf, allocator, filters, "Label", value, "label");
    if (filters.project) |value| try appendIssueFilterChip(buf, allocator, filters, "Project", value, "project");
    if (filters.milestone) |value| try appendIssueFilterChip(buf, allocator, filters, "Milestone", value, "milestone");
    if (filters.assignee) |value| try appendIssueFilterChip(buf, allocator, filters, "Assignee", value, "assignee");
    if (filters.sort != .newest) try appendIssueSortChip(buf, allocator, filters);
    try buf.appendSlice(allocator, "</div>");
}

fn hasIssueSearchChips(filters: IssueFilters) bool {
    return filters.state == .all or
        filters.author != null or
        filters.label != null or
        filters.project != null or
        filters.milestone != null or
        filters.assignee != null or
        filters.sort != .newest;
}

fn appendIssueFilterChip(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    filters: IssueFilters,
    label: []const u8,
    value: []const u8,
    param_name: []const u8,
) !void {
    try appendTemplate(buf, allocator,
        \\<a class="work-item-search-chip" href="
    , .{});
    try appendIssuesHref(buf, allocator, filters, .{
        .param_name = param_name,
        .param_value = null,
    });
    try appendTemplate(buf, allocator,
        \\"><span>{label}</span><strong>{value}</strong><span class="work-item-search-chip-remove" aria-hidden="true"></span></a>
    , .{
        .label = label,
        .value = value,
    });
}

fn appendIssueStateChip(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    filters: IssueFilters,
    label: []const u8,
    value: []const u8,
    clear_state: IssueStateFilter,
) !void {
    try appendTemplate(buf, allocator,
        \\<a class="work-item-search-chip" href="
    , .{});
    try appendIssuesHref(buf, allocator, filters, .{ .state = clear_state });
    try appendTemplate(buf, allocator,
        \\"><span>{label}</span><strong>{value}</strong><span class="work-item-search-chip-remove" aria-hidden="true"></span></a>
    , .{
        .label = label,
        .value = value,
    });
}

fn appendIssueSortChip(buf: *std.ArrayList(u8), allocator: Allocator, filters: IssueFilters) !void {
    try appendTemplate(buf, allocator,
        \\<a class="work-item-search-chip" href="
    , .{});
    try appendIssuesHref(buf, allocator, filters, .{ .sort = .newest });
    try appendTemplate(buf, allocator,
        \\"><span>Sort</span><strong>{value}</strong><span class="work-item-search-chip-remove" aria-hidden="true"></span></a>
    , .{ .value = issueSortLabel(filters.sort) });
}

fn appendIssueFiltersPopover(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, filters: IssueFilters) !void {
    try appendTemplate(buf, allocator,
        \\<details{classes} data-popover-menu><summary><span class="button-icon icon-filter" aria-hidden="true"></span><span>Filters</span></summary><div class="issues-filter-popover work-items-filter-popover" role="menu">
    , .{
        .classes = shared.classAttr("issues-filter-menu work-items-filter-menu", &.{shared.class("active", hasIssueSearchChips(filters))}),
    });
    try appendIssueStateFilterSection(buf, allocator, filters);
    try appendIssueFilterSection(buf, allocator, db, filters, .author);
    try appendIssueFilterSection(buf, allocator, db, filters, .label);
    try appendIssueFilterSection(buf, allocator, db, filters, .project);
    try appendIssueFilterSection(buf, allocator, db, filters, .milestone);
    try appendIssueFilterSection(buf, allocator, db, filters, .assignee);
    try appendIssueSortFilterSection(buf, allocator, filters);
    try buf.appendSlice(allocator, "</div></details>");
}

fn appendIssueStateFilterSection(buf: *std.ArrayList(u8), allocator: Allocator, filters: IssueFilters) !void {
    try buf.appendSlice(allocator, "<section class=\"work-items-filter-section\"><span class=\"work-items-filter-section-title\">State</span>");
    try appendIssueStateMenuLink(buf, allocator, filters, .open);
    try appendIssueStateMenuLink(buf, allocator, filters, .closed);
    try appendIssueStateMenuLink(buf, allocator, filters, .all);
    try buf.appendSlice(allocator, "</section>");
}

fn appendIssueStateMenuLink(buf: *std.ArrayList(u8), allocator: Allocator, filters: IssueFilters, state: IssueStateFilter) !void {
    try appendTemplate(buf, allocator,
        \\<a class="{classes}" role="menuitem" href="
    , .{ .classes = shared.classes("issues-filter-option", &.{shared.class("selected", filters.state == state)}) });
    try appendIssuesHref(buf, allocator, filters, .{ .state = state });
    try appendTemplate(buf, allocator,
        \\"><span>{label}</span></a>
    , .{ .label = issueStateFilterLabel(state) });
}

fn appendIssueFilterSection(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    filters: IssueFilters,
    kind: IssueFilterKind,
) !void {
    const active = issueFilterValue(filters, kind);
    try appendTemplate(buf, allocator,
        \\<section class="work-items-filter-section"><span class="work-items-filter-section-title">{label}</span>
    , .{ .label = issueFilterLabel(kind) });
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
    try buf.appendSlice(allocator, "</section>");
}

fn appendIssueSortFilterSection(buf: *std.ArrayList(u8), allocator: Allocator, filters: IssueFilters) !void {
    try buf.appendSlice(allocator, "<section class=\"work-items-filter-section\"><span class=\"work-items-filter-section-title\">Sort</span>");
    try appendIssueSortMenuLink(buf, allocator, filters, .newest);
    try appendIssueSortMenuLink(buf, allocator, filters, .oldest);
    try appendIssueSortMenuLink(buf, allocator, filters, .updated);
    try buf.appendSlice(allocator, "</section>");
}

fn issueStateFilterLabel(state: IssueStateFilter) []const u8 {
    return switch (state) {
        .open => "Open",
        .closed => "Closed",
        .all => "All",
    };
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
        \\  SELECT i.id, COALESCE(NULLIF(m.source_author, ''), NULLIF(si.display_name, ''), i.author_principal) AS author
        \\  FROM issues i
        \\  LEFT JOIN issue_metadata m ON m.issue_id = i.id
        \\  LEFT JOIN identities si ON si.id = m.source_identity
        \\)
        \\WHERE author <> ''
        \\GROUP BY author
        \\ORDER BY lower(author), author
        ,
        .label =>
        \\SELECT il.label, COUNT(DISTINCT il.issue_id)
        \\FROM issue_labels il
        \\LEFT JOIN label_definitions ld ON ld.name = il.label
        \\GROUP BY il.label
        \\ORDER BY CASE WHEN MAX(ld.id) IS NULL THEN 1 ELSE 0 END,
        \\         MIN(ld.priority),
        \\         lower(il.label),
        \\         il.label
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
    try shared.appendQueryParam(buf, allocator, &first, "state", work_items.issueStateValue(override.state orelse filters.state));
    if (filterHrefValue(filters, override, "q")) |value| try shared.appendQueryParam(buf, allocator, &first, "q", value);
    if (filterHrefValue(filters, override, "author")) |value| try shared.appendQueryParam(buf, allocator, &first, "author", value);
    if (filterHrefValue(filters, override, "label")) |value| try shared.appendQueryParam(buf, allocator, &first, "label", value);
    if (filterHrefValue(filters, override, "project")) |value| try shared.appendQueryParam(buf, allocator, &first, "project", value);
    if (filterHrefValue(filters, override, "milestone")) |value| try shared.appendQueryParam(buf, allocator, &first, "milestone", value);
    if (filterHrefValue(filters, override, "assignee")) |value| try shared.appendQueryParam(buf, allocator, &first, "assignee", value);

    const sort = override.sort orelse filters.sort;
    if (sort != .newest) try shared.appendQueryParam(buf, allocator, &first, "sort", work_items.issueSortValue(sort));
    if (override.page) |page| {
        const pagination = shared.Pagination{
            .page = page,
            .per_page = override.per_page orelse issues_default_page_size,
        };
        try shared.appendPaginationQueryParams(buf, allocator, &first, pagination, page, issues_default_page_size);
    }
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

fn issuesHrefOwned(allocator: Allocator, filters: IssueFilters, pagination: shared.Pagination, page: usize) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try appendIssuesHref(&buf, allocator, filters, .{
        .page = page,
        .per_page = pagination.per_page,
    });
    return buf.toOwnedSlice(allocator);
}

fn appendIssuesPagination(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    filters: IssueFilters,
    pagination: shared.Pagination,
    shown: usize,
    has_next_page: bool,
) !void {
    const previous_href = if (pagination.page > 1) try issuesHrefOwned(allocator, filters, pagination, pagination.page - 1) else null;
    defer if (previous_href) |href| allocator.free(href);
    const next_href = if (has_next_page) try issuesHrefOwned(allocator, filters, pagination, pagination.page + 1) else null;
    defer if (next_href) |href| allocator.free(href);
    const summary = try shared.paginationSummaryOwned(allocator, pagination, shown, null);
    defer allocator.free(summary);
    try shared.appendPaginationNav(buf, allocator, "Issues pages", summary, previous_href, next_href);
}

fn appendIssueListRow(
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
    milestone: []const u8,
    issue_type: []const u8,
    priority: []const u8,
    comment_count: usize,
    task_summary: shared.MarkdownTaskSummary,
) !void {
    var issue_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const issue_ref = util.shortObjectRef(&issue_ref_buf, id);
    const closed = std.mem.eql(u8, state, "closed");
    try appendTemplate(buf, allocator,
        \\<article class="issue-list-row is-{state}">
        \\  <div class="issue-state-cell"><span class="issue-state-icon {state}" title="{state}" aria-label="{state}"></span></div>
        \\  <div class="issue-row-content">
        \\    <div class="issue-row-title-line"><a class="issue-row-title" href="{href}">{title}</a>
    , .{
        .state = state,
        .href = issueHref(issue_ref),
        .title = title,
    });
    try appendIssueRowType(buf, allocator, issue_type);
    try appendIssueRowPriority(buf, allocator, priority);
    try appendIssueRowRelationshipBadges(buf, allocator, db, id);
    try appendIssueRowLabels(buf, allocator, db, id);
    try buf.appendSlice(allocator, "</div><p class=\"issue-row-meta\">");
    try shared.appendIssueReferenceText(buf, allocator, issue_ref);
    var legacy_ref = try shared.loadLegacyReference(allocator, db, "issue", id);
    defer if (legacy_ref) |*value| value.deinit(allocator);
    if (legacy_ref) |value| {
        try buf.appendSlice(allocator, " / ");
        try shared.appendLegacyIssueReference(buf, allocator, legacy_links, value.provider, value.number);
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
    try shared.appendAvatarWithUrl(buf, allocator, author, author_avatar_url, "issue-author-avatar");
    try buf.appendSlice(allocator,
        \\  </div>
        \\</article>
    );
}

fn appendIssueRowLabels(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, issue_id: []const u8) !void {
    var stmt = try db.prepare(
        \\SELECT selected.label, COALESCE(ld.color, '')
        \\FROM (SELECT DISTINCT label FROM issue_labels WHERE issue_id = ?) AS selected
        \\LEFT JOIN label_definitions ld ON ld.name = selected.label
        \\ORDER BY CASE WHEN ld.id IS NULL THEN 1 ELSE 0 END,
        \\         ld.priority,
        \\         lower(selected.label),
        \\         selected.label
    );
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    var shown = false;
    while (try stmt.step()) {
        const label = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(label);
        const color = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(color);
        if (!shown) {
            try buf.appendSlice(allocator, "<span class=\"issue-row-labels\">");
            shown = true;
        }
        try appendIssueLabel(buf, allocator, label, color);
    }
    if (shown) try buf.appendSlice(allocator, "</span>");
}

fn appendIssueRowType(buf: *std.ArrayList(u8), allocator: Allocator, issue_type: []const u8) !void {
    if (issue_type.len == 0) return;
    try appendTemplate(buf, allocator,
        \\<span class="issue-row-type issue-row-type-{kind}" title="Type: {label}" aria-label="Type: {label}"><span class="issue-type-dot issue-type-{kind}" aria-hidden="true"></span>{label}</span>
    , .{
        .kind = issue_type,
        .label = issueTypeLabel(issue_type),
    });
}

fn appendIssueRowPriority(buf: *std.ArrayList(u8), allocator: Allocator, priority: []const u8) !void {
    if (priority.len == 0) return;
    try appendTemplate(buf, allocator,
        \\<span class="issue-row-priority issue-row-priority-{tone}" title="Priority: {priority}" aria-label="Priority: {priority}">{priority}</span>
    , .{
        .tone = priorityTone(priority),
        .priority = priority,
    });
}

fn appendIssueRowRelationshipBadges(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, issue_id: []const u8) !void {
    if (try hasBlockingIssue(db, issue_id)) {
        try buf.appendSlice(allocator, "<span class=\"issue-row-relationship-badge is-blocked\" title=\"Blocked by another issue\">Blocked</span>");
    }

    var stmt = try db.prepare(
        \\SELECT COUNT(DISTINCT child.id),
        \\       SUM(CASE WHEN child.state = 'closed' THEN 1 ELSE 0 END)
        \\FROM issue_relationships r
        \\JOIN issues child ON child.id = r.source_issue_id
        \\WHERE r.target_issue_id = ?
        \\  AND r.relationship = 'parent'
    );
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    if (!(try stmt.step())) return;
    const total = stmt.columnInt64(0);
    if (total <= 0) return;
    const done = stmt.columnInt64(1);
    try appendTemplate(buf, allocator,
        \\<span class="issue-row-relationship-badge" title="Sub-issues">{done} / {total}</span>
    , .{
        .done = done,
        .total = total,
    });
}

fn hasBlockingIssue(db: *SqliteDb, issue_id: []const u8) !bool {
    var stmt = try db.prepare(
        \\SELECT 1
        \\FROM issue_relationships r
        \\JOIN issues blocker ON blocker.id = r.source_issue_id
        \\WHERE r.target_issue_id = ?
        \\  AND r.relationship = 'blocks'
        \\  AND blocker.state = 'open'
        \\LIMIT 1
    );
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    return try stmt.step();
}

fn appendIssueLabel(buf: *std.ArrayList(u8), allocator: Allocator, label: []const u8, color: []const u8) !void {
    if (validHexColor(color)) {
        try appendTemplate(buf, allocator,
            \\<span class="issue-label label-custom" style="--label-color: {color}">{label}</span>
        , .{
            .color = color,
            .label = label,
        });
        return;
    }

    try appendTemplate(buf, allocator,
        \\<span class="issue-label {kind}">{label}</span>
    , .{
        .kind = issueLabelKind(label),
        .label = label,
    });
}

fn validHexColor(value: []const u8) bool {
    if (value.len != 7 or value[0] != '#') return false;
    for (value[1..]) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
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
        try shared.appendAvatar(buf, allocator, assignee, "");
    }
    if (shown) try buf.appendSlice(allocator, "</span>");
}

fn issueSortLabel(sort: IssueSort) []const u8 {
    return switch (sort) {
        .newest => "Newest",
        .oldest => "Oldest",
        .updated => "Recently updated",
    };
}

fn issueTypeLabel(issue_type: []const u8) []const u8 {
    if (std.mem.eql(u8, issue_type, "bug")) return "Bug";
    if (std.mem.eql(u8, issue_type, "feature")) return "Feature";
    if (std.mem.eql(u8, issue_type, "task")) return "Task";
    return issue_type;
}

fn priorityTone(priority: []const u8) []const u8 {
    if (std.mem.eql(u8, priority, "P0")) return "p0";
    if (std.mem.eql(u8, priority, "P1")) return "p1";
    if (std.mem.eql(u8, priority, "P2")) return "p2";
    if (std.mem.eql(u8, priority, "P3")) return "p3";
    return "none";
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

fn percentDecodeForm(allocator: Allocator, value: []const u8) ![]u8 {
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

fn hexValue(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
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

test "issues toolbar renders search form" {
    var filters = IssueFilters{
        .allocator = std.testing.allocator,
        .state = .open,
        .q = try std.testing.allocator.dupe(u8, "label:bug crash"),
    };
    defer filters.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendIssuesToolbar(&buf, std.testing.allocator, null, filters);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "class=\"issues-toolbar work-items-toolbar\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "action=\"/issues\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "label:bug crash") != null);
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
    try std.testing.expectEqualStrings("/issues?state=open&amp;q=crash%20fix&amp;sort=updated", buf.items);
}
