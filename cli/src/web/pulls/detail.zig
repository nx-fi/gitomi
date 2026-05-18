const std = @import("std");
const comment_mod = @import("../../comment.zig");
const event_validation = @import("../../event/validation.zig");
const index = @import("../../index.zig");
const issues_page = @import("../issues.zig");
const pull_comments = @import("comments.zig");
const pull_git_tabs = @import("git_tabs.zig");
const merge_editor = @import("merge_editor.zig");
const notifications = @import("../notifications.zig");
const pull_merge = @import("merge.zig");
const pulls_list = @import("list.zig");
const pull_sidebar = @import("sidebar.zig");
const pull = @import("../../pr.zig");
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
const appendHref = shared.appendHref;
const appendPill = shared.appendPill;
const appendShellEnd = shared.appendShellEnd;
const appendShellStart = shared.appendShellStart;
const appendRelativeTime = shared.appendRelativeTime;
const appendTemplate = shared.appendTemplate;
const commitHref = shared.commitHref;
const createCommentAddedEvent = comment_mod.createCommentAddedEvent;
const createCommentReplyEvent = comment_mod.createCommentReplyEvent;
const createReactionEvent = reaction_mod.createReactionEvent;
const literalHref = shared.literalHref;
const pullHref = shared.pullHref;
const queryValueOwned = shared.queryValueOwned;
const sendRedirect = shared.sendRedirect;
const sendPlainResponse = shared.sendPlainResponse;
const sendResponse = shared.sendResponse;
const sqlite = index.sqlite;

const PullDetailTab = enum {
    conversation,
    commits,
    files,
};

const PullDetail = work_items.PullDetail;

const PullTabCounts = struct {
    comments: usize = 0,
    commits: ?usize = null,
    files: ?usize = null,
    additions: ?usize = null,
    deletions: ?usize = null,
};

const PullMergeSnapshot = merge_editor.PullMergeSnapshot;
const PullMergeStatus = merge_editor.PullMergeStatus;
const ResolvedConflictFile = merge_editor.ResolvedConflictFile;
const contentHasConflictMarkers = merge_editor.contentHasConflictMarkers;

const FormField = struct {
    name: []u8,
    value: []u8,

    fn deinit(self: FormField, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value);
    }
};

const SubmittedExpectedOids = struct {
    base_oid: []const u8,
    head_oid: []const u8,
};

const DiffCommentSide = work_items.DiffCommentSide;
const DiffCommentContext = work_items.DiffCommentContext;

pub const renderPullsPage = pulls_list.renderPullsPage;
pub const handlePullBulkPost = pulls_list.handlePullBulkPost;

fn pullDetailTabFromTarget(allocator: Allocator, target: []const u8) !PullDetailTab {
    const tab_value = try queryValueOwned(allocator, target, "tab");
    defer if (tab_value) |value| allocator.free(value);
    const value = tab_value orelse return .conversation;
    if (std.mem.eql(u8, value, "commits")) return .commits;
    if (std.mem.eql(u8, value, "files")) return .files;
    return .conversation;
}

pub fn renderPullDetailPage(allocator: Allocator, repo: Repo, raw_ref: []const u8, target: []const u8, csrf_token: []const u8) ![]u8 {
    return renderPullDetailPageWithMergeError(allocator, repo, raw_ref, target, csrf_token, null);
}

