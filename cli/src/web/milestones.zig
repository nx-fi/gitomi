const std = @import("std");
const event_mod = @import("../event.zig");
const index = @import("../index.zig");
const milestone_mod = @import("../milestone.zig");
const repo_mod = @import("../repo.zig");
const shared = @import("shared.zig");
const issues_page = @import("issues.zig");
const util = @import("../util.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const SqliteDb = index.SqliteDb;
const appendEmptyCell = shared.appendEmptyCell;
const appendEmptyState = shared.appendEmptyState;
const appendSectionHead = shared.appendSectionHead;
const appendShellEnd = shared.appendShellEnd;
const appendShellStart = shared.appendShellStart;
const appendStatePill = shared.appendStatePill;
const appendTemplate = shared.appendTemplate;
const createMilestoneCreatedEvent = milestone_mod.createMilestoneCreatedEvent;
const createMilestoneDeletedEvent = milestone_mod.createMilestoneDeletedEvent;
const createMilestoneStringEvent = milestone_mod.createMilestoneStringEvent;
const createMilestoneUpdatedEvent = milestone_mod.createMilestoneUpdatedEvent;
const formValueOwned = issues_page.formValueOwned;
const literalHref = shared.literalHref;
const sendRedirect = shared.sendRedirect;
const sendResponse = shared.sendResponse;
const sendPlainResponse = shared.sendPlainResponse;
const sqlite = index.sqlite;

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

pub fn renderMilestonesPage(allocator: Allocator, repo: Repo, target: []const u8) ![]u8 {
    if (try shared.renderIndexingPageIfStale(allocator, repo, "Milestones", "projects", target)) |body| return body;
    try index.ensureIndex(allocator, repo);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "Milestones", "projects");
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    const counts = try loadMilestoneCounts(allocator, &db);
    const filters = try milestoneFiltersFromTarget(allocator, target, counts);
    try appendMilestonesSummaryPage(&buf, allocator, &db, filters, counts);
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
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
        \\SELECT state, COUNT(*)
        \\FROM milestones
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

fn appendMilestonesSummaryPage(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, filters: MilestoneFilters, counts: MilestoneCounts) !void {
    try buf.appendSlice(allocator,
        \\<div class="issues-toolbar milestones-toolbar">
        \\  <div>
        \\    <h1>Milestones</h1>
        \\  </div>
        \\  <div class="issues-toolbar-actions">
        \\    <a class="button primary" href="/new-milestone">New milestone</a>
        \\  </div>
        \\</div>
        \\<section class="panel issues-panel milestones-summary-panel">
    );
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
        try appendMilestoneSummaryRow(buf, allocator, id, title, description, due_at, state, issue_count, closed_count);
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
        \\WITH milestone_rows AS (
        \\  SELECT m.id, m.title, m.description, m.due_at, m.state,
        \\         (SELECT COUNT(*)
        \\          FROM issue_metadata im
        \\          JOIN issues i ON i.id = im.issue_id
        \\          WHERE im.milestone = m.title) AS issue_count,
        \\         (SELECT COUNT(*)
        \\          FROM issue_metadata im
        \\          JOIN issues i ON i.id = im.issue_id
        \\          WHERE im.milestone = m.title AND i.state = 'closed') AS closed_count,
        \\         max(m.created_at, m.title_occurred_at, m.description_occurred_at, m.due_at_occurred_at, m.state_occurred_at) AS activity_at
        \\  FROM milestones m
        \\)
        \\SELECT id, title, description, due_at, state, issue_count, closed_count
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
) !void {
    var ref_buf: [util.short_object_ref_len]u8 = undefined;
    const milestone_ref = util.shortObjectRef(&ref_buf, id);
    const open_count = issue_count - @min(issue_count, closed_count);
    const progress = milestoneProgressPercent(closed_count, issue_count);
    try appendTemplate(buf, allocator,
        \\<article class="issue-list-row milestone-list-row is-{state}">
        \\  <div class="issue-row-content milestone-row-main">
        \\    <div class="issue-row-title-line"><span class="issue-milestone-icon" aria-hidden="true"></span><strong class="issue-row-title">{title}</strong><code>^{milestone_ref}</code></div>
    , .{
        .state = state,
        .title = title,
        .milestone_ref = milestone_ref,
    });
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
    try appendMilestoneActionMenu(buf, allocator, milestone_ref, title, state);
    try buf.appendSlice(allocator,
        \\  </div>
        \\</article>
    );
}

fn appendMilestoneActionMenu(buf: *std.ArrayList(u8), allocator: Allocator, milestone_ref: []const u8, title: []const u8, state: []const u8) !void {
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
        \\"><input type="hidden" name="action" value="{action}"><button type="submit" role="menuitem"><span class="milestone-menu-icon milestone-menu-icon-state" aria-hidden="true"></span><span>{label}</span></button></form>
    , .{
        .action = if (std.mem.eql(u8, state, "closed")) "reopen" else "close",
        .label = if (std.mem.eql(u8, state, "closed")) "Reopen" else "Close",
    });
    try buf.appendSlice(allocator, "<form method=\"post\" action=\"/milestones/");
    try shared.appendUrlEncoded(buf, allocator, milestone_ref);
    try buf.appendSlice(allocator,
        \\"><input type="hidden" name="action" value="delete"><button class="danger" type="submit" role="menuitem"><span class="milestone-menu-icon milestone-menu-icon-delete" aria-hidden="true"></span><span>Delete</span></button></form>
        \\  </div>
        \\</details>
    );
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

fn issueWord(count: usize) []const u8 {
    return if (count == 1) "issue" else "issues";
}

pub fn appendMilestonesPanel(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb) !void {
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
        \\SELECT m.id, m.title, m.description, m.due_at, m.state,
        \\       (SELECT COUNT(*)
        \\        FROM issue_metadata im
        \\        JOIN issues i ON i.id = im.issue_id
        \\        WHERE im.milestone = m.title) AS issue_count,
        \\       (SELECT COUNT(*)
        \\        FROM issue_metadata im
        \\        JOIN issues i ON i.id = im.issue_id
        \\        WHERE im.milestone = m.title AND i.state = 'closed') AS closed_count
        \\FROM milestones m
        \\ORDER BY
        \\  CASE m.state WHEN 'open' THEN 0 ELSE 1 END,
        \\  CASE WHEN m.due_at = '' THEN 1 ELSE 0 END,
        \\  m.due_at,
        \\  lower(m.title),
        \\  m.id
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
        try appendMilestoneRow(buf, allocator, id, title, description, due_at, state, issue_count, closed_count);
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
) !void {
    var ref_buf: [util.short_object_ref_len]u8 = undefined;
    const milestone_ref = util.shortObjectRef(&ref_buf, id);
    try buf.appendSlice(allocator, "<tr><td><div class=\"milestone-title-cell\"><span class=\"issue-milestone-icon\" aria-hidden=\"true\"></span><div><strong>");
    try shared.appendHtml(buf, allocator, title);
    try appendTemplate(buf, allocator, "</strong><code>^{milestone_ref}</code>", .{ .milestone_ref = milestone_ref });
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
    try appendMilestoneActionMenu(buf, allocator, milestone_ref, title, state);
    try buf.appendSlice(allocator, "</div></td></tr>");
}

pub fn renderMilestoneFormFromRef(allocator: Allocator, repo: Repo, raw_ref: []const u8) ![]u8 {
    try index.ensureIndex(allocator, repo);
    var data = loadMilestoneFormData(allocator, repo, raw_ref) catch return renderMilestoneNotFound(allocator, repo, raw_ref);
    defer data.deinit(allocator);
    return renderMilestoneForm(allocator, repo, raw_ref, null, data.title, data.description, data.due_at, data.state);
}

pub fn renderNewMilestoneForm(allocator: Allocator, repo: Repo) ![]u8 {
    return renderMilestoneForm(allocator, repo, null, null, "", "", "", "open");
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
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const editing = raw_ref != null;
    try appendShellStart(&buf, allocator, repo, if (editing) "Edit Milestone" else "New Milestone", "projects");
    try buf.appendSlice(allocator, "<section class=\"panel form-panel milestone-form-panel\">");
    try appendTemplate(&buf, allocator,
        \\<div class="project-create-head">
        \\  <div>
        \\    <p class="eyebrow">Projects</p>
        \\    <h1>{heading}</h1>
        \\  </div>
        \\  <a class="button secondary" href="/milestones" aria-label="Close milestone form">Close</a>
        \\</div>
    , .{ .heading = if (editing) "Edit milestone" else "Create milestone" });
    if (error_message) |message| {
        try appendTemplate(&buf, allocator, "<div class=\"flash error\">{message}</div>", .{ .message = message });
    }
    try buf.appendSlice(allocator, "<form class=\"issue-form\" method=\"post\" action=\"");
    if (raw_ref) |value| {
        try buf.appendSlice(allocator, "/milestones/");
        try shared.appendUrlEncoded(&buf, allocator, value);
    } else {
        try buf.appendSlice(allocator, "/milestones");
    }
    try appendTemplate(&buf, allocator,
        \\">
        \\  <input type="hidden" name="action" value="{action}">
        \\  <label>Title<input name="title" value="{title_value}" required autofocus></label>
    , .{
        .action = if (editing) "update" else "create",
        .title_value = title_value,
    });
    try appendTemplate(&buf, allocator,
        \\  <label>Description<textarea name="description" rows="5">{description_value}</textarea></label>
        \\  <label>Due date<input name="due_at" value="{due_at_value}" placeholder="2026-06-30"></label>
    , .{
        .description_value = description_value,
        .due_at_value = due_at_value,
    });
    if (editing) {
        try buf.appendSlice(allocator, "<label>State<select name=\"state\">");
        try appendStateOption(&buf, allocator, "open", state_value);
        try appendStateOption(&buf, allocator, "closed", state_value);
        try buf.appendSlice(allocator, "</select></label>");
    }
    try buf.appendSlice(allocator,
        \\  <div class="form-actions">
        \\    <a class="button secondary" href="/milestones">Cancel</a>
        \\    <button class="button primary" type="submit">Save milestone</button>
        \\  </div>
        \\</form>
        \\</section>
    );
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn appendStateOption(buf: *std.ArrayList(u8), allocator: Allocator, value: []const u8, selected: []const u8) !void {
    try appendTemplate(buf, allocator, "<option value=\"{value}\"", .{ .value = value });
    if (std.mem.eql(u8, value, selected)) try buf.appendSlice(allocator, " selected");
    try appendTemplate(buf, allocator, ">{value}</option>", .{ .value = value });
}

pub fn handleMilestonePost(allocator: Allocator, repo: Repo, stream: std.net.Stream, raw_ref: ?[]const u8, form_body: []const u8) !void {
    if (raw_ref) |milestone_ref| {
        try handleMilestoneUpdatePost(allocator, repo, stream, milestone_ref, form_body);
        return;
    }
    try handleMilestoneCreatePost(allocator, repo, stream, form_body);
}

fn handleMilestoneCreatePost(allocator: Allocator, repo: Repo, stream: std.net.Stream, form_body: []const u8) !void {
    const title_owned = (try formValueOwned(allocator, form_body, "title")) orelse try allocator.dupe(u8, "");
    defer allocator.free(title_owned);
    const description_owned = (try formValueOwned(allocator, form_body, "description")) orelse try allocator.dupe(u8, "");
    defer allocator.free(description_owned);
    const due_at_owned = (try formValueOwned(allocator, form_body, "due_at")) orelse try allocator.dupe(u8, "");
    defer allocator.free(due_at_owned);

    const title = std.mem.trim(u8, title_owned, " \t\r\n");
    if (title.len == 0) {
        const body = try renderMilestoneForm(allocator, repo, null, "Title is required.", title_owned, description_owned, due_at_owned, "open");
        defer allocator.free(body);
        try sendResponse(allocator, stream, 422, "Unprocessable Entity", "text/html", body, null);
        return;
    }

    createMilestoneCreatedEvent(allocator, title, description_owned, due_at_owned) catch {
        const body = try renderMilestoneForm(allocator, repo, null, "Could not create the milestone. Check that Gitomi is initialized and commit signing is configured.", title_owned, description_owned, due_at_owned, "open");
        defer allocator.free(body);
        try sendResponse(allocator, stream, 500, "Internal Server Error", "text/html", body, null);
        return;
    };

    try sendRedirect(allocator, stream, "/milestones");
}

fn handleMilestoneUpdatePost(allocator: Allocator, repo: Repo, stream: std.net.Stream, raw_ref: []const u8, form_body: []const u8) !void {
    try index.ensureIndex(allocator, repo);
    const milestone_id = index.resolveMilestoneId(allocator, repo, raw_ref) catch {
        try sendPlainResponse(allocator, stream, 404, "Not Found", "Milestone not found\n");
        return;
    };
    defer allocator.free(milestone_id);

    const action_owned = (try formValueOwned(allocator, form_body, "action")) orelse try allocator.dupe(u8, "update");
    defer allocator.free(action_owned);
    const action = std.mem.trim(u8, action_owned, " \t\r\n");
    if (std.mem.eql(u8, action, "close") or std.mem.eql(u8, action, "reopen")) {
        const state: []const u8 = if (std.mem.eql(u8, action, "close")) "closed" else "open";
        createMilestoneStringEvent(allocator, milestone_id, "milestone.state_set", "state", state) catch {
            try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not update milestone state\n");
            return;
        };
        try sendRedirect(allocator, stream, "/milestones");
        return;
    }
    if (std.mem.eql(u8, action, "delete")) {
        createMilestoneDeletedEvent(allocator, milestone_id) catch {
            try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not delete milestone\n");
            return;
        };
        try sendRedirect(allocator, stream, "/milestones");
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
        const body = try renderMilestoneForm(allocator, repo, raw_ref, "Title is required.", title_owned, description_owned, due_at_owned, state_owned);
        defer allocator.free(body);
        try sendResponse(allocator, stream, 422, "Unprocessable Entity", "text/html", body, null);
        return;
    }
    if (!validMilestoneState(state)) {
        const body = try renderMilestoneForm(allocator, repo, raw_ref, "State must be open or closed.", title_owned, description_owned, due_at_owned, state_owned);
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
    createMilestoneUpdatedEvent(allocator, milestone_id, update) catch {
        const body = try renderMilestoneForm(allocator, repo, raw_ref, "Could not update the milestone. Check that your actor can manage milestones.", title_owned, description_owned, due_at_owned, state_owned);
        defer allocator.free(body);
        try sendResponse(allocator, stream, 500, "Internal Server Error", "text/html", body, null);
        return;
    };
    try sendRedirect(allocator, stream, "/milestones");
}

fn validMilestoneState(state: []const u8) bool {
    return std.mem.eql(u8, state, "open") or std.mem.eql(u8, state, "closed");
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
