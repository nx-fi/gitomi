const std = @import("std");
const index = @import("../index.zig");
const issue = @import("../issue.zig");
const repo_mod = @import("../repo.zig");
const shared = @import("shared.zig");
const util = @import("../util.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const SqliteDb = index.SqliteDb;
const appendEmptyState = shared.appendEmptyState;
const appendHtml = shared.appendHtml;
const appendShellEnd = shared.appendShellEnd;
const appendShellStart = shared.appendShellStart;
const createIssueOpenedEvent = issue.createIssueOpenedEvent;
const ensureIndex = index.ensureIndex;
const sendRedirect = shared.sendRedirect;
const sendResponse = shared.sendResponse;
const splitCommaFields = util.splitCommaFields;
const sqlite = index.sqlite;

pub fn renderIssuesPage(allocator: Allocator, repo: Repo) ![]u8 {
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

    try ensureIndex(allocator, repo);
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var stmt = try db.prepare("SELECT id, title, state, author_principal, opened_at FROM issues ORDER BY opened_at DESC, id DESC");
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

        try buf.appendSlice(allocator, "<article class=\"issue-row\"><div class=\"issue-main\"><div class=\"issue-title\"><span class=\"state ");
        try appendHtml(&buf, allocator, state);
        try buf.appendSlice(allocator, "\">");
        try appendHtml(&buf, allocator, state);
        try buf.appendSlice(allocator, "</span><a href=\"/events#");
        try appendHtml(&buf, allocator, id[0..@min(id.len, 7)]);
        try buf.appendSlice(allocator, "\">");
        try appendHtml(&buf, allocator, title);
        try buf.appendSlice(allocator, "</a></div><p class=\"muted\">#");
        try appendHtml(&buf, allocator, id[0..@min(id.len, 7)]);
        try buf.appendSlice(allocator, " opened by ");
        try appendHtml(&buf, allocator, author);
        try buf.appendSlice(allocator, " at ");
        try appendHtml(&buf, allocator, opened_at);
        try buf.appendSlice(allocator, "</p></div></article>");
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
        try buf.appendSlice(allocator, "<div class=\"flash error\">");
        try appendHtml(&buf, allocator, message);
        try buf.appendSlice(allocator, "</div>");
    }
    try buf.appendSlice(allocator,
        \\  <form method="post" action="/issues" class="issue-form">
        \\    <label>Title<input name="title" value="
    );
    try appendHtml(&buf, allocator, title_value);
    try buf.appendSlice(allocator,
        \\" autofocus required></label>
        \\    <label>Body<textarea name="body" rows="8">
    );
    try appendHtml(&buf, allocator, body_value);
    try buf.appendSlice(allocator,
        \\</textarea></label>
        \\    <div class="grid two">
        \\      <label>Labels<input name="labels" value="
    );
    try appendHtml(&buf, allocator, labels_value);
    try buf.appendSlice(allocator,
        \\" placeholder="bug, docs"></label>
        \\      <label>Assignees<input name="assignees" value="
    );
    try appendHtml(&buf, allocator, assignees_value);
    try buf.appendSlice(allocator,
        \\" placeholder="alice, bob"></label>
        \\    </div>
        \\    <div class="form-actions">
        \\      <a class="button secondary" href="/issues">Cancel</a>
        \\      <button class="button primary" type="submit">Create issue</button>
        \\    </div>
        \\  </form>
        \\</section>
    );
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
