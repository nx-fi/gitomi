const std = @import("std");
const index = @import("../../index.zig");
const util = @import("../../util.zig");
const project_chrome = @import("chrome.zig");
const project_data = @import("data.zig");
const project_issue_render = @import("issue_render.zig");
const project_views = @import("views.zig");
const shared = @import("../shared.zig");

const Allocator = std.mem.Allocator;
const SqliteDb = index.SqliteDb;

const ActiveProjectView = project_views.ActiveProjectView;
const ProjectRenderContext = project_views.ProjectRenderContext;
const appendRelativeTime = shared.appendRelativeTime;
const appendTemplate = shared.appendTemplate;
const issueHref = shared.issueHref;
const bindProjectIssueFilter = project_data.bindProjectIssueFilter;
const projectIssueCount = project_data.projectIssueCount;
const project_issue_filter_sql = project_data.project_issue_filter_sql;
const projectRenderContextFromView = project_views.projectRenderContextFromView;
const appendProjectWorkspaceChromeStart = project_chrome.appendProjectWorkspaceChromeStart;
const appendProjectColumnOptions = project_chrome.appendProjectColumnOptions;
const appendProjectPriorityOptions = project_chrome.appendProjectPriorityOptions;
const appendProjectIssueAssignees = project_issue_render.appendProjectIssueAssignees;
const appendKanbanCardLabels = project_issue_render.appendKanbanCardLabels;
const columnTone = project_issue_render.columnTone;
const priorityTone = project_issue_render.priorityTone;

pub fn appendProjectIssues(
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
    try buf.appendSlice(allocator, "<div class=\"project-issues-view\">");
    if (issue_count == 0) {
        try appendProjectIssuesEmptyState(buf, allocator, db, project, &context);
    } else {
        try appendProjectIssuesList(buf, allocator, db, project, &context);
    }
    try buf.appendSlice(allocator, "</div></section>");
}

fn appendProjectIssuesEmptyState(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    project: []const u8,
    context: *const ProjectRenderContext,
) !void {
    try appendTemplate(buf, allocator,
        \\<section class="project-issues-empty">
        \\  <h2>No issues linked to the current project</h2>
        \\  <div class="project-issues-empty-actions">
        \\    <details class="project-action-menu" data-popover-menu>
        \\      <summary class="button primary" aria-expanded="false"><span class="project-link-icon" aria-hidden="true"></span>Add Issue</summary>
        \\      <div class="project-action-popover project-action-popover-narrow">
        \\        <form class="project-item-form" method="post" action="/projects/items">
        \\          <input type="hidden" name="action" value="add-existing">
        \\          <input type="hidden" name="project" value="{project}">
        \\          <input type="hidden" name="view" value="{view}">
        \\          <div class="project-issue-search-wrap tree-search-wrap">
        \\            <label class="tree-search-label project-issue-search-label"><span>Issue</span><input class="tree-search-input" name="issue" placeholder="Search issues or paste a ref" autocomplete="off" spellcheck="false" data-project-issue-search required></label>
        \\          </div>
        \\          <label>Priority<select name="priority">
    , .{
        .project = project,
        .view = context.view_ref,
    });
    try appendProjectPriorityOptions(buf, allocator, if (context.defaults.priority_explicit) context.defaults.priority else "");
    try buf.appendSlice(allocator,
        \\          </select></label>
        \\          <label>Status<select name="column">
    );
    try appendProjectColumnOptions(buf, allocator, db, project, if (context.defaults.status_explicit) context.defaults.status else null);
    try buf.appendSlice(allocator,
        \\          </select></label>
        \\          <div class="form-actions"><button class="button primary" type="submit">Add issue</button></div>
        \\        </form>
        \\      </div>
        \\    </details>
        \\    <details class="project-action-menu" data-popover-menu>
        \\      <summary class="button secondary" aria-expanded="false"><span class="project-add-icon" aria-hidden="true"></span>New issue</summary>
        \\      <div class="project-action-popover">
        \\        <form class="project-item-form" method="post" action="/projects/items">
        \\          <input type="hidden" name="action" value="create-issue">
        \\          <input type="hidden" name="project" value="
    );
    try shared.appendHtml(buf, allocator, project);
    try appendTemplate(buf, allocator,
        \\">
        \\          <input type="hidden" name="view" value="{view}">
        \\          <label>Title<input name="title" required></label>
    , .{ .view = context.view_ref });
    try shared.appendMarkdownEditor(buf, allocator, .{
        .rows = 4,
        .placeholder = "Describe the issue",
        .required = false,
    });
    try buf.appendSlice(allocator,
        \\          <div class="grid two">
        \\            <label>Priority<select name="priority">
    );
    try appendProjectPriorityOptions(buf, allocator, context.defaults.priority);
    try buf.appendSlice(allocator,
        \\            </select></label>
        \\            <label>Status<select name="column">
    );
    try appendProjectColumnOptions(buf, allocator, db, project, context.defaults.status);
    try buf.appendSlice(allocator,
        \\            </select></label>
        \\          </div>
        \\          <label>Labels<input name="labels" placeholder="bug, docs"></label>
        \\          <label>Assignees<input name="assignees" placeholder="alice, bob"></label>
        \\          <div class="form-actions"><button class="button secondary" type="submit">Create issue</button></div>
        \\        </form>
        \\      </div>
        \\    </details>
        \\  </div>
        \\</section>
    );
}

