const std = @import("std");
const index = @import("../../index.zig");
const repo_mod = @import("../../repo.zig");
const util = @import("../../util.zig");
const project_issue_render = @import("issue_render.zig");
const project_views = @import("views.zig");
const shared = @import("../shared.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const SqliteDb = index.SqliteDb;
const appendRelativeTime = shared.appendRelativeTime;
const appendTemplate = shared.appendTemplate;

pub const ProjectPageTab = enum {
    overview,
    table,
    board,
    roadmap,
    activity,
};

const ProjectSummary = struct {
    id: []u8,
    name: []u8,
    description: []u8,
    state: []u8,
    created_at: []u8,
    author_principal: []u8,

    fn deinit(self: *ProjectSummary, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.state);
        allocator.free(self.created_at);
        allocator.free(self.author_principal);
    }
};

const ProjectMetrics = struct {
    issue_count: usize = 0,
    open_issue_count: usize = 0,
    closed_issue_count: usize = 0,
    comment_count: usize = 0,
    assignee_count: usize = 0,
    label_count: usize = 0,
    milestone_count: usize = 0,
    field_count: usize = 0,
    view_count: usize = 0,
    top_status: []u8,
    top_status_count: usize = 0,
    top_priority: []u8,
    top_priority_count: usize = 0,
    start_at: []u8,
    end_at: []u8,
    lead: []u8,

    fn deinit(self: *ProjectMetrics, allocator: Allocator) void {
        allocator.free(self.top_status);
        allocator.free(self.top_priority);
        allocator.free(self.start_at);
        allocator.free(self.end_at);
        allocator.free(self.lead);
    }
};

pub fn appendProjectOverview(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    repo: Repo,
    db: *SqliteDb,
    project: []const u8,
) !void {
    var summary = try loadProjectSummary(allocator, db, project);
    defer summary.deinit(allocator);
    var metrics = try loadProjectMetrics(allocator, db, &summary);
    defer metrics.deinit(allocator);

    try buf.appendSlice(allocator, "<section class=\"project-overview-page\">");
    try appendProjectOverviewHeader(buf, allocator, &summary, &metrics);
    try appendProjectPageTabs(buf, allocator, project, .overview, metrics.issue_count);
    try buf.appendSlice(allocator,
        \\<div class="project-overview-layout">
        \\  <div class="project-overview-main">
    );
    try appendProjectInlineProperties(buf, allocator, repo, &summary, &metrics);
    try appendProjectResources(buf, allocator, project);
    try appendProjectUpdateBox(buf, allocator);
    try appendProjectDescription(buf, allocator, &summary);
    try appendProjectMilestones(buf, allocator, db, project, .main);
    try buf.appendSlice(allocator,
        \\  </div>
        \\  <aside class="project-overview-sidebar">
    );
    try appendProjectPropertiesPanel(buf, allocator, repo, &summary, &metrics);
    try appendProjectMilestones(buf, allocator, db, project, .sidebar);
    try appendProjectActivityPanel(buf, allocator, db, &summary, project);
    try buf.appendSlice(allocator,
        \\  </aside>
        \\</div>
        \\</section>
    );
}

pub fn appendProjectActivityView(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    repo: Repo,
    db: *SqliteDb,
    project: []const u8,
) !void {
    var summary = try loadProjectSummary(allocator, db, project);
    defer summary.deinit(allocator);
    var metrics = try loadProjectMetrics(allocator, db, &summary);
    defer metrics.deinit(allocator);

    try buf.appendSlice(allocator, "<section class=\"project-overview-page project-activity-page\">");
    try appendProjectOverviewHeader(buf, allocator, &summary, &metrics);
    try appendProjectPageTabs(buf, allocator, project, .activity, metrics.issue_count);
    try buf.appendSlice(allocator,
        \\<div class="project-overview-layout">
        \\  <div class="project-overview-main">
    );
    try appendProjectActivityMain(buf, allocator, db, &summary, project);
    try buf.appendSlice(allocator,
        \\  </div>
        \\  <aside class="project-overview-sidebar">
    );
    try appendProjectPropertiesPanel(buf, allocator, repo, &summary, &metrics);
    try appendProjectMilestones(buf, allocator, db, project, .sidebar);
    try buf.appendSlice(allocator,
        \\  </aside>
        \\</div>
        \\</section>
    );
}