fn renderPullDetailPageWithMergeError(allocator: Allocator, repo: Repo, raw_ref: []const u8, target: []const u8, csrf_token: []const u8, merge_error: ?[]const u8) ![]u8 {
    if (try shared.renderIndexingPageIfStale(allocator, repo, "Pull Request", "pulls", target)) |body| return body;
    try index.ensureIndex(allocator, repo);
    const pull_id = index.resolvePullId(allocator, repo, raw_ref) catch {
        return renderPullNotFound(allocator, repo, raw_ref);
    };
    defer allocator.free(pull_id);

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    const detail = (try work_items.loadPullDetail(allocator, &db, pull_id)) orelse return renderPullNotFound(allocator, repo, raw_ref);
    defer detail.deinit(allocator);
    const tab = try pullDetailTabFromTarget(allocator, target);

    var pull_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const pull_ref = util.shortObjectRef(&pull_ref_buf, detail.id);
    const tab_counts = try loadPullTabCounts(allocator, repo, &db, detail);
    const merge_status = try pull_merge.loadStatus(allocator, repo, detail);
    defer merge_status.deinit(allocator);
    const current_actor = try shared.currentPrincipalOwned(allocator, repo);
    defer if (current_actor) |actor| allocator.free(actor);
    const current_role = if (current_actor) |actor| try index.effectiveWriteRoleForPrincipal(allocator, repo, actor) else null;
    defer if (current_role) |role| allocator.free(role);
    const can_edit_pull = currentActorCanEditAuthor(current_actor, current_role, detail.author_principal);
    const can_manage_notifications = notifications.currentActorCanManageNotifications(current_actor, current_role);
    const notification_subscribed = if (current_actor) |actor|
        try notifications.isNotificationSubscribed(&db, actor, "pull", detail.id)
    else
        false;

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, detail.title, "pulls");
    try shared.appendDetailBackButton(&buf, allocator, shared.literalHref("/pulls"), "Back to pull requests");
    try buf.appendSlice(allocator, "<section class=\"pull-detail issue-page\">");
    try appendPullPageHeader(&buf, allocator, detail, pull_ref, tab_counts, merge_status, can_manage_notifications, notification_subscribed, csrf_token);
    try appendPullTabs(&buf, allocator, pull_ref, tab, tab_counts);
    try appendTemplate(&buf, allocator,
        \\<div class="issue-conversation-layout pull-conversation-layout">
        \\  <div class="pull-tab-content">
    , .{});
    switch (tab) {
        .conversation => try appendPullConversation(&buf, allocator, &db, detail, raw_ref, tab_counts, current_actor, can_edit_pull, merge_status, csrf_token, merge_error),
        .commits => try pull_git_tabs.appendCommits(&buf, allocator, repo, detail),
        .files => try pull_git_tabs.appendFiles(&buf, allocator, repo, detail, raw_ref),
    }
    try buf.appendSlice(allocator, "</div><aside class=\"issue-meta-sidebar pull-sidebar\">");
    try pull_sidebar.append(&buf, allocator, repo, &db, detail, pull_ref, csrf_token);
    try buf.appendSlice(allocator, "</aside></div></section>");
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn renderPullNotFound(allocator: Allocator, repo: Repo, raw_ref: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try appendShellStart(&buf, allocator, repo, "Pull Request Not Found", "pulls");
    try shared.appendDetailBackButton(&buf, allocator, shared.literalHref("/pulls"), "Back to pull requests");
    const detail = try std.fmt.allocPrint(allocator, "No pull request matches {s}.", .{raw_ref});
    defer allocator.free(detail);
    try appendEmptyState(&buf, allocator, "Pull request not found.", detail);
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

pub fn renderPullMergeEditorPage(allocator: Allocator, repo: Repo, raw_ref: []const u8, target: []const u8, csrf_token: []const u8, error_message: ?[]const u8) ![]u8 {
    if (try shared.renderIndexingPageIfStale(allocator, repo, "Resolve Conflicts", "pulls", target)) |body| return body;
    try index.ensureIndex(allocator, repo);
    const pull_id = index.resolvePullId(allocator, repo, raw_ref) catch {
        return renderPullNotFound(allocator, repo, raw_ref);
    };
    defer allocator.free(pull_id);

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    const detail = (try work_items.loadPullDetail(allocator, &db, pull_id)) orelse return renderPullNotFound(allocator, repo, raw_ref);
    defer detail.deinit(allocator);

    const merge_status = try pull_merge.loadStatus(allocator, repo, detail);
    defer merge_status.deinit(allocator);

    var pull_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const pull_ref = util.shortObjectRef(&pull_ref_buf, detail.id);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "Resolve Conflicts", "pulls");
    try shared.appendDetailBackButton(&buf, allocator, pullHref(pull_ref), "Back to pull request");
    if (!merge_status.hasConflicts()) {
        try merge_editor.appendEmptyConflictState(&buf, allocator, raw_ref, "No merge conflicts detected.", "This pull request is not currently reporting file conflicts in the local repository.");
        try appendShellEnd(&buf, allocator);
        return buf.toOwnedSlice(allocator);
    }

    const snapshot = merge_status.snapshot orelse {
        try merge_editor.appendEmptyConflictState(&buf, allocator, raw_ref, "Merge refs unavailable.", "Refresh after fetching the configured remote branches.");
        try appendShellEnd(&buf, allocator);
        return buf.toOwnedSlice(allocator);
    };

    const conflict_files = merge_status.conflict_files orelse &[_][]u8{};
    const files = try merge_editor.loadConflictFiles(allocator, repo, detail, snapshot, conflict_files);
    defer merge_editor.freeConflictFiles(allocator, files);

    try merge_editor.appendEditor(&buf, allocator, detail, raw_ref, pull_ref, csrf_token, snapshot, files, error_message);
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn loadPullTabCounts(allocator: Allocator, repo: Repo, db: *SqliteDb, detail: PullDetail) !PullTabCounts {
    var counts: PullTabCounts = .{};
    var comments = try db.prepare("SELECT COUNT(*) FROM comments WHERE parent_kind = 'pull' AND parent_id = ?");
    defer comments.deinit();
    try comments.bindText(1, detail.id);
    if (try comments.step()) counts.comments = @as(usize, @intCast(comments.columnInt64(0)));
    counts.commits = detail.commit_count;
    counts.files = detail.changed_files;
    counts.additions = detail.additions;
    counts.deletions = detail.deletions;

    const git_counts = try pull_git_tabs.loadCounts(allocator, repo, detail);
    if (git_counts.commits) |value| counts.commits = value;
    if (git_counts.files) |value| counts.files = value;
    return counts;
}

fn appendPullPageHeader(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    detail: PullDetail,
    pull_ref: []const u8,
    counts: PullTabCounts,
    merge_status: PullMergeStatus,
    can_manage_notifications: bool,
    notification_subscribed: bool,
    csrf_token: []const u8,
) !void {
    try appendTemplate(buf, allocator,
        \\<header class="issue-page-head pull-page-head">
        \\  <div class="issue-title-line">
        \\    <h1><span>{title}</span> <span class="issue-page-number">
    , .{ .title = detail.title });
    try appendPullDisplayRef(buf, allocator, detail, pull_ref);
    try appendTemplate(buf, allocator,
        \\</span></h1>
        \\    <div class="issue-page-actions">
    , .{});
    if (std.mem.eql(u8, detail.state, "open") and !detail.draft and merge_status.kind == .clean) {
        try buf.appendSlice(allocator,
            \\      <a class="button secondary pull-ready-button" href="#pull-mergeability"><span class="button-icon icon-check" aria-hidden="true"></span><span>Ready to merge</span></a>
        );
    } else if (merge_status.hasConflicts()) {
        try appendTemplate(buf, allocator,
            \\      <a class="button secondary pull-conflicts-button" href="/pulls/{pull_ref}/conflicts"><span class="button-icon icon-conflict" aria-hidden="true"></span><span>Resolve conflicts</span></a>
        , .{ .pull_ref = pull_ref });
    }
    try issues_page.appendNotificationSubscriptionButton(buf, allocator, "pulls", pull_ref, can_manage_notifications, notification_subscribed, csrf_token);
    try appendTemplate(buf, allocator,
        \\      <button class="issue-copy-button" type="button" data-copy-work-item-link="{copy_href}" aria-label="Copy link" title="Copy link"><span class="button-icon icon-copy" aria-hidden="true"></span></button>
        \\    </div>
        \\  </div>
        \\  <div class="issue-status-line pull-status-line">
    , .{ .copy_href = pullHref(pull_ref) });
    try appendPullStateBadge(buf, allocator, detail.state, detail.draft);
    try appendPullHeaderSummary(buf, allocator, detail, counts);
    try buf.appendSlice(allocator, "</div></header>");
}

fn appendPullDisplayRef(buf: *std.ArrayList(u8), allocator: Allocator, detail: PullDetail, pull_ref: []const u8) !void {
    try buf.append(allocator, '#');
    if (detail.legacy_number > 0) {
        try std.fmt.format(buf.writer(allocator), "{d}", .{detail.legacy_number});
    } else {
        try shared.appendHtml(buf, allocator, pull_ref);
    }
}

fn appendPullHeaderSummary(buf: *std.ArrayList(u8), allocator: Allocator, detail: PullDetail, counts: PullTabCounts) !void {
    if (std.mem.eql(u8, detail.state, "merged")) {
        try appendTemplate(buf, allocator,
            \\<span><strong>{actor}</strong> merged 
        , .{
            .actor = if (detail.state_actor_principal.len != 0) detail.state_actor_principal else detail.author_principal,
        });
        try appendPullCommitSummary(buf, allocator, counts.commits);
        try buf.appendSlice(allocator, " into ");
        try appendPullBranchLink(buf, allocator, detail.base_ref);
        try buf.appendSlice(allocator, " from ");
        try appendPullBranchLink(buf, allocator, detail.head_ref);
        try buf.append(allocator, ' ');
        try appendRelativeTime(buf, allocator, detail.state_occurred_at);
        try buf.appendSlice(allocator, "</span>");
        return;
    }

    if (std.mem.eql(u8, detail.state, "closed")) {
        try appendTemplate(buf, allocator,
            \\<span><strong>{actor}</strong> closed this pull request
        , .{ .actor = if (detail.state_actor_principal.len != 0) detail.state_actor_principal else detail.author_principal });
        try buf.append(allocator, ' ');
        try appendRelativeTime(buf, allocator, detail.state_occurred_at);
        try buf.appendSlice(allocator, "</span>");
        return;
    }

    try appendTemplate(buf, allocator,
        \\<span><strong>{author}</strong> wants to merge 
    , .{
        .author = pullDisplayAuthor(detail),
    });
    try appendPullCommitSummary(buf, allocator, counts.commits);
    try buf.appendSlice(allocator, " into ");
    try appendPullBranchLink(buf, allocator, detail.base_ref);
    try buf.appendSlice(allocator, " from ");
    try appendPullBranchLink(buf, allocator, detail.head_ref);
    try buf.appendSlice(allocator, "</span>");
}

fn appendPullBranchLink(buf: *std.ArrayList(u8), allocator: Allocator, ref: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<a class="pull-branch-link" href="{href}"><code>{ref}</code></a>
    , .{
        .href = shared.codeHref(ref, ""),
        .ref = ref,
    });
}

fn pullDisplayAuthor(detail: PullDetail) []const u8 {
    return detail.displayAuthor();
}

fn currentActorCanEditAuthor(current_actor: ?[]const u8, current_role: ?[]const u8, author: []const u8) bool {
    const role = current_role orelse return false;
    if (event_validation.roleAtLeast(role, "maintainer")) return true;
    const actor = current_actor orelse return false;
    return event_validation.roleAtLeast(role, "contributor") and std.mem.eql(u8, actor, author);
}

