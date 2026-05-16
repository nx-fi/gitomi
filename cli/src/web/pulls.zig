const std = @import("std");
const comment_mod = @import("../comment.zig");
const event_mod = @import("../event.zig");
const git = @import("../git.zig");
const index = @import("../index.zig");
const diff_render = @import("diff_render.zig");
const issues_page = @import("issues.zig");
const merge_editor = @import("merge_editor.zig");
const pulls_list = @import("pulls_list.zig");
const pull = @import("../pr.zig");
const reaction_mod = @import("../reaction.zig");
const repo_mod = @import("../repo.zig");
const shared = @import("shared.zig");
const util = @import("../util.zig");
const work_items = @import("../work_items.zig");
const zwf = @import("../zwf.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const SqliteDb = index.SqliteDb;
const appendEmptyState = shared.appendEmptyState;
const appendHref = shared.appendHref;
const appendPill = shared.appendPill;
const appendSectionHead = shared.appendSectionHead;
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
const runCommand = git.runCommand;
const sendRedirect = shared.sendRedirect;
const sendPlainResponse = shared.sendPlainResponse;
const sendResponse = shared.sendResponse;
const sqlite = index.sqlite;

const max_pull_diff_bytes = work_items.max_pull_diff_bytes;

const PullDetailTab = enum {
    conversation,
    commits,
    files,
};

const ReactionChoice = struct {
    value: []const u8,
    label: []const u8,
    title: []const u8,
};

const ReactionSummary = struct {
    emoji: []u8,
    count: i64,
    reacted: bool,

    fn deinit(self: *ReactionSummary, allocator: Allocator) void {
        allocator.free(self.emoji);
    }
};

const reaction_choices = [_]ReactionChoice{
    .{ .value = "\xF0\x9F\x91\x8D", .label = "\xF0\x9F\x91\x8D", .title = "Thumbs up" },
    .{ .value = "\xF0\x9F\x91\x8E", .label = "\xF0\x9F\x91\x8E", .title = "Thumbs down" },
    .{ .value = "\xF0\x9F\x98\x84", .label = "\xF0\x9F\x98\x84", .title = "Laugh" },
    .{ .value = "\xF0\x9F\x8E\x89", .label = "\xF0\x9F\x8E\x89", .title = "Hooray" },
    .{ .value = "\xF0\x9F\x98\x95", .label = "\xF0\x9F\x98\x95", .title = "Confused" },
    .{ .value = "\xE2\x9D\xA4\xEF\xB8\x8F", .label = "\xE2\x9D\xA4\xEF\xB8\x8F", .title = "Heart" },
    .{ .value = "\xF0\x9F\x9A\x80", .label = "\xF0\x9F\x9A\x80", .title = "Rocket" },
    .{ .value = "\xF0\x9F\x91\x80", .label = "\xF0\x9F\x91\x80", .title = "Eyes" },
};

const PullDetail = work_items.PullDetail;

const PullTabCounts = struct {
    comments: usize = 0,
    commits: ?usize = null,
    files: ?usize = null,
    additions: ?usize = null,
    deletions: ?usize = null,
};

const PullGitRefs = work_items.PullGitRefs;
const PullMergeMethod = merge_editor.PullMergeMethod;
const PullMergeResult = merge_editor.PullMergeResult;
const PullMergeSnapshot = merge_editor.PullMergeSnapshot;
const PullMergeStatus = merge_editor.PullMergeStatus;
const RemoteBranchTarget = merge_editor.RemoteBranchTarget;
const ResolvedConflictFile = merge_editor.ResolvedConflictFile;
const contentHasConflictMarkers = merge_editor.contentHasConflictMarkers;
const isRegularGitMode = merge_editor.isRegularGitMode;
const isSafeMergePath = merge_editor.isSafeMergePath;
const tempPath = merge_editor.tempPath;
const writeFileBytes = merge_editor.writeFileBytes;

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

const PullCommit = struct {
    full_hash: []u8,
    short_hash: []u8,
    author: []u8,
    relative: []u8,
    subject: []u8,

    fn deinit(self: PullCommit, allocator: Allocator) void {
        allocator.free(self.full_hash);
        allocator.free(self.short_hash);
        allocator.free(self.author);
        allocator.free(self.relative);
        allocator.free(self.subject);
    }
};

pub const renderPullsPage = pulls_list.renderPullsPage;

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
    const merge_status = try loadPullMergeStatus(allocator, repo, detail);
    defer merge_status.deinit(allocator);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, detail.title, "pulls");
    try shared.appendDetailBackButton(&buf, allocator, shared.literalHref("/pulls"), "Back to pull requests");
    try buf.appendSlice(allocator, "<section class=\"pull-detail issue-page\">");
    try appendPullPageHeader(&buf, allocator, detail, pull_ref, tab_counts, merge_status);
    try appendPullTabs(&buf, allocator, pull_ref, tab, tab_counts);
    try appendTemplate(&buf, allocator,
        \\<div class="issue-conversation-layout pull-conversation-layout">
        \\  <div class="pull-tab-content">
    , .{});
    const current_actor = try shared.currentPrincipalOwned(allocator, repo);
    defer if (current_actor) |actor| allocator.free(actor);
    const current_role = if (current_actor) |actor| try index.effectiveWriteRoleForPrincipal(allocator, repo, actor) else null;
    defer if (current_role) |role| allocator.free(role);
    const can_edit_pull = currentActorCanEditAuthor(current_actor, current_role, detail.author_principal);
    switch (tab) {
        .conversation => try appendPullConversation(&buf, allocator, &db, detail, raw_ref, tab_counts, current_actor, can_edit_pull, merge_status, csrf_token, merge_error),
        .commits => try appendPullCommits(&buf, allocator, repo, detail),
        .files => try appendPullFiles(&buf, allocator, repo, detail, raw_ref),
    }
    try buf.appendSlice(allocator, "</div><aside class=\"issue-meta-sidebar pull-sidebar\">");
    try appendPullSidebar(&buf, allocator, repo, &db, detail, pull_ref);
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

pub fn renderPullMergeEditorPage(allocator: Allocator, repo: Repo, raw_ref: []const u8, target: []const u8, error_message: ?[]const u8) ![]u8 {
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

    const merge_status = try loadPullMergeStatus(allocator, repo, detail);
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

    try merge_editor.appendEditor(&buf, allocator, detail, raw_ref, pull_ref, snapshot, files, error_message);
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

    const git_counts = try loadPullGitTabCounts(allocator, repo, detail);
    if (git_counts.commits) |value| counts.commits = value;
    if (git_counts.files) |value| counts.files = value;
    return counts;
}

fn loadPullGitTabCounts(allocator: Allocator, repo: Repo, detail: PullDetail) !PullTabCounts {
    var counts: PullTabCounts = .{};
    const git_refs = (try work_items.loadPullGitRefs(allocator, repo, detail)) orelse return counts;
    defer git_refs.deinit(allocator);

    const merge_base = try work_items.loadMergeBase(allocator, repo, git_refs.base, git_refs.head);
    defer if (merge_base) |value| allocator.free(value);
    const base = merge_base orelse return counts;

    const range = try std.fmt.allocPrint(allocator, "{s}..{s}", .{ base, git_refs.head });
    defer allocator.free(range);
    if (try work_items.gitMaybe(allocator, repo, &.{ "rev-list", "--count", range }, 64 * 1024)) |raw_count| {
        defer allocator.free(raw_count);
        const trimmed = std.mem.trim(u8, raw_count, " \t\r\n");
        counts.commits = std.fmt.parseUnsigned(usize, trimmed, 10) catch null;
    }

    if (try work_items.gitMaybe(allocator, repo, &.{ "diff", "--name-only", "--find-renames", base, git_refs.head }, max_pull_diff_bytes)) |raw_files| {
        defer allocator.free(raw_files);
        var files: usize = 0;
        var lines = std.mem.splitScalar(u8, raw_files, '\n');
        while (lines.next()) |raw_line| {
            if (std.mem.trim(u8, raw_line, " \t\r\n").len != 0) files += 1;
        }
        counts.files = files;
    }

    return counts;
}