fn loadProjectSummary(allocator: Allocator, db: *SqliteDb, project: []const u8) !ProjectSummary {
    var stmt = try db.prepare(
        \\SELECT id, name, description, state, created_at, author_principal
        \\FROM projects
        \\WHERE name = ?
        \\ORDER BY created_at DESC, id DESC
        \\LIMIT 1
    );
    defer stmt.deinit();
    try stmt.bindText(1, project);
    if (try stmt.step()) {
        return .{
            .id = try stmt.columnTextDup(allocator, 0),
            .name = try stmt.columnTextDup(allocator, 1),
            .description = try stmt.columnTextDup(allocator, 2),
            .state = try stmt.columnTextDup(allocator, 3),
            .created_at = try stmt.columnTextDup(allocator, 4),
            .author_principal = try stmt.columnTextDup(allocator, 5),
        };
    }

    return .{
        .id = try allocator.dupe(u8, ""),
        .name = try allocator.dupe(u8, project),
        .description = try allocator.dupe(u8, ""),
        .state = try allocator.dupe(u8, "open"),
        .created_at = try allocator.dupe(u8, ""),
        .author_principal = try allocator.dupe(u8, ""),
    };
}

fn loadProjectMetrics(allocator: Allocator, db: *SqliteDb, summary: *const ProjectSummary) !ProjectMetrics {
    var metrics = ProjectMetrics{
        .top_status = try allocator.dupe(u8, ""),
        .top_priority = try allocator.dupe(u8, ""),
        .start_at = try allocator.dupe(u8, ""),
        .end_at = try allocator.dupe(u8, ""),
        .lead = try allocator.dupe(u8, ""),
    };
    errdefer metrics.deinit(allocator);

    try loadProjectIssueCounts(db, summary.name, &metrics);
    try loadProjectTopStatus(allocator, db, summary.name, &metrics);
    try loadProjectTopPriority(allocator, db, summary.name, &metrics);
    try loadProjectDateRange(allocator, db, summary.name, &metrics);
    try loadProjectLead(allocator, db, summary.name, summary.author_principal, &metrics);
    if (summary.id.len != 0) {
        metrics.field_count = try countProjectRows(db, "project_fields", summary.id, "state != 'removed'");
        metrics.view_count = try countProjectRows(db, "project_views", summary.id, "state != 'removed'");
    }
    return metrics;
}

fn projectItemsCte(comptime body: []const u8) []const u8 {
    return (
        \\WITH project_items AS (
        \\  SELECT issue_id, column_name AS legacy_column
        \\  FROM issue_projects
        \\  WHERE project = ?
        \\  UNION
        \\  SELECT pm.issue_id, ''
        \\  FROM project_memberships pm
        \\  JOIN projects p ON p.id = pm.project_id
        \\  WHERE p.name = ?
        \\)
    ) ++ body;
}

fn loadProjectIssueCounts(db: *SqliteDb, project: []const u8, metrics: *ProjectMetrics) !void {
    var stmt = try db.prepare(projectItemsCte(
        \\SELECT
        \\  COUNT(DISTINCT i.id),
        \\  COUNT(DISTINCT CASE WHEN i.state = 'open' THEN i.id END),
        \\  COUNT(DISTINCT CASE WHEN i.state = 'closed' THEN i.id END),
        \\  COUNT(DISTINCT ia.assignee),
        \\  COUNT(DISTINCT il.label),
        \\  COUNT(DISTINCT NULLIF(im.milestone, '')),
        \\  COUNT(DISTINCT c.id)
        \\FROM project_items p
        \\JOIN issues i ON i.id = p.issue_id
        \\LEFT JOIN issue_assignees ia ON ia.issue_id = i.id
        \\LEFT JOIN issue_labels il ON il.issue_id = i.id
        \\LEFT JOIN issue_metadata im ON im.issue_id = i.id
        \\LEFT JOIN comments c ON c.parent_kind = 'issue' AND c.parent_id = i.id
    ));
    defer stmt.deinit();
    try bindProjectNameTwice(&stmt, project);
    if (!(try stmt.step())) return;
    metrics.issue_count = @intCast(stmt.columnInt64(0));
    metrics.open_issue_count = @intCast(stmt.columnInt64(1));
    metrics.closed_issue_count = @intCast(stmt.columnInt64(2));
    metrics.assignee_count = @intCast(stmt.columnInt64(3));
    metrics.label_count = @intCast(stmt.columnInt64(4));
    metrics.milestone_count = @intCast(stmt.columnInt64(5));
    metrics.comment_count = @intCast(stmt.columnInt64(6));
}

fn loadProjectTopStatus(allocator: Allocator, db: *SqliteDb, project: []const u8, metrics: *ProjectMetrics) !void {
    var stmt = try db.prepare(projectItemsCte(
        \\SELECT
        \\  CASE
        \\    WHEN COALESCE(im.status, '') <> '' THEN im.status
        \\    WHEN p.legacy_column <> '' THEN p.legacy_column
        \\    ELSE ''
        \\  END AS status_value,
        \\  COUNT(DISTINCT p.issue_id)
        \\FROM project_items p
        \\JOIN issues i ON i.id = p.issue_id
        \\LEFT JOIN issue_metadata im ON im.issue_id = p.issue_id
        \\GROUP BY status_value
        \\ORDER BY COUNT(DISTINCT p.issue_id) DESC, lower(status_value), status_value
        \\LIMIT 1
    ));
    defer stmt.deinit();
    try bindProjectNameTwice(&stmt, project);
    if (!(try stmt.step())) return;
    allocator.free(metrics.top_status);
    metrics.top_status = try stmt.columnTextDup(allocator, 0);
    metrics.top_status_count = @intCast(stmt.columnInt64(1));
}

