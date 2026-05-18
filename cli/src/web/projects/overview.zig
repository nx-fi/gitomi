const std = @import("std");
const cmd_common = @import("../../cmd_common.zig");
const event_mod = @import("../../event.zig");
const index = @import("../../index.zig");
const issues_page = @import("../issues.zig");
const project_mod = @import("../../project.zig");
const repo_mod = @import("../../repo.zig");
const util = @import("../../util.zig");
const project_issue_render = @import("issue_render.zig");
const project_views = @import("views.zig");
const shared = @import("../shared.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const SqliteDb = index.SqliteDb;
const createProjectUpdatedEvent = project_mod.createProjectUpdatedEvent;
const formValueOwned = issues_page.formValueOwned;
const appendRelativeTime = shared.appendRelativeTime;
const appendTemplate = shared.appendTemplate;
const isIssuePriority = cmd_common.isIssuePriority;
const sendPlainResponse = shared.sendPlainResponse;
const sendRedirect = shared.sendRedirect;
const percentDecodeForm = issues_page.percentDecodeForm;

pub const ProjectPageTab = enum {
    overview,
    table,
    board,
    roadmap,
    issues,
    activity,
};

const ProjectSummary = struct {
    id: []u8,
    name: []u8,
    description: []u8,
    state: []u8,
    status: []u8,
    status_occurred_at: []u8,
    priority: []u8,
    start_at: []u8,
    end_at: []u8,
    created_at: []u8,
    author_principal: []u8,

    fn deinit(self: *ProjectSummary, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.state);
        allocator.free(self.status);
        allocator.free(self.status_occurred_at);
        allocator.free(self.priority);
        allocator.free(self.start_at);
        allocator.free(self.end_at);
        allocator.free(self.created_at);
        allocator.free(self.author_principal);
    }
};

const ProjectMetrics = struct {
    issue_count: usize = 0,
    open_issue_count: usize = 0,
    closed_issue_count: usize = 0,
    started_issue_count: usize = 0,
    completed_issue_count: usize = 0,
    comment_count: usize = 0,
    member_count: usize = 0,
    label_count: usize = 0,
    milestone_count: usize = 0,
    closed_milestone_count: usize = 0,
    field_count: usize = 0,
    view_count: usize = 0,
};

const ProjectUpdateNote = struct {
    body: []u8,
    status: []u8,
    occurred_at: []u8,
    actor: []u8,

    fn deinit(self: *ProjectUpdateNote, allocator: Allocator) void {
        allocator.free(self.body);
        allocator.free(self.status);
        allocator.free(self.occurred_at);
        allocator.free(self.actor);
    }
};

pub fn appendProjectOverview(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    repo: Repo,
    db: *SqliteDb,
    project: []const u8,
) !void {
    _ = repo;
    var summary = try loadProjectSummary(allocator, db, project);
    defer summary.deinit(allocator);
    const metrics = try loadProjectMetrics(allocator, db, &summary);
    var update_note = try loadLatestProjectUpdateNote(allocator, db, &summary);
    defer update_note.deinit(allocator);

    try buf.appendSlice(allocator, "<section class=\"panel project-overview-page\">");
    try appendProjectOverviewHeader(buf, allocator, &summary, &metrics);
    try appendProjectPageTabs(buf, allocator, project, .overview, metrics.issue_count);
    try buf.appendSlice(allocator,
        \\<div class="project-overview-layout">
        \\  <div class="project-overview-main">
    );
    try appendProjectUpdateSection(buf, allocator, &summary, &update_note);
    try appendProjectDescription(buf, allocator, &summary);
    try buf.appendSlice(allocator,
        \\  </div>
        \\  <aside class="project-overview-sidebar">
    );
    try appendProjectPropertiesPanel(buf, allocator, db, &summary, &metrics);
    try appendProjectMilestones(buf, allocator, db, &summary, &metrics, .sidebar);
    try appendProjectProgressPanel(buf, allocator, &summary, &metrics);
    try appendProjectActivityPanel(buf, allocator, db, &summary, project);
    try buf.appendSlice(allocator,
        \\  </aside>
        \\</div>
        \\</section>
    );
}

pub fn appendProjectActivityView(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    repo: Repo,
    db: *SqliteDb,
    project: []const u8,
) !void {
    _ = repo;
    var summary = try loadProjectSummary(allocator, db, project);
    defer summary.deinit(allocator);
    const metrics = try loadProjectMetrics(allocator, db, &summary);

    try buf.appendSlice(allocator, "<section class=\"panel project-overview-page project-activity-page\">");
    try appendProjectOverviewHeader(buf, allocator, &summary, &metrics);
    try appendProjectPageTabs(buf, allocator, project, .activity, metrics.issue_count);
    try buf.appendSlice(allocator,
        \\<div class="project-overview-layout">
        \\  <div class="project-overview-main">
    );
    try appendProjectActivityMain(buf, allocator, db, &summary, project);
    try buf.appendSlice(allocator,
        \\  </div>
        \\  <aside class="project-overview-sidebar">
    );
    try appendProjectPropertiesPanel(buf, allocator, db, &summary, &metrics);
    try appendProjectMilestones(buf, allocator, db, &summary, &metrics, .sidebar);
    try appendProjectProgressPanel(buf, allocator, &summary, &metrics);
    try buf.appendSlice(allocator,
        \\  </aside>
        \\</div>
        \\</section>
    );
}

pub fn handleProjectPropertiesPost(allocator: Allocator, repo: Repo, stream: std.net.Stream, form_body: []const u8) !void {
    try index.ensureIndex(allocator, repo);

    const action_owned = try formTrimmedOwned(allocator, form_body, "action");
    defer allocator.free(action_owned);
    const project_ref_owned = try formTrimmedOwned(allocator, form_body, "project_id");
    defer allocator.free(project_ref_owned);
    const project_name_owned = try formTrimmedOwned(allocator, form_body, "project");
    defer allocator.free(project_name_owned);

    if (action_owned.len == 0) {
        try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Project property action is required\n");
        return;
    }

    const project_ref = if (project_ref_owned.len != 0) project_ref_owned else project_name_owned;
    if (project_ref.len == 0) {
        try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Project is required\n");
        return;
    }

    const project_id = index.resolveProjectId(allocator, repo, project_ref) catch {
        try sendPlainResponse(allocator, stream, 404, "Not Found", "Project not found\n");
        return;
    };
    defer allocator.free(project_id);

    if (std.mem.eql(u8, action_owned, "save-description")) {
        const description_owned = (try formValueOwned(allocator, form_body, "description")) orelse try allocator.dupe(u8, "");
        defer allocator.free(description_owned);
        if (try projectFormHashUnchanged(allocator, form_body, "project-description", "", description_owned)) {
            try redirectProjectOverview(allocator, stream, project_name_owned, project_ref);
            return;
        }
        if (!(try writeProjectUpdateOrFail(allocator, stream, project_id, .{ .description = description_owned }))) return;
    } else if (std.mem.eql(u8, action_owned, "add-update")) {
        const status_owned = try requiredProjectFormValue(allocator, stream, form_body, "status", "Status is required\n");
        const status = status_owned orelse return;
        defer allocator.free(status);
        if (!project_views.isProjectStatusValue(status)) {
            try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Status must be Draft, Todo, WIP, Review, Done, or Failed\n");
            return;
        }
        const body_owned = (try formValueOwned(allocator, form_body, "update_body")) orelse try allocator.dupe(u8, "");
        defer allocator.free(body_owned);
        const trimmed_body = std.mem.trim(u8, body_owned, " \t\r\n");
        const effective_body: []const u8 = if (trimmed_body.len == 0) "" else body_owned;
        if (try projectFormHashUnchanged(allocator, form_body, "project-update", status, effective_body)) {
            try redirectProjectOverview(allocator, stream, project_name_owned, project_ref);
            return;
        }
        const update_body: ?[]const u8 = if (effective_body.len == 0) null else effective_body;
        if (!(try writeProjectUpdateOrFail(allocator, stream, project_id, .{ .status = status, .update_body = update_body }))) return;
    } else if (std.mem.eql(u8, action_owned, "add-milestones")) {
        var milestone_refs = try formValuesOwned(allocator, form_body, "milestone");
        defer freeStringList(allocator, &milestone_refs);
        if (milestone_refs.items.len == 0) {
            try redirectProjectOverview(allocator, stream, project_name_owned, project_ref);
            return;
        }
        var milestone_ids: std.ArrayList([]const u8) = .empty;
        defer freeConstStringList(allocator, &milestone_ids);
        for (milestone_refs.items) |raw_milestone_ref| {
            const milestone_ref = std.mem.trim(u8, raw_milestone_ref, " \t\r\n");
            if (milestone_ref.len == 0) continue;
            const milestone_id = index.resolveMilestoneId(allocator, repo, milestone_ref) catch {
                try sendPlainResponse(allocator, stream, 404, "Not Found", "Milestone not found\n");
                return;
            };
            errdefer allocator.free(milestone_id);
            if (containsConstString(milestone_ids.items, milestone_id)) {
                allocator.free(milestone_id);
                continue;
            }
            try milestone_ids.append(allocator, milestone_id);
        }
        if (milestone_ids.items.len != 0) {
            if (!(try writeProjectUpdateOrFail(allocator, stream, project_id, .{ .milestones_added = milestone_ids.items }))) return;
        }
    } else if (std.mem.eql(u8, action_owned, "remove-milestone")) {
        const value_owned = try requiredProjectFormValue(allocator, stream, form_body, "value", "Milestone is required\n");
        const value = value_owned orelse return;
        defer allocator.free(value);
        const milestone_id = index.resolveMilestoneId(allocator, repo, value) catch {
            try sendPlainResponse(allocator, stream, 404, "Not Found", "Milestone not found\n");
            return;
        };
        defer allocator.free(milestone_id);
        const values = [_][]const u8{milestone_id};
        if (!(try writeProjectUpdateOrFail(allocator, stream, project_id, .{ .milestones_removed = values[0..] }))) return;
    } else if (std.mem.eql(u8, action_owned, "set-status")) {
        const status_owned = try requiredProjectFormValue(allocator, stream, form_body, "status", "Status is required\n");
        const status = status_owned orelse return;
        defer allocator.free(status);
        if (!project_views.isProjectStatusValue(status)) {
            try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Status must be Draft, Todo, WIP, Review, Done, or Failed\n");
            return;
        }
        if (!(try writeProjectUpdateOrFail(allocator, stream, project_id, .{ .status = status }))) return;
    } else if (std.mem.eql(u8, action_owned, "set-priority")) {
        const priority_owned = try requiredProjectFormValue(allocator, stream, form_body, "priority", "Priority is required\n");
        const priority = priority_owned orelse return;
        defer allocator.free(priority);
        if (!isIssuePriority(priority)) {
            try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Priority must be P0, P1, P2, or P3\n");
            return;
        }
        if (!(try writeProjectUpdateOrFail(allocator, stream, project_id, .{ .priority = priority }))) return;
    } else if (std.mem.eql(u8, action_owned, "set-dates")) {
        const start_owned = try requiredProjectFormValue(allocator, stream, form_body, "start_at", "Start date is required\n");
        const start_at = start_owned orelse return;
        defer allocator.free(start_at);
        const end_owned = try formTrimmedOwned(allocator, form_body, "end_at");
        defer allocator.free(end_owned);
        if (!isProjectDateValue(start_at) or !isProjectDateValue(end_owned)) {
            try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Dates must use YYYY-MM-DD\n");
            return;
        }
        if (end_owned.len != 0 and std.mem.order(u8, end_owned, start_at) != .gt) {
            try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "End date must be after start date\n");
            return;
        }
        if (!(try writeProjectUpdateOrFail(allocator, stream, project_id, .{ .start_at = start_at, .end_at = end_owned }))) return;
    } else if (std.mem.eql(u8, action_owned, "add-lead") or std.mem.eql(u8, action_owned, "remove-lead")) {
        const value_owned = try requiredProjectFormValue(allocator, stream, form_body, "value", "Lead is required\n");
        const value = value_owned orelse return;
        defer allocator.free(value);
        const values = [_][]const u8{value};
        var update = event_mod.ProjectUpdate{};
        if (std.mem.eql(u8, action_owned, "add-lead")) {
            update.leads_added = values[0..];
        } else {
            update.leads_removed = values[0..];
        }
        if (!(try writeProjectUpdateOrFail(allocator, stream, project_id, update))) return;
    } else if (std.mem.eql(u8, action_owned, "add-member") or std.mem.eql(u8, action_owned, "remove-member")) {
        const value_owned = try requiredProjectFormValue(allocator, stream, form_body, "value", "Member is required\n");
        const value = value_owned orelse return;
        defer allocator.free(value);
        const values = [_][]const u8{value};
        var update = event_mod.ProjectUpdate{};
        if (std.mem.eql(u8, action_owned, "add-member")) {
            update.members_added = values[0..];
        } else {
            update.members_removed = values[0..];
        }
        if (!(try writeProjectUpdateOrFail(allocator, stream, project_id, update))) return;
    } else if (std.mem.eql(u8, action_owned, "add-label") or std.mem.eql(u8, action_owned, "remove-label")) {
        const value_owned = try requiredProjectFormValue(allocator, stream, form_body, "value", "Label is required\n");
        const value = value_owned orelse return;
        defer allocator.free(value);
        const values = [_][]const u8{value};
        var update = event_mod.ProjectUpdate{};
        if (std.mem.eql(u8, action_owned, "add-label")) {
            update.labels_added = values[0..];
        } else {
            update.labels_removed = values[0..];
        }
        if (!(try writeProjectUpdateOrFail(allocator, stream, project_id, update))) return;
    } else {
        try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Unknown project property action\n");
        return;
    }

    try redirectProjectOverview(allocator, stream, project_name_owned, project_ref);
}