fn currentActorCanEditInRepo(allocator: Allocator, repo: Repo, author: []const u8) !bool {
    const current_actor = try shared.currentPrincipalOwned(allocator, repo);
    defer if (current_actor) |actor| allocator.free(actor);
    const current_role = if (current_actor) |actor| try index.effectiveWriteRoleForPrincipal(allocator, repo, actor) else null;
    defer if (current_role) |role| allocator.free(role);
    return currentActorCanEditAuthor(current_actor, current_role, author);
}

fn appendPullCommitSummary(buf: *std.ArrayList(u8), allocator: Allocator, count: ?usize) !void {
    const value = count orelse {
        try buf.appendSlice(allocator, "changes");
        return;
    };
    try appendTemplate(buf, allocator, "{commit_count} {commit_word}", .{
        .commit_count = value,
        .commit_word = commitWord(value),
    });
}

fn appendPullStateBadge(buf: *std.ArrayList(u8), allocator: Allocator, state: []const u8, draft: bool) !void {
    const badge_state = if (draft and std.mem.eql(u8, state, "open")) "draft" else state;
    try appendTemplate(buf, allocator,
        \\<span class="issue-state-badge pull-state-badge is-{state}"><span class="issue-state-mark" aria-hidden="true"></span>{label}</span>
    , .{
        .state = badge_state,
        .label = pullStateLabel(badge_state),
    });
}

fn pullStateLabel(state: []const u8) []const u8 {
    if (std.mem.eql(u8, state, "open")) return "Open";
    if (std.mem.eql(u8, state, "merged")) return "Merged";
    if (std.mem.eql(u8, state, "closed")) return "Closed";
    if (std.mem.eql(u8, state, "draft")) return "Draft";
    return state;
}

fn appendPullTabs(buf: *std.ArrayList(u8), allocator: Allocator, pull_ref: []const u8, active: PullDetailTab, counts: PullTabCounts) !void {
    try buf.appendSlice(allocator, "<nav class=\"view-tabs pull-tabs\" aria-label=\"Pull request view\">");
    try appendPullTab(buf, allocator, pull_ref, "Conversation", .conversation, active, counts.comments);
    try appendPullTabOptionalCount(buf, allocator, pull_ref, "Commits", .commits, active, counts.commits);
    try appendPullTabOptionalCount(buf, allocator, pull_ref, "Files changed", .files, active, counts.files);
    try appendPullTabDiffstat(buf, allocator, counts);
    try buf.appendSlice(allocator, "</nav>");
}

fn appendPullTabDiffstat(buf: *std.ArrayList(u8), allocator: Allocator, counts: PullTabCounts) !void {
    if (counts.additions == null and counts.deletions == null) return;

    const additions = counts.additions orelse 0;
    const deletions = counts.deletions orelse 0;
    try appendTemplate(buf, allocator,
        \\<span class="pull-tab-diffstat" aria-label="{additions} additions and {deletions} deletions"><strong>+{additions}</strong><em>-{deletions}</em><span class="pull-tab-diffstat-bars" aria-hidden="true">
    , .{
        .additions = additions,
        .deletions = deletions,
    });

    const total = additions + deletions;
    const bar_count: usize = 5;
    var add_bars: usize = 0;
    if (total > 0 and additions > 0) {
        add_bars = (additions * bar_count + total - 1) / total;
        if (add_bars > bar_count) add_bars = bar_count;
    }
    var del_bars: usize = 0;
    if (total > 0 and deletions > 0) {
        del_bars = bar_count - add_bars;
        if (del_bars == 0) del_bars = 1;
    }
    if (add_bars + del_bars > bar_count) {
        if (add_bars >= del_bars) {
            add_bars = bar_count - del_bars;
        } else {
            del_bars = bar_count - add_bars;
        }
    }

    var i: usize = 0;
    while (i < bar_count) : (i += 1) {
        const class_name = if (i < add_bars) "is-add" else if (i < add_bars + del_bars) "is-del" else "is-empty";
        try appendTemplate(buf, allocator, "<i class=\"{class_name}\"></i>", .{ .class_name = class_name });
    }
    try buf.appendSlice(allocator, "</span></span>");
}

fn appendPullTabOptionalCount(buf: *std.ArrayList(u8), allocator: Allocator, pull_ref: []const u8, label: []const u8, tab: PullDetailTab, active: PullDetailTab, count: ?usize) !void {
    try appendPullTabStart(buf, allocator, pull_ref, label, tab, active);
    if (count) |value| try appendTemplate(buf, allocator, "<span class=\"issue-count-badge\">{count}</span>", .{ .count = value });
    try buf.appendSlice(allocator, "</a>");
}

fn appendPullTab(buf: *std.ArrayList(u8), allocator: Allocator, pull_ref: []const u8, label: []const u8, tab: PullDetailTab, active: PullDetailTab, count: usize) !void {
    try appendPullTabStart(buf, allocator, pull_ref, label, tab, active);
    try appendTemplate(buf, allocator, "<span class=\"issue-count-badge\">{count}</span>", .{ .count = count });
    try buf.appendSlice(allocator, "</a>");
}

fn appendPullTabStart(buf: *std.ArrayList(u8), allocator: Allocator, pull_ref: []const u8, label: []const u8, tab: PullDetailTab, active: PullDetailTab) !void {
    try appendTemplate(buf, allocator,
        \\<a class="{classes}" href="/pulls/{pull_ref}{suffix}"><span class="pull-tab-icon {icon}" aria-hidden="true"></span><span>{label}</span>
    , .{
        .classes = shared.classes("", &.{shared.class("active", tab == active)}),
        .pull_ref = pull_ref,
        .suffix = pullTabSuffix(tab),
        .label = label,
        .icon = pullTabIconClass(tab),
    });
}

fn pullTabSuffix(tab: PullDetailTab) []const u8 {
    return switch (tab) {
        .conversation => "",
        .commits => "?tab=commits",
        .files => "?tab=files",
    };
}

fn pullTabIconClass(tab: PullDetailTab) []const u8 {
    return switch (tab) {
        .conversation => "pull-tab-conversation-icon",
        .commits => "pull-tab-commits-icon",
        .files => "pull-tab-files-icon",
    };
}

fn appendPullFacts(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, db: *SqliteDb, detail: PullDetail, pull_ref: []const u8) !void {
    try buf.appendSlice(allocator, "<aside class=\"pull-sidebar\"><dl class=\"facts issue-facts\">");
    try buf.appendSlice(allocator, "<div><dt>Status</dt><dd>");
    try appendPullStatePill(buf, allocator, detail.state, detail.draft);
    try appendTemplate(buf, allocator,
        \\</dd></div><div><dt>ID</dt><dd><code>{id}</code></dd></div><div><dt>Opened</dt><dd>
    , .{
        .id = detail.id,
    });
    try appendRelativeTime(buf, allocator, detail.opened_at);
    try appendTemplate(buf, allocator,
        \\</dd></div><div><dt>Author</dt><dd>{author}/{device}</dd></div><div><dt>Base</dt><dd>
    , .{
        .author = detail.author_principal,
        .device = detail.author_device,
    });
    try appendPullBranchLink(buf, allocator, detail.base_ref);
    try buf.appendSlice(allocator, "</dd></div><div><dt>Head</dt><dd>");
    try appendPullBranchLink(buf, allocator, detail.head_ref);
    try buf.appendSlice(allocator, "</dd></div>");
    if (detail.legacy_number > 0) {
        try buf.appendSlice(allocator, "<div><dt>GitHub</dt><dd>");
        try appendLegacyPullLink(buf, allocator, detail.legacy_number);
        try buf.appendSlice(allocator, "</dd></div>");
    }
    if (detail.merge_oid.len != 0) {
        try appendTemplate(buf, allocator, "<div><dt>Merge OID</dt><dd><code>{merge_oid}</code></dd></div>", .{ .merge_oid = detail.merge_oid });
    }
    if (detail.target_oid.len != 0) {
        try appendTemplate(buf, allocator, "<div><dt>Target OID</dt><dd><code>{target_oid}</code></dd></div>", .{ .target_oid = detail.target_oid });
    }
    if (detail.merge_oid.len != 0 or detail.target_oid.len != 0) {
        try buf.appendSlice(allocator, "<div><dt>Local merge</dt><dd>");
        try pull_merge.appendLocalMergeCheck(buf, allocator, repo, detail);
        try buf.appendSlice(allocator, "</dd></div>");
    }
    try appendPullCollectionFact(buf, allocator, db, "Labels", "SELECT DISTINCT label FROM pull_labels WHERE pull_id = ? ORDER BY label", detail.id);
    try appendPullCollectionFact(buf, allocator, db, "Assignees", "SELECT DISTINCT assignee FROM pull_assignees WHERE pull_id = ? ORDER BY assignee", detail.id);
    try appendPullCollectionFact(buf, allocator, db, "Reviewers", "SELECT DISTINCT reviewer FROM pull_reviewers WHERE pull_id = ? ORDER BY reviewer", detail.id);
    try appendTemplate(buf, allocator, "<div><dt>Link</dt><dd><a href=\"/pulls/{pull_ref}\">/pulls/{pull_ref}</a></dd></div>", .{ .pull_ref = pull_ref });
    try buf.appendSlice(allocator, "</dl></aside>");
}