fn loadProjectTopPriority(allocator: Allocator, db: *SqliteDb, project: []const u8, metrics: *ProjectMetrics) !void {
    var stmt = try db.prepare(projectItemsCte(
        \\SELECT COALESCE(im.priority, ''), COUNT(DISTINCT p.issue_id)
        \\FROM project_items p
        \\JOIN issues i ON i.id = p.issue_id
        \\LEFT JOIN issue_metadata im ON im.issue_id = p.issue_id
        \\GROUP BY COALESCE(im.priority, '')
        \\ORDER BY COUNT(DISTINCT p.issue_id) DESC, COALESCE(im.priority, '')
        \\LIMIT 1
    ));
    defer stmt.deinit();
    try bindProjectNameTwice(&stmt, project);
    if (!(try stmt.step())) return;
    allocator.free(metrics.top_priority);
    metrics.top_priority = try stmt.columnTextDup(allocator, 0);
    metrics.top_priority_count = @intCast(stmt.columnInt64(1));
}

fn loadProjectDateRange(allocator: Allocator, db: *SqliteDb, project: []const u8, metrics: *ProjectMetrics) !void {
    var stmt = try db.prepare(
        \\SELECT
        \\  COALESCE(MIN(CASE WHEN pf.key = 'start_at' THEN json_extract(pfv.value_json, '$') END), ''),
        \\  COALESCE(
        \\    MAX(CASE WHEN pf.key = 'end_at' THEN json_extract(pfv.value_json, '$') END),
        \\    MAX(CASE WHEN pf.key = 'target_at' THEN json_extract(pfv.value_json, '$') END),
        \\    ''
        \\  )
        \\FROM projects p
        \\JOIN project_fields pf ON pf.project_id = p.id
        \\JOIN project_field_values pfv ON pfv.project_id = p.id AND pfv.field_id = pf.id
        \\WHERE p.name = ?
        \\  AND pf.key IN ('start_at', 'end_at', 'target_at')
        \\  AND pf.state != 'removed'
        \\  AND COALESCE(json_extract(pfv.value_json, '$'), '') <> ''
    );
    defer stmt.deinit();
    try stmt.bindText(1, project);
    if (!(try stmt.step())) return;
    allocator.free(metrics.start_at);
    metrics.start_at = try stmt.columnTextDup(allocator, 0);
    allocator.free(metrics.end_at);
    metrics.end_at = try stmt.columnTextDup(allocator, 1);
}

fn loadProjectLead(allocator: Allocator, db: *SqliteDb, project: []const u8, fallback: []const u8, metrics: *ProjectMetrics) !void {
    var stmt = try db.prepare(projectItemsCte(
        \\SELECT ia.assignee, COUNT(DISTINCT ia.issue_id)
        \\FROM project_items p
        \\JOIN issue_assignees ia ON ia.issue_id = p.issue_id
        \\GROUP BY ia.assignee
        \\ORDER BY COUNT(DISTINCT ia.issue_id) DESC, lower(ia.assignee), ia.assignee
        \\LIMIT 1
    ));
    defer stmt.deinit();
    try bindProjectNameTwice(&stmt, project);
    allocator.free(metrics.lead);
    if (try stmt.step()) {
        metrics.lead = try stmt.columnTextDup(allocator, 0);
    } else {
        metrics.lead = try allocator.dupe(u8, fallback);
    }
}

fn countProjectRows(db: *SqliteDb, comptime table: []const u8, project_id: []const u8, comptime where_extra: []const u8) !usize {
    var stmt = try db.prepare("SELECT COUNT(*) FROM " ++ table ++ " WHERE project_id = ? AND " ++ where_extra);
    defer stmt.deinit();
    try stmt.bindText(1, project_id);
    if (!(try stmt.step())) return 0;
    return @intCast(stmt.columnInt64(0));
}

fn bindProjectNameTwice(stmt: *index.SqliteStmt, project: []const u8) !void {
    try stmt.bindText(1, project);
    try stmt.bindText(2, project);
}

fn appendProjectOverviewHeader(buf: *std.ArrayList(u8), allocator: Allocator, summary: *const ProjectSummary, metrics: *const ProjectMetrics) !void {
    try appendTemplate(buf, allocator,
        \\<header class="project-overview-head">
        \\  <div class="project-overview-title">
        \\    <span class="project-overview-icon" aria-hidden="true"></span>
        \\    <div>
        \\      <p class="eyebrow">Project</p>
        \\      <h1>{project}</h1>
    , .{ .project = summary.name });
    if (summary.description.len == 0) {
        try buf.appendSlice(allocator, "<p class=\"muted\">Add a short summary...</p>");
    } else {
        try appendTemplate(buf, allocator, "<p>{description}</p>", .{ .description = summary.description });
    }
    try appendTemplate(buf, allocator,
        \\    </div>
        \\  </div>
        \\  <div class="project-overview-head-stats" aria-label="Project issue summary">
        \\    <span><strong>{issue_count}</strong> issues</span>
        \\    <span><strong>{open_count}</strong> open</span>
        \\    <span><strong>{closed_count}</strong> closed</span>
        \\  </div>
        \\</header>
    , .{
        .issue_count = metrics.issue_count,
        .open_count = metrics.open_issue_count,
        .closed_count = metrics.closed_issue_count,
    });
}

