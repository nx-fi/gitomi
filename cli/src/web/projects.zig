const std = @import("std");
const cmd_common = @import("../cmd_common.zig");
const event_mod = @import("../event.zig");
const index = @import("../index.zig");
const issue_mod = @import("../issue.zig");
const project_mod = @import("../project.zig");
const repo_mod = @import("../repo.zig");
const shared = @import("shared.zig");
const util = @import("../util.zig");
const issues_page = @import("issues.zig");
const milestones_page = @import("milestones.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const SqliteDb = index.SqliteDb;
const Button = shared.Button;
const appendEmptyState = shared.appendEmptyState;
const appendRelativeTime = shared.appendRelativeTime;
const appendSectionHead = shared.appendSectionHead;
const appendShellEnd = shared.appendShellEnd;
const appendShellStart = shared.appendShellStart;
const appendStatePill = shared.appendStatePill;
const appendTemplate = shared.appendTemplate;
const createIssueOpenedWithMetadataEvent = issue_mod.createIssueOpenedWithMetadataEvent;
const createIssueProjectFieldClearedEvent = issue_mod.createIssueProjectFieldClearedEvent;
const createIssueProjectFieldSetEvent = issue_mod.createIssueProjectFieldSetEvent;
const createIssueProjectEvent = issue_mod.createIssueProjectEvent;
const createIssueStringEvent = issue_mod.createIssueStringEvent;
const createProjectCreatedEvent = project_mod.createProjectCreatedEvent;
const createProjectFieldCreatedEvent = project_mod.createProjectFieldCreatedEvent;
const createProjectFieldOptionAddedEvent = project_mod.createProjectFieldOptionAddedEvent;
const createProjectViewCreatedEvent = project_mod.createProjectViewCreatedEvent;
const formValueOwned = issues_page.formValueOwned;
const issueHref = shared.issueHref;
const literalHref = shared.literalHref;
const sendRedirect = shared.sendRedirect;
const sendPlainResponse = shared.sendPlainResponse;
const sendResponse = shared.sendResponse;
const jsonStringArgument = cmd_common.jsonStringArgument;
const splitCommaFields = util.splitCommaFields;
const sqlite = index.sqlite;

const ProjectTemplate = struct {
    id: []const u8,
    title: []const u8,
    source: []const u8,
    description: []const u8,
    columns: []const u8,
    group: TemplateGroup,
    preview: []const u8,
};

const TemplateGroup = enum {
    featured,
    scratch,
};

const ProjectView = enum {
    table,
    board,
    roadmap,
};

const ProjectGroupField = enum {
    status,
    priority,
};

const ActiveProjectView = struct {
    layout: ProjectView,
    title: []u8,
    ref: []u8,
    config_json: []u8,
    saved: bool,

    fn deinit(self: *ActiveProjectView, allocator: Allocator) void {
        allocator.free(self.title);
        allocator.free(self.ref);
        allocator.free(self.config_json);
    }
};

const ProjectIssueFilter = struct {
    require_assignee: bool = false,
    assignee: []const u8 = "",
    bug_label: bool = false,
    current_iteration: bool = false,
};

const ProjectViewDefaults = struct {
    status: []const u8 = default_project_status,
    status_explicit: bool = false,
    priority: []const u8 = default_project_priority,
    priority_explicit: bool = false,
};

const max_project_table_fields = 6;

const ProjectTableField = struct {
    key: []u8,
    name: []u8,
    field_type: []u8,

    fn deinit(self: *ProjectTableField, allocator: Allocator) void {
        allocator.free(self.key);
        allocator.free(self.name);
        allocator.free(self.field_type);
    }
};

const ProjectTableFields = struct {
    items: [max_project_table_fields]ProjectTableField = undefined,
    len: usize = 0,

    fn deinit(self: *ProjectTableFields, allocator: Allocator) void {
        for (self.items[0..self.len]) |*field| field.deinit(allocator);
    }
};

const ProjectRenderContext = struct {
    filter: ProjectIssueFilter,
    defaults: ProjectViewDefaults,
    table_fields: ?*const ProjectTableFields = null,
    view_ref: []const u8,

    fn tableFieldCount(self: ProjectRenderContext) usize {
        return if (self.table_fields) |fields| fields.len else 0;
    }

    fn tableColspan(self: ProjectRenderContext) usize {
        return 9 + self.tableFieldCount();
    }
};

const project_issue_filter_sql =
    \\
    \\  AND (? = 0 OR EXISTS (
    \\    SELECT 1
    \\    FROM issue_assignees ia
    \\    WHERE ia.issue_id = i.id AND ia.assignee = ?
    \\  ))
    \\  AND (? = 0 OR EXISTS (
    \\    SELECT 1
    \\    FROM issue_labels il
    \\    WHERE il.issue_id = i.id AND lower(il.label) = 'bug'
    \\  ))
    \\  AND (? = 0 OR EXISTS (
    \\    SELECT 1
    \\    FROM projects filter_project
    \\    JOIN project_fields filter_field
    \\      ON filter_field.project_id = filter_project.id
    \\     AND filter_field.key = 'iteration'
    \\     AND filter_field.state != 'removed'
    \\    JOIN project_field_values filter_value
    \\      ON filter_value.project_id = filter_project.id
    \\     AND filter_value.issue_id = i.id
    \\     AND filter_value.field_id = filter_field.id
    \\    WHERE filter_project.name = ?
    \\      AND COALESCE(json_extract(filter_value.value_json, '$'), '') = 'current'
    \\  ))
;

const default_project_template_id = "kanban";
const default_project_priority = "P3";
const default_project_status = "Draft";
const project_status_values = [_][]const u8{ "Draft", "Todo", "WIP", "Review", "Done", "Failed" };
const project_priority_values = [_][]const u8{ "P0", "P1", "P2", "P3" };
const default_project_status_columns = "Draft, Todo, WIP, Review, Done, Failed";

const project_templates = [_]ProjectTemplate{
    .{
        .id = "team-planning",
        .title = "Team planning",
        .source = "Gitomi",
        .description = "Manage team work items, upcoming cycles, and capacity.",
        .columns = default_project_status_columns,
        .group = .featured,
        .preview = "table",
    },
    .{
        .id = "kanban",
        .title = "Kanban",
        .source = "Gitomi",
        .description = "Visualize project status and limit work in progress.",
        .columns = default_project_status_columns,
        .group = .featured,
        .preview = "board",
    },
    .{
        .id = "feature-release",
        .title = "Feature release",
        .source = "Gitomi",
        .description = "Prioritize, review, and ship a focused release.",
        .columns = default_project_status_columns,
        .group = .featured,
        .preview = "table",
    },
    .{
        .id = "bug-tracker",
        .title = "Bug tracker",
        .source = "Gitomi",
        .description = "Track, triage, and resolve reported bugs.",
        .columns = default_project_status_columns,
        .group = .featured,
        .preview = "board",
    },
    .{
        .id = "table",
        .title = "Table",
        .source = "Start from scratch",
        .description = "Start from a compact list of work items.",
        .columns = default_project_status_columns,
        .group = .scratch,
        .preview = "table",
    },
    .{
        .id = "board",
        .title = "Board",
        .source = "Start from scratch",
        .description = "Start with a lightweight Kanban workflow.",
        .columns = default_project_status_columns,
        .group = .scratch,
        .preview = "board",
    },
    .{
        .id = "roadmap",
        .title = "Roadmap",
        .source = "Start from scratch",
        .description = "Organize work by planning horizon.",
        .columns = default_project_status_columns,
        .group = .scratch,
        .preview = "roadmap",
    },
};

pub fn renderProjectsPage(allocator: Allocator, repo: Repo, target: []const u8) ![]u8 {
    if (try shared.renderIndexingPageIfStale(allocator, repo, "Projects", "projects", target)) |body| return body;
    try index.ensureIndex(allocator, repo);

    const project_query = try trimmedQueryValueOwned(allocator, target, "project");
    defer if (project_query) |value| allocator.free(value);
    const view_query = try trimmedQueryValueOwned(allocator, target, "view");
    defer if (view_query) |value| allocator.free(value);

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    if (project_query) |project| {
        return renderProjectWorkspace(allocator, repo, &db, project, view_query orelse "");
    }

    return renderProjectIndex(allocator, repo, &db);
}

fn renderProjectIndex(allocator: Allocator, repo: Repo, db: *SqliteDb) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "Projects", "projects");
    try buf.appendSlice(allocator,
        \\<div class="project-page-layout" data-project-index-tabs>
        \\  <aside class="project-page-sidebar">
        \\    <nav class="project-page-tabs" aria-label="Projects sections" role="tablist">
        \\      <a id="project-tab-projects" class="project-page-tab" href="#projects" role="tab" aria-controls="projects" aria-selected="true" data-project-index-tab="projects"><span class="button-icon icon-projects" aria-hidden="true"></span><span>Projects</span></a>
        \\      <a id="project-tab-milestones" class="project-page-tab" href="#milestones" role="tab" aria-controls="milestones" aria-selected="false" data-project-index-tab="milestones"><span class="button-icon icon-milestones" aria-hidden="true"></span><span>Milestones</span></a>
        \\    </nav>
        \\  </aside>
        \\  <div class="project-page-content">
        \\    <section id="projects" class="panel project-index-panel project-page-panel" role="tabpanel" aria-labelledby="project-tab-projects" data-project-index-panel>
    );
    try appendSectionHead(&buf, allocator, "Projects", "Issue Workspaces", Button{
        .label = "New project",
        .href = literalHref("/new-project"),
        .kind = "primary",
    });
    try buf.appendSlice(allocator,
        \\<div class="project-index-grid">
    );

    var projects = try db.prepare(
        \\WITH project_names AS (
        \\  SELECT name FROM projects
        \\  UNION
        \\  SELECT project AS name FROM issue_projects
        \\)
        \\SELECT
        \\  pn.name,
        \\  COALESCE((SELECT p.description FROM projects p WHERE p.name = pn.name ORDER BY p.created_at DESC, p.id DESC LIMIT 1), ''),
        \\  COALESCE((SELECT p.state FROM projects p WHERE p.name = pn.name ORDER BY p.created_at DESC, p.id DESC LIMIT 1), 'open'),
        \\  (SELECT COUNT(DISTINCT ip.issue_id) FROM issue_projects ip WHERE ip.project = pn.name),
        \\  (SELECT COUNT(DISTINCT column_name) FROM (
        \\     SELECT pc.column_name AS column_name
        \\     FROM project_columns pc
        \\     JOIN projects p ON p.id = pc.project_id
        \\     WHERE p.name = pn.name
        \\     UNION
        \\     SELECT ip.column_name AS column_name
        \\     FROM issue_projects ip
        \\     WHERE ip.project = pn.name
        \\  )),
        \\  COALESCE((SELECT MAX(activity_at) FROM (
        \\     SELECT p.created_at AS activity_at FROM projects p WHERE p.name = pn.name
        \\     UNION ALL
        \\     SELECT i.state_occurred_at AS activity_at
        \\     FROM issue_projects ip
        \\     JOIN issues i ON i.id = ip.issue_id
        \\     WHERE ip.project = pn.name
        \\  )), '')
        \\FROM project_names pn
        \\ORDER BY
        \\  CASE WHEN COALESCE((SELECT MAX(activity_at) FROM (
        \\     SELECT p.created_at AS activity_at FROM projects p WHERE p.name = pn.name
        \\     UNION ALL
        \\     SELECT i.state_occurred_at AS activity_at
        \\     FROM issue_projects ip
        \\     JOIN issues i ON i.id = ip.issue_id
        \\     WHERE ip.project = pn.name
        \\  )), '') = '' THEN 1 ELSE 0 END,
        \\  COALESCE((SELECT MAX(activity_at) FROM (
        \\     SELECT p.created_at AS activity_at FROM projects p WHERE p.name = pn.name
        \\     UNION ALL
        \\     SELECT i.state_occurred_at AS activity_at
        \\     FROM issue_projects ip
        \\     JOIN issues i ON i.id = ip.issue_id
        \\     WHERE ip.project = pn.name
        \\  )), '') DESC,
        \\  lower(pn.name),
        \\  pn.name
    );
    defer projects.deinit();

    var shown: usize = 0;
    while (try projects.step()) {
        const project = try projects.columnTextDup(allocator, 0);
        defer allocator.free(project);
        const description = try projects.columnTextDup(allocator, 1);
        defer allocator.free(description);
        const state = try projects.columnTextDup(allocator, 2);
        defer allocator.free(state);
        const issue_count = @as(usize, @intCast(projects.columnInt64(3)));
        const column_count = @as(usize, @intCast(projects.columnInt64(4)));
        const activity_at = try projects.columnTextDup(allocator, 5);
        defer allocator.free(activity_at);
        try appendProjectIndexCard(&buf, allocator, project, description, state, issue_count, column_count, activity_at);
        shown += 1;
    }
    try buf.appendSlice(allocator, "</div>");
    if (shown == 0) {
        try appendEmptyState(&buf, allocator, "No projects yet.", "Create the first project from this browser UI or with gt project create.");
    }
    try buf.appendSlice(allocator, "</section>");

    try milestones_page.appendMilestonesPanel(&buf, allocator, db);
    try buf.appendSlice(allocator,
        \\  </div>
        \\</div>
    );

    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn renderProjectWorkspace(
    allocator: Allocator,
    repo: Repo,
    db: *SqliteDb,
    project: []const u8,
    view_ref: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, project, "projects");
    try shared.appendDetailBackButton(&buf, allocator, shared.literalHref("/projects"), "Back to projects");
    if (!(try projectExists(db, project))) {
        try appendProjectNotFound(&buf, allocator, project);
        try appendShellEnd(&buf, allocator);
        return buf.toOwnedSlice(allocator);
    }

    var active_view = try resolveActiveProjectView(allocator, db, project, view_ref);
    defer active_view.deinit(allocator);
    const current_principal = (try shared.currentPrincipalOwned(allocator, repo)) orelse try allocator.dupe(u8, "");
    defer allocator.free(current_principal);

    switch (active_view.layout) {
        .table => try appendProjectTable(&buf, allocator, db, project, &active_view, current_principal),
        .board => try appendProjectBoard(&buf, allocator, db, project, &active_view, current_principal),
        .roadmap => try appendProjectRoadmap(&buf, allocator, db, project, &active_view, current_principal),
    }

    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn appendProjectIndexCard(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    project: []const u8,
    description: []const u8,
    state: []const u8,
    issue_count: usize,
    column_count: usize,
    activity_at: []const u8,
) !void {
    try appendTemplate(buf, allocator,
        \\<article class="project-index-card">
        \\  <div class="project-index-card-head">
        \\    <div>
        \\      <p class="eyebrow">Project</p>
        \\      <h2><a href="
    , .{});
    try appendProjectHref(buf, allocator, project, .board);
    try appendTemplate(buf, allocator,
        \\">{project}</a></h2>
        \\    </div>
    , .{ .project = project });
    try appendStatePill(buf, allocator, state);
    try buf.appendSlice(allocator, "</div>");
    if (description.len != 0) {
        try appendTemplate(buf, allocator,
            \\<p class="project-index-description">{description}</p>
        , .{ .description = description });
    }
    try appendTemplate(buf, allocator,
        \\<div class="project-index-stats">
        \\  <span><strong>{issue_count}</strong> item{s}</span>
        \\  <span><strong>{column_count}</strong> status {column_word}</span>
    , .{
        .issue_count = issue_count,
        .s = if (issue_count == 1) "" else "s",
        .column_count = column_count,
        .column_word = if (column_count == 1) "value" else "values",
    });
    if (activity_at.len != 0) {
        try buf.appendSlice(allocator, "<span>Updated ");
        try appendRelativeTime(buf, allocator, activity_at);
        try buf.appendSlice(allocator, "</span>");
    }
    try buf.appendSlice(allocator, "</div><div class=\"project-index-actions\">");
    try appendProjectViewLink(buf, allocator, project, .table, "Table");
    try appendProjectViewLink(buf, allocator, project, .board, "Board");
    try appendProjectViewLink(buf, allocator, project, .roadmap, "Roadmap");
    try buf.appendSlice(allocator, "</div></article>");
}

fn appendProjectBoard(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    project: []const u8,
    active_view: *const ActiveProjectView,
    current_principal: []const u8,
) !void {
    const context = projectRenderContextFromView(allocator, active_view, current_principal);
    const issue_count = try projectIssueCount(db, project, context.filter);
    try appendProjectWorkspaceChromeStart(buf, allocator, db, project, issue_count, active_view);
    try appendTemplate(buf, allocator,
        \\  <div class="kanban-board" data-project="{project}">
    , .{ .project = project });
    try appendProjectColumns(buf, allocator, db, project, &context, appendProjectColumn);
    try buf.appendSlice(allocator,
        \\  </div>
        \\</section>
    );
}

