const std = @import("std");
const index = @import("../index.zig");
const project_mod = @import("../project.zig");
const repo_mod = @import("../repo.zig");
const shared = @import("shared.zig");
const util = @import("../util.zig");
const issues_page = @import("issues.zig");

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
const createProjectCreatedEvent = project_mod.createProjectCreatedEvent;
const formValueOwned = issues_page.formValueOwned;
const issueHref = shared.issueHref;
const literalHref = shared.literalHref;
const sendRedirect = shared.sendRedirect;
const sendResponse = shared.sendResponse;
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

const default_project_template_id = "kanban";

const project_templates = [_]ProjectTemplate{
    .{
        .id = "team-planning",
        .title = "Team planning",
        .source = "Gitomi",
        .description = "Manage team work items, upcoming cycles, and capacity.",
        .columns = "Backlog, Todo, In Progress, In Review, Done",
        .group = .featured,
        .preview = "table",
    },
    .{
        .id = "kanban",
        .title = "Kanban",
        .source = "Gitomi",
        .description = "Visualize project status and limit work in progress.",
        .columns = "Todo, In Progress, Done",
        .group = .featured,
        .preview = "board",
    },
    .{
        .id = "feature-release",
        .title = "Feature release",
        .source = "Gitomi",
        .description = "Prioritize, review, and ship a focused release.",
        .columns = "Todo, In Progress, In Review, Done",
        .group = .featured,
        .preview = "table",
    },
    .{
        .id = "bug-tracker",
        .title = "Bug tracker",
        .source = "Gitomi",
        .description = "Track, triage, and resolve reported bugs.",
        .columns = "Triage, Backlog, Ready, In Progress, Done",
        .group = .featured,
        .preview = "board",
    },
    .{
        .id = "table",
        .title = "Table",
        .source = "Start from scratch",
        .description = "Start from a compact list of work items.",
        .columns = "Todo",
        .group = .scratch,
        .preview = "table",
    },
    .{
        .id = "board",
        .title = "Board",
        .source = "Start from scratch",
        .description = "Start with a lightweight Kanban workflow.",
        .columns = "Todo, In Progress, Done",
        .group = .scratch,
        .preview = "board",
    },
    .{
        .id = "roadmap",
        .title = "Roadmap",
        .source = "Start from scratch",
        .description = "Organize work by planning horizon.",
        .columns = "Now, Next, Later, Done",
        .group = .scratch,
        .preview = "roadmap",
    },
};

pub fn renderProjectsPage(allocator: Allocator, repo: Repo, target: []const u8) ![]u8 {
    if (try shared.renderIndexingPageIfStale(allocator, repo, "Projects", "projects", target)) |body| return body;
    try index.ensureIndex(allocator, repo);

    const project_query = try trimmedQueryValueOwned(allocator, target, "project");
    defer if (project_query) |value| allocator.free(value);
    const view = try projectViewFromTarget(allocator, target);

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    if (project_query) |project| {
        return renderProjectWorkspace(allocator, repo, &db, project, view);
    }

    return renderProjectIndex(allocator, repo, &db);
}

