const std = @import("std");
const cmd_common = @import("../../cmd_common.zig");
const index = @import("../../index.zig");
const issue = @import("../../issue.zig");
const issue_form = @import("form.zig");
const issue_relationships = @import("relationships.zig");
const project_issue_render = @import("../projects/issue_render.zig");
const project_views = @import("../projects/views.zig");
const repo_mod = @import("../../repo.zig");
const shared = @import("../shared.zig");
const util = @import("../../util.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const SqliteDb = index.SqliteDb;
const appendTemplate = shared.appendTemplate;
const createIssueProjectEvent = issue.createIssueProjectEvent;
const createIssueStringEvent = issue.createIssueStringEvent;
const ensureIndex = index.ensureIndex;
const isIssuePriority = cmd_common.isIssuePriority;
const isIssueStatus = cmd_common.isIssueStatus;
const isIssueType = cmd_common.isIssueType;
const commitHref = shared.commitHref;
const pullHref = shared.pullHref;
const sendRedirect = shared.sendRedirect;
const sendPlainResponse = shared.sendPlainResponse;
const formValueOwned = issue_form.formValueOwned;
const RelationshipItem = issue_relationships.RelationshipItem;

const issue_sidebar_csrf_field = "csrf_token";
const issue_sidebar_csrf_token_len = 64;

var issue_sidebar_csrf_mutex: std.Thread.Mutex = .{};
var issue_sidebar_csrf_ready = false;
var issue_sidebar_csrf_token: [issue_sidebar_csrf_token_len]u8 = undefined;

fn issueSidebarCsrfToken() []const u8 {
    issue_sidebar_csrf_mutex.lock();
    defer issue_sidebar_csrf_mutex.unlock();

    if (!issue_sidebar_csrf_ready) {
        var random_bytes: [issue_sidebar_csrf_token_len / 2]u8 = undefined;
        std.crypto.random.bytes(&random_bytes);
        const hex = "0123456789abcdef";
        for (random_bytes, 0..) |byte, i| {
            issue_sidebar_csrf_token[i * 2] = hex[@as(usize, byte >> 4)];
            issue_sidebar_csrf_token[i * 2 + 1] = hex[@as(usize, byte & 0x0f)];
        }
        issue_sidebar_csrf_ready = true;
    }

    return issue_sidebar_csrf_token[0..];
}

fn validateIssueSidebarCsrf(allocator: Allocator, stream: std.net.Stream, form_body: []const u8) !bool {
    const token_owned = (try formValueOwned(allocator, form_body, issue_sidebar_csrf_field)) orelse {
        try sendPlainResponse(allocator, stream, 403, "Forbidden", "Invalid sidebar form token\n");
        return false;
    };
    defer allocator.free(token_owned);

    const token = std.mem.trim(u8, token_owned, " \t\r\n");
    if (!std.mem.eql(u8, token, issueSidebarCsrfToken())) {
        try sendPlainResponse(allocator, stream, 403, "Forbidden", "Invalid sidebar form token\n");
        return false;
    }
    return true;
}

pub fn append(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    raw_ref: []const u8,
    issue_id: []const u8,
    author: []const u8,
    milestone: []const u8,
    issue_type: []const u8,
    priority: []const u8,
    status: []const u8,
    body: []const u8,
) !void {
    try appendIssueSidebarAssignees(buf, allocator, db, raw_ref, issue_id);
    try appendIssueSidebarLabels(buf, allocator, db, raw_ref, issue_id);
    try appendIssueSidebarPriority(buf, allocator, raw_ref, priority);
    try appendIssueSidebarStatus(buf, allocator, raw_ref, status);
    try appendIssueSidebarType(buf, allocator, raw_ref, issue_type);
    try appendIssueSidebarProjects(buf, allocator, db, raw_ref, issue_id);
    try appendIssueSidebarMilestone(buf, allocator, db, raw_ref, milestone);
    try appendIssueSidebarRelationships(buf, allocator, db, issue_id, body);
    try appendIssueSidebarDevelopment(buf, allocator, db, issue_id);
    try appendIssueSidebarNotifications(buf, allocator);
    try appendIssueSidebarParticipants(buf, allocator, db, issue_id, author);
}

fn appendIssueSidebarAssignees(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, raw_ref: []const u8, issue_id: []const u8) !void {
    try appendIssueSidebarEditableSectionStart(buf, allocator, "Assignees", "Add assignees");
    try appendIssueSidebarAssigneeMenu(buf, allocator, db, raw_ref, issue_id);
    try appendIssueSidebarEditableSectionBodyStart(buf, allocator);
    var stmt = try db.prepare("SELECT DISTINCT assignee FROM issue_assignees WHERE issue_id = ? ORDER BY assignee");
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    var shown = false;
    while (try stmt.step()) {
        const assignee = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(assignee);
        try appendIssueSidebarPerson(buf, allocator, assignee);
        shown = true;
    }
    if (!shown) try buf.appendSlice(allocator, "<p class=\"issue-sidebar-empty\">No one assigned</p>");
    try appendIssueSidebarSectionEnd(buf, allocator);
}

fn appendIssueSidebarLabels(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, raw_ref: []const u8, issue_id: []const u8) !void {
    try appendIssueSidebarEditableSectionStart(buf, allocator, "Labels", "Apply labels to this issue");
    try appendIssueSidebarLabelsMenu(buf, allocator, db, raw_ref, issue_id);
    try appendIssueSidebarEditableSectionBodyStart(buf, allocator);
    var stmt = try db.prepare("SELECT DISTINCT label FROM issue_labels WHERE issue_id = ? ORDER BY label");
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    var shown = false;
    while (try stmt.step()) {
        const label = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(label);
        if (!shown) {
            try buf.appendSlice(allocator, "<div class=\"issue-sidebar-labels\">");
            shown = true;
        }
        try appendIssueSidebarLabel(buf, allocator, label);
    }
    if (shown) {
        try buf.appendSlice(allocator, "</div>");
    } else {
        try buf.appendSlice(allocator, "<p class=\"issue-sidebar-empty\">None yet</p>");
    }
    try appendIssueSidebarSectionEnd(buf, allocator);
}

fn appendIssueSidebarPriority(buf: *std.ArrayList(u8), allocator: Allocator, raw_ref: []const u8, priority: []const u8) !void {
    try appendIssueSidebarEditableSectionStart(buf, allocator, "Priority", "Set priority");
    try appendIssueSidebarPriorityMenu(buf, allocator, raw_ref, priority);
    try appendIssueSidebarEditableSectionBodyStart(buf, allocator);
    if (priority.len == 0) {
        try buf.appendSlice(allocator, "<p class=\"issue-sidebar-empty\">No priority</p>");
    } else {
        try appendIssuePriorityChip(buf, allocator, priority);
    }
    try appendIssueSidebarSectionEnd(buf, allocator);
}

fn appendIssueSidebarStatus(buf: *std.ArrayList(u8), allocator: Allocator, raw_ref: []const u8, status: []const u8) !void {
    try appendIssueSidebarEditableSectionStart(buf, allocator, "Status", "Set status");
    try appendIssueSidebarStatusMenu(buf, allocator, raw_ref, status);
    try appendIssueSidebarEditableSectionBodyStart(buf, allocator);
    if (status.len == 0) {
        try buf.appendSlice(allocator, "<p class=\"issue-sidebar-empty\">No status</p>");
    } else {
        try appendIssueStatusChip(buf, allocator, status);
    }
    try appendIssueSidebarSectionEnd(buf, allocator);
}

fn appendIssueSidebarType(buf: *std.ArrayList(u8), allocator: Allocator, raw_ref: []const u8, issue_type: []const u8) !void {
    try appendIssueSidebarEditableSectionStart(buf, allocator, "Type", "Select issue type");
    try appendIssueSidebarMenuFilter(buf, allocator, "Filter types");
    try appendIssueSidebarMenuGroupStart(buf, allocator, "Available types");
    try appendIssueSidebarTypeActionRow(buf, allocator, raw_ref, "bug", issue_type);
    try appendIssueSidebarTypeActionRow(buf, allocator, raw_ref, "feature", issue_type);
    try appendIssueSidebarTypeActionRow(buf, allocator, raw_ref, "task", issue_type);
    try appendIssueSidebarMenuGroupEnd(buf, allocator);
    try appendIssueSidebarEditableSectionBodyStart(buf, allocator);
    if (issue_type.len == 0) {
        try buf.appendSlice(allocator, "<p class=\"issue-sidebar-empty\">No type</p>");
    } else {
        try buf.appendSlice(allocator, "<span class=\"issue-sidebar-token\">");
        try appendIssueTypeChip(buf, allocator, issue_type);
        try buf.appendSlice(allocator, "</span>");
    }
    try appendIssueSidebarSectionEnd(buf, allocator);
}

fn appendIssueSidebarProjects(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, raw_ref: []const u8, issue_id: []const u8) !void {
    try appendIssueSidebarEditableSectionStart(buf, allocator, "Projects", "Select projects");
    try appendIssueSidebarProjectsMenu(buf, allocator, db, raw_ref, issue_id);
    try appendIssueSidebarEditableSectionBodyStart(buf, allocator);
    var stmt = try db.prepare(
        \\SELECT DISTINCT project, column_name
        \\FROM issue_projects
        \\WHERE issue_id = ?
        \\ORDER BY project, column_name
    );
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    var shown = false;
    while (try stmt.step()) {
        const project = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(project);
        const column = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(column);
        try buf.appendSlice(allocator, "<span class=\"issue-sidebar-token issue-sidebar-project-token\"><span class=\"issue-sidebar-pill\">");
        try appendTemplate(buf, allocator, "{project}", .{ .project = project });
        if (column.len != 0) try appendTemplate(buf, allocator, " / {column}", .{ .column = column });
        try buf.appendSlice(allocator, "</span></span>");
        shown = true;
    }
    if (!shown) try buf.appendSlice(allocator, "<p class=\"issue-sidebar-empty\">No projects</p>");
    try appendIssueSidebarSectionEnd(buf, allocator);
}

fn appendIssueSidebarMilestone(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, raw_ref: []const u8, milestone: []const u8) !void {
    try appendIssueSidebarEditableSectionStart(buf, allocator, "Milestone", "Set milestone");
    try appendIssueSidebarMilestoneMenu(buf, allocator, db, raw_ref, milestone);
    try appendIssueSidebarEditableSectionBodyStart(buf, allocator);
    if (milestone.len == 0) {
        try buf.appendSlice(allocator, "<p class=\"issue-sidebar-empty\">No milestone</p>");
    } else {
        try buf.appendSlice(allocator, "<span class=\"issue-sidebar-token\"><span class=\"issue-sidebar-pill\">");
        try shared.appendHtml(buf, allocator, milestone);
        try buf.appendSlice(allocator, "</span></span>");
    }
    try appendIssueSidebarSectionEnd(buf, allocator);
}

fn appendIssueSidebarRelationships(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, issue_id: []const u8, body: []const u8) !void {
    try appendIssueSidebarEditableSectionStart(buf, allocator, "Relationships", "Add relationship");
    try appendIssueSidebarRelationshipsMenu(buf, allocator);
    try appendIssueSidebarEditableSectionBodyStart(buf, allocator);
    var relationships: std.ArrayList(RelationshipItem) = .empty;
    defer {
        for (relationships.items) |*item| item.deinit();
        relationships.deinit(allocator);
    }
    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var keys = seen.keyIterator();
        while (keys.next()) |key| allocator.free(key.*);
        seen.deinit();
    }
    try issue_relationships.collectDirectivesFromText(allocator, db, issue_id, body, &seen, &relationships);

    var stmt = try db.prepare(
        \\SELECT body
        \\FROM comments
        \\WHERE parent_kind = 'issue'
        \\  AND parent_id = ?
        \\  AND redacted = 0
        \\ORDER BY created_at, id
    );
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    while (try stmt.step()) {
        const comment_body = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(comment_body);
        try issue_relationships.collectDirectivesFromText(allocator, db, issue_id, comment_body, &seen, &relationships);
    }

    if (relationships.items.len == 0) {
        try buf.appendSlice(allocator, "<p class=\"issue-sidebar-empty\">None yet</p>");
    } else {
        try issue_relationships.appendGroups(buf, allocator, relationships.items);
    }
    try appendIssueSidebarSectionEnd(buf, allocator);
}

