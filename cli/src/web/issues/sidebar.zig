const std = @import("std");
const cmd_common = @import("../../cmd_common.zig");
const development_links = @import("../development_links.zig");
const index = @import("../../index.zig");
const issue = @import("../../issue.zig");
const issue_relationships = @import("relationships.zig");
const milestone_mod = @import("../../milestone.zig");
const project_issue_render = @import("../projects/issue_render.zig");
const project_views = @import("../projects/views.zig");
const repo_mod = @import("../../repo.zig");
const shared = @import("../shared.zig");
const sidebar = @import("../shared/sidebar.zig");
const util = @import("../../util.zig");
const zwf = @import("../../zwf.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const SqliteDb = index.SqliteDb;
const sqlite = index.sqlite;
const appendTemplate = shared.appendTemplate;
const createIssueConcurrentGroupEvent = issue.createIssueConcurrentGroupEvent;
const createIssueProjectEvent = issue.createIssueProjectEvent;
const createIssueRelationshipEvent = issue.createIssueRelationshipEvent;
const createIssueStringEvent = issue.createIssueStringEvent;
const createSubIssueOpenedWithMetadataEventResult = issue.createSubIssueOpenedWithMetadataEventResult;
const ensureMilestoneCreatedForTitle = milestone_mod.ensureMilestoneCreatedForTitle;
const ensureIndex = index.ensureIndex;
const isIssuePriority = cmd_common.isIssuePriority;
const isIssueStatus = cmd_common.isIssueStatus;
const isIssueType = cmd_common.isIssueType;
const commitHref = shared.commitHref;
const pullHref = shared.pullHref;
const sendRedirect = shared.sendRedirect;
const sendPlainResponse = shared.sendPlainResponse;
const formValueOwned = shared.formValueOwned;
const RelationshipItem = issue_relationships.RelationshipItem;

fn issueSidebarForm(raw_ref: []const u8, csrf_token: []const u8) sidebar.FormContext {
    return .{
        .target = .issue,
        .raw_ref = raw_ref,
        .csrf_field = zwf.csrf.field_name,
        .csrf_token = csrf_token,
    };
}

const selected_issue_sidebar_projects_sql =
    \\WITH selected_projects(project) AS (
    \\  SELECT DISTINCT project
    \\  FROM issue_projects
    \\  WHERE issue_id = ?
    \\  UNION
    \\  SELECT DISTINCT p.name
    \\  FROM project_memberships pm
    \\  JOIN projects p ON p.id = pm.project_id
    \\  WHERE pm.issue_id = ?
    \\)
    \\SELECT sp.project,
    \\       COALESCE(
    \\         NULLIF((
    \\           SELECT ip.column_name
    \\           FROM issue_projects ip
    \\           LEFT JOIN events e ON e.event_hash = ip.add_hash
    \\           WHERE ip.issue_id = ? AND ip.project = sp.project
    \\           ORDER BY e.ordinal DESC, ip.add_hash DESC
    \\           LIMIT 1
    \\         ), ''),
    \\         NULLIF((SELECT m.status FROM issue_metadata m WHERE m.issue_id = ?), ''),
    \\         'Draft'
    \\       ) AS column_name
    \\FROM selected_projects sp
    \\WHERE sp.project <> ''
    \\ORDER BY lower(sp.project), sp.project
;

fn validateIssueSidebarCsrf(allocator: Allocator, stream: std.net.Stream, csrf_token: []const u8, form_body: []const u8) !bool {
    const token_owned = (try formValueOwned(allocator, form_body, zwf.csrf.field_name)) orelse {
        try sendPlainResponse(allocator, stream, 403, "Forbidden", "Invalid sidebar form token\n");
        return false;
    };
    defer allocator.free(token_owned);

    const token = std.mem.trim(u8, token_owned, " \t\r\n");
    if (!zwf.csrf.verify(csrf_token, token)) {
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
    csrf_token: []const u8,
) !void {
    try appendIssueSidebarAssignees(buf, allocator, db, raw_ref, issue_id, csrf_token);
    try appendIssueSidebarLabels(buf, allocator, db, raw_ref, issue_id, csrf_token);
    try appendIssueSidebarPriority(buf, allocator, raw_ref, priority, csrf_token);
    try appendIssueSidebarStatus(buf, allocator, raw_ref, status, csrf_token);
    try appendIssueSidebarType(buf, allocator, raw_ref, issue_type, csrf_token);
    try appendIssueSidebarProjects(buf, allocator, db, raw_ref, issue_id, csrf_token);
    try appendIssueSidebarMilestone(buf, allocator, db, raw_ref, milestone, csrf_token);
    try appendIssueSidebarRelationships(buf, allocator, db, raw_ref, issue_id, body, csrf_token);
    try appendIssueSidebarDevelopment(buf, allocator, db, issue_id, body);
    try appendIssueSidebarParticipants(buf, allocator, db, issue_id, author);
}

fn appendIssueSidebarAssignees(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, raw_ref: []const u8, issue_id: []const u8, csrf_token: []const u8) !void {
    try sidebar.appendEditableSectionStart(buf, allocator, "Assignees", "Add assignees");
    try appendIssueSidebarAssigneeMenu(buf, allocator, db, raw_ref, issue_id, csrf_token);
    try sidebar.appendEditableSectionBodyStart(buf, allocator);
    try sidebar.appendPeopleBody(buf, allocator, db, "SELECT DISTINCT assignee FROM issue_assignees WHERE issue_id = ? ORDER BY assignee", issue_id, "No one assigned");
    try sidebar.appendSectionEnd(buf, allocator);
}

fn appendIssueSidebarLabels(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, raw_ref: []const u8, issue_id: []const u8, csrf_token: []const u8) !void {
    try sidebar.appendEditableSectionStart(buf, allocator, "Labels", "Apply labels to this issue");
    try appendIssueSidebarLabelsMenu(buf, allocator, db, raw_ref, issue_id, csrf_token);
    try sidebar.appendEditableSectionBodyStart(buf, allocator);
    try sidebar.appendLabelsBody(buf, allocator, db,
        \\SELECT selected.label, COALESCE(ld.color, '')
        \\FROM (SELECT DISTINCT label FROM issue_labels WHERE issue_id = ?) AS selected
        \\LEFT JOIN label_definitions ld ON ld.name = selected.label
        \\ORDER BY CASE WHEN ld.id IS NULL THEN 1 ELSE 0 END,
        \\         ld.priority,
        \\         lower(selected.label),
        \\         selected.label
    , issue_id, "None yet");
    try sidebar.appendSectionEnd(buf, allocator);
}

fn appendIssueSidebarPriority(buf: *std.ArrayList(u8), allocator: Allocator, raw_ref: []const u8, priority: []const u8, csrf_token: []const u8) !void {
    try sidebar.appendEditableSectionStart(buf, allocator, "Priority", "Set priority");
    try appendIssueSidebarPriorityMenu(buf, allocator, raw_ref, priority, csrf_token);
    try sidebar.appendEditableSectionBodyStart(buf, allocator);
    if (priority.len == 0) {
        try sidebar.appendEmptyText(buf, allocator, "No priority");
    } else {
        try appendIssuePriorityChip(buf, allocator, priority);
    }
    try sidebar.appendSectionEnd(buf, allocator);
}

fn appendIssueSidebarStatus(buf: *std.ArrayList(u8), allocator: Allocator, raw_ref: []const u8, status: []const u8, csrf_token: []const u8) !void {
    try sidebar.appendEditableSectionStart(buf, allocator, "Status", "Set status");
    try appendIssueSidebarStatusMenu(buf, allocator, raw_ref, status, csrf_token);
    try sidebar.appendEditableSectionBodyStart(buf, allocator);
    if (status.len == 0) {
        try sidebar.appendEmptyText(buf, allocator, "No status");
    } else {
        try appendIssueStatusChip(buf, allocator, status);
    }
    try sidebar.appendSectionEnd(buf, allocator);
}

fn appendIssueSidebarType(buf: *std.ArrayList(u8), allocator: Allocator, raw_ref: []const u8, issue_type: []const u8, csrf_token: []const u8) !void {
    try sidebar.appendEditableSectionStart(buf, allocator, "Type", "Select issue type");
    try sidebar.appendMenuFilter(buf, allocator, "Filter types");
    try sidebar.appendMenuGroupStart(buf, allocator, "Available types");
    try appendIssueSidebarTypeActionRow(buf, allocator, raw_ref, "bug", issue_type, csrf_token);
    try appendIssueSidebarTypeActionRow(buf, allocator, raw_ref, "feature", issue_type, csrf_token);
    try appendIssueSidebarTypeActionRow(buf, allocator, raw_ref, "task", issue_type, csrf_token);
    try sidebar.appendMenuGroupEnd(buf, allocator);
    try sidebar.appendEditableSectionBodyStart(buf, allocator);
    if (issue_type.len == 0) {
        try sidebar.appendEmptyText(buf, allocator, "No type");
    } else {
        try buf.appendSlice(allocator, "<span class=\"issue-sidebar-token\">");
        try appendIssueTypeChip(buf, allocator, issue_type);
        try buf.appendSlice(allocator, "</span>");
    }
    try sidebar.appendSectionEnd(buf, allocator);
}

fn appendIssueSidebarProjects(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, raw_ref: []const u8, issue_id: []const u8, csrf_token: []const u8) !void {
    try sidebar.appendEditableSectionStart(buf, allocator, "Projects", "Select projects");
    try appendIssueSidebarProjectsMenu(buf, allocator, db, raw_ref, issue_id, csrf_token);
    try sidebar.appendEditableSectionBodyStart(buf, allocator);
    var stmt = try db.prepare(selected_issue_sidebar_projects_sql);
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    try stmt.bindText(2, issue_id);
    try stmt.bindText(3, issue_id);
    try stmt.bindText(4, issue_id);
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
    if (!shown) try sidebar.appendEmptyText(buf, allocator, "No projects");
    try sidebar.appendSectionEnd(buf, allocator);
}

fn appendIssueSidebarMilestone(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, raw_ref: []const u8, milestone: []const u8, csrf_token: []const u8) !void {
    try sidebar.appendEditableSectionStart(buf, allocator, "Milestone", "Set milestone");
    try appendIssueSidebarMilestoneMenu(buf, allocator, db, raw_ref, milestone, csrf_token);
    try sidebar.appendEditableSectionBodyStart(buf, allocator);
    if (milestone.len == 0) {
        try sidebar.appendEmptyText(buf, allocator, "No milestone");
    } else {
        try buf.appendSlice(allocator, "<span class=\"issue-sidebar-token\"><span class=\"issue-sidebar-pill\">");
        try shared.appendHtml(buf, allocator, milestone);
        try buf.appendSlice(allocator, "</span></span>");
    }
    try sidebar.appendSectionEnd(buf, allocator);
}

fn appendIssueSidebarRelationships(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, raw_ref: []const u8, issue_id: []const u8, body: []const u8, csrf_token: []const u8) !void {
    try sidebar.appendEditableSectionStart(buf, allocator, "Relationships", "Add relationship");
    try appendIssueSidebarRelationshipsMenu(buf, allocator, db, raw_ref, issue_id, csrf_token);
    try sidebar.appendEditableSectionBodyStart(buf, allocator);
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
    try issue_relationships.collectStoredIssueRelationships(allocator, db, issue_id, &seen, &relationships);
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
        try sidebar.appendEmptyText(buf, allocator, "None yet");
    } else {
        try issue_relationships.appendEditableGroups(buf, allocator, raw_ref, csrf_token, relationships.items);
    }
    try sidebar.appendSectionEnd(buf, allocator);
}

fn appendIssueSidebarDevelopment(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, issue_id: []const u8, body: []const u8) !void {
    try sidebar.appendEditableSectionStart(buf, allocator, "Development", "Link development");
    try appendIssueSidebarDevelopmentMenu(buf, allocator, db);
    try sidebar.appendEditableSectionBodyStart(buf, allocator);
    var links: std.ArrayList(development_links.DevelopmentLink) = .empty;
    defer development_links.freeLinks(allocator, &links);
    try development_links.collectForIssue(allocator, db, issue_id, body, &links);
    var shown = false;
    for (links.items) |link| {
        try development_links.appendLinkRow(buf, allocator, link);
        shown = true;
    }
    var stmt = try db.prepare(
        \\SELECT commit_oid
        \\FROM commit_references
        \\WHERE object_kind = 'issue' AND object_id = ?
        \\ORDER BY commit_oid
        \\LIMIT 8
    );
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
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
    if (!shown) try sidebar.appendEmptyText(buf, allocator, "No linked branches or pull requests.");
    try sidebar.appendSectionEnd(buf, allocator);
}

fn appendIssueSidebarParticipants(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, issue_id: []const u8, author: []const u8) !void {
    try sidebar.appendSectionStart(buf, allocator, "Participants");
    try buf.appendSlice(allocator, "<div class=\"issue-participants\">");
    try sidebar.appendAvatar(buf, allocator, author, "");
    var stmt = try db.prepare("SELECT DISTINCT assignee FROM issue_assignees WHERE issue_id = ? AND assignee <> ? ORDER BY assignee");
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    try stmt.bindText(2, author);
    while (try stmt.step()) {
        const assignee = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(assignee);
        try sidebar.appendAvatar(buf, allocator, assignee, "");
    }
    try buf.appendSlice(allocator, "</div>");
    try sidebar.appendSectionEnd(buf, allocator);
}

fn appendIssueSidebarAssigneeMenu(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, raw_ref: []const u8, issue_id: []const u8, csrf_token: []const u8) !void {
    try sidebar.appendSingleInputForm(buf, allocator, issueSidebarForm(raw_ref, csrf_token), "add-assignee", "value", "Add assignee", "Filter assignees");
    try sidebar.appendMenuGroupStart(buf, allocator, "Assigned");
    var selected = try db.prepare("SELECT DISTINCT assignee FROM issue_assignees WHERE issue_id = ? ORDER BY lower(assignee), assignee");
    defer selected.deinit();
    try selected.bindText(1, issue_id);
    var shown = false;
    while (try selected.step()) {
        const assignee = try selected.columnTextDup(allocator, 0);
        defer allocator.free(assignee);
        try sidebar.appendPersonActionRow(buf, allocator, issueSidebarForm(raw_ref, csrf_token), "remove-assignee", assignee, true);
        shown = true;
    }
    if (!shown) try sidebar.appendMenuEmpty(buf, allocator, "No assignees selected.");
    try sidebar.appendMenuGroupEnd(buf, allocator);

    try sidebar.appendMenuGroupStart(buf, allocator, "Suggestions");
    var suggestions = try db.prepare(
        \\SELECT DISTINCT assignee
        \\FROM (
        \\  SELECT assignee AS assignee FROM issue_assignees
        \\  UNION
        \\  SELECT COALESCE(NULLIF(m.source_author, ''), NULLIF(si.display_name, ''), i.author_principal) AS assignee
        \\  FROM issues i
        \\  LEFT JOIN issue_metadata m ON m.issue_id = i.id
        \\  LEFT JOIN identities si ON si.id = m.source_identity
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
        try sidebar.appendPersonActionRow(buf, allocator, issueSidebarForm(raw_ref, csrf_token), "add-assignee", assignee, false);
        shown = true;
    }
    if (!shown) try sidebar.appendMenuEmpty(buf, allocator, "No assignee suggestions.");
    try sidebar.appendMenuGroupEnd(buf, allocator);
}

fn appendIssueSidebarLabelsMenu(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, raw_ref: []const u8, issue_id: []const u8, csrf_token: []const u8) !void {
    try sidebar.appendSingleInputForm(buf, allocator, issueSidebarForm(raw_ref, csrf_token), "add-label", "value", "Add label", "Filter labels");
    try sidebar.appendMenuGroupStart(buf, allocator, "Selected labels");
    var selected = try db.prepare(
        \\SELECT selected.label, COALESCE(ld.color, '')
        \\FROM (SELECT DISTINCT label FROM issue_labels WHERE issue_id = ?) AS selected
        \\LEFT JOIN label_definitions ld ON ld.name = selected.label
        \\ORDER BY CASE WHEN ld.id IS NULL THEN 1 ELSE 0 END,
        \\         ld.priority,
        \\         lower(selected.label),
        \\         selected.label
    );
    defer selected.deinit();
    try selected.bindText(1, issue_id);
    var shown = false;
    while (try selected.step()) {
        const label = try selected.columnTextDup(allocator, 0);
        defer allocator.free(label);
        const color = try selected.columnTextDup(allocator, 1);
        defer allocator.free(color);
        try sidebar.appendLabelActionRow(buf, allocator, issueSidebarForm(raw_ref, csrf_token), "remove-label", label, color, true);
        shown = true;
    }
    if (!shown) try sidebar.appendMenuEmpty(buf, allocator, "No labels selected.");
    try sidebar.appendMenuGroupEnd(buf, allocator);

    try sidebar.appendMenuGroupStart(buf, allocator, "Suggestions");
    var suggestions = try db.prepare(
        \\WITH label_names AS (
        \\  SELECT name AS label FROM label_definitions
        \\  UNION
        \\  SELECT label FROM issue_labels
        \\  UNION
        \\  SELECT label FROM pull_labels
        \\)
        \\SELECT label_names.label, COALESCE(ld.color, '')
        \\FROM label_names
        \\LEFT JOIN label_definitions ld ON ld.name = label_names.label
        \\WHERE label_names.label NOT IN (SELECT label FROM issue_labels WHERE issue_id = ?)
        \\ORDER BY CASE WHEN ld.id IS NULL THEN 1 ELSE 0 END,
        \\         ld.priority,
        \\         lower(label_names.label),
        \\         label_names.label
        \\LIMIT 24
    );
    defer suggestions.deinit();
    try suggestions.bindText(1, issue_id);
    shown = false;
    while (try suggestions.step()) {
        const label = try suggestions.columnTextDup(allocator, 0);
        defer allocator.free(label);
        const color = try suggestions.columnTextDup(allocator, 1);
        defer allocator.free(color);
        try sidebar.appendLabelActionRow(buf, allocator, issueSidebarForm(raw_ref, csrf_token), "add-label", label, color, false);
        shown = true;
    }
    if (!shown) try sidebar.appendMenuEmpty(buf, allocator, "No label suggestions.");
    try sidebar.appendMenuGroupEnd(buf, allocator);
}

fn appendIssueSidebarProjectsMenu(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, raw_ref: []const u8, issue_id: []const u8, csrf_token: []const u8) !void {
    try appendIssueSidebarProjectForm(buf, allocator, raw_ref, csrf_token);
    try sidebar.appendMenuGroupStart(buf, allocator, "Selected projects");
    var selected = try db.prepare(selected_issue_sidebar_projects_sql);
    defer selected.deinit();
    try selected.bindText(1, issue_id);
    try selected.bindText(2, issue_id);
    try selected.bindText(3, issue_id);
    try selected.bindText(4, issue_id);
    var shown = false;
    while (try selected.step()) {
        const project = try selected.columnTextDup(allocator, 0);
        defer allocator.free(project);
        const column = try selected.columnTextDup(allocator, 1);
        defer allocator.free(column);
        try appendIssueSidebarProjectActionRow(buf, allocator, db, raw_ref, "add-project", project, column, true, csrf_token);
        shown = true;
    }
    if (!shown) try sidebar.appendMenuEmpty(buf, allocator, "No projects selected.");
    try sidebar.appendMenuGroupEnd(buf, allocator);

    try sidebar.appendMenuGroupStart(buf, allocator, "Suggestions");
    var suggestions = try db.prepare(
        \\SELECT DISTINCT candidate.project, candidate.column_name
        \\FROM (
        \\  SELECT p.name AS project, 'Draft' AS column_name
        \\  FROM projects p
        \\  WHERE p.state <> 'closed'
        \\  UNION
        \\  SELECT project, 'Draft' AS column_name FROM issue_projects
        \\) AS candidate
        \\WHERE candidate.project <> ''
        \\  AND NOT EXISTS (
        \\    SELECT 1 FROM issue_projects ip
        \\    WHERE ip.issue_id = ?
        \\      AND ip.project = candidate.project
        \\  )
        \\  AND NOT EXISTS (
        \\    SELECT 1
        \\    FROM project_memberships pm
        \\    JOIN projects p ON p.id = pm.project_id
        \\    WHERE pm.issue_id = ?
        \\      AND p.name = candidate.project
        \\  )
        \\ORDER BY lower(candidate.project), candidate.project
        \\LIMIT 20
    );
    defer suggestions.deinit();
    try suggestions.bindText(1, issue_id);
    try suggestions.bindText(2, issue_id);
    shown = false;
    while (try suggestions.step()) {
        const project = try suggestions.columnTextDup(allocator, 0);
        defer allocator.free(project);
        const column = try suggestions.columnTextDup(allocator, 1);
        defer allocator.free(column);
        try appendIssueSidebarProjectActionRow(buf, allocator, db, raw_ref, "add-project", project, column, false, csrf_token);
        shown = true;
    }
    if (!shown) try sidebar.appendMenuEmpty(buf, allocator, "No project suggestions.");
    try sidebar.appendMenuGroupEnd(buf, allocator);
}

fn appendIssueSidebarMilestoneMenu(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, raw_ref: []const u8, milestone: []const u8, csrf_token: []const u8) !void {
    try sidebar.appendSingleInputForm(buf, allocator, issueSidebarForm(raw_ref, csrf_token), "set-milestone", "milestone", "Set milestone", "Filter milestones");
    try sidebar.appendMenuGroupStart(buf, allocator, "Selected milestone");
    if (milestone.len == 0) {
        try sidebar.appendMenuEmpty(buf, allocator, "No milestone selected.");
    } else {
        try appendIssueSidebarMilestoneActionRow(buf, allocator, raw_ref, milestone, true, csrf_token);
    }
    try sidebar.appendMenuGroupEnd(buf, allocator);

    try sidebar.appendMenuGroupStart(buf, allocator, "Suggestions");
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
        try appendIssueSidebarMilestoneActionRow(buf, allocator, raw_ref, candidate, false, csrf_token);
        shown = true;
    }
    if (!shown) try sidebar.appendMenuEmpty(buf, allocator, "No milestone suggestions.");
    try sidebar.appendMenuGroupEnd(buf, allocator);
}

fn appendIssueSidebarPriorityMenu(buf: *std.ArrayList(u8), allocator: Allocator, raw_ref: []const u8, selected_priority: []const u8, csrf_token: []const u8) !void {
    try sidebar.appendMenuGroupStart(buf, allocator, "Priorities");
    for (project_views.project_priority_values) |priority| {
        try appendIssueSidebarPriorityActionRow(buf, allocator, raw_ref, priority, std.mem.eql(u8, selected_priority, priority), csrf_token);
    }
    try sidebar.appendMenuGroupEnd(buf, allocator);
}

fn appendIssueSidebarStatusMenu(buf: *std.ArrayList(u8), allocator: Allocator, raw_ref: []const u8, selected_status: []const u8, csrf_token: []const u8) !void {
    try sidebar.appendMenuGroupStart(buf, allocator, "Statuses");
    for (project_views.project_status_values) |status| {
        try appendIssueSidebarStatusActionRow(buf, allocator, raw_ref, status, std.mem.eql(u8, selected_status, status), csrf_token);
    }
    try sidebar.appendMenuGroupEnd(buf, allocator);
}

fn appendIssueSidebarRelationshipsMenu(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, raw_ref: []const u8, issue_id: []const u8, csrf_token: []const u8) !void {
    try buf.appendSlice(allocator, "<div class=\"issue-sidebar-relationship-menu\" data-issue-relationship-menu>");
    try buf.appendSlice(allocator, "<div class=\"issue-sidebar-relationship-panel is-active\" data-issue-relationship-panel=\"actions\">");
    try appendIssueSidebarRelationshipActionRow(buf, allocator, "parent", "Add parent");
    try appendIssueSidebarRelationshipActionRow(buf, allocator, "sub-issue-create", "Create sub-issue");
    try appendIssueSidebarRelationshipActionRow(buf, allocator, "sub-issue", "Add sub-issue");
    try appendIssueSidebarRelationshipActionRow(buf, allocator, "blocked-by", "Mark as blocked by");
    try appendIssueSidebarRelationshipActionRow(buf, allocator, "blocking", "Add or change blocking");
    try appendIssueSidebarRelationshipActionRow(buf, allocator, "concurrent-group", "Add to group");
    try buf.appendSlice(allocator, "</div>");

    try appendIssueSidebarRelationshipPickerPanelStart(buf, allocator, "parent", "Add parent");
    try sidebar.appendMenuFilter(buf, allocator, "Search issues");
    try appendIssueSidebarRelationshipIssueGroup(buf, allocator, db, raw_ref, issue_id, "Issues", "add-parent", "Set parent", csrf_token);
    try appendIssueSidebarRelationshipPanelEnd(buf, allocator);

    try appendIssueSidebarRelationshipPickerPanelStart(buf, allocator, "sub-issue-create", "Create sub-issue");
    try sidebar.appendSingleInputForm(buf, allocator, issueSidebarForm(raw_ref, csrf_token), "create-sub-issue", "title", "Create sub-issue", "Sub-issue title");
    try appendIssueSidebarRelationshipPanelEnd(buf, allocator);

    try appendIssueSidebarRelationshipPickerPanelStart(buf, allocator, "sub-issue", "Add sub-issue");
    try sidebar.appendMenuFilter(buf, allocator, "Search issues");
    try appendIssueSidebarRelationshipIssueGroup(buf, allocator, db, raw_ref, issue_id, "Issues", "add-sub-issue", "Add sub-issue", csrf_token);
    try appendIssueSidebarRelationshipPanelEnd(buf, allocator);

    try appendIssueSidebarRelationshipPickerPanelStart(buf, allocator, "blocked-by", "Mark as blocked by");
    try sidebar.appendMenuFilter(buf, allocator, "Search issues");
    try appendIssueSidebarRelationshipIssueGroup(buf, allocator, db, raw_ref, issue_id, "Issues", "add-blocked-by", "Mark blocked by", csrf_token);
    try appendIssueSidebarRelationshipPanelEnd(buf, allocator);

    try appendIssueSidebarRelationshipPickerPanelStart(buf, allocator, "blocking", "Add or change blocking");
    try sidebar.appendMenuFilter(buf, allocator, "Search issues");
    try appendIssueSidebarRelationshipIssueGroup(buf, allocator, db, raw_ref, issue_id, "Issues", "add-blocking", "Mark as blocking", csrf_token);
    try appendIssueSidebarRelationshipPanelEnd(buf, allocator);

    try appendIssueSidebarRelationshipPickerPanelStart(buf, allocator, "concurrent-group", "Add to group");
    try sidebar.appendSingleInputForm(buf, allocator, issueSidebarForm(raw_ref, csrf_token), "add-concurrent-group", "group", "Add to group", "Concurrent group");
    try appendIssueSidebarRelationshipPanelEnd(buf, allocator);
    try buf.appendSlice(allocator, "</div>");
}

fn appendIssueSidebarRelationshipActionRow(buf: *std.ArrayList(u8), allocator: Allocator, panel: []const u8, label: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<button class="issue-sidebar-picker-row issue-sidebar-relationship-action" type="button" data-issue-relationship-panel-target="{panel}"><span class="issue-sidebar-picker-primary">{label}</span><span class="issue-sidebar-action-caret" aria-hidden="true"></span></button>
    , .{
        .panel = panel,
        .label = label,
    });
}