fn formTrimmedOwned(allocator: Allocator, form_body: []const u8, wanted_key: []const u8) ![]u8 {
    const owned = (try formValueOwned(allocator, form_body, wanted_key)) orelse try allocator.dupe(u8, "");
    defer allocator.free(owned);
    const trimmed = std.mem.trim(u8, owned, " \t\r\n");
    return try allocator.dupe(u8, trimmed);
}

fn formValuesOwned(allocator: Allocator, body: []const u8, wanted_key: []const u8) !std.ArrayList([]u8) {
    var values: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(allocator, &values);

    var pairs = std.mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const raw_key = pair[0..eq];
        const raw_value = if (eq < pair.len) pair[eq + 1 ..] else "";
        const key = try percentDecodeForm(allocator, raw_key);
        defer allocator.free(key);
        if (!std.mem.eql(u8, key, wanted_key)) continue;
        const value = try percentDecodeForm(allocator, raw_value);
        errdefer allocator.free(value);
        try values.append(allocator, value);
    }
    return values;
}

fn freeStringList(allocator: Allocator, values: *std.ArrayList([]u8)) void {
    for (values.items) |value| allocator.free(value);
    values.deinit(allocator);
}

fn freeConstStringList(allocator: Allocator, values: *std.ArrayList([]const u8)) void {
    for (values.items) |value| allocator.free(value);
    values.deinit(allocator);
}

fn containsConstString(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

fn requiredProjectFormValue(allocator: Allocator, stream: std.net.Stream, form_body: []const u8, name: []const u8, message: []const u8) !?[]u8 {
    const value_owned = try formTrimmedOwned(allocator, form_body, name);
    errdefer allocator.free(value_owned);
    if (value_owned.len == 0) {
        allocator.free(value_owned);
        try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", message);
        return null;
    }
    return value_owned;
}

fn writeProjectUpdateOrFail(allocator: Allocator, stream: std.net.Stream, project_id: []const u8, update: event_mod.ProjectUpdate) !bool {
    createProjectUpdatedEvent(allocator, project_id, update) catch {
        try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not update project properties\n");
        return false;
    };
    return true;
}

fn redirectProjectOverview(allocator: Allocator, stream: std.net.Stream, project_name: []const u8, fallback_ref: []const u8) !void {
    const location = try projectOverviewLocationOwned(allocator, project_name, fallback_ref);
    defer allocator.free(location);
    try sendRedirect(allocator, stream, location);
}

fn projectOverviewLocationOwned(allocator: Allocator, project_name: []const u8, fallback_ref: []const u8) ![]u8 {
    var location: std.ArrayList(u8) = .empty;
    errdefer location.deinit(allocator);
    try location.appendSlice(allocator, "/projects?project=");
    if (project_name.len != 0) {
        try shared.appendUrlEncoded(&location, allocator, project_name);
    } else {
        try shared.appendUrlEncoded(&location, allocator, fallback_ref);
    }
    return location.toOwnedSlice(allocator);
}

fn projectFormHashUnchanged(allocator: Allocator, form_body: []const u8, kind: []const u8, status: []const u8, body: []const u8) !bool {
    const previous_hash = try formTrimmedOwned(allocator, form_body, "previous_hash");
    defer allocator.free(previous_hash);
    if (previous_hash.len == 0) return false;
    const submitted_hash = try projectContentHashOwned(allocator, kind, status, body);
    defer allocator.free(submitted_hash);
    return std.mem.eql(u8, previous_hash, submitted_hash);
}

fn projectContentHashOwned(allocator: Allocator, kind: []const u8, status: []const u8, body: []const u8) ![]u8 {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(allocator);
    try source.appendSlice(allocator, kind);
    try source.append(allocator, 0);
    try source.appendSlice(allocator, status);
    try source.append(allocator, 0);
    try source.appendSlice(allocator, body);
    return try util.sha256Hex(allocator, source.items);
}

fn isProjectDateValue(value: []const u8) bool {
    if (value.len == 0) return true;
    if (value.len != 10) return false;
    for (value, 0..) |char, index_value| {
        if (index_value == 4 or index_value == 7) {
            if (char != '-') return false;
        } else if (!std.ascii.isDigit(char)) {
            return false;
        }
    }
    return true;
}

fn loadProjectSummary(allocator: Allocator, db: *SqliteDb, project: []const u8) !ProjectSummary {
    var stmt = try db.prepare(
        \\SELECT id, name, description, state, status, status_occurred_at, priority, start_at, end_at, created_at, author_principal
        \\FROM projects
        \\WHERE name = ?
        \\ORDER BY created_at DESC, id DESC
        \\LIMIT 1
    );
    defer stmt.deinit();
    try stmt.bindText(1, project);
    if (try stmt.step()) {
        return .{
            .id = try stmt.columnTextDup(allocator, 0),
            .name = try stmt.columnTextDup(allocator, 1),
            .description = try stmt.columnTextDup(allocator, 2),
            .state = try stmt.columnTextDup(allocator, 3),
            .status = try stmt.columnTextDup(allocator, 4),
            .status_occurred_at = try stmt.columnTextDup(allocator, 5),
            .priority = try stmt.columnTextDup(allocator, 6),
            .start_at = try stmt.columnTextDup(allocator, 7),
            .end_at = try stmt.columnTextDup(allocator, 8),
            .created_at = try stmt.columnTextDup(allocator, 9),
            .author_principal = try stmt.columnTextDup(allocator, 10),
        };
    }

    return .{
        .id = try allocator.dupe(u8, ""),
        .name = try allocator.dupe(u8, project),
        .description = try allocator.dupe(u8, ""),
        .state = try allocator.dupe(u8, "open"),
        .status = try allocator.dupe(u8, "WIP"),
        .status_occurred_at = try allocator.dupe(u8, ""),
        .priority = try allocator.dupe(u8, ""),
        .start_at = try allocator.dupe(u8, ""),
        .end_at = try allocator.dupe(u8, ""),
        .created_at = try allocator.dupe(u8, ""),
        .author_principal = try allocator.dupe(u8, ""),
    };
}

fn loadProjectMetrics(allocator: Allocator, db: *SqliteDb, summary: *const ProjectSummary) !ProjectMetrics {
    _ = allocator;
    var metrics = ProjectMetrics{};
    try loadProjectIssueCounts(db, summary.name, &metrics);
    try loadProjectMilestoneCounts(db, summary.id, &metrics);
    try loadProjectPropertyCounts(db, summary.id, &metrics);
    if (summary.id.len != 0) {
        metrics.field_count = try countProjectRows(db, "project_fields", summary.id, "state != 'removed'");
        metrics.view_count = try countProjectRows(db, "project_views", summary.id, "state != 'removed'");
    }
    return metrics;
}

fn projectItemsCte(comptime body: []const u8) []const u8 {
    return (
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
    ) ++ body;
}

fn loadProjectIssueCounts(db: *SqliteDb, project: []const u8, metrics: *ProjectMetrics) !void {
    var stmt = try db.prepare(projectItemsCte(
        \\SELECT
        \\  COUNT(DISTINCT i.id),
        \\  COUNT(DISTINCT CASE WHEN i.state = 'open' THEN i.id END),
        \\  COUNT(DISTINCT CASE WHEN i.state = 'closed' THEN i.id END),
        \\  COUNT(DISTINCT CASE
        \\    WHEN i.state = 'closed' OR COALESCE(m.status, '') IN ('WIP', 'Review', 'Done', 'Failed') THEN i.id
        \\  END),
        \\  COUNT(DISTINCT CASE
        \\    WHEN i.state = 'closed' OR COALESCE(m.status, '') = 'Done' THEN i.id
        \\  END),
        \\  COUNT(DISTINCT c.id)
        \\FROM project_items p
        \\JOIN issues i ON i.id = p.issue_id
        \\LEFT JOIN issue_metadata m ON m.issue_id = i.id
        \\LEFT JOIN comments c ON c.parent_kind = 'issue' AND c.parent_id = i.id
    ));
    defer stmt.deinit();
    try bindProjectNameTwice(&stmt, project);
    if (!(try stmt.step())) return;
    metrics.issue_count = @intCast(stmt.columnInt64(0));
    metrics.open_issue_count = @intCast(stmt.columnInt64(1));
    metrics.closed_issue_count = @intCast(stmt.columnInt64(2));
    metrics.started_issue_count = @intCast(stmt.columnInt64(3));
    metrics.completed_issue_count = @intCast(stmt.columnInt64(4));
    metrics.comment_count = @intCast(stmt.columnInt64(5));
}

fn loadProjectMilestoneCounts(db: *SqliteDb, project_id: []const u8, metrics: *ProjectMetrics) !void {
    if (project_id.len == 0) return;
    var stmt = try db.prepare(
        \\SELECT COUNT(DISTINCT pm.milestone_id),
        \\       COUNT(DISTINCT CASE WHEN m.state = 'closed' THEN pm.milestone_id END)
        \\FROM project_milestones pm
        \\JOIN milestones m ON m.id = pm.milestone_id
        \\WHERE pm.project_id = ?
    );
    defer stmt.deinit();
    try stmt.bindText(1, project_id);
    if (!(try stmt.step())) return;
    metrics.milestone_count = @intCast(stmt.columnInt64(0));
    metrics.closed_milestone_count = @intCast(stmt.columnInt64(1));
}

fn loadLatestProjectUpdateNote(allocator: Allocator, db: *SqliteDb, summary: *const ProjectSummary) !ProjectUpdateNote {
    if (summary.id.len == 0) return emptyProjectUpdateNote(allocator);

    var stmt = try db.prepare(
        \\SELECT body, actor_principal, occurred_at
        \\FROM events
        \\WHERE valid_json != 0
        \\  AND domain_status = 'accepted'
        \\  AND event_type = 'project.updated'
        \\  AND object_kind = 'project'
        \\  AND object_id = ?
        \\ORDER BY ordinal DESC
        \\LIMIT 25
    );
    defer stmt.deinit();
    try stmt.bindText(1, summary.id);

    while (try stmt.step()) {
        const body = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(body);
        const actor = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(actor);
        const occurred_at = try stmt.columnTextDup(allocator, 2);
        defer allocator.free(occurred_at);

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch continue;
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |object| object,
            else => continue,
        };
        const payload = switch (root.get("payload") orelse continue) {
            .object => |object| object,
            else => continue,
        };
        const update_body = event_mod.jsonString(payload.get("update_body"));
        const status = event_mod.jsonString(payload.get("status"));
        if (update_body == null and status == null) continue;
        return .{
            .body = try allocator.dupe(u8, update_body orelse ""),
            .status = try allocator.dupe(u8, status orelse ""),
            .occurred_at = try allocator.dupe(u8, occurred_at),
            .actor = try allocator.dupe(u8, actor),
        };
    }

    return emptyProjectUpdateNote(allocator);
}