fn appendIssueSidebarDevelopment(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, issue_id: []const u8) !void {
    try appendIssueSidebarEditableSectionStart(buf, allocator, "Development", "Link development");
    try appendIssueSidebarDevelopmentMenu(buf, allocator, db);
    try appendIssueSidebarEditableSectionBodyStart(buf, allocator);
    var stmt = try db.prepare(
        \\SELECT commit_oid
        \\FROM commit_references
        \\WHERE object_kind = 'issue' AND object_id = ?
        \\ORDER BY commit_oid
        \\LIMIT 8
    );
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    var shown = false;
    while (try stmt.step()) {
        const commit_oid = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(commit_oid);
        try appendTemplate(buf, allocator,
            \\<a class="issue-sidebar-link-row" href="{href}"><span class="issue-sidebar-row-kind">commit</span><code>{short_oid}</code></a>
        , .{
            .href = commitHref(commit_oid),
            .short_oid = commit_oid[0..@min(commit_oid.len, 12)],
        });
        shown = true;
    }
    if (!shown) try buf.appendSlice(allocator, "<p class=\"issue-sidebar-empty\">No linked branches or pull requests.</p>");
    try appendIssueSidebarSectionEnd(buf, allocator);
}

fn appendIssueSidebarParticipants(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, issue_id: []const u8, author: []const u8) !void {
    try appendIssueSidebarSectionStart(buf, allocator, "Participants");
    try buf.appendSlice(allocator, "<div class=\"issue-participants\">");
    try appendIssueAvatar(buf, allocator, author, "");
    var stmt = try db.prepare("SELECT DISTINCT assignee FROM issue_assignees WHERE issue_id = ? AND assignee <> ? ORDER BY assignee");
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    try stmt.bindText(2, author);
    while (try stmt.step()) {
        const assignee = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(assignee);
        try appendIssueAvatar(buf, allocator, assignee, "");
    }
    try buf.appendSlice(allocator, "</div>");
    try appendIssueSidebarSectionEnd(buf, allocator);
}

