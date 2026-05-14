const std = @import("std");
const index = @import("../index.zig");
const issue = @import("../issue.zig");
const markdown_render = @import("markdown_render.zig");
const repo_mod = @import("../repo.zig");
const shared = @import("shared.zig");
const util = @import("../util.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const SqliteDb = index.SqliteDb;
const appendEmptyState = shared.appendEmptyState;
const appendShellEnd = shared.appendShellEnd;
const appendShellStart = shared.appendShellStart;
const appendTemplate = shared.appendTemplate;
const createIssueOpenedEvent = issue.createIssueOpenedEvent;
const ensureIndex = index.ensureIndex;
const sendRedirect = shared.sendRedirect;
const sendResponse = shared.sendResponse;
const splitCommaFields = util.splitCommaFields;
const sqlite = index.sqlite;
const trustedHtml = shared.trustedHtml;

pub fn renderIssuesPage(allocator: Allocator, repo: Repo) ![]u8 {
    if (try shared.renderIndexingPageIfStale(allocator, repo, "Issues", "issues", "/issues")) |body| return body;
    try ensureIndex(allocator, repo);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "Issues", "issues");
    try buf.appendSlice(allocator,
        \\<section class="panel">
        \\  <div class="section-head">
        \\    <div>
        \\      <p class="eyebrow">Issues</p>
        \\      <h1>Local Issue Tracker</h1>
        \\    </div>
        \\    <a class="button primary" href="/new-issue">New issue</a>
        \\  </div>
        \\  <div class="list">
    );

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var stmt = try db.prepare(
        \\SELECT i.id, i.title, i.state,
        \\       COALESCE(NULLIF(m.source_author, ''), i.author_principal),
        \\       i.opened_at
        \\FROM issues i
        \\LEFT JOIN issue_metadata m ON m.issue_id = i.id
        \\ORDER BY i.opened_at DESC, i.id DESC
    );
    defer stmt.deinit();

    var shown: usize = 0;
    while (try stmt.step()) {
        const id = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(id);
        const title = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(title);
        const state = try stmt.columnTextDup(allocator, 2);
        defer allocator.free(state);
        const author = try stmt.columnTextDup(allocator, 3);
        defer allocator.free(author);
        const opened_at = try stmt.columnTextDup(allocator, 4);
        defer allocator.free(opened_at);

        const short_id = id[0..@min(id.len, 7)];
        try appendTemplate(&buf, allocator,
            \\<article class="issue-row"><div class="issue-main"><div class="issue-title"><span class="state {state}">{state}</span><a href="/issues/{id}">{title}</a></div><p class="muted">#{id} opened by {author} at {opened_at}</p></div></article>
        , .{
            .state = state,
            .id = short_id,
            .title = title,
            .author = author,
            .opened_at = opened_at,
        });
        shown += 1;
    }

    if (shown == 0) {
        try appendEmptyState(&buf, allocator, "No issues yet.", "Create the first local issue from this browser UI or with gt issue open.");
    }

    try buf.appendSlice(allocator,
        \\  </div>
        \\</section>
    );
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

pub fn renderIssueDetailPage(allocator: Allocator, repo: Repo, raw_ref: []const u8) ![]u8 {
    const return_target = try std.fmt.allocPrint(allocator, "/issues/{s}", .{raw_ref});
    defer allocator.free(return_target);
    if (try shared.renderIndexingPageIfStale(allocator, repo, "Issue", "issues", return_target)) |body| return body;
    try ensureIndex(allocator, repo);
    const issue_id = index.resolveIssueId(allocator, repo, raw_ref) catch {
        return renderIssueNotFound(allocator, repo, raw_ref);
    };
    defer allocator.free(issue_id);

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    var stmt = try db.prepare(
        \\SELECT i.id, i.title, i.state, i.author_principal, i.author_device, i.opened_at, i.body,
        \\       COALESCE(m.source_author, ''), COALESCE(m.milestone, '')
        \\FROM issues i
        \\LEFT JOIN issue_metadata m ON m.issue_id = i.id
        \\WHERE i.id = ?
    );
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    if (!(try stmt.step())) return renderIssueNotFound(allocator, repo, raw_ref);

    const id = try stmt.columnTextDup(allocator, 0);
    defer allocator.free(id);
    const title = try stmt.columnTextDup(allocator, 1);
    defer allocator.free(title);
    const state = try stmt.columnTextDup(allocator, 2);
    defer allocator.free(state);
    const author_principal = try stmt.columnTextDup(allocator, 3);
    defer allocator.free(author_principal);
    const author_device = try stmt.columnTextDup(allocator, 4);
    defer allocator.free(author_device);
    const opened_at = try stmt.columnTextDup(allocator, 5);
    defer allocator.free(opened_at);
    const body = try stmt.columnTextDup(allocator, 6);
    defer allocator.free(body);
    const source_author = try stmt.columnTextDup(allocator, 7);
    defer allocator.free(source_author);
    const milestone = try stmt.columnTextDup(allocator, 8);
    defer allocator.free(milestone);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, title, "issues");
    try appendTemplate(&buf, allocator,
        \\<section class="panel issue-detail">
        \\  <div class="section-head issue-detail-head">
        \\    <div>
        \\      <p class="eyebrow">Issue</p>
        \\      <h1>{title}</h1>
        \\    </div>
        \\    <a class="button secondary" href="/issues">Back to issues</a>
        \\  </div>
        \\  <div class="issue-detail-body">
        \\    <aside class="issue-sidebar">
    , .{ .title = title });
    try appendIssueFacts(&buf, allocator, &db, id, state, author_principal, author_device, source_author, opened_at, milestone);
    try appendTemplate(&buf, allocator,
        \\    </aside>
        \\    <div class="issue-thread">
        \\      <article class="issue-card">
        \\        <div class="comment-meta"><strong>{author}</strong><span>{opened_at}</span></div>
        \\        <div class="markdown-body">
    , .{
        .author = if (source_author.len != 0) source_author else author_principal,
        .opened_at = opened_at,
    });
    if (body.len == 0) {
        try buf.appendSlice(allocator, "<p class=\"muted\">No description provided.</p>");
    } else {
        try markdown_render.appendMarkdown(&buf, allocator, body);
    }
    try buf.appendSlice(allocator,
        \\        </div>
        \\      </article>
    );
    try appendIssueComments(&buf, allocator, &db, id);
    try buf.appendSlice(allocator,
        \\    </div>
        \\  </div>
        \\</section>
    );
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn renderIssueNotFound(allocator: Allocator, repo: Repo, raw_ref: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try appendShellStart(&buf, allocator, repo, "Issue Not Found", "issues");
    const detail = try std.fmt.allocPrint(allocator, "No issue matches {s}.", .{raw_ref});
    defer allocator.free(detail);
    try appendEmptyState(&buf, allocator, "Issue not found.", detail);
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn appendIssueFacts(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    issue_id: []const u8,
    state: []const u8,
    author_principal: []const u8,
    author_device: []const u8,
    source_author: []const u8,
    opened_at: []const u8,
    milestone: []const u8,
) !void {
    try appendTemplate(buf, allocator,
        \\<dl class="facts issue-facts"><div><dt>Status</dt><dd><span class="state {state}">{state}</span></dd></div><div><dt>ID</dt><dd><code>{issue_id}</code></dd></div><div><dt>Opened</dt><dd>{opened_at}</dd></div><div><dt>Author</dt><dd>{author}
    , .{
        .state = state,
        .issue_id = issue_id,
        .opened_at = opened_at,
        .author = if (source_author.len != 0) source_author else author_principal,
    });
    if (source_author.len != 0) {
        try appendTemplate(buf, allocator,
            \\ <span class="muted">imported by {author_principal}/{author_device}</span>
        , .{
            .author_principal = author_principal,
            .author_device = author_device,
        });
    } else {
        try appendTemplate(buf, allocator, "/{author_device}", .{ .author_device = author_device });
    }
    try buf.appendSlice(allocator, "</dd></div>");
    if (milestone.len != 0) {
        try appendTemplate(buf, allocator,
            \\<div><dt>Milestone</dt><dd>{milestone}</dd></div>
        , .{ .milestone = milestone });
    }
    try appendIssueCollectionFact(buf, allocator, db, "Labels", "SELECT DISTINCT label FROM issue_labels WHERE issue_id = ? ORDER BY label", issue_id);
    try appendIssueCollectionFact(buf, allocator, db, "Assignees", "SELECT DISTINCT assignee FROM issue_assignees WHERE issue_id = ? ORDER BY assignee", issue_id);
    try appendIssueProjectsFact(buf, allocator, db, issue_id);
    try buf.appendSlice(allocator, "</dl>");
}

fn appendIssueCollectionFact(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    label: []const u8,
    comptime sql_text: []const u8,
    issue_id: []const u8,
) !void {
    try appendTemplate(buf, allocator,
        \\<div><dt>{label}</dt><dd class="pill-list">
    , .{ .label = label });
    var stmt = try db.prepare(sql_text);
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    var shown = false;
    while (try stmt.step()) {
        const value = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(value);
        try appendTemplate(buf, allocator, "<span class=\"pill\">{value}</span>", .{ .value = value });
        shown = true;
    }
    if (!shown) try buf.appendSlice(allocator, "<span class=\"muted\">None</span>");
    try buf.appendSlice(allocator, "</dd></div>");
}

fn appendIssueProjectsFact(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, issue_id: []const u8) !void {
    var stmt = try db.prepare(
        \\SELECT DISTINCT project, column_name
        \\FROM issue_projects
        \\WHERE issue_id = ?
        \\ORDER BY project, column_name
    );
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    try buf.appendSlice(allocator, "<div><dt>Projects</dt><dd class=\"pill-list\">");
    var shown = false;
    while (try stmt.step()) {
        const project = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(project);
        const column = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(column);
        try appendTemplate(buf, allocator, "<span class=\"pill\">{project}", .{ .project = project });
        if (column.len != 0) {
            try appendTemplate(buf, allocator, " / {column}", .{ .column = column });
        }
        try buf.appendSlice(allocator, "</span>");
        shown = true;
    }
    if (!shown) try buf.appendSlice(allocator, "<span class=\"muted\">None</span>");
    try buf.appendSlice(allocator, "</dd></div>");
}

fn appendIssueComments(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, issue_id: []const u8) !void {
    var stmt = try db.prepare(
        \\SELECT id, body, redacted, COALESCE(NULLIF(source_author, ''), author_principal), created_at, reply_parent_id, reply_parent_hash
        \\FROM comments
        \\WHERE parent_kind = 'issue' AND parent_id = ?
        \\ORDER BY created_at, id
    );
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    var shown = false;
    while (try stmt.step()) {
        const id = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(id);
        const body = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(body);
        const redacted = stmt.columnInt(2) != 0;
        const author = try stmt.columnTextDup(allocator, 3);
        defer allocator.free(author);
        const created_at = try stmt.columnTextDup(allocator, 4);
        defer allocator.free(created_at);
        const reply_parent_id = try stmt.columnTextDup(allocator, 5);
        defer allocator.free(reply_parent_id);
        const reply_parent_hash = try stmt.columnTextDup(allocator, 6);
        defer allocator.free(reply_parent_hash);

        try appendTemplate(buf, allocator,
            \\<article class="issue-card comment-card{reply_class}"><div class="comment-meta"><strong>{author}</strong><span>{created_at}</span></div>
        , .{
            .reply_class = trustedHtml(if (reply_parent_id.len != 0 or reply_parent_hash.len != 0) " is-reply" else ""),
            .author = author,
            .created_at = created_at,
        });
        if (reply_parent_id.len != 0 or reply_parent_hash.len != 0) {
            try buf.appendSlice(allocator, "<p class=\"reply-note\">Reply to ");
            if (reply_parent_id.len != 0) {
                try appendTemplate(buf, allocator, "#{reply_parent_id}", .{
                    .reply_parent_id = reply_parent_id[0..@min(reply_parent_id.len, 7)],
                });
            } else {
                try appendTemplate(buf, allocator, "{reply_parent_hash}", .{
                    .reply_parent_hash = reply_parent_hash[0..@min(reply_parent_hash.len, 12)],
                });
            }
            try buf.appendSlice(allocator, "</p>");
        }
        try buf.appendSlice(allocator, "<div class=\"markdown-body\">");
        if (redacted) {
            try buf.appendSlice(allocator, "<p class=\"muted\">Comment redacted.</p>");
        } else {
            try markdown_render.appendMarkdown(buf, allocator, body);
        }
        try buf.appendSlice(allocator, "</div></article>");
        shown = true;
    }
    if (!shown) {
        try buf.appendSlice(allocator, "<div class=\"empty inline-empty\"><strong>No comments yet.</strong></div>");
    }
}

pub fn renderIssueForm(
    allocator: Allocator,
    repo: Repo,
    error_message: ?[]const u8,
    title_value: []const u8,
    body_value: []const u8,
    labels_value: []const u8,
    assignees_value: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "New Issue", "issues");
    try buf.appendSlice(allocator,
        \\<section class="panel form-panel">
        \\  <div class="section-head">
        \\    <div>
        \\      <p class="eyebrow">Issues</p>
        \\      <h1>New Issue</h1>
        \\    </div>
        \\  </div>
    );
    if (error_message) |message| {
        try appendTemplate(&buf, allocator,
            \\<div class="flash error">{message}</div>
        , .{ .message = message });
    }
    try appendTemplate(&buf, allocator,
        \\  <form method="post" action="/issues" class="issue-form">
        \\    <label>Title<input name="title" value="{title_value}" autofocus required></label>
        \\    <label>Body<textarea name="body" rows="8">{body_value}</textarea></label>
        \\    <div class="grid two">
        \\      <label>Labels<input name="labels" value="{labels_value}" placeholder="bug, docs"></label>
        \\      <label>Assignees<input name="assignees" value="{assignees_value}" placeholder="alice, bob"></label>
        \\    </div>
        \\    <div class="form-actions">
        \\      <a class="button secondary" href="/issues">Cancel</a>
        \\      <button class="button primary" type="submit">Create issue</button>
        \\    </div>
        \\  </form>
        \\</section>
    , .{
        .title_value = title_value,
        .body_value = body_value,
        .labels_value = labels_value,
        .assignees_value = assignees_value,
    });
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

pub fn handleIssuePost(allocator: Allocator, repo: Repo, stream: std.net.Stream, form_body: []const u8) !void {
    const title_owned = (try formValueOwned(allocator, form_body, "title")) orelse try allocator.dupe(u8, "");
    defer allocator.free(title_owned);
    const body_owned = (try formValueOwned(allocator, form_body, "body")) orelse try allocator.dupe(u8, "");
    defer allocator.free(body_owned);
    const labels_owned = (try formValueOwned(allocator, form_body, "labels")) orelse try allocator.dupe(u8, "");
    defer allocator.free(labels_owned);
    const assignees_owned = (try formValueOwned(allocator, form_body, "assignees")) orelse try allocator.dupe(u8, "");
    defer allocator.free(assignees_owned);

    const title = std.mem.trim(u8, title_owned, " \t\r\n");
    if (title.len == 0) {
        const body = try renderIssueForm(allocator, repo, "Title is required.", title_owned, body_owned, labels_owned, assignees_owned);
        defer allocator.free(body);
        try sendResponse(allocator, stream, 422, "Unprocessable Entity", "text/html", body, null);
        return;
    }

    var labels = try splitCommaFields(allocator, labels_owned);
    defer labels.deinit(allocator);
    var assignees = try splitCommaFields(allocator, assignees_owned);
    defer assignees.deinit(allocator);

    createIssueOpenedEvent(allocator, title, body_owned, labels.items, assignees.items) catch {
        const body = try renderIssueForm(
            allocator,
            repo,
            "Could not create the issue. Check that Gitomi is initialized and Git commit signing is configured.",
            title_owned,
            body_owned,
            labels_owned,
            assignees_owned,
        );
        defer allocator.free(body);
        try sendResponse(allocator, stream, 500, "Internal Server Error", "text/html", body, null);
        return;
    };

    try sendRedirect(allocator, stream, "/issues");
}

pub fn issueTitleFromSubject(subject: []const u8) []const u8 {
    const marker = " #";
    const marker_index = std.mem.indexOf(u8, subject, marker) orelse return subject;
    const after_marker = subject[marker_index + marker.len ..];
    const title_index = std.mem.indexOfScalar(u8, after_marker, ' ') orelse return subject;
    const title = std.mem.trim(u8, after_marker[title_index + 1 ..], " \t\r\n");
    return if (title.len == 0) subject else title;
}

pub fn formValueOwned(allocator: Allocator, body: []const u8, wanted_key: []const u8) !?[]u8 {
    var pairs = std.mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const raw_key = pair[0..eq];
        const raw_value = if (eq < pair.len) pair[eq + 1 ..] else "";
        const key = try percentDecodeForm(allocator, raw_key);
        defer allocator.free(key);
        if (!std.mem.eql(u8, key, wanted_key)) continue;
        return try percentDecodeForm(allocator, raw_value);
    }
    return null;
}

pub fn percentDecodeForm(allocator: Allocator, value: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        switch (value[i]) {
            '+' => try buf.append(allocator, ' '),
            '%' => {
                if (i + 2 >= value.len) return error.InvalidFormEncoding;
                const hi = hexValue(value[i + 1]) orelse return error.InvalidFormEncoding;
                const lo = hexValue(value[i + 2]) orelse return error.InvalidFormEncoding;
                try buf.append(allocator, (hi << 4) | lo);
                i += 2;
            },
            else => |c| try buf.append(allocator, c),
        }
    }

    return buf.toOwnedSlice(allocator);
}

pub fn hexValue(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

test "web form decoding handles spaces and escapes" {
    const decoded = try percentDecodeForm(std.testing.allocator, "hello+local%2Fworld%21");
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("hello local/world!", decoded);

    const value = (try formValueOwned(std.testing.allocator, "title=First+issue&labels=bug%2Cdocs", "labels")).?;
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("bug,docs", value);
}

test "web issue titles come from issue opened subjects" {
    try std.testing.expectEqualStrings("Indexed issue", issueTitleFromSubject("issue.opened #018f000 Indexed issue"));
    try std.testing.expectEqualStrings("custom subject", issueTitleFromSubject("custom subject"));
}