fn appendProjectWorkspaceChromeStart(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    project: []const u8,
    issue_count: usize,
    active_view: *const ActiveProjectView,
) !void {
    try appendTemplate(buf, allocator,
        \\<section class="panel kanban-panel project-board-panel project-detail-panel project-detail-{view}">
        \\  <div class="project-board-top">
        \\    <div class="project-title-line">
        \\      <span class="project-lock-icon" aria-hidden="true"></span>
        \\      <div>
        \\        <p class="eyebrow">Project {title_label}</p>
        \\        <h1>{project}</h1>
        \\      </div>
        \\    </div>
    , .{
        .view = projectViewValue(active_view.layout),
        .title_label = active_view.title,
        .project = project,
    });
    try buf.appendSlice(allocator, "<a class=\"button secondary project-issues-link\" href=\"/issues?project=");
    try shared.appendUrlEncoded(buf, allocator, project);
    try buf.appendSlice(allocator, "\">Open issues</a></div>");
    try appendProjectViewTabs(buf, allocator, db, project, active_view, issue_count);
    try appendProjectItemActions(buf, allocator, db, project, active_view);
    try appendProjectIssueSearchIndex(buf, allocator, db);
    try appendTemplate(buf, allocator,
        \\  <form class="project-filter-bar" method="get" action="/issues">
        \\    <span class="project-filter-icon" aria-hidden="true"></span>
        \\    <input type="hidden" name="project" value="{project}">
        \\    <input type="search" name="q" placeholder="Filter by keyword or by field" aria-label="Filter project issues">
        \\  </form>
    , .{
        .project = project,
        .issue_count = issue_count,
    });

    try appendProjectSummary(buf, allocator, db, project, issue_count);
}

fn appendProjectIssueSearchIndex(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb) !void {
    var stmt = try db.prepare(
        \\SELECT i.id, i.title, i.state,
        \\       COALESCE(m.priority, ''),
        \\       COALESCE(m.status, ''),
        \\       COALESCE(a.number, 0)
        \\FROM issues i
        \\LEFT JOIN issue_metadata m ON m.issue_id = i.id
        \\LEFT JOIN legacy_aliases a
        \\  ON a.provider = 'github' AND a.object_kind = 'issue' AND a.object_id = i.id
        \\ORDER BY
        \\  CASE i.state WHEN 'open' THEN 0 ELSE 1 END,
        \\  i.opened_at DESC,
        \\  i.id DESC
        \\LIMIT 500
    );
    defer stmt.deinit();

    try buf.appendSlice(allocator, "<div data-project-issue-search-index hidden>");
    while (try stmt.step()) {
        const id = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(id);
        const title = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(title);
        const state = try stmt.columnTextDup(allocator, 2);
        defer allocator.free(state);
        const priority = try stmt.columnTextDup(allocator, 3);
        defer allocator.free(priority);
        const status = try stmt.columnTextDup(allocator, 4);
        defer allocator.free(status);
        const legacy_number = stmt.columnInt64(5);

        var ref_buf: [util.short_object_ref_len]u8 = undefined;
        const short_ref = util.shortObjectRef(&ref_buf, id);
        const issue_ref = if (legacy_number > 0)
            try std.fmt.allocPrint(allocator, "#{d}", .{legacy_number})
        else
            try std.fmt.allocPrint(allocator, "#{s}", .{short_ref});
        defer allocator.free(issue_ref);
        const issue_display = if (legacy_number > 0)
            try std.fmt.allocPrint(allocator, "GitHub #{d}", .{legacy_number})
        else
            try std.fmt.allocPrint(allocator, "#{s}", .{short_ref});
        defer allocator.free(issue_display);

        try appendTemplate(buf, allocator,
            \\<span data-project-issue-search-item data-issue-ref="{issue_ref}" data-issue-display="{issue_display}" data-issue-title="{title}" data-issue-state="{state}" data-issue-priority="{priority}" data-issue-status="{status}"></span>
        , .{
            .issue_ref = issue_ref,
            .issue_display = issue_display,
            .title = title,
            .state = state,
            .priority = priority,
            .status = status,
        });
    }
    try buf.appendSlice(allocator, "</div>");
}

fn appendProjectColumns(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    project: []const u8,
    context: *const ProjectRenderContext,
    comptime appendColumnFn: fn (*std.ArrayList(u8), Allocator, *SqliteDb, []const u8, []const u8, *const ProjectRenderContext) anyerror!void,
) !void {
    for (project_status_values) |status| {
        try appendColumnFn(buf, allocator, db, project, status, context);
    }

    var columns = try db.prepare(
        \\SELECT column_name FROM (
        \\  SELECT pc.column_name AS column_name
        \\  FROM project_columns pc
        \\  JOIN projects p ON p.id = pc.project_id
        \\  WHERE p.name = ?
        \\  UNION
        \\  SELECT column_name
        \\  FROM issue_projects
        \\  WHERE project = ?
        \\)
        \\ORDER BY
        \\  CASE lower(column_name)
        \\    WHEN 'triage' THEN 5
        \\    WHEN 'backlog' THEN 10
        \\    WHEN 'todo' THEN 20
        \\    WHEN 'to do' THEN 20
        \\    WHEN 'ready' THEN 30
        \\    WHEN 'in progress' THEN 40
        \\    WHEN 'doing' THEN 40
        \\    WHEN 'in review' THEN 50
        \\    WHEN 'review' THEN 50
        \\    WHEN 'done' THEN 60
        \\    WHEN 'completed' THEN 60
        \\    WHEN 'closed' THEN 60
        \\    ELSE 70
        \\  END,
        \\  lower(column_name),
        \\  column_name
    );
    defer columns.deinit();
    try columns.bindText(1, project);
    try columns.bindText(2, project);
    while (try columns.step()) {
        const column = try columns.columnTextDup(allocator, 0);
        defer allocator.free(column);
        if (isProjectStatusValue(column)) continue;
        try appendColumnFn(buf, allocator, db, project, column, context);
    }
}

fn appendProjectPriorityGroups(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    project: []const u8,
    context: *const ProjectRenderContext,
    comptime appendGroupFn: fn (*std.ArrayList(u8), Allocator, *SqliteDb, []const u8, []const u8, *const ProjectRenderContext) anyerror!void,
) !void {
    for (project_priority_values) |priority| {
        try appendGroupFn(buf, allocator, db, project, priority, context);
    }
    try appendGroupFn(buf, allocator, db, project, "", context);
}

fn appendProjectColumnOptions(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    project: []const u8,
    selected: ?[]const u8,
) !void {
    _ = db;
    _ = project;
    for (project_status_values) |status| {
        try appendTemplate(buf, allocator,
            \\<option value="{value}"{selected}>{label}</option>
        , .{
            .value = status,
            .selected = shared.trustedHtml(if (selected) |current| if (std.mem.eql(u8, current, status)) " selected" else "" else if (std.mem.eql(u8, status, default_project_status)) " selected" else ""),
            .label = status,
        });
    }
}

fn appendProjectPriorityOptions(buf: *std.ArrayList(u8), allocator: Allocator, selected: []const u8) !void {
    if (selected.len == 0) {
        try buf.appendSlice(allocator, "<option value=\"\">Keep current</option>");
    }
    for (project_priority_values) |priority| {
        try appendTemplate(buf, allocator,
            \\<option value="{value}"{selected}>{label}</option>
        , .{
            .value = priority,
            .selected = shared.trustedHtml(if (std.mem.eql(u8, selected, priority)) " selected" else ""),
            .label = priority,
        });
    }
}

fn appendProjectTableFieldHeaders(buf: *std.ArrayList(u8), allocator: Allocator, fields: *const ProjectTableFields) !void {
    for (fields.items[0..fields.len]) |field| {
        try appendTemplate(buf, allocator, "<th>{name}</th>", .{ .name = field.name });
    }
}

fn appendProjectTableFieldCells(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    project: []const u8,
    issue_id: []const u8,
    context: *const ProjectRenderContext,
) !void {
    const fields = context.table_fields orelse return;
    for (fields.items[0..fields.len]) |field| {
        const value = try projectFieldStringValue(allocator, db, project, issue_id, field.key);
        defer allocator.free(value);
        try appendProjectTableFieldCell(buf, allocator, project, issue_id, context.view_ref, field, value);
    }
}

fn appendProjectTableFieldCell(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    project: []const u8,
    issue_id: []const u8,
    view_ref: []const u8,
    field: ProjectTableField,
    value: []const u8,
) !void {
    try appendTemplate(buf, allocator,
        \\<td>
        \\  <form class="project-table-field-form" method="post" action="/projects/items">
        \\    <input type="hidden" name="action" value="set-project-field">
        \\    <input type="hidden" name="project" value="{project}">
        \\    <input type="hidden" name="issue" value="{issue}">
        \\    <input type="hidden" name="field" value="{field_key}">
        \\    <input type="hidden" name="view" value="{view}">
    , .{
        .project = project,
        .issue = issue_id,
        .field_key = field.key,
        .view = view_ref,
    });
    if (std.mem.eql(u8, field.field_type, "boolean")) {
        try appendProjectBooleanFieldSelect(buf, allocator, field.name, value);
    } else {
        try appendTemplate(buf, allocator,
            \\    <input type="{input_type}" name="value" value="{value}" aria-label="{name}">
        , .{
            .input_type = projectFieldInputType(field.field_type),
            .value = value,
            .name = field.name,
        });
    }
    try buf.appendSlice(allocator,
        \\    <button type="submit" aria-label="Save field value">Save</button>
        \\  </form>
        \\</td>
    );
}

fn appendProjectBooleanFieldSelect(buf: *std.ArrayList(u8), allocator: Allocator, name: []const u8, value: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\    <select name="value" aria-label="{name}">
        \\      <option value=""{empty_selected}>Unset</option>
        \\      <option value="true"{true_selected}>True</option>
        \\      <option value="false"{false_selected}>False</option>
        \\    </select>
    , .{
        .name = name,
        .empty_selected = shared.trustedHtml(if (value.len == 0) " selected" else ""),
        .true_selected = shared.trustedHtml(if (std.mem.eql(u8, value, "true")) " selected" else ""),
        .false_selected = shared.trustedHtml(if (std.mem.eql(u8, value, "false")) " selected" else ""),
    });
}

fn projectFieldInputType(field_type: []const u8) []const u8 {
    if (std.mem.eql(u8, field_type, "number")) return "number";
    if (std.mem.eql(u8, field_type, "date")) return "date";
    return "text";
}

fn appendProjectTable(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    project: []const u8,
    active_view: *const ActiveProjectView,
    current_principal: []const u8,
) !void {
    const context = projectRenderContextFromView(allocator, active_view, current_principal);
    const issue_count = try projectIssueCount(db, project, context.filter);
    const group_field = projectGroupFieldFromConfig(allocator, active_view.config_json);
    var table_fields = try projectTableFieldsFromConfig(allocator, db, project, active_view.config_json);
    defer table_fields.deinit(allocator);
    var table_context = context;
    table_context.table_fields = &table_fields;
    try appendProjectWorkspaceChromeStart(buf, allocator, db, project, issue_count, active_view);
    try buf.appendSlice(allocator,
        \\  <div class="project-table-view">
        \\    <table class="project-data-table">
        \\      <thead>
        \\        <tr><th>Title</th><th>Priority</th><th>Status</th>
    );
    try appendProjectTableFieldHeaders(buf, allocator, &table_fields);
    try buf.appendSlice(allocator,
        \\<th>Issue state</th><th>Assignees</th><th>Labels</th><th>Milestone</th><th>Comments</th><th>Opened</th></tr>
        \\      </thead>
        \\      <tbody>
    );
    switch (group_field) {
        .status => try appendProjectColumns(buf, allocator, db, project, &table_context, appendProjectTableGroup),
        .priority => try appendProjectPriorityGroups(buf, allocator, db, project, &table_context, appendProjectPriorityTableGroup),
    }
    try buf.appendSlice(allocator,
        \\      </tbody>
        \\    </table>
        \\  </div>
        \\</section>
    );
}

fn appendProjectRoadmap(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    project: []const u8,
    active_view: *const ActiveProjectView,
    current_principal: []const u8,
) !void {
    const context = projectRenderContextFromView(allocator, active_view, current_principal);
    const issue_count = try projectIssueCount(db, project, context.filter);
    const group_field = projectGroupFieldFromConfig(allocator, active_view.config_json);
    try appendProjectWorkspaceChromeStart(buf, allocator, db, project, issue_count, active_view);
    try buf.appendSlice(allocator,
        \\  <div class="project-roadmap-view">
        \\    <div class="project-roadmap-scale" aria-hidden="true"><span>Unscheduled</span><span>Now</span><span>Next</span><span>Later</span></div>
    );
    switch (group_field) {
        .status => try appendProjectColumns(buf, allocator, db, project, &context, appendProjectRoadmapLane),
        .priority => try appendProjectPriorityGroups(buf, allocator, db, project, &context, appendProjectPriorityRoadmapLane),
    }
    try buf.appendSlice(allocator,
        \\  </div>
        \\</section>
    );
}

fn appendProjectTableGroup(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    project: []const u8,
    column: []const u8,
    context: *const ProjectRenderContext,
) !void {
    const count = try projectColumnIssueCount(db, project, column, context.filter);
    const title = if (column.len == 0) "No status" else column;
    try appendTemplate(buf, allocator,
        \\<tr class="project-table-group-row"><th colspan="{colspan}"><span class="kanban-status-dot" aria-hidden="true"></span>{title}<span>{count}</span></th></tr>
    , .{
        .colspan = context.tableColspan(),
        .title = title,
        .count = count,
    });

    var rows = try db.prepare(
        \\WITH project_items AS (
        \\  SELECT pi.issue_id,
        \\         CASE
        \\           WHEN COALESCE(m.status, '') <> '' THEN m.status
        \\           ELSE pi.legacy_column
        \\         END AS effective_status
        \\  FROM (
        \\    SELECT issue_id, column_name AS legacy_column
        \\    FROM issue_projects
        \\    WHERE project = ?
        \\    UNION
        \\    SELECT pm.issue_id, ''
        \\    FROM project_memberships pm
        \\    JOIN projects p ON p.id = pm.project_id
        \\    WHERE p.name = ?
        \\  ) pi
        \\  LEFT JOIN issue_metadata m ON m.issue_id = pi.issue_id
        \\)
        \\SELECT DISTINCT i.id, i.title, i.state,
        \\       COALESCE(NULLIF(m.source_author, ''), i.author_principal),
        \\       i.opened_at,
        \\       COALESCE(m.milestone, ''),
        \\       COALESCE(m.priority, ''),
        \\       COALESCE(m.status, ''),
        \\       COALESCE(a.number, 0),
        \\       (SELECT COUNT(*) FROM comments c WHERE c.parent_kind = 'issue' AND c.parent_id = i.id)
        \\FROM project_items p
        \\JOIN issues i ON i.id = p.issue_id
        \\LEFT JOIN issue_metadata m ON m.issue_id = i.id
        \\LEFT JOIN legacy_aliases a
        \\  ON a.provider = 'github' AND a.object_kind = 'issue' AND a.object_id = i.id
        \\WHERE p.effective_status = ?
    ++ project_issue_filter_sql ++
        \\ORDER BY i.opened_at DESC, i.id DESC
    );
    defer rows.deinit();
    try rows.bindText(1, project);
    try rows.bindText(2, project);
    try rows.bindText(3, column);
    try bindProjectIssueFilter(&rows, 4, project, context.filter);

    var shown = false;
    while (try rows.step()) {
        const id = try rows.columnTextDup(allocator, 0);
        defer allocator.free(id);
        const title_text = try rows.columnTextDup(allocator, 1);
        defer allocator.free(title_text);
        const state = try rows.columnTextDup(allocator, 2);
        defer allocator.free(state);
        const author = try rows.columnTextDup(allocator, 3);
        defer allocator.free(author);
        const opened_at = try rows.columnTextDup(allocator, 4);
        defer allocator.free(opened_at);
        const milestone = try rows.columnTextDup(allocator, 5);
        defer allocator.free(milestone);
        const priority = try rows.columnTextDup(allocator, 6);
        defer allocator.free(priority);
        const status = try rows.columnTextDup(allocator, 7);
        defer allocator.free(status);
        const legacy_number = rows.columnInt64(8);
        const comment_count = @as(usize, @intCast(rows.columnInt64(9)));
        try appendProjectTableIssueRow(buf, allocator, db, project, context, id, title_text, state, author, opened_at, milestone, priority, effectiveStatusLabel(status, column), legacy_number, comment_count);
        shown = true;
    }
    if (!shown) {
        try appendTemplate(buf, allocator,
            \\<tr class="project-table-empty-row"><td colspan="{colspan}">No issues</td></tr>
        , .{ .colspan = context.tableColspan() });
    }
}