pub fn appendProjectPageTabs(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    project: []const u8,
    active: ProjectPageTab,
    issue_count: usize,
) !void {
    try buf.appendSlice(allocator,
        \\<div class="project-overview-tabs">
        \\  <nav class="project-overview-primary-tabs" aria-label="Project tabs">
    );
    try appendProjectPageTab(buf, allocator, project, active, .overview, "Overview", "project-view-overview-icon", "overview");
    try appendProjectPageTab(buf, allocator, project, active, .table, "Table", "project-view-table-icon", project_views.projectViewValue(.table));
    try appendProjectPageTab(buf, allocator, project, active, .board, "Board", "project-view-board-icon", project_views.projectViewValue(.board));
    try appendProjectPageTab(buf, allocator, project, active, .roadmap, "Roadmap", "project-view-roadmap-icon", project_views.projectViewValue(.roadmap));
    try appendProjectPageTab(buf, allocator, project, active, .activity, "Activity", "button-icon icon-history", "activity");
    try buf.appendSlice(allocator, "<a class=\"project-overview-tab\" href=\"/issues?project=");
    try shared.appendUrlEncoded(buf, allocator, project);
    try appendTemplate(buf, allocator, "\">Issues <span class=\"issue-count-badge\">{issue_count}</span></a>", .{ .issue_count = issue_count });
    try buf.appendSlice(allocator,
        \\  </nav>
        \\</div>
    );
}

fn appendProjectPageTab(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    project: []const u8,
    active: ProjectPageTab,
    tab: ProjectPageTab,
    label: []const u8,
    icon_class: []const u8,
    view_ref: []const u8,
) !void {
    if (active == tab) {
        try appendTemplate(buf, allocator,
            \\<span class="project-overview-tab active"><span class="{icon_class}" aria-hidden="true"></span>{label}</span>
        , .{
            .icon_class = icon_class,
            .label = label,
        });
        return;
    }

    try buf.appendSlice(allocator, "<a class=\"project-overview-tab\" href=\"");
    if (tab == .overview) {
        try appendProjectOverviewHref(buf, allocator, project);
    } else {
        try appendProjectViewHref(buf, allocator, project, view_ref);
    }
    try buf.appendSlice(allocator, "\">");
    try appendTemplate(buf, allocator,
        \\<span class="{icon_class}" aria-hidden="true"></span>{label}</a>
    , .{
        .icon_class = icon_class,
        .label = label,
    });
}

fn appendProjectInlineProperties(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, summary: *const ProjectSummary, metrics: *const ProjectMetrics) !void {
    try buf.appendSlice(allocator, "<section class=\"project-overview-properties-strip\" aria-label=\"Project properties\">");
    try appendProjectProperty(buf, allocator, "Status", "project-overview-status-icon", projectStateLabel(summary.state), .{ .tone = projectStateTone(summary.state) });
    try appendProjectProperty(buf, allocator, "Priority", "project-overview-priority-icon", priorityLabel(metrics.top_priority), .{ .tone = project_issue_render.priorityTone(metrics.top_priority) });
    try appendProjectProperty(buf, allocator, "Lead", "icon-users", if (metrics.lead.len == 0) "No lead" else metrics.lead, .{});
    const date_label = try projectDatesLabelOwned(allocator, metrics);
    defer allocator.free(date_label);
    try appendProjectProperty(buf, allocator, "Dates", "icon-calendar", date_label, .{});
    try appendProjectProperty(buf, allocator, "Teams", "icon-projects", repositoryOwnerLabel(repo), .{});
    try buf.appendSlice(allocator, "</section>");
}

const ProjectPropertyOptions = struct {
    tone: []const u8 = "",
};

fn appendProjectProperty(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    label: []const u8,
    icon_class: []const u8,
    value: []const u8,
    options: ProjectPropertyOptions,
) !void {
    try appendTemplate(buf, allocator,
        \\<div class="project-overview-property">
        \\  <span>{label}</span>
        \\  <strong class="{tone_class}"><span class="button-icon {icon_class}" aria-hidden="true"></span>{value}</strong>
        \\</div>
    , .{
        .label = label,
        .tone_class = projectOverviewToneClass(options.tone),
        .icon_class = icon_class,
        .value = value,
    });
}