fn renderProjectIndex(allocator: Allocator, repo: Repo, db: *SqliteDb) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "Projects", "projects");
    try buf.appendSlice(allocator, "<section class=\"panel project-index-panel\">");
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

    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn renderProjectWorkspace(
    allocator: Allocator,
    repo: Repo,
    db: *SqliteDb,
    project: []const u8,
    view: ProjectView,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, project, "projects");
    if (!(try projectExists(db, project))) {
        try appendProjectNotFound(&buf, allocator, project);
        try appendShellEnd(&buf, allocator);
        return buf.toOwnedSlice(allocator);
    }

    switch (view) {
        .table => try appendProjectTable(&buf, allocator, db, project),
        .board => try appendProjectBoard(&buf, allocator, db, project),
        .roadmap => try appendProjectRoadmap(&buf, allocator, db, project),
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
        \\">@{project}</a></h2>
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

fn appendProjectBoard(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, project: []const u8) !void {
    const issue_count = try projectIssueCount(db, project);
    try appendProjectWorkspaceChromeStart(buf, allocator, db, project, issue_count, .board, "Board");
    try buf.appendSlice(allocator,
        \\  <div class="kanban-board">
    );
    try appendProjectColumns(buf, allocator, db, project, appendProjectColumn);
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
    active_view: ProjectView,
    title_label: []const u8,
) !void {
    try appendTemplate(buf, allocator,
        \\<section class="panel kanban-panel project-board-panel">
        \\  <div class="project-board-top">
        \\    <div class="project-title-line">
        \\      <span class="project-lock-icon" aria-hidden="true"></span>
        \\      <div>
        \\        <p class="eyebrow">Project {title_label}</p>
        \\        <h1>@{project}</h1>
        \\      </div>
        \\    </div>
    , .{
        .title_label = title_label,
        .project = project,
    });
    try buf.appendSlice(allocator, "<a class=\"button secondary project-issues-link\" href=\"/issues?project=");
    try shared.appendUrlEncoded(buf, allocator, project);
    try buf.appendSlice(allocator, "\">Open issues</a></div>");
    try appendProjectViewTabs(buf, allocator, project, active_view, issue_count);
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

fn appendProjectColumns(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    project: []const u8,
    comptime appendColumnFn: fn (*std.ArrayList(u8), Allocator, *SqliteDb, []const u8, []const u8) anyerror!void,
) !void {
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
    var shown_column = false;
    while (try columns.step()) {
        const column = try columns.columnTextDup(allocator, 0);
        defer allocator.free(column);
        try appendColumnFn(buf, allocator, db, project, column);
        shown_column = true;
    }
    if (!shown_column) try appendColumnFn(buf, allocator, db, project, "");
}

fn appendProjectTable(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, project: []const u8) !void {
    const issue_count = try projectIssueCount(db, project);
    try appendProjectWorkspaceChromeStart(buf, allocator, db, project, issue_count, .table, "Table");
    try buf.appendSlice(allocator,
        \\  <div class="project-table-view">
        \\    <table class="project-data-table">
        \\      <thead>
        \\        <tr><th>Title</th><th>Project status</th><th>Issue state</th><th>Assignees</th><th>Labels</th><th>Milestone</th><th>Comments</th><th>Opened</th></tr>
        \\      </thead>
        \\      <tbody>
    );
    try appendProjectColumns(buf, allocator, db, project, appendProjectTableGroup);
    try buf.appendSlice(allocator,
        \\      </tbody>
        \\    </table>
        \\  </div>
        \\</section>
    );
}

fn appendProjectRoadmap(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, project: []const u8) !void {
    const issue_count = try projectIssueCount(db, project);
    try appendProjectWorkspaceChromeStart(buf, allocator, db, project, issue_count, .roadmap, "Roadmap");
    try buf.appendSlice(allocator,
        \\  <div class="project-roadmap-view">
        \\    <div class="project-roadmap-scale" aria-hidden="true"><span>Unscheduled</span><span>Now</span><span>Next</span><span>Later</span></div>
    );
    try appendProjectColumns(buf, allocator, db, project, appendProjectRoadmapLane);
    try buf.appendSlice(allocator,
        \\  </div>
        \\</section>
    );
}

fn appendProjectTableGroup(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, project: []const u8, column: []const u8) !void {
    const count = try projectColumnIssueCount(db, project, column);
    const title = if (column.len == 0) "No status" else column;
    try appendTemplate(buf, allocator,
        \\<tr class="project-table-group-row"><th colspan="8"><span class="kanban-status-dot" aria-hidden="true"></span>{title}<span>{count}</span></th></tr>
    , .{
        .title = title,
        .count = count,
    });

    var rows = try db.prepare(
        \\SELECT DISTINCT i.id, i.title, i.state,
        \\       COALESCE(NULLIF(m.source_author, ''), i.author_principal),
        \\       i.opened_at,
        \\       COALESCE(m.milestone, ''),
        \\       COALESCE(a.number, 0),
        \\       (SELECT COUNT(*) FROM comments c WHERE c.parent_kind = 'issue' AND c.parent_id = i.id)
        \\FROM issue_projects p
        \\JOIN issues i ON i.id = p.issue_id
        \\LEFT JOIN issue_metadata m ON m.issue_id = i.id
        \\LEFT JOIN legacy_aliases a
        \\  ON a.provider = 'github' AND a.object_kind = 'issue' AND a.object_id = i.id
        \\WHERE p.project = ? AND p.column_name = ?
        \\ORDER BY i.opened_at DESC, i.id DESC
    );
    defer rows.deinit();
    try rows.bindText(1, project);
    try rows.bindText(2, column);

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
        const legacy_number = rows.columnInt64(6);
        const comment_count = @as(usize, @intCast(rows.columnInt64(7)));
        try appendProjectTableIssueRow(buf, allocator, db, id, title_text, state, author, opened_at, milestone, legacy_number, comment_count, column);
        shown = true;
    }
    if (!shown) {
        try appendTemplate(buf, allocator,
            \\<tr class="project-table-empty-row"><td colspan="8">No issues</td></tr>
        , .{});
    }
}

fn appendProjectTableIssueRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    id: []const u8,
    title: []const u8,
    state: []const u8,
    author: []const u8,
    opened_at: []const u8,
    milestone: []const u8,
    legacy_number: i64,
    comment_count: usize,
    column: []const u8,
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
        \\  <td><span class="project-status-chip tone-{tone}">{status}</span></td>
        \\  <td>{state}</td>
        \\  <td>
    , .{
        .tone = columnTone(column),
        .status = if (column.len == 0) "No status" else column,
        .state = state,
    });
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