fn appendProjectPriorityTableGroup(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    project: []const u8,
    priority_group: []const u8,
    context: *const ProjectRenderContext,
) !void {
    const count = try projectPriorityIssueCount(db, project, priority_group, context.filter);
    const title = if (priority_group.len == 0) "No priority" else priority_group;
    try appendTemplate(buf, allocator,
        \\<tr class="project-table-group-row"><th colspan="{colspan}"><span class="project-priority-chip tone-{tone}">{title}</span><span>{count}</span></th></tr>
    , .{
        .colspan = context.tableColspan(),
        .tone = priorityTone(priority_group),
        .title = title,
        .count = count,
    });

    var rows = try db.prepare(
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
        \\SELECT DISTINCT i.id, i.title, i.state,
        \\       COALESCE(NULLIF(m.source_author, ''), i.author_principal),
        \\       i.opened_at,
        \\       COALESCE(m.milestone, ''),
        \\       COALESCE(m.priority, ''),
        \\       COALESCE(NULLIF(m.status, ''), p.legacy_column, ''),
        \\       COALESCE(a.number, 0),
        \\       (SELECT COUNT(*) FROM comments c WHERE c.parent_kind = 'issue' AND c.parent_id = i.id)
        \\FROM project_items p
        \\JOIN issues i ON i.id = p.issue_id
        \\LEFT JOIN issue_metadata m ON m.issue_id = i.id
        \\LEFT JOIN legacy_aliases a
        \\  ON a.provider = 'github' AND a.object_kind = 'issue' AND a.object_id = i.id
        \\WHERE COALESCE(m.priority, '') = ?
    ++ project_issue_filter_sql ++
        \\ORDER BY
        \\  CASE COALESCE(NULLIF(m.status, ''), p.legacy_column, '')
        \\    WHEN 'Draft' THEN 10
        \\    WHEN 'Todo' THEN 20
        \\    WHEN 'WIP' THEN 30
        \\    WHEN 'Review' THEN 40
        \\    WHEN 'Done' THEN 50
        \\    WHEN 'Failed' THEN 60
        \\    ELSE 70
        \\  END,
        \\  i.opened_at DESC, i.id DESC
    );
    defer rows.deinit();
    try rows.bindText(1, project);
    try rows.bindText(2, project);
    try rows.bindText(3, priority_group);
    try bindProjectIssueFilter(&rows, 4, project, context.filter);

    var shown = false;
    while (try rows.step()) {
        const id = try rows.columnTextDup(allocator, 0);
        defer allocator.free(id);
        const title_text = try rows.columnTextDup(allocator, 1);
        defer allocator.free(title_text);
        const state = try rows.columnTextDup(allocator, 2);
        defer allocator.free(state);
        const author = try rows.columnTextDup(allocator, 3);
        defer allocator.free(author);
        const opened_at = try rows.columnTextDup(allocator, 4);
        defer allocator.free(opened_at);
        const milestone = try rows.columnTextDup(allocator, 5);
        defer allocator.free(milestone);
        const priority = try rows.columnTextDup(allocator, 6);
        defer allocator.free(priority);
        const status = try rows.columnTextDup(allocator, 7);
        defer allocator.free(status);
        const legacy_number = rows.columnInt64(8);
        const comment_count = @as(usize, @intCast(rows.columnInt64(9)));
        try appendProjectTableIssueRow(buf, allocator, db, project, context, id, title_text, state, author, opened_at, milestone, priority, status, legacy_number, comment_count);
        shown = true;
    }
    if (!shown) {
        try appendTemplate(buf, allocator,
            \\<tr class="project-table-empty-row"><td colspan="{colspan}">No issues</td></tr>
        , .{ .colspan = context.tableColspan() });
    }
}

fn appendProjectTableIssueRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    project: []const u8,
    context: *const ProjectRenderContext,
    id: []const u8,
    title: []const u8,
    state: []const u8,
    author: []const u8,
    opened_at: []const u8,
    milestone: []const u8,
    priority: []const u8,
    status: []const u8,
    legacy_number: i64,
    comment_count: usize,
) !void {
    var issue_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const issue_ref = util.shortObjectRef(&issue_ref_buf, id);
    try appendTemplate(buf, allocator,
        \\<tr class="project-table-issue-row is-{state}">
        \\  <td><div class="project-table-title-cell"><span class="issue-state-icon {state}" title="{state}" aria-label="{state}"></span><a href="{href}">{title}</a><small>
    , .{
        .state = state,
        .href = issueHref(issue_ref),
        .title = title,
    });
    if (legacy_number > 0) {
        try appendTemplate(buf, allocator, "GitHub #{legacy_number}", .{ .legacy_number = legacy_number });
    } else {
        try appendTemplate(buf, allocator, "#{id}", .{ .id = issue_ref });
    }
    try appendTemplate(buf, allocator,
        \\</small></div></td>
        \\  <td><span class="project-priority-chip tone-{priority_tone}">{priority}</span></td>
        \\  <td><span class="project-status-chip tone-{tone}">{status}</span></td>
    , .{
        .priority_tone = priorityTone(priority),
        .priority = if (priority.len == 0) "None" else priority,
        .tone = columnTone(status),
        .status = if (status.len == 0) "No status" else status,
        .state = state,
    });
    try appendProjectTableFieldCells(buf, allocator, db, project, id, context);
    try appendTemplate(buf, allocator, "<td>{state}</td><td>", .{ .state = state });
    _ = author;
    try appendProjectIssueAssignees(buf, allocator, db, id);
    try buf.appendSlice(allocator, "</td><td>");
    try appendKanbanCardLabels(buf, allocator, db, id);
    try appendTemplate(buf, allocator,
        \\</td><td>{milestone}</td><td>{comment_count}</td><td>
    , .{
        .milestone = milestone,
        .comment_count = comment_count,
    });
    try appendRelativeTime(buf, allocator, opened_at);
    try buf.appendSlice(allocator, "</td></tr>");
}

fn appendProjectRoadmapLane(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    project: []const u8,
    column: []const u8,
    context: *const ProjectRenderContext,
) !void {
    const count = try projectColumnIssueCount(db, project, column, context.filter);
    const title = if (column.len == 0) "No status" else column;
    try appendTemplate(buf, allocator,
        \\<section class="project-roadmap-lane tone-{tone}">
        \\  <header><span class="kanban-status-dot" aria-hidden="true"></span><h2>{title}</h2><span>{count}</span></header>
        \\  <div class="project-roadmap-items">
    , .{
        .tone = columnTone(column),
        .title = title,
        .count = count,
    });

    var rows = try db.prepare(
        \\WITH project_items AS (
        \\  SELECT pi.issue_id,
        \\         CASE
        \\           WHEN COALESCE(m.status, '') <> '' THEN m.status
        \\           ELSE pi.legacy_column
        \\         END AS effective_status
        \\  FROM (
        \\    SELECT issue_id, column_name AS legacy_column
        \\    FROM issue_projects
        \\    WHERE project = ?
        \\    UNION
        \\    SELECT pm.issue_id, ''
        \\    FROM project_memberships pm
        \\    JOIN projects p ON p.id = pm.project_id
        \\    WHERE p.name = ?
        \\  ) pi
        \\  LEFT JOIN issue_metadata m ON m.issue_id = pi.issue_id
        \\)
        \\SELECT DISTINCT i.id, i.title, i.state,
        \\       COALESCE(NULLIF(m.source_author, ''), i.author_principal),
        \\       i.opened_at,
        \\       COALESCE(a.number, 0)
        \\FROM project_items p
        \\JOIN issues i ON i.id = p.issue_id
        \\LEFT JOIN issue_metadata m ON m.issue_id = i.id
        \\LEFT JOIN legacy_aliases a
        \\  ON a.provider = 'github' AND a.object_kind = 'issue' AND a.object_id = i.id
        \\WHERE p.effective_status = ?
    ++ project_issue_filter_sql ++
        \\ORDER BY i.opened_at DESC, i.id DESC
    );
    defer rows.deinit();
    try rows.bindText(1, project);
    try rows.bindText(2, project);
    try rows.bindText(3, column);
    try bindProjectIssueFilter(&rows, 4, project, context.filter);

    var shown = false;
    while (try rows.step()) {
        const id = try rows.columnTextDup(allocator, 0);
        defer allocator.free(id);
        const title_text = try rows.columnTextDup(allocator, 1);
        defer allocator.free(title_text);
        const state = try rows.columnTextDup(allocator, 2);
        defer allocator.free(state);
        const author = try rows.columnTextDup(allocator, 3);
        defer allocator.free(author);
        const opened_at = try rows.columnTextDup(allocator, 4);
        defer allocator.free(opened_at);
        const legacy_number = rows.columnInt64(5);
        try appendProjectRoadmapItem(buf, allocator, db, project, id, title_text, state, author, opened_at, legacy_number);
        shown = true;
    }
    if (!shown) try buf.appendSlice(allocator, "<div class=\"kanban-empty-drop\">No issues</div>");
    try buf.appendSlice(allocator, "</div></section>");
}

fn appendProjectPriorityRoadmapLane(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    project: []const u8,
    priority_group: []const u8,
    context: *const ProjectRenderContext,
) !void {
    const count = try projectPriorityIssueCount(db, project, priority_group, context.filter);
    const title = if (priority_group.len == 0) "No priority" else priority_group;
    try appendTemplate(buf, allocator,
        \\<section class="project-roadmap-lane tone-{tone}">
        \\  <header><span class="project-priority-chip tone-{tone}">{title}</span><span>{count}</span></header>
        \\  <div class="project-roadmap-items">
    , .{
        .tone = priorityTone(priority_group),
        .title = title,
        .count = count,
    });

    var rows = try db.prepare(
        \\WITH project_items AS (
        \\  SELECT issue_id
        \\  FROM issue_projects
        \\  WHERE project = ?
        \\  UNION
        \\  SELECT pm.issue_id
        \\  FROM project_memberships pm
        \\  JOIN projects p ON p.id = pm.project_id
        \\  WHERE p.name = ?
        \\)
        \\SELECT DISTINCT i.id, i.title, i.state,
        \\       COALESCE(NULLIF(m.source_author, ''), i.author_principal),
        \\       i.opened_at,
        \\       COALESCE(a.number, 0)
        \\FROM project_items p
        \\JOIN issues i ON i.id = p.issue_id
        \\LEFT JOIN issue_metadata m ON m.issue_id = i.id
        \\LEFT JOIN legacy_aliases a
        \\  ON a.provider = 'github' AND a.object_kind = 'issue' AND a.object_id = i.id
        \\WHERE COALESCE(m.priority, '') = ?
    ++ project_issue_filter_sql ++
        \\ORDER BY i.opened_at DESC, i.id DESC
    );
    defer rows.deinit();
    try rows.bindText(1, project);
    try rows.bindText(2, project);
    try rows.bindText(3, priority_group);
    try bindProjectIssueFilter(&rows, 4, project, context.filter);

    var shown = false;
    while (try rows.step()) {
        const id = try rows.columnTextDup(allocator, 0);
        defer allocator.free(id);
        const title_text = try rows.columnTextDup(allocator, 1);
        defer allocator.free(title_text);
        const state = try rows.columnTextDup(allocator, 2);
        defer allocator.free(state);
        const author = try rows.columnTextDup(allocator, 3);
        defer allocator.free(author);
        const opened_at = try rows.columnTextDup(allocator, 4);
        defer allocator.free(opened_at);
        const legacy_number = rows.columnInt64(5);
        try appendProjectRoadmapItem(buf, allocator, db, project, id, title_text, state, author, opened_at, legacy_number);
        shown = true;
    }
    if (!shown) try buf.appendSlice(allocator, "<div class=\"kanban-empty-drop\">No issues</div>");
    try buf.appendSlice(allocator, "</div></section>");
}

fn appendProjectRoadmapItem(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    project: []const u8,
    id: []const u8,
    title: []const u8,
    state: []const u8,
    author: []const u8,
    opened_at: []const u8,
    legacy_number: i64,
) !void {
    const has_start_field = try projectFieldKeyExists(db, project, "start_at");
    const has_target_field = try projectFieldKeyExists(db, project, "target_at");
    const start_at = if (has_start_field) try projectFieldStringValue(allocator, db, project, id, "start_at") else try allocator.dupe(u8, "");
    defer allocator.free(start_at);
    const target_at = if (has_target_field) try projectFieldStringValue(allocator, db, project, id, "target_at") else try allocator.dupe(u8, "");
    defer allocator.free(target_at);

    var issue_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const issue_ref = util.shortObjectRef(&issue_ref_buf, id);
    try appendTemplate(buf, allocator,
        \\<article class="project-roadmap-item is-{state}">
        \\  <span class="project-roadmap-bar" aria-hidden="true"></span>
        \\  <div><a href="{href}">{title}</a><small>
    , .{
        .state = state,
        .href = issueHref(issue_ref),
        .title = title,
    });
    if (legacy_number > 0) {
        try appendTemplate(buf, allocator, "GitHub #{legacy_number}", .{ .legacy_number = legacy_number });
    } else {
        try appendTemplate(buf, allocator, "#{id}", .{ .id = issue_ref });
    }
    try appendTemplate(buf, allocator, " by {author} opened ", .{ .author = author });
    try appendRelativeTime(buf, allocator, opened_at);
    try buf.appendSlice(allocator, "</small>");
    if (has_start_field or has_target_field) {
        try appendTemplate(buf, allocator,
            \\<form class="project-roadmap-date-form" method="post" action="/projects/items">
            \\  <input type="hidden" name="action" value="set-roadmap-dates">
            \\  <input type="hidden" name="project" value="{project}">
            \\  <input type="hidden" name="issue" value="{issue}">
            \\  <input type="hidden" name="view" value="roadmap">
        , .{
            .project = project,
            .issue = id,
        });
        if (has_start_field) {
            try appendTemplate(buf, allocator,
                \\  <label>Start<input type="date" name="start_at" value="{start_at}"></label>
            , .{ .start_at = start_at });
        }
        if (has_target_field) {
            try appendTemplate(buf, allocator,
                \\  <label>Target<input type="date" name="target_at" value="{target_at}"></label>
            , .{ .target_at = target_at });
        }
        try buf.appendSlice(allocator,
            \\  <button class="button secondary" type="submit">Save</button>
            \\</form>
        );
    }
    try buf.appendSlice(allocator, "</div></article>");
}

fn appendProjectViewTabs(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    project: []const u8,
    active_view: *const ActiveProjectView,
    issue_count: usize,
) !void {
    try buf.appendSlice(allocator, "<div class=\"project-view-tabs\" aria-label=\"Project views\">");
    const shown_saved_views = try appendProjectSavedViewTabs(buf, allocator, db, project, active_view);
    if (!shown_saved_views) {
        try appendProjectViewTab(buf, allocator, project, active_view, .table, "Table", "project-view-table-icon");
        try appendProjectViewTab(buf, allocator, project, active_view, .board, "Board", "project-view-board-icon");
        try appendProjectViewTab(buf, allocator, project, active_view, .roadmap, "Roadmap", "project-view-roadmap-icon");
    }
    try buf.appendSlice(allocator, "<a class=\"project-view-tab\" href=\"/issues?project=");
    try shared.appendUrlEncoded(buf, allocator, project);
    try appendTemplate(buf, allocator,
        \\">Issues <span class="issue-count-badge">{issue_count}</span></a></div>
    , .{ .issue_count = issue_count });
}

