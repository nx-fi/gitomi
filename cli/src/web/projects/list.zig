const std = @import("std");
const index = @import("../../index.zig");
const repo_mod = @import("../../repo.zig");
const project_views = @import("views.zig");
const milestones_page = @import("../milestones.zig");
const shared = @import("../shared.zig");

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
const literalHref = shared.literalHref;
const ProjectView = project_views.ProjectView;
const projectViewValue = project_views.projectViewValue;

pub fn renderProjectIndex(allocator: Allocator, repo: Repo, db: *SqliteDb) ![]u8 {
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
    try appendProjectOverviewHref(buf, allocator, project);
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

fn appendProjectViewLink(buf: *std.ArrayList(u8), allocator: Allocator, project: []const u8, view: ProjectView, label: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<a class="button secondary" href="
    , .{});
    try appendProjectHref(buf, allocator, project, view);
    try appendTemplate(buf, allocator, "\">{label}</a>", .{ .label = label });
}

fn appendProjectOverviewHref(buf: *std.ArrayList(u8), allocator: Allocator, project: []const u8) !void {
    try buf.appendSlice(allocator, "/projects?project=");
    try shared.appendUrlEncoded(buf, allocator, project);
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

test "project index names do not prepend at sign" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendProjectIndexCard(&buf, std.testing.allocator, "Release & Plan", "", "open", 0, 0, "");

    try std.testing.expect(std.mem.indexOf(u8, buf.items, ">Release &amp; Plan</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "@Release") == null);
}