fn emptyProjectUpdateNote(allocator: Allocator) !ProjectUpdateNote {
    return .{
        .body = try allocator.dupe(u8, ""),
        .status = try allocator.dupe(u8, ""),
        .occurred_at = try allocator.dupe(u8, ""),
        .actor = try allocator.dupe(u8, ""),
    };
}

fn loadProjectPropertyCounts(db: *SqliteDb, project_id: []const u8, metrics: *ProjectMetrics) !void {
    if (project_id.len == 0) return;
    metrics.member_count = try countProjectRows(db, "project_members", project_id, "member <> ''");
    metrics.label_count = try countProjectRows(db, "project_labels", project_id, "label <> ''");
}

fn countProjectRows(db: *SqliteDb, comptime table: []const u8, project_id: []const u8, comptime where_extra: []const u8) !usize {
    var stmt = try db.prepare("SELECT COUNT(*) FROM " ++ table ++ " WHERE project_id = ? AND " ++ where_extra);
    defer stmt.deinit();
    try stmt.bindText(1, project_id);
    if (!(try stmt.step())) return 0;
    return @intCast(stmt.columnInt64(0));
}

fn bindProjectNameTwice(stmt: *index.SqliteStmt, project: []const u8) !void {
    try stmt.bindText(1, project);
    try stmt.bindText(2, project);
}

fn appendProjectOverviewHeader(buf: *std.ArrayList(u8), allocator: Allocator, summary: *const ProjectSummary, metrics: *const ProjectMetrics) !void {
    const completion_label = try projectCompletionLabelOwned(allocator, metrics);
    defer allocator.free(completion_label);
    try appendTemplate(buf, allocator,
        \\<header class="project-overview-head">
        \\  <div class="project-overview-title">
        \\    <span class="project-overview-icon" aria-hidden="true"></span>
        \\    <div>
        \\      <p class="eyebrow">Project</p>
        \\      <h1>{project}</h1>
    , .{ .project = summary.name });
    if (summary.description.len != 0) {
        try appendTemplate(buf, allocator, "<p>{description}</p>", .{ .description = summary.description });
    }
    try appendTemplate(buf, allocator,
        \\    </div>
        \\  </div>
        \\  <div class="project-overview-head-stats" aria-label="Project issue summary">
        \\    <span><strong>{completion_label}</strong></span>
        \\    <span><strong>{issue_count}</strong> issues</span>
        \\    <span><strong>{open_count}</strong> open</span>
        \\    <span><strong>{closed_count}</strong> closed</span>
        \\  </div>
        \\</header>
    , .{
        .completion_label = completion_label,
        .issue_count = metrics.issue_count,
        .open_count = metrics.open_issue_count,
        .closed_count = metrics.closed_issue_count,
    });
}

fn projectCompletionLabelOwned(allocator: Allocator, metrics: *const ProjectMetrics) ![]u8 {
    if (metrics.milestone_count == 0) return allocator.dupe(u8, "No milestones");
    if (metrics.closed_milestone_count >= metrics.milestone_count) return allocator.dupe(u8, "Complete");
    return std.fmt.allocPrint(allocator, "{d}/{d} milestones done", .{
        metrics.closed_milestone_count,
        metrics.milestone_count,
    });
}

pub fn appendProjectPageTabs(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    project: []const u8,
    active: ProjectPageTab,
    issue_count: usize,
) !void {
    try buf.appendSlice(allocator,
        \\<div class="project-overview-tabs">
        \\  <nav class="project-overview-primary-tabs" aria-label="Project tabs">
    );
    try appendProjectPageTab(buf, allocator, project, active, .overview, "Overview", "project-view-overview-icon", "overview");
    try appendProjectPageTab(buf, allocator, project, active, .table, "Table", "project-view-table-icon", project_views.projectViewValue(.table));
    try appendProjectPageTab(buf, allocator, project, active, .board, "Board", "project-view-board-icon", project_views.projectViewValue(.board));
    try appendProjectPageTab(buf, allocator, project, active, .roadmap, "Roadmap", "project-view-roadmap-icon", project_views.projectViewValue(.roadmap));
    try appendProjectPageTab(buf, allocator, project, active, .issues, "Issues", "button-icon icon-issues", project_views.projectViewValue(.issues));
    try appendProjectPageTab(buf, allocator, project, active, .activity, "Activity", "button-icon icon-history", "activity");
    _ = issue_count;
    try buf.appendSlice(allocator,
        \\  </nav>
        \\</div>
    );
}

fn appendProjectPageTab(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    project: []const u8,
    active: ProjectPageTab,
    tab: ProjectPageTab,
    label: []const u8,
    icon_class: []const u8,
    view_ref: []const u8,
) !void {
    if (active == tab) {
        try appendTemplate(buf, allocator,
            \\<span class="project-overview-tab active"><span class="{icon_class}" aria-hidden="true"></span>{label}</span>
        , .{
            .icon_class = icon_class,
            .label = label,
        });
        return;
    }

    try buf.appendSlice(allocator, "<a class=\"project-overview-tab\" href=\"");
    if (tab == .overview) {
        try appendProjectOverviewHref(buf, allocator, project);
    } else {
        try appendProjectViewHref(buf, allocator, project, view_ref);
    }
    try buf.appendSlice(allocator, "\">");
    try appendTemplate(buf, allocator,
        \\<span class="{icon_class}" aria-hidden="true"></span>{label}</a>
    , .{
        .icon_class = icon_class,
        .label = label,
    });
}

fn appendProjectInlineProperties(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, summary: *const ProjectSummary, metrics: *const ProjectMetrics) !void {
    const health_label = projectHealthLabel(summary.status, summary.state);
    const health_tone = projectHealthTone(summary.status, summary.state);
    const progress = projectProgressPercent(metrics);
    const progress_degrees = projectProgressDegrees(metrics);
    const leads_label = try projectCollectionPreviewOwned(allocator, db, "project_leads", "lead", summary.id, "No lead");
    defer allocator.free(leads_label);
    const target_label = try projectTargetDateLabelOwned(allocator, summary);
    defer allocator.free(target_label);
    try appendTemplate(buf, allocator,
        \\<section class="panel project-summary-panel" aria-label="Project summary">
        \\  <article class="project-summary-row issue-list-row tone-{health_tone}">
        \\    <div class="issue-state-cell"><span class="issue-state-icon project-summary-health-icon {health_icon_state} tone-{health_tone}" title="{health_label}" aria-label="{health_label}"></span></div>
        \\    <div class="issue-row-content">
        \\      <div class="issue-row-title-line project-summary-title-line"><span class="project-summary-kicker">Health</span><strong class="project-summary-health-value tone-{health_tone}">{health_label}
    , .{
        .health_icon_state = projectHealthIconState(health_tone),
        .health_tone = health_tone,
        .health_label = health_label,
    });
    if (summary.status_occurred_at.len != 0) {
        try buf.appendSlice(allocator, "<span aria-hidden=\"true\"> &middot; </span>");
        try appendRelativeTime(buf, allocator, summary.status_occurred_at);
    }
    try buf.appendSlice(allocator,
        \\</strong></div>
        \\      <div class="project-summary-fields">
    );
    try appendProjectSummaryField(buf, allocator, "Priority", "project-overview-priority-icon", prioritySummaryLabel(summary.priority), project_issue_render.priorityTone(summary.priority));
    try appendProjectSummaryField(buf, allocator, "Lead", "icon-users", leads_label, "");
    try appendProjectSummaryField(buf, allocator, "Target date", "icon-calendar", target_label, "");
    try appendProjectSummaryFieldValue(buf, allocator, "Issues", "icon-issues", metrics.issue_count, "");
    try buf.appendSlice(allocator,
        \\      </div>
        \\    </div>
        \\    <div class="issue-row-side project-summary-side">
        \\      <span class="project-summary-side-label">Status</span>
    );
    try appendTemplate(buf, allocator,
        \\      <strong class="project-summary-progress tone-{tone}" title="{closed_count} of {issue_count} issues closed" style="--issue-task-progress: {progress_degrees}deg"><span class="issue-task-progress-icon project-summary-progress-icon" aria-hidden="true"></span>{progress}%</strong>
        \\    </div>
        \\  </article>
        \\</section>
    , .{
        .tone = projectProgressTone(metrics),
        .closed_count = metrics.closed_issue_count,
        .issue_count = metrics.issue_count,
        .progress_degrees = progress_degrees,
        .progress = progress,
    });
}

fn appendProjectSummaryField(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    label: []const u8,
    icon_class: []const u8,
    value: []const u8,
    tone: []const u8,
) !void {
    try appendTemplate(buf, allocator,
        \\<div class="project-summary-field">
        \\  <span>{label}</span>
        \\  <strong class="{tone_class}"><span class="button-icon {icon_class}" aria-hidden="true"></span>{value}</strong>
        \\</div>
    , .{
        .label = label,
        .tone_class = projectSummaryValueClass(tone),
        .icon_class = icon_class,
        .value = value,
    });
}

fn appendProjectSummaryFieldValue(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    label: []const u8,
    icon_class: []const u8,
    value: usize,
    tone: []const u8,
) !void {
    const value_label = try std.fmt.allocPrint(allocator, "{d}", .{value});
    defer allocator.free(value_label);
    try appendProjectSummaryField(buf, allocator, label, icon_class, value_label, tone);
}

fn projectSummaryValueClass(tone: []const u8) []const u8 {
    if (std.mem.eql(u8, tone, "progress")) return "project-summary-value tone-progress";
    if (std.mem.eql(u8, tone, "done")) return "project-summary-value tone-done";
    if (std.mem.eql(u8, tone, "failed")) return "project-summary-value tone-failed";
    if (std.mem.eql(u8, tone, "p0")) return "project-summary-value tone-p0";
    if (std.mem.eql(u8, tone, "p1")) return "project-summary-value tone-p1";
    if (std.mem.eql(u8, tone, "p2")) return "project-summary-value tone-p2";
    if (std.mem.eql(u8, tone, "p3")) return "project-summary-value tone-p3";
    return "project-summary-value";
}

fn projectHealthLabel(status: []const u8, state: []const u8) []const u8 {
    if (std.mem.eql(u8, state, "closed") or std.mem.eql(u8, status, "Done")) return "Complete";
    if (std.mem.eql(u8, status, "Failed")) return "At risk";
    if (status.len == 0 or std.mem.eql(u8, status, "Draft") or std.mem.eql(u8, status, "Todo")) return "Not started";
    return "On track";
}

fn projectHealthTone(status: []const u8, state: []const u8) []const u8 {
    if (std.mem.eql(u8, state, "closed") or std.mem.eql(u8, status, "Done")) return "done";
    if (std.mem.eql(u8, status, "Failed")) return "failed";
    if (status.len == 0 or std.mem.eql(u8, status, "Draft") or std.mem.eql(u8, status, "Todo")) return "todo";
    return "progress";
}

fn projectProgressPercent(metrics: *const ProjectMetrics) usize {
    return projectProgressPercentFrom(metrics.closed_issue_count, metrics.issue_count);
}

fn projectProgressTone(metrics: *const ProjectMetrics) []const u8 {
    if (metrics.issue_count != 0 and metrics.closed_issue_count >= metrics.issue_count) return "done";
    if (metrics.closed_issue_count == 0) return "todo";
    return "progress";
}