fn appendPullPageHeader(buf: *std.ArrayList(u8), allocator: Allocator, detail: PullDetail, pull_ref: []const u8, counts: PullTabCounts, merge_status: PullMergeStatus) !void {
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
    try buf.appendSlice(allocator,
        \\      <button class="issue-copy-button" type="button" disabled aria-label="Copy pull request link"><span class="button-icon icon-copy" aria-hidden="true"></span></button>
        \\    </div>
        \\  </div>
        \\  <div class="issue-status-line pull-status-line">
    );
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
    if (event_mod.roleAtLeast(role, "maintainer")) return true;
    const actor = current_actor orelse return false;
    return event_mod.roleAtLeast(role, "contributor") and std.mem.eql(u8, actor, author);
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
        try appendLocalMergeCheck(buf, allocator, repo, detail);
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

fn appendPullSidebar(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, db: *SqliteDb, detail: PullDetail, pull_ref: []const u8) !void {
    try appendPullSidebarPeopleSection(buf, allocator, db, "Reviewers", "Manage reviewers", "SELECT DISTINCT reviewer FROM pull_reviewers WHERE pull_id = ? ORDER BY reviewer", detail.id, "No reviewers");
    try appendPullSidebarPeopleSection(buf, allocator, db, "Assignees", "Manage assignees", "SELECT DISTINCT assignee FROM pull_assignees WHERE pull_id = ? ORDER BY assignee", detail.id, "No one assigned");
    try appendPullSidebarLabels(buf, allocator, db, detail.id);
    try appendPullSidebarEmptySection(buf, allocator, "Projects", "Manage projects", "No projects");
    try appendPullSidebarEmptySection(buf, allocator, "Milestone", "Set milestone", "No milestone");
    try appendPullSidebarDevelopment(buf, allocator, repo, detail, pull_ref);
    try appendPullSidebarNotifications(buf, allocator);
    try appendPullSidebarParticipants(buf, allocator, db, detail);
}

fn appendPullSidebarSectionStart(buf: *std.ArrayList(u8), allocator: Allocator, title: []const u8, menu_label: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<section class="issue-sidebar-section"><div class="issue-sidebar-heading"><h2>{title}</h2><button class="pull-sidebar-gear" type="button" disabled aria-label="{menu_label}" title="{menu_label}"><span class="issue-sidebar-menu-icon" aria-hidden="true"></span></button></div>
    , .{
        .title = title,
        .menu_label = menu_label,
    });
}

fn appendPullSidebarSectionEnd(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator, "</section>");
}

fn appendPullSidebarPeopleSection(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    title: []const u8,
    menu_label: []const u8,
    comptime sql_text: []const u8,
    pull_id: []const u8,
    empty_text: []const u8,
) !void {
    try appendPullSidebarSectionStart(buf, allocator, title, menu_label);
    var stmt = try db.prepare(sql_text);
    defer stmt.deinit();
    try stmt.bindText(1, pull_id);
    var shown = false;
    while (try stmt.step()) {
        const person = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(person);
        try appendPullSidebarPerson(buf, allocator, person);
        shown = true;
    }
    if (!shown) try appendTemplate(buf, allocator, "<p class=\"issue-sidebar-empty\">{empty_text}</p>", .{ .empty_text = empty_text });
    try appendPullSidebarSectionEnd(buf, allocator);
}

fn appendPullSidebarLabels(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, pull_id: []const u8) !void {
    try appendPullSidebarSectionStart(buf, allocator, "Labels", "Manage labels");
    var stmt = try db.prepare("SELECT DISTINCT label FROM pull_labels WHERE pull_id = ? ORDER BY label");
    defer stmt.deinit();
    try stmt.bindText(1, pull_id);
    var shown = false;
    while (try stmt.step()) {
        const label = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(label);
        if (!shown) {
            try buf.appendSlice(allocator, "<div class=\"issue-sidebar-labels\">");
            shown = true;
        }
        try appendLabel(buf, allocator, label);
    }
    if (shown) {
        try buf.appendSlice(allocator, "</div>");
    } else {
        try buf.appendSlice(allocator, "<p class=\"issue-sidebar-empty\">None yet</p>");
    }
    try appendPullSidebarSectionEnd(buf, allocator);
}

fn appendPullSidebarEmptySection(buf: *std.ArrayList(u8), allocator: Allocator, title: []const u8, menu_label: []const u8, empty_text: []const u8) !void {
    try appendPullSidebarSectionStart(buf, allocator, title, menu_label);
    try appendTemplate(buf, allocator, "<p class=\"issue-sidebar-empty\">{empty_text}</p>", .{ .empty_text = empty_text });
    try appendPullSidebarSectionEnd(buf, allocator);
}

fn appendPullSidebarDevelopment(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, detail: PullDetail, pull_ref: []const u8) !void {
    try appendPullSidebarSectionStart(buf, allocator, "Development", "Link development");
    try buf.appendSlice(allocator,
        \\<p class="issue-sidebar-empty">Successfully merging this pull request may close linked issues.</p>
        \\<div class="pull-sidebar-branches"><span><strong>Base</strong>
    );
    try appendPullBranchLink(buf, allocator, detail.base_ref);
    try buf.appendSlice(allocator, "</span><span><strong>Head</strong>");
    try appendPullBranchLink(buf, allocator, detail.head_ref);
    try buf.appendSlice(allocator, "</span></div>");
    if (detail.merge_oid.len != 0) {
        try appendTemplate(buf, allocator,
            \\<a class="issue-sidebar-link-row" href="{href}"><span class="issue-sidebar-row-kind">merge</span><code>{short_oid}</code></a>
        , .{
            .href = commitHref(detail.merge_oid),
            .short_oid = detail.merge_oid[0..@min(detail.merge_oid.len, 12)],
        });
    }
    if (detail.target_oid.len != 0) {
        try appendTemplate(buf, allocator,
            \\<a class="issue-sidebar-link-row" href="{href}"><span class="issue-sidebar-row-kind">target</span><code>{short_oid}</code></a>
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
    try appendTemplate(buf, allocator, "<p class=\"pull-sidebar-note\"><a href=\"/pulls/{pull_ref}\">/pulls/{pull_ref}</a></p>", .{ .pull_ref = pull_ref });
    try appendPullSidebarSectionEnd(buf, allocator);
}

fn appendPullSidebarNotifications(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try appendPullSidebarSectionStart(buf, allocator, "Notifications", "Customize notifications");
    try buf.appendSlice(allocator,
        \\<button class="button secondary issue-sidebar-full-button" type="button" disabled>Subscribe</button>
        \\<p class="issue-sidebar-empty">You're receiving notifications because you modified this pull request.</p>
    );
    try appendPullSidebarSectionEnd(buf, allocator);
}

fn appendPullSidebarParticipants(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, detail: PullDetail) !void {
    try appendPullSidebarSectionStart(buf, allocator, "Participants", "Manage participants");
    try buf.appendSlice(allocator, "<div class=\"issue-participants\">");
    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var keys = seen.keyIterator();
        while (keys.next()) |key| allocator.free(key.*);
        seen.deinit();
    }
    try appendPullSidebarParticipant(buf, allocator, &seen, pullDisplayAuthor(detail));
    try appendPullSidebarParticipantQuery(buf, allocator, db, &seen, "SELECT DISTINCT assignee FROM pull_assignees WHERE pull_id = ? ORDER BY assignee", detail.id);
    try appendPullSidebarParticipantQuery(buf, allocator, db, &seen, "SELECT DISTINCT reviewer FROM pull_reviewers WHERE pull_id = ? ORDER BY reviewer", detail.id);
    try buf.appendSlice(allocator, "</div>");
    try appendPullSidebarSectionEnd(buf, allocator);
}

fn appendPullSidebarParticipantQuery(
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
        try appendPullSidebarParticipant(buf, allocator, seen, person);
    }
}

fn appendPullSidebarParticipant(buf: *std.ArrayList(u8), allocator: Allocator, seen: *std.StringHashMap(void), person: []const u8) !void {
    if (person.len == 0 or seen.contains(person)) return;
    const key = try allocator.dupe(u8, person);
    errdefer allocator.free(key);
    try seen.put(key, {});
    try appendAvatar(buf, allocator, person, "");
}