fn appendIssueSidebarRelationshipPickerPanelStart(buf: *std.ArrayList(u8), allocator: Allocator, panel: []const u8, title: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<div class="issue-sidebar-relationship-panel" data-issue-relationship-panel="{panel}" hidden><button class="issue-sidebar-relationship-back" type="button" data-issue-relationship-panel-target="actions"><span aria-hidden="true"></span>Back</button><div class="issue-sidebar-popover-subtitle">{title}</div>
    , .{
        .panel = panel,
        .title = title,
    });
}

fn appendIssueSidebarRelationshipPanelEnd(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator, "</div>");
}

fn appendIssueSidebarRelationshipIssueGroup(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    raw_ref: []const u8,
    current_issue_id: []const u8,
    title: []const u8,
    action: []const u8,
    button_label: []const u8,
    csrf_token: []const u8,
) !void {
    try sidebar.appendMenuGroupStart(buf, allocator, title);
    var stmt = try db.prepare(
        \\SELECT i.id, i.title, i.state, COALESCE(a.number, 0)
        \\FROM issues i
        \\LEFT JOIN legacy_aliases a
        \\  ON a.provider = 'github' AND a.object_kind = 'issue' AND a.object_id = i.id
        \\WHERE i.id <> ?
        \\ORDER BY CASE i.state WHEN 'open' THEN 0 ELSE 1 END,
        \\         i.opened_at DESC,
        \\         i.id
        \\LIMIT 40
    );
    defer stmt.deinit();
    try stmt.bindText(1, current_issue_id);

    var shown = false;
    while (try stmt.step()) {
        const target_id = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(target_id);
        const target_title = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(target_title);
        const state = try stmt.columnTextDup(allocator, 2);
        defer allocator.free(state);
        const legacy_number = stmt.columnInt64(3);
        try appendIssueSidebarIssueRelationshipChoice(buf, allocator, raw_ref, action, target_id, target_title, state, legacy_number, button_label, csrf_token);
        shown = true;
    }
    if (!shown) try sidebar.appendMenuEmpty(buf, allocator, "No other issues.");
    try sidebar.appendMenuGroupEnd(buf, allocator);
}

