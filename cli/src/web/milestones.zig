const std = @import("std");
const event_mod = @import("../event.zig");
const index = @import("../index.zig");
const issue_mod = @import("../issue.zig");
const milestone_mod = @import("../milestone.zig");
const repo_mod = @import("../repo.zig");
const shared = @import("shared.zig");
const issues_page = @import("issues.zig");
const util = @import("../util.zig");
const zwf = @import("../zwf.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const SqliteDb = index.SqliteDb;
const appendEmptyCell = shared.appendEmptyCell;
const appendEmptyState = shared.appendEmptyState;
const appendSectionHead = shared.appendSectionHead;
const appendShellEnd = shared.appendShellEnd;
const appendShellStart = shared.appendShellStart;
const appendRelativeTime = shared.appendRelativeTime;
const appendStatePill = shared.appendStatePill;
const appendTemplate = shared.appendTemplate;
const createMilestoneCreatedEvent = milestone_mod.createMilestoneCreatedEvent;
const createMilestoneDeletedEvent = milestone_mod.createMilestoneDeletedEvent;
const createMilestoneStringEvent = milestone_mod.createMilestoneStringEvent;
const createMilestoneUpdatedEvent = milestone_mod.createMilestoneUpdatedEvent;
const createIssueStringEvent = issue_mod.createIssueStringEvent;
const formValueOwned = issues_page.formValueOwned;
const literalHref = shared.literalHref;
const percentDecodeForm = issues_page.percentDecodeForm;
const sendRedirect = shared.sendRedirect;
const sendResponse = shared.sendResponse;
const sendPlainResponse = shared.sendPlainResponse;
const sqlite = index.sqlite;

const milestone_ref_len: usize = 8;

const MilestoneFormData = struct {
    id: []u8,
    title: []u8,
    description: []u8,
    due_at: []u8,
    state: []u8,

    fn deinit(self: *MilestoneFormData, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        allocator.free(self.description);
        allocator.free(self.due_at);
        allocator.free(self.state);
    }
};

const MilestoneDetailData = struct {
    id: []u8,
    title: []u8,
    description: []u8,
    due_at: []u8,
    state: []u8,
    created_at: []u8,
    updated_at: []u8,
    author_principal: []u8,
    issue_count: usize,
    closed_count: usize,

    fn deinit(self: *MilestoneDetailData, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        allocator.free(self.description);
        allocator.free(self.due_at);
        allocator.free(self.state);
        allocator.free(self.created_at);
        allocator.free(self.updated_at);
        allocator.free(self.author_principal);
    }
};

const MilestoneStateFilter = enum {
    open,
    closed,
};

const MilestoneSort = enum {
    updated,
    furthest_due,
    closest_due,
    least_complete,
    most_complete,
    alphabetical,
    reverse_alphabetical,
    most_issues,
    fewest_issues,
};

const MilestoneCounts = struct {
    open: usize = 0,
    closed: usize = 0,
};

const MilestoneFilters = struct {
    state: MilestoneStateFilter,
    sort: MilestoneSort,
};

const MilestoneHrefOverride = struct {
    state: ?MilestoneStateFilter = null,
    sort: ?MilestoneSort = null,
};

pub fn renderMilestonesPage(allocator: Allocator, repo: Repo, target: []const u8, csrf_token: []const u8) ![]u8 {
    if (try shared.renderIndexingPageIfStale(allocator, repo, "Milestones", "projects", target)) |body| return body;
    try index.ensureIndex(allocator, repo);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "Milestones", "projects");
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    const counts = try loadMilestoneCounts(allocator, &db);
    const filters = try milestoneFiltersFromTarget(allocator, target, counts);
    try appendMilestoneProjectLayoutStart(&buf, allocator);
    try appendMilestonesSummaryPage(&buf, allocator, &db, filters, counts, csrf_token);
    try appendMilestoneProjectLayoutEnd(&buf, allocator);
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn appendMilestoneProjectLayoutStart(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator,
        \\<div class="project-page-layout">
        \\  <aside class="project-page-sidebar">
        \\    <nav class="project-page-tabs" aria-label="Projects sections">
        \\      <a class="project-page-tab" href="/projects"><span class="button-icon icon-projects" aria-hidden="true"></span><span>Projects</span></a>
        \\      <a class="project-page-tab active" href="/milestones"><span class="button-icon icon-milestones" aria-hidden="true"></span><span>Milestones</span></a>
        \\    </nav>
        \\  </aside>
        \\  <div class="project-page-content">
    );
}

fn appendMilestoneProjectLayoutEnd(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator,
        \\  </div>
        \\</div>
    );
}

fn milestoneFiltersFromTarget(allocator: Allocator, target: []const u8, counts: MilestoneCounts) !MilestoneFilters {
    return .{
        .state = try milestoneStateFromTarget(allocator, target, counts),
        .sort = try milestoneSortFromTarget(allocator, target),
    };
}

fn milestoneStateFromTarget(allocator: Allocator, target: []const u8, counts: MilestoneCounts) !MilestoneStateFilter {
    const state_value = try shared.queryValueOwned(allocator, target, "state");
    defer if (state_value) |value| allocator.free(value);
    if (state_value) |value| {
        if (std.mem.eql(u8, value, "closed")) return .closed;
        if (std.mem.eql(u8, value, "open")) return .open;
    }
    return if (counts.open == 0 and counts.closed > 0) .closed else .open;
}

fn milestoneSortFromTarget(allocator: Allocator, target: []const u8) !MilestoneSort {
    const sort_value = try shared.queryValueOwned(allocator, target, "sort");
    defer if (sort_value) |value| allocator.free(value);
    const value = sort_value orelse return .updated;
    if (std.mem.eql(u8, value, "furthest_due")) return .furthest_due;
    if (std.mem.eql(u8, value, "closest_due")) return .closest_due;
    if (std.mem.eql(u8, value, "least_complete")) return .least_complete;
    if (std.mem.eql(u8, value, "most_complete")) return .most_complete;
    if (std.mem.eql(u8, value, "alphabetical")) return .alphabetical;
    if (std.mem.eql(u8, value, "reverse_alphabetical")) return .reverse_alphabetical;
    if (std.mem.eql(u8, value, "most_issues")) return .most_issues;
    if (std.mem.eql(u8, value, "fewest_issues")) return .fewest_issues;
    return .updated;
}

fn loadMilestoneCounts(allocator: Allocator, db: *SqliteDb) !MilestoneCounts {
    var counts: MilestoneCounts = .{};
    var stmt = try db.prepare(
        \\WITH milestone_rows AS (
        \\  SELECT state
        \\  FROM milestones
        \\  UNION ALL
        \\  SELECT 'open' AS state
        \\  FROM issue_metadata im
        \\  WHERE im.milestone <> ''
        \\    AND NOT EXISTS (
        \\      SELECT 1
        \\      FROM milestones m
        \\      WHERE m.title = im.milestone
        \\    )
        \\  GROUP BY im.milestone
        \\)
        \\SELECT state, COUNT(*)
        \\FROM milestone_rows
        \\GROUP BY state
    );
    defer stmt.deinit();
    while (try stmt.step()) {
        const state = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(state);
        const count = @as(usize, @intCast(stmt.columnInt64(1)));
        if (std.mem.eql(u8, state, "closed")) {
            counts.closed = count;
        } else {
            counts.open += count;
        }
    }
    return counts;
}

fn appendMilestonesSummaryPage(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, filters: MilestoneFilters, counts: MilestoneCounts, csrf_token: []const u8) !void {
    try buf.appendSlice(allocator,
        \\<section class="panel issues-panel milestones-summary-panel">
    );
    try appendSectionHead(buf, allocator, "Projects", "Milestones", .{
        .label = "New milestone",
        .href = literalHref("/new-milestone"),
        .kind = "primary",
    });
    try appendMilestonesListHeader(buf, allocator, filters, counts);

    var stmt = try prepareMilestoneSummaryStmt(allocator, db, filters);
    defer stmt.deinit();
    try stmt.bindText(1, milestoneStateValue(filters.state));

    var shown: usize = 0;
    while (try stmt.step()) {
        const id = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(id);
        const title = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(title);
        const description = try stmt.columnTextDup(allocator, 2);
        defer allocator.free(description);
        const due_at = try stmt.columnTextDup(allocator, 3);
        defer allocator.free(due_at);
        const state = try stmt.columnTextDup(allocator, 4);
        defer allocator.free(state);
        const issue_count = @as(usize, @intCast(stmt.columnInt64(5)));
        const closed_count = @as(usize, @intCast(stmt.columnInt64(6)));
        const implicit = stmt.columnInt64(7) != 0;
        try appendMilestoneSummaryRow(buf, allocator, id, title, description, due_at, state, issue_count, closed_count, implicit, csrf_token);
        shown += 1;
    }

    if (shown == 0) {
        switch (filters.state) {
            .open => try appendEmptyState(buf, allocator, "No open milestones.", "Closed milestones are available from the Closed tab."),
            .closed => try appendEmptyState(buf, allocator, "No closed milestones.", "Open milestones are available from the Open tab."),
        }
    }
    try buf.appendSlice(allocator, "</section>");
}