fn appendProjectIssuesList(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    project: []const u8,
    context: *const ProjectRenderContext,
) !void {
    try buf.appendSlice(allocator, "<section class=\"project-issues-list\" aria-label=\"Project issues\">");
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
        \\WHERE 1 = 1
    ++ project_issue_filter_sql ++
        \\ORDER BY
        \\  CASE i.state WHEN 'open' THEN 0 ELSE 1 END,
        \\  i.opened_at DESC,
        \\  i.id DESC
    );
    defer rows.deinit();
    try rows.bindText(1, project);
    try rows.bindText(2, project);
    try bindProjectIssueFilter(&rows, 3, project, context.filter);

    while (try rows.step()) {
        const id = try rows.columnTextDup(allocator, 0);
        defer allocator.free(id);
        const title = try rows.columnTextDup(allocator, 1);
        defer allocator.free(title);
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
        try appendProjectIssueRow(buf, allocator, db, id, title, state, author, opened_at, milestone, priority, status, legacy_number, comment_count);
    }
    try buf.appendSlice(allocator, "</section>");
}

fn appendProjectIssueRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
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
        \\<article class="issue-list-row project-issue-list-row is-{state}">
        \\  <div class="issue-state-cell"><span class="issue-state-icon {state}" title="{state}" aria-label="{state}"></span></div>
        \\  <div class="issue-row-content">
        \\    <div class="issue-row-title-line"><a class="issue-row-title" href="{href}">{title}</a><span class="project-priority-chip tone-{priority_tone}">{priority}</span><span class="project-status-chip tone-{status_tone}">{status}</span></div>
        \\    <p class="issue-row-meta">
    , .{
        .state = state,
        .href = issueHref(issue_ref),
        .title = title,
        .priority_tone = priorityTone(priority),
        .priority = if (priority.len == 0) "None" else priority,
        .status_tone = columnTone(status),
        .status = if (status.len == 0) "No status" else status,
    });
    if (legacy_number > 0) {
        try appendTemplate(buf, allocator, "GitHub #{legacy_number}", .{ .legacy_number = legacy_number });
    } else {
        try appendTemplate(buf, allocator, "#{issue_ref}", .{ .issue_ref = issue_ref });
    }
    try appendTemplate(buf, allocator, " by {author} opened ", .{ .author = author });
    try appendRelativeTime(buf, allocator, opened_at);
    try buf.appendSlice(allocator, "</p>");
    try appendKanbanCardLabels(buf, allocator, db, id);
    try buf.appendSlice(allocator, "</div><div class=\"issue-row-side\">");
    if (milestone.len != 0) {
        try appendTemplate(buf, allocator,
            \\<span class="issue-row-milestone" title="Milestone"><span class="issue-milestone-icon" aria-hidden="true"></span>{milestone}</span>
        , .{ .milestone = milestone });
    }
    try appendProjectIssueAssignees(buf, allocator, db, id);
    if (comment_count > 0) {
        try appendTemplate(buf, allocator,
            \\<span class="issue-comments" title="Comments"><span class="issue-comments-icon" aria-hidden="true"></span>{comment_count}</span>
        , .{ .comment_count = comment_count });
    }
    try buf.appendSlice(allocator, "</div></article>");
}
