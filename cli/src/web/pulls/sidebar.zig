const std = @import("std");
const development_links = @import("../development_links.zig");
const git = @import("../../git.zig");
const index = @import("../../index.zig");
const pr = @import("../../pr.zig");
const repo_mod = @import("../../repo.zig");
const shared = @import("../shared.zig");
const sidebar = @import("../shared/sidebar.zig");
const util = @import("../../util.zig");
const work_items = @import("../../work_items.zig");
const zwf = @import("../../zwf.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const SqliteDb = index.SqliteDb;
const PullDetail = work_items.PullDetail;
const appendTemplate = shared.appendTemplate;
const commitHref = shared.commitHref;
const issueHref = shared.issueHref;
const runCommand = git.runCommand;
const sendPlainResponse = shared.sendPlainResponse;

fn pullSidebarForm(raw_ref: []const u8, csrf_token: []const u8) sidebar.FormContext {
    return .{
        .target = .pull,
        .raw_ref = raw_ref,
        .csrf_field = zwf.csrf.field_name,
        .csrf_token = csrf_token,
    };
}

pub fn append(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    repo: Repo,
    db: *SqliteDb,
    detail: PullDetail,
    raw_ref: []const u8,
    csrf_token: []const u8,
) !void {
    try appendReviewers(buf, allocator, db, raw_ref, detail.id, csrf_token);
    try appendAssignees(buf, allocator, db, raw_ref, detail.id, csrf_token);
    try appendLabels(buf, allocator, db, raw_ref, detail.id, csrf_token);
    try appendDevelopment(buf, allocator, repo, db, detail, raw_ref);
    try appendNotifications(buf, allocator);
    try appendParticipants(buf, allocator, db, detail);
}

fn appendReviewers(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, raw_ref: []const u8, pull_id: []const u8, csrf_token: []const u8) !void {
    try sidebar.appendEditableSectionStart(buf, allocator, "Reviewers", "Manage reviewers");
    try appendPeopleMenu(buf, allocator, db, raw_ref, pull_id, csrf_token, .reviewer);
    try sidebar.appendEditableSectionBodyStart(buf, allocator);
    try sidebar.appendPeopleBody(buf, allocator, db, "SELECT DISTINCT reviewer FROM pull_reviewers WHERE pull_id = ? ORDER BY reviewer", pull_id, "No reviewers");
    try sidebar.appendSectionEnd(buf, allocator);
}

fn appendAssignees(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, raw_ref: []const u8, pull_id: []const u8, csrf_token: []const u8) !void {
    try sidebar.appendEditableSectionStart(buf, allocator, "Assignees", "Manage assignees");
    try appendPeopleMenu(buf, allocator, db, raw_ref, pull_id, csrf_token, .assignee);
    try sidebar.appendEditableSectionBodyStart(buf, allocator);
    try sidebar.appendPeopleBody(buf, allocator, db, "SELECT DISTINCT assignee FROM pull_assignees WHERE pull_id = ? ORDER BY assignee", pull_id, "No one assigned");
    try sidebar.appendSectionEnd(buf, allocator);
}

const PeopleKind = enum {
    assignee,
    reviewer,

    fn noun(self: PeopleKind) []const u8 {
        return switch (self) {
            .assignee => "assignee",
            .reviewer => "reviewer",
        };
    }

    fn plural(self: PeopleKind) []const u8 {
        return switch (self) {
            .assignee => "assignees",
            .reviewer => "reviewers",
        };
    }

    fn addAction(self: PeopleKind) []const u8 {
        return switch (self) {
            .assignee => "add-assignee",
            .reviewer => "add-reviewer",
        };
    }

    fn removeAction(self: PeopleKind) []const u8 {
        return switch (self) {
            .assignee => "remove-assignee",
            .reviewer => "remove-reviewer",
        };
    }

    fn selectedSql(self: PeopleKind) []const u8 {
        return switch (self) {
            .assignee => "SELECT DISTINCT assignee FROM pull_assignees WHERE pull_id = ? ORDER BY lower(assignee), assignee",
            .reviewer => "SELECT DISTINCT reviewer FROM pull_reviewers WHERE pull_id = ? ORDER BY lower(reviewer), reviewer",
        };
    }

    fn selectedColumn(self: PeopleKind) []const u8 {
        return switch (self) {
            .assignee => "assignee",
            .reviewer => "reviewer",
        };
    }

    fn selectedTable(self: PeopleKind) []const u8 {
        return switch (self) {
            .assignee => "pull_assignees",
            .reviewer => "pull_reviewers",
        };
    }
};

fn appendPeopleMenu(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    raw_ref: []const u8,
    pull_id: []const u8,
    csrf_token: []const u8,
    kind: PeopleKind,
) !void {
    const add_label = try std.fmt.allocPrint(allocator, "Add {s}", .{kind.noun()});
    defer allocator.free(add_label);
    const filter_label = try std.fmt.allocPrint(allocator, "Filter {s}", .{kind.plural()});
    defer allocator.free(filter_label);
    try sidebar.appendSingleInputForm(buf, allocator, pullSidebarForm(raw_ref, csrf_token), kind.addAction(), "value", add_label, filter_label);

    try sidebar.appendMenuGroupStart(buf, allocator, if (kind == .reviewer) "Requested reviewers" else "Assigned");
    var selected = try db.prepare(kind.selectedSql());
    defer selected.deinit();
    try selected.bindText(1, pull_id);
    var shown = false;
    while (try selected.step()) {
        const person = try selected.columnTextDup(allocator, 0);
        defer allocator.free(person);
        try sidebar.appendPersonActionRow(buf, allocator, pullSidebarForm(raw_ref, csrf_token), kind.removeAction(), person, true);
        shown = true;
    }
    if (!shown) {
        const message = try std.fmt.allocPrint(allocator, "No {s} selected.", .{kind.plural()});
        defer allocator.free(message);
        try sidebar.appendMenuEmpty(buf, allocator, message);
    }
    try sidebar.appendMenuGroupEnd(buf, allocator);

    try sidebar.appendMenuGroupStart(buf, allocator, "Suggestions");
    try appendPeopleSuggestions(buf, allocator, db, raw_ref, pull_id, csrf_token, kind);
    try sidebar.appendMenuGroupEnd(buf, allocator);
}

fn appendPeopleSuggestions(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    raw_ref: []const u8,
    pull_id: []const u8,
    csrf_token: []const u8,
    kind: PeopleKind,
) !void {
    const sql_text = try std.fmt.allocPrint(allocator,
        \\SELECT DISTINCT person
        \\FROM (
        \\  SELECT assignee AS person FROM pull_assignees
        \\  UNION
        \\  SELECT reviewer AS person FROM pull_reviewers
        \\  UNION
        \\  SELECT COALESCE(NULLIF(pm.source_author, ''), NULLIF(sp.display_name, ''), p.author_principal) AS person
        \\  FROM pulls p
        \\  LEFT JOIN pull_metadata pm ON pm.pull_id = p.id
        \\  LEFT JOIN identities sp ON sp.id = pm.source_identity
        \\  UNION
        \\  SELECT COALESCE(NULLIF(im.source_author, ''), NULLIF(si.display_name, ''), i.author_principal) AS person
        \\  FROM issues i
        \\  LEFT JOIN issue_metadata im ON im.issue_id = i.id
        \\  LEFT JOIN identities si ON si.id = im.source_identity
        \\)
        \\WHERE person <> ''
        \\  AND person NOT IN (SELECT {s} FROM {s} WHERE pull_id = ?)
        \\ORDER BY lower(person), person
        \\LIMIT 20
    , .{ kind.selectedColumn(), kind.selectedTable() });
    defer allocator.free(sql_text);
    var suggestions = try db.prepare(sql_text);
    defer suggestions.deinit();
    try suggestions.bindText(1, pull_id);
    var shown = false;
    while (try suggestions.step()) {
        const person = try suggestions.columnTextDup(allocator, 0);
        defer allocator.free(person);
        try sidebar.appendPersonActionRow(buf, allocator, pullSidebarForm(raw_ref, csrf_token), kind.addAction(), person, false);
        shown = true;
    }
    if (!shown) {
        const message = try std.fmt.allocPrint(allocator, "No {s} suggestions.", .{kind.noun()});
        defer allocator.free(message);
        try sidebar.appendMenuEmpty(buf, allocator, message);
    }
}

fn appendLabels(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, raw_ref: []const u8, pull_id: []const u8, csrf_token: []const u8) !void {
    try sidebar.appendEditableSectionStart(buf, allocator, "Labels", "Manage labels");
    try appendLabelsMenu(buf, allocator, db, raw_ref, pull_id, csrf_token);
    try sidebar.appendEditableSectionBodyStart(buf, allocator);
    try sidebar.appendLabelsBody(buf, allocator, db,
        \\SELECT selected.label, COALESCE(ld.color, '')
        \\FROM (SELECT DISTINCT label FROM pull_labels WHERE pull_id = ?) AS selected
        \\LEFT JOIN label_definitions ld ON ld.name = selected.label
        \\ORDER BY CASE WHEN ld.id IS NULL THEN 1 ELSE 0 END,
        \\         ld.priority,
        \\         lower(selected.label),
        \\         selected.label
    , pull_id, "None yet");
    try sidebar.appendSectionEnd(buf, allocator);
}

fn appendLabelsMenu(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, raw_ref: []const u8, pull_id: []const u8, csrf_token: []const u8) !void {
    try sidebar.appendSingleInputForm(buf, allocator, pullSidebarForm(raw_ref, csrf_token), "add-label", "value", "Add label", "Filter labels");
    try sidebar.appendMenuGroupStart(buf, allocator, "Selected labels");
    var selected = try db.prepare(
        \\SELECT selected.label, COALESCE(ld.color, '')
        \\FROM (SELECT DISTINCT label FROM pull_labels WHERE pull_id = ?) AS selected
        \\LEFT JOIN label_definitions ld ON ld.name = selected.label
        \\ORDER BY CASE WHEN ld.id IS NULL THEN 1 ELSE 0 END,
        \\         ld.priority,
        \\         lower(selected.label),
        \\         selected.label
    );
    defer selected.deinit();
    try selected.bindText(1, pull_id);
    var shown = false;
    while (try selected.step()) {
        const label = try selected.columnTextDup(allocator, 0);
        defer allocator.free(label);
        const color = try selected.columnTextDup(allocator, 1);
        defer allocator.free(color);
        try sidebar.appendLabelTokenActionRow(buf, allocator, pullSidebarForm(raw_ref, csrf_token), "remove-label", label, color, true);
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
        \\WHERE label_names.label NOT IN (SELECT label FROM pull_labels WHERE pull_id = ?)
        \\ORDER BY CASE WHEN ld.id IS NULL THEN 1 ELSE 0 END,
        \\         ld.priority,
        \\         lower(label_names.label),
        \\         label_names.label
        \\LIMIT 24
    );
    defer suggestions.deinit();
    try suggestions.bindText(1, pull_id);
    shown = false;
    while (try suggestions.step()) {
        const label = try suggestions.columnTextDup(allocator, 0);
        defer allocator.free(label);
        const color = try suggestions.columnTextDup(allocator, 1);
        defer allocator.free(color);
        try sidebar.appendLabelTokenActionRow(buf, allocator, pullSidebarForm(raw_ref, csrf_token), "add-label", label, color, false);
        shown = true;
    }
    if (!shown) try sidebar.appendMenuEmpty(buf, allocator, "No label suggestions.");
    try sidebar.appendMenuGroupEnd(buf, allocator);
}

fn appendDevelopment(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, db: *SqliteDb, detail: PullDetail, raw_ref: []const u8) !void {
    try sidebar.appendEditableSectionStart(buf, allocator, "Development", "Open linked issue");
    try appendDevelopmentMenu(buf, allocator, db);
    try sidebar.appendEditableSectionBodyStart(buf, allocator);
    var links: std.ArrayList(development_links.DevelopmentLink) = .empty;
    defer development_links.freeLinks(allocator, &links);
    try development_links.collectForPull(allocator, db, detail.id, detail.body, &links);
    if (links.items.len == 0) {
        try sidebar.appendEmptyText(buf, allocator, "No linked issues.");
    } else {
        for (links.items) |link| try development_links.appendLinkRow(buf, allocator, link);
    }
    try buf.appendSlice(allocator, "<div class=\"pull-sidebar-branches\"><span><strong>Base</strong>");
    try appendPullBranchLink(buf, allocator, detail.base_ref);
    try buf.appendSlice(allocator, "</span><span><strong>Head</strong>");
    try appendPullBranchLink(buf, allocator, detail.head_ref);
    try buf.appendSlice(allocator, "</span></div>");
    if (detail.merge_oid.len != 0) {
        try appendTemplate(buf, allocator,
            \\<a class="issue-sidebar-link-row" href="{href}"><span class="issue-sidebar-row-kind">merge</span><code>{short_oid}</code><span class="issue-sidebar-row-title">Merge commit</span></a>
        , .{
            .href = commitHref(detail.merge_oid),
            .short_oid = detail.merge_oid[0..@min(detail.merge_oid.len, 12)],
        });
    }
    if (detail.target_oid.len != 0) {
        try appendTemplate(buf, allocator,
            \\<a class="issue-sidebar-link-row" href="{href}"><span class="issue-sidebar-row-kind">target</span><code>{short_oid}</code><span class="issue-sidebar-row-title">Target commit</span></a>
        , .{
            .href = commitHref(detail.target_oid),
            .short_oid = detail.target_oid[0..@min(detail.target_oid.len, 12)],
        });
    }
    if (detail.merge_oid.len != 0 or detail.target_oid.len != 0) {
        try buf.appendSlice(allocator, "<p class=\"pull-sidebar-note\">");
        try appendLocalMergeCheck(buf, allocator, repo, detail);
        try buf.appendSlice(allocator, "</p>");
    }
    try appendTemplate(buf, allocator, "<p class=\"pull-sidebar-note\"><a href=\"/pulls/{pull_ref}\">/pulls/{pull_ref}</a></p>", .{ .pull_ref = raw_ref });
    try sidebar.appendSectionEnd(buf, allocator);
}

fn appendDevelopmentMenu(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb) !void {
    try sidebar.appendMenuFilter(buf, allocator, "Search issues");
    try sidebar.appendMenuGroupStart(buf, allocator, "Open issues");
    var stmt = try db.prepare(
        \\SELECT i.id, i.title, COALESCE(a.number, 0)
        \\FROM issues i
        \\LEFT JOIN legacy_aliases a
        \\  ON a.provider = 'github' AND a.object_kind = 'issue' AND a.object_id = i.id
        \\WHERE i.state = 'open'
        \\ORDER BY i.opened_at DESC
        \\LIMIT 12
    );
    defer stmt.deinit();
    var shown = false;
    while (try stmt.step()) {
        const issue_id = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(issue_id);
        const title = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(title);
        const legacy_number = stmt.columnInt64(2);
        try appendIssueChoice(buf, allocator, issue_id, title, legacy_number);
        shown = true;
    }
    if (!shown) try sidebar.appendMenuEmpty(buf, allocator, "No open issues.");
    try sidebar.appendMenuGroupEnd(buf, allocator);
}

fn appendNotifications(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try sidebar.appendSectionStart(buf, allocator, "Notifications");
    try buf.appendSlice(allocator,
        \\<button class="button secondary issue-sidebar-full-button" type="button" disabled>Subscribe</button>
    );
    try sidebar.appendSectionEnd(buf, allocator);
}

fn appendParticipants(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, detail: PullDetail) !void {
    try sidebar.appendSectionStart(buf, allocator, "Participants");
    try buf.appendSlice(allocator, "<div class=\"issue-participants\">");
    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var keys = seen.keyIterator();
        while (keys.next()) |key| allocator.free(key.*);
        seen.deinit();
    }
    try appendParticipant(buf, allocator, &seen, detail.displayAuthor());
    try appendParticipantQuery(buf, allocator, db, &seen, "SELECT DISTINCT assignee FROM pull_assignees WHERE pull_id = ? ORDER BY assignee", detail.id);
    try appendParticipantQuery(buf, allocator, db, &seen, "SELECT DISTINCT reviewer FROM pull_reviewers WHERE pull_id = ? ORDER BY reviewer", detail.id);
    try buf.appendSlice(allocator, "</div>");
    try sidebar.appendSectionEnd(buf, allocator);
}