fn appendMilestonesListHeader(buf: *std.ArrayList(u8), allocator: Allocator, filters: MilestoneFilters, counts: MilestoneCounts) !void {
    try buf.appendSlice(allocator,
        \\<header class="issues-list-head milestones-list-head">
        \\  <nav class="issues-state-tabs" aria-label="Milestone state">
    );
    try appendMilestoneStateTab(buf, allocator, "Open", counts.open, .open, filters);
    try appendMilestoneStateTab(buf, allocator, "Closed", counts.closed, .closed, filters);
    try buf.appendSlice(allocator,
        \\  </nav>
        \\  <div class="issues-filter-menus milestones-filter-menus">
    );
    try appendMilestoneSortMenu(buf, allocator, filters);
    try buf.appendSlice(allocator,
        \\  </div>
        \\</header>
    );
}

fn appendMilestoneStateTab(buf: *std.ArrayList(u8), allocator: Allocator, label: []const u8, count: usize, tab_filter: MilestoneStateFilter, filters: MilestoneFilters) !void {
    try appendTemplate(buf, allocator,
        \\<a class="{classes}" href="
    , .{
        .classes = shared.classes("issues-state-tab", &.{shared.class("active", tab_filter == filters.state)}),
    });
    try appendMilestonesHref(buf, allocator, filters, .{ .state = tab_filter });
    try appendTemplate(buf, allocator,
        \\"><span>{label}</span><span class="issue-count-badge">{count}</span></a>
    , .{
        .label = label,
        .count = count,
    });
}

fn appendMilestoneSortMenu(buf: *std.ArrayList(u8), allocator: Allocator, filters: MilestoneFilters) !void {
    try appendTemplate(buf, allocator,
        \\<details{classes} data-popover-menu><summary><span class="button-icon icon-sort" aria-hidden="true"></span><span>Sort</span></summary><div class="issues-filter-popover milestones-sort-popover" role="menu">
        \\  <span class="milestones-sort-title">Sort by</span>
    , .{
        .classes = shared.classAttr("issues-filter-menu milestones-sort-menu", &.{shared.class("active", filters.sort != .updated)}),
    });
    try appendMilestoneSortMenuLink(buf, allocator, filters, .updated);
    try appendMilestoneSortMenuLink(buf, allocator, filters, .furthest_due);
    try appendMilestoneSortMenuLink(buf, allocator, filters, .closest_due);
    try appendMilestoneSortMenuLink(buf, allocator, filters, .least_complete);
    try appendMilestoneSortMenuLink(buf, allocator, filters, .most_complete);
    try appendMilestoneSortMenuLink(buf, allocator, filters, .alphabetical);
    try appendMilestoneSortMenuLink(buf, allocator, filters, .reverse_alphabetical);
    try appendMilestoneSortMenuLink(buf, allocator, filters, .most_issues);
    try appendMilestoneSortMenuLink(buf, allocator, filters, .fewest_issues);
    try buf.appendSlice(allocator, "</div></details>");
}

fn appendMilestoneSortMenuLink(buf: *std.ArrayList(u8), allocator: Allocator, filters: MilestoneFilters, sort: MilestoneSort) !void {
    try appendTemplate(buf, allocator,
        \\<a class="{classes}" role="menuitem" href="
    , .{ .classes = shared.classes("issues-filter-option", &.{shared.class("selected", filters.sort == sort)}) });
    try appendMilestonesHref(buf, allocator, filters, .{ .sort = sort });
    try appendTemplate(buf, allocator,
        \\"><span>{label}</span></a>
    , .{ .label = milestoneSortLabel(sort) });
}

fn appendMilestonesHref(buf: *std.ArrayList(u8), allocator: Allocator, filters: MilestoneFilters, override: MilestoneHrefOverride) !void {
    try buf.appendSlice(allocator, "/milestones");
    var first = true;
    try shared.appendQueryParam(buf, allocator, &first, "state", milestoneStateValue(override.state orelse filters.state));
    const sort = override.sort orelse filters.sort;
    if (sort != .updated) try shared.appendQueryParam(buf, allocator, &first, "sort", milestoneSortValue(sort));
}

fn prepareMilestoneSummaryStmt(allocator: Allocator, db: *SqliteDb, filters: MilestoneFilters) !index.SqliteStmt {
    const sql_text = try std.fmt.allocPrint(allocator,
        \\WITH explicit_milestones AS (
        \\  SELECT m.id, m.title, m.description, m.due_at, m.state,
        \\         (SELECT COUNT(*)
        \\          FROM issue_metadata im
        \\          JOIN issues i ON i.id = im.issue_id
        \\          WHERE im.milestone = m.title) AS issue_count,
        \\         (SELECT COUNT(*)
        \\          FROM issue_metadata im
        \\          JOIN issues i ON i.id = im.issue_id
        \\          WHERE im.milestone = m.title AND i.state = 'closed') AS closed_count,
        \\         max(m.created_at, m.title_occurred_at, m.description_occurred_at, m.due_at_occurred_at, m.state_occurred_at) AS activity_at,
        \\         0 AS implicit
        \\  FROM milestones m
        \\),
        \\implicit_milestones AS (
        \\  SELECT '' AS id, im.milestone AS title, '' AS description, '' AS due_at, 'open' AS state,
        \\         COUNT(*) AS issue_count,
        \\         SUM(CASE WHEN i.state = 'closed' THEN 1 ELSE 0 END) AS closed_count,
        \\         MAX(CASE WHEN i.state = 'closed' THEN i.state_occurred_at ELSE i.opened_at END) AS activity_at,
        \\         1 AS implicit
        \\  FROM issue_metadata im
        \\  JOIN issues i ON i.id = im.issue_id
        \\  WHERE im.milestone <> ''
        \\    AND NOT EXISTS (
        \\      SELECT 1
        \\      FROM milestones m
        \\      WHERE m.title = im.milestone
        \\    )
        \\  GROUP BY im.milestone
        \\),
        \\milestone_rows AS (
        \\  SELECT * FROM explicit_milestones
        \\  UNION ALL
        \\  SELECT * FROM implicit_milestones
        \\)
        \\SELECT id, title, description, due_at, state, issue_count, closed_count, implicit
        \\FROM milestone_rows
        \\WHERE state = ?
        \\ORDER BY {s}
    , .{milestoneSortOrderSql(filters.sort)});
    defer allocator.free(sql_text);
    return db.prepare(sql_text);
}

fn appendMilestoneSummaryRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    id: []const u8,
    title: []const u8,
    description: []const u8,
    due_at: []const u8,
    state: []const u8,
    issue_count: usize,
    closed_count: usize,
    implicit: bool,
    csrf_token: []const u8,
) !void {
    var ref_buf: [milestone_ref_len]u8 = undefined;
    const milestone_ref = if (implicit) "" else milestoneDisplayRef(&ref_buf, id);
    const open_count = issue_count - @min(issue_count, closed_count);
    const progress = milestoneProgressPercent(closed_count, issue_count);
    try appendTemplate(buf, allocator,
        \\<article class="issue-list-row milestone-list-row is-{state}">
        \\  <div class="issue-row-content milestone-row-main">
        \\    <div class="issue-row-title-line"><span class="issue-milestone-icon" aria-hidden="true"></span>
    , .{
        .state = state,
    });
    if (implicit) {
        try buf.appendSlice(allocator, "<a class=\"issue-row-title\" href=\"/issues?milestone=");
        try shared.appendUrlEncoded(buf, allocator, title);
        try appendTemplate(buf, allocator, "\">{title}</a>", .{ .title = title });
    } else {
        try appendTemplate(buf, allocator, "<a class=\"issue-row-title\" href=\"/milestones/{milestone_ref}\">{title}</a><code>#{milestone_ref}</code>", .{
            .title = title,
            .milestone_ref = milestone_ref,
        });
    }
    try buf.appendSlice(allocator, "</div>");
    try buf.appendSlice(allocator, "<p class=\"issue-row-meta milestone-row-meta\">");
    if (due_at.len == 0) {
        try buf.appendSlice(allocator, "No due date");
    } else {
        try shared.appendHtml(buf, allocator, due_at);
    }
    try appendTemplate(buf, allocator,
        \\ <span aria-hidden="true">&bull;</span> {closed_count}/{issue_count} {issue_word} closed
    , .{
        .closed_count = closed_count,
        .issue_count = issue_count,
        .issue_word = issueWord(issue_count),
    });
    if (description.len != 0) {
        try appendTemplate(buf, allocator,
            \\ <span aria-hidden="true">&bull;</span> {description}
        , .{ .description = description });
    }
    try appendTemplate(buf, allocator,
        \\</p>
        \\  </div>
        \\  <div class="milestone-row-progress">
        \\    <div class="milestone-progress-track" aria-hidden="true"><span style="width: {progress}%;"></span></div>
        \\    <p><strong>{progress}%</strong> complete <strong>{open_count}</strong> open <strong>{closed_count}</strong> closed</p>
        \\  </div>
        \\  <div class="milestone-row-actions">
    , .{
        .progress = progress,
        .open_count = open_count,
        .closed_count = closed_count,
    });
    if (!implicit) try appendMilestoneActionMenu(buf, allocator, milestone_ref, title, state, csrf_token);
    try buf.appendSlice(allocator,
        \\  </div>
        \\</article>
    );
}