fn appendProjectItemActions(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    project: []const u8,
    active_view: *const ActiveProjectView,
) !void {
    const defaults = projectViewDefaultsFromConfig(allocator, active_view.config_json);
    try buf.appendSlice(allocator,
        \\<div class="project-item-actions">
    );
    try appendTemplate(buf, allocator,
        \\  <details class="project-action-menu" data-popover-menu>
        \\    <summary class="button primary" aria-expanded="false"><span class="project-add-icon" aria-hidden="true"></span>New issue</summary>
        \\    <div class="project-action-popover">
        \\      <form class="project-item-form" method="post" action="/projects/items">
        \\        <input type="hidden" name="action" value="create-issue">
        \\        <input type="hidden" name="project" value="{project}">
        \\        <input type="hidden" name="view" value="{view}">
        \\        <label>Title<input name="title" required></label>
        \\        <label>Body<textarea name="body" rows="4"></textarea></label>
        \\        <div class="grid two">
        \\          <label>Priority<select name="priority">
    , .{
        .project = project,
        .view = active_view.ref,
    });
    try appendProjectPriorityOptions(buf, allocator, defaults.priority);
    try buf.appendSlice(allocator,
        \\          </select></label>
        \\          <label>Status<select name="column">
    );
    try appendProjectColumnOptions(buf, allocator, db, project, defaults.status);
    try appendTemplate(buf, allocator,
        \\          </select></label>
        \\        </div>
        \\        <label>Labels<input name="labels" placeholder="bug, docs"></label>
        \\        <label>Assignees<input name="assignees" placeholder="alice, bob"></label>
        \\        <div class="form-actions"><button class="button primary" type="submit">Create issue</button></div>
        \\      </form>
        \\    </div>
        \\  </details>
        \\  <details class="project-action-menu" data-popover-menu>
        \\    <summary class="button secondary" aria-expanded="false"><span class="project-link-icon" aria-hidden="true"></span>Add existing</summary>
        \\    <div class="project-action-popover project-action-popover-narrow">
        \\      <form class="project-item-form" method="post" action="/projects/items">
        \\        <input type="hidden" name="action" value="add-existing">
        \\        <input type="hidden" name="project" value="{project}">
        \\        <input type="hidden" name="view" value="{view}">
        \\        <div class="project-issue-search-wrap tree-search-wrap">
        \\          <label class="tree-search-label project-issue-search-label"><span>Issue</span><input class="tree-search-input" name="issue" placeholder="Search issues or paste a ref" autocomplete="off" spellcheck="false" data-project-issue-search required></label>
        \\        </div>
        \\        <label>Priority<select name="priority">
    , .{
        .project = project,
        .view = active_view.ref,
    });
    try appendProjectPriorityOptions(buf, allocator, if (defaults.priority_explicit) defaults.priority else "");
    try buf.appendSlice(allocator,
        \\        </select></label>
        \\        <label>Status<select name="column">
    );
    try appendProjectColumnOptions(buf, allocator, db, project, if (defaults.status_explicit) defaults.status else null);
    try buf.appendSlice(allocator,
        \\        </select></label>
        \\        <div class="form-actions"><button class="button primary" type="submit">Add issue</button></div>
        \\      </form>
        \\    </div>
        \\  </details>
        \\</div>
    );
}

fn appendProjectViewTab(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    project: []const u8,
    active_view: *const ActiveProjectView,
    view: ProjectView,
    label: []const u8,
    icon_class: []const u8,
) !void {
    if (!active_view.saved and active_view.layout == view) {
        try appendTemplate(buf, allocator,
            \\<span class="project-view-tab active"><span class="{icon_class}" aria-hidden="true"></span>{label}</span>
        , .{
            .icon_class = icon_class,
            .label = label,
        });
        return;
    }
    try appendProjectViewLinkWithClass(buf, allocator, project, view, label, icon_class, "project-view-tab");
}

fn appendProjectSavedViewTabs(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    project: []const u8,
    active_view: *const ActiveProjectView,
) !bool {
    var stmt = try db.prepare(
        \\SELECT pv.id, pv.name, pv.layout
        \\FROM project_views pv
        \\JOIN projects p ON p.id = pv.project_id
        \\WHERE p.name = ? AND pv.state != 'removed'
        \\ORDER BY pv.position, pv.name, pv.id
    );
    defer stmt.deinit();
    try stmt.bindText(1, project);

    var shown = false;
    while (try stmt.step()) {
        const view_id = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(view_id);
        const name = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(name);
        const layout = try stmt.columnTextDup(allocator, 2);
        defer allocator.free(layout);
        const view_layout = projectViewFromValue(layout);
        const active = active_view.saved and std.mem.eql(u8, active_view.ref, view_id);
        try appendProjectSavedViewTab(buf, allocator, project, view_id, name, view_layout, active);
        shown = true;
    }
    return shown;
}

fn appendProjectSavedViewTab(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    project: []const u8,
    view_id: []const u8,
    name: []const u8,
    layout: ProjectView,
    active: bool,
) !void {
    const icon_class = projectViewIconClass(layout);
    if (active) {
        try appendTemplate(buf, allocator,
            \\<span class="project-view-tab active"><span class="{icon_class}" aria-hidden="true"></span>{name}</span>
        , .{
            .icon_class = icon_class,
            .name = name,
        });
        return;
    }
    try appendTemplate(buf, allocator,
        \\<a class="project-view-tab" href="
    , .{});
    try appendProjectViewRefHref(buf, allocator, project, view_id);
    try appendTemplate(buf, allocator,
        \\"><span class="{icon_class}" aria-hidden="true"></span>{name}</a>
    , .{
        .icon_class = icon_class,
        .name = name,
    });
}

fn appendProjectViewLink(buf: *std.ArrayList(u8), allocator: Allocator, project: []const u8, view: ProjectView, label: []const u8) !void {
    try appendProjectViewLinkWithClass(buf, allocator, project, view, label, "", "button secondary");
}

fn appendProjectViewLinkWithClass(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    project: []const u8,
    view: ProjectView,
    label: []const u8,
    icon_class: []const u8,
    class_name: []const u8,
) !void {
    try appendTemplate(buf, allocator,
        \\<a class="{class_name}" href="
    , .{ .class_name = class_name });
    try appendProjectHref(buf, allocator, project, view);
    try buf.appendSlice(allocator, "\">");
    if (icon_class.len != 0) {
        try appendTemplate(buf, allocator,
            \\<span class="{icon_class}" aria-hidden="true"></span>
        , .{ .icon_class = icon_class });
    }
    try appendTemplate(buf, allocator, "{label}</a>", .{ .label = label });
}

fn appendProjectHref(buf: *std.ArrayList(u8), allocator: Allocator, project: []const u8, view: ProjectView) !void {
    try appendProjectViewRefHref(buf, allocator, project, projectViewValue(view));
}

fn appendProjectViewRefHref(buf: *std.ArrayList(u8), allocator: Allocator, project: []const u8, view_ref: []const u8) !void {
    try buf.appendSlice(allocator, "/projects?project=");
    try shared.appendUrlEncoded(buf, allocator, project);
    try buf.appendSlice(allocator, "&amp;view=");
    try shared.appendUrlEncoded(buf, allocator, view_ref);
}

fn appendProjectNotFound(buf: *std.ArrayList(u8), allocator: Allocator, project: []const u8) !void {
    try buf.appendSlice(allocator, "<section class=\"panel\">");
    try appendSectionHead(buf, allocator, "Projects", "Project not found", Button{
        .label = "New project",
        .href = literalHref("/new-project"),
        .kind = "primary",
    });
    try appendTemplate(buf, allocator,
        \\<div class="empty"><strong>{project}</strong><p>No project or project issue placements match this name.</p></div>
        \\</section>
    , .{ .project = project });
}

fn appendProjectSummary(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, project: []const u8, issue_count: usize) !void {
    var stmt = try db.prepare(
        \\SELECT description, state
        \\FROM projects
        \\WHERE name = ?
        \\ORDER BY created_at DESC, id DESC
        \\LIMIT 1
    );
    defer stmt.deinit();
    try stmt.bindText(1, project);
    if (!(try stmt.step())) return;
    const description = try stmt.columnTextDup(allocator, 0);
    defer allocator.free(description);
    const state = try stmt.columnTextDup(allocator, 1);
    defer allocator.free(state);
    try buf.appendSlice(allocator, "<div class=\"project-summary\">");
    try appendStatePill(buf, allocator, state);
    try appendTemplate(buf, allocator,
        \\<span class="project-summary-count">{issue_count} item{s}</span>
    , .{
        .issue_count = issue_count,
        .s = if (issue_count == 1) "" else "s",
    });
    if (description.len != 0) {
        try appendTemplate(buf, allocator,
            \\<p class="muted">{description}</p>
        , .{ .description = description });
    }
    try buf.appendSlice(allocator, "</div>");
}

fn appendProjectColumn(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    project: []const u8,
    column: []const u8,
    context: *const ProjectRenderContext,
) !void {
    const count = try projectColumnIssueCount(db, project, column, context.filter);
    const title = if (column.len == 0) "No column" else column;
    const tone = columnTone(column);
    const note = columnDescription(column);
    try appendTemplate(buf, allocator,
        \\<section class="kanban-column tone-{tone}" data-project-column data-project="{project}" data-column="{column}">
        \\  <header>
        \\    <div class="kanban-column-title">
        \\      <span class="kanban-status-dot" aria-hidden="true"></span>
        \\      <h2>{title}</h2>
        \\      <span class="kanban-count">{count}</span>
        \\    </div>
        \\    <div class="kanban-column-actions">
        \\      <details class="kanban-column-add-menu" data-popover-menu>
        \\        <summary aria-label="Add issue to {title}" title="Add issue"><span class="kanban-column-add" aria-hidden="true"></span></summary>
        \\        <div class="kanban-column-popover">
        \\          <form class="project-item-form project-column-issue-form" method="post" action="/projects/items">
        \\            <input type="hidden" name="action" value="create-issue">
        \\            <input type="hidden" name="project" value="{project}">
        \\            <input type="hidden" name="view" value="{view}">
        \\            <label>Title<input name="title" required></label>
        \\            <label>Body<textarea name="body" rows="4"></textarea></label>
        \\            <div class="grid two">
        \\              <label>Priority<select name="priority">
    , .{
        .tone = tone,
        .project = project,
        .column = column,
        .view = context.view_ref,
        .title = title,
        .count = count,
        .note = note,
    });
    try appendProjectPriorityOptions(buf, allocator, context.defaults.priority);
    try buf.appendSlice(allocator,
        \\              </select></label>
        \\              <label>Status<select name="column">
    );
    try appendProjectColumnOptions(buf, allocator, db, project, column);
    try appendTemplate(buf, allocator,
        \\              </select></label>
        \\            </div>
        \\            <label>Labels<input name="labels" placeholder="bug, docs"></label>
        \\            <label>Assignees<input name="assignees" placeholder="alice, bob"></label>
        \\            <div class="form-actions"><button class="button primary" type="submit">Create issue</button></div>
        \\          </form>
        \\          <form class="project-item-form project-column-existing-form" method="post" action="/projects/items">
        \\            <input type="hidden" name="action" value="add-existing">
        \\            <input type="hidden" name="project" value="{project}">
        \\            <input type="hidden" name="column" value="{column}">
        \\            <input type="hidden" name="priority" value="{existing_priority}">
        \\            <input type="hidden" name="view" value="{view}">
        \\            <div class="project-issue-search-wrap tree-search-wrap">
        \\              <label class="tree-search-label project-issue-search-label"><span>Issue</span><input class="tree-search-input" name="issue" placeholder="Search issues or paste a ref" aria-label="Issue" autocomplete="off" spellcheck="false" data-project-issue-search required></label>
        \\            </div>
        \\            <div class="form-actions"><button class="button secondary" type="submit">Add issue</button></div>
        \\          </form>
        \\        </div>
        \\      </details>
        \\    </div>
        \\  </header>
        \\  <p class="kanban-column-note">{note}</p>
        \\  <div class="kanban-cards" data-project-dropzone>
    , .{
        .project = project,
        .column = column,
        .existing_priority = if (context.defaults.priority_explicit) context.defaults.priority else "",
        .view = context.view_ref,
        .note = note,
    });

    var cards = try db.prepare(
        \\WITH project_items AS (
        \\  SELECT pi.issue_id,
        \\         CASE
        \\           WHEN COALESCE(m.status, '') <> '' THEN m.status
        \\           ELSE pi.legacy_column
        \\         END AS effective_status
        \\  FROM (
        \\    SELECT issue_id, column_name AS legacy_column
        \\    FROM issue_projects
        \\    WHERE project = ?
        \\    UNION
        \\    SELECT pm.issue_id, ''
        \\    FROM project_memberships pm
        \\    JOIN projects p ON p.id = pm.project_id
        \\    WHERE p.name = ?
        \\  ) pi
        \\  LEFT JOIN issue_metadata m ON m.issue_id = pi.issue_id
        \\)
        \\SELECT DISTINCT i.id, i.title, i.state,
        \\       COALESCE(NULLIF(m.source_author, ''), i.author_principal),
        \\       i.opened_at,
        \\       COALESCE(m.priority, ''),
        \\       COALESCE(m.status, ''),
        \\       COALESCE(a.number, 0),
        \\       (SELECT COUNT(*) FROM comments c WHERE c.parent_kind = 'issue' AND c.parent_id = i.id)
        \\FROM project_items p
        \\JOIN issues i ON i.id = p.issue_id
        \\LEFT JOIN issue_metadata m ON m.issue_id = i.id
        \\LEFT JOIN legacy_aliases a
        \\  ON a.provider = 'github' AND a.object_kind = 'issue' AND a.object_id = i.id
        \\WHERE p.effective_status = ?
    ++ project_issue_filter_sql ++
        \\ORDER BY i.opened_at DESC, i.id DESC
    );
    defer cards.deinit();
    try cards.bindText(1, project);
    try cards.bindText(2, project);
    try cards.bindText(3, column);
    try bindProjectIssueFilter(&cards, 4, project, context.filter);
    var shown = false;
    while (try cards.step()) {
        const id = try cards.columnTextDup(allocator, 0);
        defer allocator.free(id);
        const card_title = try cards.columnTextDup(allocator, 1);
        defer allocator.free(card_title);
        const state = try cards.columnTextDup(allocator, 2);
        defer allocator.free(state);
        const author = try cards.columnTextDup(allocator, 3);
        defer allocator.free(author);
        const opened_at = try cards.columnTextDup(allocator, 4);
        defer allocator.free(opened_at);
        const priority = try cards.columnTextDup(allocator, 5);
        defer allocator.free(priority);
        const status = try cards.columnTextDup(allocator, 6);
        defer allocator.free(status);
        const legacy_number = cards.columnInt64(7);
        const comment_count = @as(usize, @intCast(cards.columnInt64(8)));

        var issue_ref_buf: [util.short_object_ref_len]u8 = undefined;
        const issue_ref = util.shortObjectRef(&issue_ref_buf, id);
        try appendTemplate(buf, allocator,
            \\<article class="kanban-card is-{state}" draggable="true" data-project-card data-project="{project}" data-issue-id="{id}" data-issue-ref="{issue_ref}" data-column="{column}">
            \\  <div class="kanban-card-head">
            \\    <span class="kanban-card-drag-handle" aria-hidden="true"></span>
            \\    <span class="issue-state-icon {state}" title="{state}" aria-label="{state}"></span>
            \\    <span class="kanban-card-ref">
        , .{
            .state = state,
            .project = project,
            .id = id,
            .issue_ref = issue_ref,
            .column = column,
        });
        if (legacy_number > 0) {
            try appendTemplate(buf, allocator, "GitHub #{legacy_number}", .{ .legacy_number = legacy_number });
        } else {
            try appendTemplate(buf, allocator, "#{id}", .{ .id = issue_ref });
        }
        try buf.appendSlice(allocator, "</span>");
        try appendIssueAvatar(buf, allocator, author, "kanban-card-avatar");
        try appendTemplate(buf, allocator,
            \\  </div>
            \\  <a class="kanban-card-title" href="{href}">{title}</a>
        , .{
            .href = issueHref(issue_ref),
            .title = card_title,
        });
        try appendKanbanCardLabels(buf, allocator, db, id);
        try appendTemplate(buf, allocator,
            \\  <div class="kanban-card-fields"><span class="project-priority-chip tone-{priority_tone}">{priority}</span><span class="project-status-chip tone-{status_tone}">{status}</span></div>
        , .{
            .priority_tone = priorityTone(priority),
            .priority = if (priority.len == 0) "None" else priority,
            .status_tone = columnTone(effectiveStatusLabel(status, column)),
            .status = effectiveStatusLabel(status, column),
        });
        try appendTemplate(buf, allocator,
            \\  <p class="kanban-card-meta">Opened by {author}
        , .{ .author = author });
        try buf.append(allocator, ' ');
        try appendRelativeTime(buf, allocator, opened_at);
        if (comment_count > 0) {
            try appendTemplate(buf, allocator,
                \\<span class="kanban-card-comments">{comment_count}</span>
            , .{ .comment_count = comment_count });
        }
        try buf.appendSlice(allocator, "</p></article>");
        shown = true;
    }
    if (!shown) try buf.appendSlice(allocator, "<div class=\"kanban-empty-drop\">No issues</div>");
    try buf.appendSlice(allocator, "</div></section>");
}

