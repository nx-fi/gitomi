const std = @import("std");
const cmd_common = @import("../../cmd_common.zig");
const index = @import("../../index.zig");
const repo_mod = @import("../../repo.zig");
const project_issue_render = @import("issue_render.zig");
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
const appendTemplate = shared.appendTemplate;
const literalHref = shared.literalHref;

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
    try appendProjectIndexListHeader(&buf, allocator);

    var projects = try db.prepare(
        \\WITH project_names AS (
        \\  SELECT name FROM projects
        \\  UNION
        \\  SELECT project AS name FROM issue_projects
        \\),
        \\latest_projects AS (
        \\  SELECT id, name, description, state, status, status_occurred_at, priority, end_at, created_at
        \\  FROM (
        \\    SELECT
        \\      p.id,
        \\      p.name,
        \\      p.description,
        \\      p.state,
        \\      p.status,
        \\      p.status_occurred_at,
        \\      p.priority,
        \\      p.end_at,
        \\      p.created_at,
        \\      ROW_NUMBER() OVER (PARTITION BY p.name ORDER BY p.created_at DESC, p.id DESC) AS rank
        \\    FROM projects p
        \\  )
        \\  WHERE rank = 1
        \\),
        \\project_items AS (
        \\  SELECT ip.project AS name, ip.issue_id
        \\  FROM issue_projects ip
        \\  UNION
        \\  SELECT lp.name AS name, pm.issue_id
        \\  FROM latest_projects lp
        \\  JOIN project_memberships pm ON pm.project_id = lp.id
        \\),
        \\lead_values AS (
        \\  SELECT DISTINCT lp.name, pl.lead
        \\  FROM latest_projects lp
        \\  JOIN project_leads pl ON pl.project_id = lp.id
        \\  WHERE pl.lead <> ''
        \\),
        \\lead_rank AS (
        \\  SELECT
        \\    name,
        \\    lead,
        \\    COUNT(*) OVER (PARTITION BY name) AS lead_count,
        \\    ROW_NUMBER() OVER (PARTITION BY name ORDER BY lower(lead), lead) AS rank
        \\  FROM lead_values
        \\),
        \\project_activity AS (
        \\  SELECT lp.name, lp.created_at AS activity_at
        \\  FROM latest_projects lp
        \\  UNION ALL
        \\  SELECT pi.name, i.state_occurred_at AS activity_at
        \\  FROM project_items pi
        \\  JOIN issues i ON i.id = pi.issue_id
        \\),
        \\project_activity_max AS (
        \\  SELECT name, MAX(activity_at) AS activity_at
        \\  FROM project_activity
        \\  GROUP BY name
        \\)
        \\SELECT
        \\  pn.name,
        \\  COALESCE(lp.description, ''),
        \\  COALESCE(lp.state, 'open'),
        \\  COALESCE(lp.status, 'Planned'),
        \\  COALESCE(NULLIF(lp.status_occurred_at, ''), NULLIF(lp.created_at, ''), ''),
        \\  COALESCE(lp.priority, ''),
        \\  COALESCE(lp.end_at, ''),
        \\  COUNT(DISTINCT pi.issue_id),
        \\  COUNT(DISTINCT CASE WHEN i.state = 'closed' THEN i.id END),
        \\  COALESCE(lr.lead, ''),
        \\  COALESCE(lr.lead_count, 0),
        \\  COALESCE(pa.activity_at, '')
        \\FROM project_names pn
        \\LEFT JOIN latest_projects lp ON lp.name = pn.name
        \\LEFT JOIN project_items pi ON pi.name = pn.name
        \\LEFT JOIN issues i ON i.id = pi.issue_id
        \\LEFT JOIN lead_rank lr ON lr.name = pn.name AND lr.rank = 1
        \\LEFT JOIN project_activity_max pa ON pa.name = pn.name
        \\GROUP BY
        \\  pn.name,
        \\  lp.description,
        \\  lp.state,
        \\  lp.status,
        \\  lp.status_occurred_at,
        \\  lp.created_at,
        \\  lp.priority,
        \\  lp.end_at,
        \\  lr.lead,
        \\  lr.lead_count,
        \\  pa.activity_at
        \\ORDER BY
        \\  CASE WHEN COALESCE(pa.activity_at, '') = '' THEN 1 ELSE 0 END,
        \\  COALESCE(pa.activity_at, '') DESC,
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
        const status = try projects.columnTextDup(allocator, 3);
        defer allocator.free(status);
        const status_at = try projects.columnTextDup(allocator, 4);
        defer allocator.free(status_at);
        const priority = try projects.columnTextDup(allocator, 5);
        defer allocator.free(priority);
        const target_at = try projects.columnTextDup(allocator, 6);
        defer allocator.free(target_at);
        const issue_count = @as(usize, @intCast(projects.columnInt64(7)));
        const closed_issue_count = @as(usize, @intCast(projects.columnInt64(8)));
        const lead = try projects.columnTextDup(allocator, 9);
        defer allocator.free(lead);
        const lead_count = @as(usize, @intCast(projects.columnInt64(10)));
        const activity_at = try projects.columnTextDup(allocator, 11);
        defer allocator.free(activity_at);
        try appendProjectIndexRow(&buf, allocator, project, description, state, status, status_at, priority, target_at, issue_count, closed_issue_count, lead, lead_count, activity_at);
        shown += 1;
    }
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

