const std = @import("std");
const comment_mod = @import("../../comment.zig");
const cmd_common = @import("../../cmd_common.zig");
const event_model = @import("../../event/model.zig");
const event_json = @import("../../event/json.zig");
const index = @import("../../index.zig");
const project_mod = @import("../../project.zig");
const reaction_mod = @import("../../reaction.zig");
const settings = @import("../../settings.zig");
const repo_mod = @import("../../repo.zig");
const util = @import("../../util.zig");
const work_items = @import("../../work_items.zig");
const issues_page = @import("../issues.zig");
const reaction_choices = @import("../reaction_choices.zig");
const project_issue_render = @import("issue_render.zig");
const project_views = @import("views.zig");
const project_data = @import("data.zig");
const shared = @import("../shared.zig");
const zwf = @import("../../zwf.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const SqliteDb = index.SqliteDb;
const createCommentAddedEvent = comment_mod.createCommentAddedEvent;
const createCommentReplyEvent = comment_mod.createCommentReplyEvent;
const createProjectUpdatedEvent = project_mod.createProjectUpdatedEvent;
const createReactionEvent = reaction_mod.createReactionEvent;
const formValueOwned = shared.formValueOwned;
const formValuesOwned = shared.formValuesOwned;
const appendRelativeTime = shared.appendRelativeTime;
const appendTemplate = shared.appendTemplate;
const isIssuePriority = cmd_common.isIssuePriority;
const isProjectStatus = cmd_common.isProjectStatus;
const isProjectUpdateHealth = cmd_common.isProjectUpdateHealth;
const sendPlainResponse = shared.sendPlainResponse;
const sendRedirect = shared.sendRedirect;
const projectIdExists = project_data.projectIdExists;

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
    csrf_token: []const u8,

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
    health: []u8,
    occurred_at: []u8,
    actor: []u8,

    fn deinit(self: *ProjectUpdateNote, allocator: Allocator) void {
        allocator.free(self.body);
        allocator.free(self.health);
        allocator.free(self.occurred_at);
        allocator.free(self.actor);
    }
};

const ProjectUpdatePayload = struct {
    body: []u8,
    health: []u8,

    fn deinit(self: *ProjectUpdatePayload, allocator: Allocator) void {
        allocator.free(self.body);
        allocator.free(self.health);
    }
};

const ReactionChoice = reaction_choices.Choice;

const ReactionSummary = struct {
    emoji: []u8,
    count: i64,
    reacted: bool,

    fn deinit(self: *ReactionSummary, allocator: Allocator) void {
        allocator.free(self.emoji);
    }
};

