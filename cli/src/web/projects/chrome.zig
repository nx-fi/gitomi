const std = @import("std");
const index = @import("../../index.zig");
const repo_mod = @import("../../repo.zig");
const util = @import("../../util.zig");
const project_data = @import("data.zig");
const project_overview = @import("overview.zig");
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

pub fn appendProjectWorkspaceChromeStart(
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

pub fn appendProjectColumnOptions(
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

pub fn appendProjectPriorityOptions(buf: *std.ArrayList(u8), allocator: Allocator, selected: []const u8) !void {
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

fn appendProjectViewTabs(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    project: []const u8,
    active_view: *const ActiveProjectView,
    issue_count: usize,
) !void {
    _ = db;
    const active_tab: project_overview.ProjectPageTab = switch (active_view.layout) {
        .table => .table,
        .board => .board,
        .roadmap => .roadmap,
        .issues => .issues,
    };
    try project_overview.appendProjectPageTabs(buf, allocator, project, active_tab, issue_count);
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
        \\    <summary class="button primary" aria-expanded="false"><span class="project-link-icon" aria-hidden="true"></span>Add issue</summary>
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
    try appendTemplate(buf, allocator,
        \\        </select></label>
        \\        <div class="form-actions"><button class="button primary" type="submit">Add issue</button></div>
        \\      </form>
        \\    </div>
        \\  </details>
        \\  <details class="project-action-menu" data-popover-menu>
        \\    <summary class="button secondary" aria-expanded="false"><span class="project-add-icon" aria-hidden="true"></span>New issue</summary>
        \\    <div class="project-action-popover">
        \\      <form class="project-item-form" method="post" action="/projects/items">
        \\        <input type="hidden" name="action" value="create-issue">
        \\        <input type="hidden" name="project" value="{project}">
        \\        <input type="hidden" name="view" value="{view}">
        \\        <label>Title<input name="title" required></label>
    , .{
        .project = project,
        .view = active_view.ref,
    });
    try shared.appendMarkdownEditor(buf, allocator, .{
        .rows = 4,
        .placeholder = "Describe the issue",
        .required = false,
    });
    try buf.appendSlice(allocator,
        \\        <div class="grid two">
        \\          <label>Priority<select name="priority">
    );
    try appendProjectPriorityOptions(buf, allocator, defaults.priority);
    try appendTemplate(buf, allocator,
        \\          </select></label>
        \\          <label>Status<select name="column">
    , .{});
    try appendProjectColumnOptions(buf, allocator, db, project, defaults.status);
    try appendTemplate(buf, allocator,
        \\          </select></label>
        \\        </div>
        \\        <label>Labels<input name="labels" placeholder="bug, docs"></label>
        \\        <label>Assignees<input name="assignees" placeholder="alice, bob"></label>
        \\        <div class="form-actions"><button class="button secondary" type="submit">Create issue</button></div>
        \\      </form>
        \\    </div>
        \\  </details>
        \\</div>
    , .{});
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

pub fn appendProjectNotFound(buf: *std.ArrayList(u8), allocator: Allocator, project: []const u8) !void {
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
