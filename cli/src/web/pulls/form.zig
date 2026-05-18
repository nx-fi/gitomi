const std = @import("std");
const issues_page = @import("../issues.zig");
const pull = @import("../../pr.zig");
const repo_mod = @import("../../repo.zig");
const shared = @import("../shared.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const appendSectionHead = shared.appendSectionHead;
const appendShellEnd = shared.appendShellEnd;
const appendShellStart = shared.appendShellStart;
const appendTemplate = shared.appendTemplate;
const sendPlainResponse = shared.sendPlainResponse;
const sendRedirect = shared.sendRedirect;
const sendResponse = shared.sendResponse;

pub fn renderPullForm(
    allocator: Allocator,
    repo: Repo,
    csrf_token: []const u8,
    error_message: ?[]const u8,
    title_value: []const u8,
    body_value: []const u8,
    base_value: []const u8,
    head_value: []const u8,
    draft: bool,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "New Pull Request", "pulls");
    try buf.appendSlice(allocator, "<section class=\"panel form-panel\">");
    try appendSectionHead(&buf, allocator, "Pull requests", "New Pull Request", null);
    if (error_message) |message| {
        try appendTemplate(&buf, allocator, "<div class=\"flash error\">{message}</div>", .{ .message = message });
    }
    try appendTemplate(&buf, allocator,
        \\  <form method="post" action="/pulls" class="issue-form">
        \\    <input type="hidden" name="csrf_token" value="{csrf_token}">
        \\    <label>Title<input name="title" value="{title_value}" autofocus required></label>
        \\    <label>Body</label>
    , .{
        .csrf_token = csrf_token,
        .title_value = title_value,
    });
    try shared.appendMarkdownEditor(&buf, allocator, .{
        .rows = 8,
        .placeholder = "Describe the pull request",
        .value = body_value,
        .required = false,
    });
    try appendTemplate(&buf, allocator,
        \\    <div class="grid two">
        \\      <label>Base ref<input name="base" value="{base_value}" placeholder="main" required></label>
        \\      <label>Head ref<input name="head" value="{head_value}" placeholder="feature-branch" required></label>
        \\    </div>
        \\    <label class="checkbox-label"><input type="checkbox" name="draft" value="1"{draft_checked}> Draft</label>
        \\    <div class="form-actions">
        \\      <a class="button secondary" href="/pulls">Cancel</a>
        \\      <button class="button primary" type="submit">Create pull request</button>
        \\    </div>
        \\  </form>
        \\</section>
    , .{
        .base_value = base_value,
        .head_value = head_value,
        .draft_checked = if (draft) " checked" else "",
    });
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

pub fn handlePullPost(allocator: Allocator, repo: Repo, stream: std.net.Stream, csrf_token: []const u8, form_body: []const u8) !void {
    const submitted_token = try issues_page.formValueOwned(allocator, form_body, "csrf_token");
    defer if (submitted_token) |value| allocator.free(value);
    if (submitted_token == null or !std.mem.eql(u8, submitted_token.?, csrf_token)) {
        try sendPlainResponse(allocator, stream, 403, "Forbidden", "Invalid CSRF token\n");
        return;
    }

    const title_owned = (try issues_page.formValueOwned(allocator, form_body, "title")) orelse try allocator.dupe(u8, "");
    defer allocator.free(title_owned);
    const body_owned = (try issues_page.formValueOwned(allocator, form_body, "body")) orelse try allocator.dupe(u8, "");
    defer allocator.free(body_owned);
    const base_owned = (try issues_page.formValueOwned(allocator, form_body, "base")) orelse try allocator.dupe(u8, "");
    defer allocator.free(base_owned);
    const head_owned = (try issues_page.formValueOwned(allocator, form_body, "head")) orelse try allocator.dupe(u8, "");
    defer allocator.free(head_owned);
    const draft_value = try issues_page.formValueOwned(allocator, form_body, "draft");
    defer if (draft_value) |value| allocator.free(value);
    const draft = draft_value != null;

    const title = std.mem.trim(u8, title_owned, " \t\r\n");
    const base_ref = std.mem.trim(u8, base_owned, " \t\r\n");
    const head_ref = std.mem.trim(u8, head_owned, " \t\r\n");
    if (title.len == 0 or base_ref.len == 0 or head_ref.len == 0) {
        const body = try renderPullForm(
            allocator,
            repo,
            csrf_token,
            "Title, base ref, and head ref are required.",
            title_owned,
            body_owned,
            base_owned,
            head_owned,
            draft,
        );
        defer allocator.free(body);
        try sendResponse(allocator, stream, 422, "Unprocessable Entity", "text/html", body, null);
        return;
    }

    pull.createPullOpenedEvent(allocator, title, body_owned, base_ref, head_ref, draft) catch |err| {
        const message = shared.writeFailureMessage(err, "Could not create the pull request. Check that Gitomi is initialized and Git commit signing is configured.");
        const body = try renderPullForm(
            allocator,
            repo,
            csrf_token,
            message,
            title_owned,
            body_owned,
            base_owned,
            head_owned,
            draft,
        );
        defer allocator.free(body);
        try sendResponse(allocator, stream, shared.writeFailureStatus(err), shared.writeFailureReason(err), "text/html", body, null);
        return;
    };

    try sendRedirect(allocator, stream, "/pulls");
}