pub fn appendProjectOverview(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    repo: Repo,
    db: *SqliteDb,
    project: []const u8,
    csrf_token: []const u8,
) !void {
    var summary = try loadProjectSummary(allocator, db, project, csrf_token);
    defer summary.deinit(allocator);
    const metrics = try loadProjectMetrics(db, &summary);
    var update_note = try loadLatestProjectUpdateNote(allocator, db, &summary);
    defer update_note.deinit(allocator);
    const current_actor = try shared.currentPrincipalOwned(allocator, repo);
    defer if (current_actor) |actor| allocator.free(actor);

    try buf.appendSlice(allocator, "<section class=\"panel project-overview-page\">");
    try appendProjectOverviewHeader(buf, allocator, &summary, &metrics);
    try appendProjectPageTabs(buf, allocator, project, summary.id, .overview, csrf_token);
    try buf.appendSlice(allocator,
        \\<div class="project-overview-layout">
        \\  <div class="project-overview-main">
    );
    try appendProjectUpdateSection(buf, allocator, db, &summary, &update_note, current_actor);
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
    db: *SqliteDb,
    project: []const u8,
    csrf_token: []const u8,
) !void {
    var summary = try loadProjectSummary(allocator, db, project, csrf_token);
    defer summary.deinit(allocator);
    const metrics = try loadProjectMetrics(db, &summary);

    try buf.appendSlice(allocator, "<section class=\"panel project-overview-page project-activity-page\">");
    try appendProjectOverviewHeader(buf, allocator, &summary, &metrics);
    try appendProjectPageTabs(buf, allocator, project, summary.id, .activity, csrf_token);
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

pub fn handleProjectPropertiesPost(allocator: Allocator, repo: Repo, stream: @import("compat").net.Stream, form_body: []const u8) !void {
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
        const health_owned = try requiredProjectFormValue(allocator, stream, form_body, "update_health", "Update health is required\n");
        const health = health_owned orelse return;
        defer allocator.free(health);
        if (!isProjectUpdateHealth(health)) {
            try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Update health must be on_track, at_risk, or off_track\n");
            return;
        }
        const update_health = cmd_common.canonicalProjectUpdateHealth(health);
        const body_owned = (try formValueOwned(allocator, form_body, "update_body")) orelse try allocator.dupe(u8, "");
        defer allocator.free(body_owned);
        const trimmed_body = std.mem.trim(u8, body_owned, " \t\r\n");
        const effective_body: []const u8 = if (trimmed_body.len == 0) "" else body_owned;
        if (try projectFormHashUnchanged(allocator, form_body, "project-update", update_health, effective_body)) {
            try redirectProjectOverview(allocator, stream, project_name_owned, project_ref);
            return;
        }
        const update_body: ?[]const u8 = if (effective_body.len == 0) null else effective_body;
        if (!(try writeProjectUpdateOrFail(allocator, stream, project_id, .{ .update_health = update_health, .update_body = update_body }))) return;
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
        if (!isProjectStatus(status)) {
            try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Status must be Backlog, Planned, In Progress, Completed, or Canceled\n");
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
        const start_owned = try formTrimmedOwned(allocator, form_body, "start_at");
        defer allocator.free(start_owned);
        const end_owned = try formTrimmedOwned(allocator, form_body, "end_at");
        defer allocator.free(end_owned);
        if (!isProjectDateValue(start_owned) or !isProjectDateValue(end_owned)) {
            try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Dates must use YYYY-MM-DD\n");
            return;
        }
        if (!(try writeProjectUpdateOrFail(allocator, stream, project_id, .{ .start_at = start_owned, .end_at = end_owned }))) return;
    } else if (std.mem.eql(u8, action_owned, "set-start-date")) {
        const start_owned = try formTrimmedOwned(allocator, form_body, "start_at");
        defer allocator.free(start_owned);
        if (!isProjectDateValue(start_owned)) {
            try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Date must use YYYY-MM-DD\n");
            return;
        }
        if (!(try writeProjectUpdateOrFail(allocator, stream, project_id, .{ .start_at = start_owned }))) return;
    } else if (std.mem.eql(u8, action_owned, "set-end-date")) {
        const end_owned = try formTrimmedOwned(allocator, form_body, "end_at");
        defer allocator.free(end_owned);
        if (!isProjectDateValue(end_owned)) {
            try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Date must use YYYY-MM-DD\n");
            return;
        }
        if (!(try writeProjectUpdateOrFail(allocator, stream, project_id, .{ .end_at = end_owned }))) return;
    } else if (std.mem.eql(u8, action_owned, "add-lead") or std.mem.eql(u8, action_owned, "remove-lead")) {
        const value_owned = try requiredProjectFormValue(allocator, stream, form_body, "value", "Lead is required\n");
        const value = value_owned orelse return;
        defer allocator.free(value);
        const values = [_][]const u8{value};
        var update = event_model.ProjectUpdate{};
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
        var update = event_model.ProjectUpdate{};
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
        var update = event_model.ProjectUpdate{};
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

pub fn handleProjectDefaultViewPost(allocator: Allocator, repo: Repo, stream: @import("compat").net.Stream, form_body: []const u8) !void {
    try index.ensureIndex(allocator, repo);

    const project_id_owned = try formTrimmedOwned(allocator, form_body, "project_id");
    defer allocator.free(project_id_owned);
    const project_owned = try formTrimmedOwned(allocator, form_body, "project");
    defer allocator.free(project_owned);
    const view_owned = try formTrimmedOwned(allocator, form_body, "view");
    defer allocator.free(view_owned);

    if (project_id_owned.len == 0 or project_owned.len == 0) {
        try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Project is required\n");
        return;
    }
    if (!settings.isProjectDefaultViewValue(view_owned)) {
        try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Unknown project view\n");
        return;
    }

    var db = try SqliteDb.open(allocator, repo.index_path, index.sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    if (!(try projectIdExists(&db, project_id_owned))) {
        try sendPlainResponse(allocator, stream, 404, "Not Found", "Project not found\n");
        return;
    }

    settings.saveProjectDefaultView(allocator, repo, project_id_owned, view_owned) catch {
        try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not save project view preference\n");
        return;
    };

    const location = try projectViewLocationOwned(allocator, project_owned, view_owned);
    defer allocator.free(location);
    try sendRedirect(allocator, stream, location);
}

pub fn handleProjectCommentPost(allocator: Allocator, repo: Repo, stream: @import("compat").net.Stream, form_body: []const u8) !void {
    try index.ensureIndex(allocator, repo);

    const project_id_owned = try formTrimmedOwned(allocator, form_body, "project_id");
    defer allocator.free(project_id_owned);
    const project_name_owned = try formTrimmedOwned(allocator, form_body, "project");
    defer allocator.free(project_name_owned);
    if (project_id_owned.len == 0 or project_name_owned.len == 0) {
        try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Project is required\n");
        return;
    }

    var db = try SqliteDb.open(allocator, repo.index_path, index.sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    if (!(try projectIdExists(&db, project_id_owned))) {
        try sendPlainResponse(allocator, stream, 404, "Not Found", "Project not found\n");
        return;
    }

    const action_owned = try formTrimmedOwned(allocator, form_body, "action");
    defer allocator.free(action_owned);
    if (std.mem.eql(u8, action_owned, "add-reaction") or std.mem.eql(u8, action_owned, "remove-reaction")) {
        const emoji_owned = try formTrimmedOwned(allocator, form_body, "emoji");
        defer allocator.free(emoji_owned);
        if (emoji_owned.len == 0) {
            try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Emoji is required\n");
            return;
        }

        const target_kind_owned = try formTrimmedOwned(allocator, form_body, "target_kind");
        defer allocator.free(target_kind_owned);
        const target_kind = if (target_kind_owned.len == 0) "project" else target_kind_owned;
        const add = std.mem.eql(u8, action_owned, "add-reaction");
        if (std.mem.eql(u8, target_kind, "project")) {
            createReactionEvent(allocator, "project", project_id_owned, emoji_owned, add) catch {
                try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not update reaction\n");
                return;
            };
        } else if (std.mem.eql(u8, target_kind, "comment")) {
            const target_ref_owned = try formTrimmedOwned(allocator, form_body, "target_ref");
            defer allocator.free(target_ref_owned);
            if (target_ref_owned.len == 0) {
                try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Comment target is required\n");
                return;
            }
            const comment_id = index.resolveCommentId(allocator, repo, target_ref_owned) catch {
                try sendPlainResponse(allocator, stream, 404, "Not Found", "Comment not found\n");
                return;
            };
            defer allocator.free(comment_id);
            var parent = try index.commentParentInfo(allocator, repo, comment_id);
            defer parent.deinit();
            if (!std.mem.eql(u8, parent.parent_kind, "project") or !std.mem.eql(u8, parent.parent_id, project_id_owned)) {
                try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Comment is not in this project\n");
                return;
            }
            createReactionEvent(allocator, "comment", comment_id, emoji_owned, add) catch {
                try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not update reaction\n");
                return;
            };
        } else {
            try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Unknown reaction target\n");
            return;
        }

        const location = try projectUpdateThreadLocationOwned(allocator, project_name_owned, project_id_owned);
        defer allocator.free(location);
        try sendRedirect(allocator, stream, location);
        return;
    }

    if (action_owned.len != 0 and !std.mem.eql(u8, action_owned, "comment")) {
        try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Unknown project comment action\n");
        return;
    }
    if (!(try projectHasLatestUpdateNote(allocator, &db, project_id_owned))) {
        try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Project update is required\n");
        return;
    }

    const body_owned = (try formValueOwned(allocator, form_body, "body")) orelse try allocator.dupe(u8, "");
    defer allocator.free(body_owned);
    const body = std.mem.trim(u8, body_owned, " \t\r\n");
    if (body.len == 0) {
        try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Comment is required\n");
        return;
    }

    const reply_ref_owned = try formTrimmedOwned(allocator, form_body, "reply_parent_ref");
    defer allocator.free(reply_ref_owned);
    if (reply_ref_owned.len != 0) {
        const reply_parent_id = index.resolveCommentId(allocator, repo, reply_ref_owned) catch {
            try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Reply target was not found\n");
            return;
        };
        defer allocator.free(reply_parent_id);
        var parent = try index.commentParentInfo(allocator, repo, reply_parent_id);
        defer parent.deinit();
        if (!std.mem.eql(u8, parent.parent_kind, "project") or !std.mem.eql(u8, parent.parent_id, project_id_owned)) {
            try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Reply target is not in this project\n");
            return;
        }
        createCommentReplyEvent(allocator, "project", project_id_owned, reply_parent_id, parent.add_hash, body_owned) catch {
            try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not add the reply\n");
            return;
        };
    } else {
        createCommentAddedEvent(allocator, "project", project_id_owned, body_owned) catch {
            try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not add the comment\n");
            return;
        };
    }

    const location = try projectUpdateThreadLocationOwned(allocator, project_name_owned, project_id_owned);
    defer allocator.free(location);
    try sendRedirect(allocator, stream, location);
}

fn formTrimmedOwned(allocator: Allocator, form_body: []const u8, wanted_key: []const u8) ![]u8 {
    const owned = (try formValueOwned(allocator, form_body, wanted_key)) orelse try allocator.dupe(u8, "");
    defer allocator.free(owned);
    const trimmed = std.mem.trim(u8, owned, " \t\r\n");
    return try allocator.dupe(u8, trimmed);
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

fn requiredProjectFormValue(allocator: Allocator, stream: @import("compat").net.Stream, form_body: []const u8, name: []const u8, message: []const u8) !?[]u8 {
    const value_owned = try formTrimmedOwned(allocator, form_body, name);
    errdefer allocator.free(value_owned);
    if (value_owned.len == 0) {
        allocator.free(value_owned);
        try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", message);
        return null;
    }
    return value_owned;
}

fn writeProjectUpdateOrFail(allocator: Allocator, stream: @import("compat").net.Stream, project_id: []const u8, update: event_model.ProjectUpdate) !bool {
    createProjectUpdatedEvent(allocator, project_id, update) catch {
        try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not update project properties\n");
        return false;
    };
    return true;
}

fn redirectProjectOverview(allocator: Allocator, stream: @import("compat").net.Stream, project_name: []const u8, fallback_ref: []const u8) !void {
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

fn projectViewLocationOwned(allocator: Allocator, project_name: []const u8, view_ref: []const u8) ![]u8 {
    var location: std.ArrayList(u8) = .empty;
    errdefer location.deinit(allocator);
    try location.appendSlice(allocator, "/projects?project=");
    try shared.appendUrlEncoded(&location, allocator, project_name);
    try location.appendSlice(allocator, "&view=");
    try shared.appendUrlEncoded(&location, allocator, view_ref);
    return location.toOwnedSlice(allocator);
}

fn projectUpdateThreadLocationOwned(allocator: Allocator, project_name: []const u8, fallback_ref: []const u8) ![]u8 {
    const location = try projectOverviewLocationOwned(allocator, project_name, fallback_ref);
    errdefer allocator.free(location);
    const with_anchor = try std.fmt.allocPrint(allocator, "{s}#project-update-thread", .{location});
    allocator.free(location);
    return with_anchor;
}

fn projectFormHashUnchanged(allocator: Allocator, form_body: []const u8, kind: []const u8, marker: []const u8, body: []const u8) !bool {
    const previous_hash = try formTrimmedOwned(allocator, form_body, "previous_hash");
    defer allocator.free(previous_hash);
    if (previous_hash.len == 0) return false;
    const submitted_hash = try projectContentHashOwned(allocator, kind, marker, body);
    defer allocator.free(submitted_hash);
    return std.mem.eql(u8, previous_hash, submitted_hash);
}

fn projectContentHashOwned(allocator: Allocator, kind: []const u8, marker: []const u8, body: []const u8) ![]u8 {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(allocator);
    try source.appendSlice(allocator, kind);
    try source.append(allocator, 0);
    try source.appendSlice(allocator, marker);
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

fn loadProjectSummary(allocator: Allocator, db: *SqliteDb, project: []const u8, csrf_token: []const u8) !ProjectSummary {
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
            .csrf_token = csrf_token,
        };
    }

    return .{
        .id = try allocator.dupe(u8, ""),
        .name = try allocator.dupe(u8, project),
        .description = try allocator.dupe(u8, ""),
        .state = try allocator.dupe(u8, "open"),
        .status = try allocator.dupe(u8, cmd_common.default_project_status),
        .status_occurred_at = try allocator.dupe(u8, ""),
        .priority = try allocator.dupe(u8, ""),
        .start_at = try allocator.dupe(u8, ""),
        .end_at = try allocator.dupe(u8, ""),
        .created_at = try allocator.dupe(u8, ""),
        .author_principal = try allocator.dupe(u8, ""),
        .csrf_token = csrf_token,
    };
}

fn loadProjectMetrics(db: *SqliteDb, summary: *const ProjectSummary) !ProjectMetrics {
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

        var payload_note = (try parseProjectUpdatePayload(allocator, body)) orelse continue;
        errdefer payload_note.deinit(allocator);
        const note_occurred_at = try allocator.dupe(u8, occurred_at);
        errdefer allocator.free(note_occurred_at);
        const note_actor = try allocator.dupe(u8, actor);
        errdefer allocator.free(note_actor);
        return .{
            .body = payload_note.body,
            .health = payload_note.health,
            .occurred_at = note_occurred_at,
            .actor = note_actor,
        };
    }

    return emptyProjectUpdateNote(allocator);
}

fn projectHasLatestUpdateNote(allocator: Allocator, db: *SqliteDb, project_id: []const u8) !bool {
    if (project_id.len == 0) return false;
    var stmt = try db.prepare(
        \\SELECT body
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
    try stmt.bindText(1, project_id);

    while (try stmt.step()) {
        const body = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(body);
        var payload_note = (try parseProjectUpdatePayload(allocator, body)) orelse continue;
        payload_note.deinit(allocator);
        return true;
    }
    return false;
}

fn parseProjectUpdatePayload(allocator: Allocator, event_body: []const u8) !?ProjectUpdatePayload {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, event_body, .{}) catch return null;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return null,
    };
    const payload = switch (root.get("payload") orelse return null) {
        .object => |object| object,
        else => return null,
    };
    const update_body = event_json.jsonString(payload.get("update_body"));
    const health = projectUpdateHealthValue(event_json.jsonString(payload.get("update_health")) orelse "");
    if (update_body == null and health.len == 0) return null;
    const body = try allocator.dupe(u8, update_body orelse "");
    errdefer allocator.free(body);
    return .{
        .body = body,
        .health = try allocator.dupe(u8, health),
    };
}

fn emptyProjectUpdateNote(allocator: Allocator) !ProjectUpdateNote {
    return .{
        .body = try allocator.dupe(u8, ""),
        .health = try allocator.dupe(u8, ""),
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
    try appendTemplate(buf, allocator,
        \\<header class="project-overview-head">
        \\  <div class="project-overview-title">
        \\    <span class="project-overview-icon" aria-hidden="true"></span>
        \\    <div>
        \\      <p class="eyebrow">Project</p>
        \\      <h1>{project}</h1>
    , .{ .project = summary.name });
    try appendTemplate(buf, allocator,
        \\    </div>
        \\  </div>
        \\  <div class="project-overview-head-stats" aria-label="Project issue summary">
        \\    <span class="project-overview-issue-stat"><strong>{open_count}/{issue_count}</strong> issues</span>
        \\  </div>
        \\</header>
    , .{
        .issue_count = metrics.issue_count,
        .open_count = metrics.open_issue_count,
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
    project_id: []const u8,
    active: ProjectPageTab,
    csrf_token: []const u8,
) !void {
    try buf.appendSlice(allocator,
        \\<div class="project-overview-tabs">
        \\  <nav class="project-overview-primary-tabs" aria-label="Project tabs">
    );
    try appendProjectPageTab(buf, allocator, project, project_id, active, .overview, "Overview", "project-view-overview-icon", "overview", csrf_token);
    try appendProjectViewSwitcher(buf, allocator, project, project_id, active, csrf_token);
    try appendProjectPageTab(buf, allocator, project, project_id, active, .activity, "Activity", "button-icon icon-history", "activity", csrf_token);
    try buf.appendSlice(allocator,
        \\  </nav>
        \\</div>
    );
}

fn appendProjectPageTab(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    project: []const u8,
    project_id: []const u8,
    active: ProjectPageTab,
    tab: ProjectPageTab,
    label: []const u8,
    icon_class: []const u8,
    view_ref: []const u8,
    csrf_token: []const u8,
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

    if (project_id.len != 0) {
        try appendProjectDefaultViewFormOpen(buf, allocator, project, project_id, view_ref, csrf_token, "project-overview-tab-form");
        try appendTemplate(buf, allocator,
            \\<button class="project-overview-tab" type="submit"><span class="{icon_class}" aria-hidden="true"></span>{label}</button></form>
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

fn appendProjectViewSwitcher(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    project: []const u8,
    project_id: []const u8,
    active: ProjectPageTab,
    csrf_token: []const u8,
) !void {
    const active_label = projectSwitcherActiveLabel(active);
    const active_icon = projectSwitcherActiveIcon(active);
    try appendTemplate(buf, allocator,
        \\<details class="{classes}" data-popover-menu>
        \\  <summary class="project-overview-tab project-view-switcher-summary" aria-label="Project view switcher"><span class="{icon_class}" aria-hidden="true"></span><span>{label}</span><span class="project-choice-caret" aria-hidden="true"></span></summary>
        \\  <div class="project-view-switcher-menu" role="menu">
    , .{
        .classes = shared.classes("project-view-switcher", &.{shared.class("active", isProjectSwitcherActive(active))}),
        .icon_class = active_icon,
        .label = active_label,
    });
    try appendProjectSwitcherItem(buf, allocator, project, project_id, active, .table, "Table", "project-view-table-icon", project_views.projectViewValue(.table), csrf_token);
    try appendProjectSwitcherItem(buf, allocator, project, project_id, active, .board, "Board", "project-view-board-icon", project_views.projectViewValue(.board), csrf_token);
    try appendProjectSwitcherItem(buf, allocator, project, project_id, active, .roadmap, "Roadmap", "project-view-roadmap-icon", project_views.projectViewValue(.roadmap), csrf_token);
    try appendProjectSwitcherItem(buf, allocator, project, project_id, active, .issues, "Issues", "button-icon icon-issues", project_views.projectViewValue(.issues), csrf_token);
    try buf.appendSlice(allocator, "</div></details>");
}

fn appendProjectSwitcherItem(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    project: []const u8,
    project_id: []const u8,
    active: ProjectPageTab,
    tab: ProjectPageTab,
    label: []const u8,
    icon_class: []const u8,
    view_ref: []const u8,
    csrf_token: []const u8,
) !void {
    if (project_id.len != 0) {
        try appendProjectDefaultViewFormOpen(buf, allocator, project, project_id, view_ref, csrf_token, "project-view-switcher-form");
        try appendTemplate(buf, allocator,
            \\<button class="{classes}" type="submit" role="menuitem"><span class="{icon_class}" aria-hidden="true"></span><span>{label}</span></button></form>
        , .{
            .classes = shared.classes("project-view-switcher-item", &.{shared.class("active", active == tab)}),
            .icon_class = icon_class,
            .label = label,
        });
        return;
    }

    try appendTemplate(buf, allocator,
        \\<a class="{classes}" role="menuitem" href="
    , .{ .classes = shared.classes("project-view-switcher-item", &.{shared.class("active", active == tab)}) });
    try appendProjectViewHref(buf, allocator, project, view_ref);
    try buf.appendSlice(allocator, "\">");
    try appendTemplate(buf, allocator,
        \\<span class="{icon_class}" aria-hidden="true"></span><span>{label}</span></a>
    , .{
        .icon_class = icon_class,
        .label = label,
    });
}

fn appendProjectDefaultViewFormOpen(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    project: []const u8,
    project_id: []const u8,
    view_ref: []const u8,
    csrf_token: []const u8,
    class_name: []const u8,
) !void {
    try appendTemplate(buf, allocator,
        \\<form class="{class_name}" method="post" action="/projects/default-view"><input type="hidden" name="{csrf_field}" value="{csrf_token}"><input type="hidden" name="project" value="{project}"><input type="hidden" name="project_id" value="{project_id}"><input type="hidden" name="view" value="{view_ref}">
    , .{
        .class_name = class_name,
        .csrf_field = zwf.csrf.field_name,
        .csrf_token = csrf_token,
        .project = project,
        .project_id = project_id,
        .view_ref = view_ref,
    });
}

fn isProjectSwitcherActive(active: ProjectPageTab) bool {
    return active == .table or active == .board or active == .roadmap or active == .issues;
}

fn projectSwitcherActiveLabel(active: ProjectPageTab) []const u8 {
    return switch (active) {
        .table => "Table",
        .board => "Board",
        .roadmap => "Roadmap",
        .issues => "Issues",
        else => "Views",
    };
}

fn projectSwitcherActiveIcon(active: ProjectPageTab) []const u8 {
    return switch (active) {
        .table => "project-view-table-icon",
        .board => "project-view-board-icon",
        .roadmap => "project-view-roadmap-icon",
        .issues => "button-icon icon-issues",
        else => "project-view-board-icon",
    };
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

fn appendProjectUpdateSection(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: ?*SqliteDb,
    summary: *const ProjectSummary,
    note: *const ProjectUpdateNote,
    current_actor: ?[]const u8,
) !void {
    const note_has_update = projectUpdateNoteHasUpdate(note);
    const selected_health = projectUpdateHealthValue(if (note.health.len != 0) note.health else cmd_common.default_project_update_health);
    const health_tone = projectUpdateHealthTone(selected_health);
    try buf.appendSlice(allocator,
        \\<section class="project-overview-section project-markdown-section project-update-section">
        \\  <details class="project-markdown-edit project-update-edit" data-popover-menu>
        \\    <summary class="button secondary project-update-button"><span class="button-icon project-update-button-icon" aria-hidden="true"></span><span>Update</span></summary>
        \\    <form class="project-markdown-form" method="post" action="/projects/properties" data-project-markdown-form data-project-content-kind="project-update">
    );
    try appendProjectHiddenFields(buf, allocator, summary);
    try appendProjectHashFields(buf, allocator, "project-update", selected_health, note.body);
    try buf.appendSlice(allocator,
        \\      <input type="hidden" name="action" value="add-update">
    );
    try appendProjectUpdateHealthSelect(buf, allocator, selected_health);
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
    if (note.health.len != 0) try appendProjectUpdateHealthChip(buf, allocator, note.health);
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
        if (note_has_update) {
            try buf.appendSlice(allocator, "<p class=\"project-markdown-empty\">No update details.</p>");
        } else {
            try buf.appendSlice(allocator, "<p class=\"project-markdown-empty\">No update yet.</p>");
        }
    } else {
        try shared.appendMarkdownSource(buf, allocator, note.body, .{});
    }
    try buf.appendSlice(allocator, "</div>");
    if (note_has_update) {
        if (db) |project_db| {
            try appendProjectReactionBar(buf, allocator, project_db, "project", summary.id, summary, "", current_actor, "project-update-actions reaction-bar", true, "Reply to update");
        }
    }
    try buf.appendSlice(allocator, "</article>");
    if (note_has_update) {
        if (db) |project_db| {
            try appendProjectUpdateThread(buf, allocator, project_db, summary, current_actor);
        }
    }
    try buf.appendSlice(allocator, "</section>");
}

fn appendProjectUpdateThread(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    summary: *const ProjectSummary,
    current_actor: ?[]const u8,
) !void {
    try buf.appendSlice(allocator, "<div id=\"project-update-thread\" class=\"project-update-thread issue-timeline\">");
    try appendProjectUpdateComments(buf, allocator, db, summary, current_actor);
    try appendProjectUpdateCommentForm(buf, allocator, summary, current_actor);
    try appendProjectUpdateInlineReplyTemplate(buf, allocator, summary);
    try buf.appendSlice(allocator, "</div>");
}

fn appendProjectUpdateComments(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    summary: *const ProjectSummary,
    current_actor: ?[]const u8,
) !void {
    if (summary.id.len == 0) return;
    var stmt = try work_items.prepareCommentsStmt(db, "project", summary.id);
    defer stmt.deinit();
    var rows: std.ArrayList(work_items.CommentRow) = .empty;
    defer {
        for (rows.items) |row| row.deinit(allocator);
        rows.deinit(allocator);
    }
    while (try stmt.step()) {
        const row = try work_items.commentRowFromStmt(allocator, &stmt);
        errdefer row.deinit(allocator);
        try rows.append(allocator, row);
    }
    if (rows.items.len == 0) return;

    const rendered = try allocator.alloc(bool, rows.items.len);
    defer allocator.free(rendered);
    @memset(rendered, false);

    for (rows.items, 0..) |row, row_index| {
        if (isProjectThreadRootComment(rows.items, row)) {
            try appendProjectUpdateCommentBranch(buf, allocator, db, rows.items, rendered, row_index, 0, summary, current_actor);
        }
    }
    for (rows.items, 0..) |_, row_index| {
        if (!rendered[row_index]) {
            try appendProjectUpdateCommentBranch(buf, allocator, db, rows.items, rendered, row_index, 0, summary, current_actor);
        }
    }
}

fn isProjectThreadRootComment(rows: []const work_items.CommentRow, row: work_items.CommentRow) bool {
    if (row.reply_parent_id.len == 0) return true;
    return projectCommentIndexById(rows, row.reply_parent_id) == null;
}

fn projectCommentIndexById(rows: []const work_items.CommentRow, id: []const u8) ?usize {
    for (rows, 0..) |row, row_index| {
        if (std.mem.eql(u8, row.id, id)) return row_index;
    }
    return null;
}

fn appendProjectUpdateCommentBranch(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    rows: []const work_items.CommentRow,
    rendered: []bool,
    row_index: usize,
    depth: usize,
    summary: *const ProjectSummary,
    current_actor: ?[]const u8,
) !void {
    if (rendered[row_index]) return;
    rendered[row_index] = true;

    const row = rows[row_index];
    try appendProjectUpdateCommentRow(buf, allocator, db, row, depth, summary, current_actor);

    for (rows, 0..) |child, child_index| {
        if (!rendered[child_index] and child.reply_parent_id.len != 0 and std.mem.eql(u8, child.reply_parent_id, row.id)) {
            try appendProjectUpdateCommentBranch(buf, allocator, db, rows, rendered, child_index, depth + 1, summary, current_actor);
        }
    }
}

fn appendProjectUpdateCommentRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    row: work_items.CommentRow,
    depth: usize,
    summary: *const ProjectSummary,
    current_actor: ?[]const u8,
) !void {
    const anchor = try std.fmt.allocPrint(allocator, "comment-{s}", .{row.id[0..@min(row.id.len, 7)]});
    defer allocator.free(anchor);
    var comment_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const comment_ref = util.shortObjectRef(&comment_ref_buf, row.id);
    const comment_ref_value = try std.fmt.allocPrint(allocator, "comment:{s}", .{comment_ref});
    defer allocator.free(comment_ref_value);
    const depth_class = projectCommentDepthClass(depth);

    try appendTemplate(buf, allocator,
        \\<div class="{classes}" id="{anchor}"><div class="issue-timeline-avatar">
    , .{
        .classes = shared.classes("issue-timeline-item project-update-comment-item", &.{
            shared.class("is-reply", row.isReply() or depth > 0),
            shared.class(depth_class, depth_class.len != 0),
        }),
        .anchor = anchor,
    });
    try shared.appendAvatarWithUrl(buf, allocator, row.display_author, row.source_avatar_url, "issue-detail-avatar");
    try appendTemplate(buf, allocator,
        \\</div><article class="issue-comment-box project-update-comment-box"><header class="issue-comment-head"><div><strong>{author}</strong><span>commented
    , .{ .author = row.display_author });
    try buf.append(allocator, ' ');
    try appendRelativeTime(buf, allocator, row.created_at);
    try buf.appendSlice(allocator, "</span></div>");
    try issues_page.appendIssueActionMenu(buf, allocator, anchor, comment_ref_value, row.body, !row.redacted and row.body.len != 0, "");
    try buf.appendSlice(allocator, "</header>");
    if (row.isReply()) {
        try buf.appendSlice(allocator, "<p class=\"reply-note\">Reply to ");
        if (row.reply_parent_id.len != 0) {
            var reply_ref_buf: [util.short_object_ref_len]u8 = undefined;
            const reply_ref = util.shortObjectRef(&reply_ref_buf, row.reply_parent_id);
            try appendTemplate(buf, allocator, "comment:{reply_ref}", .{ .reply_ref = reply_ref });
        } else {
            try appendTemplate(buf, allocator, "{reply_parent_hash}", .{ .reply_parent_hash = row.reply_parent_hash[0..@min(row.reply_parent_hash.len, 12)] });
        }
        try buf.appendSlice(allocator, "</p>");
    }
    try buf.appendSlice(allocator, "<div class=\"markdown-body\">");
    if (row.redacted) {
        try buf.appendSlice(allocator, "<p class=\"muted\">Comment redacted.</p>");
    } else {
        try shared.appendMarkdownSource(buf, allocator, row.body, .{});
    }
    try buf.appendSlice(allocator, "</div>");
    try appendProjectReactionBar(buf, allocator, db, "comment", row.id, summary, comment_ref_value, current_actor, "reaction-bar project-comment-reaction-bar", true, "Reply");
    try buf.appendSlice(allocator, "</article></div>");
}

fn projectCommentDepthClass(depth: usize) []const u8 {
    return switch (@min(depth, 3)) {
        0 => "",
        1 => "comment-depth-1",
        2 => "comment-depth-2",
        else => "comment-depth-3",
    };
}

fn appendProjectUpdateCommentForm(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    summary: *const ProjectSummary,
    current_actor: ?[]const u8,
) !void {
    try buf.appendSlice(allocator,
        \\<div class="issue-timeline-item issue-comment-form-item project-update-comment-form-item">
        \\  <div class="issue-timeline-avatar">
    );
    try shared.appendCurrentActorAvatar(buf, allocator, current_actor, "issue-detail-avatar issue-comment-form-avatar");
    try buf.appendSlice(allocator,
        \\  </div>
        \\  <form class="issue-comment-box issue-comment-form project-update-comment-form" method="post" action="/projects/comments">
    );
    try appendProjectHiddenFields(buf, allocator, summary);
    try buf.appendSlice(allocator,
        \\    <input type="hidden" name="action" value="comment">
        \\    <input type="hidden" name="reply_parent_ref" value="" data-reply-parent-ref>
    );
    try shared.appendMarkdownEditor(buf, allocator, .{ .placeholder = "Reply to the update" });
    try buf.appendSlice(allocator,
        \\    <div class="issue-comment-form-actions">
        \\      <button class="button primary" type="submit">Reply</button>
        \\    </div>
        \\  </form>
        \\</div>
    );
}

fn appendProjectUpdateInlineReplyTemplate(buf: *std.ArrayList(u8), allocator: Allocator, summary: *const ProjectSummary) !void {
    try buf.appendSlice(allocator, "<template data-comment-reply-form-template>");
    try buf.appendSlice(allocator, "<form class=\"inline-comment-reply-form issue-comment-form project-update-comment-form\" method=\"post\" action=\"/projects/comments\" data-inline-comment-reply-form>");
    try appendProjectHiddenFields(buf, allocator, summary);
    try buf.appendSlice(allocator,
        \\    <input type="hidden" name="action" value="comment">
        \\    <input type="hidden" name="reply_parent_ref" value="" data-reply-parent-ref>
    );
    try shared.appendMarkdownEditor(buf, allocator, .{ .rows = 4, .placeholder = "Reply" });
    try buf.appendSlice(allocator,
        \\    <div class="issue-comment-form-actions">
        \\      <button class="button secondary" type="button" data-comment-reply-cancel>Cancel</button>
        \\      <button class="button primary" type="submit">Reply</button>
        \\    </div>
        \\  </form>
        \\</template>
    );
}

fn appendProjectReactionBar(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    object_kind: []const u8,
    object_id: []const u8,
    summary: *const ProjectSummary,
    target_ref: []const u8,
    current_actor: ?[]const u8,
    class_name: []const u8,
    include_reply: bool,
    reply_label: []const u8,
) !void {
    var reactions: std.ArrayList(ReactionSummary) = .empty;
    defer {
        for (reactions.items) |*item| item.deinit(allocator);
        reactions.deinit(allocator);
    }

    try appendTemplate(buf, allocator, "<div class=\"{class_name}\">", .{ .class_name = class_name });
    if (include_reply) try appendProjectReplyButton(buf, allocator, target_ref, reply_label);
    var stmt = try db.prepare(
        \\SELECT emoji, COUNT(DISTINCT actor_principal),
        \\       SUM(CASE WHEN actor_principal = ? THEN 1 ELSE 0 END)
        \\FROM reactions
        \\WHERE object_kind = ? AND object_id = ?
        \\GROUP BY emoji
        \\ORDER BY MIN(created_at), emoji
    );
    defer stmt.deinit();
    try stmt.bindText(1, current_actor orelse "");
    try stmt.bindText(2, object_kind);
    try stmt.bindText(3, object_id);

    while (try stmt.step()) {
        const emoji = try stmt.columnTextDup(allocator, 0);
        const count = stmt.columnInt64(1);
        const reacted = current_actor != null and stmt.columnInt64(2) > 0;
        errdefer allocator.free(emoji);
        try reactions.append(allocator, .{
            .emoji = emoji,
            .count = count,
            .reacted = reacted,
        });
    }

    try appendProjectReactionPicker(buf, allocator, summary, object_kind, target_ref, reactions.items);
    for (reactions.items) |item| {
        try appendProjectReactionButton(buf, allocator, summary, object_kind, target_ref, item.emoji, item.emoji, item.count, item.reacted);
    }
    try buf.appendSlice(allocator, "</div>");
}

fn appendProjectReplyButton(buf: *std.ArrayList(u8), allocator: Allocator, target_ref: []const u8, label: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<button class="comment-reply-button project-update-action" type="button" data-comment-reply-ref="{target_ref}" aria-label="{label}" title="{label}"><span class="issue-comments-icon" aria-hidden="true"></span></button>
    , .{
        .target_ref = target_ref,
        .label = label,
    });
}

fn appendProjectReactionPicker(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    summary: *const ProjectSummary,
    object_kind: []const u8,
    target_ref: []const u8,
    reactions: []const ReactionSummary,
) !void {
    try buf.appendSlice(allocator,
        \\<details class="reaction-picker" data-popover-menu>
        \\  <summary class="reaction-add-button project-update-action" aria-label="Add reaction" title="Add reaction"><span class="reaction-add-icon" aria-hidden="true"></span></summary>
        \\  <div class="reaction-popover" role="menu" aria-label="Add reaction">
    );
    for (reaction_choices.choices) |choice| {
        try appendProjectReactionChoiceButton(buf, allocator, summary, object_kind, target_ref, choice, reactionWasSelected(reactions, choice.value));
    }
    try buf.appendSlice(allocator, "</div></details>");
}

fn appendProjectReactionChoiceButton(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    summary: *const ProjectSummary,
    object_kind: []const u8,
    target_ref: []const u8,
    choice: ReactionChoice,
    reacted: bool,
) !void {
    try appendProjectReactionFormOpen(buf, allocator, summary, "reaction-choice-form", if (reacted) "remove-reaction" else "add-reaction", object_kind, target_ref, choice.value);
    try appendTemplate(buf, allocator,
        \\<button{class_attr} type="submit" role="menuitem" aria-pressed="{pressed}" title="{title}"><span class="reaction-emoji">
    , .{
        .class_attr = shared.classAttr("reaction-choice-button", &.{
            shared.class("selected", reacted),
            shared.class("is-selected", reacted),
        }),
        .pressed = reacted,
        .title = if (reacted) "Remove your reaction" else choice.title,
    });
    try shared.appendHtml(buf, allocator, choice.label);
    try buf.appendSlice(allocator, "</span></button></form>");
}

fn appendProjectReactionButton(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    summary: *const ProjectSummary,
    object_kind: []const u8,
    target_ref: []const u8,
    emoji_value: []const u8,
    emoji_label: []const u8,
    count: i64,
    reacted: bool,
) !void {
    try appendProjectReactionFormOpen(buf, allocator, summary, "reaction-form", if (reacted) "remove-reaction" else "add-reaction", object_kind, target_ref, emoji_value);
    try appendTemplate(buf, allocator,
        \\<button{class_attr} type="submit" aria-pressed="{pressed}" title="{title}"><span class="reaction-emoji">
    , .{
        .class_attr = shared.classAttr("reaction-button", &.{
            shared.class("selected", reacted),
            shared.class("is-selected", reacted),
        }),
        .pressed = reacted,
        .title = if (reacted) "Remove your reaction" else "Add reaction",
    });
    try shared.appendHtml(buf, allocator, emoji_label);
    try appendTemplate(buf, allocator, "</span><span class=\"reaction-count\">{count}</span></button></form>", .{ .count = count });
}

fn appendProjectReactionFormOpen(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    summary: *const ProjectSummary,
    form_class: []const u8,
    action: []const u8,
    object_kind: []const u8,
    target_ref: []const u8,
    emoji_value: []const u8,
) !void {
    try appendTemplate(buf, allocator, "<form class=\"{form_class}\" method=\"post\" action=\"/projects/comments\">", .{ .form_class = form_class });
    try appendProjectHiddenFields(buf, allocator, summary);
    try appendTemplate(buf, allocator,
        \\<input type="hidden" name="action" value="{action}"><input type="hidden" name="target_kind" value="{object_kind}">
    , .{
        .action = action,
        .object_kind = object_kind,
    });
    if (target_ref.len != 0) {
        try appendTemplate(buf, allocator,
            \\<input type="hidden" name="target_ref" value="{target_ref}">
        , .{ .target_ref = target_ref });
    }
    try appendTemplate(buf, allocator,
        \\<input type="hidden" name="emoji" value="{emoji_value}">
    , .{ .emoji_value = emoji_value });
}

fn reactionWasSelected(reactions: []const ReactionSummary, emoji: []const u8) bool {
    for (reactions) |item| {
        if (std.mem.eql(u8, item.emoji, emoji)) return item.reacted;
    }
    return false;
}

fn appendProjectDescription(buf: *std.ArrayList(u8), allocator: Allocator, summary: *const ProjectSummary) !void {
    try buf.appendSlice(allocator,
        \\<section class="project-overview-section project-markdown-section project-description-section">
        \\  <details class="project-markdown-edit project-description-edit" data-popover-menu>
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

fn projectUpdateNoteHasUpdate(note: *const ProjectUpdateNote) bool {
    return note.body.len != 0 or note.health.len != 0 or note.occurred_at.len != 0 or note.actor.len != 0;
}

fn appendProjectUpdateHealthSelect(buf: *std.ArrayList(u8), allocator: Allocator, selected_health: []const u8) !void {
    const selected_update_health = projectUpdateHealthValue(selected_health);
    try buf.appendSlice(allocator,
        \\<details class="project-update-health-menu" data-popover-menu data-project-update-health-menu>
        \\  <summary class="project-update-health-control" aria-label="Change update health">
    );
    for (cmd_common.project_update_health_values) |health| {
        try appendTemplate(buf, allocator,
            \\<span class="project-update-health-selected project-update-health-selected-{class}">
        , .{ .class = projectUpdateHealthValueClass(health) });
        try appendProjectUpdateHealthTriggerChip(buf, allocator, health);
        try buf.appendSlice(allocator, "</span>");
    }
    try buf.appendSlice(allocator,
        \\  </summary>
        \\  <div class="project-update-health-options" role="radiogroup" aria-label="Update health">
    );
    for (cmd_common.project_update_health_values) |health| {
        try appendTemplate(buf, allocator,
            \\<label class="project-update-health-option tone-{tone}">
            \\  <input type="radio" name="update_health" value="{health}" required
        , .{
            .tone = projectUpdateHealthTone(health),
            .health = health,
        });
        if (std.mem.eql(u8, selected_update_health, health)) try buf.appendSlice(allocator, " checked");
        try buf.appendSlice(allocator, ">");
        try appendProjectUpdateHealthChip(buf, allocator, health);
        try buf.appendSlice(allocator,
            \\  <span class="project-update-health-check" aria-hidden="true"></span>
            \\</label>
        );
    }
    try buf.appendSlice(allocator,
        \\  </div>
        \\</details>
    );
}

fn appendProjectUpdateHealthChip(buf: *std.ArrayList(u8), allocator: Allocator, health: []const u8) !void {
    const update_health = projectUpdateHealthValue(health);
    try appendTemplate(buf, allocator,
        \\<span class="project-update-health-chip tone-{tone}"><span class="project-update-health-mark" aria-hidden="true"></span>{health}</span>
    , .{
        .tone = projectUpdateHealthTone(update_health),
        .health = projectUpdateHealthLabel(update_health),
    });
}

fn appendProjectUpdateHealthTriggerChip(buf: *std.ArrayList(u8), allocator: Allocator, health: []const u8) !void {
    const update_health = projectUpdateHealthValue(health);
    try appendTemplate(buf, allocator,
        \\<span class="project-update-health-chip project-update-health-trigger-chip tone-{tone}"><span class="project-update-health-mark" aria-hidden="true"></span>{health}<span class="project-update-health-chevron" aria-hidden="true"></span></span>
    , .{
        .tone = projectUpdateHealthTone(update_health),
        .health = projectUpdateHealthLabel(update_health),
    });
}

fn projectUpdateHealthValue(value: []const u8) []const u8 {
    return cmd_common.canonicalProjectUpdateHealth(value);
}

fn projectUpdateHealthLabel(value: []const u8) []const u8 {
    return cmd_common.projectUpdateHealthLabel(value);
}

fn projectUpdateHealthValueClass(value: []const u8) []const u8 {
    const health = projectUpdateHealthValue(value);
    if (std.mem.eql(u8, health, "on_track")) return "on-track";
    if (std.mem.eql(u8, health, "at_risk")) return "at-risk";
    if (std.mem.eql(u8, health, "off_track")) return "off-track";
    return "none";
}

fn projectUpdateHealthTone(value: []const u8) []const u8 {
    return projectUpdateHealthValueClass(value);
}

fn appendProjectLifecycleStatusChip(buf: *std.ArrayList(u8), allocator: Allocator, status: []const u8) !void {
    const project_status = projectLifecycleStatusValue(status);
    try appendTemplate(buf, allocator,
        \\<span class="project-lifecycle-status-chip tone-{tone}"><span class="project-lifecycle-status-mark" aria-hidden="true"></span>{status}</span>
    , .{
        .tone = projectLifecycleStatusTone(project_status),
        .status = projectLifecycleStatusLabel(project_status),
    });
}

fn appendProjectLifecycleStatusTriggerChip(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    status: []const u8,
    extra_class: []const u8,
    chevron_class: []const u8,
) !void {
    const project_status = projectLifecycleStatusValue(status);
    try appendTemplate(buf, allocator,
        \\<span class="project-lifecycle-status-chip {extra_class} tone-{tone}"><span class="project-lifecycle-status-mark" aria-hidden="true"></span>{status}<span class="{chevron_class}" aria-hidden="true"></span></span>
    , .{
        .extra_class = extra_class,
        .tone = projectLifecycleStatusTone(project_status),
        .status = projectLifecycleStatusLabel(project_status),
        .chevron_class = chevron_class,
    });
}

fn projectLifecycleStatusValue(status: []const u8) []const u8 {
    return cmd_common.canonicalProjectStatus(status);
}

fn projectLifecycleStatusLabel(status: []const u8) []const u8 {
    return if (status.len == 0) "No status" else status;
}

fn projectLifecycleStatusTone(status: []const u8) []const u8 {
    if (std.mem.eql(u8, status, "Backlog")) return "backlog";
    if (std.mem.eql(u8, status, "Planned")) return "planned";
    if (std.mem.eql(u8, status, "Completed")) return "completed";
    if (std.mem.eql(u8, status, "Canceled")) return "canceled";
    if (std.mem.eql(u8, status, "In Progress")) return "progress";
    return "neutral";
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
        \\<section class="project-overview-side-panel project-properties-panel">
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
    const start_label = if (summary.start_at.len != 0) try dateLabelOwned(allocator, summary.start_at) else try allocator.dupe(u8, "No start date");
    defer allocator.free(start_label);
    const end_label = if (summary.end_at.len != 0) try dateLabelOwned(allocator, summary.end_at) else try allocator.dupe(u8, "No end date");
    defer allocator.free(end_label);
    try appendProjectDateRangeProperty(buf, allocator, summary, start_label, end_label);
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
    const current_status = projectLifecycleStatusValue(summary.status);
    try appendProjectPropertyChipMenuStart(buf, allocator, "Status", "Set status");
    if (summary.status.len == 0) {
        try appendProjectPropertyEmptyTrigger(buf, allocator, "No status");
    } else {
        try appendProjectStatusTriggerChip(buf, allocator, current_status);
    }
    try appendProjectPropertyChipMenuPopoverStart(buf, allocator, "Set status");
    try appendProjectMenuGroupStart(buf, allocator, "Statuses");
    for (cmd_common.project_status_values) |status| {
        try appendProjectValueActionRow(buf, allocator, summary, "set-status", "status", status, status, std.mem.eql(u8, current_status, status), .status);
    }
    try appendProjectMenuGroupEnd(buf, allocator);
    try appendProjectPropertyMenuEnd(buf, allocator);
}

fn appendProjectPriorityProperty(buf: *std.ArrayList(u8), allocator: Allocator, summary: *const ProjectSummary) !void {
    try appendProjectPropertyChipMenuStart(buf, allocator, "Priority", "Set priority");
    if (summary.priority.len == 0) {
        try appendProjectPropertyEmptyTrigger(buf, allocator, "No priority");
    } else {
        try appendProjectPriorityTriggerChip(buf, allocator, summary.priority);
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
        \\</summary><div class="issue-sidebar-popover project-property-popover" role="dialog" aria-label="{menu_label}"><div class="issue-sidebar-popover-title">{menu_label}</div>
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

fn appendProjectDateRangeProperty(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    summary: *const ProjectSummary,
    start_label: []const u8,
    end_label: []const u8,
) !void {
    try buf.appendSlice(allocator,
        \\<div class="project-overview-date-range-row">
        \\  <dt>Dates</dt>
        \\  <dd class="project-property-date-range-links">
    );
    try appendProjectDatePickerMenu(buf, allocator, summary, "Start date", "set-start-date", "start_at", summary.start_at, start_label, "No start date", "", summary.end_at);
    try buf.appendSlice(allocator, "<span class=\"project-property-date-separator\" aria-hidden=\"true\">-</span>");
    try appendProjectDatePickerMenu(buf, allocator, summary, "End date", "set-end-date", "end_at", summary.end_at, end_label, "No end date", summary.start_at, "");
    try buf.appendSlice(allocator, "</dd></div>");
}

fn appendProjectDatePickerMenu(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    summary: *const ProjectSummary,
    menu_label: []const u8,
    action: []const u8,
    input_name: []const u8,
    input_value: []const u8,
    display_value: []const u8,
    placeholder: []const u8,
    invalid_until: []const u8,
    invalid_from: []const u8,
) !void {
    try appendTemplate(buf, allocator,
        \\<details class="project-property-menu project-property-date-menu" data-popover-menu data-issue-sidebar-menu><summary class="project-property-date-link" aria-label="{menu_label}" title="{menu_label}"><span>{display_value}</span></summary><div class="issue-sidebar-popover project-property-popover" role="dialog" aria-label="{menu_label}"><div class="issue-sidebar-popover-title">{menu_label}</div>
    , .{
        .menu_label = menu_label,
        .display_value = display_value,
    });
    try buf.appendSlice(allocator, "<form class=\"project-property-date-form project-property-date-picker-form\" method=\"post\" action=\"/projects/properties\">");
    try appendProjectHiddenFields(buf, allocator, summary);
    try appendTemplate(buf, allocator,
        \\<input type="hidden" name="action" value="{action}">
        \\<input type="date" name="{input_name}" value="{input_value}" aria-label="{menu_label}" data-date-picker data-date-picker-inline="yes" data-date-picker-autosubmit="yes" data-date-picker-placeholder="{placeholder}"
    , .{
        .action = action,
        .input_name = input_name,
        .input_value = input_value,
        .menu_label = menu_label,
        .placeholder = placeholder,
    });
    if (invalid_until.len != 0) {
        try appendTemplate(buf, allocator, " data-date-picker-invalid-until=\"{invalid_until}\"", .{ .invalid_until = invalid_until });
    }
    if (invalid_from.len != 0) {
        try appendTemplate(buf, allocator, " data-date-picker-invalid-from=\"{invalid_from}\"", .{ .invalid_from = invalid_from });
    }
    try buf.appendSlice(allocator, "></form></div></details>");
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
        \\         ld.priority,
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
        \\         ld.priority,
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
        \\<input type="hidden" name="{csrf_field}" value="{csrf_token}"><input type="hidden" name="project_id" value="{project_id}"><input type="hidden" name="project" value="{project}">
    , .{
        .csrf_field = zwf.csrf.field_name,
        .csrf_token = summary.csrf_token,
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
    try appendProjectLifecycleStatusChip(buf, allocator, status);
}

fn appendProjectStatusTriggerChip(buf: *std.ArrayList(u8), allocator: Allocator, status: []const u8) !void {
    try appendProjectLifecycleStatusTriggerChip(buf, allocator, status, "project-property-trigger-chip", "project-property-chip-chevron");
}

fn appendProjectPriorityChip(buf: *std.ArrayList(u8), allocator: Allocator, priority: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<span class="issue-row-priority issue-row-priority-{tone}" title="Priority: {priority}" aria-label="Priority: {priority}">{priority}</span>
    , .{
        .tone = project_issue_render.priorityTone(priority),
        .priority = priority,
    });
}

fn appendProjectPriorityTriggerChip(buf: *std.ArrayList(u8), allocator: Allocator, priority: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<span class="project-priority-trigger"><span class="issue-row-priority issue-row-priority-{tone}" title="Priority: {priority}" aria-label="Priority: {priority}">{priority}</span><span class="project-property-chip-chevron" aria-hidden="true"></span></span>
    , .{
        .tone = project_issue_render.priorityTone(priority),
        .priority = priority,
    });
}

fn appendProjectPropertyEmptyTrigger(buf: *std.ArrayList(u8), allocator: Allocator, label: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<span class="project-property-empty project-property-empty-trigger">{label}<span class="project-property-chip-chevron" aria-hidden="true"></span></span>
    , .{ .label = label });
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
        .description = try std.testing.allocator.dupe(u8, "Internal roadmap"),
        .state = try std.testing.allocator.dupe(u8, "open"),
        .status = try std.testing.allocator.dupe(u8, cmd_common.default_project_status),
        .status_occurred_at = try std.testing.allocator.dupe(u8, ""),
        .priority = try std.testing.allocator.dupe(u8, ""),
        .start_at = try std.testing.allocator.dupe(u8, ""),
        .end_at = try std.testing.allocator.dupe(u8, ""),
        .created_at = try std.testing.allocator.dupe(u8, ""),
        .author_principal = try std.testing.allocator.dupe(u8, ""),
        .csrf_token = "token-123",
    };
    defer summary.deinit(std.testing.allocator);
    const metrics = ProjectMetrics{
        .issue_count = 35,
        .open_issue_count = 24,
        .closed_issue_count = 11,
    };

    try appendProjectOverviewHeader(&buf, std.testing.allocator, &summary, &metrics);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<h1>Release &amp; Plan</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<h1>@Release") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Internal roadmap") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "No milestones") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<strong>24/35</strong> issues") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, ">24</strong> open") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, ">11</strong> closed") == null);
}

test "project latest update renders update health instead of lifecycle status" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var summary = ProjectSummary{
        .id = try std.testing.allocator.dupe(u8, "p1"),
        .name = try std.testing.allocator.dupe(u8, "Release"),
        .description = try std.testing.allocator.dupe(u8, ""),
        .state = try std.testing.allocator.dupe(u8, "open"),
        .status = try std.testing.allocator.dupe(u8, cmd_common.default_project_status),
        .status_occurred_at = try std.testing.allocator.dupe(u8, ""),
        .priority = try std.testing.allocator.dupe(u8, ""),
        .start_at = try std.testing.allocator.dupe(u8, ""),
        .end_at = try std.testing.allocator.dupe(u8, ""),
        .created_at = try std.testing.allocator.dupe(u8, ""),
        .author_principal = try std.testing.allocator.dupe(u8, ""),
        .csrf_token = "token-123",
    };
    defer summary.deinit(std.testing.allocator);
    var note = ProjectUpdateNote{
        .body = try std.testing.allocator.dupe(u8, "Needs attention"),
        .health = try std.testing.allocator.dupe(u8, "at_risk"),
        .occurred_at = try std.testing.allocator.dupe(u8, ""),
        .actor = try std.testing.allocator.dupe(u8, ""),
    };
    defer note.deinit(std.testing.allocator);

    try appendProjectUpdateSection(&buf, std.testing.allocator, null, &summary, &note, null);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "At risk") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "name=\"update_health\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "name=\"_csrf\" value=\"token-123\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Planned") == null);
}

test "project latest update hides reply thread until update exists" {
    var db = try SqliteDb.open(std.testing.allocator, ":memory:", index.sqlite.SQLITE_OPEN_READWRITE | index.sqlite.SQLITE_OPEN_CREATE, true);
    defer db.deinit();
    try index.createIndexSchema(&db);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var summary = ProjectSummary{
        .id = try std.testing.allocator.dupe(u8, "p1"),
        .name = try std.testing.allocator.dupe(u8, "Release"),
        .description = try std.testing.allocator.dupe(u8, ""),
        .state = try std.testing.allocator.dupe(u8, "open"),
        .status = try std.testing.allocator.dupe(u8, cmd_common.default_project_status),
        .status_occurred_at = try std.testing.allocator.dupe(u8, ""),
        .priority = try std.testing.allocator.dupe(u8, ""),
        .start_at = try std.testing.allocator.dupe(u8, ""),
        .end_at = try std.testing.allocator.dupe(u8, ""),
        .created_at = try std.testing.allocator.dupe(u8, ""),
        .author_principal = try std.testing.allocator.dupe(u8, ""),
        .csrf_token = "token-123",
    };
    defer summary.deinit(std.testing.allocator);
    var empty_note = try emptyProjectUpdateNote(std.testing.allocator);
    defer empty_note.deinit(std.testing.allocator);

    try appendProjectUpdateSection(&buf, std.testing.allocator, &db, &summary, &empty_note, null);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "No update yet.") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "project-update-thread") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Reply to update") == null);

    buf.clearRetainingCapacity();
    var note = ProjectUpdateNote{
        .body = try std.testing.allocator.dupe(u8, "Shipped milestone one"),
        .health = try std.testing.allocator.dupe(u8, "on_track"),
        .occurred_at = try std.testing.allocator.dupe(u8, "2026-05-20T08:00:00Z"),
        .actor = try std.testing.allocator.dupe(u8, "alice"),
    };
    defer note.deinit(std.testing.allocator);

    try appendProjectUpdateSection(&buf, std.testing.allocator, &db, &summary, &note, null);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "project-update-thread") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Reply to update") != null);
}