fn appendParticipantQuery(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    seen: *std.StringHashMap(void),
    comptime sql_text: []const u8,
    pull_id: []const u8,
) !void {
    var stmt = try db.prepare(sql_text);
    defer stmt.deinit();
    try stmt.bindText(1, pull_id);
    while (try stmt.step()) {
        const person = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(person);
        try appendParticipant(buf, allocator, seen, person);
    }
}

fn appendParticipant(buf: *std.ArrayList(u8), allocator: Allocator, seen: *std.StringHashMap(void), person: []const u8) !void {
    if (person.len == 0 or seen.contains(person)) return;
    const key = try allocator.dupe(u8, person);
    errdefer allocator.free(key);
    try seen.put(key, {});
    try sidebar.appendAvatar(buf, allocator, person, "");
}

fn appendIssueChoice(buf: *std.ArrayList(u8), allocator: Allocator, issue_id: []const u8, title: []const u8, legacy_number: i64) !void {
    var issue_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const issue_ref = util.shortObjectRef(&issue_ref_buf, issue_id);
    const number_text = try numberText(allocator, issue_ref, legacy_number);
    defer allocator.free(number_text);

    try buf.appendSlice(allocator, "<a class=\"issue-sidebar-picker-row issue-sidebar-link-choice\" href=\"");
    try shared.appendHref(buf, allocator, issueHref(if (legacy_number > 0) number_text[1..] else issue_ref));
    try appendTemplate(buf, allocator,
        \\" data-sidebar-filter-text="{title} {number_text}"><span class="issue-sidebar-picker-check" aria-hidden="true"></span><span class="issue-sidebar-issue-icon is-open" aria-hidden="true"></span><span class="issue-sidebar-picker-text"><span class="issue-sidebar-picker-primary">{title}</span><span class="issue-sidebar-picker-secondary">{number_text}</span></span></a>
    , .{
        .title = title,
        .number_text = number_text,
    });
}