fn projectProgressDegrees(metrics: *const ProjectMetrics) usize {
    if (metrics.issue_count == 0) return 0;
    return (@min(metrics.closed_issue_count, metrics.issue_count) * 360) / metrics.issue_count;
}

fn projectHealthIconState(tone: []const u8) []const u8 {
    if (std.mem.eql(u8, tone, "done")) return "closed";
    return "open";
}

fn projectProgressPercentFrom(completed: usize, total: usize) usize {
    if (total == 0) return 0;
    return (@min(completed, total) * 100) / total;
}

fn appendProjectResources(buf: *std.ArrayList(u8), allocator: Allocator, project: []const u8) !void {
    try buf.appendSlice(allocator,
        \\<section class="project-overview-section project-overview-resources">
        \\  <div class="project-overview-section-title">
        \\    <h2>Resources</h2>
        \\    <span class="project-overview-add" aria-hidden="true">+</span>
        \\  </div>
        \\  <div class="project-overview-resource-links">
    );
    try appendProjectResourceLink(buf, allocator, project, .table, "Table", "project-view-table-icon");
    try appendProjectResourceLink(buf, allocator, project, .board, "Board", "project-view-board-icon");
    try appendProjectResourceLink(buf, allocator, project, .roadmap, "Roadmap", "project-view-roadmap-icon");
    try buf.appendSlice(allocator,
        \\  </div>
        \\</section>
    );
}

fn appendProjectResourceLink(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    project: []const u8,
    view: project_views.ProjectView,
    label: []const u8,
    icon_class: []const u8,
) !void {
    try buf.appendSlice(allocator, "<a class=\"project-overview-resource-link\" href=\"");
    try appendProjectViewHref(buf, allocator, project, project_views.projectViewValue(view));
    try buf.appendSlice(allocator, "\">");
    try appendTemplate(buf, allocator,
        \\<span class="{icon_class}" aria-hidden="true"></span>{label}</a>
    , .{
        .icon_class = icon_class,
        .label = label,
    });
}

fn appendProjectUpdateSection(buf: *std.ArrayList(u8), allocator: Allocator, summary: *const ProjectSummary, note: *const ProjectUpdateNote) !void {
    const effective_status = if (note.status.len != 0) note.status else summary.status;
    const health_label = projectUpdateHealthLabel(effective_status, summary.state);
    const health_tone = projectUpdateHealthTone(effective_status, summary.state);
    try buf.appendSlice(allocator,
        \\<section class="project-overview-section project-markdown-section project-update-section">
        \\  <details class="project-markdown-edit project-update-edit">
        \\    <summary class="button secondary project-update-button"><span class="button-icon project-update-button-icon" aria-hidden="true"></span><span>Update</span></summary>
        \\    <form class="project-markdown-form" method="post" action="/projects/properties" data-project-markdown-form data-project-content-kind="project-update">
    );
    try appendProjectHiddenFields(buf, allocator, summary);
    try appendProjectHashFields(buf, allocator, "project-update", effective_status, note.body);
    try buf.appendSlice(allocator,
        \\      <input type="hidden" name="action" value="add-update">
    );
    try appendProjectStatusSelect(buf, allocator, effective_status);
    try shared.appendMarkdownEditor(buf, allocator, .{
        .name = "update_body",
        .rows = 6,
        .placeholder = "Write a project update",
        .value = note.body,
        .required = false,
    });
    try appendTemplate(buf, allocator,
        \\      <div class="project-markdown-actions"><button class="project-markdown-cancel" type="button" data-project-markdown-cancel>Cancel</button><button type="submit">Save update</button></div>
        \\    </form>
        \\  </details>
        \\  <div class="project-overview-section-title project-update-section-title"><h2>Latest update</h2></div>
        \\  <article class="project-update-card project-markdown-preview tone-{health_tone}">
        \\    <header class="project-update-card-head">
        \\      <div class="project-update-card-meta">
    , .{ .health_tone = health_tone });
    try appendProjectUpdateHealthChip(buf, allocator, health_label, health_tone);
    if (note.actor.len != 0) {
        try project_issue_render.appendIssueAvatar(buf, allocator, note.actor, "project-update-avatar");
        try appendTemplate(buf, allocator, "<strong>{actor}</strong>", .{ .actor = note.actor });
    } else if (note.occurred_at.len != 0) {
        try buf.appendSlice(allocator, "<strong>Unknown</strong>");
    }
    if (note.occurred_at.len != 0) {
        try buf.appendSlice(allocator, "<span>");
        try appendRelativeTime(buf, allocator, note.occurred_at);
        try buf.appendSlice(allocator, "</span>");
    }
    try buf.appendSlice(allocator,
        \\      </div>
        \\    </header>
        \\    <div class="project-update-body markdown-body">
    );
    if (note.body.len == 0) {
        try buf.appendSlice(allocator, "<p class=\"project-markdown-empty\">No update yet.</p>");
    } else {
        try shared.appendMarkdownSource(buf, allocator, note.body, .{});
    }
    try buf.appendSlice(allocator,
        \\    </div>
        \\    <footer class="project-update-actions" aria-label="Update actions">
        \\      <button class="project-update-action" type="button"><span class="issue-comments-icon" aria-hidden="true"></span><span>Reply</span></button>
        \\      <button class="project-update-action" type="button"><span class="reaction-add-icon" aria-hidden="true"></span><span>React</span></button>
        \\    </footer>
        \\  </article>
        \\</section>
    );
}

fn appendProjectDescription(buf: *std.ArrayList(u8), allocator: Allocator, summary: *const ProjectSummary) !void {
    try buf.appendSlice(allocator,
        \\<section class="project-overview-section project-markdown-section project-description-section">
        \\  <details class="project-markdown-edit project-description-edit">
        \\    <summary class="button secondary project-update-button" aria-label="Edit description" title="Edit description"><span class="button-icon project-update-button-icon" aria-hidden="true"></span><span>Edit</span></summary>
        \\    <form class="project-markdown-form" method="post" action="/projects/properties" data-project-markdown-form data-project-content-kind="project-description">
    );
    try appendProjectHiddenFields(buf, allocator, summary);
    try buf.appendSlice(allocator, "<input type=\"hidden\" name=\"action\" value=\"save-description\">");
    try appendProjectHashFields(buf, allocator, "project-description", "", summary.description);
    try shared.appendMarkdownEditor(buf, allocator, .{
        .name = "description",
        .rows = 8,
        .placeholder = "Write a project description",
        .value = summary.description,
        .required = false,
    });
    try buf.appendSlice(allocator,
        \\      <div class="project-markdown-actions"><button class="project-markdown-cancel" type="button" data-project-markdown-cancel>Cancel</button><button type="submit">Save description</button></div>
        \\    </form>
        \\  </details>
        \\  <div class="project-overview-section-title project-description-section-title"><h2>Description</h2></div>
        \\  <article class="project-description-card project-markdown-preview">
        \\    <div class="project-overview-description project-description-body markdown-body">
    );
    if (summary.description.len == 0) {
        try buf.appendSlice(allocator, "<p class=\"project-markdown-empty\">No description yet.</p>");
    } else {
        try shared.appendMarkdownSource(buf, allocator, summary.description, .{});
    }
    try buf.appendSlice(allocator,
        \\    </div>
        \\  </article>
        \\</section>
    );
}

fn appendProjectStatusSelect(buf: *std.ArrayList(u8), allocator: Allocator, selected_status: []const u8) !void {
    const selected_health = projectUpdateHealthStatusValue(selected_status);
    const options = [_]struct {
        value: []const u8,
        label: []const u8,
        tone: []const u8,
    }{
        .{ .value = "WIP", .label = "On track", .tone = "progress" },
        .{ .value = "Review", .label = "At risk", .tone = "risk" },
        .{ .value = "Failed", .label = "Off track", .tone = "failed" },
    };
    try buf.appendSlice(allocator,
        \\<fieldset class="project-update-status-field">
        \\  <legend>Status</legend>
        \\  <details class="project-update-status-menu" data-popover-menu data-project-status-menu>
        \\    <summary class="project-update-status-control" aria-label="Status">
    );
    for (options) |option| {
        try appendTemplate(buf, allocator,
            \\<span class="project-update-status-selected project-update-status-selected-{class}">
        , .{ .class = projectUpdateStatusValueClass(option.value) });
        try appendProjectUpdateHealthChip(buf, allocator, option.label, option.tone);
        try buf.appendSlice(allocator, "</span>");
    }
    try buf.appendSlice(allocator,
        \\      <span class="project-update-status-chevron" aria-hidden="true"></span>
        \\    </summary>
        \\    <div class="project-update-status-options" role="radiogroup" aria-label="Status">
    );
    for (options) |option| {
        try appendTemplate(buf, allocator,
            \\<label class="project-update-status-option tone-{tone}">
            \\  <input type="radio" name="status" value="{status}" required
        , .{
            .tone = option.tone,
            .status = option.value,
        });
        if (std.mem.eql(u8, selected_health, option.value)) try buf.appendSlice(allocator, " checked");
        try buf.appendSlice(allocator, ">");
        try appendProjectUpdateHealthChip(buf, allocator, option.label, option.tone);
        try buf.appendSlice(allocator,
            \\  <span class="project-update-status-check" aria-hidden="true"></span>
            \\</label>
        );
    }
    try buf.appendSlice(allocator,
        \\    </div>
        \\  </details>
        \\</fieldset>
    );
}

fn projectUpdateStatusValueClass(value: []const u8) []const u8 {
    if (std.mem.eql(u8, value, "Failed")) return "failed";
    if (std.mem.eql(u8, value, "Review")) return "review";
    return "wip";
}

fn appendProjectUpdateHealthChip(buf: *std.ArrayList(u8), allocator: Allocator, label: []const u8, tone: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<span class="issue-state-badge project-update-health-chip tone-{tone}"><span class="issue-state-mark" aria-hidden="true"></span>{label}</span>
    , .{
        .tone = tone,
        .label = label,
    });
}

fn projectUpdateHealthStatusValue(status: []const u8) []const u8 {
    if (std.mem.eql(u8, status, "Failed")) return "Failed";
    if (std.mem.eql(u8, status, "Review") or std.mem.eql(u8, status, "Draft") or std.mem.eql(u8, status, "Todo")) return "Review";
    return "WIP";
}

fn projectUpdateHealthLabel(status: []const u8, state: []const u8) []const u8 {
    _ = state;
    const health_status = projectUpdateHealthStatusValue(status);
    if (std.mem.eql(u8, health_status, "Failed")) return "Off track";
    if (std.mem.eql(u8, health_status, "Review")) return "At risk";
    return "On track";
}

fn projectUpdateHealthTone(status: []const u8, state: []const u8) []const u8 {
    _ = state;
    const health_status = projectUpdateHealthStatusValue(status);
    if (std.mem.eql(u8, health_status, "Failed")) return "failed";
    if (std.mem.eql(u8, health_status, "Review")) return "risk";
    return "progress";
}

fn appendProjectHashFields(buf: *std.ArrayList(u8), allocator: Allocator, kind: []const u8, status: []const u8, body: []const u8) !void {
    const hash = try projectContentHashOwned(allocator, kind, status, body);
    defer allocator.free(hash);
    try appendTemplate(buf, allocator,
        \\<input type="hidden" name="previous_hash" value="{hash}" data-project-previous-hash><input type="hidden" name="current_hash" value="{hash}" data-project-current-hash>
    , .{ .hash = hash });
}

const MilestonePlacement = enum {
    main,
    sidebar,
};