test "project latest update detection ignores property-only updates" {
    var db = try SqliteDb.open(std.testing.allocator, ":memory:", index.sqlite.SQLITE_OPEN_READWRITE | index.sqlite.SQLITE_OPEN_CREATE, true);
    defer db.deinit();
    try index.createIndexSchema(&db);

    try db.exec(
        \\INSERT INTO events(ref, "commit", event_hash, tree, subject, body, empty_tree, valid_json, event_type, object_kind, object_id, actor_principal, actor_device, seq, occurred_at, domain_status, rejection_reason)
        \\VALUES ('refs/gitomi/events/alice', 'commit-1', 'hash-1', 'tree', 'subject', '{"payload":{"status":"Planned"}}', 0, 1, 'project.updated', 'project', 'p1', 'alice', 'device', 1, '2026-05-20T08:00:00Z', 'accepted', '');
    );
    try std.testing.expect(!(try projectHasLatestUpdateNote(std.testing.allocator, &db, "p1")));

    try db.exec(
        \\INSERT INTO events(ref, "commit", event_hash, tree, subject, body, empty_tree, valid_json, event_type, object_kind, object_id, actor_principal, actor_device, seq, occurred_at, domain_status, rejection_reason)
        \\VALUES ('refs/gitomi/events/alice', 'commit-2', 'hash-2', 'tree', 'subject', '{"payload":{"update_body":"Shipped milestone one","update_health":"on_track"}}', 0, 1, 'project.updated', 'project', 'p1', 'alice', 'device', 2, '2026-05-20T08:05:00Z', 'accepted', '');
    );
    try std.testing.expect(try projectHasLatestUpdateNote(std.testing.allocator, &db, "p1"));
}