fn appendMilestoneActionMenu(buf: *std.ArrayList(u8), allocator: Allocator, milestone_ref: []const u8, title: []const u8, state: []const u8, csrf_token: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<details class="milestone-action-menu" data-popover-menu>
        \\  <summary class="issue-kebab-button" aria-label="Milestone actions for {title}"></summary>
        \\  <div class="milestone-action-popover" role="menu">
        \\    <a role="menuitem" href="/milestones/
    , .{ .title = title });
    try shared.appendUrlEncoded(buf, allocator, milestone_ref);
    try buf.appendSlice(allocator, "/edit\"><span class=\"milestone-menu-icon milestone-menu-icon-edit\" aria-hidden=\"true\"></span><span>Edit</span></a>");
    try buf.appendSlice(allocator, "<form method=\"post\" action=\"/milestones/");
    try shared.appendUrlEncoded(buf, allocator, milestone_ref);
    try appendTemplate(buf, allocator,
        \\"><input type="hidden" name="{csrf_field}" value="{csrf_token}"><input type="hidden" name="action" value="{action}"><button type="submit" role="menuitem"><span class="milestone-menu-icon milestone-menu-icon-state" aria-hidden="true"></span><span>{label}</span></button></form>
    , .{
        .csrf_field = zwf.csrf.field_name,
        .csrf_token = csrf_token,
        .action = if (std.mem.eql(u8, state, "closed")) "reopen" else "close",
        .label = if (std.mem.eql(u8, state, "closed")) "Reopen" else "Close",
    });
    try buf.appendSlice(allocator, "<form method=\"post\" action=\"/milestones/");
    try shared.appendUrlEncoded(buf, allocator, milestone_ref);
    try appendTemplate(buf, allocator,
        \\"><input type="hidden" name="{csrf_field}" value="{csrf_token}"><input type="hidden" name="action" value="delete"><button class="danger" type="submit" role="menuitem"><span class="milestone-menu-icon milestone-menu-icon-delete" aria-hidden="true"></span><span>Delete</span></button></form>
        \\  </div>
        \\</details>
    , .{
        .csrf_field = zwf.csrf.field_name,
        .csrf_token = csrf_token,
    });
}

fn milestoneStateValue(state: MilestoneStateFilter) []const u8 {
    return switch (state) {
        .open => "open",
        .closed => "closed",
    };
}

fn milestoneSortValue(sort: MilestoneSort) []const u8 {
    return switch (sort) {
        .updated => "updated",
        .furthest_due => "furthest_due",
        .closest_due => "closest_due",
        .least_complete => "least_complete",
        .most_complete => "most_complete",
        .alphabetical => "alphabetical",
        .reverse_alphabetical => "reverse_alphabetical",
        .most_issues => "most_issues",
        .fewest_issues => "fewest_issues",
    };
}

fn milestoneSortLabel(sort: MilestoneSort) []const u8 {
    return switch (sort) {
        .updated => "Recently updated",
        .furthest_due => "Furthest due date",
        .closest_due => "Closest due date",
        .least_complete => "Least complete",
        .most_complete => "Most complete",
        .alphabetical => "Alphabetical",
        .reverse_alphabetical => "Reverse alphabetical",
        .most_issues => "Most issues",
        .fewest_issues => "Fewest issues",
    };
}

fn milestoneSortOrderSql(sort: MilestoneSort) []const u8 {
    return switch (sort) {
        .updated =>
        \\activity_at DESC, lower(title), title, id
        ,
        .furthest_due =>
        \\CASE WHEN due_at = '' THEN 1 ELSE 0 END, due_at DESC, lower(title), title, id
        ,
        .closest_due =>
        \\CASE WHEN due_at = '' THEN 1 ELSE 0 END, due_at ASC, lower(title), title, id
        ,
        .least_complete =>
        \\CASE WHEN issue_count = 0 THEN 0 ELSE (closed_count * 1000000 / issue_count) END ASC, issue_count DESC, lower(title), title, id
        ,
        .most_complete =>
        \\CASE WHEN issue_count = 0 THEN 0 ELSE (closed_count * 1000000 / issue_count) END DESC, issue_count DESC, lower(title), title, id
        ,
        .alphabetical =>
        \\lower(title) ASC, title ASC, id
        ,
        .reverse_alphabetical =>
        \\lower(title) DESC, title DESC, id
        ,
        .most_issues =>
        \\issue_count DESC, lower(title), title, id
        ,
        .fewest_issues =>
        \\issue_count ASC, lower(title), title, id
        ,
    };
}

fn milestoneProgressPercent(closed_count: usize, issue_count: usize) usize {
    if (issue_count == 0) return 0;
    return (@min(closed_count, issue_count) * 100) / issue_count;
}

fn milestoneDisplayRef(out_buf: *[milestone_ref_len]u8, object_id: []const u8) []const u8 {
    return util.objectRefPrefix(out_buf[0..], object_id);
}

fn milestoneDetailPathOwned(allocator: Allocator, milestone_ref: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "/milestones/");
    try shared.appendUrlEncoded(&buf, allocator, milestone_ref);
    return buf.toOwnedSlice(allocator);
}

fn appendMilestoneStateBadge(buf: *std.ArrayList(u8), allocator: Allocator, state: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<span class="issue-state-badge is-{state}"><span class="issue-state-mark" aria-hidden="true"></span>{label}</span>
    , .{
        .state = state,
        .label = if (std.mem.eql(u8, state, "closed")) "Closed" else "Open",
    });
}

fn appendMilestoneStateButtonForm(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    milestone_ref: []const u8,
    state: []const u8,
    return_to: []const u8,
    button_class: []const u8,
    csrf_token: []const u8,
) !void {
    const closed = std.mem.eql(u8, state, "closed");
    try buf.appendSlice(allocator, "<form class=\"milestone-state-form\" method=\"post\" action=\"/milestones/");
    try shared.appendUrlEncoded(buf, allocator, milestone_ref);
    try appendTemplate(buf, allocator,
        \\">
        \\  <input type="hidden" name="{csrf_field}" value="{csrf_token}">
        \\  <input type="hidden" name="action" value="{action}">
        \\  <input type="hidden" name="return_to" value="{return_to}">
        \\  <button class="{button_class}" type="submit">{label}</button>
        \\</form>
    , .{
        .csrf_field = zwf.csrf.field_name,
        .csrf_token = csrf_token,
        .action = if (closed) "reopen" else "close",
        .return_to = return_to,
        .button_class = button_class,
        .label = if (closed) "Reopen milestone" else "Close milestone",
    });
}

fn issueWord(count: usize) []const u8 {
    return if (count == 1) "issue" else "issues";
}