fn appendProjectMilestones(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    summary: *const ProjectSummary,
    metrics: *const ProjectMetrics,
    placement: MilestonePlacement,
) !void {
    const completion_label = try projectCompletionLabelOwned(allocator, metrics);
    defer allocator.free(completion_label);
    switch (placement) {
        .main => try buf.appendSlice(allocator,
            \\<section class="project-overview-section project-overview-milestones-main">
            \\  <div class="project-overview-section-title">
            \\    <div><h2>Milestones</h2><p class="project-overview-section-meta">
        ),
        .sidebar => try buf.appendSlice(allocator,
            \\<section class="project-overview-side-panel project-overview-milestones-side">
            \\  <div class="project-overview-side-panel-head"><div><h2>Milestones</h2><span class="project-overview-side-kicker">
        ),
    }
    try shared.appendHtml(buf, allocator, completion_label);
    switch (placement) {
        .main => try buf.appendSlice(allocator,
            \\</p></div>
        ),
        .sidebar => try buf.appendSlice(allocator,
            \\</span></div>
        ),
    }
    try appendProjectMilestonePicker(buf, allocator, db, summary);
    switch (placement) {
        .main => try buf.appendSlice(allocator,
            \\  </div>
            \\  <div class="project-overview-milestone-list">
        ),
        .sidebar => try buf.appendSlice(allocator,
            \\  </div>
            \\  <div class="project-overview-milestone-list">
        ),
    }

    if (summary.id.len == 0) {
        try buf.appendSlice(allocator, "<p class=\"project-overview-empty\">No milestones assigned.</p></div></section>");
        return;
    }

    var stmt = try db.prepare(projectItemsCte(
        \\SELECT
        \\  m.title,
        \\  COUNT(DISTINCT i.id),
        \\  COUNT(DISTINCT CASE WHEN i.state = 'closed' THEN i.id END),
        \\  COALESCE(NULLIF(m.due_at, ''), ''),
        \\  m.id,
        \\  m.state
        \\FROM project_milestones pm
        \\JOIN milestones m ON m.id = pm.milestone_id
        \\LEFT JOIN issue_metadata im ON lower(im.milestone) = lower(m.title)
        \\LEFT JOIN project_items p ON p.issue_id = im.issue_id
        \\LEFT JOIN issues i ON i.id = p.issue_id
        \\WHERE pm.project_id = ?
        \\GROUP BY m.id, m.title, m.state, m.due_at
        \\ORDER BY
        \\  CASE WHEN m.state = 'closed' THEN 1 ELSE 0 END,
        \\  CASE WHEN COALESCE(NULLIF(m.due_at, ''), '') = '' THEN 1 ELSE 0 END,
        \\  COALESCE(NULLIF(m.due_at, ''), ''),
        \\  lower(m.title),
        \\  m.title
        \\LIMIT 6
    ));
    defer stmt.deinit();
    try bindProjectNameTwice(&stmt, summary.name);
    try stmt.bindText(3, summary.id);

    var shown: usize = 0;
    while (try stmt.step()) {
        const title = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(title);
        const total: usize = @intCast(stmt.columnInt64(1));
        const closed: usize = @intCast(stmt.columnInt64(2));
        const due_at = try stmt.columnTextDup(allocator, 3);
        defer allocator.free(due_at);
        const milestone_id = try stmt.columnTextDup(allocator, 4);
        defer allocator.free(milestone_id);
        const state = try stmt.columnTextDup(allocator, 5);
        defer allocator.free(state);
        try appendProjectMilestoneRow(buf, allocator, title, milestone_id, state, total, closed, due_at, placement);
        shown += 1;
    }
    if (shown == 0) {
        try buf.appendSlice(allocator, "<p class=\"project-overview-empty\">No milestones assigned.</p>");
    }
    try buf.appendSlice(allocator, "</div></section>");
}

fn appendProjectMilestonePicker(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, summary: *const ProjectSummary) !void {
    try buf.appendSlice(allocator,
        \\<details class="project-milestone-picker" data-popover-menu data-issue-sidebar-menu>
        \\  <summary class="project-overview-add" aria-label="Add milestones" title="Add milestones"><span class="project-add-icon" aria-hidden="true"></span></summary>
        \\  <div class="issue-sidebar-popover project-milestone-popover" role="dialog" aria-label="Add milestones">
        \\    <div class="issue-sidebar-popover-title">Add milestones</div>
        \\    <label class="issue-sidebar-menu-input issue-sidebar-menu-filter"><span aria-hidden="true"></span><input placeholder="Filter milestones" aria-label="Filter milestones" autocomplete="off" data-issue-sidebar-filter></label>
    );
    try appendProjectMilestoneSelectedGroup(buf, allocator, db, summary);
    try appendProjectMilestoneCandidateForm(buf, allocator, db, summary);
    try buf.appendSlice(allocator, "</div></details>");
}

fn appendProjectMilestoneSelectedGroup(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, summary: *const ProjectSummary) !void {
    try appendProjectMenuGroupStart(buf, allocator, "Selected milestones");
    if (summary.id.len == 0) {
        try appendProjectMenuEmpty(buf, allocator, "No milestones selected.");
        try appendProjectMenuGroupEnd(buf, allocator);
        return;
    }

    var selected = try db.prepare(
        \\SELECT m.id, m.title, m.state
        \\FROM project_milestones pm
        \\JOIN milestones m ON m.id = pm.milestone_id
        \\WHERE pm.project_id = ?
        \\ORDER BY
        \\  CASE WHEN m.state = 'closed' THEN 1 ELSE 0 END,
        \\  lower(m.title),
        \\  m.title
    );
    defer selected.deinit();
    try selected.bindText(1, summary.id);
    var shown = false;
    while (try selected.step()) {
        const milestone_id = try selected.columnTextDup(allocator, 0);
        defer allocator.free(milestone_id);
        const title = try selected.columnTextDup(allocator, 1);
        defer allocator.free(title);
        const state = try selected.columnTextDup(allocator, 2);
        defer allocator.free(state);
        try appendProjectMilestoneRemoveRow(buf, allocator, summary, milestone_id, title, state);
        shown = true;
    }
    if (!shown) try appendProjectMenuEmpty(buf, allocator, "No milestones selected.");
    try appendProjectMenuGroupEnd(buf, allocator);
}

fn appendProjectMilestoneCandidateForm(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, summary: *const ProjectSummary) !void {
    try buf.appendSlice(allocator, "<form class=\"project-milestone-check-form\" method=\"post\" action=\"/projects/properties\">");
    try appendProjectHiddenFields(buf, allocator, summary);
    try buf.appendSlice(allocator, "<input type=\"hidden\" name=\"action\" value=\"add-milestones\">");
    try appendProjectMenuGroupStart(buf, allocator, "Milestones");

    var candidates = try db.prepare(
        \\SELECT id, title, state, COALESCE(NULLIF(due_at, ''), '')
        \\FROM milestones
        \\WHERE id NOT IN (SELECT milestone_id FROM project_milestones WHERE project_id = ?)
        \\ORDER BY
        \\  CASE WHEN state = 'closed' THEN 1 ELSE 0 END,
        \\  CASE WHEN COALESCE(NULLIF(due_at, ''), '') = '' THEN 1 ELSE 0 END,
        \\  COALESCE(NULLIF(due_at, ''), ''),
        \\  lower(title),
        \\  title
        \\LIMIT 50
    );
    defer candidates.deinit();
    try candidates.bindText(1, summary.id);
    var shown = false;
    while (try candidates.step()) {
        const milestone_id = try candidates.columnTextDup(allocator, 0);
        defer allocator.free(milestone_id);
        const title = try candidates.columnTextDup(allocator, 1);
        defer allocator.free(title);
        const state = try candidates.columnTextDup(allocator, 2);
        defer allocator.free(state);
        const due_at = try candidates.columnTextDup(allocator, 3);
        defer allocator.free(due_at);
        try appendProjectMilestoneCheckRow(buf, allocator, milestone_id, title, state, due_at);
        shown = true;
    }
    if (!shown) try appendProjectMenuEmpty(buf, allocator, "No available milestones.");
    try appendProjectMenuGroupEnd(buf, allocator);
    if (shown) {
        try buf.appendSlice(allocator, "<div class=\"project-milestone-check-actions\"><button type=\"submit\">Add selected</button></div>");
    }
    try buf.appendSlice(allocator, "</form>");
}

fn appendProjectMilestoneRemoveRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    summary: *const ProjectSummary,
    milestone_id: []const u8,
    title: []const u8,
    state: []const u8,
) !void {
    try buf.appendSlice(allocator, "<form class=\"issue-sidebar-picker-form\" method=\"post\" action=\"/projects/properties\">");
    try appendProjectHiddenFields(buf, allocator, summary);
    try appendTemplate(buf, allocator,
        \\<input type="hidden" name="action" value="remove-milestone"><input type="hidden" name="value" value="{milestone_id}"><button class="issue-sidebar-picker-row is-selected project-milestone-picker-row" type="submit" data-sidebar-filter-text="{title} {state}"><span class="issue-sidebar-picker-check" aria-hidden="true"></span><span class="button-icon icon-milestones" aria-hidden="true"></span><span class="issue-sidebar-picker-primary">{title}</span><span class="issue-sidebar-picker-secondary">{state}</span></button></form>
    , .{
        .milestone_id = milestone_id,
        .title = title,
        .state = milestoneStateLabel(state),
    });
}

fn appendProjectMilestoneCheckRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    milestone_id: []const u8,
    title: []const u8,
    state: []const u8,
    due_at: []const u8,
) !void {
    try appendTemplate(buf, allocator,
        \\<label class="project-milestone-check-row" data-sidebar-filter-text="{title} {state}">
        \\  <input type="checkbox" name="milestone" value="{milestone_id}">
        \\  <span class="button-icon icon-milestones" aria-hidden="true"></span>
        \\  <span class="project-milestone-check-text"><strong>{title}</strong><span>{state}
    , .{
        .milestone_id = milestone_id,
        .title = title,
        .state = milestoneStateLabel(state),
    });
    if (due_at.len != 0) {
        const due_label = try dateLabelOwned(allocator, due_at);
        defer allocator.free(due_label);
        try appendTemplate(buf, allocator, " · {due_label}", .{ .due_label = due_label });
    }
    try buf.appendSlice(allocator, "</span></span></label>");
}

fn appendProjectMilestoneRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    title: []const u8,
    milestone_id: []const u8,
    state: []const u8,
    total: usize,
    closed: usize,
    due_at: []const u8,
    placement: MilestonePlacement,
) !void {
    const progress = if (total == 0) 0 else (closed * 100) / total;
    const complete = std.mem.eql(u8, state, "closed");
    try appendTemplate(buf, allocator,
        \\<article class="{classes}">
        \\  <span class="button-icon icon-milestones" aria-hidden="true"></span>
        \\  <div>
    , .{
        .classes = shared.classes("project-overview-milestone-row", &.{shared.class("is-complete", complete)}),
    });
    if (milestone_id.len != 0) {
        var ref_buf: [8]u8 = undefined;
        const milestone_ref = util.objectRefPrefix(ref_buf[0..], milestone_id);
        try appendTemplate(buf, allocator,
            \\    <a href="/milestones/{milestone_ref}"><strong>{title}</strong></a>
        , .{
            .milestone_ref = milestone_ref,
            .title = title,
        });
    } else {
        try appendTemplate(buf, allocator,
            \\    <strong>{title}</strong>
        , .{ .title = title });
    }
    try appendTemplate(buf, allocator,
        \\    <span>{closed}/{total} issues
    , .{
        .closed = closed,
        .total = total,
    });
    if (due_at.len != 0) {
        const due_label = try dateLabelOwned(allocator, due_at);
        defer allocator.free(due_label);
        try appendTemplate(buf, allocator, " · {due_label}", .{ .due_label = due_label });
    }
    try appendTemplate(buf, allocator,
        \\</span>
        \\  </div>
    , .{});
    if (placement == .main) {
        try appendTemplate(buf, allocator,
            \\  <span class="project-overview-progress" style="--progress: {progress};" aria-label="{progress}% complete"></span>
        , .{ .progress = shared.percent(progress, 100) });
    }
    try buf.appendSlice(allocator, "</article>");
}