fn projectOverviewToneClass(tone: []const u8) []const u8 {
    if (std.mem.eql(u8, tone, "progress")) return "project-overview-property-value tone-progress";
    if (std.mem.eql(u8, tone, "done")) return "project-overview-property-value tone-done";
    if (std.mem.eql(u8, tone, "failed")) return "project-overview-property-value tone-failed";
    if (std.mem.eql(u8, tone, "p0")) return "project-overview-property-value tone-p0";
    if (std.mem.eql(u8, tone, "p1")) return "project-overview-property-value tone-p1";
    if (std.mem.eql(u8, tone, "p2")) return "project-overview-property-value tone-p2";
    if (std.mem.eql(u8, tone, "p3")) return "project-overview-property-value tone-p3";
    return "project-overview-property-value";
}

fn appendProjectResources(buf: *std.ArrayList(u8), allocator: Allocator, project: []const u8) !void {
    try buf.appendSlice(allocator,
        \\<section class="project-overview-section project-overview-resources">
        \\  <div class="project-overview-section-title">
        \\    <h2>Resources</h2>
        \\    <span class="project-overview-add" aria-hidden="true">+</span>
        \\  </div>
        \\  <div class="project-overview-resource-links">
    );
    try appendProjectResourceLink(buf, allocator, project, .table, "Table", "project-view-table-icon");
    try appendProjectResourceLink(buf, allocator, project, .board, "Board", "project-view-board-icon");
    try appendProjectResourceLink(buf, allocator, project, .roadmap, "Roadmap", "project-view-roadmap-icon");
    try buf.appendSlice(allocator,
        \\  </div>
        \\</section>
    );
}

fn appendProjectResourceLink(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    project: []const u8,
    view: project_views.ProjectView,
    label: []const u8,
    icon_class: []const u8,
) !void {
    try buf.appendSlice(allocator, "<a class=\"project-overview-resource-link\" href=\"");
    try appendProjectViewHref(buf, allocator, project, project_views.projectViewValue(view));
    try buf.appendSlice(allocator, "\">");
    try appendTemplate(buf, allocator,
        \\<span class="{icon_class}" aria-hidden="true"></span>{label}</a>
    , .{
        .icon_class = icon_class,
        .label = label,
    });
}

fn appendProjectUpdateBox(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator,
        \\<section class="project-overview-update-box" aria-label="Project updates">
        \\  <span class="button-icon icon-history" aria-hidden="true"></span>
        \\  <span>No project updates yet</span>
        \\</section>
    );
}

fn appendProjectDescription(buf: *std.ArrayList(u8), allocator: Allocator, summary: *const ProjectSummary) !void {
    try buf.appendSlice(allocator,
        \\<section class="project-overview-section">
        \\  <h2>Description</h2>
        \\  <div class="project-overview-description markdown-body">
    );
    if (summary.description.len == 0) {
        try buf.appendSlice(allocator, "<p class=\"muted\">Add description...</p>");
    } else {
        try shared.appendMarkdownSource(buf, allocator, summary.description, .{});
    }
    try buf.appendSlice(allocator,
        \\  </div>
        \\</section>
    );
}

const MilestonePlacement = enum {
    main,
    sidebar,
};

fn appendProjectMilestones(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    project: []const u8,
    placement: MilestonePlacement,
) !void {
    switch (placement) {
        .main => try buf.appendSlice(allocator,
            \\<section class="project-overview-section project-overview-milestones-main">
            \\  <h2>Milestones</h2>
            \\  <div class="project-overview-milestone-list">
        ),
        .sidebar => try buf.appendSlice(allocator,
            \\<section class="project-overview-side-panel project-overview-milestones-side">
            \\  <div class="project-overview-side-panel-head"><h2>Milestones</h2></div>
            \\  <div class="project-overview-milestone-list">
        ),
    }

    var stmt = try db.prepare(projectItemsCte(
        \\SELECT
        \\  im.milestone,
        \\  COUNT(DISTINCT i.id),
        \\  COALESCE(SUM(CASE WHEN i.state = 'closed' THEN 1 ELSE 0 END), 0),
        \\  COALESCE(m.due_at, '')
        \\FROM project_items p
        \\JOIN issues i ON i.id = p.issue_id
        \\JOIN issue_metadata im ON im.issue_id = i.id AND im.milestone <> ''
        \\LEFT JOIN milestones m ON lower(m.title) = lower(im.milestone)
        \\GROUP BY im.milestone, m.due_at
        \\ORDER BY
        \\  CASE WHEN COALESCE(m.due_at, '') = '' THEN 1 ELSE 0 END,
        \\  m.due_at,
        \\  lower(im.milestone),
        \\  im.milestone
        \\LIMIT 6
    ));
    defer stmt.deinit();
    try bindProjectNameTwice(&stmt, project);

    var shown: usize = 0;
    while (try stmt.step()) {
        const title = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(title);
        const total: usize = @intCast(stmt.columnInt64(1));
        const closed: usize = @intCast(stmt.columnInt64(2));
        const due_at = try stmt.columnTextDup(allocator, 3);
        defer allocator.free(due_at);
        try appendProjectMilestoneRow(buf, allocator, title, total, closed, due_at, placement);
        shown += 1;
    }
    if (shown == 0) {
        try buf.appendSlice(allocator, "<p class=\"project-overview-empty\">No milestones assigned.</p>");
    }
    try buf.appendSlice(allocator, "</div></section>");
}