fn appendProjectRoadmapLane(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, project: []const u8, column: []const u8) !void {
    const count = try projectColumnIssueCount(db, project, column);
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
        \\SELECT DISTINCT i.id, i.title, i.state,
        \\       COALESCE(NULLIF(m.source_author, ''), i.author_principal),
        \\       i.opened_at,
        \\       COALESCE(a.number, 0)
        \\FROM issue_projects p
        \\JOIN issues i ON i.id = p.issue_id
        \\LEFT JOIN issue_metadata m ON m.issue_id = i.id
        \\LEFT JOIN legacy_aliases a
        \\  ON a.provider = 'github' AND a.object_kind = 'issue' AND a.object_id = i.id
        \\WHERE p.project = ? AND p.column_name = ?
        \\ORDER BY i.opened_at DESC, i.id DESC
    );
    defer rows.deinit();
    try rows.bindText(1, project);
    try rows.bindText(2, column);

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
        try appendProjectRoadmapItem(buf, allocator, id, title_text, state, author, opened_at, legacy_number);
        shown = true;
    }
    if (!shown) try buf.appendSlice(allocator, "<div class=\"kanban-empty-drop\">No issues</div>");
    try buf.appendSlice(allocator, "</div></section>");
}

fn appendProjectRoadmapItem(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    id: []const u8,
    title: []const u8,
    state: []const u8,
    author: []const u8,
    opened_at: []const u8,
    legacy_number: i64,
) !void {
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
    try buf.appendSlice(allocator, "</small></div></article>");
}

fn appendProjectViewTabs(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    project: []const u8,
    active_view: ProjectView,
    issue_count: usize,
) !void {
    try buf.appendSlice(allocator, "<div class=\"project-view-tabs\" aria-label=\"Project views\">");
    try appendProjectViewTab(buf, allocator, project, active_view, .table, "Table", "project-view-table-icon");
    try appendProjectViewTab(buf, allocator, project, active_view, .board, "Board", "project-view-board-icon");
    try appendProjectViewTab(buf, allocator, project, active_view, .roadmap, "Roadmap", "project-view-roadmap-icon");
    try buf.appendSlice(allocator, "<a class=\"project-view-tab\" href=\"/issues?project=");
    try shared.appendUrlEncoded(buf, allocator, project);
    try appendTemplate(buf, allocator,
        \\">Issues <span class="issue-count-badge">{issue_count}</span></a></div>
    , .{ .issue_count = issue_count });
}