fn numberText(allocator: Allocator, short_ref: []const u8, legacy_number: i64) ![]u8 {
    if (legacy_number > 0) return try std.fmt.allocPrint(allocator, "#{d}", .{legacy_number});
    return try std.fmt.allocPrint(allocator, "#{s}", .{short_ref});
}

fn appendPullBranchLink(buf: *std.ArrayList(u8), allocator: Allocator, ref: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<a class="pull-branch-link" href="{href}"><code>{ref}</code></a>
    , .{
        .href = shared.codeHref(ref, ""),
        .ref = ref,
    });
}

fn appendLocalMergeCheck(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, detail: PullDetail) !void {
    const oid = if (detail.target_oid.len != 0) detail.target_oid else detail.merge_oid;
    const status = try localContainsOid(allocator, repo, oid, detail.base_ref);
    if (status) |contains| {
        try buf.appendSlice(allocator, if (contains) "Confirmed in base ref" else "Not confirmed in base ref");
    } else {
        try buf.appendSlice(allocator, "Unavailable");
    }
}

fn localContainsOid(allocator: Allocator, repo: Repo, oid: []const u8, base_ref: []const u8) !?bool {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "git", "-C", repo.root, "merge-base", "--is-ancestor", oid, base_ref });
    var result = try runCommand(allocator, argv.items, null, 1024 * 1024);
    defer result.deinit();
    if (result.exitCode()) |code| {
        if (code == 0) return true;
        if (code == 1) return false;
    }
    return null;
}