fn appendProjectIndexListHeader(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator,
        \\<header class="project-index-list-head">
        \\  <div class="issues-select-all"><input type="checkbox" aria-label="Select all projects" disabled></div>
        \\  <span>Name</span>
        \\  <span>Health</span>
        \\  <span>Priority</span>
        \\  <span>Lead</span>
        \\  <span>Target date</span>
        \\  <span>Issues</span>
        \\  <span>Status</span>
        \\</header>
    );
}

fn appendProjectIndexRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    project: []const u8,
    description: []const u8,
    state: []const u8,
    status: []const u8,
    status_at: []const u8,
    priority: []const u8,
    target_at: []const u8,
    issue_count: usize,
    closed_issue_count: usize,
    lead: []const u8,
    lead_count: usize,
    activity_at: []const u8,
) !void {
    const health_label = projectHealthLabel(status, state);
    const health_tone = projectHealthTone(status, state);
    const progress = projectProgressPercent(issue_count, closed_issue_count);
    const progress_tone = projectProgressTone(issue_count, closed_issue_count);
    const progress_degrees = projectProgressDegrees(issue_count, closed_issue_count);
    const lead_label = try projectLeadLabelOwned(allocator, lead, lead_count);
    defer allocator.free(lead_label);
    const target_label = try projectTargetDateLabelOwned(allocator, target_at);
    defer allocator.free(target_label);
    try appendTemplate(buf, allocator,
        \\<article class="project-index-row issue-list-row tone-{health_tone}">
        \\  <div class="issue-select-cell"><input type="checkbox" aria-label="Select project {project}" disabled></div>
        \\  <div class="project-index-name-cell">
        \\    <span class="project-index-icon" aria-hidden="true"></span>
        \\    <div>
        \\      <a class="issue-row-title" href="
    , .{
        .health_tone = health_tone,
        .project = project,
    });
    try appendProjectOverviewHref(buf, allocator, project);
    try appendTemplate(buf, allocator,
        \\">{project}</a>
    , .{ .project = project });
    if (description.len != 0) {
        try appendTemplate(buf, allocator,
            \\      <p class="issue-row-meta">{description}</p>
        , .{ .description = description });
    } else if (activity_at.len != 0) {
        try buf.appendSlice(allocator, "<p class=\"issue-row-meta\">Updated ");
        try appendRelativeTime(buf, allocator, activity_at);
        try buf.appendSlice(allocator, "</p>");
    }
    try buf.appendSlice(allocator,
        \\    </div>
        \\  </div>
        \\  <div class="project-index-health">
    );
    try appendTemplate(buf, allocator,
        \\<span class="issue-state-icon project-summary-health-icon {health_icon_state} tone-{health_tone}" title="{health_label}" aria-label="{health_label}"></span><strong class="project-summary-health-value tone-{health_tone}">{health_label}
    , .{
        .health_icon_state = projectHealthIconState(health_tone),
        .health_tone = health_tone,
        .health_label = health_label,
    });
    const health_at = if (status_at.len != 0) status_at else activity_at;
    if (health_at.len != 0) {
        try buf.appendSlice(allocator, "<span aria-hidden=\"true\"> &middot; </span>");
        try appendRelativeTime(buf, allocator, health_at);
    }
    try appendTemplate(buf, allocator,
        \\</strong></div>
        \\  <div class="project-index-priority"><strong class="{priority_class}">{priority}</strong></div>
        \\  <div class="project-index-lead"><span class="button-icon icon-users" aria-hidden="true"></span><strong>{lead}</strong></div>
        \\  <div class="project-index-target"><span class="button-icon icon-calendar" aria-hidden="true"></span><strong>{target}</strong></div>
        \\  <div class="project-index-issues"><strong>{issue_count}</strong></div>
        \\  <div class="project-index-progress"><strong class="project-summary-progress tone-{progress_tone}" title="{closed_issue_count} of {issue_count} issues closed" style="--issue-task-progress: {progress_degrees}deg"><span class="issue-task-progress-icon project-summary-progress-icon" aria-hidden="true"></span>{progress}%</strong></div>
        \\</article>
    , .{
        .priority_class = projectIndexPriorityClass(priority),
        .priority = priorityIndexLabel(priority),
        .lead = lead_label,
        .target = target_label,
        .issue_count = issue_count,
        .closed_issue_count = closed_issue_count,
        .progress_tone = progress_tone,
        .progress_degrees = progress_degrees,
        .progress = progress,
    });
}