fn appendIssueSidebarNotifications(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try appendIssueSidebarSectionStart(buf, allocator, "Notifications");
    try buf.appendSlice(allocator,
        \\<button class="button secondary issue-sidebar-full-button" type="button" disabled>Subscribe</button>
    );
    try appendIssueSidebarSectionEnd(buf, allocator);
}

fn appendIssueSidebarAssigneeMenu(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, raw_ref: []const u8, issue_id: []const u8) !void {
    try appendIssueSidebarSingleInputForm(buf, allocator, raw_ref, "add-assignee", "value", "Add assignee", "Filter assignees");
    try appendIssueSidebarMenuGroupStart(buf, allocator, "Assigned");
    var selected = try db.prepare("SELECT DISTINCT assignee FROM issue_assignees WHERE issue_id = ? ORDER BY lower(assignee), assignee");
    defer selected.deinit();
    try selected.bindText(1, issue_id);
    var shown = false;
    while (try selected.step()) {
        const assignee = try selected.columnTextDup(allocator, 0);
        defer allocator.free(assignee);
        try appendIssueSidebarAssigneeActionRow(buf, allocator, raw_ref, "remove-assignee", assignee, true);
        shown = true;
    }
    if (!shown) try appendIssueSidebarMenuEmpty(buf, allocator, "No assignees selected.");
    try appendIssueSidebarMenuGroupEnd(buf, allocator);

    try appendIssueSidebarMenuGroupStart(buf, allocator, "Suggestions");
    var suggestions = try db.prepare(
        \\SELECT DISTINCT assignee
        \\FROM (
        \\  SELECT assignee AS assignee FROM issue_assignees
        \\  UNION
        \\  SELECT COALESCE(NULLIF(m.source_author, ''), i.author_principal) AS assignee
        \\  FROM issues i
        \\  LEFT JOIN issue_metadata m ON m.issue_id = i.id
        \\)
        \\WHERE assignee <> ''
        \\  AND assignee NOT IN (SELECT assignee FROM issue_assignees WHERE issue_id = ?)
        \\ORDER BY lower(assignee), assignee
        \\LIMIT 20
    );
    defer suggestions.deinit();
    try suggestions.bindText(1, issue_id);
    shown = false;
    while (try suggestions.step()) {
        const assignee = try suggestions.columnTextDup(allocator, 0);
        defer allocator.free(assignee);
        try appendIssueSidebarAssigneeActionRow(buf, allocator, raw_ref, "add-assignee", assignee, false);
        shown = true;
    }
    if (!shown) try appendIssueSidebarMenuEmpty(buf, allocator, "No assignee suggestions.");
    try appendIssueSidebarMenuGroupEnd(buf, allocator);
}

fn appendIssueSidebarLabelsMenu(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, raw_ref: []const u8, issue_id: []const u8) !void {
    try appendIssueSidebarSingleInputForm(buf, allocator, raw_ref, "add-label", "value", "Add label", "Filter labels");
    try appendIssueSidebarMenuGroupStart(buf, allocator, "Selected labels");
    var selected = try db.prepare("SELECT DISTINCT label FROM issue_labels WHERE issue_id = ? ORDER BY lower(label), label");
    defer selected.deinit();
    try selected.bindText(1, issue_id);
    var shown = false;
    while (try selected.step()) {
        const label = try selected.columnTextDup(allocator, 0);
        defer allocator.free(label);
        try appendIssueSidebarLabelActionRow(buf, allocator, raw_ref, "remove-label", label, true);
        shown = true;
    }
    if (!shown) try appendIssueSidebarMenuEmpty(buf, allocator, "No labels selected.");
    try appendIssueSidebarMenuGroupEnd(buf, allocator);

    try appendIssueSidebarMenuGroupStart(buf, allocator, "Suggestions");
    var suggestions = try db.prepare(
        \\SELECT DISTINCT label
        \\FROM issue_labels
        \\WHERE label NOT IN (SELECT label FROM issue_labels WHERE issue_id = ?)
        \\ORDER BY lower(label), label
        \\LIMIT 24
    );
    defer suggestions.deinit();
    try suggestions.bindText(1, issue_id);
    shown = false;
    while (try suggestions.step()) {
        const label = try suggestions.columnTextDup(allocator, 0);
        defer allocator.free(label);
        try appendIssueSidebarLabelActionRow(buf, allocator, raw_ref, "add-label", label, false);
        shown = true;
    }
    if (!shown) try appendIssueSidebarMenuEmpty(buf, allocator, "No label suggestions.");
    try appendIssueSidebarMenuGroupEnd(buf, allocator);
}