fn appendProjectPropertiesPanel(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, summary: *const ProjectSummary, metrics: *const ProjectMetrics) !void {
    try buf.appendSlice(allocator,
        \\<section class="project-overview-side-panel">
        \\  <div class="project-overview-side-panel-head"><h2>Properties</h2></div>
        \\  <dl class="project-overview-side-properties">
    );
    try appendProjectStatusProperty(buf, allocator, summary);
    try appendProjectPriorityProperty(buf, allocator, summary);
    try appendProjectPeopleProperty(buf, allocator, db, summary, "Lead", "icon-users", "project_leads", "lead", "add-lead", "remove-lead", "Add lead", "Filter leads", "No lead");
    const members_label = try countLabelOwned(allocator, metrics.member_count, "member", "members");
    defer allocator.free(members_label);
    const issues_label = try countLabelOwned(allocator, metrics.issue_count, "issue", "issues");
    defer allocator.free(issues_label);
    try appendProjectPeopleProperty(buf, allocator, db, summary, "Members", "icon-users", "project_members", "member", "add-member", "remove-member", "Add member", "Filter members", members_label);
    try appendSidebarProperty(buf, allocator, "Issues", "icon-issues", issues_label);
    const date_label = try projectDatesLabelOwned(allocator, summary);
    defer allocator.free(date_label);
    try appendProjectDatesProperty(buf, allocator, summary, date_label);
    try appendProjectLabelsProperty(buf, allocator, db, summary, metrics);
    try buf.appendSlice(allocator,
        \\  </dl>
        \\</section>
    );
}

fn appendProjectProgressPanel(buf: *std.ArrayList(u8), allocator: Allocator, summary: *const ProjectSummary, metrics: *const ProjectMetrics) !void {
    const progress = projectProgressPercentFrom(metrics.completed_issue_count, metrics.issue_count);
    const start_label = if (summary.start_at.len != 0) try dateLabelOwned(allocator, summary.start_at) else try allocator.dupe(u8, "Start");
    defer allocator.free(start_label);
    const target_label = if (summary.end_at.len != 0) try dateLabelOwned(allocator, summary.end_at) else try allocator.dupe(u8, "Target");
    defer allocator.free(target_label);

    try appendTemplate(buf, allocator,
        \\<section class="project-overview-side-panel project-progress-panel">
        \\  <div class="project-overview-side-panel-head"><div><h2>Progress</h2><span class="project-overview-side-kicker">{progress}% complete</span></div></div>
        \\  <div class="project-progress-body" style="--started: {started_percent}; --completed: {completed_percent};">
        \\    <div class="project-progress-stats">
        \\      <div><span class="project-progress-legend scope" aria-hidden="true"></span><span>Scope</span><strong>{scope}</strong></div>
        \\      <div><span class="project-progress-legend started" aria-hidden="true"></span><span>Started</span><strong>{started}</strong></div>
        \\      <div><span class="project-progress-legend completed" aria-hidden="true"></span><span>Completed</span><strong>{completed}</strong></div>
        \\    </div>
        \\    <div class="project-progress-chart" aria-label="{started} started and {completed} completed out of {scope} issues">
        \\      <span class="project-progress-scope-line" aria-hidden="true"></span>
        \\      <span class="project-progress-started-line" aria-hidden="true"></span>
        \\      <span class="project-progress-completed-line" aria-hidden="true"></span>
        \\    </div>
        \\    <div class="project-progress-axis"><span>{start_label}</span><span>{target_label}</span></div>
        \\  </div>
        \\</section>
    , .{
        .progress = progress,
        .started_percent = shared.percent(metrics.started_issue_count, metrics.issue_count),
        .completed_percent = shared.percent(metrics.completed_issue_count, metrics.issue_count),
        .scope = metrics.issue_count,
        .started = metrics.started_issue_count,
        .completed = metrics.completed_issue_count,
        .start_label = start_label,
        .target_label = target_label,
    });
}

fn appendSidebarProperty(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    label: []const u8,
    icon_class: []const u8,
    value: []const u8,
) !void {
    try appendTemplate(buf, allocator,
        \\<div>
        \\  <dt>{label}</dt>
        \\  <dd><span class="button-icon {icon_class}" aria-hidden="true"></span>{value}</dd>
        \\</div>
    , .{
        .label = label,
        .icon_class = icon_class,
        .value = value,
    });
}

fn appendProjectStatusProperty(buf: *std.ArrayList(u8), allocator: Allocator, summary: *const ProjectSummary) !void {
    try appendProjectPropertyChipMenuStart(buf, allocator, "Status", "Set status");
    if (summary.status.len == 0) {
        try buf.appendSlice(allocator, "<span class=\"project-property-empty\">No status</span>");
    } else {
        try appendProjectStatusChip(buf, allocator, summary.status);
    }
    try appendProjectPropertyChipMenuPopoverStart(buf, allocator, "Set status");
    try appendProjectMenuGroupStart(buf, allocator, "Statuses");
    for (project_views.project_status_values) |status| {
        try appendProjectValueActionRow(buf, allocator, summary, "set-status", "status", status, status, std.mem.eql(u8, summary.status, status), .status);
    }
    try appendProjectMenuGroupEnd(buf, allocator);
    try appendProjectPropertyMenuEnd(buf, allocator);
}

fn appendProjectPriorityProperty(buf: *std.ArrayList(u8), allocator: Allocator, summary: *const ProjectSummary) !void {
    try appendProjectPropertyChipMenuStart(buf, allocator, "Priority", "Set priority");
    if (summary.priority.len == 0) {
        try buf.appendSlice(allocator, "<span class=\"project-property-empty\">No priority</span>");
    } else {
        try appendProjectPriorityChip(buf, allocator, summary.priority);
    }
    try appendProjectPropertyChipMenuPopoverStart(buf, allocator, "Set priority");
    try appendProjectMenuGroupStart(buf, allocator, "Priorities");
    for (project_views.project_priority_values) |priority| {
        try appendProjectValueActionRow(buf, allocator, summary, "set-priority", "priority", priority, priority, std.mem.eql(u8, summary.priority, priority), .priority);
    }
    try appendProjectMenuGroupEnd(buf, allocator);
    try appendProjectPropertyMenuEnd(buf, allocator);
}

fn appendProjectPropertyChipMenuStart(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    label: []const u8,
    menu_label: []const u8,
) !void {
    try appendTemplate(buf, allocator,
        \\<div class="project-overview-property-chip-row">
        \\  <dt>{label}</dt>
        \\  <dd><details class="project-property-menu project-property-chip-menu" data-popover-menu data-issue-sidebar-menu><summary aria-label="{menu_label}" title="{menu_label}">
    , .{
        .label = label,
        .menu_label = menu_label,
    });
}

fn appendProjectPropertyChipMenuPopoverStart(buf: *std.ArrayList(u8), allocator: Allocator, menu_label: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<span class="issue-sidebar-menu-icon project-property-menu-icon" aria-hidden="true"></span></summary><div class="issue-sidebar-popover project-property-popover" role="dialog" aria-label="{menu_label}"><div class="issue-sidebar-popover-title">{menu_label}</div>
    , .{ .menu_label = menu_label });
}

const ProjectValueKind = enum {
    text,
    status,
    priority,
};

fn appendProjectPeopleProperty(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    summary: *const ProjectSummary,
    label: []const u8,
    icon_class: []const u8,
    comptime table: []const u8,
    comptime column: []const u8,
    add_action: []const u8,
    remove_action: []const u8,
    menu_label: []const u8,
    placeholder: []const u8,
    empty_label: []const u8,
) !void {
    const value = try projectCollectionPreviewOwned(allocator, db, table, column, summary.id, empty_label);
    defer allocator.free(value);
    try appendProjectPropertyMenuStart(buf, allocator, label, icon_class, menu_label, value);
    try appendProjectSingleInputForm(buf, allocator, summary, add_action, "value", menu_label, placeholder);
    try appendProjectMenuGroupStart(buf, allocator, "Selected");
    var selected = try db.prepare("SELECT DISTINCT " ++ column ++ " FROM " ++ table ++ " WHERE project_id = ? ORDER BY lower(" ++ column ++ "), " ++ column);
    defer selected.deinit();
    try selected.bindText(1, summary.id);
    var shown = false;
    while (try selected.step()) {
        const person = try selected.columnTextDup(allocator, 0);
        defer allocator.free(person);
        try appendProjectPersonActionRow(buf, allocator, summary, remove_action, person, true);
        shown = true;
    }
    if (!shown) try appendProjectMenuEmpty(buf, allocator, empty_label);
    try appendProjectMenuGroupEnd(buf, allocator);

    try appendProjectMenuGroupStart(buf, allocator, "Suggestions");
    var suggestions = try db.prepare(
        \\SELECT DISTINCT person
        \\FROM (
        \\  SELECT lead AS person FROM project_leads
        \\  UNION
        \\  SELECT member AS person FROM project_members
        \\  UNION
        \\  SELECT assignee AS person FROM issue_assignees
        \\  UNION
        \\  SELECT author_principal AS person FROM issues
        \\  UNION
        \\  SELECT author_principal AS person FROM projects
        \\  UNION
        \\  SELECT COALESCE(NULLIF(display_name, ''), NULLIF(email, ''), id) AS person FROM identities
        \\)
        \\WHERE person <> ''
        \\  AND person NOT IN (SELECT 
    ++ column ++
        \\ FROM 
    ++ table ++
        \\ WHERE project_id = ?)
        \\ORDER BY lower(person), person
        \\LIMIT 20
    );
    defer suggestions.deinit();
    try suggestions.bindText(1, summary.id);
    shown = false;
    while (try suggestions.step()) {
        const person = try suggestions.columnTextDup(allocator, 0);
        defer allocator.free(person);
        try appendProjectPersonActionRow(buf, allocator, summary, add_action, person, false);
        shown = true;
    }
    if (!shown) try appendProjectMenuEmpty(buf, allocator, "No suggestions.");
    try appendProjectMenuGroupEnd(buf, allocator);
    try appendProjectPropertyMenuEnd(buf, allocator);
}

fn appendProjectDatesProperty(buf: *std.ArrayList(u8), allocator: Allocator, summary: *const ProjectSummary, value: []const u8) !void {
    try appendProjectPropertyMenuStart(buf, allocator, "Dates", "icon-calendar", "Set dates", value);
    try buf.appendSlice(allocator, "<form class=\"project-property-date-form\" method=\"post\" action=\"/projects/properties\">");
    try appendProjectHiddenFields(buf, allocator, summary);
    try appendTemplate(buf, allocator,
        \\<input type="hidden" name="action" value="set-dates">
        \\<label>Start<input type="date" name="start_at" value="{start_at}" required></label>
        \\<label>End<input type="date" name="end_at" value="{end_at}" min="{min_end_at}"></label>
        \\<button type="submit">Save dates</button>
    , .{
        .start_at = summary.start_at,
        .end_at = summary.end_at,
        .min_end_at = summary.start_at,
    });
    try buf.appendSlice(allocator, "</form>");
    try appendProjectPropertyMenuEnd(buf, allocator);
}