fn appendPullSidebarPerson(buf: *std.ArrayList(u8), allocator: Allocator, name: []const u8) !void {
    try buf.appendSlice(allocator, "<div class=\"issue-sidebar-person\">");
    try appendAvatar(buf, allocator, name, "");
    try appendTemplate(buf, allocator, "<span>{name}</span></div>", .{ .name = name });
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
    try appendAvatar(buf, allocator, pullDisplayAuthor(detail), "issue-detail-avatar");
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
        try buf.appendSlice(allocator, "/checklist\"");
    }
    try buf.appendSlice(allocator, ">");
    if (detail.body.len == 0) {
        try buf.appendSlice(allocator, "<p class=\"muted\">No description provided.</p>");
    } else {
        try shared.appendMarkdownSource(buf, allocator, detail.body, .{});
    }
    try buf.appendSlice(allocator, "</div>");
    try appendPullReactionBar(buf, allocator, db, "pull", detail.id, raw_ref, "", current_actor);
    try buf.appendSlice(allocator, "</article></div>");
    try appendPullComments(buf, allocator, db, raw_ref, detail.id, current_actor);
    try appendPullMergeabilityTimeline(buf, allocator, detail, raw_ref, counts.commits, merge_status, csrf_token, merge_error);
    try appendPullResolutionTimeline(buf, allocator, detail);
    try appendPullCommentForm(buf, allocator, raw_ref, current_actor);
    try buf.appendSlice(allocator, "</div>");
}

fn appendPullComments(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    raw_ref: []const u8,
    pull_id: []const u8,
    current_actor: ?[]const u8,
) !void {
    var stmt = try work_items.prepareCommentsStmt(db, "pull", pull_id);
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

        try appendTemplate(buf, allocator,
            \\<div class="{classes}" id="{anchor}"><div class="issue-timeline-avatar">
        , .{
            .classes = shared.classes("issue-timeline-item", &.{shared.class("is-reply", row.isReply())}),
            .anchor = anchor,
        });
        try appendAvatar(buf, allocator, row.display_author, "issue-detail-avatar");
        try appendTemplate(buf, allocator,
            \\</div><article class="issue-comment-box comment-card"><header class="issue-comment-head"><div><strong>{author}</strong><span>commented
        , .{
            .author = row.display_author,
        });
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
        try appendPullReactionBar(buf, allocator, db, "comment", row.id, raw_ref, comment_ref_value, current_actor);
        try buf.appendSlice(allocator, "</article></div>");
    }
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

fn appendPullReactionBar(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    object_kind: []const u8,
    object_id: []const u8,
    raw_pull_ref: []const u8,
    target_ref: []const u8,
    current_actor: ?[]const u8,
) !void {
    var reactions: std.ArrayList(ReactionSummary) = .empty;
    defer {
        for (reactions.items) |*item| item.deinit(allocator);
        reactions.deinit(allocator);
    }

    try buf.appendSlice(allocator, "<div class=\"reaction-bar\">");
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

    try appendPullReactionPicker(buf, allocator, raw_pull_ref, object_kind, target_ref, reactions.items);
    for (reactions.items) |item| {
        try appendPullReactionButton(buf, allocator, raw_pull_ref, object_kind, target_ref, item.emoji, item.emoji, item.count, item.reacted);
    }
    try buf.appendSlice(allocator, "</div>");
}

fn appendPullReactionPicker(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_pull_ref: []const u8,
    object_kind: []const u8,
    target_ref: []const u8,
    reactions: []const ReactionSummary,
) !void {
    try buf.appendSlice(allocator,
        \\<details class="reaction-picker" data-popover-menu>
        \\  <summary class="reaction-add-button" aria-label="Add reaction" title="Add reaction"><span class="reaction-add-icon" aria-hidden="true"></span></summary>
        \\  <div class="reaction-popover" role="menu" aria-label="Add reaction">
    );
    for (reaction_choices) |choice| {
        try appendPullReactionChoiceButton(buf, allocator, raw_pull_ref, object_kind, target_ref, choice, pullReactionWasSelected(reactions, choice.value));
    }
    try buf.appendSlice(allocator, "</div></details>");
}