fn appendIssueSidebarProjectsMenu(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, raw_ref: []const u8, issue_id: []const u8) !void {
    try appendIssueSidebarProjectForm(buf, allocator, raw_ref);
    try appendIssueSidebarMenuGroupStart(buf, allocator, "Selected projects");
    var selected = try db.prepare(
        \\SELECT DISTINCT project, column_name
        \\FROM issue_projects
        \\WHERE issue_id = ?
        \\ORDER BY lower(project), lower(column_name), project, column_name
    );
    defer selected.deinit();
    try selected.bindText(1, issue_id);
    var shown = false;
    while (try selected.step()) {
        const project = try selected.columnTextDup(allocator, 0);
        defer allocator.free(project);
        const column = try selected.columnTextDup(allocator, 1);
        defer allocator.free(column);
        try appendIssueSidebarProjectActionRow(buf, allocator, raw_ref, "remove-project", project, column, true);
        shown = true;
    }
    if (!shown) try appendIssueSidebarMenuEmpty(buf, allocator, "No projects selected.");
    try appendIssueSidebarMenuGroupEnd(buf, allocator);

    try appendIssueSidebarMenuGroupStart(buf, allocator, "Suggestions");
    var suggestions = try db.prepare(
        \\SELECT DISTINCT candidate.project, candidate.column_name
        \\FROM (
        \\  SELECT p.name AS project, pc.column_name AS column_name
        \\  FROM projects p
        \\  JOIN project_columns pc ON pc.project_id = p.id
        \\  WHERE p.state <> 'closed'
        \\  UNION
        \\  SELECT project, column_name FROM issue_projects
        \\) AS candidate
        \\WHERE candidate.project <> ''
        \\  AND candidate.column_name <> ''
        \\  AND NOT EXISTS (
        \\    SELECT 1 FROM issue_projects ip
        \\    WHERE ip.issue_id = ?
        \\      AND ip.project = candidate.project
        \\      AND ip.column_name = candidate.column_name
        \\  )
        \\ORDER BY lower(candidate.project), lower(candidate.column_name), candidate.project, candidate.column_name
        \\LIMIT 20
    );
    defer suggestions.deinit();
    try suggestions.bindText(1, issue_id);
    shown = false;
    while (try suggestions.step()) {
        const project = try suggestions.columnTextDup(allocator, 0);
        defer allocator.free(project);
        const column = try suggestions.columnTextDup(allocator, 1);
        defer allocator.free(column);
        try appendIssueSidebarProjectActionRow(buf, allocator, raw_ref, "add-project", project, column, false);
        shown = true;
    }
    if (!shown) try appendIssueSidebarMenuEmpty(buf, allocator, "No project suggestions.");
    try appendIssueSidebarMenuGroupEnd(buf, allocator);
}

fn appendIssueSidebarMilestoneMenu(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, raw_ref: []const u8, milestone: []const u8) !void {
    try appendIssueSidebarSingleInputForm(buf, allocator, raw_ref, "set-milestone", "milestone", "Set milestone", "Filter milestones");
    try appendIssueSidebarMenuGroupStart(buf, allocator, "Selected milestone");
    if (milestone.len == 0) {
        try appendIssueSidebarMenuEmpty(buf, allocator, "No milestone selected.");
    } else {
        try appendIssueSidebarMilestoneActionRow(buf, allocator, raw_ref, milestone, true);
    }
    try appendIssueSidebarMenuGroupEnd(buf, allocator);

    try appendIssueSidebarMenuGroupStart(buf, allocator, "Suggestions");
    var suggestions = try db.prepare(
        \\SELECT DISTINCT candidate.milestone
        \\FROM (
        \\  SELECT title AS milestone FROM milestones WHERE state <> 'closed'
        \\  UNION
        \\  SELECT milestone FROM issue_metadata WHERE milestone <> ''
        \\) AS candidate
        \\WHERE candidate.milestone <> ''
        \\  AND candidate.milestone <> ?
        \\ORDER BY lower(candidate.milestone), candidate.milestone
        \\LIMIT 20
    );
    defer suggestions.deinit();
    try suggestions.bindText(1, milestone);
    var shown = false;
    while (try suggestions.step()) {
        const candidate = try suggestions.columnTextDup(allocator, 0);
        defer allocator.free(candidate);
        try appendIssueSidebarMilestoneActionRow(buf, allocator, raw_ref, candidate, false);
        shown = true;
    }
    if (!shown) try appendIssueSidebarMenuEmpty(buf, allocator, "No milestone suggestions.");
    try appendIssueSidebarMenuGroupEnd(buf, allocator);
}

fn appendIssueSidebarPriorityMenu(buf: *std.ArrayList(u8), allocator: Allocator, raw_ref: []const u8, selected_priority: []const u8) !void {
    try appendIssueSidebarMenuGroupStart(buf, allocator, "Priorities");
    for (project_views.project_priority_values) |priority| {
        try appendIssueSidebarPriorityActionRow(buf, allocator, raw_ref, priority, std.mem.eql(u8, selected_priority, priority));
    }
    try appendIssueSidebarMenuGroupEnd(buf, allocator);
}

fn appendIssueSidebarStatusMenu(buf: *std.ArrayList(u8), allocator: Allocator, raw_ref: []const u8, selected_status: []const u8) !void {
    try appendIssueSidebarMenuGroupStart(buf, allocator, "Statuses");
    for (project_views.project_status_values) |status| {
        try appendIssueSidebarStatusActionRow(buf, allocator, raw_ref, status, std.mem.eql(u8, selected_status, status));
    }
    try appendIssueSidebarMenuGroupEnd(buf, allocator);
}

fn appendIssueSidebarRelationshipsMenu(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator, "<div class=\"issue-sidebar-command-list\">");
    try appendIssueSidebarCommand(buf, allocator, "Add parent", "Alt P");
    try appendIssueSidebarCommand(buf, allocator, "Mark as blocked by", "B B");
    try appendIssueSidebarCommand(buf, allocator, "Mark as blocking", "B X");
    try appendIssueSidebarCommand(buf, allocator, "Add security alert", "");
    try buf.appendSlice(allocator, "</div>");
}

fn appendIssueSidebarDevelopmentMenu(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb) !void {
    try appendIssueSidebarMenuFilter(buf, allocator, "Search pull requests");
    try appendIssueSidebarMenuGroupStart(buf, allocator, "Open pull requests");
    var stmt = try db.prepare(
        \\SELECT p.id, p.title, COALESCE(a.number, 0)
        \\FROM pulls p
        \\LEFT JOIN legacy_aliases a
        \\  ON a.provider = 'github' AND a.object_kind = 'pull' AND a.object_id = p.id
        \\WHERE p.state = 'open'
        \\ORDER BY p.opened_at DESC
        \\LIMIT 12
    );
    defer stmt.deinit();
    var shown = false;
    while (try stmt.step()) {
        const pull_id = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(pull_id);
        const title = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(title);
        const legacy_number = stmt.columnInt64(2);
        try appendIssueSidebarPullChoice(buf, allocator, pull_id, title, legacy_number);
        shown = true;
    }
    if (!shown) try appendIssueSidebarMenuEmpty(buf, allocator, "No open pull requests.");
    try appendIssueSidebarMenuGroupEnd(buf, allocator);
}