fn appendProjectMilestoneRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    title: []const u8,
    total: usize,
    closed: usize,
    due_at: []const u8,
    placement: MilestonePlacement,
) !void {
    const progress = if (total == 0) 0 else (closed * 100) / total;
    try appendTemplate(buf, allocator,
        \\<article class="project-overview-milestone-row">
        \\  <span class="button-icon icon-milestones" aria-hidden="true"></span>
        \\  <div>
        \\    <strong>{title}</strong>
        \\    <span>{closed}/{total} issues
    , .{
        .title = title,
        .closed = closed,
        .total = total,
    });
    if (due_at.len != 0) {
        const due_label = try dateLabelOwned(allocator, due_at);
        defer allocator.free(due_label);
        try appendTemplate(buf, allocator, " · {due_label}", .{ .due_label = due_label });
    }
    try appendTemplate(buf, allocator,
        \\</span>
        \\  </div>
    , .{});
    if (placement == .main) {
        try appendTemplate(buf, allocator,
            \\  <span class="project-overview-progress" style="--progress: {progress};" aria-label="{progress}% complete"></span>
        , .{ .progress = shared.percent(progress, 100) });
    }
    try buf.appendSlice(allocator, "</article>");
}

fn appendProjectPropertiesPanel(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, summary: *const ProjectSummary, metrics: *const ProjectMetrics) !void {
    try buf.appendSlice(allocator,
        \\<section class="project-overview-side-panel">
        \\  <div class="project-overview-side-panel-head"><h2>Properties</h2></div>
        \\  <dl class="project-overview-side-properties">
    );
    try appendSidebarProperty(buf, allocator, "Status", "project-overview-status-icon", projectStateLabel(summary.state));
    try appendSidebarProperty(buf, allocator, "Priority", "project-overview-priority-icon", priorityLabel(metrics.top_priority));
    try appendSidebarProperty(buf, allocator, "Lead", "icon-users", if (metrics.lead.len == 0) "No lead" else metrics.lead);
    const members_label = try countLabelOwned(allocator, metrics.assignee_count, "member", "members");
    defer allocator.free(members_label);
    const issues_label = try countLabelOwned(allocator, metrics.issue_count, "issue", "issues");
    defer allocator.free(issues_label);
    const labels_label = try countLabelOwned(allocator, metrics.label_count, "label", "labels");
    defer allocator.free(labels_label);
    try appendSidebarProperty(buf, allocator, "Members", "icon-users", members_label);
    try appendSidebarProperty(buf, allocator, "Issues", "icon-issues", issues_label);
    const date_label = try projectDatesLabelOwned(allocator, metrics);
    defer allocator.free(date_label);
    try appendSidebarProperty(buf, allocator, "Dates", "icon-calendar", date_label);
    try appendSidebarProperty(buf, allocator, "Teams", "icon-projects", repositoryOwnerLabel(repo));
    try appendSidebarProperty(buf, allocator, "Slack", "icon-slack", "No Slack channel");
    try appendSidebarProperty(buf, allocator, "Labels", "icon-labels", labels_label);
    try buf.appendSlice(allocator,
        \\  </dl>
        \\</section>
    );
}

fn appendSidebarProperty(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    label: []const u8,
    icon_class: []const u8,
    value: []const u8,
) !void {
    try appendTemplate(buf, allocator,
        \\<div>
        \\  <dt>{label}</dt>
        \\  <dd><span class="button-icon {icon_class}" aria-hidden="true"></span>{value}</dd>
        \\</div>
    , .{
        .label = label,
        .icon_class = icon_class,
        .value = value,
    });
}

fn appendProjectActivityMain(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, summary: *const ProjectSummary, project: []const u8) !void {
    try buf.appendSlice(allocator,
        \\<section class="project-overview-section project-overview-activity-main">
        \\  <div class="project-overview-section-title"><h2>Activity</h2><a class="button secondary" href="/events">See all</a></div>
        \\  <div class="project-overview-activity-list">
    );
    try appendProjectActivityItems(buf, allocator, db, summary, project, 24);
    try buf.appendSlice(allocator,
        \\  </div>
        \\</section>
    );
}