fn projectIssueCount(db: *SqliteDb, project: []const u8, filter: ProjectIssueFilter) !usize {
    var stmt = try db.prepare(
        \\WITH project_items AS (
        \\  SELECT issue_id
        \\  FROM issue_projects
        \\  WHERE project = ?
        \\  UNION
        \\  SELECT pm.issue_id
        \\  FROM project_memberships pm
        \\  JOIN projects p ON p.id = pm.project_id
        \\  WHERE p.name = ?
        \\)
        \\SELECT COUNT(DISTINCT i.id)
        \\FROM project_items p
        \\JOIN issues i ON i.id = p.issue_id
        \\WHERE 1 = 1
    ++ project_issue_filter_sql);
    defer stmt.deinit();
    try stmt.bindText(1, project);
    try stmt.bindText(2, project);
    try bindProjectIssueFilter(&stmt, 3, project, filter);
    if (!(try stmt.step())) return 0;
    return @intCast(stmt.columnInt64(0));
}

fn projectColumnIssueCount(db: *SqliteDb, project: []const u8, column: []const u8, filter: ProjectIssueFilter) !usize {
    var stmt = try db.prepare(
        \\WITH project_items AS (
        \\  SELECT pi.issue_id,
        \\         CASE
        \\           WHEN COALESCE(m.status, '') <> '' THEN m.status
        \\           ELSE pi.legacy_column
        \\         END AS effective_status
        \\  FROM (
        \\    SELECT issue_id, column_name AS legacy_column
        \\    FROM issue_projects
        \\    WHERE project = ?
        \\    UNION
        \\    SELECT pm.issue_id, ''
        \\    FROM project_memberships pm
        \\    JOIN projects p ON p.id = pm.project_id
        \\    WHERE p.name = ?
        \\  ) pi
        \\  LEFT JOIN issue_metadata m ON m.issue_id = pi.issue_id
        \\)
        \\SELECT COUNT(DISTINCT i.id)
        \\FROM project_items p
        \\JOIN issues i ON i.id = p.issue_id
        \\WHERE p.effective_status = ?
    ++ project_issue_filter_sql);
    defer stmt.deinit();
    try stmt.bindText(1, project);
    try stmt.bindText(2, project);
    try stmt.bindText(3, column);
    try bindProjectIssueFilter(&stmt, 4, project, filter);
    if (!(try stmt.step())) return 0;
    return @intCast(stmt.columnInt64(0));
}

fn projectPriorityIssueCount(db: *SqliteDb, project: []const u8, priority: []const u8, filter: ProjectIssueFilter) !usize {
    var stmt = try db.prepare(
        \\WITH project_items AS (
        \\  SELECT issue_id
        \\  FROM issue_projects
        \\  WHERE project = ?
        \\  UNION
        \\  SELECT pm.issue_id
        \\  FROM project_memberships pm
        \\  JOIN projects p ON p.id = pm.project_id
        \\  WHERE p.name = ?
        \\)
        \\SELECT COUNT(DISTINCT p.issue_id)
        \\FROM project_items p
        \\JOIN issues i ON i.id = p.issue_id
        \\LEFT JOIN issue_metadata m ON m.issue_id = p.issue_id
        \\WHERE COALESCE(m.priority, '') = ?
    ++ project_issue_filter_sql);
    defer stmt.deinit();
    try stmt.bindText(1, project);
    try stmt.bindText(2, project);
    try stmt.bindText(3, priority);
    try bindProjectIssueFilter(&stmt, 4, project, filter);
    if (!(try stmt.step())) return 0;
    return @intCast(stmt.columnInt64(0));
}

fn projectFieldKeyExists(db: *SqliteDb, project: []const u8, field_key: []const u8) !bool {
    var stmt = try db.prepare(
        \\SELECT 1
        \\FROM project_fields pf
        \\JOIN projects p ON p.id = pf.project_id
        \\WHERE p.name = ? AND pf.key = ? AND pf.state != 'removed'
        \\LIMIT 1
    );
    defer stmt.deinit();
    try stmt.bindText(1, project);
    try stmt.bindText(2, field_key);
    return try stmt.step();
}

fn projectFieldStringValue(allocator: Allocator, db: *SqliteDb, project: []const u8, issue_id: []const u8, field_key: []const u8) ![]u8 {
    var stmt = try db.prepare(
        \\SELECT COALESCE(json_extract(pfv.value_json, '$'), '')
        \\FROM project_field_values pfv
        \\JOIN project_fields pf ON pf.id = pfv.field_id AND pf.project_id = pfv.project_id
        \\JOIN projects p ON p.id = pfv.project_id
        \\WHERE p.name = ?
        \\  AND pfv.issue_id = ?
        \\  AND pf.key = ?
        \\  AND pf.state != 'removed'
        \\LIMIT 1
    );
    defer stmt.deinit();
    try stmt.bindText(1, project);
    try stmt.bindText(2, issue_id);
    try stmt.bindText(3, field_key);
    if (!(try stmt.step())) return try allocator.dupe(u8, "");
    return try stmt.columnTextDup(allocator, 0);
}