fn appendIssueSidebarSectionStart(buf: *std.ArrayList(u8), allocator: Allocator, title: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<section class="issue-sidebar-section"><div class="issue-sidebar-heading"><h2>{title}</h2></div>
    , .{ .title = title });
}

fn appendIssueSidebarEditableSectionStart(buf: *std.ArrayList(u8), allocator: Allocator, title: []const u8, menu_label: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<section class="issue-sidebar-section"><div class="issue-sidebar-heading"><h2>{title}</h2><details class="issue-sidebar-menu" data-popover-menu data-issue-sidebar-menu><summary aria-label="{menu_label}" title="{menu_label}"><span class="issue-sidebar-menu-icon" aria-hidden="true"></span></summary><div class="issue-sidebar-popover" role="dialog" aria-label="{menu_label}"><div class="issue-sidebar-popover-title">{menu_label}</div>
    , .{
        .title = title,
        .menu_label = menu_label,
    });
}

fn appendIssueSidebarEditableSectionBodyStart(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator, "</div></details></div>");
}

fn appendIssueSidebarSectionEnd(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator, "</section>");
}

fn appendIssueSidebarPerson(buf: *std.ArrayList(u8), allocator: Allocator, name: []const u8) !void {
    try buf.appendSlice(allocator, "<div class=\"issue-sidebar-person\">");
    try appendIssueAvatar(buf, allocator, name, "");
    try appendTemplate(buf, allocator, "<span>{name}</span>", .{ .name = name });
    try buf.appendSlice(allocator, "</div>");
}

fn appendIssueSidebarLabel(buf: *std.ArrayList(u8), allocator: Allocator, label: []const u8) !void {
    try buf.appendSlice(allocator, "<span class=\"issue-sidebar-token\">");
    try appendIssueLabel(buf, allocator, label);
    try buf.appendSlice(allocator, "</span>");
}

fn appendIssueSidebarSingleInputForm(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_ref: []const u8,
    action: []const u8,
    input_name: []const u8,
    button_label: []const u8,
    placeholder: []const u8,
) !void {
    try buf.appendSlice(allocator, "<form class=\"issue-sidebar-add-form issue-sidebar-menu-form\" method=\"post\" action=\"");
    try appendIssueSidebarAction(buf, allocator, raw_ref);
    try appendTemplate(buf, allocator,
        \\"><input type="hidden" name="csrf_token" value="{csrf_token}"><input type="hidden" name="action" value="{action}"><label class="issue-sidebar-menu-input"><span aria-hidden="true"></span><input name="{input_name}" placeholder="{placeholder}" aria-label="{placeholder}" autocomplete="off" data-issue-sidebar-filter></label><button type="submit">{button_label}</button></form>
    , .{
        .action = action,
        .input_name = input_name,
        .placeholder = placeholder,
        .button_label = button_label,
        .csrf_token = issueSidebarCsrfToken(),
    });
}

fn appendIssueSidebarProjectForm(buf: *std.ArrayList(u8), allocator: Allocator, raw_ref: []const u8) !void {
    try buf.appendSlice(allocator, "<form class=\"issue-sidebar-add-form issue-sidebar-project-form issue-sidebar-menu-form\" method=\"post\" action=\"");
    try appendIssueSidebarAction(buf, allocator, raw_ref);
    try appendTemplate(buf, allocator,
        \\"><input type="hidden" name="csrf_token" value="{csrf_token}"><input type="hidden" name="action" value="add-project"><label class="issue-sidebar-menu-input"><span aria-hidden="true"></span><input name="project" placeholder="Filter projects" aria-label="Project" autocomplete="off" data-issue-sidebar-filter></label><input name="column" placeholder="Column" aria-label="Column" autocomplete="off"><button type="submit">Add project</button></form>
    , .{ .csrf_token = issueSidebarCsrfToken() });
}

fn appendIssueSidebarMenuFilter(buf: *std.ArrayList(u8), allocator: Allocator, placeholder: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<label class="issue-sidebar-menu-input issue-sidebar-menu-filter"><span aria-hidden="true"></span><input placeholder="{placeholder}" aria-label="{placeholder}" autocomplete="off" data-issue-sidebar-filter></label>
    , .{ .placeholder = placeholder });
}

fn appendIssueSidebarMenuGroupStart(buf: *std.ArrayList(u8), allocator: Allocator, title: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<div class="issue-sidebar-menu-group"><div class="issue-sidebar-menu-group-title">{title}</div>
    , .{ .title = title });
}

fn appendIssueSidebarMenuGroupEnd(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator, "</div>");
}

fn appendIssueSidebarMenuEmpty(buf: *std.ArrayList(u8), allocator: Allocator, message: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<p class="issue-sidebar-menu-empty" data-sidebar-filter-text="">{message}</p>
    , .{ .message = message });
}

fn appendIssueSidebarAssigneeActionRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_ref: []const u8,
    action: []const u8,
    assignee: []const u8,
    selected: bool,
) !void {
    try appendIssueSidebarValueActionFormStart(buf, allocator, raw_ref, action, "value", assignee, assignee, selected);
    try appendIssueAvatar(buf, allocator, assignee, "");
    try appendTemplate(buf, allocator, "<span class=\"issue-sidebar-picker-primary\">{assignee}</span></button></form>", .{
        .assignee = assignee,
    });
}

fn appendIssueSidebarLabelActionRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_ref: []const u8,
    action: []const u8,
    label: []const u8,
    selected: bool,
) !void {
    try appendIssueSidebarValueActionFormStart(buf, allocator, raw_ref, action, "value", label, label, selected);
    try appendIssueLabel(buf, allocator, label);
    try buf.appendSlice(allocator, "</button></form>");
}

fn appendIssueSidebarMilestoneActionRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_ref: []const u8,
    milestone: []const u8,
    selected: bool,
) !void {
    if (selected) {
        try buf.appendSlice(allocator, "<form class=\"issue-sidebar-picker-form\" method=\"post\" action=\"");
        try appendIssueSidebarAction(buf, allocator, raw_ref);
        try appendTemplate(buf, allocator,
            \\"><input type="hidden" name="csrf_token" value="{csrf_token}"><input type="hidden" name="action" value="clear-milestone"><button class="issue-sidebar-picker-row is-selected" type="submit" data-sidebar-filter-text="{milestone}"><span class="issue-sidebar-picker-check" aria-hidden="true"></span><span class="issue-milestone-icon" aria-hidden="true"></span><span class="issue-sidebar-picker-primary">{milestone}</span></button></form>
        , .{
            .milestone = milestone,
            .csrf_token = issueSidebarCsrfToken(),
        });
        return;
    }

    try buf.appendSlice(allocator, "<form class=\"issue-sidebar-picker-form\" method=\"post\" action=\"");
    try appendIssueSidebarAction(buf, allocator, raw_ref);
    try appendTemplate(buf, allocator,
        \\"><input type="hidden" name="csrf_token" value="{csrf_token}"><input type="hidden" name="action" value="set-milestone"><input type="hidden" name="milestone" value="{milestone}"><button class="issue-sidebar-picker-row" type="submit" data-sidebar-filter-text="{milestone}"><span class="issue-sidebar-picker-check" aria-hidden="true"></span><span class="issue-milestone-icon" aria-hidden="true"></span><span class="issue-sidebar-picker-primary">{milestone}</span></button></form>
    , .{
        .milestone = milestone,
        .csrf_token = issueSidebarCsrfToken(),
    });
}

fn appendIssueSidebarProjectActionRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_ref: []const u8,
    action: []const u8,
    project: []const u8,
    column: []const u8,
    selected: bool,
) !void {
    const state_class: []const u8 = if (selected) " is-selected" else "";
    try buf.appendSlice(allocator, "<form class=\"issue-sidebar-picker-form\" method=\"post\" action=\"");
    try appendIssueSidebarAction(buf, allocator, raw_ref);
    try appendTemplate(buf, allocator,
        \\"><input type="hidden" name="csrf_token" value="{csrf_token}"><input type="hidden" name="action" value="{action}"><input type="hidden" name="project" value="{project}"><input type="hidden" name="column" value="{column}"><button class="issue-sidebar-picker-row{state_class}" type="submit" data-sidebar-filter-text="{project} {column}"><span class="issue-sidebar-picker-check" aria-hidden="true"></span><span class="issue-sidebar-project-icon" aria-hidden="true"></span><span class="issue-sidebar-picker-text"><span class="issue-sidebar-picker-primary">{project}</span><span class="issue-sidebar-picker-secondary">{column}</span></span></button></form>
    , .{
        .action = action,
        .project = project,
        .column = column,
        .state_class = state_class,
        .csrf_token = issueSidebarCsrfToken(),
    });
}

fn appendIssueSidebarPriorityActionRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_ref: []const u8,
    priority: []const u8,
    selected: bool,
) !void {
    try appendIssueSidebarValueActionFormStart(buf, allocator, raw_ref, "set-priority", "priority", priority, priority, selected);
    try appendIssuePriorityChip(buf, allocator, priority);
    try buf.appendSlice(allocator, "</button></form>");
}

fn appendIssueSidebarStatusActionRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_ref: []const u8,
    status: []const u8,
    selected: bool,
) !void {
    try appendIssueSidebarValueActionFormStart(buf, allocator, raw_ref, "set-status", "status", status, status, selected);
    try appendIssueStatusChip(buf, allocator, status);
    try buf.appendSlice(allocator, "</button></form>");
}

fn appendIssueSidebarTypeActionRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_ref: []const u8,
    issue_type: []const u8,
    selected_type: []const u8,
) !void {
    const filter_text = try std.fmt.allocPrint(allocator, "{s} {s}", .{ issueTypeLabel(issue_type), issueTypeDescription(issue_type) });
    defer allocator.free(filter_text);
    try appendIssueSidebarValueActionFormStart(buf, allocator, raw_ref, "set-type", "type", issue_type, filter_text, std.mem.eql(u8, selected_type, issue_type));
    try appendIssueTypeDot(buf, allocator, issue_type);
    try appendTemplate(buf, allocator,
        \\<span class="issue-sidebar-picker-text"><span class="issue-sidebar-picker-primary">{title}</span><span class="issue-sidebar-picker-secondary">{description}</span></span></button></form>
    , .{
        .title = issueTypeLabel(issue_type),
        .description = issueTypeDescription(issue_type),
    });
}

fn appendIssueSidebarValueActionFormStart(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_ref: []const u8,
    action: []const u8,
    input_name: []const u8,
    value: []const u8,
    filter_text: []const u8,
    selected: bool,
) !void {
    const state_class: []const u8 = if (selected) " is-selected" else "";
    try buf.appendSlice(allocator, "<form class=\"issue-sidebar-picker-form\" method=\"post\" action=\"");
    try appendIssueSidebarAction(buf, allocator, raw_ref);
    try appendTemplate(buf, allocator,
        \\"><input type="hidden" name="csrf_token" value="{csrf_token}"><input type="hidden" name="action" value="{action}"><input type="hidden" name="{input_name}" value="{value}"><button class="issue-sidebar-picker-row{state_class}" type="submit" data-sidebar-filter-text="{filter_text}"><span class="issue-sidebar-picker-check" aria-hidden="true"></span>
    , .{
        .action = action,
        .input_name = input_name,
        .value = value,
        .filter_text = filter_text,
        .state_class = state_class,
        .csrf_token = issueSidebarCsrfToken(),
    });
}

fn appendIssuePriorityChip(buf: *std.ArrayList(u8), allocator: Allocator, priority: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<span class="issue-row-priority issue-row-priority-{tone}" title="Priority: {priority}" aria-label="Priority: {priority}">{priority}</span>
    , .{
        .tone = project_issue_render.priorityTone(priority),
        .priority = priority,
    });
}

fn appendIssueStatusChip(buf: *std.ArrayList(u8), allocator: Allocator, status: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<span class="project-status-chip tone-{tone}">{status}</span>
    , .{
        .tone = project_issue_render.columnTone(status),
        .status = status,
    });
}

fn appendIssueTypeChip(buf: *std.ArrayList(u8), allocator: Allocator, issue_type: []const u8) !void {
    try buf.appendSlice(allocator, "<span class=\"issue-sidebar-pill issue-type-chip\">");
    try appendIssueTypeDot(buf, allocator, issue_type);
    try appendTemplate(buf, allocator, "<span>{label}</span></span>", .{
        .label = issueTypeLabel(issue_type),
    });
}

fn appendIssueTypeDot(buf: *std.ArrayList(u8), allocator: Allocator, issue_type: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<span class="issue-type-dot issue-type-{kind}" aria-hidden="true"></span>
    , .{
        .kind = issue_type,
    });
}