pub fn handlePullSidebarPost(allocator: Allocator, repo: Repo, stream: @import("compat").net.Stream, raw_ref: []const u8, csrf_token: []const u8, form_body: []const u8) !void {
    const submitted_csrf = (try shared.formValueOwned(allocator, form_body, zwf.csrf.field_name)) orelse {
        try sendPlainResponse(allocator, stream, 403, "Forbidden", "Invalid CSRF token\n");
        return;
    };
    defer allocator.free(submitted_csrf);
    if (!zwf.csrf.verify(csrf_token, std.mem.trim(u8, submitted_csrf, " \t\r\n"))) {
        try sendPlainResponse(allocator, stream, 403, "Forbidden", "Invalid CSRF token\n");
        return;
    }

    try index.ensureIndex(allocator, repo);
    const pull_id = index.resolvePullId(allocator, repo, raw_ref) catch {
        try sendPlainResponse(allocator, stream, 404, "Not Found", "Pull request not found\n");
        return;
    };
    defer allocator.free(pull_id);

    const action_owned = (try shared.formValueOwned(allocator, form_body, "action")) orelse {
        try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Missing sidebar action\n");
        return;
    };
    defer allocator.free(action_owned);
    const action = std.mem.trim(u8, action_owned, " \t\r\n");

    if (std.mem.eql(u8, action, "add-label") or std.mem.eql(u8, action, "remove-label")) {
        const value_owned = try sidebar.requiredValue(allocator, stream, form_body, "value", "Label is required.");
        const value = value_owned orelse return;
        defer allocator.free(value);
        const event_type: []const u8 = if (std.mem.eql(u8, action, "add-label")) "pull.label_added" else "pull.label_removed";
        if (!(try writePullSidebarStringEventOrFail(allocator, stream, pull_id, event_type, "label", value))) return;
    } else if (std.mem.eql(u8, action, "add-assignee") or std.mem.eql(u8, action, "remove-assignee")) {
        const value_owned = try sidebar.requiredValue(allocator, stream, form_body, "value", "Assignee is required.");
        const value = value_owned orelse return;
        defer allocator.free(value);
        const event_type: []const u8 = if (std.mem.eql(u8, action, "add-assignee")) "pull.assignee_added" else "pull.assignee_removed";
        if (!(try writePullSidebarStringEventOrFail(allocator, stream, pull_id, event_type, "assignee", value))) return;
    } else if (std.mem.eql(u8, action, "add-reviewer") or std.mem.eql(u8, action, "remove-reviewer")) {
        const value_owned = try sidebar.requiredValue(allocator, stream, form_body, "value", "Reviewer is required.");
        const value = value_owned orelse return;
        defer allocator.free(value);
        const event_type: []const u8 = if (std.mem.eql(u8, action, "add-reviewer")) "pull.reviewer_added" else "pull.reviewer_removed";
        if (!(try writePullSidebarStringEventOrFail(allocator, stream, pull_id, event_type, "reviewer", value))) return;
    } else {
        try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Unknown sidebar action\n");
        return;
    }

    const location = try std.fmt.allocPrint(allocator, "/pulls/{s}", .{raw_ref});
    defer allocator.free(location);
    try shared.sendRedirect(allocator, stream, location);
}

fn writePullSidebarStringEventOrFail(
    allocator: Allocator,
    stream: @import("compat").net.Stream,
    pull_id: []const u8,
    event_type: []const u8,
    payload_key: []const u8,
    payload_value: []const u8,
) !bool {
    pr.createPullStringEvent(allocator, pull_id, event_type, payload_key, payload_value) catch {
        try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not update pull request metadata\n");
        return false;
    };
    return true;
}