pub fn renderMilestoneDetailPage(allocator: Allocator, repo: Repo, raw_ref: []const u8, target: []const u8, csrf_token: []const u8) ![]u8 {
    if (try shared.renderIndexingPageIfStale(allocator, repo, "Milestone", "projects", target)) |body| return body;
    try index.ensureIndex(allocator, repo);

    var data = loadMilestoneDetailData(allocator, repo, raw_ref) catch return renderMilestoneNotFound(allocator, repo, raw_ref);
    defer data.deinit(allocator);

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    const issue_state = try milestoneIssueStateFromTarget(allocator, target, data);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var ref_buf: [milestone_ref_len]u8 = undefined;
    const milestone_ref = milestoneDisplayRef(&ref_buf, data.id);
    const detail_path = try milestoneDetailPathOwned(allocator, milestone_ref);
    defer allocator.free(detail_path);

    try appendShellStart(&buf, allocator, repo, data.title, "projects");
    try shared.appendDetailBackButton(&buf, allocator, shared.literalHref("/projects#milestones"), "Back to milestones");
    try buf.appendSlice(allocator, "<section class=\"milestone-detail-page\">");
    try appendMilestoneDetailHeader(&buf, allocator, &db, milestone_ref, detail_path, data, csrf_token);
    try appendMilestoneDetailDescription(&buf, allocator, data.description);
    try appendMilestoneDetailProgress(&buf, allocator, data.closed_count, data.issue_count);
    try appendMilestoneDetailIssues(&buf, allocator, &db, milestone_ref, data.title, issue_state, data.issue_count, data.closed_count);
    try buf.appendSlice(allocator, "</section>");
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn appendMilestoneDetailHeader(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    milestone_ref: []const u8,
    return_to: []const u8,
    data: MilestoneDetailData,
    csrf_token: []const u8,
) !void {
    try appendTemplate(buf, allocator,
        \\<header class="issue-page-head milestone-detail-head">
        \\  <div class="issue-title-line">
        \\    <h1><span>{title}</span> <span class="issue-page-number">#{milestone_ref}</span></h1>
        \\    <div class="issue-page-actions milestone-detail-actions">
        \\      <a class="button secondary" href="/milestones/{milestone_ref}/edit">Edit</a>
    , .{
        .title = data.title,
        .milestone_ref = milestone_ref,
    });
    try appendMilestoneStateButtonForm(buf, allocator, milestone_ref, data.state, return_to, "button secondary", csrf_token);
    try appendMilestoneAddIssueMenu(buf, allocator, db, milestone_ref, return_to, data.title, csrf_token);
    try buf.appendSlice(allocator,
        \\    </div>
        \\  </div>
        \\  <div class="issue-status-line milestone-detail-meta">
    );
    try appendMilestoneStateBadge(buf, allocator, data.state);
    if (data.due_at.len == 0) {
        try buf.appendSlice(allocator, "<span>No due date</span>");
    } else {
        try appendTemplate(buf, allocator, "<span>Due {due_at}</span>", .{ .due_at = data.due_at });
    }
    try buf.appendSlice(allocator, "<span aria-hidden=\"true\">&bull;</span><span>Last updated ");
    try appendRelativeTime(buf, allocator, data.updated_at);
    try buf.appendSlice(allocator, "</span></div></header>");
}

fn appendMilestoneAddIssueMenu(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    milestone_ref: []const u8,
    return_to: []const u8,
    milestone_title: []const u8,
    csrf_token: []const u8,
) !void {
    try appendTemplate(buf, allocator,
        \\      <details class="milestone-add-issue-menu" data-popover-menu data-issue-sidebar-menu>
        \\        <summary class="button primary">Add issue</summary>
        \\        <div class="issue-sidebar-popover milestone-add-issue-popover" role="dialog" aria-label="Add issue to milestone">
        \\          <div class="issue-sidebar-popover-title">Add issue</div>
        \\          <form class="milestone-add-issues-form" method="post" action="/milestones/{milestone_ref}">
        \\            <input type="hidden" name="{csrf_field}" value="{csrf_token}">
        \\            <input type="hidden" name="action" value="add-issues">
        \\            <input type="hidden" name="return_to" value="{return_to}">
        \\            <div class="milestone-add-issue-controls">
        \\              <label class="issue-sidebar-menu-input issue-sidebar-menu-filter"><span aria-hidden="true"></span><input placeholder="Search issues" aria-label="Search issues" autocomplete="off" data-issue-sidebar-filter></label>
        \\              <select class="milestone-add-issue-state-filter" aria-label="Filter issues" data-issue-sidebar-state-filter>
        \\                <option value="">All</option>
        \\                <option value="open">Open</option>
        \\                <option value="closed">Closed</option>
        \\              </select>
        \\            </div>
        \\            <div class="milestone-add-issue-list" role="group" aria-label="Issues">
    , .{
        .milestone_ref = milestone_ref,
        .csrf_field = zwf.csrf.field_name,
        .csrf_token = csrf_token,
        .return_to = return_to,
    });

    var stmt = try db.prepare(
        \\SELECT i.id, i.title, i.state, COALESCE(im.milestone, ''), COALESCE(a.number, 0)
        \\FROM issues i
        \\LEFT JOIN issue_metadata im ON im.issue_id = i.id
        \\LEFT JOIN legacy_aliases a
        \\  ON a.provider = 'github' AND a.object_kind = 'issue' AND a.object_id = i.id
        \\WHERE COALESCE(im.milestone, '') <> ?
        \\ORDER BY CASE i.state WHEN 'open' THEN 0 ELSE 1 END,
        \\         i.opened_at DESC,
        \\         i.id DESC
        \\LIMIT 80
    );
    defer stmt.deinit();
    try stmt.bindText(1, milestone_title);

    var shown = false;
    while (try stmt.step()) {
        const issue_id = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(issue_id);
        const title = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(title);
        const state = try stmt.columnTextDup(allocator, 2);
        defer allocator.free(state);
        const current_milestone = try stmt.columnTextDup(allocator, 3);
        defer allocator.free(current_milestone);
        const legacy_number = stmt.columnInt64(4);
        try appendMilestoneAddIssueRow(buf, allocator, issue_id, title, state, current_milestone, legacy_number);
        shown = true;
    }
    if (!shown) {
        try appendEmptyState(buf, allocator, "No available issues.", "All issues are already in this milestone.");
    }

    try buf.appendSlice(allocator,
        \\            </div>
        \\            <div class="milestone-add-issue-actions"><button class="button primary" type="submit">Add</button></div>
        \\          </form>
        \\        </div>
        \\      </details>
    );
}

fn appendMilestoneAddIssueRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    issue_id: []const u8,
    title: []const u8,
    state: []const u8,
    current_milestone: []const u8,
    legacy_number: i64,
) !void {
    var issue_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const issue_ref = util.shortObjectRef(&issue_ref_buf, issue_id);
    const number_text = try issueNumberTextOwned(allocator, issue_ref, legacy_number);
    defer allocator.free(number_text);

    try appendTemplate(buf, allocator,
        \\<label class="milestone-add-issue-row" data-sidebar-filter-text="{title} {number_text} {current_milestone}" data-sidebar-state="{state}">
        \\  <input type="checkbox" name="issue" value="{issue_ref}" aria-label="Add {number_text} {title}">
        \\  <span class="{icon_classes}" aria-hidden="true"></span>
        \\  <span class="issue-sidebar-picker-text"><span class="issue-sidebar-picker-primary">{title}</span>
    , .{
        .title = title,
        .number_text = number_text,
        .current_milestone = current_milestone,
        .state = state,
        .issue_ref = issue_ref,
        .icon_classes = shared.classes("issue-sidebar-issue-icon", &.{
            shared.class("is-open", std.mem.eql(u8, state, "open")),
            shared.class("is-closed", std.mem.eql(u8, state, "closed")),
        }),
    });
    if (current_milestone.len != 0) {
        try appendTemplate(buf, allocator, "<span class=\"issue-sidebar-picker-secondary\">{current_milestone}</span>", .{ .current_milestone = current_milestone });
    }
    try appendTemplate(buf, allocator,
        \\</span><span class="issue-sidebar-picker-secondary issue-sidebar-choice-ref">{number_text}</span></label>
    , .{ .number_text = number_text });
}

fn issueNumberTextOwned(allocator: Allocator, issue_ref: []const u8, legacy_number: i64) ![]u8 {
    if (legacy_number > 0) return try std.fmt.allocPrint(allocator, "#{d}", .{legacy_number});
    return try std.fmt.allocPrint(allocator, "#{s}", .{issue_ref});
}

fn appendMilestoneDetailDescription(buf: *std.ArrayList(u8), allocator: Allocator, description: []const u8) !void {
    if (description.len == 0) return;
    try buf.appendSlice(allocator, "<section class=\"milestone-detail-description markdown-body\">");
    try shared.appendMarkdownSource(buf, allocator, description, .{});
    try buf.appendSlice(allocator, "</section>");
}

fn appendMilestoneDetailProgress(buf: *std.ArrayList(u8), allocator: Allocator, closed_count: usize, issue_count: usize) !void {
    const open_count = issue_count - @min(issue_count, closed_count);
    const progress = milestoneProgressPercent(closed_count, issue_count);
    try appendTemplate(buf, allocator,
        \\<section class="milestone-detail-progress" aria-label="Milestone progress">
        \\  <div class="milestone-detail-progress-line"><strong>{progress}%</strong><span>complete</span><span>{open_count} open</span><span>{closed_count} closed</span></div>
        \\  <div class="milestone-progress-track" aria-hidden="true"><span style="width: {progress}%;"></span></div>
        \\</section>
    , .{
        .progress = progress,
        .open_count = open_count,
        .closed_count = closed_count,
    });
}