fn projectHealthLabel(status: []const u8, state: []const u8) []const u8 {
    const project_status = cmd_common.canonicalProjectStatus(status);
    if (std.mem.eql(u8, state, "closed") or std.mem.eql(u8, project_status, "Completed")) return "Complete";
    if (std.mem.eql(u8, project_status, "Canceled")) return "Canceled";
    if (std.mem.eql(u8, project_status, "Backlog") or std.mem.eql(u8, project_status, "Planned")) return "Not started";
    return "On track";
}

fn projectHealthTone(status: []const u8, state: []const u8) []const u8 {
    const project_status = cmd_common.canonicalProjectStatus(status);
    if (std.mem.eql(u8, state, "closed") or std.mem.eql(u8, project_status, "Completed")) return "done";
    if (std.mem.eql(u8, project_status, "Canceled")) return "failed";
    if (std.mem.eql(u8, project_status, "Backlog") or std.mem.eql(u8, project_status, "Planned")) return "todo";
    return "progress";
}

fn projectProgressPercent(issue_count: usize, closed_issue_count: usize) usize {
    if (issue_count == 0) return 0;
    return (@min(closed_issue_count, issue_count) * 100) / issue_count;
}

fn projectProgressTone(issue_count: usize, closed_issue_count: usize) []const u8 {
    if (issue_count != 0 and closed_issue_count >= issue_count) return "done";
    if (closed_issue_count == 0) return "todo";
    return "progress";
}

fn projectProgressDegrees(issue_count: usize, closed_issue_count: usize) usize {
    if (issue_count == 0) return 0;
    return (@min(closed_issue_count, issue_count) * 360) / issue_count;
}

fn projectHealthIconState(tone: []const u8) []const u8 {
    if (std.mem.eql(u8, tone, "done")) return "closed";
    return "open";
}

fn projectLeadLabelOwned(allocator: Allocator, lead: []const u8, lead_count: usize) ![]u8 {
    if (lead_count == 0 or lead.len == 0) return allocator.dupe(u8, "No lead");
    if (lead_count == 1) return allocator.dupe(u8, lead);
    return std.fmt.allocPrint(allocator, "{s} + {d}", .{ lead, lead_count - 1 });
}

fn projectTargetDateLabelOwned(allocator: Allocator, target_at: []const u8) ![]u8 {
    if (target_at.len == 0) return allocator.dupe(u8, "No target date");
    return dateLabelWithOrdinalOwned(allocator, target_at);
}

fn dateLabelWithOrdinalOwned(allocator: Allocator, value: []const u8) ![]u8 {
    if (value.len >= 10 and value[4] == '-' and value[7] == '-') {
        const month = std.fmt.parseInt(u8, value[5..7], 10) catch 0;
        const day = std.fmt.parseInt(u8, value[8..10], 10) catch 0;
        if (month >= 1 and month <= 12 and day >= 1 and day <= 31) {
            return std.fmt.allocPrint(allocator, "{s} {d}{s}", .{ monthNames()[month - 1], day, ordinalSuffix(day) });
        }
    }
    return allocator.dupe(u8, value);
}

fn ordinalSuffix(day: u8) []const u8 {
    if (day >= 11 and day <= 13) return "th";
    return switch (day % 10) {
        1 => "st",
        2 => "nd",
        3 => "rd",
        else => "th",
    };
}

fn monthNames() []const []const u8 {
    return &.{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
}

fn projectIndexPriorityClass(priority: []const u8) []const u8 {
    const tone = project_issue_render.priorityTone(priority);
    if (std.mem.eql(u8, tone, "p0")) return "project-index-priority-value tone-p0";
    if (std.mem.eql(u8, tone, "p1")) return "project-index-priority-value tone-p1";
    if (std.mem.eql(u8, tone, "p2")) return "project-index-priority-value tone-p2";
    if (std.mem.eql(u8, tone, "p3")) return "project-index-priority-value tone-p3";
    return "project-index-priority-value";
}

fn priorityIndexLabel(priority: []const u8) []const u8 {
    return if (priority.len == 0) "---" else priority;
}

fn appendProjectOverviewHref(buf: *std.ArrayList(u8), allocator: Allocator, project: []const u8) !void {
    try buf.appendSlice(allocator, "/projects?project=");
    try shared.appendUrlEncoded(buf, allocator, project);
}

test "project index names do not prepend at sign" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendProjectIndexRow(&buf, std.testing.allocator, "Release & Plan", "", "open", cmd_common.default_project_status, "", "", "", 0, 0, "", 0, "");

    try std.testing.expect(std.mem.indexOf(u8, buf.items, ">Release &amp; Plan</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "@Release") == null);
}
