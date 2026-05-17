const std = @import("std");
const index = @import("../../index.zig");
const repo_mod = @import("../../repo.zig");
const util = @import("../../util.zig");
const project_chrome = @import("chrome.zig");
const project_data = @import("data.zig");
const project_groups = @import("groups.zig");
const project_issue_render = @import("issue_render.zig");
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

pub fn appendProjectTable(
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
        \\       COALESCE(NULLIF(si.display_name, ''), NULLIF(m.source_author, ''), i.author_principal),
        \\       i.opened_at,
        \\       COALESCE(m.milestone, ''),
        \\       COALESCE(m.priority, ''),
        \\       COALESCE(m.status, ''),
        \\       COALESCE(a.number, 0),
        \\       (SELECT COUNT(*) FROM comments c WHERE c.parent_kind = 'issue' AND c.parent_id = i.id)
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
        \\       COALESCE(NULLIF(si.display_name, ''), NULLIF(m.source_author, ''), i.author_principal),
        \\       i.opened_at,
        \\       COALESCE(m.milestone, ''),
        \\       COALESCE(m.priority, ''),
        \\       COALESCE(NULLIF(m.status, ''), p.legacy_column, ''),
        \\       COALESCE(a.number, 0),
        \\       (SELECT COUNT(*) FROM comments c WHERE c.parent_kind = 'issue' AND c.parent_id = i.id)
        \\FROM project_items p
        \\JOIN issues i ON i.id = p.issue_id
        \\LEFT JOIN issue_metadata m ON m.issue_id = i.id
        \\LEFT JOIN identities si ON si.id = m.source_identity
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