fn appendProjectLabelsProperty(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, summary: *const ProjectSummary, metrics: *const ProjectMetrics) !void {
    const labels_label = try countLabelOwned(allocator, metrics.label_count, "label", "labels");
    defer allocator.free(labels_label);
    try appendProjectPropertyMenuStart(buf, allocator, "Labels", "icon-labels", "Apply labels", labels_label);
    try appendProjectSingleInputForm(buf, allocator, summary, "add-label", "value", "Add label", "Filter labels");
    try appendProjectMenuGroupStart(buf, allocator, "Selected labels");
    var selected = try db.prepare(
        \\SELECT selected.label, COALESCE(ld.color, '')
        \\FROM (SELECT DISTINCT label FROM project_labels WHERE project_id = ?) AS selected
        \\LEFT JOIN label_definitions ld ON ld.name = selected.label
        \\ORDER BY CASE WHEN ld.id IS NULL THEN 1 ELSE 0 END,
        \\         ld.position,
        \\         lower(selected.label),
        \\         selected.label
    );
    defer selected.deinit();
    try selected.bindText(1, summary.id);
    var shown = false;
    while (try selected.step()) {
        const label = try selected.columnTextDup(allocator, 0);
        defer allocator.free(label);
        const color = try selected.columnTextDup(allocator, 1);
        defer allocator.free(color);
        try appendProjectLabelActionRow(buf, allocator, summary, "remove-label", label, color, true);
        shown = true;
    }
    if (!shown) try appendProjectMenuEmpty(buf, allocator, "No labels selected.");
    try appendProjectMenuGroupEnd(buf, allocator);

    try appendProjectMenuGroupStart(buf, allocator, "Suggestions");
    var suggestions = try db.prepare(
        \\WITH label_names AS (
        \\  SELECT name AS label FROM label_definitions
        \\  UNION
        \\  SELECT label FROM issue_labels
        \\  UNION
        \\  SELECT label FROM pull_labels
        \\  UNION
        \\  SELECT label FROM project_labels
        \\)
        \\SELECT label_names.label, COALESCE(ld.color, '')
        \\FROM label_names
        \\LEFT JOIN label_definitions ld ON ld.name = label_names.label
        \\WHERE label_names.label NOT IN (SELECT label FROM project_labels WHERE project_id = ?)
        \\ORDER BY CASE WHEN ld.id IS NULL THEN 1 ELSE 0 END,
        \\         ld.position,
        \\         lower(label_names.label),
        \\         label_names.label
        \\LIMIT 24
    );
    defer suggestions.deinit();
    try suggestions.bindText(1, summary.id);
    shown = false;
    while (try suggestions.step()) {
        const label = try suggestions.columnTextDup(allocator, 0);
        defer allocator.free(label);
        const color = try suggestions.columnTextDup(allocator, 1);
        defer allocator.free(color);
        try appendProjectLabelActionRow(buf, allocator, summary, "add-label", label, color, false);
        shown = true;
    }
    if (!shown) try appendProjectMenuEmpty(buf, allocator, "No label suggestions.");
    try appendProjectMenuGroupEnd(buf, allocator);
    try appendProjectPropertyMenuEnd(buf, allocator);
}

fn appendProjectPropertyMenuStart(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    label: []const u8,
    icon_class: []const u8,
    menu_label: []const u8,
    value: []const u8,
) !void {
    try appendTemplate(buf, allocator,
        \\<div>
        \\  <dt>{label}</dt>
        \\  <dd><details class="project-property-menu" data-popover-menu data-issue-sidebar-menu><summary aria-label="{menu_label}" title="{menu_label}"><span class="button-icon {icon_class}" aria-hidden="true"></span><span>{value}</span></summary><div class="issue-sidebar-popover project-property-popover" role="dialog" aria-label="{menu_label}"><div class="issue-sidebar-popover-title">{menu_label}</div>
    , .{
        .label = label,
        .icon_class = icon_class,
        .menu_label = menu_label,
        .value = value,
    });
}

fn appendProjectPropertyMenuEnd(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator, "</div></details></dd></div>");
}

fn appendProjectMenuGroupStart(buf: *std.ArrayList(u8), allocator: Allocator, title: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<div class="issue-sidebar-menu-group"><div class="issue-sidebar-menu-group-title">{title}</div>
    , .{ .title = title });
}

fn appendProjectMenuGroupEnd(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator, "</div>");
}

fn appendProjectMenuEmpty(buf: *std.ArrayList(u8), allocator: Allocator, message: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<p class="issue-sidebar-menu-empty" data-sidebar-filter-text="">{message}</p>
    , .{ .message = message });
}

fn appendProjectSingleInputForm(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    summary: *const ProjectSummary,
    action: []const u8,
    input_name: []const u8,
    button_label: []const u8,
    placeholder: []const u8,
) !void {
    try buf.appendSlice(allocator, "<form class=\"issue-sidebar-add-form issue-sidebar-menu-form\" method=\"post\" action=\"/projects/properties\">");
    try appendProjectHiddenFields(buf, allocator, summary);
    try appendTemplate(buf, allocator,
        \\<input type="hidden" name="action" value="{action}"><label class="issue-sidebar-menu-input"><span aria-hidden="true"></span><input name="{input_name}" placeholder="{placeholder}" aria-label="{placeholder}" autocomplete="off" data-issue-sidebar-filter></label><button type="submit">{button_label}</button></form>
    , .{
        .action = action,
        .input_name = input_name,
        .placeholder = placeholder,
        .button_label = button_label,
    });
}

fn appendProjectHiddenFields(buf: *std.ArrayList(u8), allocator: Allocator, summary: *const ProjectSummary) !void {
    try appendTemplate(buf, allocator,
        \\<input type="hidden" name="project_id" value="{project_id}"><input type="hidden" name="project" value="{project}">
    , .{
        .project_id = summary.id,
        .project = summary.name,
    });
}

fn appendProjectValueActionRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    summary: *const ProjectSummary,
    action: []const u8,
    input_name: []const u8,
    value: []const u8,
    filter_text: []const u8,
    selected: bool,
    kind: ProjectValueKind,
) !void {
    const state_class: []const u8 = if (selected) " is-selected" else "";
    try buf.appendSlice(allocator, "<form class=\"issue-sidebar-picker-form\" method=\"post\" action=\"/projects/properties\">");
    try appendProjectHiddenFields(buf, allocator, summary);
    try appendTemplate(buf, allocator,
        \\<input type="hidden" name="action" value="{action}"><input type="hidden" name="{input_name}" value="{value}"><button class="issue-sidebar-picker-row{state_class}" type="submit" data-sidebar-filter-text="{filter_text}"><span class="issue-sidebar-picker-check" aria-hidden="true"></span>
    , .{
        .action = action,
        .input_name = input_name,
        .value = value,
        .filter_text = filter_text,
        .state_class = state_class,
    });
    switch (kind) {
        .status => try appendProjectStatusChip(buf, allocator, value),
        .priority => try appendProjectPriorityChip(buf, allocator, value),
        .text => try appendTemplate(buf, allocator, "<span class=\"issue-sidebar-picker-primary\">{value}</span>", .{ .value = value }),
    }
    try buf.appendSlice(allocator, "</button></form>");
}

fn appendProjectPersonActionRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    summary: *const ProjectSummary,
    action: []const u8,
    person: []const u8,
    selected: bool,
) !void {
    const state_class: []const u8 = if (selected) " is-selected" else "";
    try buf.appendSlice(allocator, "<form class=\"issue-sidebar-picker-form\" method=\"post\" action=\"/projects/properties\">");
    try appendProjectHiddenFields(buf, allocator, summary);
    try appendTemplate(buf, allocator,
        \\<input type="hidden" name="action" value="{action}"><input type="hidden" name="value" value="{person}"><button class="issue-sidebar-picker-row{state_class}" type="submit" data-sidebar-filter-text="{person}"><span class="issue-sidebar-picker-check" aria-hidden="true"></span>
    , .{
        .action = action,
        .person = person,
        .state_class = state_class,
    });
    try project_issue_render.appendIssueAvatar(buf, allocator, person, "");
    try appendTemplate(buf, allocator, "<span class=\"issue-sidebar-picker-primary\">{person}</span></button></form>", .{ .person = person });
}

fn appendProjectLabelActionRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    summary: *const ProjectSummary,
    action: []const u8,
    label: []const u8,
    color: []const u8,
    selected: bool,
) !void {
    const state_class: []const u8 = if (selected) " is-selected" else "";
    try buf.appendSlice(allocator, "<form class=\"issue-sidebar-picker-form\" method=\"post\" action=\"/projects/properties\">");
    try appendProjectHiddenFields(buf, allocator, summary);
    try appendTemplate(buf, allocator,
        \\<input type="hidden" name="action" value="{action}"><input type="hidden" name="value" value="{label}"><button class="issue-sidebar-picker-row{state_class}" type="submit" data-sidebar-filter-text="{label}"><span class="issue-sidebar-picker-check" aria-hidden="true"></span>
    , .{
        .action = action,
        .label = label,
        .state_class = state_class,
    });
    try appendProjectLabel(buf, allocator, label, color);
    try buf.appendSlice(allocator, "</button></form>");
}

fn appendProjectStatusChip(buf: *std.ArrayList(u8), allocator: Allocator, status: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<span class="project-status-chip tone-{tone}">{status}</span>
    , .{
        .tone = project_issue_render.columnTone(status),
        .status = statusLabel(status),
    });
}

fn appendProjectPriorityChip(buf: *std.ArrayList(u8), allocator: Allocator, priority: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<span class="issue-row-priority issue-row-priority-{tone}" title="Priority: {priority}" aria-label="Priority: {priority}">{priority}</span>
    , .{
        .tone = project_issue_render.priorityTone(priority),
        .priority = priority,
    });
}

fn appendProjectLabel(buf: *std.ArrayList(u8), allocator: Allocator, label: []const u8, color: []const u8) !void {
    if (validHexColor(color)) {
        try appendTemplate(buf, allocator,
            \\<span class="issue-label label-custom" style="--label-color: {color}">{label}</span>
        , .{
            .color = color,
            .label = label,
        });
        return;
    }
    try appendTemplate(buf, allocator,
        \\<span class="issue-label {kind}">{label}</span>
    , .{
        .kind = issueLabelKind(label),
        .label = label,
    });
}

