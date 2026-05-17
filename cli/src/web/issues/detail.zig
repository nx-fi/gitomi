const std = @import("std");
const comment_mod = @import("../../comment.zig");
const event_mod = @import("../../event.zig");
const index = @import("../../index.zig");
const issue = @import("../../issue.zig");
const issue_form = @import("form.zig");
const issue_reactions = @import("reactions.zig");
const issue_sidebar = @import("sidebar.zig");
const issue_timeline = @import("timeline.zig");
const issues_list = @import("list.zig");
const reaction_mod = @import("../../reaction.zig");
const repo_mod = @import("../../repo.zig");
const shared = @import("../shared.zig");
const util = @import("../../util.zig");
const work_items = @import("../../work_items.zig");
const zwf = @import("../../zwf.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const SqliteDb = index.SqliteDb;
const appendEmptyState = shared.appendEmptyState;
const appendSectionHead = shared.appendSectionHead;
const appendShellEnd = shared.appendShellEnd;
const appendShellStart = shared.appendShellStart;
const appendRelativeTime = shared.appendRelativeTime;
const appendTemplate = shared.appendTemplate;
const createCommentAddedEvent = comment_mod.createCommentAddedEvent;
const createCommentBodySetEvent = comment_mod.createCommentBodySetEvent;
const createCommentReplyEvent = comment_mod.createCommentReplyEvent;
const createIssueStringEvent = issue.createIssueStringEvent;
const createIssueUpdatedEvent = issue.createIssueUpdatedEvent;
const createReactionEvent = reaction_mod.createReactionEvent;
const ensureIndex = index.ensureIndex;
const sendRedirect = shared.sendRedirect;
const sendPlainResponse = shared.sendPlainResponse;
const sendResponse = shared.sendResponse;
const sqlite = index.sqlite;

pub const renderIssuesPage = issues_list.renderIssuesPage;
const formValueOwned = issue_form.formValueOwned;
const queryValueOwned = issue_form.queryValueOwned;

pub fn renderIssueDetailPage(allocator: Allocator, repo: Repo, raw_ref: []const u8, csrf_token: []const u8) ![]u8 {
    return renderIssueDetailPageWithCommentForm(allocator, repo, raw_ref, csrf_token, null, "");
}

fn renderIssueDetailPageWithCommentForm(
    allocator: Allocator,
    repo: Repo,
    raw_ref: []const u8,
    csrf_token: []const u8,
    comment_error: ?[]const u8,
    comment_value: []const u8,
) ![]u8 {
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

    const detail = (try work_items.loadIssueDetail(allocator, &db, issue_id)) orelse return renderIssueNotFound(allocator, repo, raw_ref);
    defer detail.deinit(allocator);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const display_author = detail.displayAuthor();
    const current_actor = try shared.currentPrincipalOwned(allocator, repo);
    defer if (current_actor) |actor| allocator.free(actor);
    const current_role = if (current_actor) |actor| try index.effectiveWriteRoleForPrincipal(allocator, repo, actor) else null;
    defer if (current_role) |role| allocator.free(role);
    const can_edit_issue = currentActorCanEditAuthor(current_actor, current_role, detail.author_principal);
    const issue_edit_href = if (can_edit_issue) try issueEditHrefOwned(allocator, raw_ref, null) else "";
    defer if (can_edit_issue) allocator.free(issue_edit_href);

    try appendShellStart(&buf, allocator, repo, detail.title, "issues");
    try shared.appendDetailBackButton(&buf, allocator, shared.literalHref("/issues"), "Back to issues");
    try buf.appendSlice(allocator, "<section class=\"issue-page\">");
    try appendIssuePageHeader(&buf, allocator, raw_ref, detail.id, detail.title, detail.state, display_author, detail.opened_at, detail.state_occurred_at, detail.comment_count, detail.legacy_number, can_edit_issue);
    try appendTemplate(&buf, allocator,
        \\  <div class="issue-conversation-layout">
        \\    <div class="issue-conversation">
        \\      <div class="issue-timeline-item">
        \\        <div class="issue-timeline-avatar">
    , .{});
    try appendIssueAvatar(&buf, allocator, display_author, "issue-detail-avatar");
    try appendTemplate(&buf, allocator,
        \\        </div>
        \\        <article class="issue-comment-box" id="issue-description">
        \\          <header class="issue-comment-head">
        \\            <div><strong>{author}</strong><span>opened
    , .{
        .author = display_author,
    });
    try buf.append(allocator, ' ');
    try appendRelativeTime(&buf, allocator, detail.opened_at);
    try buf.appendSlice(allocator, "</span></div>");
    try appendIssueActionMenu(&buf, allocator, "issue-description", "", detail.body, detail.body.len != 0, issue_edit_href);
    try buf.appendSlice(allocator,
        \\          </header>
        \\          <div class="markdown-body"
    );
    if (can_edit_issue) {
        try buf.appendSlice(allocator, " data-checklist-owner=\"issue\" data-checklist-update-action=\"/issues/");
        try shared.appendUrlEncoded(&buf, allocator, raw_ref);
        try buf.appendSlice(allocator, "/checklist\" data-checklist-csrf=\"");
        try shared.appendHtml(&buf, allocator, csrf_token);
        try buf.append(allocator, '"');
    }
    try buf.appendSlice(allocator, ">");
    if (detail.body.len == 0) {
        try buf.appendSlice(allocator, "<p class=\"muted\">No description provided.</p>");
    } else {
        try shared.appendMarkdownSource(&buf, allocator, detail.body, .{});
    }
    try buf.appendSlice(allocator,
        \\          </div>
    );
    try issue_reactions.appendBar(&buf, allocator, &db, "issue", detail.id, raw_ref, "", current_actor, csrf_token);
    try buf.appendSlice(allocator,
        \\        </article>
        \\      </div>
    );
    try appendIssueComments(&buf, allocator, &db, raw_ref, detail.id, current_actor, current_role, csrf_token);
    try issue_timeline.append(&buf, allocator, &db, detail.id);
    try appendIssueCommentForm(&buf, allocator, raw_ref, detail.state, current_actor, csrf_token, comment_error, comment_value);
    try buf.appendSlice(allocator, "    </div><aside class=\"issue-meta-sidebar\">");
    try issue_sidebar.append(&buf, allocator, &db, raw_ref, detail.id, display_author, detail.milestone, detail.priority, detail.status, detail.body);
    try buf.appendSlice(allocator, "</aside></div></section>");
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn appendIssuePageHeader(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_ref: []const u8,
    issue_id: []const u8,
    title: []const u8,
    state: []const u8,
    author: []const u8,
    opened_at: []const u8,
    state_at: []const u8,
    comment_count: usize,
    legacy_number: i64,
    can_edit: bool,
) !void {
    try appendTemplate(buf, allocator,
        \\  <header class="issue-page-head">
        \\    <div class="issue-title-line">
        \\      <h1><span>{title}</span> <span class="issue-page-number">
    , .{ .title = title });
    try appendIssueDisplayRef(buf, allocator, issue_id, legacy_number);
    try appendTemplate(buf, allocator,
        \\</span></h1>
        \\      <div class="issue-page-actions">
    , .{});
    if (can_edit) {
        try buf.appendSlice(allocator, "        <a class=\"button secondary\" href=\"/issues/");
        try shared.appendUrlEncoded(buf, allocator, raw_ref);
        try buf.appendSlice(allocator, "/edit\">Edit</a>\n");
    } else {
        try buf.appendSlice(allocator, "        <button class=\"button secondary\" type=\"button\" disabled>Edit</button>\n");
    }
    try appendTemplate(buf, allocator,
        \\
        \\        <a class="button primary" href="/new-issue">New issue</a>
        \\        <button class="issue-copy-button" type="button" disabled aria-label="Copy issue link"><span class="button-icon icon-copy" aria-hidden="true"></span></button>
        \\      </div>
        \\    </div>
        \\    <div class="issue-status-line">
    , .{});
    try appendIssueStateBadge(buf, allocator, state);
    try appendTemplate(buf, allocator,
        \\      <span><strong>{author}</strong> opened this issue
    , .{
        .author = author,
    });
    try buf.append(allocator, ' ');
    try appendRelativeTime(buf, allocator, opened_at);
    if (std.mem.eql(u8, state, "closed")) {
        try buf.appendSlice(allocator, " and closed it ");
        try appendRelativeTime(buf, allocator, state_at);
    }
    try appendTemplate(buf, allocator,
        \\ · {comment_count} {comment_word}</span>
        \\    </div>
        \\  </header>
    , .{
        .comment_count = comment_count,
        .comment_word = commentWord(comment_count),
    });
}

fn appendIssueDisplayRef(buf: *std.ArrayList(u8), allocator: Allocator, issue_id: []const u8, legacy_number: i64) !void {
    try buf.append(allocator, '#');
    if (legacy_number > 0) {
        try std.fmt.format(buf.writer(allocator), "{d}", .{legacy_number});
        return;
    }

    var issue_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const issue_ref = util.shortObjectRef(&issue_ref_buf, issue_id);
    try shared.appendHtml(buf, allocator, issue_ref);
}

fn appendIssueStateBadge(buf: *std.ArrayList(u8), allocator: Allocator, state: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<span class="issue-state-badge is-{state}"><span class="issue-state-mark" aria-hidden="true"></span>{label}</span>
    , .{
        .state = state,
        .label = issueStateLabel(state),
    });
}

fn issueStateLabel(state: []const u8) []const u8 {
    if (std.mem.eql(u8, state, "open")) return "Open";
    if (std.mem.eql(u8, state, "closed")) return "Closed";
    return state;
}

fn commentWord(count: usize) []const u8 {
    return if (count == 1) "comment" else "comments";
}

fn appendIssueAvatar(buf: *std.ArrayList(u8), allocator: Allocator, name: []const u8, extra_class: []const u8) !void {
    try shared.appendAvatar(buf, allocator, name, extra_class);
}

fn renderIssueNotFound(allocator: Allocator, repo: Repo, raw_ref: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try appendShellStart(&buf, allocator, repo, "Issue Not Found", "issues");
    try shared.appendDetailBackButton(&buf, allocator, shared.literalHref("/issues"), "Back to issues");
    const detail = try std.fmt.allocPrint(allocator, "No issue matches {s}.", .{raw_ref});
    defer allocator.free(detail);
    try appendEmptyState(&buf, allocator, "Issue not found.", detail);
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

pub fn renderIssueEditPage(allocator: Allocator, repo: Repo, raw_ref: []const u8, target: []const u8) ![]u8 {
    const target_ref_owned = try queryValueOwned(allocator, target, "target");
    defer if (target_ref_owned) |value| allocator.free(value);
    const target_ref = if (target_ref_owned) |value| std.mem.trim(u8, value, " \t\r\n") else "issue";
    if (target_ref.len == 0 or std.mem.eql(u8, target_ref, "issue")) {
        return renderIssueEditIssuePage(allocator, repo, raw_ref, null, null, null);
    }
    return renderIssueEditCommentPage(allocator, repo, raw_ref, target_ref, null, null);
}

fn renderIssueEditIssuePage(
    allocator: Allocator,
    repo: Repo,
    raw_ref: []const u8,
    error_message: ?[]const u8,
    title_override: ?[]const u8,
    body_override: ?[]const u8,
) ![]u8 {
    try ensureIndex(allocator, repo);
    const issue_id = index.resolveIssueId(allocator, repo, raw_ref) catch {
        return renderIssueNotFound(allocator, repo, raw_ref);
    };
    defer allocator.free(issue_id);

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var stmt = try db.prepare("SELECT title, body, author_principal FROM issues WHERE id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    if (!(try stmt.step())) return renderIssueNotFound(allocator, repo, raw_ref);

    const title = try stmt.columnTextDup(allocator, 0);
    defer allocator.free(title);
    const body = try stmt.columnTextDup(allocator, 1);
    defer allocator.free(body);
    const author_principal = try stmt.columnTextDup(allocator, 2);
    defer allocator.free(author_principal);

    if (!(try currentActorCanEditInRepo(allocator, repo, author_principal))) {
        return renderIssueEditAccessDenied(allocator, repo, raw_ref, "Edit issue", "You do not have permission to edit this issue.");
    }

    return renderIssueEditIssueForm(
        allocator,
        repo,
        raw_ref,
        error_message,
        title_override orelse title,
        body_override orelse body,
    );
}

fn renderIssueEditIssueForm(
    allocator: Allocator,
    repo: Repo,
    raw_ref: []const u8,
    error_message: ?[]const u8,
    title_value: []const u8,
    body_value: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "Edit Issue", "issues");
    try buf.appendSlice(allocator, "<section class=\"panel form-panel\">");
    try appendSectionHead(&buf, allocator, "Issues", "Edit Issue", null);
    if (error_message) |message| {
        try appendTemplate(&buf, allocator, "<div class=\"flash error\">{message}</div>", .{ .message = message });
    }
    try buf.appendSlice(allocator, "<form method=\"post\" action=\"/issues/");
    try shared.appendUrlEncoded(&buf, allocator, raw_ref);
    try buf.appendSlice(allocator, "/edit\" class=\"issue-form\">");
    try appendTemplate(&buf, allocator,
        \\<input type="hidden" name="target_ref" value="issue">
        \\<label>Title<input name="title" value="{title_value}" autofocus required></label>
        \\<label>Body</label>
    , .{ .title_value = title_value });
    try shared.appendMarkdownEditor(&buf, allocator, .{
        .rows = 10,
        .placeholder = "Update issue description",
        .value = body_value,
        .required = false,
    });
    try buf.appendSlice(allocator, "<div class=\"form-actions\">");
    try appendIssueCancelLink(&buf, allocator, raw_ref, null);
    try buf.appendSlice(allocator, "<button class=\"button primary\" type=\"submit\">Save changes</button></div></form></section>");
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn renderIssueEditCommentPage(
    allocator: Allocator,
    repo: Repo,
    raw_ref: []const u8,
    target_ref: []const u8,
    error_message: ?[]const u8,
    body_override: ?[]const u8,
) ![]u8 {
    try ensureIndex(allocator, repo);
    const issue_id = index.resolveIssueId(allocator, repo, raw_ref) catch {
        return renderIssueNotFound(allocator, repo, raw_ref);
    };
    defer allocator.free(issue_id);
    const comment_id = index.resolveCommentId(allocator, repo, target_ref) catch {
        return renderIssueEditAccessDenied(allocator, repo, raw_ref, "Edit comment", "Comment not found.");
    };
    defer allocator.free(comment_id);
    var parent = try index.commentParentInfo(allocator, repo, comment_id);
    defer parent.deinit();
    if (!std.mem.eql(u8, parent.parent_kind, "issue") or !std.mem.eql(u8, parent.parent_id, issue_id)) {
        return renderIssueEditAccessDenied(allocator, repo, raw_ref, "Edit comment", "Comment is not in this issue.");
    }

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var stmt = try db.prepare("SELECT body, redacted, author_principal FROM comments WHERE id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, comment_id);
    if (!(try stmt.step())) return renderIssueEditAccessDenied(allocator, repo, raw_ref, "Edit comment", "Comment not found.");

    const body = try stmt.columnTextDup(allocator, 0);
    defer allocator.free(body);
    const redacted = stmt.columnInt(1) != 0;
    const author_principal = try stmt.columnTextDup(allocator, 2);
    defer allocator.free(author_principal);
    if (redacted or !(try currentActorCanEditInRepo(allocator, repo, author_principal))) {
        return renderIssueEditAccessDenied(allocator, repo, raw_ref, "Edit comment", "You do not have permission to edit this comment.");
    }

    var comment_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const comment_ref = util.shortObjectRef(&comment_ref_buf, comment_id);
    const comment_ref_value = try std.fmt.allocPrint(allocator, "comment:{s}", .{comment_ref});
    defer allocator.free(comment_ref_value);
    const anchor = try std.fmt.allocPrint(allocator, "comment-{s}", .{comment_ref});
    defer allocator.free(anchor);
    return renderIssueEditCommentForm(
        allocator,
        repo,
        raw_ref,
        comment_ref_value,
        anchor,
        error_message,
        body_override orelse body,
    );
}

fn renderIssueEditCommentForm(
    allocator: Allocator,
    repo: Repo,
    raw_ref: []const u8,
    target_ref: []const u8,
    anchor: []const u8,
    error_message: ?[]const u8,
    body_value: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "Edit Comment", "issues");
    try buf.appendSlice(allocator, "<section class=\"panel form-panel\">");
    try appendSectionHead(&buf, allocator, "Issues", "Edit Comment", null);
    if (error_message) |message| {
        try appendTemplate(&buf, allocator, "<div class=\"flash error\">{message}</div>", .{ .message = message });
    }
    try buf.appendSlice(allocator, "<form method=\"post\" action=\"/issues/");
    try shared.appendUrlEncoded(&buf, allocator, raw_ref);
    try buf.appendSlice(allocator, "/edit\" class=\"issue-form\">");
    try appendTemplate(&buf, allocator,
        \\<input type="hidden" name="target_ref" value="{target_ref}">
        \\<label>Comment</label>
    , .{ .target_ref = target_ref });
    try shared.appendMarkdownEditor(&buf, allocator, .{
        .rows = 10,
        .placeholder = "Update comment",
        .value = body_value,
        .required = false,
    });
    try buf.appendSlice(allocator, "<div class=\"form-actions\">");
    try appendIssueCancelLink(&buf, allocator, raw_ref, anchor);
    try buf.appendSlice(allocator, "<button class=\"button primary\" type=\"submit\">Save changes</button></div></form></section>");
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn renderIssueEditAccessDenied(allocator: Allocator, repo: Repo, raw_ref: []const u8, title: []const u8, message: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try appendShellStart(&buf, allocator, repo, title, "issues");
    try buf.appendSlice(allocator, "<section class=\"panel form-panel\">");
    try appendSectionHead(&buf, allocator, "Issues", title, null);
    try appendTemplate(&buf, allocator, "<div class=\"flash error\">{message}</div><div class=\"form-actions\">", .{ .message = message });
    try appendIssueCancelLink(&buf, allocator, raw_ref, null);
    try buf.appendSlice(allocator, "</div></section>");
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn appendIssueCancelLink(buf: *std.ArrayList(u8), allocator: Allocator, raw_ref: []const u8, anchor: ?[]const u8) !void {
    try buf.appendSlice(allocator, "<a class=\"button secondary\" href=\"/issues/");
    try shared.appendUrlEncoded(buf, allocator, raw_ref);
    if (anchor) |value| {
        try buf.append(allocator, '#');
        try shared.appendHtml(buf, allocator, value);
    }
    try buf.appendSlice(allocator, "\">Cancel</a>");
}

fn currentActorCanEditInRepo(allocator: Allocator, repo: Repo, author: []const u8) !bool {
    const current_actor = try shared.currentPrincipalOwned(allocator, repo);
    defer if (current_actor) |actor| allocator.free(actor);
    const current_role = if (current_actor) |actor| try index.effectiveWriteRoleForPrincipal(allocator, repo, actor) else null;
    defer if (current_role) |role| allocator.free(role);
    return currentActorCanEditAuthor(current_actor, current_role, author);
}

fn appendIssueComments(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    raw_ref: []const u8,
    issue_id: []const u8,
    current_actor: ?[]const u8,
    current_role: ?[]const u8,
    csrf_token: []const u8,
) !void {
    var stmt = try work_items.prepareCommentsStmt(db, "issue", issue_id);
    defer stmt.deinit();
    while (try stmt.step()) {
        const row = try work_items.commentRowFromStmt(allocator, &stmt);
        defer row.deinit(allocator);
        const anchor = try std.fmt.allocPrint(allocator, "comment-{s}", .{row.id[0..@min(row.id.len, 7)]});
        defer allocator.free(anchor);
        var comment_ref_buf: [util.short_object_ref_len]u8 = undefined;
        const comment_ref = util.shortObjectRef(&comment_ref_buf, row.id);
        const comment_ref_value = try std.fmt.allocPrint(allocator, "comment:{s}", .{comment_ref});
        defer allocator.free(comment_ref_value);
        const can_edit_comment = !row.redacted and currentActorCanEditAuthor(current_actor, current_role, row.author_principal);
        const comment_edit_href = if (can_edit_comment) try issueEditHrefOwned(allocator, raw_ref, comment_ref_value) else "";
        defer if (can_edit_comment) allocator.free(comment_edit_href);

        try appendTemplate(buf, allocator,
            \\<div class="{classes}" id="{anchor}"><div class="issue-timeline-avatar">
        , .{
            .classes = shared.classes("issue-timeline-item", &.{shared.class("is-reply", row.isReply())}),
            .anchor = anchor,
        });
        try appendIssueAvatar(buf, allocator, row.display_author, "issue-detail-avatar");
        try appendTemplate(buf, allocator,
            \\</div><article class="issue-comment-box"><header class="issue-comment-head"><div><strong>{author}</strong><span>commented
        , .{
            .author = row.display_author,
        });
        try buf.append(allocator, ' ');
        try appendRelativeTime(buf, allocator, row.created_at);
        try buf.appendSlice(allocator, "</span></div>");
        try appendIssueActionMenu(buf, allocator, anchor, comment_ref_value, row.body, !row.redacted and row.body.len != 0, comment_edit_href);
        try buf.appendSlice(allocator, "</header>");
        if (row.isReply()) {
            try buf.appendSlice(allocator, "<p class=\"reply-note\">Reply to ");
            if (row.reply_parent_id.len != 0) {
                try appendTemplate(buf, allocator, "#{reply_parent_id}", .{
                    .reply_parent_id = row.reply_parent_id[0..@min(row.reply_parent_id.len, 7)],
                });
            } else {
                try appendTemplate(buf, allocator, "{reply_parent_hash}", .{
                    .reply_parent_hash = row.reply_parent_hash[0..@min(row.reply_parent_hash.len, 12)],
                });
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
        try issue_reactions.appendBar(buf, allocator, db, "comment", row.id, raw_ref, comment_ref_value, current_actor, csrf_token);
        try buf.appendSlice(allocator, "</article></div>");
    }
}

pub fn appendIssueActionMenu(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    anchor: []const u8,
    reply_ref: []const u8,
    markdown: []const u8,
    markdown_available: bool,
    edit_href: []const u8,
) !void {
    try appendTemplate(buf, allocator,
        \\<details class="issue-action-menu" data-popover-menu data-issue-menu data-issue-anchor="{anchor}" data-issue-reply-ref="{reply_ref}" data-issue-edit-href="{edit_href}">
        \\  <summary class="issue-kebab-button" aria-label="Comment actions" title="Comment actions"></summary>
        \\  <template data-issue-markdown>{markdown}</template>
        \\  <div class="issue-action-popover" role="menu">
    , .{
        .anchor = anchor,
        .reply_ref = reply_ref,
        .edit_href = edit_href,
        .markdown = markdown,
    });
    try appendIssueActionMenuItem(buf, allocator, "copy-link", "issue-menu-icon-link", "Copy link", false);
    try appendIssueActionMenuItem(buf, allocator, "copy-markdown", "issue-menu-icon-markdown", "Copy Markdown", !markdown_available);
    try appendIssueActionMenuItem(buf, allocator, "quote-reply", "issue-menu-icon-quote", "Quote reply", !markdown_available);
    try buf.appendSlice(allocator, "<div class=\"issue-action-divider\" role=\"separator\"></div>");
    try appendIssueActionMenuItem(buf, allocator, "edit", "issue-menu-icon-edit", "Edit", edit_href.len == 0);
    try buf.appendSlice(allocator, "</div></details>");
}

fn currentActorCanEditAuthor(current_actor: ?[]const u8, current_role: ?[]const u8, author: []const u8) bool {
    const role = current_role orelse return false;
    if (event_mod.roleAtLeast(role, "maintainer")) return true;
    const actor = current_actor orelse return false;
    return event_mod.roleAtLeast(role, "contributor") and std.mem.eql(u8, actor, author);
}

fn issueEditHrefOwned(allocator: Allocator, raw_ref: []const u8, target_ref: ?[]const u8) ![]u8 {
    var href: std.ArrayList(u8) = .empty;
    errdefer href.deinit(allocator);
    try href.appendSlice(allocator, "/issues/");
    try shared.appendUrlEncoded(&href, allocator, raw_ref);
    try href.appendSlice(allocator, "/edit");
    if (target_ref) |target| {
        try href.appendSlice(allocator, "?target=");
        try shared.appendUrlEncoded(&href, allocator, target);
    }
    return href.toOwnedSlice(allocator);
}

fn appendIssueActionMenuItem(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    action: []const u8,
    icon_class: []const u8,
    label: []const u8,
    disabled: bool,
) !void {
    try appendTemplate(buf, allocator,
        \\<button type="button" role="menuitem" data-issue-action="{action}"
    , .{ .action = action });
    if (disabled) try buf.appendSlice(allocator, " disabled");
    try appendTemplate(buf, allocator,
        \\><span class="issue-menu-icon {icon_class}" aria-hidden="true"></span><span data-issue-menu-label>{label}</span></button>
    , .{
        .icon_class = icon_class,
        .label = label,
    });
}

fn appendIssueCommentForm(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_ref: []const u8,
    state: []const u8,
    current_actor: ?[]const u8,
    csrf_token: []const u8,
    error_message: ?[]const u8,
    body_value: []const u8,
) !void {
    try buf.appendSlice(allocator,
        \\<div class="issue-timeline-item issue-comment-form-item">
    );
    try buf.appendSlice(allocator, "  <div class=\"issue-timeline-avatar\">");
    try appendIssueAvatar(buf, allocator, current_actor orelse "Current user", "issue-detail-avatar issue-comment-form-avatar");
    try buf.appendSlice(allocator, "</div>");
    try buf.appendSlice(allocator,
        \\  <form class="issue-comment-box issue-comment-form" method="post" action="/issues/
    );
    try shared.appendUrlEncoded(buf, allocator, raw_ref);
    try appendTemplate(buf, allocator,
        \\/comments">
        \\    <input type="hidden" name="{csrf_field}" value="{csrf_token}">
        \\    <input type="hidden" name="reply_parent_ref" value="" data-reply-parent-ref>
    , .{ .csrf_field = zwf.csrf.field_name, .csrf_token = csrf_token });
    try shared.appendMarkdownEditor(buf, allocator, .{ .value = body_value });
    if (error_message) |message| {
        try appendTemplate(buf, allocator,
            \\    <p class="issue-comment-error">{message}</p>
        , .{ .message = message });
    }
    const state_action = if (std.mem.eql(u8, state, "closed")) "reopen-issue" else "close-issue";
    const state_label = if (std.mem.eql(u8, state, "closed")) "Reopen issue" else "Close issue";
    const state_class = if (std.mem.eql(u8, state, "closed")) "primary is-reopen" else "secondary is-close";
    try buf.appendSlice(allocator,
        \\    <div class="issue-comment-form-actions">
        \\      <button class="button secondary" type="submit" name="action" value="comment">Comment</button>
    );
    try appendTemplate(buf, allocator,
        \\      <button class="button {state_class} issue-state-submit" type="submit" name="action" value="{state_action}" formnovalidate>{state_label}</button>
    , .{
        .state_class = state_class,
        .state_action = state_action,
        .state_label = state_label,
    });
    try buf.appendSlice(allocator,
        \\    </div>
        \\  </form>
        \\</div>
    );
}

pub fn handleIssueEditPost(allocator: Allocator, repo: Repo, stream: std.net.Stream, raw_ref: []const u8, form_body: []const u8) !void {
    try ensureIndex(allocator, repo);
    const issue_id = index.resolveIssueId(allocator, repo, raw_ref) catch {
        const page = try renderIssueNotFound(allocator, repo, raw_ref);
        defer allocator.free(page);
        try sendResponse(allocator, stream, 404, "Not Found", "text/html", page, null);
        return;
    };
    defer allocator.free(issue_id);

    const target_ref_owned = (try formValueOwned(allocator, form_body, "target_ref")) orelse try allocator.dupe(u8, "issue");
    defer allocator.free(target_ref_owned);
    const target_ref = std.mem.trim(u8, target_ref_owned, " \t\r\n");
    if (target_ref.len == 0 or std.mem.eql(u8, target_ref, "issue")) {
        try handleIssueBodyEditPost(allocator, repo, stream, raw_ref, issue_id, form_body);
        return;
    }
    try handleCommentBodyEditPost(allocator, repo, stream, raw_ref, issue_id, target_ref, form_body);
}

fn handleIssueBodyEditPost(
    allocator: Allocator,
    repo: Repo,
    stream: std.net.Stream,
    raw_ref: []const u8,
    issue_id: []const u8,
    form_body: []const u8,
) !void {
    const title_owned = (try formValueOwned(allocator, form_body, "title")) orelse try allocator.dupe(u8, "");
    defer allocator.free(title_owned);
    const body_owned = (try formValueOwned(allocator, form_body, "body")) orelse try allocator.dupe(u8, "");
    defer allocator.free(body_owned);
    const title = std.mem.trim(u8, title_owned, " \t\r\n");
    if (title.len == 0) {
        const page = try renderIssueEditIssuePage(allocator, repo, raw_ref, "Title is required.", title_owned, body_owned);
        defer allocator.free(page);
        try sendResponse(allocator, stream, 422, "Unprocessable Entity", "text/html", page, null);
        return;
    }

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var stmt = try db.prepare("SELECT title, body, author_principal FROM issues WHERE id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    if (!(try stmt.step())) {
        const page = try renderIssueNotFound(allocator, repo, raw_ref);
        defer allocator.free(page);
        try sendResponse(allocator, stream, 404, "Not Found", "text/html", page, null);
        return;
    }
    const current_title = try stmt.columnTextDup(allocator, 0);
    defer allocator.free(current_title);
    const current_body = try stmt.columnTextDup(allocator, 1);
    defer allocator.free(current_body);
    const author_principal = try stmt.columnTextDup(allocator, 2);
    defer allocator.free(author_principal);
    if (!(try currentActorCanEditInRepo(allocator, repo, author_principal))) {
        const page = try renderIssueEditAccessDenied(allocator, repo, raw_ref, "Edit issue", "You do not have permission to edit this issue.");
        defer allocator.free(page);
        try sendResponse(allocator, stream, 403, "Forbidden", "text/html", page, null);
        return;
    }

    var update: event_mod.IssueUpdate = .{};
    if (!std.mem.eql(u8, title, current_title)) update.title = title;
    if (!std.mem.eql(u8, body_owned, current_body)) update.body = body_owned;
    if (!update.hasChanges()) {
        const location = try std.fmt.allocPrint(allocator, "/issues/{s}", .{raw_ref});
        defer allocator.free(location);
        try sendRedirect(allocator, stream, location);
        return;
    }

    createIssueUpdatedEvent(allocator, issue_id, update) catch {
        const page = try renderIssueEditIssuePage(allocator, repo, raw_ref, "Could not save the issue. Check that Gitomi is initialized and Git commit signing is configured.", title, body_owned);
        defer allocator.free(page);
        try sendResponse(allocator, stream, 500, "Internal Server Error", "text/html", page, null);
        return;
    };

    const location = try std.fmt.allocPrint(allocator, "/issues/{s}", .{raw_ref});
    defer allocator.free(location);
    try sendRedirect(allocator, stream, location);
}

pub fn handleIssueChecklistPost(allocator: Allocator, repo: Repo, stream: std.net.Stream, raw_ref: []const u8, form_body: []const u8) !void {
    try ensureIndex(allocator, repo);
    const issue_id = index.resolveIssueId(allocator, repo, raw_ref) catch {
        try sendPlainResponse(allocator, stream, 404, "Not Found", "Issue not found\n");
        return;
    };
    defer allocator.free(issue_id);

    const body_owned = (try formValueOwned(allocator, form_body, "body")) orelse {
        try sendPlainResponse(allocator, stream, 400, "Bad Request", "Missing body\n");
        return;
    };
    defer allocator.free(body_owned);

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var stmt = try db.prepare("SELECT body, author_principal FROM issues WHERE id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    if (!(try stmt.step())) {
        try sendPlainResponse(allocator, stream, 404, "Not Found", "Issue not found\n");
        return;
    }
    const current_body = try stmt.columnTextDup(allocator, 0);
    defer allocator.free(current_body);
    const author_principal = try stmt.columnTextDup(allocator, 1);
    defer allocator.free(author_principal);
    if (!(try currentActorCanEditInRepo(allocator, repo, author_principal))) {
        try sendPlainResponse(allocator, stream, 403, "Forbidden", "Forbidden\n");
        return;
    }
    if (std.mem.eql(u8, body_owned, current_body)) {
        try sendResponse(allocator, stream, 204, "No Content", "text/plain", "", null);
        return;
    }

    createIssueUpdatedEvent(allocator, issue_id, .{ .body = body_owned }) catch {
        try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not update checklist\n");
        return;
    };
    try sendResponse(allocator, stream, 204, "No Content", "text/plain", "", null);
}

fn handleCommentBodyEditPost(
    allocator: Allocator,
    repo: Repo,
    stream: std.net.Stream,
    raw_ref: []const u8,
    issue_id: []const u8,
    target_ref: []const u8,
    form_body: []const u8,
) !void {
    const body_owned = (try formValueOwned(allocator, form_body, "body")) orelse try allocator.dupe(u8, "");
    defer allocator.free(body_owned);
    const comment_id = index.resolveCommentId(allocator, repo, target_ref) catch {
        const page = try renderIssueEditAccessDenied(allocator, repo, raw_ref, "Edit comment", "Comment not found.");
        defer allocator.free(page);
        try sendResponse(allocator, stream, 404, "Not Found", "text/html", page, null);
        return;
    };
    defer allocator.free(comment_id);
    var parent = try index.commentParentInfo(allocator, repo, comment_id);
    defer parent.deinit();
    if (!std.mem.eql(u8, parent.parent_kind, "issue") or !std.mem.eql(u8, parent.parent_id, issue_id)) {
        const page = try renderIssueEditAccessDenied(allocator, repo, raw_ref, "Edit comment", "Comment is not in this issue.");
        defer allocator.free(page);
        try sendResponse(allocator, stream, 422, "Unprocessable Entity", "text/html", page, null);
        return;
    }

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var stmt = try db.prepare("SELECT body, redacted, author_principal FROM comments WHERE id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, comment_id);
    if (!(try stmt.step())) {
        const page = try renderIssueEditAccessDenied(allocator, repo, raw_ref, "Edit comment", "Comment not found.");
        defer allocator.free(page);
        try sendResponse(allocator, stream, 404, "Not Found", "text/html", page, null);
        return;
    }
    const current_body = try stmt.columnTextDup(allocator, 0);
    defer allocator.free(current_body);
    const redacted = stmt.columnInt(1) != 0;
    const author_principal = try stmt.columnTextDup(allocator, 2);
    defer allocator.free(author_principal);
    if (redacted or !(try currentActorCanEditInRepo(allocator, repo, author_principal))) {
        const page = try renderIssueEditAccessDenied(allocator, repo, raw_ref, "Edit comment", "You do not have permission to edit this comment.");
        defer allocator.free(page);
        try sendResponse(allocator, stream, 403, "Forbidden", "text/html", page, null);
        return;
    }

    var comment_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const comment_ref = util.shortObjectRef(&comment_ref_buf, comment_id);
    if (std.mem.eql(u8, body_owned, current_body)) {
        const location = try std.fmt.allocPrint(allocator, "/issues/{s}#comment-{s}", .{ raw_ref, comment_ref });
        defer allocator.free(location);
        try sendRedirect(allocator, stream, location);
        return;
    }

    createCommentBodySetEvent(allocator, comment_id, body_owned) catch {
        const page = try renderIssueEditCommentPage(allocator, repo, raw_ref, target_ref, "Could not save the comment. Check that Gitomi is initialized and Git commit signing is configured.", body_owned);
        defer allocator.free(page);
        try sendResponse(allocator, stream, 500, "Internal Server Error", "text/html", page, null);
        return;
    };

    const location = try std.fmt.allocPrint(allocator, "/issues/{s}#comment-{s}", .{ raw_ref, comment_ref });
    defer allocator.free(location);
    try sendRedirect(allocator, stream, location);
}

pub fn handleIssueCommentPost(allocator: Allocator, repo: Repo, stream: std.net.Stream, raw_ref: []const u8, csrf_token: []const u8, form_body: []const u8) !void {
    const action_owned = try formValueOwned(allocator, form_body, "action");
    defer if (action_owned) |value| allocator.free(value);
    if (action_owned) |raw_action| {
        const action = std.mem.trim(u8, raw_action, " \t\r\n");
        if (std.mem.eql(u8, action, "add-reaction") or std.mem.eql(u8, action, "remove-reaction")) {
            try ensureIndex(allocator, repo);
            const issue_id = index.resolveIssueId(allocator, repo, raw_ref) catch {
                try sendPlainResponse(allocator, stream, 404, "Not Found", "Issue not found\n");
                return;
            };
            defer allocator.free(issue_id);

            const emoji_owned = (try formValueOwned(allocator, form_body, "emoji")) orelse {
                try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Emoji is required\n");
                return;
            };
            defer allocator.free(emoji_owned);
            const emoji = std.mem.trim(u8, emoji_owned, " \t\r\n");
            if (emoji.len == 0) {
                try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Emoji is required\n");
                return;
            }

            const target_kind_owned = (try formValueOwned(allocator, form_body, "target_kind")) orelse try allocator.dupe(u8, "issue");
            defer allocator.free(target_kind_owned);
            const target_kind = std.mem.trim(u8, target_kind_owned, " \t\r\n");
            const add = std.mem.eql(u8, action, "add-reaction");
            if (std.mem.eql(u8, target_kind, "issue")) {
                createReactionEvent(allocator, "issue", issue_id, emoji, add) catch {
                    try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not update reaction\n");
                    return;
                };
            } else if (std.mem.eql(u8, target_kind, "comment")) {
                const target_ref_owned = (try formValueOwned(allocator, form_body, "target_ref")) orelse {
                    try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Comment target is required\n");
                    return;
                };
                defer allocator.free(target_ref_owned);
                const comment_id = index.resolveCommentId(allocator, repo, target_ref_owned) catch {
                    try sendPlainResponse(allocator, stream, 404, "Not Found", "Comment not found\n");
                    return;
                };
                defer allocator.free(comment_id);
                var parent = try index.commentParentInfo(allocator, repo, comment_id);
                defer parent.deinit();
                if (!std.mem.eql(u8, parent.parent_kind, "issue") or !std.mem.eql(u8, parent.parent_id, issue_id)) {
                    try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Comment is not in this issue\n");
                    return;
                }
                createReactionEvent(allocator, "comment", comment_id, emoji, add) catch {
                    try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not update reaction\n");
                    return;
                };
            } else {
                try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Unknown reaction target\n");
                return;
            }

            const location = try std.fmt.allocPrint(allocator, "/issues/{s}", .{raw_ref});
            defer allocator.free(location);
            try sendRedirect(allocator, stream, location);
            return;
        }
    }

    const submit_action = if (action_owned) |raw_action| std.mem.trim(u8, raw_action, " \t\r\n") else "comment";
    const target_state: ?[]const u8 = if (std.mem.eql(u8, submit_action, "close-issue"))
        "closed"
    else if (std.mem.eql(u8, submit_action, "reopen-issue"))
        "open"
    else
        null;
    if (!std.mem.eql(u8, submit_action, "comment") and target_state == null) {
        try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Unknown issue action\n");
        return;
    }

    const body_owned = (try formValueOwned(allocator, form_body, "body")) orelse try allocator.dupe(u8, "");
    defer allocator.free(body_owned);

    const body = std.mem.trim(u8, body_owned, " \t\r\n");
    if (body.len == 0 and target_state == null) {
        const page = try renderIssueDetailPageWithCommentForm(allocator, repo, raw_ref, csrf_token, "Comment is required.", body_owned);
        defer allocator.free(page);
        try sendResponse(allocator, stream, 422, "Unprocessable Entity", "text/html", page, null);
        return;
    }

    try ensureIndex(allocator, repo);
    const issue_id = index.resolveIssueId(allocator, repo, raw_ref) catch {
        const page = try renderIssueNotFound(allocator, repo, raw_ref);
        defer allocator.free(page);
        try sendResponse(allocator, stream, 404, "Not Found", "text/html", page, null);
        return;
    };
    defer allocator.free(issue_id);

    if (body.len != 0) {
        const reply_ref_owned = try formValueOwned(allocator, form_body, "reply_parent_ref");
        defer if (reply_ref_owned) |value| allocator.free(value);
        const reply_ref = if (reply_ref_owned) |value| std.mem.trim(u8, value, " \t\r\n") else "";
        if (reply_ref.len != 0) {
            const reply_parent_id = index.resolveCommentId(allocator, repo, reply_ref) catch {
                const page = try renderIssueDetailPageWithCommentForm(allocator, repo, raw_ref, csrf_token, "Reply target was not found.", body_owned);
                defer allocator.free(page);
                try sendResponse(allocator, stream, 422, "Unprocessable Entity", "text/html", page, null);
                return;
            };
            defer allocator.free(reply_parent_id);
            var parent = try index.commentParentInfo(allocator, repo, reply_parent_id);
            defer parent.deinit();
            if (!std.mem.eql(u8, parent.parent_kind, "issue") or !std.mem.eql(u8, parent.parent_id, issue_id)) {
                const page = try renderIssueDetailPageWithCommentForm(allocator, repo, raw_ref, csrf_token, "Reply target is not in this issue.", body_owned);
                defer allocator.free(page);
                try sendResponse(allocator, stream, 422, "Unprocessable Entity", "text/html", page, null);
                return;
            }
            createCommentReplyEvent(allocator, "issue", issue_id, reply_parent_id, parent.add_hash, body_owned) catch {
                const page = try renderIssueDetailPageWithCommentForm(
                    allocator,
                    repo,
                    raw_ref,
                    csrf_token,
                    "Could not add the reply. Check that Gitomi is initialized and Git commit signing is configured.",
                    body_owned,
                );
                defer allocator.free(page);
                try sendResponse(allocator, stream, 500, "Internal Server Error", "text/html", page, null);
                return;
            };
        } else {
            createCommentAddedEvent(allocator, "issue", issue_id, body_owned) catch {
                const page = try renderIssueDetailPageWithCommentForm(
                    allocator,
                    repo,
                    raw_ref,
                    csrf_token,
                    "Could not add the comment. Check that Gitomi is initialized and Git commit signing is configured.",
                    body_owned,
                );
                defer allocator.free(page);
                try sendResponse(allocator, stream, 500, "Internal Server Error", "text/html", page, null);
                return;
            };
        }
    }

    if (target_state) |state_value| {
        createIssueStringEvent(allocator, issue_id, "issue.state_set", "state", state_value) catch {
            const page = try renderIssueDetailPageWithCommentForm(
                allocator,
                repo,
                raw_ref,
                csrf_token,
                if (std.mem.eql(u8, state_value, "closed"))
                    "Could not close the issue. Check that Gitomi is initialized and Git commit signing is configured."
                else
                    "Could not reopen the issue. Check that Gitomi is initialized and Git commit signing is configured.",
                body_owned,
            );
            defer allocator.free(page);
            try sendResponse(allocator, stream, 500, "Internal Server Error", "text/html", page, null);
            return;
        };
    }

    const location = try std.fmt.allocPrint(allocator, "/issues/{s}", .{raw_ref});
    defer allocator.free(location);
    try sendRedirect(allocator, stream, location);
}