fn appendIssueSidebarDevelopmentMenu(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb) !void {
    try sidebar.appendMenuFilter(buf, allocator, "Search pull requests");
    try sidebar.appendMenuGroupStart(buf, allocator, "Open pull requests");
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
    if (!shown) try sidebar.appendMenuEmpty(buf, allocator, "No open pull requests.");
    try sidebar.appendMenuGroupEnd(buf, allocator);
}

fn appendIssueSidebarProjectForm(buf: *std.ArrayList(u8), allocator: Allocator, raw_ref: []const u8, csrf_token: []const u8) !void {
    try buf.appendSlice(allocator, "<form class=\"issue-sidebar-add-form issue-sidebar-project-form issue-sidebar-menu-form\" method=\"post\" action=\"");
    try sidebar.appendAction(buf, allocator, issueSidebarForm(raw_ref, csrf_token));
    try buf.appendSlice(allocator, "\">");
    try sidebar.appendCsrfInput(buf, allocator, issueSidebarForm(raw_ref, csrf_token));
    try sidebar.appendHiddenInput(buf, allocator, "action", "add-project");
    try sidebar.appendHiddenInput(buf, allocator, "column", project_views.default_project_status);
    try buf.appendSlice(allocator, "<label class=\"issue-sidebar-menu-input\"><span aria-hidden=\"true\"></span><input name=\"project\" placeholder=\"Filter projects\" aria-label=\"Project\" autocomplete=\"off\" data-issue-sidebar-filter></label><button type=\"submit\">Add project</button></form>");
}

fn appendIssueSidebarMilestoneActionRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_ref: []const u8,
    milestone: []const u8,
    selected: bool,
    csrf_token: []const u8,
) !void {
    if (selected) {
        try buf.appendSlice(allocator, "<form class=\"issue-sidebar-picker-form\" method=\"post\" action=\"");
        try sidebar.appendAction(buf, allocator, issueSidebarForm(raw_ref, csrf_token));
        try buf.appendSlice(allocator, "\">");
        try sidebar.appendCsrfInput(buf, allocator, issueSidebarForm(raw_ref, csrf_token));
        try appendTemplate(buf, allocator,
            \\<input type="hidden" name="action" value="clear-milestone"><button class="issue-sidebar-picker-row is-selected" type="submit" data-sidebar-filter-text="{milestone}"><span class="issue-sidebar-picker-check" aria-hidden="true"></span><span class="issue-milestone-icon" aria-hidden="true"></span><span class="issue-sidebar-picker-primary">{milestone}</span></button></form>
        , .{ .milestone = milestone });
        return;
    }

    try buf.appendSlice(allocator, "<form class=\"issue-sidebar-picker-form\" method=\"post\" action=\"");
    try sidebar.appendAction(buf, allocator, issueSidebarForm(raw_ref, csrf_token));
    try buf.appendSlice(allocator, "\">");
    try sidebar.appendCsrfInput(buf, allocator, issueSidebarForm(raw_ref, csrf_token));
    try appendTemplate(buf, allocator,
        \\<input type="hidden" name="action" value="set-milestone"><input type="hidden" name="milestone" value="{milestone}"><button class="issue-sidebar-picker-row" type="submit" data-sidebar-filter-text="{milestone}"><span class="issue-sidebar-picker-check" aria-hidden="true"></span><span class="issue-milestone-icon" aria-hidden="true"></span><span class="issue-sidebar-picker-primary">{milestone}</span></button></form>
    , .{ .milestone = milestone });
}

fn appendIssueSidebarProjectActionRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    raw_ref: []const u8,
    action: []const u8,
    project: []const u8,
    column: []const u8,
    selected: bool,
    csrf_token: []const u8,
) !void {
    const state_class: []const u8 = if (selected) " is-selected" else "";
    const remove_class: []const u8 = if (selected) " has-remove" else "";
    const check_label: []const u8 = if (selected) "Update project status" else "Add project to selected status";
    try buf.appendSlice(allocator, "<form class=\"issue-sidebar-picker-form\" method=\"post\" action=\"");
    try sidebar.appendAction(buf, allocator, issueSidebarForm(raw_ref, csrf_token));
    try appendTemplate(buf, allocator,
        \\" data-sidebar-filter-text="{project} {column}">
    , .{
        .project = project,
        .column = column,
    });
    try sidebar.appendCsrfInput(buf, allocator, issueSidebarForm(raw_ref, csrf_token));
    try appendTemplate(buf, allocator,
        \\<input type="hidden" name="project" value="{project}"><div class="issue-sidebar-project-choice-row{state_class}{remove_class}"><button class="issue-sidebar-project-check{state_class}" type="submit" name="action" value="{action}" aria-label="{check_label}"><span class="issue-sidebar-picker-check" aria-hidden="true"></span></button><span class="issue-sidebar-project-icon" aria-hidden="true"></span><span class="issue-sidebar-picker-text"><span class="issue-sidebar-picker-primary">{project}</span></span><select class="issue-sidebar-project-status-select" name="column" aria-label="Status">
    , .{
        .action = action,
        .project = project,
        .state_class = state_class,
        .remove_class = remove_class,
        .check_label = check_label,
    });
    try appendIssueSidebarProjectStatusOptions(buf, allocator, db, project, column);
    try buf.appendSlice(allocator, "</select>");
    if (selected) {
        try buf.appendSlice(allocator, "<button class=\"issue-sidebar-project-remove-button\" type=\"submit\" name=\"action\" value=\"remove-project\" aria-label=\"Remove project\">x</button>");
    }
    try buf.appendSlice(allocator, "</div></form>");
}