fn appendProjectViewTab(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    project: []const u8,
    active_view: ProjectView,
    view: ProjectView,
    label: []const u8,
    icon_class: []const u8,
) !void {
    if (active_view == view) {
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
    try buf.appendSlice(allocator, "/projects?project=");
    try shared.appendUrlEncoded(buf, allocator, project);
    try buf.appendSlice(allocator, "&amp;view=");
    try buf.appendSlice(allocator, projectViewValue(view));
}

fn appendProjectNotFound(buf: *std.ArrayList(u8), allocator: Allocator, project: []const u8) !void {
    try buf.appendSlice(allocator, "<section class=\"panel\">");
    try appendSectionHead(buf, allocator, "Projects", "Project not found", Button{
        .label = "New project",
        .href = literalHref("/new-project"),
        .kind = "primary",
    });
    try appendTemplate(buf, allocator,
        \\<div class="empty"><strong>@{project}</strong><p>No project or project issue placements match this name.</p></div>
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

fn appendProjectColumn(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, project: []const u8, column: []const u8) !void {
    const count = try projectColumnIssueCount(db, project, column);
    const title = if (column.len == 0) "No column" else column;
    const tone = columnTone(column);
    const note = columnDescription(column);
    try appendTemplate(buf, allocator,
        \\<section class="kanban-column tone-{tone}">
        \\  <header>
        \\    <div class="kanban-column-title">
        \\      <span class="kanban-status-dot" aria-hidden="true"></span>
        \\      <h2>{title}</h2>
        \\      <span class="kanban-count">{count}</span>
        \\    </div>
        \\    <div class="kanban-column-actions" aria-hidden="true"><span class="kanban-column-menu"></span><span class="kanban-column-add"></span></div>
        \\  </header>
        \\  <p class="kanban-column-note">{note}</p>
        \\  <div class="kanban-cards">
    , .{
        .tone = tone,
        .title = title,
        .count = count,
        .note = note,
    });

    var cards = try db.prepare(
        \\SELECT DISTINCT i.id, i.title, i.state,
        \\       COALESCE(NULLIF(m.source_author, ''), i.author_principal),
        \\       i.opened_at,
        \\       COALESCE(a.number, 0),
        \\       (SELECT COUNT(*) FROM comments c WHERE c.parent_kind = 'issue' AND c.parent_id = i.id)
        \\FROM issue_projects p
        \\JOIN issues i ON i.id = p.issue_id
        \\LEFT JOIN issue_metadata m ON m.issue_id = i.id
        \\LEFT JOIN legacy_aliases a
        \\  ON a.provider = 'github' AND a.object_kind = 'issue' AND a.object_id = i.id
        \\WHERE p.project = ? AND p.column_name = ?
        \\ORDER BY i.opened_at DESC, i.id DESC
    );
    defer cards.deinit();
    try cards.bindText(1, project);
    try cards.bindText(2, column);
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
        const legacy_number = cards.columnInt64(5);
        const comment_count = @as(usize, @intCast(cards.columnInt64(6)));

        var issue_ref_buf: [util.short_object_ref_len]u8 = undefined;
        const issue_ref = util.shortObjectRef(&issue_ref_buf, id);
        try appendTemplate(buf, allocator,
            \\<article class="kanban-card is-{state}">
            \\  <div class="kanban-card-head">
            \\    <span class="issue-state-icon {state}" title="{state}" aria-label="{state}"></span>
            \\    <span class="kanban-card-ref">
        , .{
            .state = state,
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

fn projectIssueCount(db: *SqliteDb, project: []const u8) !usize {
    var stmt = try db.prepare("SELECT COUNT(DISTINCT issue_id) FROM issue_projects WHERE project = ?");
    defer stmt.deinit();
    try stmt.bindText(1, project);
    if (!(try stmt.step())) return 0;
    return @intCast(stmt.columnInt64(0));
}

fn projectColumnIssueCount(db: *SqliteDb, project: []const u8, column: []const u8) !usize {
    var stmt = try db.prepare(
        \\SELECT COUNT(DISTINCT issue_id)
        \\FROM issue_projects
        \\WHERE project = ? AND column_name = ?
    );
    defer stmt.deinit();
    try stmt.bindText(1, project);
    try stmt.bindText(2, column);
    if (!(try stmt.step())) return 0;
    return @intCast(stmt.columnInt64(0));
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

    var columns = try splitCommaFields(allocator, columns_owned);
    defer columns.deinit(allocator);

    createProjectCreatedEvent(allocator, name, description_owned, columns.items) catch {
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

    try sendRedirect(allocator, stream, "/projects");
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
        \\    <label>Columns<input name="columns" value="{columns_value}" placeholder="Todo, In Progress, Done"></label>
        \\    <div class="project-column-chips" aria-label="Template columns">
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
    if (!shown) try buf.appendSlice(allocator, "<span>Todo</span><span>In Progress</span><span>Done</span>");
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

fn projectViewFromTarget(allocator: Allocator, target: []const u8) !ProjectView {
    const view = try trimmedQueryValueOwned(allocator, target, "view");
    defer if (view) |value| allocator.free(value);
    const value = view orelse return .board;
    if (std.mem.eql(u8, value, "table")) return .table;
    if (std.mem.eql(u8, value, "roadmap")) return .roadmap;
    return .board;
}

fn projectViewValue(view: ProjectView) []const u8 {
    return switch (view) {
        .table => "table",
        .board => "board",
        .roadmap => "roadmap",
    };
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
    if (asciiContainsIgnoreCase(column, "done") or asciiContainsIgnoreCase(column, "complete") or asciiContainsIgnoreCase(column, "closed")) return "done";
    if (asciiContainsIgnoreCase(column, "progress") or asciiContainsIgnoreCase(column, "doing")) return "progress";
    if (asciiContainsIgnoreCase(column, "review")) return "review";
    if (asciiContainsIgnoreCase(column, "triage") or asciiContainsIgnoreCase(column, "backlog")) return "backlog";
    if (asciiContainsIgnoreCase(column, "todo") or asciiContainsIgnoreCase(column, "to do") or asciiContainsIgnoreCase(column, "ready") or asciiContainsIgnoreCase(column, "now") or asciiContainsIgnoreCase(column, "next")) return "todo";
    return "neutral";
}

fn columnDescription(column: []const u8) []const u8 {
    if (column.len == 0) return "Issues without a project column";
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