fn validHexColor(value: []const u8) bool {
    if (value.len != 7 or value[0] != '#') return false;
    for (value[1..]) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

fn issueLabelKind(label: []const u8) []const u8 {
    if (asciiEqlIgnoreCase(label, "bug")) return "label-bug";
    if (asciiEqlIgnoreCase(label, "enhancement") or asciiEqlIgnoreCase(label, "feature") or asciiEqlIgnoreCase(label, "feat")) return "label-enhancement";
    if (asciiEqlIgnoreCase(label, "docs") or asciiEqlIgnoreCase(label, "documentation")) return "label-docs";
    if (asciiEqlIgnoreCase(label, "question")) return "label-question";
    if (asciiEqlIgnoreCase(label, "security")) return "label-security";
    return "label-default";
}

fn appendProjectActivityMain(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, summary: *const ProjectSummary, project: []const u8) !void {
    try buf.appendSlice(allocator,
        \\<section class="project-overview-section project-overview-activity-main">
        \\  <div class="project-overview-section-title"><h2>Activity</h2><a class="button secondary" href="
    );
    try appendProjectActivityHref(buf, allocator, project);
    try buf.appendSlice(allocator,
        \\">See all</a></div>
        \\  <div class="project-overview-activity-list">
    );
    try appendProjectActivityItems(buf, allocator, db, summary, project, 24);
    try buf.appendSlice(allocator,
        \\  </div>
        \\</section>
    );
}

fn appendProjectActivityPanel(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, summary: *const ProjectSummary, project: []const u8) !void {
    try buf.appendSlice(allocator,
        \\<section id="project-activity" class="project-overview-side-panel project-overview-activity">
        \\  <div class="project-overview-side-panel-head"><h2>Activity</h2><a href="
    );
    try appendProjectActivityHref(buf, allocator, project);
    try buf.appendSlice(allocator,
        \\">See all</a></div>
        \\  <div class="project-overview-activity-list">
    );
    try appendProjectActivityItems(buf, allocator, db, summary, project, 4);
    try buf.appendSlice(allocator,
        \\  </div>
        \\</section>
    );
}

fn appendProjectActivityHref(buf: *std.ArrayList(u8), allocator: Allocator, project: []const u8) !void {
    try buf.appendSlice(allocator, "/events?project=");
    try shared.appendUrlEncoded(buf, allocator, project);
}

fn appendProjectActivityItems(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    summary: *const ProjectSummary,
    project: []const u8,
    limit: usize,
) !void {
    var shown: usize = 0;
    if (summary.id.len != 0) {
        shown = try appendProjectEvents(buf, allocator, db, summary.id, project, limit);
    }
    if (shown == 0 and summary.created_at.len != 0) {
        try appendTemplate(buf, allocator,
            \\<article>
            \\  <span class="project-overview-activity-icon" aria-hidden="true"></span>
            \\  <p><strong>{actor}</strong> created the project · 
        , .{ .actor = if (summary.author_principal.len == 0) "Unknown" else summary.author_principal });
        try appendRelativeTime(buf, allocator, summary.created_at);
        try buf.appendSlice(allocator, "</p></article>");
        shown += 1;
    }
    if (shown == 0) {
        try buf.appendSlice(allocator, "<p class=\"project-overview-empty\">No project activity yet.</p>");
    }
}

fn appendProjectEvents(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    project_id: []const u8,
    project: []const u8,
    limit: usize,
) !usize {
    var stmt = try db.prepare(projectItemsCte(
        \\SELECT e.event_type, e.subject, e.actor_principal, e.occurred_at, e.object_id, e.object_kind
        \\FROM events e
        \\WHERE e.valid_json != 0
        \\  AND (
        \\    (e.object_kind = 'project' AND e.object_id = ?)
        \\    OR (e.object_kind = 'issue' AND e.object_id IN (SELECT issue_id FROM project_items))
        \\  )
        \\ORDER BY e.ordinal DESC
        \\LIMIT ?
    ));
    defer stmt.deinit();
    try bindProjectNameTwice(&stmt, project);
    try stmt.bindText(3, project_id);
    try stmt.bindInt64(4, @intCast(limit));

    var shown: usize = 0;
    while (try stmt.step()) {
        const event_type = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(event_type);
        const subject = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(subject);
        const actor = try stmt.columnTextDup(allocator, 2);
        defer allocator.free(actor);
        const occurred_at = try stmt.columnTextDup(allocator, 3);
        defer allocator.free(occurred_at);
        const object_id = try stmt.columnTextDup(allocator, 4);
        defer allocator.free(object_id);
        const object_kind = try stmt.columnTextDup(allocator, 5);
        defer allocator.free(object_kind);
        try appendProjectEventRow(buf, allocator, event_type, object_kind, subject, actor, occurred_at, object_id);
        shown += 1;
    }
    return shown;
}

fn appendProjectEventRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    event_type: []const u8,
    object_kind: []const u8,
    subject: []const u8,
    actor: []const u8,
    occurred_at: []const u8,
    object_id: []const u8,
) !void {
    const label = projectEventLabel(event_type, object_kind);
    try appendTemplate(buf, allocator,
        \\<article>
        \\  <span class="project-overview-activity-icon" aria-hidden="true"></span>
        \\  <p><strong>{actor}</strong> {label}
    , .{
        .actor = actor,
        .label = label,
    });
    if (object_id.len != 0) {
        var ref_buf: [util.short_object_ref_len]u8 = undefined;
        try appendTemplate(buf, allocator, " <code>{ref}</code>", .{ .ref = util.shortObjectRef(&ref_buf, object_id) });
    }
    try buf.appendSlice(allocator, " · ");
    try appendRelativeTime(buf, allocator, occurred_at);
    if (subject.len != 0) {
        try appendTemplate(buf, allocator, "<span>{subject}</span>", .{ .subject = subject });
    }
    try buf.appendSlice(allocator, "</p></article>");
}

fn projectEventLabel(event_type: []const u8, object_kind: []const u8) []const u8 {
    if (std.mem.eql(u8, object_kind, "issue")) {
        if (std.mem.eql(u8, event_type, "issue.created")) return "created issue";
        if (std.mem.eql(u8, event_type, "issue.updated")) return "updated issue";
        if (std.mem.eql(u8, event_type, "issue.project_added")) return "added issue to project";
        if (std.mem.eql(u8, event_type, "issue.project_removed")) return "removed issue from project";
        return "changed issue";
    }
    if (std.mem.eql(u8, event_type, "project.created")) return "created";
    if (std.mem.eql(u8, event_type, "project.updated")) return "updated";
    if (std.mem.eql(u8, event_type, "project.column_added")) return "added a column to";
    if (std.mem.eql(u8, event_type, "project.column_removed")) return "removed a column from";
    if (std.mem.eql(u8, event_type, "project.field_created")) return "created a field on";
    if (std.mem.eql(u8, event_type, "project.field_updated")) return "updated a field on";
    if (std.mem.eql(u8, event_type, "project.view_created")) return "created a view on";
    if (std.mem.eql(u8, event_type, "project.view_updated")) return "updated a view on";
    return "changed";
}

fn projectStateLabel(state: []const u8) []const u8 {
    if (std.mem.eql(u8, state, "closed")) return "Completed";
    if (std.mem.eql(u8, state, "open")) return "In Progress";
    return if (state.len == 0) "No status" else state;
}

fn projectStateTone(state: []const u8) []const u8 {
    if (std.mem.eql(u8, state, "closed")) return "done";
    if (std.mem.eql(u8, state, "open")) return "progress";
    return "neutral";
}

fn milestoneStateLabel(state: []const u8) []const u8 {
    if (std.mem.eql(u8, state, "closed")) return "Closed";
    if (std.mem.eql(u8, state, "open")) return "Open";
    return if (state.len == 0) "Open" else state;
}

fn statusLabel(status: []const u8) []const u8 {
    if (status.len == 0) return "No status";
    if (std.mem.eql(u8, status, "WIP")) return "In Progress";
    return status;
}

fn priorityLabel(priority: []const u8) []const u8 {
    return if (priority.len == 0) "No priority" else priority;
}

fn prioritySummaryLabel(priority: []const u8) []const u8 {
    return if (priority.len == 0) "---" else priority;
}

fn repositoryOwnerLabel(repo: Repo) []const u8 {
    if (std.fs.path.dirname(repo.root)) |parent| return std.fs.path.basename(parent);
    return std.fs.path.basename(repo.root);
}

fn projectDatesLabelOwned(allocator: Allocator, summary: *const ProjectSummary) ![]u8 {
    const start_label = if (summary.start_at.len != 0) try dateLabelOwned(allocator, summary.start_at) else try allocator.dupe(u8, "No start date");
    defer allocator.free(start_label);
    const end_label = if (summary.end_at.len != 0) try dateLabelOwned(allocator, summary.end_at) else try allocator.dupe(u8, "No end date");
    defer allocator.free(end_label);
    return std.fmt.allocPrint(allocator, "{s} + {s}", .{ start_label, end_label });
}

fn projectTargetDateLabelOwned(allocator: Allocator, summary: *const ProjectSummary) ![]u8 {
    if (summary.end_at.len == 0) return allocator.dupe(u8, "No target date");
    return dateLabelWithOrdinalOwned(allocator, summary.end_at);
}

fn projectCollectionPreviewOwned(
    allocator: Allocator,
    db: *SqliteDb,
    comptime table: []const u8,
    comptime column: []const u8,
    project_id: []const u8,
    empty_label: []const u8,
) ![]u8 {
    var stmt = try db.prepare("SELECT " ++ column ++ ", COUNT(*) OVER () FROM (SELECT DISTINCT " ++ column ++ " FROM " ++ table ++ " WHERE project_id = ? ORDER BY lower(" ++ column ++ "), " ++ column ++ ") LIMIT 2");
    defer stmt.deinit();
    try stmt.bindText(1, project_id);
    var values: [2][]u8 = undefined;
    var len: usize = 0;
    var total: usize = 0;
    while (try stmt.step()) {
        values[len] = try stmt.columnTextDup(allocator, 0);
        len += 1;
        total = @intCast(stmt.columnInt64(1));
    }
    defer {
        for (values[0..len]) |value| allocator.free(value);
    }

    if (total == 0) return try allocator.dupe(u8, empty_label);
    if (total == 1) return try allocator.dupe(u8, values[0]);
    return try std.fmt.allocPrint(allocator, "{s} + {d}", .{ values[0], total - 1 });
}

fn dateLabelOwned(allocator: Allocator, value: []const u8) ![]u8 {
    if (value.len >= 10 and value[4] == '-' and value[7] == '-') {
        const month = std.fmt.parseInt(u8, value[5..7], 10) catch 0;
        const day = std.fmt.parseInt(u8, value[8..10], 10) catch 0;
        if (month >= 1 and month <= 12 and day >= 1 and day <= 31) {
            return std.fmt.allocPrint(allocator, "{s} {d}", .{ monthNames()[month - 1], day });
        }
    }
    return allocator.dupe(u8, value);
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

fn countLabelOwned(allocator: Allocator, value: usize, singular: []const u8, plural: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{d} {s}", .{ value, if (value == 1) singular else plural });
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (std.ascii.toLower(left) != std.ascii.toLower(right)) return false;
    }
    return true;
}

fn appendProjectViewHref(buf: *std.ArrayList(u8), allocator: Allocator, project: []const u8, view_ref: []const u8) !void {
    try buf.appendSlice(allocator, "/projects?project=");
    try shared.appendUrlEncoded(buf, allocator, project);
    try buf.appendSlice(allocator, "&amp;view=");
    try shared.appendUrlEncoded(buf, allocator, view_ref);
}

fn appendProjectOverviewHref(buf: *std.ArrayList(u8), allocator: Allocator, project: []const u8) !void {
    try buf.appendSlice(allocator, "/projects?project=");
    try shared.appendUrlEncoded(buf, allocator, project);
}

test "project overview header renders plain project name" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var summary = ProjectSummary{
        .id = try std.testing.allocator.dupe(u8, "p1"),
        .name = try std.testing.allocator.dupe(u8, "Release & Plan"),
        .description = try std.testing.allocator.dupe(u8, ""),
        .state = try std.testing.allocator.dupe(u8, "open"),
        .status = try std.testing.allocator.dupe(u8, "WIP"),
        .status_occurred_at = try std.testing.allocator.dupe(u8, ""),
        .priority = try std.testing.allocator.dupe(u8, ""),
        .start_at = try std.testing.allocator.dupe(u8, ""),
        .end_at = try std.testing.allocator.dupe(u8, ""),
        .created_at = try std.testing.allocator.dupe(u8, ""),
        .author_principal = try std.testing.allocator.dupe(u8, ""),
    };
    defer summary.deinit(std.testing.allocator);
    const metrics = ProjectMetrics{};

    try appendProjectOverviewHeader(&buf, std.testing.allocator, &summary, &metrics);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<h1>Release &amp; Plan</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<h1>@Release") == null);
}

test "project issues tab stays in project workspace" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendProjectPageTabs(&buf, std.testing.allocator, "Release Plan", .overview, 3);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "href=\"/projects?project=Release%20Plan&amp;view=issues\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "href=\"/issues?project=") == null);
}

test "project activity href scopes settings activity to project" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendProjectActivityHref(&buf, std.testing.allocator, "Release Plan");

    try std.testing.expectEqualStrings("/events?project=Release%20Plan", buf.items);
}

test "project dates label uses start plus end" {
    var summary = ProjectSummary{
        .id = try std.testing.allocator.dupe(u8, "p1"),
        .name = try std.testing.allocator.dupe(u8, "Release"),
        .description = try std.testing.allocator.dupe(u8, ""),
        .state = try std.testing.allocator.dupe(u8, "open"),
        .status = try std.testing.allocator.dupe(u8, "WIP"),
        .status_occurred_at = try std.testing.allocator.dupe(u8, ""),
        .priority = try std.testing.allocator.dupe(u8, ""),
        .start_at = try std.testing.allocator.dupe(u8, "2026-05-17"),
        .end_at = try std.testing.allocator.dupe(u8, "2026-05-28"),
        .created_at = try std.testing.allocator.dupe(u8, ""),
        .author_principal = try std.testing.allocator.dupe(u8, ""),
    };
    defer summary.deinit(std.testing.allocator);

    const label = try projectDatesLabelOwned(std.testing.allocator, &summary);
    defer std.testing.allocator.free(label);

    try std.testing.expectEqualStrings("May 17 + May 28", label);
}