pub fn renderProjectForm(
    allocator: Allocator,
    repo: Repo,
    error_message: ?[]const u8,
    name_value: []const u8,
    description_value: []const u8,
    columns_value: []const u8,
    template_id: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const selected_template = projectTemplateById(template_id);

    try appendShellStart(&buf, allocator, repo, "New Project", "projects");
    try buf.appendSlice(allocator, "<section class=\"panel project-create-panel\">");
    try appendTemplate(&buf, allocator,
        \\<div class="project-create-head">
        \\  <div>
        \\    <p class="eyebrow">Projects</p>
        \\    <h1>Create project</h1>
        \\  </div>
        \\  <a class="button secondary" href="/projects" aria-label="Close create project">Close</a>
        \\</div>
    , .{});
    if (error_message) |message| {
        try appendTemplate(&buf, allocator,
            \\<div class="flash error">{message}</div>
        , .{ .message = message });
    }
    try buf.appendSlice(allocator, "<div class=\"project-create-layout\">");
    try appendProjectTemplateSidebar(&buf, allocator, selected_template.id);
    try buf.appendSlice(allocator,
        \\<div class="project-template-workspace">
        \\  <div class="project-template-search">
        \\    <span class="project-template-search-icon" aria-hidden="true"></span>
        \\    <input type="search" placeholder="Search templates" aria-label="Search templates" data-project-template-search>
        \\  </div>
        \\  <div class="project-template-content">
        \\    <div class="project-template-list" data-project-template-list>
        \\      <h2>Featured</h2>
    );
    try appendProjectTemplateCards(&buf, allocator, selected_template.id, .featured);
    try buf.appendSlice(allocator,
        \\      <h2>Start from scratch</h2>
    );
    try appendProjectTemplateCards(&buf, allocator, selected_template.id, .scratch);
    try buf.appendSlice(allocator,
        \\    </div>
    );
    try appendProjectConfigForm(&buf, allocator, selected_template, name_value, description_value, columns_value);
    try buf.appendSlice(allocator,
        \\  </div>
        \\</div>
        \\</div>
        \\</section>
    );
    try appendProjectTemplateSearchScript(&buf, allocator);
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

pub fn renderProjectFormFromTarget(allocator: Allocator, repo: Repo, target: []const u8) ![]u8 {
    const template_id = try queryValueOwned(allocator, target, "template");
    defer if (template_id) |value| allocator.free(value);
    const selected_template = projectTemplateById(template_id orelse default_project_template_id);

    const name = try queryValueOwned(allocator, target, "name");
    defer if (name) |value| allocator.free(value);
    const description = try queryValueOwned(allocator, target, "description");
    defer if (description) |value| allocator.free(value);
    const columns = try queryValueOwned(allocator, target, "columns");
    defer if (columns) |value| allocator.free(value);

    return renderProjectForm(
        allocator,
        repo,
        null,
        name orelse "",
        description orelse selected_template.description,
        columns orelse selected_template.columns,
        selected_template.id,
    );
}

const TemplateFieldOption = struct {
    name: []const u8,
    color: []const u8,
};

fn seedProjectTemplateEvents(allocator: Allocator, template_id: []const u8, project_id: []const u8) !void {
    const template = projectTemplateById(template_id);
    if (std.mem.eql(u8, template.id, "table")) {
        try seedTemplateView(allocator, project_id, "Table", "table", 1, table_status_view_config);
    } else if (std.mem.eql(u8, template.id, "board")) {
        try seedTemplateView(allocator, project_id, "Board", "board", 1, board_status_view_config);
        try seedTemplateView(allocator, project_id, "Table", "table", 2, table_status_view_config);
    } else if (std.mem.eql(u8, template.id, "roadmap")) {
        try seedRoadmapFields(allocator, project_id, 1);
        try seedTemplateView(allocator, project_id, "Roadmap", "roadmap", 1, roadmap_view_config);
        try seedTemplateView(allocator, project_id, "Table", "table", 2, table_status_view_config);
    } else if (std.mem.eql(u8, template.id, "kanban")) {
        try seedTemplateView(allocator, project_id, "Board", "board", 1, kanban_board_view_config);
        try seedTemplateView(allocator, project_id, "Prioritized", "table", 2, priority_table_view_config);
        try seedTemplateView(allocator, project_id, "My items", "table", 3, my_items_view_config);
    } else if (std.mem.eql(u8, template.id, "feature-release")) {
        try seedSizeField(allocator, project_id, 1);
        try seedRoadmapFields(allocator, project_id, 2);
        try seedTemplateView(allocator, project_id, "Prioritized", "table", 1, priority_table_view_config);
        try seedTemplateView(allocator, project_id, "Status", "board", 2, board_status_view_config);
        try seedTemplateView(allocator, project_id, "Roadmap", "roadmap", 3, roadmap_view_config);
        try seedTemplateView(allocator, project_id, "Bugs", "table", 4, bugs_view_config);
    } else if (std.mem.eql(u8, template.id, "bug-tracker")) {
        try seedTemplateView(allocator, project_id, "Prioritized bugs", "table", 1, bugs_priority_view_config);
        try seedTemplateView(allocator, project_id, "Triage", "board", 2, bug_triage_view_config);
        try seedTemplateView(allocator, project_id, "My items", "table", 3, my_items_view_config);
    } else if (std.mem.eql(u8, template.id, "team-planning")) {
        try seedTemplateField(allocator, project_id, "iteration", "Iteration", "text", 1);
        try seedTemplateField(allocator, project_id, "estimate", "Estimate", "number", 2);
        try seedRoadmapFields(allocator, project_id, 3);
        try seedTemplateView(allocator, project_id, "Backlog", "table", 1, table_status_view_config);
        try seedTemplateView(allocator, project_id, "Board", "board", 2, board_status_view_config);
        try seedTemplateView(allocator, project_id, "Current iteration", "table", 3, current_iteration_view_config);
        try seedTemplateView(allocator, project_id, "Roadmap", "roadmap", 4, roadmap_view_config);
        try seedTemplateView(allocator, project_id, "My items", "table", 5, my_items_view_config);
    }
}

fn seedTemplateField(
    allocator: Allocator,
    project_id: []const u8,
    key: []const u8,
    name: []const u8,
    field_type: []const u8,
    position: i64,
) !void {
    const field_id = try createProjectFieldCreatedEvent(allocator, project_id, key, name, field_type, position, false, null);
    defer allocator.free(field_id);
}

fn seedTemplateSingleSelectField(
    allocator: Allocator,
    project_id: []const u8,
    key: []const u8,
    name: []const u8,
    position: i64,
    options: []const TemplateFieldOption,
) !void {
    const field_id = try createProjectFieldCreatedEvent(allocator, project_id, key, name, "single_select", position, false, null);
    defer allocator.free(field_id);
    for (options, 0..) |option, option_index| {
        const option_position: i64 = @intCast(option_index + 1);
        try createProjectFieldOptionAddedEvent(allocator, project_id, field_id, option.name, option.color, option_position);
    }
}

fn seedRoadmapFields(allocator: Allocator, project_id: []const u8, start_position: i64) !void {
    try seedTemplateField(allocator, project_id, "start_at", "Start date", "date", start_position);
    try seedTemplateField(allocator, project_id, "target_at", "Target date", "date", start_position + 1);
}

fn seedSizeField(allocator: Allocator, project_id: []const u8, position: i64) !void {
    const size_options = [_]TemplateFieldOption{
        .{ .name = "S", .color = "green" },
        .{ .name = "M", .color = "blue" },
        .{ .name = "L", .color = "orange" },
    };
    try seedTemplateSingleSelectField(allocator, project_id, "size", "Size", position, size_options[0..]);
}

fn seedTemplateView(
    allocator: Allocator,
    project_id: []const u8,
    name: []const u8,
    layout: []const u8,
    position: i64,
    config_json: []const u8,
) !void {
    try createProjectViewCreatedEvent(allocator, project_id, name, layout, position, config_json);
}

const table_status_view_config =
    \\{"group_by":"issue.status","fields":["issue.priority","issue.status","issue.state","issue.assignees","issue.labels","issue.milestone"]}
;
const board_status_view_config =
    \\{"group_by":"issue.status","columns":["Draft","Todo","WIP","Review","Done","Failed"],"card_fields":["issue.priority","issue.state","issue.assignees","issue.labels"]}
;
const kanban_board_view_config =
    \\{"group_by":"issue.status","columns":["Draft","Todo","WIP","Review","Done","Failed"],"defaults":{"issue.status":"Draft","issue.priority":"P3"},"card_fields":["issue.priority","issue.state","issue.assignees","issue.labels"]}
;
const priority_table_view_config =
    \\{"group_by":"issue.priority","fields":["issue.priority","issue.status","issue.state","issue.assignees","issue.labels","issue.milestone"],"defaults":{"issue.priority":"P3","issue.status":"Draft"}}
;
const my_items_view_config =
    \\{"filter":{"assignee":"@me"},"group_by":"issue.status","fields":["issue.priority","issue.status","issue.state","issue.assignees","issue.labels"]}
;
const roadmap_view_config =
    \\{"start":"project.start_at","target":"project.target_at","group_by":"issue.priority","status":"issue.status","fields":["issue.priority","issue.status","project.start_at","project.target_at"]}
;
const bugs_view_config =
    \\{"filter":{"any":[{"issue.type":"bug"},{"label":"bug"}]},"group_by":"issue.status","fields":["issue.priority","issue.status","issue.state","issue.assignees","issue.labels"]}
;
const bugs_priority_view_config =
    \\{"filter":{"any":[{"issue.type":"bug"},{"label":"bug"}]},"group_by":"issue.priority","fields":["issue.priority","issue.status","issue.state","issue.assignees","issue.labels"],"defaults":{"issue.priority":"P3","issue.status":"Draft"}}
;
const bug_triage_view_config =
    \\{"filter":{"any":[{"issue.type":"bug"},{"label":"bug"}]},"group_by":"issue.status","columns":["Draft","Todo","WIP","Review","Done","Failed"],"defaults":{"issue.status":"Todo","issue.priority":"P3"},"card_fields":["issue.priority","issue.state","issue.assignees","issue.labels"]}
;
const current_iteration_view_config =
    \\{"filter":{"project.iteration":"current"},"group_by":"issue.status","fields":["project.iteration","project.estimate","issue.priority","issue.status","issue.assignees"]}
;

pub fn handleProjectPost(allocator: Allocator, repo: Repo, stream: std.net.Stream, form_body: []const u8) !void {
    const name_owned = (try formValueOwned(allocator, form_body, "name")) orelse try allocator.dupe(u8, "");
    defer allocator.free(name_owned);
    const description_owned = (try formValueOwned(allocator, form_body, "description")) orelse try allocator.dupe(u8, "");
    defer allocator.free(description_owned);
    const columns_owned = (try formValueOwned(allocator, form_body, "columns")) orelse try allocator.dupe(u8, "");
    defer allocator.free(columns_owned);
    const template_owned = (try formValueOwned(allocator, form_body, "template")) orelse try allocator.dupe(u8, default_project_template_id);
    defer allocator.free(template_owned);

    const name = std.mem.trim(u8, name_owned, " \t\r\n");
    if (name.len == 0) {
        const body = try renderProjectForm(allocator, repo, "Name is required.", name_owned, description_owned, columns_owned, template_owned);
        defer allocator.free(body);
        try sendResponse(allocator, stream, 422, "Unprocessable Entity", "text/html", body, null);
        return;
    }

    const effective_columns = if (std.mem.trim(u8, columns_owned, " \t\r\n").len == 0) default_project_status_columns else columns_owned;
    var columns = try splitCommaFields(allocator, effective_columns);
    defer columns.deinit(allocator);
    for (columns.items) |column| {
        if (!isProjectStatusValue(column)) {
            const body = try renderProjectForm(allocator, repo, "Status values must be Draft, Todo, WIP, Review, Done, or Failed.", name_owned, description_owned, effective_columns, template_owned);
            defer allocator.free(body);
            try sendResponse(allocator, stream, 422, "Unprocessable Entity", "text/html", body, null);
            return;
        }
    }

    const project_id = createProjectCreatedEvent(allocator, name, description_owned, columns.items) catch {
        const body = try renderProjectForm(
            allocator,
            repo,
            "Could not create the project. Check that Gitomi is initialized and Git commit signing is configured.",
            name_owned,
            description_owned,
            columns_owned,
            template_owned,
        );
        defer allocator.free(body);
        try sendResponse(allocator, stream, 500, "Internal Server Error", "text/html", body, null);
        return;
    };
    defer allocator.free(project_id);

    seedProjectTemplateEvents(allocator, template_owned, project_id) catch {
        const body = try renderProjectForm(
            allocator,
            repo,
            "Project was created, but template setup failed. Check that Gitomi commit signing is configured and try adding views from the project CLI.",
            name_owned,
            description_owned,
            columns_owned,
            template_owned,
        );
        defer allocator.free(body);
        try sendResponse(allocator, stream, 500, "Internal Server Error", "text/html", body, null);
        return;
    };

    try sendRedirect(allocator, stream, "/projects");
}

pub fn handleProjectItemPost(allocator: Allocator, repo: Repo, stream: std.net.Stream, form_body: []const u8) !void {
    const action_owned = try formTrimmedOwned(allocator, form_body, "action");
    defer allocator.free(action_owned);
    const project_owned = try formTrimmedOwned(allocator, form_body, "project");
    defer allocator.free(project_owned);
    var column_owned = try formTrimmedOwned(allocator, form_body, "column");
    defer allocator.free(column_owned);
    const priority_owned = try formTrimmedOwned(allocator, form_body, "priority");
    defer allocator.free(priority_owned);
    const view_owned = try formTrimmedOwned(allocator, form_body, "view");
    defer allocator.free(view_owned);
    const request_mode_owned = try formTrimmedOwned(allocator, form_body, "request_mode");
    defer allocator.free(request_mode_owned);

    const wants_async = std.mem.eql(u8, request_mode_owned, "async");
    if (project_owned.len == 0) {
        try sendProjectItemError(allocator, stream, wants_async, 422, "Unprocessable Entity", "Project is required\n");
        return;
    }
    if (column_owned.len == 0) {
        allocator.free(column_owned);
        column_owned = try allocator.dupe(u8, default_project_status);
    }
    if (!isProjectStatusValue(column_owned)) {
        try sendProjectItemError(allocator, stream, wants_async, 422, "Unprocessable Entity", "Status must be Draft, Todo, WIP, Review, Done, or Failed\n");
        return;
    }
    if (priority_owned.len != 0 and !isProjectPriorityValue(priority_owned)) {
        try sendProjectItemError(allocator, stream, wants_async, 422, "Unprocessable Entity", "Priority must be P0, P1, P2, or P3\n");
        return;
    }

    if (std.mem.eql(u8, action_owned, "create-issue")) {
        const title_owned = try formTrimmedOwned(allocator, form_body, "title");
        defer allocator.free(title_owned);
        if (title_owned.len == 0) {
            try sendProjectItemError(allocator, stream, wants_async, 422, "Unprocessable Entity", "Title is required\n");
            return;
        }
        const body_owned = (try formValueOwned(allocator, form_body, "body")) orelse try allocator.dupe(u8, "");
        defer allocator.free(body_owned);
        const labels_owned = (try formValueOwned(allocator, form_body, "labels")) orelse try allocator.dupe(u8, "");
        defer allocator.free(labels_owned);
        const assignees_owned = (try formValueOwned(allocator, form_body, "assignees")) orelse try allocator.dupe(u8, "");
        defer allocator.free(assignees_owned);
        var labels = try splitCommaFields(allocator, labels_owned);
        defer labels.deinit(allocator);
        var assignees = try splitCommaFields(allocator, assignees_owned);
        defer assignees.deinit(allocator);
        const placements = [_]event_mod.IssueProjectPlacement{.{
            .project = project_owned,
            .column = column_owned,
        }};
        createIssueOpenedWithMetadataEvent(
            allocator,
            title_owned,
            body_owned,
            labels.items,
            assignees.items,
            .{
                .priority = if (priority_owned.len == 0) default_project_priority else priority_owned,
                .status = column_owned,
                .projects = placements[0..],
            },
        ) catch {
            try sendProjectItemError(allocator, stream, wants_async, 500, "Internal Server Error", "Could not create issue\n");
            return;
        };
    } else if (std.mem.eql(u8, action_owned, "set-roadmap-dates")) {
        const issue_ref_owned = try formTrimmedOwned(allocator, form_body, "issue");
        defer allocator.free(issue_ref_owned);
        if (issue_ref_owned.len == 0) {
            try sendProjectItemError(allocator, stream, wants_async, 422, "Unprocessable Entity", "Issue is required\n");
            return;
        }
        const start_at_owned = try formTrimmedOwned(allocator, form_body, "start_at");
        defer allocator.free(start_at_owned);
        const target_at_owned = try formTrimmedOwned(allocator, form_body, "target_at");
        defer allocator.free(target_at_owned);
        if (!isProjectDateValue(start_at_owned) or !isProjectDateValue(target_at_owned)) {
            try sendProjectItemError(allocator, stream, wants_async, 422, "Unprocessable Entity", "Dates must use YYYY-MM-DD\n");
            return;
        }
        try index.ensureIndex(allocator, repo);
        const issue_id = index.resolveIssueId(allocator, repo, issue_ref_owned) catch {
            try sendProjectItemError(allocator, stream, wants_async, 404, "Not Found", "Issue not found\n");
            return;
        };
        defer allocator.free(issue_id);
        const project_id = index.resolveProjectId(allocator, repo, project_owned) catch {
            try sendProjectItemError(allocator, stream, wants_async, 404, "Not Found", "Project not found\n");
            return;
        };
        defer allocator.free(project_id);
        setProjectDateField(allocator, repo, issue_id, project_id, project_owned, "start_at", start_at_owned) catch {
            try sendProjectItemError(allocator, stream, wants_async, 500, "Internal Server Error", "Could not update roadmap start date\n");
            return;
        };
        setProjectDateField(allocator, repo, issue_id, project_id, project_owned, "target_at", target_at_owned) catch {
            try sendProjectItemError(allocator, stream, wants_async, 500, "Internal Server Error", "Could not update roadmap target date\n");
            return;
        };
    } else if (std.mem.eql(u8, action_owned, "set-project-field")) {
        const issue_ref_owned = try formTrimmedOwned(allocator, form_body, "issue");
        defer allocator.free(issue_ref_owned);
        if (issue_ref_owned.len == 0) {
            try sendProjectItemError(allocator, stream, wants_async, 422, "Unprocessable Entity", "Issue is required\n");
            return;
        }
        const field_key_owned = try formTrimmedOwned(allocator, form_body, "field");
        defer allocator.free(field_key_owned);
        if (field_key_owned.len == 0) {
            try sendProjectItemError(allocator, stream, wants_async, 422, "Unprocessable Entity", "Project field is required\n");
            return;
        }
        const value_owned = try formTrimmedOwned(allocator, form_body, "value");
        defer allocator.free(value_owned);
        try index.ensureIndex(allocator, repo);
        const issue_id = index.resolveIssueId(allocator, repo, issue_ref_owned) catch {
            try sendProjectItemError(allocator, stream, wants_async, 404, "Not Found", "Issue not found\n");
            return;
        };
        defer allocator.free(issue_id);
        const project_id = index.resolveProjectId(allocator, repo, project_owned) catch {
            try sendProjectItemError(allocator, stream, wants_async, 404, "Not Found", "Project not found\n");
            return;
        };
        defer allocator.free(project_id);
        setProjectFieldValue(allocator, repo, issue_id, project_id, project_owned, field_key_owned, value_owned) catch |err| {
            switch (err) {
                error.InvalidProjectFieldValue => try sendProjectItemError(allocator, stream, wants_async, 422, "Unprocessable Entity", "Project field value is invalid\n"),
                else => try sendProjectItemError(allocator, stream, wants_async, 500, "Internal Server Error", "Could not update project field\n"),
            }
            return;
        };
    } else if (std.mem.eql(u8, action_owned, "add-existing") or std.mem.eql(u8, action_owned, "move")) {
        const issue_ref_owned = try formTrimmedOwned(allocator, form_body, "issue");
        defer allocator.free(issue_ref_owned);
        if (issue_ref_owned.len == 0) {
            try sendProjectItemError(allocator, stream, wants_async, 422, "Unprocessable Entity", "Issue is required\n");
            return;
        }
        try index.ensureIndex(allocator, repo);
        const issue_id = index.resolveIssueId(allocator, repo, issue_ref_owned) catch {
            try sendProjectItemError(allocator, stream, wants_async, 404, "Not Found", "Issue not found\n");
            return;
        };
        defer allocator.free(issue_id);
        updateIssueProjectMetadata(allocator, repo, issue_id, project_owned, column_owned, priority_owned) catch {
            try sendProjectItemError(allocator, stream, wants_async, 500, "Internal Server Error", "Could not update issue project metadata\n");
            return;
        };
    } else if (std.mem.eql(u8, action_owned, "remove")) {
        const issue_ref_owned = try formTrimmedOwned(allocator, form_body, "issue");
        defer allocator.free(issue_ref_owned);
        if (issue_ref_owned.len == 0) {
            try sendProjectItemError(allocator, stream, wants_async, 422, "Unprocessable Entity", "Issue is required\n");
            return;
        }
        try index.ensureIndex(allocator, repo);
        const issue_id = index.resolveIssueId(allocator, repo, issue_ref_owned) catch {
            try sendProjectItemError(allocator, stream, wants_async, 404, "Not Found", "Issue not found\n");
            return;
        };
        defer allocator.free(issue_id);
        removeIssueProjectPlacements(allocator, repo, issue_id, project_owned, null) catch {
            try sendProjectItemError(allocator, stream, wants_async, 500, "Internal Server Error", "Could not remove issue from project\n");
            return;
        };
    } else {
        try sendProjectItemError(allocator, stream, wants_async, 422, "Unprocessable Entity", "Unknown project item action\n");
        return;
    }

    if (wants_async) {
        try sendResponse(allocator, stream, 204, "No Content", "text/plain", "", null);
        return;
    }
    const location = try projectWorkspaceLocationOwned(allocator, project_owned, view_owned);
    defer allocator.free(location);
    try sendRedirect(allocator, stream, location);
}

fn setProjectDateField(
    allocator: Allocator,
    repo: Repo,
    issue_id: []const u8,
    project_id: []const u8,
    project_ref: []const u8,
    field_key: []const u8,
    value: []const u8,
) !void {
    const field_id = index.resolveProjectFieldId(allocator, repo, project_id, field_key) catch |err| {
        if (value.len == 0) return;
        return err;
    };
    defer allocator.free(field_id);
    if (value.len == 0) {
        try createIssueProjectFieldClearedEvent(allocator, issue_id, project_id, project_ref, field_id, null);
        return;
    }
    const value_json = try jsonStringArgument(allocator, value);
    defer allocator.free(value_json);
    try createIssueProjectFieldSetEvent(allocator, issue_id, project_id, project_ref, field_id, null, value_json);
}

fn setProjectFieldValue(
    allocator: Allocator,
    repo: Repo,
    issue_id: []const u8,
    project_id: []const u8,
    project_ref: []const u8,
    field_key: []const u8,
    value: []const u8,
) !void {
    const field_id = try index.resolveProjectFieldId(allocator, repo, project_id, field_key);
    defer allocator.free(field_id);
    if (value.len == 0) {
        try createIssueProjectFieldClearedEvent(allocator, issue_id, project_id, project_ref, field_id, null);
        return;
    }
    const field_type = try projectFieldTypeOwned(allocator, repo, project_id, field_id);
    defer allocator.free(field_type);
    const value_json = try projectFieldValueJson(allocator, field_type, value);
    defer allocator.free(value_json);
    try createIssueProjectFieldSetEvent(allocator, issue_id, project_id, project_ref, field_id, null, value_json);
}

fn projectFieldTypeOwned(allocator: Allocator, repo: Repo, project_id: []const u8, field_id: []const u8) ![]u8 {
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var stmt = try db.prepare(
        \\SELECT field_type
        \\FROM project_fields
        \\WHERE project_id = ? AND id = ? AND state != 'removed'
        \\LIMIT 1
    );
    defer stmt.deinit();
    try stmt.bindText(1, project_id);
    try stmt.bindText(2, field_id);
    if (!(try stmt.step())) return error.ProjectFieldNotFound;
    return try stmt.columnTextDup(allocator, 0);
}

fn projectFieldValueJson(allocator: Allocator, field_type: []const u8, value: []const u8) ![]u8 {
    if (std.mem.eql(u8, field_type, "number")) {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, value, .{}) catch return error.InvalidProjectFieldValue;
        defer parsed.deinit();
        switch (parsed.value) {
            .integer, .float => {},
            else => return error.InvalidProjectFieldValue,
        }
        return try allocator.dupe(u8, value);
    }
    if (std.mem.eql(u8, field_type, "boolean")) {
        if (!std.mem.eql(u8, value, "true") and !std.mem.eql(u8, value, "false")) return error.InvalidProjectFieldValue;
        return try allocator.dupe(u8, value);
    }
    if (std.mem.eql(u8, field_type, "date") and !isProjectDateValue(value)) return error.InvalidProjectFieldValue;
    return try jsonStringArgument(allocator, value);
}

fn isProjectDateValue(value: []const u8) bool {
    if (value.len == 0) return true;
    if (value.len != 10) return false;
    for (value, 0..) |char, index_value| {
        if (index_value == 4 or index_value == 7) {
            if (char != '-') return false;
        } else if (!std.ascii.isDigit(char)) {
            return false;
        }
    }
    return true;
}

fn appendProjectTemplateSidebar(buf: *std.ArrayList(u8), allocator: Allocator, selected_id: []const u8) !void {
    try buf.appendSlice(allocator,
        \\<aside class="project-template-sidebar">
        \\  <div class="project-template-sidebar-group">
        \\    <span>Project templates</span>
    );
    try appendProjectTemplateNavLink(buf, allocator, "Featured", "kanban", selected_id);
    try appendProjectTemplateNavLink(buf, allocator, "All templates", "team-planning", selected_id);
    try appendProjectTemplateNavLink(buf, allocator, "From this repository", "bug-tracker", selected_id);
    try buf.appendSlice(allocator,
        \\  </div>
        \\  <div class="project-template-sidebar-group">
        \\    <span>Start from scratch</span>
    );
    try appendProjectTemplateNavLink(buf, allocator, "Table", "table", selected_id);
    try appendProjectTemplateNavLink(buf, allocator, "Board", "board", selected_id);
    try appendProjectTemplateNavLink(buf, allocator, "Roadmap", "roadmap", selected_id);
    try buf.appendSlice(allocator,
        \\  </div>
        \\</aside>
    );
}

fn appendProjectTemplateNavLink(buf: *std.ArrayList(u8), allocator: Allocator, label: []const u8, template_id: []const u8, selected_id: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<a{class_attr} href="/new-project?template={template_id}">{label}</a>
    , .{
        .class_attr = shared.classAttr("project-template-nav-link", &.{shared.class("active", std.mem.eql(u8, template_id, selected_id))}),
        .template_id = template_id,
        .label = label,
    });
}

fn appendProjectTemplateCards(buf: *std.ArrayList(u8), allocator: Allocator, selected_id: []const u8, group: TemplateGroup) !void {
    try buf.appendSlice(allocator, "<div class=\"project-template-grid\">");
    for (project_templates) |template| {
        if (template.group != group) continue;
        try appendProjectTemplateCard(buf, allocator, template, selected_id);
    }
    try buf.appendSlice(allocator, "</div>");
}

fn appendProjectTemplateCard(buf: *std.ArrayList(u8), allocator: Allocator, template: ProjectTemplate, selected_id: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<a{class_attr} href="/new-project?template={id}" data-project-template-card data-template-text="{title} {source} {description}">
    , .{
        .class_attr = shared.classAttr("project-template-card", &.{shared.class("selected", std.mem.eql(u8, template.id, selected_id))}),
        .id = template.id,
        .title = template.title,
        .source = template.source,
        .description = template.description,
    });
    try appendProjectTemplatePreview(buf, allocator, template.preview);
    try appendTemplate(buf, allocator,
        \\  <div class="project-template-card-body">
        \\    <h3>{title} <span>&middot; {source}</span></h3>
        \\    <p>{description}</p>
        \\  </div>
        \\</a>
    , .{
        .title = template.title,
        .source = template.source,
        .description = template.description,
    });
}