fn appendProjectActivityPanel(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, summary: *const ProjectSummary, project: []const u8) !void {
    try buf.appendSlice(allocator,
        \\<section id="project-activity" class="project-overview-side-panel project-overview-activity">
        \\  <div class="project-overview-side-panel-head"><h2>Activity</h2><a href="/events">See all</a></div>
        \\  <div class="project-overview-activity-list">
    );
    try appendProjectActivityItems(buf, allocator, db, summary, project, 4);
    try buf.appendSlice(allocator,
        \\  </div>
        \\</section>
    );
}

fn appendProjectActivityItems(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    summary: *const ProjectSummary,
    project: []const u8,
    limit: usize,
) !void {
    var shown: usize = 0;
    if (summary.id.len != 0) {
        shown = try appendProjectEvents(buf, allocator, db, summary.id, project, limit);
    }
    if (shown == 0 and summary.created_at.len != 0) {
        try appendTemplate(buf, allocator,
            \\<article>
            \\  <span class="project-overview-activity-icon" aria-hidden="true"></span>
            \\  <p><strong>{actor}</strong> created the project · 
        , .{ .actor = if (summary.author_principal.len == 0) "Unknown" else summary.author_principal });
        try appendRelativeTime(buf, allocator, summary.created_at);
        try buf.appendSlice(allocator, "</p></article>");
        shown += 1;
    }
    if (shown == 0) {
        try buf.appendSlice(allocator, "<p class=\"project-overview-empty\">No project activity yet.</p>");
    }
}

fn appendProjectEvents(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    project_id: []const u8,
    project: []const u8,
    limit: usize,
) !usize {
    var stmt = try db.prepare(projectItemsCte(
        \\SELECT e.event_type, e.subject, e.actor_principal, e.occurred_at, e.object_id, e.object_kind
        \\FROM events e
        \\WHERE e.valid_json != 0
        \\  AND (
        \\    (e.object_kind = 'project' AND e.object_id = ?)
        \\    OR (e.object_kind = 'issue' AND e.object_id IN (SELECT issue_id FROM project_items))
        \\  )
        \\ORDER BY e.ordinal DESC
        \\LIMIT ?
    ));
    defer stmt.deinit();
    try bindProjectNameTwice(&stmt, project);
    try stmt.bindText(3, project_id);
    try stmt.bindInt64(4, @intCast(limit));

    var shown: usize = 0;
    while (try stmt.step()) {
        const event_type = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(event_type);
        const subject = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(subject);
        const actor = try stmt.columnTextDup(allocator, 2);
        defer allocator.free(actor);
        const occurred_at = try stmt.columnTextDup(allocator, 3);
        defer allocator.free(occurred_at);
        const object_id = try stmt.columnTextDup(allocator, 4);
        defer allocator.free(object_id);
        const object_kind = try stmt.columnTextDup(allocator, 5);
        defer allocator.free(object_kind);
        try appendProjectEventRow(buf, allocator, event_type, object_kind, subject, actor, occurred_at, object_id);
        shown += 1;
    }
    return shown;
}

fn appendProjectEventRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    event_type: []const u8,
    object_kind: []const u8,
    subject: []const u8,
    actor: []const u8,
    occurred_at: []const u8,
    object_id: []const u8,
) !void {
    const label = projectEventLabel(event_type, object_kind);
    try appendTemplate(buf, allocator,
        \\<article>
        \\  <span class="project-overview-activity-icon" aria-hidden="true"></span>
        \\  <p><strong>{actor}</strong> {label}
    , .{
        .actor = actor,
        .label = label,
    });
    if (object_id.len != 0) {
        var ref_buf: [util.short_object_ref_len]u8 = undefined;
        try appendTemplate(buf, allocator, " <code>{ref}</code>", .{ .ref = util.shortObjectRef(&ref_buf, object_id) });
    }
    try buf.appendSlice(allocator, " · ");
    try appendRelativeTime(buf, allocator, occurred_at);
    if (subject.len != 0) {
        try appendTemplate(buf, allocator, "<span>{subject}</span>", .{ .subject = subject });
    }
    try buf.appendSlice(allocator, "</p></article>");
}

fn projectEventLabel(event_type: []const u8, object_kind: []const u8) []const u8 {
    if (std.mem.eql(u8, object_kind, "issue")) {
        if (std.mem.eql(u8, event_type, "issue.created")) return "created issue";
        if (std.mem.eql(u8, event_type, "issue.updated")) return "updated issue";
        if (std.mem.eql(u8, event_type, "issue.project_added")) return "added issue to project";
        if (std.mem.eql(u8, event_type, "issue.project_removed")) return "removed issue from project";
        return "changed issue";
    }
    if (std.mem.eql(u8, event_type, "project.created")) return "created";
    if (std.mem.eql(u8, event_type, "project.updated")) return "updated";
    if (std.mem.eql(u8, event_type, "project.column_added")) return "added a column to";
    if (std.mem.eql(u8, event_type, "project.column_removed")) return "removed a column from";
    if (std.mem.eql(u8, event_type, "project.field_created")) return "created a field on";
    if (std.mem.eql(u8, event_type, "project.field_updated")) return "updated a field on";
    if (std.mem.eql(u8, event_type, "project.view_created")) return "created a view on";
    if (std.mem.eql(u8, event_type, "project.view_updated")) return "updated a view on";
    return "changed";
}