fn appendPullReactionChoiceButton(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_pull_ref: []const u8,
    object_kind: []const u8,
    target_ref: []const u8,
    choice: ReactionChoice,
    reacted: bool,
) !void {
    try appendPullReactionFormOpen(buf, allocator, raw_pull_ref, "reaction-choice-form", if (reacted) "remove-reaction" else "add-reaction", object_kind, target_ref, choice.value);
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

fn appendPullReactionButton(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_pull_ref: []const u8,
    object_kind: []const u8,
    target_ref: []const u8,
    emoji_value: []const u8,
    emoji_label: []const u8,
    count: i64,
    reacted: bool,
) !void {
    try appendPullReactionFormOpen(buf, allocator, raw_pull_ref, "reaction-form", if (reacted) "remove-reaction" else "add-reaction", object_kind, target_ref, emoji_value);
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

fn appendPullReactionFormOpen(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_pull_ref: []const u8,
    form_class: []const u8,
    action: []const u8,
    object_kind: []const u8,
    target_ref: []const u8,
    emoji_value: []const u8,
) !void {
    try appendTemplate(buf, allocator, "<form class=\"{form_class}\" method=\"post\" action=\"/pulls/", .{ .form_class = form_class });
    try shared.appendUrlEncoded(buf, allocator, raw_pull_ref);
    try appendTemplate(buf, allocator,
        \\/comments"><input type="hidden" name="action" value="{action}"><input type="hidden" name="target_kind" value="{object_kind}">
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

fn pullReactionWasSelected(reactions: []const ReactionSummary, emoji: []const u8) bool {
    for (reactions) |item| {
        if (std.mem.eql(u8, item.emoji, emoji)) return item.reacted;
    }
    return false;
}

fn appendPullCommentForm(buf: *std.ArrayList(u8), allocator: Allocator, raw_ref: []const u8, current_actor: ?[]const u8) !void {
    try buf.appendSlice(allocator,
        \\<div class="issue-timeline-item issue-comment-form-item">
        \\  <div class="issue-timeline-avatar">
    );
    try appendAvatar(buf, allocator, current_actor orelse "Current user", "issue-detail-avatar issue-comment-form-avatar");
    try buf.appendSlice(allocator,
        \\  </div>
        \\  <form class="issue-comment-box issue-comment-form" method="post" action="/pulls/
    );
    try shared.appendUrlEncoded(buf, allocator, raw_ref);
    try buf.appendSlice(allocator,
        \\/comments">
        \\  <input type="hidden" name="reply_parent_ref" value="" data-reply-parent-ref>
    );
    try shared.appendMarkdownEditor(buf, allocator, .{});
    try buf.appendSlice(allocator,
        \\  <div class="issue-comment-form-actions">
        \\    <button class="button primary" type="submit">Comment</button>
        \\  </div>
        \\</form>
        \\</div>
    );
}

fn appendPullCommits(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, detail: PullDetail) !void {
    const commits_opt = try loadPullCommits(allocator, repo, detail);
    const commits = commits_opt orelse {
        if (detail.commit_count) |count| {
            const hint = try pullGitDataFetchHint(allocator, detail);
            defer allocator.free(hint);
            const detail_text = try std.fmt.allocPrint(allocator, "GitHub reported {d} {s}. {s}", .{ count, commitWord(count), hint });
            defer allocator.free(detail_text);
            try appendEmptyState(buf, allocator, "Commit range unavailable.", detail_text);
        } else {
            try appendEmptyState(buf, allocator, "Commit range unavailable.", "Fetch or create the base and head refs locally to inspect this pull request.");
        }
        return;
    };
    defer freePullCommits(allocator, commits);
    if (commits.len == 0) {
        try appendEmptyState(buf, allocator, "No commits in this range.", "The head ref currently has no commits ahead of the merge base.");
        return;
    }
    try buf.appendSlice(allocator, "<section class=\"panel commits-panel\"><div class=\"commit-list\">");
    for (commits) |commit| {
        try appendTemplate(buf, allocator,
            \\<article class="commit-row pull-commit-row"><div><a class="commit-title" href="{href}">{subject}</a><p>{author} committed {relative}</p></div><code class="commit-sha">{short_hash}</code></article>
        , .{
            .href = commitHref(commit.full_hash),
            .subject = commit.subject,
            .author = commit.author,
            .relative = commit.relative,
            .short_hash = commit.short_hash,
        });
    }
    try buf.appendSlice(allocator, "</div></section>");
}

fn appendPullFiles(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, detail: PullDetail, raw_ref: []const u8) !void {
    const diff_opt = try work_items.loadPullDiff(allocator, repo, detail, 3);
    const diff = diff_opt orelse {
        if (detail.changed_files != null or detail.additions != null or detail.deletions != null) {
            const detail_text = try pullImportedFileSummary(allocator, detail);
            defer allocator.free(detail_text);
            try appendEmptyState(buf, allocator, "File changes unavailable.", detail_text);
        } else {
            try appendEmptyState(buf, allocator, "File changes unavailable.", "Fetch or create the base and head refs locally to inspect this pull request.");
        }
        return;
    };
    defer allocator.free(diff);
    try buf.appendSlice(allocator, "<section class=\"diff-section pull-diff-section\" data-diff-review-action=\"/pulls/");
    try shared.appendUrlEncoded(buf, allocator, raw_ref);
    try buf.appendSlice(allocator, "/comments\">");
    try diff_render.append(buf, allocator, diff, .{
        .empty_message = "The head ref currently has no patch ahead of the merge base.",
    });
    try buf.appendSlice(allocator, "</section>");
}

fn pullImportedFileSummary(allocator: Allocator, detail: PullDetail) ![]u8 {
    const file_count = detail.changed_files orelse 0;
    const additions = detail.additions orelse 0;
    const deletions = detail.deletions orelse 0;
    const hint = try pullGitDataFetchHint(allocator, detail);
    defer allocator.free(hint);
    if (detail.additions != null or detail.deletions != null) {
        return std.fmt.allocPrint(allocator, "GitHub reported {d} changed {s} with +{d} -{d}. {s}", .{ file_count, if (file_count == 1) "file" else "files", additions, deletions, hint });
    }
    return std.fmt.allocPrint(allocator, "GitHub reported {d} changed {s}. {s}", .{ file_count, if (file_count == 1) "file" else "files", hint });
}

fn pullGitDataFetchHint(allocator: Allocator, detail: PullDetail) ![]u8 {
    if (detail.legacy_number > 0) {
        return std.fmt.allocPrint(
            allocator,
            "Fetch the PR head with `git fetch origin pull/{d}/head:refs/remotes/origin/pr/{d}`, then reload this page.",
            .{ detail.legacy_number, detail.legacy_number },
        );
    }
    return allocator.dupe(u8, "Fetch or create the base and head refs locally, then reload this page.");
}

fn loadPullCommits(allocator: Allocator, repo: Repo, detail: PullDetail) !?[]PullCommit {
    const git_refs = (try work_items.loadPullGitRefs(allocator, repo, detail)) orelse return null;
    defer git_refs.deinit(allocator);

    const merge_base = try work_items.loadMergeBase(allocator, repo, git_refs.base, git_refs.head);
    defer if (merge_base) |value| allocator.free(value);
    const base = merge_base orelse return null;
    const range = try std.fmt.allocPrint(allocator, "{s}..{s}", .{ base, git_refs.head });
    defer allocator.free(range);
    const raw = try work_items.gitMaybe(allocator, repo, &.{ "log", "--reverse", "--format=%H%x00%h%x00%an%x00%cr%x00%s", range }, git.max_git_output) orelse return null;
    defer allocator.free(raw);

    var commits: std.ArrayList(PullCommit) = .empty;
    errdefer {
        for (commits.items) |commit| commit.deinit(allocator);
        commits.deinit(allocator);
    }
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (line.len == 0) continue;
        var cols = std.mem.splitScalar(u8, line, 0);
        try commits.append(allocator, .{
            .full_hash = try allocator.dupe(u8, cols.next() orelse ""),
            .short_hash = try allocator.dupe(u8, cols.next() orelse ""),
            .author = try allocator.dupe(u8, cols.next() orelse ""),
            .relative = try allocator.dupe(u8, cols.next() orelse ""),
            .subject = try allocator.dupe(u8, cols.next() orelse ""),
        });
    }
    return try commits.toOwnedSlice(allocator);
}

fn resolveGithubPullHeadCommit(allocator: Allocator, repo: Repo, number: i64) !?[]u8 {
    if (try resolveFormattedGithubPullRef(allocator, repo, "refs/remotes/origin/pr/{d}", number)) |oid| return oid;
    if (try resolveFormattedGithubPullRef(allocator, repo, "refs/remotes/origin/pull/{d}/head", number)) |oid| return oid;
    if (try resolveFormattedGithubPullRef(allocator, repo, "refs/pull/{d}/head", number)) |oid| return oid;
    if (try resolveFormattedGithubPullRef(allocator, repo, "refs/gitomi/github/pull/{d}/head", number)) |oid| return oid;
    return null;
}

fn resolveFormattedGithubPullRef(allocator: Allocator, repo: Repo, comptime pattern: []const u8, number: i64) !?[]u8 {
    const ref = try std.fmt.allocPrint(allocator, pattern, .{number});
    defer allocator.free(ref);
    return try resolveGitCommit(allocator, repo, ref);
}

fn resolveGitCommit(allocator: Allocator, repo: Repo, ref: []const u8) !?[]u8 {
    const commit_ref = try std.fmt.allocPrint(allocator, "{s}^{{commit}}", .{ref});
    defer allocator.free(commit_ref);
    const raw = try work_items.gitMaybe(allocator, repo, &.{ "rev-parse", "--verify", "--quiet", commit_ref }, 1024 * 1024) orelse return null;
    defer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

fn isBranchShorthand(ref: []const u8) bool {
    if (std.mem.startsWith(u8, ref, "refs/")) return false;
    if (std.mem.startsWith(u8, ref, "origin/")) return false;
    if (std.mem.eql(u8, ref, "HEAD")) return false;
    return isSafeLocalBranchName(ref);
}

fn isSafeLocalBranchName(ref: []const u8) bool {
    if (ref.len == 0) return false;
    if (std.mem.startsWith(u8, ref, "-")) return false;
    if (std.mem.endsWith(u8, ref, ".lock")) return false;
    if (std.mem.indexOf(u8, ref, "..") != null) return false;
    if (std.mem.indexOf(u8, ref, "//") != null) return false;
    if (std.mem.indexOf(u8, ref, "@{") != null) return false;
    if (std.mem.indexOfAny(u8, ref, " \t\r\n\x00:^~?*[\\") != null) return false;
    return true;
}

fn remoteBranchTargetForPullRef(allocator: Allocator, repo: Repo, ref: []const u8) !?RemoteBranchTarget {
    const heads_prefix = "refs/heads/";
    if (std.mem.startsWith(u8, ref, heads_prefix)) {
        return try remoteBranchTargetForBranch(allocator, repo, null, ref[heads_prefix.len..]);
    }

    const remotes_prefix = "refs/remotes/";
    if (std.mem.startsWith(u8, ref, remotes_prefix)) {
        const rest = ref[remotes_prefix.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        return try remoteBranchTargetForBranch(allocator, repo, rest[0..slash], rest[slash + 1 ..]);
    }

    if (std.mem.indexOfScalar(u8, ref, '/')) |slash| {
        const maybe_remote = ref[0..slash];
        const maybe_branch = ref[slash + 1 ..];
        if (try remoteExists(allocator, repo, maybe_remote)) {
            return try remoteBranchTargetForBranch(allocator, repo, maybe_remote, maybe_branch);
        }
    }

    if (!isBranchShorthand(ref)) return null;
    return try remoteBranchTargetForBranch(allocator, repo, null, ref);
}

fn remoteBranchTargetForBranch(allocator: Allocator, repo: Repo, remote_hint: ?[]const u8, branch: []const u8) !?RemoteBranchTarget {
    if (!isSafeLocalBranchName(branch)) return null;

    const remote = if (remote_hint) |hint|
        try configuredRemoteName(allocator, repo, hint)
    else
        try defaultRemoteForBranch(allocator, repo, branch);
    const owned_remote = remote orelse return null;
    errdefer allocator.free(owned_remote);

    const owned_branch = try allocator.dupe(u8, branch);
    errdefer allocator.free(owned_branch);
    const remote_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch});
    errdefer allocator.free(remote_ref);
    const tracking_ref = try std.fmt.allocPrint(allocator, "refs/remotes/{s}/{s}", .{ owned_remote, branch });
    errdefer allocator.free(tracking_ref);

    return .{
        .remote = owned_remote,
        .branch = owned_branch,
        .remote_ref = remote_ref,
        .tracking_ref = tracking_ref,
    };
}

fn defaultRemoteForBranch(allocator: Allocator, repo: Repo, branch: []const u8) !?[]u8 {
    const config_key = try std.fmt.allocPrint(allocator, "branch.{s}.remote", .{branch});
    defer allocator.free(config_key);
    if (try gitConfigValueAt(allocator, repo, config_key)) |remote| {
        errdefer allocator.free(remote);
        if (try remoteExists(allocator, repo, remote)) return remote;
        allocator.free(remote);
    }
    if (try remoteExists(allocator, repo, "origin")) return try allocator.dupe(u8, "origin");
    return try singleConfiguredRemote(allocator, repo);
}

fn configuredRemoteName(allocator: Allocator, repo: Repo, remote: []const u8) !?[]u8 {
    if (!isSafeRemoteName(remote)) return null;
    if (!(try remoteExists(allocator, repo, remote))) return null;
    return try allocator.dupe(u8, remote);
}

fn remoteExists(allocator: Allocator, repo: Repo, remote: []const u8) !bool {
    if (!isSafeRemoteName(remote)) return false;
    var result = try gitRunAt(allocator, repo.root, &.{ "remote", "get-url", "--push", remote }, 1024 * 1024);
    defer result.deinit();
    return result.exitCode() == 0 and std.mem.trim(u8, result.stdout, " \t\r\n").len != 0;
}

fn singleConfiguredRemote(allocator: Allocator, repo: Repo) !?[]u8 {
    const raw = try gitCheckedAt(allocator, repo.root, &.{"remote"}, 1024 * 1024);
    defer allocator.free(raw);

    var found: ?[]const u8 = null;
    var lines = std.mem.tokenizeScalar(u8, raw, '\n');
    while (lines.next()) |raw_line| {
        const remote = std.mem.trim(u8, raw_line, " \t\r\n");
        if (!isSafeRemoteName(remote)) continue;
        if (found != null) return null;
        found = remote;
    }
    return if (found) |remote| try allocator.dupe(u8, remote) else null;
}

fn isSafeRemoteName(remote: []const u8) bool {
    if (remote.len == 0 or std.mem.eql(u8, remote, ".")) return false;
    if (std.mem.startsWith(u8, remote, "-")) return false;
    if (std.mem.indexOf(u8, remote, "..") != null) return false;
    if (std.mem.indexOfAny(u8, remote, " \t\r\n\x00:^~?*[\\") != null) return false;
    return true;
}

fn gitConfigValueAt(allocator: Allocator, repo: Repo, key: []const u8) !?[]u8 {
    var result = try gitRunAt(allocator, repo.root, &.{ "config", "--get", key }, 512 * 1024);
    defer result.deinit();
    if (result.exitCode() != 0) return null;
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

fn fetchRemoteBranches(allocator: Allocator, repo: Repo, remote: []const u8) !void {
    var result = try gitRunAt(allocator, repo.root, &.{ "fetch", "--no-tags", remote }, git.max_git_output);
    defer result.deinit();
    if (result.exitCode() != 0) return error.RemoteFetchFailed;
}

fn loadPullMergeStatus(allocator: Allocator, repo: Repo, detail: PullDetail) !PullMergeStatus {
    if (!std.mem.eql(u8, detail.state, "open")) return .{ .kind = .unavailable };

    const snapshot = (loadPullMergeSnapshot(allocator, repo, detail) catch |err| switch (err) {
        error.RemoteFetchFailed => return .{ .kind = .unavailable },
        else => return err,
    }) orelse return .{ .kind = .unavailable };
    errdefer snapshot.deinit(allocator);

    const merge_base = try work_items.loadMergeBase(allocator, repo, snapshot.expected_base_oid, snapshot.expected_head_oid);
    defer if (merge_base) |value| allocator.free(value);
    if (merge_base == null) {
        snapshot.deinit(allocator);
        return .{ .kind = .unavailable };
    }

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{
        "git",
        "-C",
        repo.root,
        "merge-tree",
        "--write-tree",
        "--name-only",
        "--no-messages",
        "-z",
        snapshot.expected_base_oid,
        snapshot.expected_head_oid,
    });

    var result = try runCommand(allocator, argv.items, null, max_pull_diff_bytes);
    defer result.deinit();
    if (result.exitCode() == 0) return .{ .kind = .clean, .snapshot = snapshot };
    if (result.exitCode() != 1) {
        snapshot.deinit(allocator);
        return .{ .kind = .unavailable };
    }

    const conflict_files = try parseMergeTreeConflictFiles(allocator, result.stdout);
    errdefer freeConflictFiles(allocator, conflict_files);
    if (conflict_files.len == 0) {
        freeConflictFiles(allocator, conflict_files);
        snapshot.deinit(allocator);
        return .{ .kind = .unavailable };
    }
    return .{
        .kind = .conflicts,
        .conflict_files = conflict_files,
        .snapshot = snapshot,
    };
}

fn loadPullMergeSnapshot(allocator: Allocator, repo: Repo, detail: PullDetail) !?PullMergeSnapshot {
    var base_target = (try remoteBranchTargetForPullRef(allocator, repo, detail.base_ref)) orelse return null;
    var base_target_owned = true;
    defer if (base_target_owned) base_target.deinit(allocator);

    try fetchRemoteBranches(allocator, repo, base_target.remote);

    const head_target = try remoteBranchTargetForPullRef(allocator, repo, detail.head_ref);
    var head_target_owned = head_target != null;
    defer if (head_target_owned) if (head_target) |target| target.deinit(allocator);

    if (head_target) |target| {
        if (!std.mem.eql(u8, target.remote, base_target.remote)) {
            try fetchRemoteBranches(allocator, repo, target.remote);
        }
    }

    const base_oid = (try resolveGitCommit(allocator, repo, base_target.tracking_ref)) orelse return null;
    errdefer allocator.free(base_oid);

    const head_oid = (try resolvePullHeadForMergeSnapshot(allocator, repo, detail, head_target)) orelse {
        allocator.free(base_oid);
        return null;
    };
    errdefer allocator.free(head_oid);

    const snapshot = PullMergeSnapshot{
        .expected_base_oid = base_oid,
        .expected_head_oid = head_oid,
        .base_target = base_target,
        .head_target = head_target,
    };
    base_target_owned = false;
    head_target_owned = false;
    return snapshot;
}

fn resolvePullHeadForMergeSnapshot(allocator: Allocator, repo: Repo, detail: PullDetail, head_target: ?RemoteBranchTarget) !?[]u8 {
    if (detail.legacy_number > 0) {
        if (try resolveGithubPullHeadCommit(allocator, repo, detail.legacy_number)) |oid| return oid;
    }
    if (head_target) |target| {
        return try resolveGitCommit(allocator, repo, target.tracking_ref);
    }
    if (try localHeadRefName(allocator, detail.head_ref)) |local_head| {
        allocator.free(local_head);
        return null;
    }
    return try resolveGitCommit(allocator, repo, detail.head_ref);
}

fn parseMergeTreeConflictFiles(allocator: Allocator, raw: []const u8) ![][]u8 {
    var files: std.ArrayList([]u8) = .empty;
    errdefer {
        for (files.items) |file| allocator.free(file);
        files.deinit(allocator);
    }

    var parts = std.mem.splitScalar(u8, raw, 0);
    _ = parts.next();
    while (parts.next()) |raw_path| {
        const path = std.mem.trim(u8, raw_path, " \t\r\n");
        if (path.len == 0 or conflictFileAlreadyListed(files.items, path)) continue;
        const owned = try allocator.dupe(u8, path);
        files.append(allocator, owned) catch |err| {
            allocator.free(owned);
            return err;
        };
    }
    return try files.toOwnedSlice(allocator);
}

fn conflictFileAlreadyListed(files: []const []const u8, path: []const u8) bool {
    for (files) |file| {
        if (std.mem.eql(u8, file, path)) return true;
    }
    return false;
}

fn freeConflictFiles(allocator: Allocator, files: [][]u8) void {
    for (files) |file| allocator.free(file);
    allocator.free(files);
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

fn appendAvatar(buf: *std.ArrayList(u8), allocator: Allocator, name: []const u8, extra_class: []const u8) !void {
    try shared.appendAvatar(buf, allocator, name, extra_class);
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
        \\    <label>Body<textarea name="body" rows="8">{body_value}</textarea></label>
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
        .csrf_token = csrf_token,
        .title_value = title_value,
        .body_value = body_value,
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

    pull.createPullOpenedEvent(allocator, title, body_owned, base_ref, head_ref, draft) catch {
        const body = try renderPullForm(
            allocator,
            repo,
            csrf_token,
            "Could not create the pull request. Check that Gitomi is initialized and Git commit signing is configured.",
            title_owned,
            body_owned,
            base_owned,
            head_owned,
            draft,
        );
        defer allocator.free(body);
        try sendResponse(allocator, stream, 500, "Internal Server Error", "text/html", body, null);
        return;
    };

    try sendRedirect(allocator, stream, "/pulls");
}

pub fn handlePullConflictPost(allocator: Allocator, repo: Repo, stream: std.net.Stream, raw_ref: []const u8, form_body: []const u8) !void {
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

    const merge_status = try loadPullMergeStatus(allocator, repo, detail);
    defer merge_status.deinit(allocator);
    if (!merge_status.hasConflicts()) {
        try sendMergeEditorError(allocator, repo, stream, raw_ref, 409, "Conflict", "This pull request no longer reports merge conflicts.");
        return;
    }

    const conflict_files = merge_status.conflict_files orelse {
        try sendMergeEditorError(allocator, repo, stream, raw_ref, 409, "Conflict", "Git did not return the conflicting file list.");
        return;
    };

    const fields = try parseFormFieldsOwned(allocator, form_body);
    defer freeFormFields(allocator, fields);

    const submitted_oids = submittedExpectedOids(fields) orelse {
        try sendMergeEditorError(allocator, repo, stream, raw_ref, 409, "Conflict", "The merge state was not confirmed. Refresh the page and try again.");
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
            try sendMergeEditorError(allocator, repo, stream, raw_ref, 422, "Unprocessable Entity", "A conflict file path was missing from the submitted resolution.");
            return;
        };
        if (!std.mem.eql(u8, submitted_path, path)) {
            try sendMergeEditorError(allocator, repo, stream, raw_ref, 422, "Unprocessable Entity", "The submitted conflict file list did not match the current merge conflicts.");
            return;
        }

        const content = findFormField(fields, content_name) orelse {
            try sendMergeEditorError(allocator, repo, stream, raw_ref, 422, "Unprocessable Entity", "Every conflicting file must be editable before the web resolver can commit.");
            return;
        };
        if (contentHasConflictMarkers(content)) {
            try sendMergeEditorError(allocator, repo, stream, raw_ref, 422, "Unprocessable Entity", "Resolve every conflict marker before committing the resolution.");
            return;
        }
        try resolved.append(allocator, .{ .path = path, .content = content });
    }

    const snapshot = merge_status.snapshot orelse {
        try sendMergeEditorError(allocator, repo, stream, raw_ref, 409, "Conflict", "Git did not return the pull request refs.");
        return;
    };
    if (!submittedOidsMatchSnapshot(submitted_oids, snapshot)) {
        try sendMergeEditorError(allocator, repo, stream, raw_ref, 409, "Conflict", "The pull request changed after this page was rendered. Refresh and try again.");
        return;
    }

    const merge_commit = commitPullConflictResolution(allocator, repo, snapshot, raw_ref, resolved.items) catch |err| {
        const message = mergeCommitErrorMessage(err) orelse return err;
        try sendMergeEditorError(allocator, repo, stream, raw_ref, 422, "Unprocessable Entity", message);
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
    const method = pullMergeMethodFromValue(method_value) orelse {
        try sendPullMergeError(allocator, repo, stream, raw_ref, csrf_token, 422, "Unprocessable Entity", "Unknown merge method.");
        return;
    };
    const submitted_oids = submittedExpectedOids(fields) orelse {
        try sendPullMergeError(allocator, repo, stream, raw_ref, csrf_token, 409, "Conflict", "The merge state was not confirmed. Refresh the page and try again.");
        return;
    };

    const merge_status = try loadPullMergeStatus(allocator, repo, detail);
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

    const merge_result = mergePullIntoBase(allocator, repo, detail, raw_ref, snapshot, method) catch |err| {
        const message = pullMergeErrorMessage(err) orelse return err;
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

    const body_owned = (try issues_page.formValueOwned(allocator, form_body, "body")) orelse {
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
    status: u16,
    reason: []const u8,
    message: []const u8,
) !void {
    const target = try std.fmt.allocPrint(allocator, "/pulls/{s}/conflicts", .{raw_ref});
    defer allocator.free(target);
    const body = try renderPullMergeEditorPage(allocator, repo, raw_ref, target, message);
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

fn queryValueOwned(allocator: Allocator, target: []const u8, wanted_key: []const u8) !?[]u8 {
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var pairs = std.mem.splitScalar(u8, target[query_start + 1 ..], '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const raw_key = pair[0..eq];
        const raw_value = if (eq < pair.len) pair[eq + 1 ..] else "";
        const key = try issues_page.percentDecodeForm(allocator, raw_key);
        defer allocator.free(key);
        if (!std.mem.eql(u8, key, wanted_key)) continue;
        return try issues_page.percentDecodeForm(allocator, raw_value);
    }
    return null;
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
        const key = try issues_page.percentDecodeForm(allocator, raw_key);
        errdefer allocator.free(key);
        const value = try issues_page.percentDecodeForm(allocator, raw_value);
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

fn pullMergeMethodFromValue(value: []const u8) ?PullMergeMethod {
    if (std.mem.eql(u8, value, "merge") or std.mem.eql(u8, value, "merge_commit")) return .merge_commit;
    if (std.mem.eql(u8, value, "squash")) return .squash;
    if (std.mem.eql(u8, value, "rebase")) return .rebase;
    return null;
}

fn mergePullIntoBase(
    allocator: Allocator,
    repo: Repo,
    detail: PullDetail,
    raw_ref: []const u8,
    snapshot: PullMergeSnapshot,
    method: PullMergeMethod,
) !PullMergeResult {
    if (!(try mergeWouldBeClean(allocator, repo, snapshot.expected_base_oid, snapshot.expected_head_oid))) return error.MergeConflicts;

    const result = switch (method) {
        .merge_commit => try createMergeCommitOnBase(allocator, repo, detail, raw_ref, snapshot.expected_base_oid, snapshot.expected_head_oid),
        .squash => try createSquashCommitOnBase(allocator, repo, detail, raw_ref, snapshot.expected_base_oid, snapshot.expected_head_oid),
        .rebase => try rebasePullOntoBase(allocator, repo, snapshot.expected_base_oid, snapshot.expected_head_oid),
    };
    errdefer result.deinit(allocator);

    const target = result.merge_oid orelse result.target_oid orelse return error.MergeCommitFailed;
    if (!(try commitIsAncestorAt(allocator, repo, snapshot.expected_base_oid, target))) return error.NonFastForwardResult;
    try pushRemoteBranchWithLease(allocator, repo, snapshot.base_target, target, snapshot.expected_base_oid);
    return result;
}

fn mergeWouldBeClean(allocator: Allocator, repo: Repo, base_commit: []const u8, head_commit: []const u8) !bool {
    var result = try gitRunAt(allocator, repo.root, &.{ "merge-tree", "--write-tree", "--no-messages", base_commit, head_commit }, max_pull_diff_bytes);
    defer result.deinit();
    if (result.exitCode()) |code| {
        if (code == 0) return true;
        if (code == 1) return false;
    }
    return error.MergeStatusUnavailable;
}

fn createMergeCommitOnBase(
    allocator: Allocator,
    repo: Repo,
    detail: PullDetail,
    raw_ref: []const u8,
    old_base: []const u8,
    head_commit: []const u8,
) !PullMergeResult {
    const tmp_worktree = try tempPath(allocator, "gitomi-pr-merge");
    defer allocator.free(tmp_worktree);
    var worktree_created = false;
    defer cleanupTempWorktree(allocator, repo.root, tmp_worktree, &worktree_created);

    const worktree_add_raw = try gitCheckedAt(allocator, repo.root, &.{ "worktree", "add", "--detach", tmp_worktree, old_base }, git.max_git_output);
    allocator.free(worktree_add_raw);
    worktree_created = true;

    const message = try std.fmt.allocPrint(allocator, "Merge pull request #{s} from {s}", .{ raw_ref, detail.head_ref });
    defer allocator.free(message);
    var merge_result = try gitRunAt(allocator, tmp_worktree, &.{ "merge", "--no-ff", "-m", message, head_commit }, git.max_git_output);
    defer merge_result.deinit();
    if (merge_result.exitCode()) |code| {
        if (code != 0) return error.MergeFailed;
    } else {
        return error.MergeFailed;
    }

    const commit_oid = try tempWorktreeHead(allocator, tmp_worktree);
    errdefer allocator.free(commit_oid);
    if (std.mem.eql(u8, commit_oid, old_base)) {
        return .{ .target_oid = commit_oid };
    }
    return .{ .merge_oid = commit_oid };
}

fn createSquashCommitOnBase(
    allocator: Allocator,
    repo: Repo,
    detail: PullDetail,
    raw_ref: []const u8,
    old_base: []const u8,
    head_commit: []const u8,
) !PullMergeResult {
    const tmp_worktree = try tempPath(allocator, "gitomi-pr-squash");
    defer allocator.free(tmp_worktree);
    var worktree_created = false;
    defer cleanupTempWorktree(allocator, repo.root, tmp_worktree, &worktree_created);

    const worktree_add_raw = try gitCheckedAt(allocator, repo.root, &.{ "worktree", "add", "--detach", tmp_worktree, old_base }, git.max_git_output);
    allocator.free(worktree_add_raw);
    worktree_created = true;

    var merge_result = try gitRunAt(allocator, tmp_worktree, &.{ "merge", "--squash", "--no-commit", head_commit }, git.max_git_output);
    defer merge_result.deinit();
    if (merge_result.exitCode()) |code| {
        if (code != 0) return error.MergeFailed;
    } else {
        return error.MergeFailed;
    }

    if (try worktreeHasStagedChanges(allocator, tmp_worktree)) {
        const message = try std.fmt.allocPrint(allocator, "Squash merge pull request #{s} from {s}", .{ raw_ref, detail.head_ref });
        defer allocator.free(message);
        const commit_output = try gitCheckedAt(allocator, tmp_worktree, &.{ "commit", "-m", message }, git.max_git_output);
        allocator.free(commit_output);
    }

    const commit_oid = try tempWorktreeHead(allocator, tmp_worktree);
    errdefer allocator.free(commit_oid);
    return .{ .target_oid = commit_oid };
}

fn rebasePullOntoBase(
    allocator: Allocator,
    repo: Repo,
    old_base: []const u8,
    head_commit: []const u8,
) !PullMergeResult {
    const merge_base = try work_items.loadMergeBase(allocator, repo, old_base, head_commit);
    defer if (merge_base) |value| allocator.free(value);
    const base = merge_base orelse return error.MergeStatusUnavailable;

    const tmp_worktree = try tempPath(allocator, "gitomi-pr-rebase");
    defer allocator.free(tmp_worktree);
    var worktree_created = false;
    defer cleanupTempWorktree(allocator, repo.root, tmp_worktree, &worktree_created);

    const worktree_add_raw = try gitCheckedAt(allocator, repo.root, &.{ "worktree", "add", "--detach", tmp_worktree, head_commit }, git.max_git_output);
    allocator.free(worktree_add_raw);
    worktree_created = true;

    var rebase_result = try gitRunAt(allocator, tmp_worktree, &.{ "rebase", "--onto", old_base, base }, git.max_git_output);
    defer rebase_result.deinit();
    if (rebase_result.exitCode()) |code| {
        if (code != 0) return error.RebaseFailed;
    } else {
        return error.RebaseFailed;
    }

    const commit_oid = try tempWorktreeHead(allocator, tmp_worktree);
    errdefer allocator.free(commit_oid);
    return .{ .target_oid = commit_oid };
}

fn tempWorktreeHead(allocator: Allocator, tmp_worktree: []const u8) ![]u8 {
    const raw = try gitCheckedAt(allocator, tmp_worktree, &.{ "rev-parse", "HEAD" }, 1024 * 1024);
    defer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.MergeCommitFailed;
    return try allocator.dupe(u8, trimmed);
}

fn worktreeHasStagedChanges(allocator: Allocator, tmp_worktree: []const u8) !bool {
    var diff_result = try gitRunAt(allocator, tmp_worktree, &.{ "diff", "--cached", "--quiet" }, 1024 * 1024);
    defer diff_result.deinit();
    if (diff_result.exitCode()) |code| {
        if (code == 0) return false;
        if (code == 1) return true;
    }
    return error.GitFailed;
}

fn commitIsAncestorAt(allocator: Allocator, repo: Repo, ancestor: []const u8, descendant: []const u8) !bool {
    var result = try gitRunAt(allocator, repo.root, &.{ "merge-base", "--is-ancestor", ancestor, descendant }, git.max_git_output);
    defer result.deinit();
    if (result.exitCode()) |code| {
        if (code == 0) return true;
        if (code == 1) return false;
    }
    return error.GitFailed;
}

fn pushRemoteBranchWithLease(allocator: Allocator, repo: Repo, target: RemoteBranchTarget, new_oid: []const u8, expected_oid: []const u8) !void {
    const lease = try std.fmt.allocPrint(allocator, "--force-with-lease={s}:{s}", .{ target.remote_ref, expected_oid });
    defer allocator.free(lease);
    const refspec = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ new_oid, target.remote_ref });
    defer allocator.free(refspec);
    const push_output = gitCheckedAt(allocator, repo.root, &.{ "push", target.remote, lease, refspec }, git.max_git_output) catch |err| switch (err) {
        error.GitFailed => return error.RemoteBranchUpdateFailed,
        else => return err,
    };
    allocator.free(push_output);
}

fn cleanupTempWorktree(allocator: Allocator, repo_root: []const u8, tmp_worktree: []const u8, worktree_created: *bool) void {
    if (worktree_created.*) {
        var remove_result = gitRunAt(allocator, repo_root, &.{ "worktree", "remove", "--force", tmp_worktree }, 1024 * 1024) catch null;
        if (remove_result) |*result| result.deinit();
    }
    std.fs.deleteTreeAbsolute(tmp_worktree) catch {};
}

fn pullMergeErrorMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.NoLocalBaseBranch => "The pull request base must be available on a configured remote before the web UI can merge it.",
        error.NoPullHeadCommit => "The pull request head commit is not available in the local repository.",
        error.MergeStatusUnavailable => "The local repository could not verify mergeability for this pull request.",
        error.MergeConflicts => "This pull request has conflicts with the current base branch.",
        error.MergeFailed => "Git could not merge this pull request into a temporary worktree.",
        error.RebaseFailed => "Git could not rebase this pull request onto the base branch.",
        error.MergeCommitFailed => "Git could not identify the merged target commit.",
        error.NonFastForwardResult => "The selected merge method did not produce a fast-forward result for the confirmed base.",
        error.BaseUpdateFailed, error.RemoteBranchUpdateFailed => "Git could not update the remote base branch. It may have changed while the merge was running.",
        error.GitFailed => "Git could not complete the merge. Check the repository state and commit signing configuration.",
        else => null,
    };
}

fn commitPullConflictResolution(
    allocator: Allocator,
    repo: Repo,
    snapshot: PullMergeSnapshot,
    raw_ref: []const u8,
    resolved_files: []const ResolvedConflictFile,
) ![]u8 {
    if (resolved_files.len == 0) return error.NoConflictResolutions;
    const head_target = snapshot.head_target orelse return error.NoRemoteHeadBranch;

    const tmp_worktree = try tempPath(allocator, "gitomi-merge-worktree");
    defer allocator.free(tmp_worktree);
    var worktree_created = false;
    defer {
        if (worktree_created) {
            var remove_result = gitRunAt(allocator, repo.root, &.{ "worktree", "remove", "--force", tmp_worktree }, 1024 * 1024) catch null;
            if (remove_result) |*result| result.deinit();
        }
        std.fs.deleteTreeAbsolute(tmp_worktree) catch {};
    }

    const worktree_add_raw = try gitCheckedAt(allocator, repo.root, &.{ "worktree", "add", "--detach", tmp_worktree, snapshot.expected_head_oid }, git.max_git_output);
    allocator.free(worktree_add_raw);
    worktree_created = true;

    var merge_result = try gitRunAt(allocator, tmp_worktree, &.{ "merge", "--no-ff", "--no-commit", snapshot.expected_base_oid }, git.max_git_output);
    defer merge_result.deinit();
    if (merge_result.exitCode()) |code| {
        if (code != 0 and code != 1) return error.MergePreparationFailed;
    } else {
        return error.MergePreparationFailed;
    }

    for (resolved_files) |file| {
        if (!isSafeMergePath(file.path)) return error.UnsafeConflictPath;
        const conflict_path_is_regular = try worktreeConflictPathIsRegularFile(allocator, tmp_worktree, file.path);
        if (!conflict_path_is_regular) return error.UnsafeConflictPath;
        const absolute_path = try std.fs.path.join(allocator, &.{ tmp_worktree, file.path });
        defer allocator.free(absolute_path);
        try writeFileBytes(absolute_path, file.content);
        const add_raw = try gitCheckedAt(allocator, tmp_worktree, &.{ "add", "--", file.path }, git.max_git_output);
        allocator.free(add_raw);
    }

    const unmerged_raw = try gitCheckedAt(allocator, tmp_worktree, &.{ "diff", "--name-only", "--diff-filter=U" }, git.max_git_output);
    defer allocator.free(unmerged_raw);
    if (std.mem.trim(u8, unmerged_raw, " \t\r\n").len != 0) return error.UnresolvedConflicts;

    const message = try std.fmt.allocPrint(allocator, "Resolve merge conflicts for PR {s}", .{raw_ref});
    defer allocator.free(message);
    const commit_output = try gitCheckedAt(allocator, tmp_worktree, &.{ "commit", "-m", message }, git.max_git_output);
    allocator.free(commit_output);

    const commit_raw = try gitCheckedAt(allocator, tmp_worktree, &.{ "rev-parse", "HEAD" }, 1024 * 1024);
    defer allocator.free(commit_raw);
    const commit_oid = try allocator.dupe(u8, std.mem.trim(u8, commit_raw, " \t\r\n"));
    errdefer allocator.free(commit_oid);
    if (commit_oid.len == 0) return error.MergeCommitFailed;

    try pushRemoteBranchWithLease(allocator, repo, head_target, commit_oid, snapshot.expected_head_oid);
    return commit_oid;
}

fn worktreeConflictPathIsRegularFile(allocator: Allocator, worktree: []const u8, path: []const u8) !bool {
    const raw = try gitCheckedAt(allocator, worktree, &.{ "ls-files", "-s", "-z", "--", path }, git.max_git_output);
    defer allocator.free(raw);
    return lsFilesStagesAreRegularFile(raw, path);
}

fn lsFilesStagesAreRegularFile(raw: []const u8, path: []const u8) bool {
    var found = false;
    var records = std.mem.splitScalar(u8, raw, 0);
    while (records.next()) |record| {
        if (record.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, record, '\t') orelse return false;
        if (!std.mem.eql(u8, record[tab + 1 ..], path)) return false;
        const space = std.mem.indexOfScalar(u8, record[0..tab], ' ') orelse return false;
        if (!isRegularGitMode(record[0..space])) return false;
        found = true;
    }
    return found;
}

fn localHeadRefName(allocator: Allocator, head_ref: []const u8) !?[]u8 {
    const heads_prefix = "refs/heads/";
    if (std.mem.startsWith(u8, head_ref, heads_prefix)) {
        const branch_name = head_ref[heads_prefix.len..];
        if (!isSafeLocalBranchName(branch_name)) return null;
        return try allocator.dupe(u8, head_ref);
    }
    if (!isBranchShorthand(head_ref)) return null;
    return try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{head_ref});
}

fn mergeCommitErrorMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.NoLocalHeadBranch, error.NoRemoteHeadBranch => "The pull request head must be a writable branch on the configured remote before the web resolver can update it.",
        error.NoConflictResolutions => "No conflict resolutions were submitted.",
        error.PullHeadChanged => "The local pull request head no longer matches the conflicts shown by the web resolver. Refresh the page and try again.",
        error.UnsafeConflictPath => "A conflicting path is not safe to write from the web resolver.",
        error.MergePreparationFailed => "Git could not prepare a merge worktree for this pull request.",
        error.UnresolvedConflicts => "Git still reports unresolved conflicts after applying the submitted files.",
        error.MergeCommitFailed => "Git could not create the merge-resolution commit.",
        error.RemoteBranchUpdateFailed => "Git could not update the remote pull request branch. It may have changed while the resolution was being committed.",
        error.GitFailed => "Git could not commit the resolution. Check the repository state and signing configuration.",
        else => null,
    };
}

fn gitRunAt(allocator: Allocator, root: []const u8, git_args: []const []const u8, max_output_bytes: usize) !git.RunOutput {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    try argv.append(allocator, "-C");
    try argv.append(allocator, root);
    for (git_args) |arg| try argv.append(allocator, arg);
    return runCommand(allocator, argv.items, null, max_output_bytes);
}

fn gitCheckedAt(allocator: Allocator, root: []const u8, git_args: []const []const u8, max_output_bytes: usize) ![]u8 {
    var result = try gitRunAt(allocator, root, git_args, max_output_bytes);
    if (result.exitCode() == 0) {
        const stdout = result.stdout;
        allocator.free(result.stderr);
        return stdout;
    }
    result.deinit();
    return error.GitFailed;
}

fn freePullCommits(allocator: Allocator, commits: []PullCommit) void {
    for (commits) |commit| commit.deinit(allocator);
    allocator.free(commits);
}

test "parse merge-tree conflict file names" {
    const raw = "b8424e5199eed14e5e0c4fa9a3668f146ef44ae9\x00cli/src/github.zig\x00cli/src/sync.zig\x00";
    const files = try parseMergeTreeConflictFiles(std.testing.allocator, raw);
    defer freeConflictFiles(std.testing.allocator, files);

    try std.testing.expectEqual(@as(usize, 2), files.len);
    try std.testing.expectEqualStrings("cli/src/github.zig", files[0]);
    try std.testing.expectEqualStrings("cli/src/sync.zig", files[1]);
}

test "parse merge-tree conflict file names skips duplicates and empty records" {
    const raw = "tree\x00a.zig\x00\x00a.zig\x00b.zig\x00";
    const files = try parseMergeTreeConflictFiles(std.testing.allocator, raw);
    defer freeConflictFiles(std.testing.allocator, files);

    try std.testing.expectEqual(@as(usize, 2), files.len);
    try std.testing.expectEqualStrings("a.zig", files[0]);
    try std.testing.expectEqualStrings("b.zig", files[1]);
}

test "parse merge-tree conflict file names returns empty for git errors without paths" {
    const files = try parseMergeTreeConflictFiles(std.testing.allocator, "");
    defer freeConflictFiles(std.testing.allocator, files);

    try std.testing.expectEqual(@as(usize, 0), files.len);
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

test "content conflict marker detection" {
    try std.testing.expect(contentHasConflictMarkers("a\n<<<<<<< head\nb\n=======\nc\n>>>>>>> main\n"));
    try std.testing.expect(!contentHasConflictMarkers("const divider = \"=======\";\n"));
}

test "pull merge method parser" {
    try std.testing.expectEqual(PullMergeMethod.merge_commit, pullMergeMethodFromValue("merge").?);
    try std.testing.expectEqual(PullMergeMethod.merge_commit, pullMergeMethodFromValue("merge_commit").?);
    try std.testing.expectEqual(PullMergeMethod.squash, pullMergeMethodFromValue("squash").?);
    try std.testing.expectEqual(PullMergeMethod.rebase, pullMergeMethodFromValue("rebase").?);
    try std.testing.expect(pullMergeMethodFromValue("fast-forward") == null);
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

test "merge editor rejects symlink conflict index stages" {
    try std.testing.expect(lsFilesStagesAreRegularFile(
        "100644 abcdef 1\tconflict.txt\x00100755 abcdef 2\tconflict.txt\x00100644 abcdef 3\tconflict.txt\x00",
        "conflict.txt",
    ));
    try std.testing.expect(!lsFilesStagesAreRegularFile(
        "100644 abcdef 1\tconflict.txt\x00120000 abcdef 2\tconflict.txt\x00100644 abcdef 3\tconflict.txt\x00",
        "conflict.txt",
    ));
    try std.testing.expect(!lsFilesStagesAreRegularFile("", "conflict.txt"));
}

test "merge resolver derives local head refs only from safe branch names" {
    const shorthand = (try localHeadRefName(std.testing.allocator, "feature/conflict-fix")).?;
    defer std.testing.allocator.free(shorthand);
    try std.testing.expectEqualStrings("refs/heads/feature/conflict-fix", shorthand);

    const full = (try localHeadRefName(std.testing.allocator, "refs/heads/origin/feature")).?;
    defer std.testing.allocator.free(full);
    try std.testing.expectEqualStrings("refs/heads/origin/feature", full);

    try std.testing.expect((try localHeadRefName(std.testing.allocator, "origin/feature")) == null);
    try std.testing.expect((try localHeadRefName(std.testing.allocator, "refs/remotes/origin/feature")) == null);
    try std.testing.expect((try localHeadRefName(std.testing.allocator, "HEAD")) == null);
    try std.testing.expect((try localHeadRefName(std.testing.allocator, "feature^{commit}")) == null);
}