fn appendMilestoneDetailIssues(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    milestone_ref: []const u8,
    milestone_title: []const u8,
    issue_state: MilestoneStateFilter,
    issue_count: usize,
    closed_count: usize,
) !void {
    const open_count = issue_count - @min(issue_count, closed_count);
    try buf.appendSlice(allocator, "<section class=\"panel issues-panel milestone-detail-issues\">");
    try appendMilestoneDetailIssuesHeader(buf, allocator, milestone_ref, issue_state, open_count, closed_count);

    var stmt = try db.prepare(
        \\SELECT i.id, i.title, i.state, i.author_principal, i.opened_at, i.state_occurred_at,
        \\       COALESCE(im.source_author, ''), i.body
        \\FROM issues i
        \\JOIN issue_metadata im ON im.issue_id = i.id
        \\WHERE im.milestone = ?
        \\  AND i.state = ?
        \\ORDER BY CASE i.state WHEN 'open' THEN i.opened_at ELSE i.state_occurred_at END DESC,
        \\         i.id DESC
    );
    defer stmt.deinit();
    try stmt.bindText(1, milestone_title);
    try stmt.bindText(2, milestoneStateValue(issue_state));

    var local_display_identity = try shared.loadLocalDisplayIdentity(allocator);
    defer local_display_identity.deinit();

    var shown: usize = 0;
    while (try stmt.step()) {
        const issue_id = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(issue_id);
        const title = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(title);
        const state = try stmt.columnTextDup(allocator, 2);
        defer allocator.free(state);
        const author_principal = try stmt.columnTextDup(allocator, 3);
        defer allocator.free(author_principal);
        const opened_at = try stmt.columnTextDup(allocator, 4);
        defer allocator.free(opened_at);
        const state_at = try stmt.columnTextDup(allocator, 5);
        defer allocator.free(state_at);
        const source_author = try stmt.columnTextDup(allocator, 6);
        defer allocator.free(source_author);
        const body = try stmt.columnTextDup(allocator, 7);
        defer allocator.free(body);
        const author = if (source_author.len != 0) source_author else local_display_identity.displayNameFor(author_principal);
        try appendMilestoneDetailIssueRow(buf, allocator, issue_id, title, state, author, opened_at, state_at, shared.markdownTaskSummary(body));
        shown += 1;
    }
    if (shown == 0) {
        switch (issue_state) {
            .open => try appendEmptyState(buf, allocator, "No open issues.", "Closed issues are available from the Closed tab."),
            .closed => try appendEmptyState(buf, allocator, "No closed issues.", "Open issues are available from the Open tab."),
        }
    }
    try buf.appendSlice(allocator, "</section>");
}

fn appendMilestoneDetailIssuesHeader(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    milestone_ref: []const u8,
    current_state: MilestoneStateFilter,
    open_count: usize,
    closed_count: usize,
) !void {
    try buf.appendSlice(allocator,
        \\<header class="issues-list-head milestone-detail-issues-head">
        \\  <div class="issues-select-all"><input type="checkbox" aria-label="Select all milestone issues" disabled></div>
        \\  <nav class="issues-state-tabs" aria-label="Milestone issue state">
    );
    try appendMilestoneIssueStateTab(buf, allocator, milestone_ref, "Open", open_count, .open, current_state, "issue-open-icon");
    try appendMilestoneIssueStateTab(buf, allocator, milestone_ref, "Closed", closed_count, .closed, current_state, "issue-closed-icon");
    try buf.appendSlice(allocator, "</nav></header>");
}

fn appendMilestoneIssueStateTab(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    milestone_ref: []const u8,
    label: []const u8,
    count: usize,
    tab_state: MilestoneStateFilter,
    current_state: MilestoneStateFilter,
    icon_class: []const u8,
) !void {
    try appendTemplate(buf, allocator,
        \\<a class="{classes}" href="/milestones/{milestone_ref}
    , .{
        .classes = shared.classes("issues-state-tab", &.{shared.class("active", tab_state == current_state)}),
        .milestone_ref = milestone_ref,
    });
    var first = true;
    try shared.appendQueryParam(buf, allocator, &first, "state", milestoneStateValue(tab_state));
    try appendTemplate(buf, allocator,
        \\"><span class="issue-tab-icon {icon_class}" aria-hidden="true"></span><span>{label}</span><span class="issue-count-badge">{count}</span></a>
    , .{
        .icon_class = icon_class,
        .label = label,
        .count = count,
    });
}

fn appendMilestoneDetailIssueRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    issue_id: []const u8,
    title: []const u8,
    state: []const u8,
    author: []const u8,
    opened_at: []const u8,
    state_at: []const u8,
    task_summary: shared.MarkdownTaskSummary,
) !void {
    var issue_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const issue_ref = util.shortObjectRef(&issue_ref_buf, issue_id);
    const closed = std.mem.eql(u8, state, "closed");
    try appendTemplate(buf, allocator,
        \\<article class="issue-list-row milestone-detail-issue-row is-{state}">
        \\  <div class="issue-select-cell"><input type="checkbox" aria-label="Select issue {issue_ref}" disabled></div>
        \\  <div class="issue-state-cell"><span class="issue-state-icon {state}" title="{state}" aria-label="{state}"></span></div>
        \\  <div class="issue-row-content">
        \\    <div class="issue-row-title-line"><a class="issue-row-title" href="{href}">{title}</a></div>
        \\    <p class="issue-row-meta">
    , .{
        .state = state,
        .issue_ref = issue_ref,
        .href = shared.issueHref(issue_ref),
        .title = title,
    });
    try shared.appendIssueReferenceText(buf, allocator, issue_ref);
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
        \\</p>
        \\  </div>
        \\  <div class="issue-row-side"></div>
        \\</article>
    );
}

fn milestoneIssueStateFromTarget(allocator: Allocator, target: []const u8, data: MilestoneDetailData) !MilestoneStateFilter {
    const state_value = try shared.queryValueOwned(allocator, target, "state");
    defer if (state_value) |value| allocator.free(value);
    if (state_value) |value| {
        if (std.mem.eql(u8, value, "closed")) return .closed;
        if (std.mem.eql(u8, value, "open")) return .open;
    }
    const open_count = data.issue_count - @min(data.issue_count, data.closed_count);
    return if (open_count == 0 and data.closed_count > 0) .closed else .open;
}

fn loadMilestoneDetailData(allocator: Allocator, repo: Repo, raw_ref: []const u8) !MilestoneDetailData {
    const milestone_id = try index.resolveMilestoneId(allocator, repo, raw_ref);
    defer allocator.free(milestone_id);
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var stmt = try db.prepare(
        \\SELECT m.id, m.title, m.description, m.due_at, m.state, m.created_at,
        \\       max(m.created_at, m.title_occurred_at, m.description_occurred_at, m.due_at_occurred_at, m.state_occurred_at) AS updated_at,
        \\       m.author_principal,
        \\       (SELECT COUNT(*)
        \\        FROM issue_metadata im
        \\        JOIN issues i ON i.id = im.issue_id
        \\        WHERE im.milestone = m.title) AS issue_count,
        \\       (SELECT COUNT(*)
        \\        FROM issue_metadata im
        \\        JOIN issues i ON i.id = im.issue_id
        \\        WHERE im.milestone = m.title AND i.state = 'closed') AS closed_count
        \\FROM milestones m
        \\WHERE m.id = ?
    );
    defer stmt.deinit();
    try stmt.bindText(1, milestone_id);
    if (!(try stmt.step())) return error.MilestoneNotFound;
    return .{
        .id = try stmt.columnTextDup(allocator, 0),
        .title = try stmt.columnTextDup(allocator, 1),
        .description = try stmt.columnTextDup(allocator, 2),
        .due_at = try stmt.columnTextDup(allocator, 3),
        .state = try stmt.columnTextDup(allocator, 4),
        .created_at = try stmt.columnTextDup(allocator, 5),
        .updated_at = try stmt.columnTextDup(allocator, 6),
        .author_principal = try stmt.columnTextDup(allocator, 7),
        .issue_count = @intCast(stmt.columnInt64(8)),
        .closed_count = @intCast(stmt.columnInt64(9)),
    };
}