fn appendIssueSidebarProjectStatusOptions(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    project: []const u8,
    selected_column: []const u8,
) !void {
    var stmt = try db.prepare(
        \\SELECT DISTINCT pc.column_name
        \\FROM project_columns pc
        \\JOIN projects p ON p.id = pc.project_id
        \\WHERE p.name = ?
        \\  AND pc.column_name <> ''
        \\ORDER BY CASE pc.column_name
        \\           WHEN 'Draft' THEN 0
        \\           WHEN 'Todo' THEN 1
        \\           WHEN 'WIP' THEN 2
        \\           WHEN 'Review' THEN 3
        \\           WHEN 'Done' THEN 4
        \\           WHEN 'Failed' THEN 5
        \\           ELSE 6
        \\         END,
        \\         lower(pc.column_name),
        \\         pc.column_name
    );
    defer stmt.deinit();
    try stmt.bindText(1, project);

    var shown = false;
    var selected_seen = false;
    while (try stmt.step()) {
        const column = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(column);
        const is_selected = std.mem.eql(u8, column, selected_column);
        selected_seen = selected_seen or is_selected;
        shown = true;
        try appendIssueSidebarProjectStatusOption(buf, allocator, column, is_selected);
    }

    if (!shown) {
        try appendDefaultProjectStatusOptions(buf, allocator, selected_column);
    } else if (selected_column.len != 0 and !selected_seen) {
        try appendIssueSidebarProjectStatusOption(buf, allocator, selected_column, true);
    }
}

fn appendDefaultProjectStatusOptions(buf: *std.ArrayList(u8), allocator: Allocator, selected_column: []const u8) !void {
    var selected_seen = false;
    for (project_views.project_status_values) |status| {
        const is_selected = std.mem.eql(u8, status, selected_column);
        selected_seen = selected_seen or is_selected;
        try appendIssueSidebarProjectStatusOption(buf, allocator, status, is_selected);
    }
    if (selected_column.len != 0 and !selected_seen) {
        try appendIssueSidebarProjectStatusOption(buf, allocator, selected_column, true);
    }
}

fn appendIssueSidebarProjectStatusOption(buf: *std.ArrayList(u8), allocator: Allocator, value: []const u8, selected: bool) !void {
    try buf.appendSlice(allocator, "<option value=\"");
    try shared.appendHtml(buf, allocator, value);
    try buf.append(allocator, '"');
    if (selected) try buf.appendSlice(allocator, " selected");
    try buf.append(allocator, '>');
    try shared.appendHtml(buf, allocator, value);
    try buf.appendSlice(allocator, "</option>");
}

fn appendIssueSidebarPriorityActionRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_ref: []const u8,
    priority: []const u8,
    selected: bool,
    csrf_token: []const u8,
) !void {
    try sidebar.appendValueActionFormStart(buf, allocator, issueSidebarForm(raw_ref, csrf_token), "set-priority", "priority", priority, priority, selected);
    try appendIssuePriorityChip(buf, allocator, priority);
    try buf.appendSlice(allocator, "</button></form>");
}

fn appendIssueSidebarStatusActionRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_ref: []const u8,
    status: []const u8,
    selected: bool,
    csrf_token: []const u8,
) !void {
    try sidebar.appendValueActionFormStart(buf, allocator, issueSidebarForm(raw_ref, csrf_token), "set-status", "status", status, status, selected);
    try appendIssueStatusChip(buf, allocator, status);
    try buf.appendSlice(allocator, "</button></form>");
}

fn appendIssueSidebarTypeActionRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_ref: []const u8,
    issue_type: []const u8,
    selected_type: []const u8,
    csrf_token: []const u8,
) !void {
    const filter_text = try std.fmt.allocPrint(allocator, "{s} {s}", .{ issueTypeLabel(issue_type), issueTypeDescription(issue_type) });
    defer allocator.free(filter_text);
    try sidebar.appendValueActionFormStart(buf, allocator, issueSidebarForm(raw_ref, csrf_token), "set-type", "type", issue_type, filter_text, std.mem.eql(u8, selected_type, issue_type));
    try appendIssueTypeDot(buf, allocator, issue_type);
    try appendTemplate(buf, allocator,
        \\<span class="issue-sidebar-picker-text"><span class="issue-sidebar-picker-primary">{title}</span><span class="issue-sidebar-picker-secondary">{description}</span></span></button></form>
    , .{
        .title = issueTypeLabel(issue_type),
        .description = issueTypeDescription(issue_type),
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

fn appendIssueSidebarIssueRelationshipChoice(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_ref: []const u8,
    action: []const u8,
    target_id: []const u8,
    title: []const u8,
    state: []const u8,
    legacy_number: i64,
    button_label: []const u8,
    csrf_token: []const u8,
) !void {
    var issue_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const issue_ref = util.shortObjectRef(&issue_ref_buf, target_id);
    const number_text = try issueNumberText(allocator, issue_ref, legacy_number);
    defer allocator.free(number_text);

    try buf.appendSlice(allocator, "<form class=\"issue-sidebar-picker-form issue-sidebar-relationship-choice-form\" method=\"post\" action=\"");
    try sidebar.appendAction(buf, allocator, issueSidebarForm(raw_ref, csrf_token));
    try buf.appendSlice(allocator, "\">");
    try sidebar.appendCsrfInput(buf, allocator, issueSidebarForm(raw_ref, csrf_token));
    try appendTemplate(buf, allocator,
        \\<input type="hidden" name="action" value="{action}"><input type="hidden" name="target" value="{target_id}"><button class="issue-sidebar-picker-row issue-sidebar-issue-choice" type="submit" data-sidebar-filter-text="{title} {number_text}" aria-label="{button_label} {title} {number_text}"><span class="issue-sidebar-picker-check" aria-hidden="true"></span><span class="{icon_classes}" aria-hidden="true"></span><span class="issue-sidebar-picker-text"><span class="issue-sidebar-picker-primary">{title}</span></span><span class="issue-sidebar-picker-secondary issue-sidebar-choice-ref">{number_text}</span></button></form>
    , .{
        .action = action,
        .target_id = target_id,
        .title = title,
        .number_text = number_text,
        .button_label = button_label,
        .icon_classes = shared.classes("issue-sidebar-issue-icon", &.{
            shared.class("is-open", std.mem.eql(u8, state, "open")),
            shared.class("is-closed", std.mem.eql(u8, state, "closed")),
        }),
    });
}

fn issueNumberText(allocator: Allocator, issue_ref: []const u8, legacy_number: i64) ![]u8 {
    if (legacy_number > 0) return try std.fmt.allocPrint(allocator, "#{d}", .{legacy_number});
    return try std.fmt.allocPrint(allocator, "#{s}", .{issue_ref});
}

fn pullNumberText(allocator: Allocator, pull_ref: []const u8, legacy_number: i64) ![]u8 {
    if (legacy_number > 0) return try std.fmt.allocPrint(allocator, "#{d}", .{legacy_number});
    return try std.fmt.allocPrint(allocator, "#{s}", .{pull_ref});
}

fn replaceIssueProjectPlacement(allocator: Allocator, repo: Repo, issue_id: []const u8, project: []const u8, column: []const u8) !void {
    var existing = try loadIssueProjectColumns(allocator, repo, issue_id, project);
    defer freeColumnList(allocator, &existing);

    if (existing.items.len == 1 and std.mem.eql(u8, existing.items[0], column)) return;

    for (existing.items) |existing_column| {
        try createIssueProjectEvent(allocator, issue_id, project, existing_column, null, null, false);
    }
    try createIssueProjectEvent(allocator, issue_id, project, column, null, null, true);
}

fn removeIssueProjectPlacements(allocator: Allocator, repo: Repo, issue_id: []const u8, project: []const u8) !void {
    var existing = try loadIssueProjectColumns(allocator, repo, issue_id, project);
    defer freeColumnList(allocator, &existing);

    if (existing.items.len == 0) {
        try createIssueProjectEvent(allocator, issue_id, project, "", null, null, false);
        return;
    }

    for (existing.items) |existing_column| {
        try createIssueProjectEvent(allocator, issue_id, project, existing_column, null, null, false);
    }
}

fn loadIssueProjectColumns(allocator: Allocator, repo: Repo, issue_id: []const u8, project: []const u8) !std.ArrayList([]u8) {
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var stmt = try db.prepare(
        \\SELECT DISTINCT column_name
        \\FROM issue_projects
        \\WHERE issue_id = ? AND project = ?
        \\ORDER BY column_name
    );
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    try stmt.bindText(2, project);

    var columns: std.ArrayList([]u8) = .empty;
    errdefer freeColumnList(allocator, &columns);
    while (try stmt.step()) {
        try columns.append(allocator, try stmt.columnTextDup(allocator, 0));
    }
    return columns;
}

fn freeColumnList(allocator: Allocator, columns: *std.ArrayList([]u8)) void {
    for (columns.items) |column| allocator.free(column);
    columns.deinit(allocator);
}

pub fn handleIssueSidebarPost(allocator: Allocator, repo: Repo, stream: std.net.Stream, raw_ref: []const u8, csrf_token: []const u8, form_body: []const u8) !void {
    if (!(try validateIssueSidebarCsrf(allocator, stream, csrf_token, form_body))) return;

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
        const value_owned = try sidebar.requiredValue(allocator, stream, form_body, "value", "Label is required.");
        const value = value_owned orelse return;
        defer allocator.free(value);
        const event_type: []const u8 = if (std.mem.eql(u8, action, "add-label")) "issue.label_added" else "issue.label_removed";
        if (!(try writeSidebarStringEventOrFail(allocator, stream, issue_id, event_type, "label", value))) return;
    } else if (std.mem.eql(u8, action, "add-assignee") or std.mem.eql(u8, action, "remove-assignee")) {
        const value_owned = try sidebar.requiredValue(allocator, stream, form_body, "value", "Assignee is required.");
        const value = value_owned orelse return;
        defer allocator.free(value);
        const event_type: []const u8 = if (std.mem.eql(u8, action, "add-assignee")) "issue.assignee_added" else "issue.assignee_removed";
        if (!(try writeSidebarStringEventOrFail(allocator, stream, issue_id, event_type, "assignee", value))) return;
    } else if (std.mem.eql(u8, action, "set-milestone")) {
        const milestone_owned = (try formValueOwned(allocator, form_body, "milestone")) orelse try allocator.dupe(u8, "");
        defer allocator.free(milestone_owned);
        const milestone = std.mem.trim(u8, milestone_owned, " \t\r\n");
        if (milestone.len != 0) {
            ensureMilestoneCreatedForTitle(allocator, repo, milestone) catch {
                try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not create milestone\n");
                return;
            };
        }
        if (!(try writeSidebarStringEventOrFail(allocator, stream, issue_id, "issue.milestone_set", "milestone", milestone))) return;
    } else if (std.mem.eql(u8, action, "clear-milestone")) {
        if (!(try writeSidebarStringEventOrFail(allocator, stream, issue_id, "issue.milestone_set", "milestone", ""))) return;
    } else if (std.mem.eql(u8, action, "set-priority")) {
        const priority_owned = try sidebar.requiredValue(allocator, stream, form_body, "priority", "Priority is required.");
        const priority = priority_owned orelse return;
        defer allocator.free(priority);
        if (!isIssuePriority(priority)) {
            try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Priority must be P0, P1, P2, or P3\n");
            return;
        }
        if (!(try writeSidebarStringEventOrFail(allocator, stream, issue_id, "issue.priority_set", "priority", priority))) return;
    } else if (std.mem.eql(u8, action, "set-type")) {
        const type_owned = try sidebar.requiredValue(allocator, stream, form_body, "type", "Type is required.");
        const issue_type = type_owned orelse return;
        defer allocator.free(issue_type);
        if (!isIssueType(issue_type)) {
            try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Type must be bug, feature, or task\n");
            return;
        }
        if (!(try writeSidebarStringEventOrFail(allocator, stream, issue_id, "issue.type_set", "type", issue_type))) return;
    } else if (std.mem.eql(u8, action, "set-status")) {
        const status_owned = try sidebar.requiredValue(allocator, stream, form_body, "status", "Status is required.");
        const status = status_owned orelse return;
        defer allocator.free(status);
        if (!isIssueStatus(status)) {
            try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Status must be Draft, Todo, WIP, Review, Done, or Failed\n");
            return;
        }
        if (!(try writeSidebarStringEventOrFail(allocator, stream, issue_id, "issue.status_set", "status", status))) return;
    } else if (std.mem.eql(u8, action, "add-project") or std.mem.eql(u8, action, "remove-project")) {
        const project_owned = try sidebar.requiredValue(allocator, stream, form_body, "project", "Project is required.");
        const project_value = project_owned orelse return;
        defer allocator.free(project_value);
        const add = std.mem.eql(u8, action, "add-project");
        if (add) {
            const column_owned = try sidebar.requiredValue(allocator, stream, form_body, "column", "Status is required.");
            const column_value = column_owned orelse return;
            defer allocator.free(column_value);
            replaceIssueProjectPlacement(allocator, repo, issue_id, project_value, column_value) catch {
                try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not update issue project placement\n");
                return;
            };
        } else {
            removeIssueProjectPlacements(allocator, repo, issue_id, project_value) catch {
                try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not update issue project placement\n");
                return;
            };
        }
    } else if (std.mem.eql(u8, action, "create-sub-issue")) {
        const title_owned = try sidebar.requiredValue(allocator, stream, form_body, "title", "Sub-issue title is required.");
        const title = title_owned orelse return;
        defer allocator.free(title);
        const result = createSubIssueOpenedWithMetadataEventResult(allocator, issue_id, title, "", &.{}, &.{}, .{}) catch {
            try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not create sub-issue\n");
            return;
        };
        defer result.deinit(allocator);
    } else if (std.mem.eql(u8, action, "add-parent") or
        std.mem.eql(u8, action, "remove-parent") or
        std.mem.eql(u8, action, "add-sub-issue") or
        std.mem.eql(u8, action, "remove-sub-issue") or
        std.mem.eql(u8, action, "add-blocked-by") or
        std.mem.eql(u8, action, "remove-blocked-by") or
        std.mem.eql(u8, action, "add-blocking") or
        std.mem.eql(u8, action, "remove-blocking"))
    {
        const target_ref_owned = try sidebar.requiredValue(allocator, stream, form_body, "target", "Issue ref is required.");
        const target_ref = target_ref_owned orelse return;
        defer allocator.free(target_ref);
        const target_id = index.resolveIssueId(allocator, repo, target_ref) catch {
            try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Target issue was not found\n");
            return;
        };
        defer allocator.free(target_id);
        if (std.mem.eql(u8, issue_id, target_id)) {
            try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Issue cannot be related to itself\n");
            return;
        }

        const inverse_action = std.mem.eql(u8, action, "add-sub-issue") or
            std.mem.eql(u8, action, "remove-sub-issue") or
            std.mem.eql(u8, action, "add-blocked-by") or
            std.mem.eql(u8, action, "remove-blocked-by");
        const relationship_source = if (inverse_action) target_id else issue_id;
        const relationship_target = if (inverse_action) issue_id else target_id;
        const relationship_kind: []const u8 = if (std.mem.indexOf(u8, action, "parent") != null or std.mem.indexOf(u8, action, "sub-issue") != null) "parent" else "blocks";
        const add_relationship = std.mem.startsWith(u8, action, "add-");
        createIssueRelationshipEvent(allocator, relationship_source, relationship_kind, relationship_target, add_relationship) catch {
            try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not update issue relationship\n");
            return;
        };
    } else if (std.mem.eql(u8, action, "add-concurrent-group") or std.mem.eql(u8, action, "remove-concurrent-group")) {
        const group_owned = try sidebar.requiredValue(allocator, stream, form_body, "group", "Concurrent group is required.");
        const group = group_owned orelse return;
        defer allocator.free(group);
        createIssueConcurrentGroupEvent(allocator, issue_id, group, std.mem.eql(u8, action, "add-concurrent-group")) catch {
            try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not update concurrent group\n");
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