fn appendPullCollectionFact(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, label: []const u8, comptime sql_text: []const u8, pull_id: []const u8) !void {
    try appendTemplate(buf, allocator, "<div><dt>{label}</dt><dd class=\"pill-list\">", .{ .label = label });
    var stmt = try db.prepare(sql_text);
    defer stmt.deinit();
    try stmt.bindText(1, pull_id);
    var shown = false;
    while (try stmt.step()) {
        const value = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(value);
        try appendPill(buf, allocator, value);
        shown = true;
    }
    if (!shown) try buf.appendSlice(allocator, "<span class=\"muted\">None</span>");
    try buf.appendSlice(allocator, "</dd></div>");
}

fn appendPullConversation(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    detail: PullDetail,
    raw_ref: []const u8,
    counts: PullTabCounts,
    current_actor: ?[]const u8,
    can_edit_pull: bool,
    merge_status: PullMergeStatus,
    csrf_token: []const u8,
    merge_error: ?[]const u8,
) !void {
    try appendTemplate(buf, allocator,
        \\<div class="issue-conversation pull-conversation">
        \\  <div class="issue-timeline-item">
        \\    <div class="issue-timeline-avatar">
    , .{});
    try appendAvatar(buf, allocator, pullDisplayAuthor(detail), detail.source_avatar_url, "issue-detail-avatar");
    try appendTemplate(buf, allocator,
        \\    </div>
        \\    <article class="issue-comment-box pull-card" id="pull-description">
        \\      <header class="issue-comment-head"><div><strong>{author}</strong><span>opened
    , .{ .author = pullDisplayAuthor(detail) });
    try buf.append(allocator, ' ');
    try appendRelativeTime(buf, allocator, detail.opened_at);
    try appendTemplate(buf, allocator,
        \\</span></div>
    , .{});
    try issues_page.appendIssueActionMenu(buf, allocator, "pull-description", "", detail.body, detail.body.len != 0, "");
    try buf.appendSlice(allocator,
        \\</header>
        \\  <div class="markdown-body"
    );
    if (can_edit_pull) {
        try buf.appendSlice(allocator, " data-checklist-owner=\"pull\" data-checklist-update-action=\"/pulls/");
        try shared.appendUrlEncoded(buf, allocator, raw_ref);
        try buf.appendSlice(allocator, "/checklist\" data-checklist-csrf=\"");
        try shared.appendHtml(buf, allocator, csrf_token);
        try buf.append(allocator, '"');
    }
    try buf.appendSlice(allocator, ">");
    if (detail.body.len == 0) {
        try buf.appendSlice(allocator, "<p class=\"muted\">No description provided.</p>");
    } else {
        try shared.appendMarkdownSource(buf, allocator, detail.body, .{});
    }
    try buf.appendSlice(allocator, "</div>");
    try pull_comments.appendReactionBar(buf, allocator, db, "pull", detail.id, raw_ref, "", current_actor);
    try buf.appendSlice(allocator, "</article></div>");
    try pull_comments.appendComments(buf, allocator, db, raw_ref, detail.id, current_actor);
    try appendPullMergeabilityTimeline(buf, allocator, detail, raw_ref, counts.commits, merge_status, csrf_token, merge_error);
    try appendPullResolutionTimeline(buf, allocator, detail);
    try pull_comments.appendCommentForm(buf, allocator, raw_ref, current_actor);
    try buf.appendSlice(allocator, "</div>");
}

fn appendPullResolutionTimeline(buf: *std.ArrayList(u8), allocator: Allocator, detail: PullDetail) !void {
    if (!std.mem.eql(u8, detail.state, "merged") and !std.mem.eql(u8, detail.state, "closed")) return;
    const merged = std.mem.eql(u8, detail.state, "merged");
    const merge_display_oid = if (detail.merge_oid.len != 0) detail.merge_oid else detail.target_oid;

    try appendTemplate(buf, allocator,
        \\<div class="issue-timeline-item pull-event-item">
        \\  <div class="issue-timeline-avatar"><span class="pull-timeline-icon is-{state}" aria-hidden="true"></span></div>
        \\  <div class="pull-event-text"><span><strong>{actor}</strong> {verb}
    , .{
        .state = detail.state,
        .actor = if (detail.state_actor_principal.len != 0) detail.state_actor_principal else detail.author_principal,
        .verb = if (merged and merge_display_oid.len != 0) "merged commit" else if (merged) "merged this pull request" else "closed this pull request",
    });
    if (merged and merge_display_oid.len != 0) {
        try appendTemplate(buf, allocator,
            \\ <a href="{href}"><code>{short_oid}</code></a> into <code>{base_ref}</code>
        , .{
            .href = commitHref(merge_display_oid),
            .short_oid = merge_display_oid[0..@min(merge_display_oid.len, 12)],
            .base_ref = detail.base_ref,
        });
    }
    try buf.append(allocator, ' ');
    try appendRelativeTime(buf, allocator, detail.state_occurred_at);
    try buf.appendSlice(allocator, "</span>");
    if (merged) {
        try buf.appendSlice(allocator, "<button class=\"button secondary pull-revert-button\" type=\"button\" disabled>Revert</button>");
    }
    try buf.appendSlice(allocator, "</div></div>");

    try appendTemplate(buf, allocator,
        \\<div class="issue-timeline-item pull-resolution-item">
        \\  <div class="issue-timeline-avatar"><span class="pull-timeline-icon is-{state}" aria-hidden="true"></span></div>
        \\  <div class="pull-resolution-box">
        \\    <h2>{title}</h2>
        \\    <p>{body}</p>
        \\  </div>
        \\</div>
    , .{
        .state = detail.state,
        .title = if (merged) "Pull request successfully merged and closed" else "Pull request closed",
        .body = if (merged) "You're all set - the branch has been merged." else "This pull request was closed without being merged.",
    });
}