pub fn appendMilestonesPanel(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, csrf_token: []const u8) !void {
    try buf.appendSlice(allocator, "<section id=\"milestones\" class=\"panel milestones-panel project-page-panel\" role=\"tabpanel\" aria-labelledby=\"project-tab-milestones\" data-project-index-panel>");
    try appendSectionHead(buf, allocator, "Projects", "Milestones", .{
        .label = "New milestone",
        .href = literalHref("/new-milestone"),
        .kind = "primary",
    });
    try buf.appendSlice(allocator,
        \\  <div class="table-wrap">
        \\    <table>
        \\      <thead><tr><th>Milestone</th><th>Progress</th><th>Due</th><th>State</th><th>Actions</th></tr></thead>
        \\      <tbody>
    );

    var stmt = try db.prepare(
        \\WITH explicit_milestones AS (
        \\  SELECT m.id, m.title, m.description, m.due_at, m.state,
        \\         (SELECT COUNT(*)
        \\          FROM issue_metadata im
        \\          JOIN issues i ON i.id = im.issue_id
        \\          WHERE im.milestone = m.title) AS issue_count,
        \\         (SELECT COUNT(*)
        \\          FROM issue_metadata im
        \\          JOIN issues i ON i.id = im.issue_id
        \\          WHERE im.milestone = m.title AND i.state = 'closed') AS closed_count,
        \\         0 AS implicit
        \\  FROM milestones m
        \\),
        \\implicit_milestones AS (
        \\  SELECT '' AS id, im.milestone AS title, '' AS description, '' AS due_at, 'open' AS state,
        \\         COUNT(*) AS issue_count,
        \\         SUM(CASE WHEN i.state = 'closed' THEN 1 ELSE 0 END) AS closed_count,
        \\         1 AS implicit
        \\  FROM issue_metadata im
        \\  JOIN issues i ON i.id = im.issue_id
        \\  WHERE im.milestone <> ''
        \\    AND NOT EXISTS (
        \\      SELECT 1
        \\      FROM milestones m
        \\      WHERE m.title = im.milestone
        \\    )
        \\  GROUP BY im.milestone
        \\),
        \\milestone_rows AS (
        \\  SELECT * FROM explicit_milestones
        \\  UNION ALL
        \\  SELECT * FROM implicit_milestones
        \\)
        \\SELECT id, title, description, due_at, state, issue_count, closed_count, implicit
        \\FROM milestone_rows
        \\ORDER BY
        \\  CASE state WHEN 'open' THEN 0 ELSE 1 END,
        \\  CASE WHEN due_at = '' THEN 1 ELSE 0 END,
        \\  due_at,
        \\  lower(title),
        \\  title,
        \\  id
    );
    defer stmt.deinit();

    var shown: usize = 0;
    while (try stmt.step()) {
        const id = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(id);
        const title = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(title);
        const description = try stmt.columnTextDup(allocator, 2);
        defer allocator.free(description);
        const due_at = try stmt.columnTextDup(allocator, 3);
        defer allocator.free(due_at);
        const state = try stmt.columnTextDup(allocator, 4);
        defer allocator.free(state);
        const issue_count = @as(usize, @intCast(stmt.columnInt64(5)));
        const closed_count = @as(usize, @intCast(stmt.columnInt64(6)));
        const implicit = stmt.columnInt64(7) != 0;
        try appendMilestoneRow(buf, allocator, id, title, description, due_at, state, issue_count, closed_count, implicit, csrf_token);
        shown += 1;
    }
    if (shown == 0) {
        try appendEmptyCell(buf, allocator, 5, "No milestones found.");
    }

    try buf.appendSlice(allocator,
        \\      </tbody>
        \\    </table>
        \\  </div>
        \\</section>
    );
}

fn appendMilestoneRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    id: []const u8,
    title: []const u8,
    description: []const u8,
    due_at: []const u8,
    state: []const u8,
    issue_count: usize,
    closed_count: usize,
    implicit: bool,
    csrf_token: []const u8,
) !void {
    var ref_buf: [milestone_ref_len]u8 = undefined;
    const milestone_ref = if (implicit) "" else milestoneDisplayRef(&ref_buf, id);
    try buf.appendSlice(allocator, "<tr><td><div class=\"milestone-title-cell\"><span class=\"issue-milestone-icon\" aria-hidden=\"true\"></span><div>");
    if (implicit) {
        try buf.appendSlice(allocator, "<a class=\"milestone-title-link\" href=\"/issues?milestone=");
        try shared.appendUrlEncoded(buf, allocator, title);
        try appendTemplate(buf, allocator, "\"><strong>{title}</strong></a>", .{ .title = title });
    } else {
        try appendTemplate(buf, allocator,
            \\<a class="milestone-title-link" href="/milestones/{milestone_ref}"><strong>{title}</strong></a><code>#{milestone_ref}</code>
        , .{
            .milestone_ref = milestone_ref,
            .title = title,
        });
    }
    if (description.len != 0) {
        try appendTemplate(buf, allocator, "<p class=\"muted\">{description}</p>", .{ .description = description });
    }
    try appendTemplate(buf, allocator,
        \\</div></div></td><td><div class="milestone-progress"><span>{closed_count}/{issue_count} closed</span><div aria-hidden="true"><span style="width: {percent};"></span></div></div></td><td>
    , .{
        .closed_count = closed_count,
        .issue_count = issue_count,
        .percent = shared.percent(@intCast(closed_count), @intCast(issue_count)),
    });
    if (due_at.len == 0) {
        try buf.appendSlice(allocator, "<span class=\"muted\">No due date</span>");
    } else {
        try shared.appendHtml(buf, allocator, due_at);
    }
    try buf.appendSlice(allocator, "</td><td>");
    try appendStatePill(buf, allocator, state);
    try buf.appendSlice(allocator, "</td><td><div class=\"milestone-actions\">");
    if (!implicit) try appendMilestoneActionMenu(buf, allocator, milestone_ref, title, state, csrf_token);
    try buf.appendSlice(allocator, "</div></td></tr>");
}

pub fn renderMilestoneFormFromRef(allocator: Allocator, repo: Repo, raw_ref: []const u8, csrf_token: []const u8) ![]u8 {
    try index.ensureIndex(allocator, repo);
    var data = loadMilestoneFormData(allocator, repo, raw_ref) catch return renderMilestoneNotFound(allocator, repo, raw_ref);
    defer data.deinit(allocator);
    return renderMilestoneForm(allocator, repo, raw_ref, null, data.title, data.description, data.due_at, data.state, csrf_token);
}

pub fn renderNewMilestoneForm(allocator: Allocator, repo: Repo, csrf_token: []const u8) ![]u8 {
    return renderMilestoneForm(allocator, repo, null, null, "", "", "", "open", csrf_token);
}

