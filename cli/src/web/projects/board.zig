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

pub fn appendProjectBoard(
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
        \\            <input type="hidden" name="action" value="add-existing">
        \\            <input type="hidden" name="project" value="{project}">
        \\            <input type="hidden" name="column" value="{column}">
        \\            <input type="hidden" name="priority" value="{existing_priority}">
        \\            <input type="hidden" name="view" value="{view}">
        \\            <div class="project-issue-search-wrap tree-search-wrap">
        \\              <label class="tree-search-label project-issue-search-label"><span>Issue</span><input class="tree-search-input" type="search" name="issue" placeholder="Search issues or paste a ref" aria-label="Issue" autocomplete="off" spellcheck="false" data-project-issue-search required></label>
        \\            </div>
        \\            <div class="form-actions"><button class="button primary" type="submit">Add issue</button></div>
        \\          </form>
        \\          <form class="project-item-form project-column-existing-form" method="post" action="/projects/items">
        \\            <input type="hidden" name="action" value="create-issue">
        \\            <input type="hidden" name="project" value="{project}">
        \\            <input type="hidden" name="view" value="{view}">
        \\            <label>Title<input name="title" required></label>
    , .{
        .tone = tone,
        .project = project,
        .column = column,
        .existing_priority = if (context.defaults.priority_explicit) context.defaults.priority else "",
        .view = context.view_ref,
        .title = title,
        .count = count,
        .note = note,
    });
    try shared.appendMarkdownEditor(buf, allocator, .{
        .rows = 4,
        .placeholder = "Describe the issue",
        .required = false,
    });
    try buf.appendSlice(allocator,
        \\            <div class="grid two">
        \\              <label>Priority<select name="priority">
    );
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
        \\            <div class="form-actions"><button class="button secondary" type="submit">Create issue</button></div>
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
        \\       COALESCE(NULLIF(si.display_name, ''), NULLIF(m.source_author, ''), i.author_principal),
        \\       i.opened_at,
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