fn appendPullMergeabilityTimeline(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    detail: PullDetail,
    raw_ref: []const u8,
    commit_count: ?usize,
    merge_status: PullMergeStatus,
    csrf_token: []const u8,
    merge_error: ?[]const u8,
) !void {
    if (!std.mem.eql(u8, detail.state, "open")) return;
    if (detail.draft) return;
    if (merge_status.kind == .clean) {
        const snapshot = merge_status.snapshot orelse return;
        try appendPullReadyToMergeTimeline(buf, allocator, raw_ref, commit_count, snapshot, csrf_token, merge_error);
        return;
    }
    if (!merge_status.hasConflicts()) return;
    try buf.appendSlice(allocator,
        \\<div class="issue-timeline-item pull-mergeability-item" id="pull-mergeability">
        \\  <div class="issue-timeline-avatar"><span class="pull-mergeability-icon is-conflicts" aria-hidden="true"></span></div>
        \\  <div class="pull-mergeability-box is-conflicts">
        \\    <div class="pull-mergeability-head">
        \\      <div>
        \\        <h2>This branch has conflicts that must be resolved</h2>
        \\        <p>Resolve these files in the web editor, then commit the resolution back to the pull request branch.</p>
        \\      </div>
        \\      <a class="button secondary pull-mergeability-action" href="/pulls/
    );
    try shared.appendUrlEncoded(buf, allocator, raw_ref);
    try buf.appendSlice(allocator,
        \\/conflicts">Resolve conflicts</a>
        \\    </div>
    );
    if (merge_status.conflict_files) |conflict_files| {
        if (conflict_files.len == 0) {
            try buf.appendSlice(allocator, "<p class=\"pull-mergeability-empty\">Git reported merge conflicts, but did not return file names.</p>");
        } else {
            try buf.appendSlice(allocator, "<ul class=\"pull-conflict-file-list\">");
            for (conflict_files) |file| {
                try appendTemplate(buf, allocator,
                    \\<li><span class="pull-conflict-file-icon" aria-hidden="true"></span><code>{file}</code></li>
                , .{ .file = file });
            }
            try buf.appendSlice(allocator, "</ul>");
        }
    } else {
        try buf.appendSlice(allocator, "<p class=\"pull-mergeability-empty\">Git reported merge conflicts, but did not return file names.</p>");
    }
    try buf.appendSlice(allocator, "</div></div>");
}

fn appendPullReadyToMergeTimeline(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_ref: []const u8,
    commit_count: ?usize,
    snapshot: PullMergeSnapshot,
    csrf_token: []const u8,
    merge_error: ?[]const u8,
) !void {
    const commit_phrase = try mergeMethodCommitPhrase(allocator, commit_count);
    defer allocator.free(commit_phrase);

    try buf.appendSlice(allocator,
        \\<div class="issue-timeline-item pull-mergeability-item" id="pull-mergeability">
        \\  <div class="issue-timeline-avatar"><span class="pull-mergeability-icon is-clean" aria-hidden="true"></span></div>
        \\  <div class="pull-mergeability-box is-clean">
        \\    <div class="pull-mergeability-head">
        \\      <div>
        \\        <h2>No conflicts with base branch</h2>
        \\        <p>Merging can be performed automatically.</p>
        \\      </div>
        \\    </div>
    );
    if (merge_error) |message| {
        try appendTemplate(buf, allocator, "<div class=\"flash error pull-merge-error\">{message}</div>", .{ .message = message });
    }
    try buf.appendSlice(allocator,
        \\    <form class="pull-merge-form" method="post" action="/pulls/
    );
    try shared.appendUrlEncoded(buf, allocator, raw_ref);
    try appendTemplate(buf, allocator,
        \\/merge">
        \\      <input type="hidden" name="{csrf_field}" value="{csrf}">
        \\      <input type="hidden" name="expected_base_oid" value="{expected_base_oid}">
        \\      <input type="hidden" name="expected_head_oid" value="{expected_head_oid}">
        \\      <div class="pull-merge-actions">
        \\        <div class="pull-merge-button-group">
        \\          <button class="button primary pull-merge-submit" type="submit" name="method" value="merge"><span class="button-icon icon-pull-request" aria-hidden="true"></span><span data-merge-submit-label>Merge pull request</span></button>
        \\          <details class="pull-merge-method-menu" data-popover-menu>
        \\            <summary class="button primary pull-merge-method-toggle" aria-label="Choose merge method" title="Choose merge method"><span class="button-icon icon-chevron-down" aria-hidden="true"></span></summary>
        \\            <div class="pull-merge-method-popover" role="menu" aria-label="Merge methods">
        \\              <button class="pull-merge-method-option is-selected" type="submit" name="method" value="merge" role="menuitemradio" aria-checked="true" data-merge-button-label="Merge pull request"><span class="pull-merge-method-check" aria-hidden="true"></span><span><strong>Create a merge commit</strong><em>{commit_phrase} from this branch will be added to the base branch via a merge commit.</em></span></button>
        \\              <button class="pull-merge-method-option" type="submit" name="method" value="squash" role="menuitemradio" aria-checked="false" data-merge-button-label="Squash and merge"><span class="pull-merge-method-check" aria-hidden="true"></span><span><strong>Squash and merge</strong><em>{commit_phrase} from this branch will be added to the base branch.</em></span></button>
        \\              <button class="pull-merge-method-option" type="submit" name="method" value="rebase" role="menuitemradio" aria-checked="false" data-merge-button-label="Rebase and merge"><span class="pull-merge-method-check" aria-hidden="true"></span><span><strong>Rebase and merge</strong><em>{commit_phrase} from this branch will be rebased and added to the base branch.</em></span></button>
        \\            </div>
        \\          </details>
        \\        </div>
        \\        <span class="pull-merge-command-hint">You can also merge this with <code>gt pr merge #{pull_ref}</code> after applying the target branch update.</span>
        \\      </div>
        \\    </form>
        \\  </div>
        \\</div>
    , .{
        .commit_phrase = commit_phrase,
        .csrf_field = zwf.csrf.field_name,
        .csrf = csrf_token,
        .expected_base_oid = snapshot.expected_base_oid,
        .expected_head_oid = snapshot.expected_head_oid,
        .pull_ref = raw_ref,
    });
}

fn appendPullStatePill(buf: *std.ArrayList(u8), allocator: Allocator, state: []const u8, draft: bool) !void {
    if (draft and std.mem.eql(u8, state, "open")) {
        try buf.appendSlice(allocator, "<span class=\"state draft\">draft</span>");
        return;
    }
    try appendTemplate(buf, allocator, "<span class=\"state {state}\">{state}</span>", .{ .state = state });
}

fn appendLabel(buf: *std.ArrayList(u8), allocator: Allocator, label: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<span class="issue-label {kind}">{label}</span>
    , .{
        .kind = labelKind(label),
        .label = label,
    });
}

fn appendAvatar(buf: *std.ArrayList(u8), allocator: Allocator, name: []const u8, avatar_url: []const u8, extra_class: []const u8) !void {
    try shared.appendAvatarWithUrl(buf, allocator, name, avatar_url, extra_class);
}

fn appendLegacyPullLink(buf: *std.ArrayList(u8), allocator: Allocator, legacy_number: i64) !void {
    const pull_ref = try std.fmt.allocPrint(allocator, "{d}", .{legacy_number});
    defer allocator.free(pull_ref);
    try buf.appendSlice(allocator, "<a href=\"");
    try appendHref(buf, allocator, pullHref(pull_ref));
    try buf.appendSlice(allocator, "\">#");
    try shared.appendHtml(buf, allocator, pull_ref);
    try buf.appendSlice(allocator, "</a>");
}