fn appendProjectTemplatePreview(buf: *std.ArrayList(u8), allocator: Allocator, preview: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<div class="project-template-preview preview-{preview}" aria-hidden="true">
    , .{ .preview = preview });
    if (std.mem.eql(u8, preview, "board")) {
        try buf.appendSlice(allocator,
            \\<span></span><span></span><span></span><span></span><span></span><span></span>
        );
    } else if (std.mem.eql(u8, preview, "roadmap")) {
        try buf.appendSlice(allocator,
            \\<span></span><span></span><span></span><span></span>
        );
    } else {
        try buf.appendSlice(allocator,
            \\<span></span><span></span><span></span><span></span><span></span><span></span><span></span><span></span>
        );
    }
    try buf.appendSlice(allocator, "</div>");
}

fn appendProjectConfigForm(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    selected_template: *const ProjectTemplate,
    name_value: []const u8,
    description_value: []const u8,
    columns_value: []const u8,
) !void {
    try appendTemplate(buf, allocator,
        \\<aside class="project-config-card">
        \\  <div class="project-config-head">
        \\    <span>Selected template</span>
        \\    <h2>{title}</h2>
        \\    <p>{description}</p>
        \\  </div>
        \\  <form method="post" action="/projects" class="issue-form project-form">
        \\    <input type="hidden" name="template" value="{template_id}">
        \\    <label>Name<input name="name" value="{name_value}" autofocus required></label>
        \\    <label>Description<textarea name="description" rows="4">{description_value}</textarea></label>
        \\    <label>Status values<input name="columns" value="{columns_value}" placeholder="Draft, Todo, WIP, Review, Done, Failed"></label>
        \\    <div class="project-column-chips" aria-label="Template status values">
    , .{
        .title = selected_template.title,
        .description = selected_template.description,
        .template_id = selected_template.id,
        .name_value = name_value,
        .description_value = description_value,
        .columns_value = columns_value,
    });
    try appendColumnChips(buf, allocator, columns_value);
    try buf.appendSlice(allocator,
        \\    </div>
        \\    <div class="form-actions">
        \\      <a class="button secondary" href="/projects">Cancel</a>
        \\      <button class="button primary" type="submit">Create project</button>
        \\    </div>
        \\  </form>
        \\</aside>
    );
}

fn appendColumnChips(buf: *std.ArrayList(u8), allocator: Allocator, columns_value: []const u8) !void {
    var parts = std.mem.splitScalar(u8, columns_value, ',');
    var shown = false;
    while (parts.next()) |part| {
        const column = std.mem.trim(u8, part, " \t\r\n");
        if (column.len == 0) continue;
        try appendTemplate(buf, allocator,
            \\<span>{column}</span>
        , .{ .column = column });
        shown = true;
    }
    if (!shown) try buf.appendSlice(allocator, "<span>Draft</span><span>Todo</span><span>WIP</span><span>Review</span><span>Done</span><span>Failed</span>");
}

fn appendProjectTemplateSearchScript(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator,
        \\<script>
        \\(function () {
        \\  var search = document.querySelector("[data-project-template-search]");
        \\  if (!search) return;
        \\  var cards = Array.prototype.slice.call(document.querySelectorAll("[data-project-template-card]"));
        \\  search.addEventListener("input", function () {
        \\    var query = search.value.trim().toLowerCase();
        \\    cards.forEach(function (card) {
        \\      var text = (card.getAttribute("data-template-text") || "").toLowerCase();
        \\      card.hidden = query.length !== 0 && text.indexOf(query) === -1;
        \\    });
        \\  });
        \\}());
        \\</script>
    );
}

fn projectTemplateById(id: []const u8) *const ProjectTemplate {
    for (project_templates[0..]) |*template| {
        if (std.mem.eql(u8, template.id, id)) return template;
    }
    for (project_templates[0..]) |*template| {
        if (std.mem.eql(u8, template.id, default_project_template_id)) return template;
    }
    return &project_templates[0];
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

fn trimmedQueryValueOwned(allocator: Allocator, target: []const u8, wanted_key: []const u8) !?[]u8 {
    const owned = try queryValueOwned(allocator, target, wanted_key) orelse return null;
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

fn formTrimmedOwned(allocator: Allocator, form_body: []const u8, wanted_key: []const u8) ![]u8 {
    const owned = (try formValueOwned(allocator, form_body, wanted_key)) orelse try allocator.dupe(u8, "");
    defer allocator.free(owned);
    const trimmed = std.mem.trim(u8, owned, " \t\r\n");
    return try allocator.dupe(u8, trimmed);
}

fn projectViewFromValue(value: []const u8) ProjectView {
    if (std.mem.eql(u8, value, "table")) return .table;
    if (std.mem.eql(u8, value, "roadmap")) return .roadmap;
    return .board;
}

fn isProjectViewValue(value: []const u8) bool {
    return std.mem.eql(u8, value, "table") or std.mem.eql(u8, value, "board") or std.mem.eql(u8, value, "roadmap");
}

fn projectViewValue(view: ProjectView) []const u8 {
    return switch (view) {
        .table => "table",
        .board => "board",
        .roadmap => "roadmap",
    };
}

fn projectViewTitle(view: ProjectView) []const u8 {
    return switch (view) {
        .table => "Table",
        .board => "Board",
        .roadmap => "Roadmap",
    };
}

fn projectViewIconClass(view: ProjectView) []const u8 {
    return switch (view) {
        .table => "project-view-table-icon",
        .board => "project-view-board-icon",
        .roadmap => "project-view-roadmap-icon",
    };
}

fn resolveActiveProjectView(allocator: Allocator, db: *SqliteDb, project: []const u8, view_ref: []const u8) !ActiveProjectView {
    if (view_ref.len != 0) {
        if (try loadSavedProjectViewByRef(allocator, db, project, view_ref)) |saved| return saved;
        if (isProjectViewValue(view_ref)) {
            const requested = projectViewFromValue(view_ref);
            if (try loadFirstSavedProjectView(allocator, db, project, requested)) |saved| return saved;
            return activeBuiltinProjectView(allocator, requested);
        }
    } else if (try loadFirstSavedProjectView(allocator, db, project, null)) |saved| {
        return saved;
    }
    return activeBuiltinProjectView(allocator, .board);
}

fn activeBuiltinProjectView(allocator: Allocator, view: ProjectView) !ActiveProjectView {
    const title = try allocator.dupe(u8, projectViewTitle(view));
    errdefer allocator.free(title);
    const ref = try allocator.dupe(u8, projectViewValue(view));
    errdefer allocator.free(ref);
    const config_json = try allocator.dupe(u8, "{}");
    errdefer allocator.free(config_json);
    return .{
        .layout = view,
        .title = title,
        .ref = ref,
        .config_json = config_json,
        .saved = false,
    };
}

fn loadSavedProjectViewByRef(allocator: Allocator, db: *SqliteDb, project: []const u8, view_ref: []const u8) !?ActiveProjectView {
    const prefix = try std.fmt.allocPrint(allocator, "{s}%", .{view_ref});
    defer allocator.free(prefix);
    var stmt = try db.prepare(
        \\SELECT pv.id, pv.name, pv.layout, pv.config_json
        \\FROM project_views pv
        \\JOIN projects p ON p.id = pv.project_id
        \\WHERE p.name = ?
        \\  AND pv.state != 'removed'
        \\  AND (pv.id = ? OR pv.name = ? OR pv.id LIKE ?)
        \\ORDER BY
        \\  CASE
        \\    WHEN pv.id = ? THEN 0
        \\    WHEN pv.name = ? THEN 1
        \\    ELSE 2
        \\  END,
        \\  pv.position, pv.name, pv.id
        \\LIMIT 1
    );
    defer stmt.deinit();
    try stmt.bindText(1, project);
    try stmt.bindText(2, view_ref);
    try stmt.bindText(3, view_ref);
    try stmt.bindText(4, prefix);
    try stmt.bindText(5, view_ref);
    try stmt.bindText(6, view_ref);
    if (!(try stmt.step())) return null;
    return try activeSavedProjectViewFromStmt(allocator, &stmt);
}

fn loadFirstSavedProjectView(allocator: Allocator, db: *SqliteDb, project: []const u8, layout: ?ProjectView) !?ActiveProjectView {
    const layout_value = if (layout) |view| projectViewValue(view) else "";
    var stmt = try db.prepare(
        \\SELECT pv.id, pv.name, pv.layout, pv.config_json
        \\FROM project_views pv
        \\JOIN projects p ON p.id = pv.project_id
        \\WHERE p.name = ?
        \\  AND pv.state != 'removed'
        \\  AND (? = '' OR pv.layout = ?)
        \\ORDER BY pv.position, pv.name, pv.id
        \\LIMIT 1
    );
    defer stmt.deinit();
    try stmt.bindText(1, project);
    try stmt.bindText(2, layout_value);
    try stmt.bindText(3, layout_value);
    if (!(try stmt.step())) return null;
    return try activeSavedProjectViewFromStmt(allocator, &stmt);
}

fn activeSavedProjectViewFromStmt(allocator: Allocator, stmt: *index.SqliteStmt) !ActiveProjectView {
    const view_id = try stmt.columnTextDup(allocator, 0);
    errdefer allocator.free(view_id);
    const name = try stmt.columnTextDup(allocator, 1);
    errdefer allocator.free(name);
    const layout = try stmt.columnTextDup(allocator, 2);
    defer allocator.free(layout);
    const config_json = try stmt.columnTextDup(allocator, 3);
    errdefer allocator.free(config_json);
    return .{
        .layout = projectViewFromValue(layout),
        .title = name,
        .ref = view_id,
        .config_json = config_json,
        .saved = true,
    };
}

fn projectGroupFieldFromConfig(allocator: Allocator, config_json: []const u8) ProjectGroupField {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, config_json, .{}) catch return .status;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return .status,
    };
    const group_by = event_mod.jsonString(root.get("group_by")) orelse return .status;
    if (std.mem.eql(u8, group_by, "issue.priority") or std.mem.eql(u8, group_by, "priority")) return .priority;
    return .status;
}

fn projectRenderContextFromView(allocator: Allocator, active_view: *const ActiveProjectView, current_principal: []const u8) ProjectRenderContext {
    return .{
        .filter = projectIssueFilterFromConfig(allocator, active_view.config_json, current_principal),
        .defaults = projectViewDefaultsFromConfig(allocator, active_view.config_json),
        .view_ref = active_view.ref,
    };
}

fn projectTableFieldsFromConfig(allocator: Allocator, db: *SqliteDb, project: []const u8, config_json: []const u8) !ProjectTableFields {
    var result: ProjectTableFields = .{};
    errdefer result.deinit(allocator);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, config_json, .{}) catch return result;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return result,
    };
    const fields_value = root.get("fields") orelse return result;
    const fields_array = switch (fields_value) {
        .array => |array| array,
        else => return result,
    };
    for (fields_array.items) |field_value| {
        if (result.len == max_project_table_fields) break;
        const field_ref = event_mod.jsonString(field_value) orelse continue;
        const field_key = projectFieldKeyFromViewRef(field_ref) orelse continue;
        if (projectTableFieldsContains(&result, field_key)) continue;
        if (try loadProjectTableField(allocator, db, project, field_key)) |field| {
            result.items[result.len] = field;
            result.len += 1;
        }
    }
    return result;
}

fn projectTableFieldsContains(fields: *const ProjectTableFields, key: []const u8) bool {
    for (fields.items[0..fields.len]) |field| {
        if (std.mem.eql(u8, field.key, key)) return true;
    }
    return false;
}

fn projectFieldKeyFromViewRef(field_ref: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, field_ref, "project.")) {
        const key = field_ref["project.".len..];
        return if (key.len == 0) null else key;
    }
    if (std.mem.startsWith(u8, field_ref, "issue.")) return null;
    if (isBuiltInIssueFieldRef(field_ref)) return null;
    return if (field_ref.len == 0) null else field_ref;
}

fn isBuiltInIssueFieldRef(field_ref: []const u8) bool {
    return std.mem.eql(u8, field_ref, "state") or
        std.mem.eql(u8, field_ref, "status") or
        std.mem.eql(u8, field_ref, "priority") or
        std.mem.eql(u8, field_ref, "type") or
        std.mem.eql(u8, field_ref, "milestone") or
        std.mem.eql(u8, field_ref, "labels") or
        std.mem.eql(u8, field_ref, "assignees") or
        std.mem.eql(u8, field_ref, "projects");
}

fn loadProjectTableField(allocator: Allocator, db: *SqliteDb, project: []const u8, field_key: []const u8) !?ProjectTableField {
    var stmt = try db.prepare(
        \\SELECT pf.key, pf.name, pf.field_type
        \\FROM project_fields pf
        \\JOIN projects p ON p.id = pf.project_id
        \\WHERE p.name = ?
        \\  AND pf.key = ?
        \\  AND pf.state != 'removed'
        \\LIMIT 1
    );
    defer stmt.deinit();
    try stmt.bindText(1, project);
    try stmt.bindText(2, field_key);
    if (!(try stmt.step())) return null;
    const key = try stmt.columnTextDup(allocator, 0);
    errdefer allocator.free(key);
    const name = try stmt.columnTextDup(allocator, 1);
    errdefer allocator.free(name);
    const field_type = try stmt.columnTextDup(allocator, 2);
    errdefer allocator.free(field_type);
    return .{
        .key = key,
        .name = name,
        .field_type = field_type,
    };
}

fn projectViewDefaultsFromConfig(allocator: Allocator, config_json: []const u8) ProjectViewDefaults {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, config_json, .{}) catch return .{};
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return .{},
    };
    const defaults_value = root.get("defaults") orelse return .{};
    const defaults_object = switch (defaults_value) {
        .object => |object| object,
        else => return .{},
    };

    var defaults: ProjectViewDefaults = .{};
    if (event_mod.jsonString(defaults_object.get("issue.status")) orelse event_mod.jsonString(defaults_object.get("status"))) |status| {
        if (canonicalProjectStatus(status)) |canonical| {
            defaults.status = canonical;
            defaults.status_explicit = true;
        }
    }
    if (event_mod.jsonString(defaults_object.get("issue.priority")) orelse event_mod.jsonString(defaults_object.get("priority"))) |priority| {
        if (canonicalProjectPriority(priority)) |canonical| {
            defaults.priority = canonical;
            defaults.priority_explicit = true;
        }
    }
    return defaults;
}

fn projectIssueFilterFromConfig(allocator: Allocator, config_json: []const u8, current_principal: []const u8) ProjectIssueFilter {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, config_json, .{}) catch return .{};
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return .{},
    };
    const filter_value = root.get("filter") orelse return .{};
    var filter: ProjectIssueFilter = .{};
    applyProjectIssueFilterValue(&filter, filter_value, current_principal);
    return filter;
}

fn applyProjectIssueFilterValue(filter: *ProjectIssueFilter, value: std.json.Value, current_principal: []const u8) void {
    switch (value) {
        .object => |object| {
            if (event_mod.jsonString(object.get("assignee"))) |assignee| {
                if (std.mem.eql(u8, assignee, "@me")) {
                    filter.require_assignee = true;
                    filter.assignee = current_principal;
                }
            }
            if (event_mod.jsonString(object.get("label"))) |label| {
                if (asciiEqlIgnoreCase(label, "bug")) filter.bug_label = true;
            }
            if (event_mod.jsonString(object.get("issue.type"))) |issue_type| {
                if (asciiEqlIgnoreCase(issue_type, "bug")) filter.bug_label = true;
            }
            if (event_mod.jsonString(object.get("project.iteration"))) |iteration| {
                if (asciiEqlIgnoreCase(iteration, "current")) filter.current_iteration = true;
            }
            if (object.get("any")) |any_value| {
                switch (any_value) {
                    .array => |items| for (items.items) |item| applyProjectIssueFilterValue(filter, item, current_principal),
                    else => {},
                }
            }
        },
        else => {},
    }
}

fn bindProjectIssueFilter(stmt: *index.SqliteStmt, start_index: c_int, project: []const u8, filter: ProjectIssueFilter) !void {
    var idx = start_index;
    try stmt.bindInt(idx, if (filter.require_assignee) 1 else 0);
    idx += 1;
    try stmt.bindText(idx, filter.assignee);
    idx += 1;
    try stmt.bindInt(idx, if (filter.bug_label) 1 else 0);
    idx += 1;
    try stmt.bindInt(idx, if (filter.current_iteration) 1 else 0);
    idx += 1;
    try stmt.bindText(idx, project);
}