fn projectStateLabel(state: []const u8) []const u8 {
    if (std.mem.eql(u8, state, "closed")) return "Completed";
    if (std.mem.eql(u8, state, "open")) return "In Progress";
    return if (state.len == 0) "No status" else state;
}

fn projectStateTone(state: []const u8) []const u8 {
    if (std.mem.eql(u8, state, "closed")) return "done";
    if (std.mem.eql(u8, state, "open")) return "progress";
    return "neutral";
}

fn priorityLabel(priority: []const u8) []const u8 {
    return if (priority.len == 0) "No priority" else priority;
}

fn repositoryOwnerLabel(repo: Repo) []const u8 {
    if (std.fs.path.dirname(repo.root)) |parent| return std.fs.path.basename(parent);
    return std.fs.path.basename(repo.root);
}

fn projectDatesLabelOwned(allocator: Allocator, metrics: *const ProjectMetrics) ![]u8 {
    const start_label = if (metrics.start_at.len != 0) try dateLabelOwned(allocator, metrics.start_at) else try allocator.dupe(u8, "No start date");
    defer allocator.free(start_label);
    const end_label = if (metrics.end_at.len != 0) try dateLabelOwned(allocator, metrics.end_at) else try allocator.dupe(u8, "No end date");
    defer allocator.free(end_label);
    return std.fmt.allocPrint(allocator, "{s} + {s}", .{ start_label, end_label });
}

fn dateLabelOwned(allocator: Allocator, value: []const u8) ![]u8 {
    if (value.len >= 10 and value[4] == '-' and value[7] == '-') {
        const month = std.fmt.parseInt(u8, value[5..7], 10) catch 0;
        const day = std.fmt.parseInt(u8, value[8..10], 10) catch 0;
        if (month >= 1 and month <= 12 and day >= 1 and day <= 31) {
            return std.fmt.allocPrint(allocator, "{s} {d}", .{ monthNames()[month - 1], day });
        }
    }
    return allocator.dupe(u8, value);
}

fn monthNames() []const []const u8 {
    return &.{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
}

fn countLabelOwned(allocator: Allocator, value: usize, singular: []const u8, plural: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{d} {s}", .{ value, if (value == 1) singular else plural });
}

fn appendProjectViewHref(buf: *std.ArrayList(u8), allocator: Allocator, project: []const u8, view_ref: []const u8) !void {
    try buf.appendSlice(allocator, "/projects?project=");
    try shared.appendUrlEncoded(buf, allocator, project);
    try buf.appendSlice(allocator, "&amp;view=");
    try shared.appendUrlEncoded(buf, allocator, view_ref);
}

fn appendProjectOverviewHref(buf: *std.ArrayList(u8), allocator: Allocator, project: []const u8) !void {
    try buf.appendSlice(allocator, "/projects?project=");
    try shared.appendUrlEncoded(buf, allocator, project);
}

test "project overview header renders plain project name" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var summary = ProjectSummary{
        .id = try std.testing.allocator.dupe(u8, "p1"),
        .name = try std.testing.allocator.dupe(u8, "Release & Plan"),
        .description = try std.testing.allocator.dupe(u8, ""),
        .state = try std.testing.allocator.dupe(u8, "open"),
        .created_at = try std.testing.allocator.dupe(u8, ""),
        .author_principal = try std.testing.allocator.dupe(u8, ""),
    };
    defer summary.deinit(std.testing.allocator);
    var metrics = ProjectMetrics{
        .top_status = try std.testing.allocator.dupe(u8, ""),
        .top_priority = try std.testing.allocator.dupe(u8, ""),
        .start_at = try std.testing.allocator.dupe(u8, ""),
        .end_at = try std.testing.allocator.dupe(u8, ""),
        .lead = try std.testing.allocator.dupe(u8, ""),
    };
    defer metrics.deinit(std.testing.allocator);

    try appendProjectOverviewHeader(&buf, std.testing.allocator, &summary, &metrics);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<h1>Release &amp; Plan</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<h1>@Release") == null);
}

test "project dates label uses start plus end" {
    var metrics = ProjectMetrics{
        .top_status = try std.testing.allocator.dupe(u8, ""),
        .top_priority = try std.testing.allocator.dupe(u8, ""),
        .start_at = try std.testing.allocator.dupe(u8, "2026-05-17"),
        .end_at = try std.testing.allocator.dupe(u8, "2026-05-28"),
        .lead = try std.testing.allocator.dupe(u8, ""),
    };
    defer metrics.deinit(std.testing.allocator);

    const label = try projectDatesLabelOwned(std.testing.allocator, &metrics);
    defer std.testing.allocator.free(label);

    try std.testing.expectEqualStrings("May 17 + May 28", label);
}