fn labelKind(label: []const u8) []const u8 {
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

fn commitWord(count: usize) []const u8 {
    return if (count == 1) "commit" else "commits";
}

fn mergeMethodCommitPhrase(allocator: Allocator, count: ?usize) ![]u8 {
    if (count) |value| {
        return std.fmt.allocPrint(allocator, "The {d} {s}", .{ value, commitWord(value) });
    }
    return allocator.dupe(u8, "The commits");
}

pub fn handlePullConflictPost(allocator: Allocator, repo: Repo, stream: std.net.Stream, raw_ref: []const u8, csrf_token: []const u8, form_body: []const u8) !void {
    const fields = try parseFormFieldsOwned(allocator, form_body);
    defer freeFormFields(allocator, fields);
    const submitted_csrf = findFormField(fields, zwf.csrf.field_name) orelse "";
    if (!zwf.csrf.verify(csrf_token, submitted_csrf)) {
        try sendPlainResponse(allocator, stream, 403, "Forbidden", "Invalid CSRF token\n");
        return;
    }

    try index.ensureIndex(allocator, repo);
    const pull_id = index.resolvePullId(allocator, repo, raw_ref) catch {
        try sendPlainResponse(allocator, stream, 404, "Not Found", "Pull request not found\n");
        return;
    };
    defer allocator.free(pull_id);

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    const detail = (try work_items.loadPullDetail(allocator, &db, pull_id)) orelse {
        try sendPlainResponse(allocator, stream, 404, "Not Found", "Pull request not found\n");
        return;
    };
    defer detail.deinit(allocator);

    const merge_status = try pull_merge.loadStatus(allocator, repo, detail);
    defer merge_status.deinit(allocator);
    if (!merge_status.hasConflicts()) {
        try sendMergeEditorError(allocator, repo, stream, raw_ref, csrf_token, 409, "Conflict", "This pull request no longer reports merge conflicts.");
        return;
    }

    const conflict_files = merge_status.conflict_files orelse {
        try sendMergeEditorError(allocator, repo, stream, raw_ref, csrf_token, 409, "Conflict", "Git did not return the conflicting file list.");
        return;
    };

    const submitted_oids = submittedExpectedOids(fields) orelse {
        try sendMergeEditorError(allocator, repo, stream, raw_ref, csrf_token, 409, "Conflict", "The merge state was not confirmed. Refresh the page and try again.");
        return;
    };

    var resolved: std.ArrayList(ResolvedConflictFile) = .empty;
    defer resolved.deinit(allocator);
    for (conflict_files, 0..) |path, index_value| {
        const path_name = try std.fmt.allocPrint(allocator, "path_{d}", .{index_value});
        defer allocator.free(path_name);
        const content_name = try std.fmt.allocPrint(allocator, "content_{d}", .{index_value});
        defer allocator.free(content_name);

        const submitted_path = findFormField(fields, path_name) orelse {
            try sendMergeEditorError(allocator, repo, stream, raw_ref, csrf_token, 422, "Unprocessable Entity", "A conflict file path was missing from the submitted resolution.");
            return;
        };
        if (!std.mem.eql(u8, submitted_path, path)) {
            try sendMergeEditorError(allocator, repo, stream, raw_ref, csrf_token, 422, "Unprocessable Entity", "The submitted conflict file list did not match the current merge conflicts.");
            return;
        }

        const content = findFormField(fields, content_name) orelse {
            try sendMergeEditorError(allocator, repo, stream, raw_ref, csrf_token, 422, "Unprocessable Entity", "Every conflicting file must be editable before the web resolver can commit.");
            return;
        };
        if (contentHasConflictMarkers(content)) {
            try sendMergeEditorError(allocator, repo, stream, raw_ref, csrf_token, 422, "Unprocessable Entity", "Resolve every conflict marker before committing the resolution.");
            return;
        }
        try resolved.append(allocator, .{ .path = path, .content = content });
    }

    const snapshot = merge_status.snapshot orelse {
        try sendMergeEditorError(allocator, repo, stream, raw_ref, csrf_token, 409, "Conflict", "Git did not return the pull request refs.");
        return;
    };
    if (!submittedOidsMatchSnapshot(submitted_oids, snapshot)) {
        try sendMergeEditorError(allocator, repo, stream, raw_ref, csrf_token, 409, "Conflict", "The pull request changed after this page was rendered. Refresh and try again.");
        return;
    }

    const merge_commit = pull_merge.commitConflictResolution(allocator, repo, snapshot, raw_ref, resolved.items) catch |err| {
        const message = pull_merge.commitErrorMessage(err) orelse return err;
        try sendMergeEditorError(allocator, repo, stream, raw_ref, csrf_token, 422, "Unprocessable Entity", message);
        return;
    };
    defer allocator.free(merge_commit);

    const location = try std.fmt.allocPrint(allocator, "/pulls/{s}", .{raw_ref});
    defer allocator.free(location);
    try sendRedirect(allocator, stream, location);
}

pub fn handlePullMergePost(allocator: Allocator, repo: Repo, stream: std.net.Stream, raw_ref: []const u8, csrf_token: []const u8, form_body: []const u8) !void {
    const fields = try parseFormFieldsOwned(allocator, form_body);
    defer freeFormFields(allocator, fields);
    const submitted_csrf = findFormField(fields, zwf.csrf.field_name) orelse "";
    if (!zwf.csrf.verify(csrf_token, submitted_csrf)) {
        try sendPlainResponse(allocator, stream, 403, "Forbidden", "Invalid CSRF token\n");
        return;
    }

    try index.ensureIndex(allocator, repo);
    const pull_id = index.resolvePullId(allocator, repo, raw_ref) catch {
        try sendPlainResponse(allocator, stream, 404, "Not Found", "Pull request not found\n");
        return;
    };
    defer allocator.free(pull_id);

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    const detail = (try work_items.loadPullDetail(allocator, &db, pull_id)) orelse {
        try sendPlainResponse(allocator, stream, 404, "Not Found", "Pull request not found\n");
        return;
    };
    defer detail.deinit(allocator);

    if (!std.mem.eql(u8, detail.state, "open")) {
        try sendPullMergeError(allocator, repo, stream, raw_ref, csrf_token, 409, "Conflict", "Only open pull requests can be merged.");
        return;
    }
    if (detail.draft) {
        try sendPullMergeError(allocator, repo, stream, raw_ref, csrf_token, 409, "Conflict", "Draft pull requests cannot be merged.");
        return;
    }

    const method_value = std.mem.trim(u8, findFormField(fields, "method") orelse "merge", " \t\r\n");
    const method = pull_merge.methodFromValue(method_value) orelse {
        try sendPullMergeError(allocator, repo, stream, raw_ref, csrf_token, 422, "Unprocessable Entity", "Unknown merge method.");
        return;
    };
    const submitted_oids = submittedExpectedOids(fields) orelse {
        try sendPullMergeError(allocator, repo, stream, raw_ref, csrf_token, 409, "Conflict", "The merge state was not confirmed. Refresh the page and try again.");
        return;
    };

    const merge_status = try pull_merge.loadStatus(allocator, repo, detail);
    defer merge_status.deinit(allocator);
    if (merge_status.hasConflicts()) {
        try sendPullMergeError(allocator, repo, stream, raw_ref, csrf_token, 409, "Conflict", "Resolve merge conflicts before merging this pull request.");
        return;
    }
    if (merge_status.kind != .clean) {
        try sendPullMergeError(allocator, repo, stream, raw_ref, csrf_token, 409, "Conflict", "The local repository could not verify that this pull request can be merged cleanly.");
        return;
    }
    const snapshot = merge_status.snapshot orelse {
        try sendPullMergeError(allocator, repo, stream, raw_ref, csrf_token, 409, "Conflict", "The local repository could not resolve the confirmed merge refs.");
        return;
    };
    if (!submittedOidsMatchSnapshot(submitted_oids, snapshot)) {
        try sendPullMergeError(allocator, repo, stream, raw_ref, csrf_token, 409, "Conflict", "The pull request changed after this page was rendered. Refresh and try again.");
        return;
    }

    const merge_result = pull_merge.mergeIntoBase(allocator, repo, detail, raw_ref, snapshot, method) catch |err| {
        const message = pull_merge.mergeErrorMessage(err) orelse return err;
        try sendPullMergeError(allocator, repo, stream, raw_ref, csrf_token, 422, "Unprocessable Entity", message);
        return;
    };
    defer merge_result.deinit(allocator);

    pull.createPullMergedEventWithMetadata(allocator, pull_id, merge_result.merge_oid, merge_result.target_oid, .{
        .base_oid = snapshot.expected_base_oid,
        .head_oid = snapshot.expected_head_oid,
        .remote = snapshot.base_target.remote,
        .remote_ref = snapshot.base_target.remote_ref,
    }) catch {
        try sendPullMergeError(allocator, repo, stream, raw_ref, csrf_token, 500, "Internal Server Error", "The base branch was updated, but Gitomi could not record the pull.merged event.");
        return;
    };

    const location = try std.fmt.allocPrint(allocator, "/pulls/{s}", .{raw_ref});
    defer allocator.free(location);
    try sendRedirect(allocator, stream, location);
}

pub fn handlePullChecklistPost(allocator: Allocator, repo: Repo, stream: std.net.Stream, raw_ref: []const u8, form_body: []const u8) !void {
    try index.ensureIndex(allocator, repo);
    const pull_id = index.resolvePullId(allocator, repo, raw_ref) catch {
        try sendPlainResponse(allocator, stream, 404, "Not Found", "Pull request not found\n");
        return;
    };
    defer allocator.free(pull_id);

    const body_owned = (try shared.formValueOwned(allocator, form_body, "body")) orelse {
        try sendPlainResponse(allocator, stream, 400, "Bad Request", "Missing body\n");
        return;
    };
    defer allocator.free(body_owned);

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var stmt = try db.prepare("SELECT body, author_principal FROM pulls WHERE id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, pull_id);
    if (!(try stmt.step())) {
        try sendPlainResponse(allocator, stream, 404, "Not Found", "Pull request not found\n");
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

    pull.createPullUpdatedEvent(allocator, pull_id, .{ .body = body_owned }) catch {
        try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not update checklist\n");
        return;
    };
    try sendResponse(allocator, stream, 204, "No Content", "text/plain", "", null);
}

fn sendMergeEditorError(
    allocator: Allocator,
    repo: Repo,
    stream: std.net.Stream,
    raw_ref: []const u8,
    csrf_token: []const u8,
    status: u16,
    reason: []const u8,
    message: []const u8,
) !void {
    const target = try std.fmt.allocPrint(allocator, "/pulls/{s}/conflicts", .{raw_ref});
    defer allocator.free(target);
    const body = try renderPullMergeEditorPage(allocator, repo, raw_ref, target, csrf_token, message);
    defer allocator.free(body);
    try sendResponse(allocator, stream, status, reason, "text/html", body, null);
}

fn sendPullMergeError(
    allocator: Allocator,
    repo: Repo,
    stream: std.net.Stream,
    raw_ref: []const u8,
    csrf_token: []const u8,
    status: u16,
    reason: []const u8,
    message: []const u8,
) !void {
    const target = try std.fmt.allocPrint(allocator, "/pulls/{s}", .{raw_ref});
    defer allocator.free(target);
    const body = try renderPullDetailPageWithMergeError(allocator, repo, raw_ref, target, csrf_token, message);
    defer allocator.free(body);
    try sendResponse(allocator, stream, status, reason, "text/html", body, null);
}

pub fn handlePullCommentPost(allocator: Allocator, repo: Repo, stream: std.net.Stream, raw_ref: []const u8, form_body: []const u8) !void {
    const fields = try parseFormFieldsOwned(allocator, form_body);
    defer freeFormFields(allocator, fields);

    if (findFormField(fields, "action")) |raw_action| {
        const action = std.mem.trim(u8, raw_action, " \t\r\n");
        if (std.mem.eql(u8, action, "add-reaction") or std.mem.eql(u8, action, "remove-reaction")) {
            try index.ensureIndex(allocator, repo);
            const pull_id = index.resolvePullId(allocator, repo, raw_ref) catch {
                try sendPlainResponse(allocator, stream, 404, "Not Found", "Pull request not found\n");
                return;
            };
            defer allocator.free(pull_id);

            const raw_emoji = findFormField(fields, "emoji") orelse {
                try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Emoji is required\n");
                return;
            };
            const emoji = std.mem.trim(u8, raw_emoji, " \t\r\n");
            if (emoji.len == 0) {
                try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Emoji is required\n");
                return;
            }

            const target_kind = std.mem.trim(u8, findFormField(fields, "target_kind") orelse "pull", " \t\r\n");
            const add = std.mem.eql(u8, action, "add-reaction");
            if (std.mem.eql(u8, target_kind, "pull")) {
                createReactionEvent(allocator, "pull", pull_id, emoji, add) catch {
                    try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not update reaction\n");
                    return;
                };
            } else if (std.mem.eql(u8, target_kind, "comment")) {
                const target_ref = findFormField(fields, "target_ref") orelse {
                    try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Comment target is required\n");
                    return;
                };
                const comment_id = index.resolveCommentId(allocator, repo, target_ref) catch {
                    try sendPlainResponse(allocator, stream, 404, "Not Found", "Comment not found\n");
                    return;
                };
                defer allocator.free(comment_id);
                var parent = try index.commentParentInfo(allocator, repo, comment_id);
                defer parent.deinit();
                if (!std.mem.eql(u8, parent.parent_kind, "pull") or !std.mem.eql(u8, parent.parent_id, pull_id)) {
                    try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Comment is not in this pull request\n");
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

            const location = try std.fmt.allocPrint(allocator, "/pulls/{s}", .{raw_ref});
            defer allocator.free(location);
            try sendRedirect(allocator, stream, location);
            return;
        }
    }

    const body_value = findFormField(fields, "body") orelse "";
    const body = std.mem.trim(u8, body_value, " \t\r\n");
    if (body.len == 0) {
        try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Comment is required\n");
        return;
    }

    try index.ensureIndex(allocator, repo);
    const pull_id = index.resolvePullId(allocator, repo, raw_ref) catch {
        try sendPlainResponse(allocator, stream, 404, "Not Found", "Pull request not found\n");
        return;
    };
    defer allocator.free(pull_id);

    const reply_ref = std.mem.trim(u8, findFormField(fields, "reply_parent_ref") orelse "", " \t\r\n");
    if (reply_ref.len != 0) {
        const reply_parent_id = index.resolveCommentId(allocator, repo, reply_ref) catch {
            try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Reply target was not found\n");
            return;
        };
        defer allocator.free(reply_parent_id);
        var parent = try index.commentParentInfo(allocator, repo, reply_parent_id);
        defer parent.deinit();
        if (!std.mem.eql(u8, parent.parent_kind, "pull") or !std.mem.eql(u8, parent.parent_id, pull_id)) {
            try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Reply target is not in this pull request\n");
            return;
        }
        createCommentReplyEvent(allocator, "pull", pull_id, reply_parent_id, parent.add_hash, body_value) catch {
            try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not add the reply\n");
            return;
        };
    } else {
        const diff_context = parseDiffCommentContext(fields) catch {
            try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Diff comment target is invalid\n");
            return;
        };
        const comment_body_owned = if (diff_context) |context| try work_items.formatDiffCommentBody(allocator, context, body_value) else null;
        defer if (comment_body_owned) |value| allocator.free(value);
        const comment_body = comment_body_owned orelse body_value;

        createCommentAddedEvent(allocator, "pull", pull_id, comment_body) catch {
            try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not add the comment\n");
            return;
        };
    }

    const location = try std.fmt.allocPrint(allocator, "/pulls/{s}", .{raw_ref});
    defer allocator.free(location);
    try sendRedirect(allocator, stream, location);
}

pub fn handlePullNotificationPost(allocator: Allocator, repo: Repo, stream: std.net.Stream, raw_ref: []const u8, form_body: []const u8) !void {
    try notifications.handleNotificationPost("pull", index.resolvePullId, "/pulls", allocator, repo, stream, raw_ref, form_body);
}

pub fn handlePullSidebarPost(allocator: Allocator, repo: Repo, stream: std.net.Stream, raw_ref: []const u8, csrf_token: []const u8, form_body: []const u8) !void {
    try pull_sidebar.handlePullSidebarPost(allocator, repo, stream, raw_ref, csrf_token, form_body);
}

fn parseFormFieldsOwned(allocator: Allocator, body: []const u8) ![]FormField {
    var fields: std.ArrayList(FormField) = .empty;
    errdefer {
        for (fields.items) |field| field.deinit(allocator);
        fields.deinit(allocator);
    }

    var pairs = std.mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const raw_key = pair[0..eq];
        const raw_value = if (eq < pair.len) pair[eq + 1 ..] else "";
        const key = try shared.percentDecodeForm(allocator, raw_key);
        errdefer allocator.free(key);
        const value = try shared.percentDecodeForm(allocator, raw_value);
        errdefer allocator.free(value);
        try fields.append(allocator, .{ .name = key, .value = value });
    }
    return try fields.toOwnedSlice(allocator);
}

fn freeFormFields(allocator: Allocator, fields: []FormField) void {
    for (fields) |field| field.deinit(allocator);
    allocator.free(fields);
}

fn findFormField(fields: []const FormField, name: []const u8) ?[]const u8 {
    for (fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return field.value;
    }
    return null;
}

fn submittedExpectedOids(fields: []const FormField) ?SubmittedExpectedOids {
    const base = std.mem.trim(u8, findFormField(fields, "expected_base_oid") orelse return null, " \t\r\n");
    const head = std.mem.trim(u8, findFormField(fields, "expected_head_oid") orelse return null, " \t\r\n");
    if (!isFullGitOid(base) or !isFullGitOid(head)) return null;
    return .{ .base_oid = base, .head_oid = head };
}

fn submittedOidsMatchSnapshot(submitted: SubmittedExpectedOids, snapshot: PullMergeSnapshot) bool {
    return std.mem.eql(u8, submitted.base_oid, snapshot.expected_base_oid) and
        std.mem.eql(u8, submitted.head_oid, snapshot.expected_head_oid);
}

fn isFullGitOid(value: []const u8) bool {
    if (value.len != 40 and value.len != 64) return false;
    for (value) |c| {
        if (!((c >= '0' and c <= '9') or
            (c >= 'a' and c <= 'f') or
            (c >= 'A' and c <= 'F'))) return false;
    }
    return true;
}

fn parseDiffCommentContext(fields: []const FormField) !?DiffCommentContext {
    const raw_file = findFormField(fields, "diff_file");
    const raw_side = findFormField(fields, "diff_side");
    const raw_start = findFormField(fields, "diff_start");
    const raw_end = findFormField(fields, "diff_end");

    if (raw_file == null and raw_side == null and raw_start == null and raw_end == null) return null;
    if (raw_file == null or raw_side == null or raw_start == null or raw_end == null) return error.InvalidDiffCommentContext;

    const file = std.mem.trim(u8, raw_file.?, " \t\r\n");
    if (!work_items.validateDiffCommentPath(file)) return error.InvalidDiffCommentContext;

    const side_name = std.mem.trim(u8, raw_side.?, " \t\r\n");
    const side: DiffCommentSide = if (std.mem.eql(u8, side_name, "old"))
        .old
    else if (std.mem.eql(u8, side_name, "new"))
        .new
    else
        return error.InvalidDiffCommentContext;

    const start_line = parseDiffCommentLine(raw_start.?) orelse return error.InvalidDiffCommentContext;
    const end_line = parseDiffCommentLine(raw_end.?) orelse return error.InvalidDiffCommentContext;
    if (end_line < start_line) return error.InvalidDiffCommentContext;

    return .{
        .file = file,
        .side = side,
        .start_line = start_line,
        .end_line = end_line,
    };
}

fn parseDiffCommentLine(value: []const u8) ?usize {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;
    const parsed = std.fmt.parseUnsigned(usize, trimmed, 10) catch return null;
    return if (parsed == 0) null else parsed;
}

test "parse diff comment context from form fields" {
    const fields = try parseFormFieldsOwned(std.testing.allocator, "diff_file=cli%2Fsrc%2Fpulls.zig&diff_side=new&diff_start=139&diff_end=151");
    defer freeFormFields(std.testing.allocator, fields);

    const context = (try parseDiffCommentContext(fields)).?;
    try std.testing.expectEqualStrings("cli/src/pulls.zig", context.file);
    try std.testing.expectEqual(DiffCommentSide.new, context.side);
    try std.testing.expectEqual(@as(usize, 139), context.start_line);
    try std.testing.expectEqual(@as(usize, 151), context.end_line);
}

test "format diff comment body includes file and line range" {
    const body = try work_items.formatDiffCommentBody(std.testing.allocator, .{
        .file = "cli/src/pulls.zig",
        .side = .new,
        .start_line = 139,
        .end_line = 151,
    }, "Looks good.");
    defer std.testing.allocator.free(body);

    try std.testing.expectEqualStrings(
        "Review comment on `cli/src/pulls.zig` (new lines 139-151).\n\nLooks good.",
        body,
    );
}

test "pull merge form includes csrf token" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    var snapshot = PullMergeSnapshot{
        .expected_base_oid = try std.testing.allocator.dupe(u8, "1111111111111111111111111111111111111111"),
        .expected_head_oid = try std.testing.allocator.dupe(u8, "2222222222222222222222222222222222222222"),
        .base_target = .{
            .remote = try std.testing.allocator.dupe(u8, "origin"),
            .branch = try std.testing.allocator.dupe(u8, "main"),
            .remote_ref = try std.testing.allocator.dupe(u8, "refs/heads/main"),
            .tracking_ref = try std.testing.allocator.dupe(u8, "refs/remotes/origin/main"),
        },
    };
    defer snapshot.deinit(std.testing.allocator);

    try appendPullReadyToMergeTimeline(&buf, std.testing.allocator, "1", 1, snapshot, "token-123", null);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "name=\"_csrf\" value=\"token-123\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "name=\"expected_base_oid\" value=\"1111111111111111111111111111111111111111\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "name=\"expected_head_oid\" value=\"2222222222222222222222222222222222222222\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "action=\"/pulls/1/merge\"") != null);
}

test "submitted merge oids require full hex object ids" {
    const fields = try parseFormFieldsOwned(
        std.testing.allocator,
        "expected_base_oid=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa&expected_head_oid=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
    );
    defer freeFormFields(std.testing.allocator, fields);

    const submitted = submittedExpectedOids(fields).?;
    try std.testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", submitted.base_oid);
    try std.testing.expectEqualStrings("BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", submitted.head_oid);

    const short_fields = try parseFormFieldsOwned(
        std.testing.allocator,
        "expected_base_oid=abc&expected_head_oid=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
    );
    defer freeFormFields(std.testing.allocator, short_fields);
    try std.testing.expect(submittedExpectedOids(short_fields) == null);
}