fn canonicalProjectStatus(value: []const u8) ?[]const u8 {
    for (project_status_values) |status| {
        if (std.mem.eql(u8, value, status)) return status;
    }
    return null;
}

fn canonicalProjectPriority(value: []const u8) ?[]const u8 {
    for (project_priority_values) |priority| {
        if (std.mem.eql(u8, value, priority)) return priority;
    }
    return null;
}

fn projectWorkspaceLocationOwned(allocator: Allocator, project: []const u8, view_ref: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "/projects?project=");
    try shared.appendUrlEncoded(&buf, allocator, project);
    try buf.appendSlice(allocator, "&view=");
    try shared.appendUrlEncoded(&buf, allocator, if (view_ref.len == 0) "board" else view_ref);
    return try buf.toOwnedSlice(allocator);
}

fn sendProjectItemError(
    allocator: Allocator,
    stream: std.net.Stream,
    wants_async: bool,
    status: u16,
    reason: []const u8,
    message: []const u8,
) !void {
    _ = wants_async;
    try sendPlainResponse(allocator, stream, status, reason, message);
}

fn replaceIssueProjectPlacement(
    allocator: Allocator,
    repo: Repo,
    issue_id: []const u8,
    project: []const u8,
    column: []const u8,
) !void {
    var existing = try loadIssueProjectColumns(allocator, repo, issue_id, project, null);
    defer freeColumnList(allocator, &existing);

    var has_target = false;
    for (existing.items) |old_column| {
        if (std.mem.eql(u8, old_column, column)) {
            has_target = true;
            continue;
        }
        try createIssueProjectEvent(allocator, issue_id, project, old_column, null, null, false);
    }
    if (!has_target) {
        try createIssueProjectEvent(allocator, issue_id, project, column, null, null, true);
    }
}

fn updateIssueProjectMetadata(
    allocator: Allocator,
    repo: Repo,
    issue_id: []const u8,
    project: []const u8,
    status: []const u8,
    priority: []const u8,
) !void {
    var existing = try loadIssueProjectColumns(allocator, repo, issue_id, project, null);
    defer freeColumnList(allocator, &existing);

    if (existing.items.len == 0) {
        try createIssueProjectEvent(allocator, issue_id, project, status, null, null, true);
    }
    try createIssueStringEvent(allocator, issue_id, "issue.status_set", "status", status);
    if (priority.len != 0) {
        try createIssueStringEvent(allocator, issue_id, "issue.priority_set", "priority", priority);
    }
}

fn removeIssueProjectPlacements(
    allocator: Allocator,
    repo: Repo,
    issue_id: []const u8,
    project: []const u8,
    column_filter: ?[]const u8,
) !void {
    var existing = try loadIssueProjectColumns(allocator, repo, issue_id, project, column_filter);
    defer freeColumnList(allocator, &existing);
    for (existing.items) |old_column| {
        try createIssueProjectEvent(allocator, issue_id, project, old_column, null, null, false);
    }
}

fn loadIssueProjectColumns(
    allocator: Allocator,
    repo: Repo,
    issue_id: []const u8,
    project: []const u8,
    column_filter: ?[]const u8,
) !std.ArrayList([]u8) {
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    const sql_text: []const u8 = if (column_filter == null)
        \\SELECT DISTINCT column_name
        \\FROM issue_projects
        \\WHERE issue_id = ? AND project = ?
        \\ORDER BY column_name
    else
        \\SELECT DISTINCT column_name
        \\FROM issue_projects
        \\WHERE issue_id = ? AND project = ? AND column_name = ?
        \\ORDER BY column_name
    ;
    var stmt = try db.prepare(sql_text);
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    try stmt.bindText(2, project);
    if (column_filter) |column| try stmt.bindText(3, column);

    var columns: std.ArrayList([]u8) = .empty;
    errdefer freeColumnList(allocator, &columns);
    while (try stmt.step()) {
        try columns.append(allocator, try stmt.columnTextDup(allocator, 0));
    }
    return columns;
}

fn freeColumnList(allocator: Allocator, columns: *std.ArrayList([]u8)) void {
    for (columns.items) |column| allocator.free(column);
    columns.deinit(allocator);
}

fn projectExists(db: *SqliteDb, project: []const u8) !bool {
    var stmt = try db.prepare(
        \\SELECT 1 FROM projects WHERE name = ?
        \\UNION
        \\SELECT 1 FROM issue_projects WHERE project = ?
        \\LIMIT 1
    );
    defer stmt.deinit();
    try stmt.bindText(1, project);
    try stmt.bindText(2, project);
    return try stmt.step();
}

fn appendProjectIssueAssignees(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, issue_id: []const u8) !void {
    var stmt = try db.prepare("SELECT DISTINCT assignee FROM issue_assignees WHERE issue_id = ? ORDER BY assignee LIMIT 4");
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    var shown = false;
    while (try stmt.step()) {
        const assignee = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(assignee);
        try appendIssueAvatar(buf, allocator, assignee, "project-table-avatar");
        shown = true;
    }
    if (!shown) try buf.appendSlice(allocator, "<span class=\"muted\">Unassigned</span>");
}

fn appendKanbanCardLabels(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, issue_id: []const u8) !void {
    var stmt = try db.prepare("SELECT DISTINCT label FROM issue_labels WHERE issue_id = ? ORDER BY label LIMIT 4");
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    var shown = false;
    while (try stmt.step()) {
        const label = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(label);
        if (!shown) {
            try buf.appendSlice(allocator, "<div class=\"kanban-card-labels\">");
            shown = true;
        }
        try appendIssueLabel(buf, allocator, label);
    }
    if (shown) try buf.appendSlice(allocator, "</div>");
}

fn appendIssueLabel(buf: *std.ArrayList(u8), allocator: Allocator, label: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<span class="issue-label {kind}">{label}</span>
    , .{
        .kind = issueLabelKind(label),
        .label = label,
    });
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

fn issueLabelKind(label: []const u8) []const u8 {
    if (asciiEqlIgnoreCase(label, "bug")) return "label-bug";
    if (asciiEqlIgnoreCase(label, "enhancement") or asciiEqlIgnoreCase(label, "feature") or asciiEqlIgnoreCase(label, "feat")) return "label-enhancement";
    if (asciiEqlIgnoreCase(label, "docs") or asciiEqlIgnoreCase(label, "documentation")) return "label-docs";
    if (asciiEqlIgnoreCase(label, "question")) return "label-question";
    if (asciiEqlIgnoreCase(label, "security")) return "label-security";
    return "label-default";
}

fn columnTone(column: []const u8) []const u8 {
    if (column.len == 0) return "neutral";
    if (asciiEqlIgnoreCase(column, "Draft")) return "draft";
    if (asciiEqlIgnoreCase(column, "Todo")) return "todo";
    if (asciiEqlIgnoreCase(column, "WIP")) return "progress";
    if (asciiEqlIgnoreCase(column, "Failed")) return "failed";
    if (asciiContainsIgnoreCase(column, "done") or asciiContainsIgnoreCase(column, "complete") or asciiContainsIgnoreCase(column, "closed")) return "done";
    if (asciiContainsIgnoreCase(column, "progress") or asciiContainsIgnoreCase(column, "doing")) return "progress";
    if (asciiContainsIgnoreCase(column, "review")) return "review";
    if (asciiContainsIgnoreCase(column, "triage") or asciiContainsIgnoreCase(column, "backlog")) return "backlog";
    if (asciiContainsIgnoreCase(column, "todo") or asciiContainsIgnoreCase(column, "to do") or asciiContainsIgnoreCase(column, "ready") or asciiContainsIgnoreCase(column, "now") or asciiContainsIgnoreCase(column, "next")) return "todo";
    return "neutral";
}

fn columnDescription(column: []const u8) []const u8 {
    if (column.len == 0) return "Issues without a project column";
    if (asciiEqlIgnoreCase(column, "Draft")) return "Scoped but not ready";
    if (asciiEqlIgnoreCase(column, "Todo")) return "Not started yet";
    if (asciiEqlIgnoreCase(column, "WIP")) return "Actively being worked on";
    if (asciiEqlIgnoreCase(column, "Review")) return "Waiting for review";
    if (asciiEqlIgnoreCase(column, "Failed")) return "Needs recovery before moving on";
    if (asciiContainsIgnoreCase(column, "done") or asciiContainsIgnoreCase(column, "complete") or asciiContainsIgnoreCase(column, "closed")) return "This has been completed";
    if (asciiContainsIgnoreCase(column, "progress") or asciiContainsIgnoreCase(column, "doing")) return "This is actively being worked on";
    if (asciiContainsIgnoreCase(column, "review")) return "Waiting for review";
    if (asciiContainsIgnoreCase(column, "triage")) return "Needs review before planning";
    if (asciiContainsIgnoreCase(column, "backlog")) return "Ready to be picked up";
    if (asciiContainsIgnoreCase(column, "ready")) return "Ready to start";
    if (asciiContainsIgnoreCase(column, "todo") or asciiContainsIgnoreCase(column, "to do")) return "This item has not been started";
    if (asciiContainsIgnoreCase(column, "now")) return "Current planning horizon";
    if (asciiContainsIgnoreCase(column, "next")) return "Planned next";
    if (asciiContainsIgnoreCase(column, "later")) return "Parked for later";
    return "Issues in this stage";
}

fn priorityTone(priority: []const u8) []const u8 {
    if (std.mem.eql(u8, priority, "P0")) return "p0";
    if (std.mem.eql(u8, priority, "P1")) return "p1";
    if (std.mem.eql(u8, priority, "P2")) return "p2";
    if (std.mem.eql(u8, priority, "P3")) return "p3";
    return "none";
}

fn isProjectPriorityValue(value: []const u8) bool {
    for (project_priority_values) |priority| {
        if (std.mem.eql(u8, value, priority)) return true;
    }
    return false;
}

fn isProjectStatusValue(value: []const u8) bool {
    for (project_status_values) |status| {
        if (std.mem.eql(u8, value, status)) return true;
    }
    return false;
}

fn effectiveStatusLabel(status: []const u8, fallback: []const u8) []const u8 {
    return if (status.len != 0) status else fallback;
}

fn asciiContainsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (asciiEqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (std.ascii.toLower(left) != std.ascii.toLower(right)) return false;
    }
    return true;
}

test "project workspace title does not prepend at sign" {
    var db = try SqliteDb.openWithOptions(
        std.testing.allocator,
        ":memory:",
        sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_CREATE,
        true,
        .{ .enable_wal = false },
    );
    defer db.deinit();
    try db.exec("CREATE TABLE projects (id TEXT, name TEXT, description TEXT, state TEXT, created_at TEXT)");
    try db.exec("CREATE TABLE issues (id TEXT, title TEXT, state TEXT, opened_at TEXT)");
    try db.exec("CREATE TABLE issue_metadata (issue_id TEXT, priority TEXT, status TEXT)");
    try db.exec("CREATE TABLE legacy_aliases (provider TEXT, object_kind TEXT, object_id TEXT, number INTEGER)");
    try db.exec("CREATE TABLE project_columns (project_id TEXT, column_name TEXT)");
    try db.exec("CREATE TABLE issue_projects (project TEXT, column_name TEXT, issue_id TEXT)");
    try db.exec("CREATE TABLE project_views (id TEXT, project_id TEXT, name TEXT, layout TEXT, position INTEGER, config_json TEXT, state TEXT)");
    try db.exec("INSERT INTO projects (id, name, description, state, created_at) VALUES ('p1', 'Release & Plan', '', 'open', '2026-05-16T00:00:00Z')");

    var active_view = try activeBuiltinProjectView(std.testing.allocator, .board);
    defer active_view.deinit(std.testing.allocator);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendProjectWorkspaceChromeStart(&buf, std.testing.allocator, &db, "Release & Plan", 0, &active_view);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<h1>Release &amp; Plan</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<h1>@Release") == null);
}

test "project view config parses saved filters" {
    const my_items = projectIssueFilterFromConfig(std.testing.allocator, my_items_view_config, "alice");
    try std.testing.expect(my_items.require_assignee);
    try std.testing.expectEqualStrings("alice", my_items.assignee);
    try std.testing.expect(!my_items.bug_label);
    try std.testing.expect(!my_items.current_iteration);

    const bugs = projectIssueFilterFromConfig(std.testing.allocator, bugs_view_config, "alice");
    try std.testing.expect(!bugs.require_assignee);
    try std.testing.expect(bugs.bug_label);
    try std.testing.expect(!bugs.current_iteration);

    const current_iteration = projectIssueFilterFromConfig(std.testing.allocator, current_iteration_view_config, "alice");
    try std.testing.expect(!current_iteration.require_assignee);
    try std.testing.expect(!current_iteration.bug_label);
    try std.testing.expect(current_iteration.current_iteration);
}

test "project view config parses creation defaults" {
    const kanban_defaults = projectViewDefaultsFromConfig(std.testing.allocator, kanban_board_view_config);
    try std.testing.expect(kanban_defaults.status_explicit);
    try std.testing.expectEqualStrings("Draft", kanban_defaults.status);
    try std.testing.expect(kanban_defaults.priority_explicit);
    try std.testing.expectEqualStrings("P3", kanban_defaults.priority);

    const no_defaults = projectViewDefaultsFromConfig(std.testing.allocator, my_items_view_config);
    try std.testing.expect(!no_defaults.status_explicit);
    try std.testing.expectEqualStrings(default_project_status, no_defaults.status);
    try std.testing.expect(!no_defaults.priority_explicit);
    try std.testing.expectEqualStrings(default_project_priority, no_defaults.priority);
}

test "project view config loads project table fields" {
    var db = try SqliteDb.openWithOptions(
        std.testing.allocator,
        ":memory:",
        sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_CREATE,
        true,
        .{ .enable_wal = false },
    );
    defer db.deinit();
    try db.exec("CREATE TABLE projects (id TEXT, name TEXT)");
    try db.exec("CREATE TABLE project_fields (id TEXT, project_id TEXT, key TEXT, name TEXT, field_type TEXT, state TEXT)");
    try db.exec("INSERT INTO projects (id, name) VALUES ('p1', 'Plan')");
    try db.exec("INSERT INTO project_fields (id, project_id, key, name, field_type, state) VALUES ('f1', 'p1', 'iteration', 'Iteration', 'text', 'active')");
    try db.exec("INSERT INTO project_fields (id, project_id, key, name, field_type, state) VALUES ('f2', 'p1', 'estimate', 'Estimate', 'number', 'active')");
    try db.exec("INSERT INTO project_fields (id, project_id, key, name, field_type, state) VALUES ('f3', 'p1', 'track', 'Track', 'text', 'removed')");

    var fields = try projectTableFieldsFromConfig(std.testing.allocator, &db, "Plan", current_iteration_view_config);
    defer fields.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqualStrings("iteration", fields.items[0].key);
    try std.testing.expectEqualStrings("Iteration", fields.items[0].name);
    try std.testing.expectEqualStrings("text", fields.items[0].field_type);
    try std.testing.expectEqualStrings("estimate", fields.items[1].key);
    try std.testing.expectEqualStrings("number", fields.items[1].field_type);
}

test "project field value json validates typed values" {
    const number_json = try projectFieldValueJson(std.testing.allocator, "number", "3.5");
    defer std.testing.allocator.free(number_json);
    try std.testing.expectEqualStrings("3.5", number_json);
    try std.testing.expectError(error.InvalidProjectFieldValue, projectFieldValueJson(std.testing.allocator, "number", "soon"));

    const bool_json = try projectFieldValueJson(std.testing.allocator, "boolean", "true");
    defer std.testing.allocator.free(bool_json);
    try std.testing.expectEqualStrings("true", bool_json);
    try std.testing.expectError(error.InvalidProjectFieldValue, projectFieldValueJson(std.testing.allocator, "boolean", "yes"));

    const date_json = try projectFieldValueJson(std.testing.allocator, "date", "2026-05-16");
    defer std.testing.allocator.free(date_json);
    try std.testing.expectEqualStrings("\"2026-05-16\"", date_json);
    try std.testing.expectError(error.InvalidProjectFieldValue, projectFieldValueJson(std.testing.allocator, "date", "2026/05/16"));
}

test "project index and not found names do not prepend at sign" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendProjectIndexCard(&buf, std.testing.allocator, "Release & Plan", "", "open", 0, 0, "");
    try appendProjectNotFound(&buf, std.testing.allocator, "Release & Plan");

    try std.testing.expect(std.mem.indexOf(u8, buf.items, ">Release &amp; Plan</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<strong>Release &amp; Plan</strong>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "@Release") == null);
}