fn renderMilestoneForm(
    allocator: Allocator,
    repo: Repo,
    raw_ref: ?[]const u8,
    error_message: ?[]const u8,
    title_value: []const u8,
    description_value: []const u8,
    due_at_value: []const u8,
    state_value: []const u8,
    csrf_token: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const editing = raw_ref != null;
    const form_id = if (editing) "milestone-edit-form" else "milestone-new-form";
    const cancel_href = if (raw_ref) |value| try milestoneDetailPathOwned(allocator, value) else try allocator.dupe(u8, "/milestones");
    defer allocator.free(cancel_href);
    try appendShellStart(&buf, allocator, repo, if (editing) "Edit Milestone" else "New Milestone", "projects");
    try appendTemplate(&buf, allocator,
        \\<section class="milestone-form-page">
        \\  <header class="milestone-form-head">
        \\    <h1>{heading}</h1>
        \\  </header>
    , .{ .heading = if (editing) "Edit milestone" else "Create milestone" });
    if (error_message) |message| {
        try appendTemplate(&buf, allocator, "<div class=\"flash error\">{message}</div>", .{ .message = message });
    }
    try appendTemplate(&buf, allocator, "<form id=\"{form_id}\" class=\"issue-form milestone-form\" method=\"post\" action=\"", .{ .form_id = form_id });
    if (raw_ref) |value| {
        try buf.appendSlice(allocator, "/milestones/");
        try shared.appendUrlEncoded(&buf, allocator, value);
    } else {
        try buf.appendSlice(allocator, "/milestones");
    }
    try appendTemplate(&buf, allocator,
        \\">
        \\  <input type="hidden" name="{csrf_field}" value="{csrf_token}">
        \\  <input type="hidden" name="action" value="{action}">
        \\  <label>Title<input name="title" value="{title_value}" required autofocus></label>
    , .{
        .csrf_field = zwf.csrf.field_name,
        .csrf_token = csrf_token,
        .action = if (editing) "update" else "create",
        .title_value = title_value,
    });
    try appendTemplate(&buf, allocator,
        \\  <label>Due date <span class="muted">(optional)</span><input type="date" name="due_at" value="{due_at_value}" placeholder="2026-06-30" data-date-picker data-date-picker-label="Due date" data-date-picker-placeholder="No due date"></label>
        \\  <label>Description <span class="muted">(optional)</span><textarea name="description" rows="7" placeholder="Describe your milestone">{description_value}</textarea></label>
    , .{
        .description_value = description_value,
        .due_at_value = due_at_value,
    });
    if (editing) {
        try appendTemplate(&buf, allocator,
            \\  <input type="hidden" name="state" value="{state_value}">
            \\  <input type="hidden" name="return_to" value="{cancel_href}">
        , .{
            .state_value = state_value,
            .cancel_href = cancel_href,
        });
    }
    try buf.appendSlice(allocator, "</form>");
    try buf.appendSlice(allocator,
        \\  <div class="milestone-form-footer">
        \\    <div class="milestone-form-state-slot">
    );
    if (raw_ref) |value| {
        try appendMilestoneStateButtonForm(&buf, allocator, value, state_value, cancel_href, "button secondary", csrf_token);
    }
    try appendTemplate(&buf, allocator,
        \\    </div>
        \\    <div class="form-actions">
        \\      <a class="button secondary" href="{cancel_href}">Cancel</a>
        \\      <button class="button primary" form="{form_id}" type="submit">{save_label}</button>
        \\    </div>
        \\  </div>
        \\</section>
    , .{
        .cancel_href = cancel_href,
        .form_id = form_id,
        .save_label = if (editing) "Save changes" else "Create milestone",
    });
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn appendStateOption(buf: *std.ArrayList(u8), allocator: Allocator, value: []const u8, selected: []const u8) !void {
    try appendTemplate(buf, allocator, "<option value=\"{value}\"", .{ .value = value });
    if (std.mem.eql(u8, value, selected)) try buf.appendSlice(allocator, " selected");
    try appendTemplate(buf, allocator, ">{value}</option>", .{ .value = value });
}

pub fn handleMilestonePost(allocator: Allocator, repo: Repo, stream: std.net.Stream, raw_ref: ?[]const u8, csrf_token: []const u8, form_body: []const u8) !void {
    if (raw_ref) |milestone_ref| {
        try handleMilestoneUpdatePost(allocator, repo, stream, milestone_ref, csrf_token, form_body);
        return;
    }
    try handleMilestoneCreatePost(allocator, repo, stream, csrf_token, form_body);
}

fn handleMilestoneCreatePost(allocator: Allocator, repo: Repo, stream: std.net.Stream, csrf_token: []const u8, form_body: []const u8) !void {
    const title_owned = (try formValueOwned(allocator, form_body, "title")) orelse try allocator.dupe(u8, "");
    defer allocator.free(title_owned);
    const description_owned = (try formValueOwned(allocator, form_body, "description")) orelse try allocator.dupe(u8, "");
    defer allocator.free(description_owned);
    const due_at_owned = (try formValueOwned(allocator, form_body, "due_at")) orelse try allocator.dupe(u8, "");
    defer allocator.free(due_at_owned);

    const title = std.mem.trim(u8, title_owned, " \t\r\n");
    if (title.len == 0) {
        const body = try renderMilestoneForm(allocator, repo, null, "Title is required.", title_owned, description_owned, due_at_owned, "open", csrf_token);
        defer allocator.free(body);
        try sendResponse(allocator, stream, 422, "Unprocessable Entity", "text/html", body, null);
        return;
    }

    createMilestoneCreatedEvent(allocator, title, description_owned, due_at_owned) catch |err| {
        const message = shared.writeFailureMessage(err, "Could not create the milestone. Check that Gitomi is initialized and commit signing is configured.");
        const body = try renderMilestoneForm(allocator, repo, null, message, title_owned, description_owned, due_at_owned, "open", csrf_token);
        defer allocator.free(body);
        try sendResponse(allocator, stream, shared.writeFailureStatus(err), shared.writeFailureReason(err), "text/html", body, null);
        return;
    };

    try sendRedirect(allocator, stream, "/milestones");
}

fn handleMilestoneUpdatePost(allocator: Allocator, repo: Repo, stream: std.net.Stream, raw_ref: []const u8, csrf_token: []const u8, form_body: []const u8) !void {
    try index.ensureIndex(allocator, repo);
    const milestone_id = index.resolveMilestoneId(allocator, repo, raw_ref) catch {
        try sendPlainResponse(allocator, stream, 404, "Not Found", "Milestone not found\n");
        return;
    };
    defer allocator.free(milestone_id);

    const action_owned = (try formValueOwned(allocator, form_body, "action")) orelse try allocator.dupe(u8, "update");
    defer allocator.free(action_owned);
    const action = std.mem.trim(u8, action_owned, " \t\r\n");
    const return_to = try milestoneReturnTargetOwned(allocator, form_body, "/milestones");
    defer allocator.free(return_to);
    if (std.mem.eql(u8, action, "close") or std.mem.eql(u8, action, "reopen")) {
        const state: []const u8 = if (std.mem.eql(u8, action, "close")) "closed" else "open";
        createMilestoneStringEvent(allocator, milestone_id, "milestone.state_set", "state", state) catch |err| {
            try sendPlainResponse(allocator, stream, shared.writeFailureStatus(err), shared.writeFailureReason(err), shared.writeFailureMessage(err, "Could not update milestone state\n"));
            return;
        };
        try sendRedirect(allocator, stream, return_to);
        return;
    }
    if (std.mem.eql(u8, action, "delete")) {
        createMilestoneDeletedEvent(allocator, milestone_id) catch |err| {
            try sendPlainResponse(allocator, stream, shared.writeFailureStatus(err), shared.writeFailureReason(err), shared.writeFailureMessage(err, "Could not delete milestone\n"));
            return;
        };
        try sendRedirect(allocator, stream, "/milestones");
        return;
    }
    if (std.mem.eql(u8, action, "add-issues")) {
        try handleMilestoneAddIssuesPost(allocator, repo, stream, milestone_id, return_to, form_body);
        return;
    }

    const title_owned = (try formValueOwned(allocator, form_body, "title")) orelse try allocator.dupe(u8, "");
    defer allocator.free(title_owned);
    const description_owned = (try formValueOwned(allocator, form_body, "description")) orelse try allocator.dupe(u8, "");
    defer allocator.free(description_owned);
    const due_at_owned = (try formValueOwned(allocator, form_body, "due_at")) orelse try allocator.dupe(u8, "");
    defer allocator.free(due_at_owned);
    const state_owned = (try formValueOwned(allocator, form_body, "state")) orelse try allocator.dupe(u8, "open");
    defer allocator.free(state_owned);

    const title = std.mem.trim(u8, title_owned, " \t\r\n");
    const state = std.mem.trim(u8, state_owned, " \t\r\n");
    if (title.len == 0) {
        const body = try renderMilestoneForm(allocator, repo, raw_ref, "Title is required.", title_owned, description_owned, due_at_owned, state_owned, csrf_token);
        defer allocator.free(body);
        try sendResponse(allocator, stream, 422, "Unprocessable Entity", "text/html", body, null);
        return;
    }
    if (!validMilestoneState(state)) {
        const body = try renderMilestoneForm(allocator, repo, raw_ref, "State must be open or closed.", title_owned, description_owned, due_at_owned, state_owned, csrf_token);
        defer allocator.free(body);
        try sendResponse(allocator, stream, 422, "Unprocessable Entity", "text/html", body, null);
        return;
    }

    const update = event_mod.MilestoneUpdate{
        .title = title,
        .description = description_owned,
        .due_at = due_at_owned,
        .state = state,
    };
    createMilestoneUpdatedEvent(allocator, milestone_id, update) catch |err| {
        const message = shared.writeFailureMessage(err, "Could not update the milestone. Check that your actor can manage milestones.");
        const body = try renderMilestoneForm(allocator, repo, raw_ref, message, title_owned, description_owned, due_at_owned, state_owned, csrf_token);
        defer allocator.free(body);
        try sendResponse(allocator, stream, shared.writeFailureStatus(err), shared.writeFailureReason(err), "text/html", body, null);
        return;
    };
    try sendRedirect(allocator, stream, return_to);
}

fn handleMilestoneAddIssuesPost(
    allocator: Allocator,
    repo: Repo,
    stream: std.net.Stream,
    milestone_id: []const u8,
    return_to: []const u8,
    form_body: []const u8,
) !void {
    var issue_refs = try formValuesOwned(allocator, form_body, "issue");
    defer {
        for (issue_refs.items) |value| allocator.free(value);
        issue_refs.deinit(allocator);
    }
    if (issue_refs.items.len == 0) {
        try sendRedirect(allocator, stream, return_to);
        return;
    }

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    const milestone_title = loadMilestoneTitleByIdOwned(allocator, &db, milestone_id) catch {
        try sendPlainResponse(allocator, stream, 404, "Not Found", "Milestone not found\n");
        return;
    };
    defer allocator.free(milestone_title);

    var issue_ids: std.ArrayList([]u8) = .empty;
    defer {
        for (issue_ids.items) |issue_id| allocator.free(issue_id);
        issue_ids.deinit(allocator);
    }

    for (issue_refs.items) |raw_issue_ref| {
        const issue_ref = std.mem.trim(u8, raw_issue_ref, " \t\r\n");
        if (issue_ref.len == 0) continue;
        const issue_id = index.resolveIssueId(allocator, repo, issue_ref) catch {
            try sendPlainResponse(allocator, stream, 404, "Not Found", "Issue not found\n");
            return;
        };
        if (containsString(issue_ids.items, issue_id)) {
            allocator.free(issue_id);
            continue;
        }
        issue_ids.append(allocator, issue_id) catch |err| {
            allocator.free(issue_id);
            return err;
        };
    }
    if (issue_ids.items.len == 0) {
        try sendRedirect(allocator, stream, return_to);
        return;
    }

    for (issue_ids.items) |issue_id| {
        createIssueStringEvent(allocator, issue_id, "issue.milestone_set", "milestone", milestone_title) catch |err| {
            try sendPlainResponse(allocator, stream, shared.writeFailureStatus(err), shared.writeFailureReason(err), shared.writeFailureMessage(err, "Could not add issues to milestone\n"));
            return;
        };
    }

    try sendRedirect(allocator, stream, return_to);
}

fn formValuesOwned(allocator: Allocator, body: []const u8, wanted_key: []const u8) !std.ArrayList([]u8) {
    var values: std.ArrayList([]u8) = .empty;
    errdefer {
        for (values.items) |value| allocator.free(value);
        values.deinit(allocator);
    }

    var pairs = std.mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const raw_key = pair[0..eq];
        const raw_value = if (eq < pair.len) pair[eq + 1 ..] else "";
        const key = try percentDecodeForm(allocator, raw_key);
        defer allocator.free(key);
        if (!std.mem.eql(u8, key, wanted_key)) continue;
        const value = try percentDecodeForm(allocator, raw_value);
        values.append(allocator, value) catch |err| {
            allocator.free(value);
            return err;
        };
    }
    return values;
}

