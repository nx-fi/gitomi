const std = @import("std");
const index = @import("../../index.zig");
const repo_mod = @import("../../repo.zig");
const util = @import("../../util.zig");
const project_chrome = @import("chrome.zig");
const project_data = @import("data.zig");
const project_groups = @import("groups.zig");
const project_issue_render = @import("issue_render.zig");
const project_overview = @import("overview.zig");
const project_board = @import("board.zig");
const project_issues = @import("issues.zig");
const project_roadmap = @import("roadmap.zig");
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
const appendProjectActivityView = project_overview.appendProjectActivityView;
const appendProjectOverview = project_overview.appendProjectOverview;
const appendProjectIssueAssignees = project_issue_render.appendProjectIssueAssignees;
const appendKanbanCardLabels = project_issue_render.appendKanbanCardLabels;
const appendIssueAvatar = project_issue_render.appendIssueAvatar;
const columnTone = project_issue_render.columnTone;
const columnDescription = project_issue_render.columnDescription;
const priorityTone = project_issue_render.priorityTone;
const effectiveStatusLabel = project_issue_render.effectiveStatusLabel;

pub fn renderProjectWorkspace(
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

    if (view_ref.len == 0 or std.mem.eql(u8, view_ref, "overview")) {
        try appendProjectOverview(&buf, allocator, repo, db, project);
        try appendShellEnd(&buf, allocator);
        return buf.toOwnedSlice(allocator);
    }
    if (std.mem.eql(u8, view_ref, "activity")) {
        try appendProjectActivityView(&buf, allocator, repo, db, project);
        try appendShellEnd(&buf, allocator);
        return buf.toOwnedSlice(allocator);
    }

    var active_view = try resolveActiveProjectView(allocator, db, project, view_ref);
    defer active_view.deinit(allocator);
    const current_principal = (try shared.currentPrincipalOwned(allocator, repo)) orelse try allocator.dupe(u8, "");
    defer allocator.free(current_principal);

    switch (active_view.layout) {
        .table => try project_table.appendProjectTable(&buf, allocator, db, project, &active_view, current_principal),
        .board => try project_board.appendProjectBoard(&buf, allocator, db, project, &active_view, current_principal),
        .roadmap => try project_roadmap.appendProjectRoadmap(&buf, allocator, db, project, &active_view, current_principal),
        .issues => try project_issues.appendProjectIssues(&buf, allocator, db, project, &active_view, current_principal),
    }

    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
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
    try db.exec("CREATE TABLE issues (id TEXT, title TEXT, state TEXT, opened_at TEXT, author_principal TEXT)");
    try db.exec("CREATE TABLE issue_metadata (issue_id TEXT, milestone TEXT, issue_type TEXT, priority TEXT, status TEXT, source_author TEXT, source_identity TEXT)");
    try db.exec("CREATE TABLE issue_labels (issue_id TEXT, label TEXT)");
    try db.exec("CREATE TABLE issue_assignees (issue_id TEXT, assignee TEXT)");
    try db.exec("CREATE TABLE label_definitions (id TEXT, name TEXT, color TEXT, priority INTEGER)");
    try db.exec("CREATE TABLE pull_labels (pull_id TEXT, label TEXT)");
    try db.exec("CREATE TABLE pull_assignees (pull_id TEXT, assignee TEXT)");
    try db.exec("CREATE TABLE identities (id TEXT, display_name TEXT, email TEXT)");
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
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "project-title-icon") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "project-lock-icon") == null);
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

test "project not found names do not prepend at sign" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendProjectNotFound(&buf, std.testing.allocator, "Release & Plan");

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<strong>Release &amp; Plan</strong>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "@Release") == null);
}