fn issueTypeLabel(issue_type: []const u8) []const u8 {
    if (std.mem.eql(u8, issue_type, "bug")) return "Bug";
    if (std.mem.eql(u8, issue_type, "feature")) return "Feature";
    if (std.mem.eql(u8, issue_type, "task")) return "Task";
    return issue_type;
}

fn issueTypeDescription(issue_type: []const u8) []const u8 {
    if (std.mem.eql(u8, issue_type, "bug")) return "An unexpected problem or behavior";
    if (std.mem.eql(u8, issue_type, "feature")) return "A request, idea, or new functionality";
    if (std.mem.eql(u8, issue_type, "task")) return "A specific piece of work";
    return "";
}

fn appendIssueSidebarCommand(buf: *std.ArrayList(u8), allocator: Allocator, label: []const u8, shortcut: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<button type="button" disabled><span>{label}</span>
    , .{ .label = label });
    if (shortcut.len != 0) {
        var parts = std.mem.tokenizeScalar(u8, shortcut, ' ');
        try buf.appendSlice(allocator, "<span class=\"issue-sidebar-command-keys\">");
        while (parts.next()) |part| {
            try appendTemplate(buf, allocator, "<kbd>{part}</kbd>", .{ .part = part });
        }
        try buf.appendSlice(allocator, "</span>");
    }
    try buf.appendSlice(allocator, "</button>");
}

fn appendIssueSidebarPullChoice(buf: *std.ArrayList(u8), allocator: Allocator, pull_id: []const u8, title: []const u8, legacy_number: i64) !void {
    var pull_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const pull_ref = util.shortObjectRef(&pull_ref_buf, pull_id);
    const number_text = try pullNumberText(allocator, pull_ref, legacy_number);
    defer allocator.free(number_text);

    try buf.appendSlice(allocator, "<a class=\"issue-sidebar-picker-row issue-sidebar-link-choice\" href=\"");
    try shared.appendHref(buf, allocator, pullHref(pull_ref));
    try appendTemplate(buf, allocator,
        \\" data-sidebar-filter-text="{title} {number_text}"><span class="issue-sidebar-picker-check" aria-hidden="true"></span><span class="issue-sidebar-pr-icon" aria-hidden="true"></span><span class="issue-sidebar-picker-text"><span class="issue-sidebar-picker-primary">{title}</span><span class="issue-sidebar-picker-secondary">{number_text}</span></span></a>
    , .{
        .title = title,
        .number_text = number_text,
    });
}

fn pullNumberText(allocator: Allocator, pull_ref: []const u8, legacy_number: i64) ![]u8 {
    if (legacy_number > 0) return try std.fmt.allocPrint(allocator, "#{d}", .{legacy_number});
    return try std.fmt.allocPrint(allocator, "#{s}", .{pull_ref});
}

fn appendIssueSidebarRemoveProjectForm(buf: *std.ArrayList(u8), allocator: Allocator, raw_ref: []const u8, project: []const u8, column: []const u8) !void {
    try buf.appendSlice(allocator, "<form class=\"issue-sidebar-remove-form\" method=\"post\" action=\"");
    try appendIssueSidebarAction(buf, allocator, raw_ref);
    try appendTemplate(buf, allocator,
        \\"><input type="hidden" name="csrf_token" value="{csrf_token}"><input type="hidden" name="action" value="remove-project"><input type="hidden" name="project" value="{project}"><input type="hidden" name="column" value="{column}"><button type="submit" aria-label="Remove project">x</button></form>
    , .{
        .project = project,
        .column = column,
        .csrf_token = issueSidebarCsrfToken(),
    });
}

fn appendIssueSidebarRemoveValueForm(buf: *std.ArrayList(u8), allocator: Allocator, raw_ref: []const u8, action: []const u8, label: []const u8) !void {
    try buf.appendSlice(allocator, "<form class=\"issue-sidebar-remove-form\" method=\"post\" action=\"");
    try appendIssueSidebarAction(buf, allocator, raw_ref);
    try appendTemplate(buf, allocator,
        \\"><input type="hidden" name="csrf_token" value="{csrf_token}"><input type="hidden" name="action" value="{action}"><button type="submit" aria-label="{label}">x</button></form>
    , .{
        .action = action,
        .label = label,
        .csrf_token = issueSidebarCsrfToken(),
    });
}

fn appendIssueSidebarRemoveNamedValueForm(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_ref: []const u8,
    action: []const u8,
    input_name: []const u8,
    value: []const u8,
    label: []const u8,
) !void {
    try buf.appendSlice(allocator, "<form class=\"issue-sidebar-remove-form\" method=\"post\" action=\"");
    try appendIssueSidebarAction(buf, allocator, raw_ref);
    try appendTemplate(buf, allocator,
        \\"><input type="hidden" name="csrf_token" value="{csrf_token}"><input type="hidden" name="action" value="{action}"><input type="hidden" name="{input_name}" value="{value}"><button type="submit" aria-label="{label}">x</button></form>
    , .{
        .action = action,
        .input_name = input_name,
        .value = value,
        .label = label,
        .csrf_token = issueSidebarCsrfToken(),
    });
}

fn appendIssueSidebarAction(buf: *std.ArrayList(u8), allocator: Allocator, raw_ref: []const u8) !void {
    try buf.appendSlice(allocator, "/issues/");
    try shared.appendUrlEncoded(buf, allocator, raw_ref);
    try buf.appendSlice(allocator, "/sidebar");
}

