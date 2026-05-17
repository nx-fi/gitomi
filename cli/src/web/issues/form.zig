const std = @import("std");
const issue = @import("../../issue.zig");
const repo_mod = @import("../../repo.zig");
const shared = @import("../shared.zig");
const util = @import("../../util.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const appendSectionHead = shared.appendSectionHead;
const appendShellEnd = shared.appendShellEnd;
const appendShellStart = shared.appendShellStart;
const appendTemplate = shared.appendTemplate;
const createIssueOpenedEvent = issue.createIssueOpenedEvent;
const sendRedirect = shared.sendRedirect;
const sendResponse = shared.sendResponse;
const splitCommaFields = util.splitCommaFields;

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
    try buf.appendSlice(allocator, "<section class=\"panel form-panel\">");
    try appendSectionHead(&buf, allocator, "Issues", "New Issue", null);
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

pub fn renderIssueFormFromTarget(allocator: Allocator, repo: Repo, target: []const u8) ![]u8 {
    const title = try queryValueOwned(allocator, target, "title");
    defer if (title) |value| allocator.free(value);
    const body = try queryValueOwned(allocator, target, "body");
    defer if (body) |value| allocator.free(value);
    const labels = try queryValueOwned(allocator, target, "labels");
    defer if (labels) |value| allocator.free(value);
    const assignees = try queryValueOwned(allocator, target, "assignees");
    defer if (assignees) |value| allocator.free(value);

    return renderIssueForm(
        allocator,
        repo,
        null,
        title orelse "",
        body orelse "",
        labels orelse "",
        assignees orelse "",
    );
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

pub fn queryValueOwned(allocator: Allocator, target: []const u8, wanted_key: []const u8) !?[]u8 {
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var pairs = std.mem.splitScalar(u8, target[query_start + 1 ..], '&');
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