test "project issues tab stays in project workspace" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendProjectPageTabs(&buf, std.testing.allocator, "Release Plan", "", .overview, "token-123");

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "href=\"/projects?project=Release%20Plan&amp;view=issues\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "href=\"/issues?project=") == null);
}

test "project activity href scopes settings activity to project" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendProjectActivityHref(&buf, std.testing.allocator, "Release Plan");

    try std.testing.expectEqualStrings("/events?project=Release%20Plan", buf.items);
}

test "project date row renders two individual date pickers" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var summary = ProjectSummary{
        .id = try std.testing.allocator.dupe(u8, "p1"),
        .name = try std.testing.allocator.dupe(u8, "Release"),
        .description = try std.testing.allocator.dupe(u8, ""),
        .state = try std.testing.allocator.dupe(u8, "open"),
        .status = try std.testing.allocator.dupe(u8, cmd_common.default_project_status),
        .status_occurred_at = try std.testing.allocator.dupe(u8, ""),
        .priority = try std.testing.allocator.dupe(u8, ""),
        .start_at = try std.testing.allocator.dupe(u8, "2026-05-17"),
        .end_at = try std.testing.allocator.dupe(u8, "2026-05-28"),
        .created_at = try std.testing.allocator.dupe(u8, ""),
        .author_principal = try std.testing.allocator.dupe(u8, ""),
        .csrf_token = "token-123",
    };
    defer summary.deinit(std.testing.allocator);

    try appendProjectDateRangeProperty(&buf, std.testing.allocator, &summary, "May 17", "May 28");

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "project-property-date-range-links") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, ">May 17</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, ">May 28</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "value=\"set-start-date\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "value=\"set-end-date\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "data-date-picker-autosubmit=\"yes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "value=\"set-dates\"") == null);
}
