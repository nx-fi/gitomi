const std = @import("std");
const index = @import("../../index.zig");
const repo_mod = @import("../../repo.zig");
const util = @import("../../util.zig");
const project_chrome = @import("chrome.zig");
const project_data = @import("data.zig");
const project_groups = @import("groups.zig");
const project_issue_render = @import("issue_render.zig");
const project_table = @import("table.zig");
const project_views = @import("views.zig");
const shared = @import("../shared.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const SqliteDb = index.SqliteDb;
const Button = shared.Button;
const appendRelativeTime = shared.appendRelativeTime;
const appendSectionHead = shared.appendSectionHead;
const appendShellEnd = shared.appendShellEnd;
const appendShellStart = shared.appendShellStart;
const appendStatePill = shared.appendStatePill;
const appendTemplate = shared.appendTemplate;
const issueHref = shared.issueHref;
const literalHref = shared.literalHref;
const sqlite = index.sqlite;

const ProjectView = project_views.ProjectView;
const ProjectGroupField = project_views.ProjectGroupField;
const ActiveProjectView = project_views.ActiveProjectView;
const ProjectTableField = project_views.ProjectTableField;
const ProjectTableFields = project_views.ProjectTableFields;
const ProjectRenderContext = project_views.ProjectRenderContext;
const default_project_priority = project_views.default_project_priority;
const default_project_status = project_views.default_project_status;
const project_status_values = project_views.project_status_values;
const project_priority_values = project_views.project_priority_values;
const table_status_view_config = project_views.table_status_view_config;
const board_status_view_config = project_views.board_status_view_config;
const kanban_board_view_config = project_views.kanban_board_view_config;
const priority_table_view_config = project_views.priority_table_view_config;
const my_items_view_config = project_views.my_items_view_config;
const roadmap_view_config = project_views.roadmap_view_config;
const bugs_view_config = project_views.bugs_view_config;
const bugs_priority_view_config = project_views.bugs_priority_view_config;
const bug_triage_view_config = project_views.bug_triage_view_config;
const current_iteration_view_config = project_views.current_iteration_view_config;
const projectViewFromValue = project_views.projectViewFromValue;
const isProjectViewValue = project_views.isProjectViewValue;
const projectViewValue = project_views.projectViewValue;
const projectViewTitle = project_views.projectViewTitle;
const projectViewIconClass = project_views.projectViewIconClass;
const projectGroupFieldFromConfig = project_views.projectGroupFieldFromConfig;
const projectRenderContextFromView = project_views.projectRenderContextFromView;
const projectViewDefaultsFromConfig = project_views.projectViewDefaultsFromConfig;
const projectIssueFilterFromConfig = project_views.projectIssueFilterFromConfig;
const isProjectPriorityValue = project_views.isProjectPriorityValue;
const isProjectStatusValue = project_views.isProjectStatusValue;
const project_issue_filter_sql = project_data.project_issue_filter_sql;
const projectIssueCount = project_data.projectIssueCount;
const projectColumnIssueCount = project_data.projectColumnIssueCount;
const projectPriorityIssueCount = project_data.projectPriorityIssueCount;
const projectFieldKeyExists = project_data.projectFieldKeyExists;
const projectFieldStringValue = project_data.projectFieldStringValue;
const resolveActiveProjectView = project_data.resolveActiveProjectView;
const activeBuiltinProjectView = project_data.activeBuiltinProjectView;
const projectTableFieldsFromConfig = project_data.projectTableFieldsFromConfig;
const bindProjectIssueFilter = project_data.bindProjectIssueFilter;
const projectExists = project_data.projectExists;
const appendProjectWorkspaceChromeStart = project_chrome.appendProjectWorkspaceChromeStart;
const appendProjectColumnOptions = project_chrome.appendProjectColumnOptions;
const appendProjectPriorityOptions = project_chrome.appendProjectPriorityOptions;
const appendProjectNotFound = project_chrome.appendProjectNotFound;
const appendProjectColumns = project_groups.appendProjectColumns;
const appendProjectPriorityGroups = project_groups.appendProjectPriorityGroups;
const appendProjectIssueAssignees = project_issue_render.appendProjectIssueAssignees;
const appendKanbanCardLabels = project_issue_render.appendKanbanCardLabels;
const appendIssueAvatar = project_issue_render.appendIssueAvatar;
const columnTone = project_issue_render.columnTone;
const columnDescription = project_issue_render.columnDescription;
const priorityTone = project_issue_render.priorityTone;
const effectiveStatusLabel = project_issue_render.effectiveStatusLabel;

pub fn appendProjectRoadmap(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    project: []const u8,
    active_view: *const ActiveProjectView,
    current_principal: []const u8,
    csrf_token: []const u8,
) !void {
    var context = projectRenderContextFromView(allocator, active_view, current_principal);
    context.csrf_token = csrf_token;
    const issue_count = try projectIssueCount(db, project, context.filter);
    const group_field = projectGroupFieldFromConfig(allocator, active_view.config_json);
    try appendProjectWorkspaceChromeStart(buf, allocator, db, project, issue_count, active_view, csrf_token);
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
        \\       COALESCE(NULLIF(m.source_author, ''), NULLIF(si.display_name, ''), i.author_principal),
        \\       i.opened_at,
        \\       COALESCE(a.number, 0)
        \\FROM project_items p
        \\JOIN issues i ON i.id = p.issue_id
        \\LEFT JOIN issue_metadata m ON m.issue_id = i.id
        \\LEFT JOIN identities si ON si.id = m.source_identity
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
        try appendProjectRoadmapItem(buf, allocator, db, project, id, title_text, state, author, opened_at, legacy_number, context.csrf_token);
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
        \\       COALESCE(NULLIF(m.source_author, ''), NULLIF(si.display_name, ''), i.author_principal),
        \\       i.opened_at,
        \\       COALESCE(a.number, 0)
        \\FROM project_items p
        \\JOIN issues i ON i.id = p.issue_id
        \\LEFT JOIN issue_metadata m ON m.issue_id = i.id
        \\LEFT JOIN identities si ON si.id = m.source_identity
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
        try appendProjectRoadmapItem(buf, allocator, db, project, id, title_text, state, author, opened_at, legacy_number, context.csrf_token);
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
    csrf_token: []const u8,
) !void {
    const has_start_field = try projectFieldKeyExists(db, project, "start_at");
    const has_end_field = try projectFieldKeyExists(db, project, "end_at");
    const has_legacy_target_field = try projectFieldKeyExists(db, project, "target_at");
    const start_at = if (has_start_field) try projectFieldStringValue(allocator, db, project, id, "start_at") else try allocator.dupe(u8, "");
    defer allocator.free(start_at);
    const end_at = if (has_end_field) try projectFieldStringValue(allocator, db, project, id, "end_at") else try allocator.dupe(u8, "");
    defer allocator.free(end_at);
    const legacy_target_at = if (has_legacy_target_field and end_at.len == 0) try projectFieldStringValue(allocator, db, project, id, "target_at") else try allocator.dupe(u8, "");
    defer allocator.free(legacy_target_at);
    const visible_end_at = if (end_at.len != 0) end_at else legacy_target_at;

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
    if (has_start_field or has_end_field or has_legacy_target_field) {
        try appendTemplate(buf, allocator,
            \\<form class="project-roadmap-date-form" method="post" action="/projects/items">
            \\  <input type="hidden" name="_csrf" value="{csrf_token}">
            \\  <input type="hidden" name="action" value="set-roadmap-dates">
            \\  <input type="hidden" name="project" value="{project}">
            \\  <input type="hidden" name="issue" value="{issue}">
            \\  <input type="hidden" name="view" value="roadmap">
        , .{
            .csrf_token = csrf_token,
            .project = project,
            .issue = id,
        });
        if (has_start_field) {
            try appendTemplate(buf, allocator,
                \\  <label>Start<input type="date" name="start_at" value="{start_at}" data-date-picker data-date-picker-label="Start date" data-date-picker-placeholder="No start date"></label>
            , .{ .start_at = start_at });
        }
        if (has_end_field or has_legacy_target_field) {
            try appendTemplate(buf, allocator,
                \\  <label>End<input type="date" name="end_at" value="{end_at}" data-date-picker data-date-picker-label="End date" data-date-picker-placeholder="No end date"></label>
            , .{ .end_at = visible_end_at });
        }
        try buf.appendSlice(allocator,
            \\  <button class="button secondary" type="submit">Save</button>
            \\</form>
        );
    }
    try buf.appendSlice(allocator, "</div></article>");
}