fn containsString(values: []const []u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

fn validMilestoneState(state: []const u8) bool {
    return std.mem.eql(u8, state, "open") or std.mem.eql(u8, state, "closed");
}

fn milestoneReturnTargetOwned(allocator: Allocator, form_body: []const u8, fallback: []const u8) ![]u8 {
    const owned = (try formValueOwned(allocator, form_body, "return_to")) orelse return try allocator.dupe(u8, fallback);
    errdefer allocator.free(owned);
    if (!isSafeMilestoneReturnTarget(owned)) {
        allocator.free(owned);
        return try allocator.dupe(u8, fallback);
    }
    return owned;
}

fn isSafeMilestoneReturnTarget(value: []const u8) bool {
    if (value.len == 0 or value[0] != '/') return false;
    if (value.len > 1 and value[1] == '/') return false;
    if (!std.mem.startsWith(u8, value, "/milestones")) return false;
    return std.mem.indexOfAny(u8, value, "\r\n") == null;
}

fn loadMilestoneTitleByIdOwned(allocator: Allocator, db: *SqliteDb, milestone_id: []const u8) ![]u8 {
    var stmt = try db.prepare(
        \\SELECT title
        \\FROM milestones
        \\WHERE id = ?
    );
    defer stmt.deinit();
    try stmt.bindText(1, milestone_id);
    if (!(try stmt.step())) return error.MilestoneNotFound;
    return try stmt.columnTextDup(allocator, 0);
}

fn loadMilestoneFormData(allocator: Allocator, repo: Repo, raw_ref: []const u8) !MilestoneFormData {
    const milestone_id = try index.resolveMilestoneId(allocator, repo, raw_ref);
    defer allocator.free(milestone_id);
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var stmt = try db.prepare(
        \\SELECT id, title, description, due_at, state
        \\FROM milestones
        \\WHERE id = ?
    );
    defer stmt.deinit();
    try stmt.bindText(1, milestone_id);
    if (!(try stmt.step())) return error.MilestoneNotFound;
    return .{
        .id = try stmt.columnTextDup(allocator, 0),
        .title = try stmt.columnTextDup(allocator, 1),
        .description = try stmt.columnTextDup(allocator, 2),
        .due_at = try stmt.columnTextDup(allocator, 3),
        .state = try stmt.columnTextDup(allocator, 4),
    };
}

fn renderMilestoneNotFound(allocator: Allocator, repo: Repo, raw_ref: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try appendShellStart(&buf, allocator, repo, "Milestone Not Found", "projects");
    const detail = try std.fmt.allocPrint(allocator, "No milestone matches {s}.", .{raw_ref});
    defer allocator.free(detail);
    try shared.appendEmptyState(&buf, allocator, "Milestone not found.", detail);
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

test "milestone summary includes issue-only milestone assignments" {
    const allocator = std.testing.allocator;
    var db = try SqliteDb.openWithOptions(allocator, ":memory:", sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_CREATE, true, .{ .enable_wal = false });
    defer db.deinit();
    try index.createIndexSchema(&db);
    try db.exec(
        \\INSERT INTO milestones(
        \\  id,
        \\  title, title_occurred_at, title_actor_principal, title_event_hash,
        \\  description, description_occurred_at, description_actor_principal, description_event_hash,
        \\  due_at, due_at_occurred_at, due_at_actor_principal, due_at_event_hash,
        \\  state, state_occurred_at, state_actor_principal, state_event_hash,
        \\  created_at, author_principal, author_device
        \\) VALUES (
        \\  'milestone-explicit',
        \\  'Explicit', '2026-05-18T00:00:00Z', 'alice', 'hash-explicit-title',
        \\  '', '2026-05-18T00:00:00Z', 'alice', 'hash-explicit-description',
        \\  '', '2026-05-18T00:00:00Z', 'alice', 'hash-explicit-due',
        \\  'open', '2026-05-18T00:00:00Z', 'alice', 'hash-explicit-state',
        \\  '2026-05-18T00:00:00Z', 'alice', 'laptop'
        \\);
        \\INSERT INTO issues(
        \\  id,
        \\  title, title_occurred_at, title_actor_principal, title_event_hash,
        \\  body, body_occurred_at, body_actor_principal, body_event_hash,
        \\  state, state_occurred_at, state_actor_principal, state_event_hash,
        \\  opened_at, author_principal, author_device
        \\) VALUES
        \\  ('issue-explicit',
        \\   'Explicit issue', '2026-05-18T00:00:00Z', 'alice', 'hash-issue-explicit-title',
        \\   '', '2026-05-18T00:00:00Z', 'alice', 'hash-issue-explicit-body',
        \\   'open', '2026-05-18T00:00:00Z', 'alice', 'hash-issue-explicit-state',
        \\   '2026-05-18T00:00:00Z', 'alice', 'laptop'),
        \\  ('issue-implicit',
        \\   'Implicit issue', '2026-05-18T00:01:00Z', 'alice', 'hash-issue-implicit-title',
        \\   '', '2026-05-18T00:01:00Z', 'alice', 'hash-issue-implicit-body',
        \\   'open', '2026-05-18T00:01:00Z', 'alice', 'hash-issue-implicit-state',
        \\   '2026-05-18T00:01:00Z', 'alice', 'laptop');
        \\INSERT INTO issue_metadata(
        \\  issue_id, source_author, source_identity, source_email, source_avatar_url, milestone,
        \\  issue_type, issue_type_occurred_at, issue_type_actor_principal, issue_type_event_hash,
        \\  priority, priority_occurred_at, priority_actor_principal, priority_event_hash,
        \\  status, status_occurred_at, status_actor_principal, status_event_hash
        \\) VALUES
        \\  ('issue-explicit', '', '', '', '', 'Explicit',
        \\   '', '', '', '',
        \\   '', '', '', '',
        \\   '', '', '', ''),
        \\  ('issue-implicit', '', '', '', '', 'Implicit',
        \\   '', '', '', '',
        \\   '', '', '', '',
        \\   '', '', '', '');
    );

    const counts = try loadMilestoneCounts(allocator, &db);
    try std.testing.expectEqual(@as(usize, 2), counts.open);
    try std.testing.expectEqual(@as(usize, 0), counts.closed);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try appendMilestonesSummaryPage(&buf, allocator, &db, .{ .state = .open, .sort = .updated }, counts, "token-123");

    try std.testing.expect(std.mem.indexOf(u8, buf.items, ">Explicit</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, ">Implicit</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "href=\"/issues?milestone=Implicit\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "name=\"_csrf\" value=\"token-123\"") != null);
}