pub fn handleIssueSidebarPost(allocator: Allocator, repo: Repo, stream: std.net.Stream, raw_ref: []const u8, form_body: []const u8) !void {
    if (!(try validateIssueSidebarCsrf(allocator, stream, form_body))) return;

    try ensureIndex(allocator, repo);
    const issue_id = index.resolveIssueId(allocator, repo, raw_ref) catch {
        try sendPlainResponse(allocator, stream, 404, "Not Found", "Issue not found\n");
        return;
    };
    defer allocator.free(issue_id);

    const action_owned = (try formValueOwned(allocator, form_body, "action")) orelse {
        try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Missing sidebar action\n");
        return;
    };
    defer allocator.free(action_owned);
    const action = std.mem.trim(u8, action_owned, " \t\r\n");

    if (std.mem.eql(u8, action, "add-label") or std.mem.eql(u8, action, "remove-label")) {
        const value_owned = try requiredSidebarValue(allocator, stream, form_body, "value", "Label is required.");
        const value = value_owned orelse return;
        defer allocator.free(value);
        const event_type: []const u8 = if (std.mem.eql(u8, action, "add-label")) "issue.label_added" else "issue.label_removed";
        if (!(try writeSidebarStringEventOrFail(allocator, stream, issue_id, event_type, "label", value))) return;
    } else if (std.mem.eql(u8, action, "add-assignee") or std.mem.eql(u8, action, "remove-assignee")) {
        const value_owned = try requiredSidebarValue(allocator, stream, form_body, "value", "Assignee is required.");
        const value = value_owned orelse return;
        defer allocator.free(value);
        const event_type: []const u8 = if (std.mem.eql(u8, action, "add-assignee")) "issue.assignee_added" else "issue.assignee_removed";
        if (!(try writeSidebarStringEventOrFail(allocator, stream, issue_id, event_type, "assignee", value))) return;
    } else if (std.mem.eql(u8, action, "set-milestone")) {
        const milestone_owned = (try formValueOwned(allocator, form_body, "milestone")) orelse try allocator.dupe(u8, "");
        defer allocator.free(milestone_owned);
        const milestone = std.mem.trim(u8, milestone_owned, " \t\r\n");
        if (!(try writeSidebarStringEventOrFail(allocator, stream, issue_id, "issue.milestone_set", "milestone", milestone))) return;
    } else if (std.mem.eql(u8, action, "clear-milestone")) {
        if (!(try writeSidebarStringEventOrFail(allocator, stream, issue_id, "issue.milestone_set", "milestone", ""))) return;
    } else if (std.mem.eql(u8, action, "set-priority")) {
        const priority_owned = try requiredSidebarValue(allocator, stream, form_body, "priority", "Priority is required.");
        const priority = priority_owned orelse return;
        defer allocator.free(priority);
        if (!isIssuePriority(priority)) {
            try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Priority must be P0, P1, P2, or P3\n");
            return;
        }
        if (!(try writeSidebarStringEventOrFail(allocator, stream, issue_id, "issue.priority_set", "priority", priority))) return;
    } else if (std.mem.eql(u8, action, "set-type")) {
        const type_owned = try requiredSidebarValue(allocator, stream, form_body, "type", "Type is required.");
        const issue_type = type_owned orelse return;
        defer allocator.free(issue_type);
        if (!isIssueType(issue_type)) {
            try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Type must be bug, feature, or task\n");
            return;
        }
        if (!(try writeSidebarStringEventOrFail(allocator, stream, issue_id, "issue.type_set", "type", issue_type))) return;
    } else if (std.mem.eql(u8, action, "set-status")) {
        const status_owned = try requiredSidebarValue(allocator, stream, form_body, "status", "Status is required.");
        const status = status_owned orelse return;
        defer allocator.free(status);
        if (!isIssueStatus(status)) {
            try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Status must be Draft, Todo, WIP, Review, Done, or Failed\n");
            return;
        }
        if (!(try writeSidebarStringEventOrFail(allocator, stream, issue_id, "issue.status_set", "status", status))) return;
    } else if (std.mem.eql(u8, action, "add-project") or std.mem.eql(u8, action, "remove-project")) {
        const project_owned = try requiredSidebarValue(allocator, stream, form_body, "project", "Project is required.");
        const project_value = project_owned orelse return;
        defer allocator.free(project_value);
        const add = std.mem.eql(u8, action, "add-project");
        const column_value = if (add) blk: {
            const column_owned = try requiredSidebarValue(allocator, stream, form_body, "column", "Column is required.");
            break :blk column_owned orelse return;
        } else blk: {
            const column_owned = (try formValueOwned(allocator, form_body, "column")) orelse try allocator.dupe(u8, "");
            defer allocator.free(column_owned);
            break :blk try allocator.dupe(u8, std.mem.trim(u8, column_owned, " \t\r\n"));
        };
        defer allocator.free(column_value);
        createIssueProjectEvent(allocator, issue_id, project_value, column_value, null, null, add) catch {
            try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not update issue project placement\n");
            return;
        };
    } else {
        try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Unknown sidebar action\n");
        return;
    }

    const location = try std.fmt.allocPrint(allocator, "/issues/{s}", .{raw_ref});
    defer allocator.free(location);
    try sendRedirect(allocator, stream, location);
}

fn appendIssueAvatar(buf: *std.ArrayList(u8), allocator: Allocator, name: []const u8, extra_class: []const u8) !void {
    try shared.appendAvatar(buf, allocator, name, extra_class);
}

fn appendIssueLabel(buf: *std.ArrayList(u8), allocator: Allocator, label: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<span class="issue-label {kind}">{label}</span>
    , .{
        .kind = issueLabelKind(label),
        .label = label,
    });
}

fn issueLabelKind(label: []const u8) []const u8 {
    if (asciiEqlIgnoreCase(label, "bug")) return "label-bug";
    if (asciiEqlIgnoreCase(label, "enhancement") or asciiEqlIgnoreCase(label, "feature") or asciiEqlIgnoreCase(label, "feat")) return "label-enhancement";
    if (asciiEqlIgnoreCase(label, "docs") or asciiEqlIgnoreCase(label, "documentation")) return "label-docs";
    if (asciiEqlIgnoreCase(label, "question")) return "label-question";
    if (asciiEqlIgnoreCase(label, "security")) return "label-security";
    return "label-default";
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (std.ascii.toLower(left) != std.ascii.toLower(right)) return false;
    }
    return true;
}

fn requiredSidebarValue(allocator: Allocator, stream: std.net.Stream, form_body: []const u8, name: []const u8, message: []const u8) !?[]u8 {
    const owned = (try formValueOwned(allocator, form_body, name)) orelse {
        try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", message);
        return null;
    };
    errdefer allocator.free(owned);
    const value = std.mem.trim(u8, owned, " \t\r\n");
    if (value.len == 0) {
        allocator.free(owned);
        try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", message);
        return null;
    }
    if (value.ptr == owned.ptr and value.len == owned.len) return owned;
    const result = try allocator.dupe(u8, value);
    allocator.free(owned);
    return result;
}

fn writeSidebarStringEventOrFail(
    allocator: Allocator,
    stream: std.net.Stream,
    issue_id: []const u8,
    event_type: []const u8,
    payload_key: []const u8,
    payload_value: []const u8,
) !bool {
    createIssueStringEvent(allocator, issue_id, event_type, payload_key, payload_value) catch {
        try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not update issue metadata\n");
        return false;
    };
    return true;
}
