const std = @import("std");
const index = @import("../../index.zig");
const repo_mod = @import("../../repo.zig");
const util = @import("../../util.zig");
const project_data = @import("data.zig");
const project_issue_render = @import("issue_render.zig");
const project_overview = @import("overview.zig");
const project_views = @import("views.zig");
const issue_form = @import("../issues/form.zig");
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
const columnTone = project_issue_render.columnTone;
const priorityTone = project_issue_render.priorityTone;

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
        \\       COALESCE(a.number, 0),
        \\       COALESCE(m.milestone, ''),
        \\       COALESCE(m.issue_type, ''),
        \\       ifnull(replace((SELECT group_concat(DISTINCT il.label) FROM issue_labels il WHERE il.issue_id = i.id), ',', ' '), ''),
        \\       ifnull(replace((SELECT group_concat(DISTINCT ia.assignee) FROM issue_assignees ia WHERE ia.issue_id = i.id), ',', ' '), '')
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
        const milestone = try stmt.columnTextDup(allocator, 6);
        defer allocator.free(milestone);
        const issue_type = try stmt.columnTextDup(allocator, 7);
        defer allocator.free(issue_type);
        const labels = try stmt.columnTextDup(allocator, 8);
        defer allocator.free(labels);
        const assignees = try stmt.columnTextDup(allocator, 9);
        defer allocator.free(assignees);

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
            \\<span data-project-issue-search-item data-issue-ref="{issue_ref}" data-issue-display="{issue_display}" data-issue-title="{title}" data-issue-state="{state}" data-issue-priority="{priority}" data-issue-status="{status}" data-issue-milestone="{milestone}" data-issue-type="{issue_type}" data-issue-labels="{labels}" data-issue-assignees="{assignees}"></span>
        , .{
            .issue_ref = issue_ref,
            .issue_display = issue_display,
            .title = title,
            .state = state,
            .priority = priority,
            .status = status,
            .milestone = milestone,
            .issue_type = issue_type,
            .labels = labels,
            .assignees = assignees,
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

pub fn appendProjectIssueMultiSearch(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator,
        \\        <div class="project-issue-search-wrap tree-search-wrap project-issue-multi-search" data-project-issue-multi-search>
        \\          <div class="tree-search-label project-issue-search-label"><span class="project-issue-search-title">Issues</span><span class="project-issue-token-input" data-project-issue-token-input><span class="project-selected-issues" data-project-selected-issues></span><input class="tree-search-input" type="search" placeholder="Search issues or paste a ref" aria-label="Search issues" autocomplete="off" spellcheck="false" data-project-issue-search data-project-issue-multiple></span></div>
        \\        </div>
    );
}

pub fn appendProjectPriorityPicker(buf: *std.ArrayList(u8), allocator: Allocator, selected: []const u8) !void {
    const current = if (selected.len == 0) default_project_priority else selected;
    try buf.appendSlice(allocator,
        \\<div class="project-choice-field project-choice-field-priority">
        \\  <div class="project-choice-label">Priority</div>
        \\  <details class="project-choice-menu" data-popover-menu data-project-choice-menu>
        \\    <summary class="project-choice-control" aria-label="Select priority">
        \\      <span class="project-choice-selected" data-project-choice-selected>
    );
    try appendProjectPriorityChip(buf, allocator, current);
    try buf.appendSlice(allocator,
        \\      </span>
        \\      <span class="project-choice-caret" aria-hidden="true"></span>
        \\    </summary>
        \\    <div class="project-choice-popover" role="radiogroup" aria-label="Priority">
    );
    for (project_priority_values) |priority| {
        try appendTemplate(buf, allocator,
            \\      <label class="project-choice-option"><input type="radio" name="priority" value="{priority}"{checked}><span class="project-choice-option-content" data-project-choice-option-content>
        , .{
            .priority = priority,
            .checked = shared.trustedHtml(if (std.mem.eql(u8, current, priority)) " checked" else ""),
        });
        try appendProjectPriorityChip(buf, allocator, priority);
        try buf.appendSlice(allocator, "</span></label>");
    }
    try buf.appendSlice(allocator,
        \\    </div>
        \\  </details>
        \\</div>
    );
}

pub fn appendProjectStatusPicker(buf: *std.ArrayList(u8), allocator: Allocator, selected: ?[]const u8) !void {
    const current = if (selected) |value| if (value.len == 0) default_project_status else value else default_project_status;
    try buf.appendSlice(allocator,
        \\<div class="project-choice-field project-choice-field-status">
        \\  <div class="project-choice-label">Status</div>
        \\  <details class="project-choice-menu" data-popover-menu data-project-choice-menu>
        \\    <summary class="project-choice-control" aria-label="Select status">
        \\      <span class="project-choice-selected" data-project-choice-selected>
    );
    try appendProjectStatusChip(buf, allocator, current);
    try buf.appendSlice(allocator,
        \\      </span>
        \\      <span class="project-choice-caret" aria-hidden="true"></span>
        \\    </summary>
        \\    <div class="project-choice-popover" role="radiogroup" aria-label="Status">
    );
    for (project_status_values) |status| {
        try appendTemplate(buf, allocator,
            \\      <label class="project-choice-option"><input type="radio" name="column" value="{status}"{checked}><span class="project-choice-option-content" data-project-choice-option-content>
        , .{
            .status = status,
            .checked = shared.trustedHtml(if (std.mem.eql(u8, current, status)) " checked" else ""),
        });
        try appendProjectStatusChip(buf, allocator, status);
        try buf.appendSlice(allocator, "</span></label>");
    }
    try buf.appendSlice(allocator,
        \\    </div>
        \\  </details>
        \\</div>
    );
}

pub fn appendProjectIssueFormPickers(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb) !void {
    var picker_options = issue_form.loadIssueFormPickerOptionsFromDb(allocator, db) catch issue_form.IssueFormPickerOptions{};
    defer picker_options.deinit(allocator);
    const empty_values: []const []const u8 = &.{};
    try issue_form.appendIssueFormLabelsPicker(buf, allocator, picker_options.labels.items, empty_values, "");
    try issue_form.appendIssueFormAssigneesPicker(buf, allocator, picker_options.assignees.items, empty_values, "");
}

fn appendProjectPriorityChip(buf: *std.ArrayList(u8), allocator: Allocator, priority: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<span class="project-priority-chip tone-{tone}">{priority}</span>
    , .{
        .tone = priorityTone(priority),
        .priority = if (priority.len == 0) "None" else priority,
    });
}

fn appendProjectStatusChip(buf: *std.ArrayList(u8), allocator: Allocator, status: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<span class="project-status-chip tone-{tone}"><span class="kanban-status-dot" aria-hidden="true"></span>{status}</span>
    , .{
        .tone = columnTone(status),
        .status = if (status.len == 0) "No status" else status,
    });
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
    , .{
        .project = project,
        .view = active_view.ref,
    });
    try appendProjectIssueMultiSearch(buf, allocator);
    try appendProjectStatusPicker(buf, allocator, if (defaults.status_explicit) defaults.status else null);
    try appendTemplate(buf, allocator,
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
    );
    try appendProjectPriorityPicker(buf, allocator, defaults.priority);
    try appendProjectStatusPicker(buf, allocator, defaults.status);
    try appendTemplate(buf, allocator,
        \\        </div>
        \\        <div class="grid two">
    , .{});
    try appendProjectIssueFormPickers(buf, allocator, db);
    try appendTemplate(buf, allocator,
        \\        </div>
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
