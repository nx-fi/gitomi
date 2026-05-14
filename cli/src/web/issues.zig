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
const appendSectionHead = shared.appendSectionHead;
const appendShellEnd = shared.appendShellEnd;
const appendShellStart = shared.appendShellStart;
const appendTemplate = shared.appendTemplate;
const createIssueOpenedEvent = issue.createIssueOpenedEvent;
const ensureIndex = index.ensureIndex;
const issueHref = shared.issueHref;
const sendRedirect = shared.sendRedirect;
const sendResponse = shared.sendResponse;
const splitCommaFields = util.splitCommaFields;
const sqlite = index.sqlite;

const IssueStateFilter = enum {
    open,
    closed,
    all,
};

const IssueCounts = struct {
    open: usize = 0,
    closed: usize = 0,
    all: usize = 0,
};

pub fn renderIssuesPage(allocator: Allocator, repo: Repo, target: []const u8) ![]u8 {
    if (try shared.renderIndexingPageIfStale(allocator, repo, "Issues", "issues", target)) |body| return body;
    try ensureIndex(allocator, repo);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    const requested_filter = try issueStateFilterFromTarget(allocator, target);
    const counts = try loadIssueCounts(&db);
    const filter = requested_filter orelse if (counts.open == 0 and counts.closed > 0) IssueStateFilter.closed else IssueStateFilter.open;

    try appendShellStart(&buf, allocator, repo, "Issues", "issues");
    try appendIssuesToolbar(&buf, allocator, filter);
    try buf.appendSlice(allocator, "<section class=\"panel issues-panel\">");
    try appendIssuesListHeader(&buf, allocator, filter, counts);

    var stmt = try db.prepare(issueListSql(filter));
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
        const state_at = try stmt.columnTextDup(allocator, 5);
        defer allocator.free(state_at);
        const milestone = try stmt.columnTextDup(allocator, 6);
        defer allocator.free(milestone);
        const comment_count = @as(usize, @intCast(stmt.columnInt64(7)));
        const legacy_number = stmt.columnInt64(8);

        try appendIssueListRow(&buf, allocator, &db, id, title, state, author, opened_at, state_at, milestone, comment_count, legacy_number);
        shown += 1;
    }

    if (shown == 0) {
        switch (filter) {
            .open => try appendEmptyState(&buf, allocator, "No open issues.", "Closed issues are available from the Closed tab."),
            .closed => try appendEmptyState(&buf, allocator, "No closed issues.", "Open issues are available from the Open tab."),
            .all => try appendEmptyState(&buf, allocator, "No issues yet.", "Create the first local issue from this browser UI or with gt issue open."),
        }
    }

    try buf.appendSlice(allocator, "</section>");
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn issueStateFilterFromTarget(allocator: Allocator, target: []const u8) !?IssueStateFilter {
    const state_value = try queryValueOwned(allocator, target, "state");
    defer if (state_value) |value| allocator.free(value);
    const value = state_value orelse return null;
    if (std.mem.eql(u8, value, "open")) return .open;
    if (std.mem.eql(u8, value, "closed")) return .closed;
    if (std.mem.eql(u8, value, "all")) return .all;
    return null;
}

fn issueListSql(filter: IssueStateFilter) []const u8 {
    const select =
        \\SELECT i.id, i.title, i.state,
        \\       COALESCE(NULLIF(m.source_author, ''), i.author_principal),
        \\       i.opened_at, i.state_occurred_at, COALESCE(m.milestone, ''),
        \\       (SELECT COUNT(*) FROM comments c WHERE c.parent_kind = 'issue' AND c.parent_id = i.id),
        \\       COALESCE(a.number, 0)
        \\FROM issues i
        \\LEFT JOIN issue_metadata m ON m.issue_id = i.id
        \\LEFT JOIN legacy_aliases a
        \\  ON a.provider = 'github' AND a.object_kind = 'issue' AND a.object_id = i.id
    ;
    return switch (filter) {
        .open => select ++
            \\ WHERE i.state = 'open'
            \\ ORDER BY i.opened_at DESC, i.id DESC
        ,
        .closed => select ++
            \\ WHERE i.state = 'closed'
            \\ ORDER BY i.state_occurred_at DESC, i.opened_at DESC, i.id DESC
        ,
        .all => select ++
            \\ ORDER BY i.state_occurred_at DESC, i.opened_at DESC, i.id DESC
        ,
    };
}

fn loadIssueCounts(db: *SqliteDb) !IssueCounts {
    var counts: IssueCounts = .{};
    var stmt = try db.prepare("SELECT state, COUNT(*) FROM issues GROUP BY state");
    defer stmt.deinit();
    while (try stmt.step()) {
        const state = try stmt.columnTextDup(db.allocator, 0);
        defer db.allocator.free(state);
        const count = @as(usize, @intCast(stmt.columnInt64(1)));
        counts.all += count;
        if (std.mem.eql(u8, state, "open")) {
            counts.open = count;
        } else if (std.mem.eql(u8, state, "closed")) {
            counts.closed = count;
        }
    }
    return counts;
}

fn appendIssuesToolbar(buf: *std.ArrayList(u8), allocator: Allocator, filter: IssueStateFilter) !void {
    try appendTemplate(buf, allocator,
        \\<div class="issues-toolbar">
        \\  <form class="issues-search" action="/issues" method="get">
        \\    <span class="issues-search-icon" aria-hidden="true"></span>
        \\    <input type="search" name="q" value="{query}" aria-label="Search issues">
        \\    <input type="hidden" name="state" value="{state}">
        \\  </form>
        \\  <div class="issues-toolbar-actions">
        \\    <button class="button secondary issue-tool-button" type="button" disabled><span class="button-icon icon-labels" aria-hidden="true"></span><span>Labels</span></button>
        \\    <button class="button secondary issue-tool-button" type="button" disabled><span class="button-icon icon-milestones" aria-hidden="true"></span><span>Milestones</span></button>
        \\    <a class="button primary" href="/new-issue">New issue</a>
        \\  </div>
        \\</div>
    , .{
        .query = issueSearchQuery(filter),
        .state = issueStateValue(filter),
    });
}

fn appendIssuesListHeader(buf: *std.ArrayList(u8), allocator: Allocator, filter: IssueStateFilter, counts: IssueCounts) !void {
    try buf.appendSlice(allocator,
        \\<header class="issues-list-head">
        \\  <div class="issues-select-all"><input type="checkbox" aria-label="Select all issues" disabled></div>
        \\  <nav class="issues-state-tabs" aria-label="Issue state">
    );
    try appendIssueStateTab(buf, allocator, "Open", counts.open, .open, filter, "issue-open-icon");
    try appendIssueStateTab(buf, allocator, "Closed", counts.closed, .closed, filter, "issue-closed-icon");
    try buf.appendSlice(allocator,
        \\  </nav>
        \\  <div class="issues-filter-menus">
        \\    <button type="button" disabled>Author</button>
        \\    <button type="button" disabled>Labels</button>
        \\    <button type="button" disabled>Projects</button>
        \\    <button type="button" disabled>Milestones</button>
        \\    <button type="button" disabled>Assignees</button>
        \\    <button type="button" disabled>Newest</button>
        \\  </div>
        \\</header>
    );
}

fn appendIssueStateTab(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    label: []const u8,
    count: usize,
    tab_filter: IssueStateFilter,
    active_filter: IssueStateFilter,
    icon_class: []const u8,
) !void {
    try appendTemplate(buf, allocator,
        \\<a class="{classes}" href="/issues?state={state}"><span class="issue-tab-icon {icon_class}" aria-hidden="true"></span><span>{label}</span><span class="issue-count-badge">{count}</span></a>
    , .{
        .classes = shared.classes("issues-state-tab", &.{shared.class("active", tab_filter == active_filter)}),
        .state = issueStateValue(tab_filter),
        .icon_class = icon_class,
        .label = label,
        .count = count,
    });
}

fn appendIssueListRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    id: []const u8,
    title: []const u8,
    state: []const u8,
    author: []const u8,
    opened_at: []const u8,
    state_at: []const u8,
    milestone: []const u8,
    comment_count: usize,
    legacy_number: i64,
) !void {
    var issue_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const issue_ref = util.shortObjectRef(&issue_ref_buf, id);
    const closed = std.mem.eql(u8, state, "closed");
    try appendTemplate(buf, allocator,
        \\<article class="issue-list-row is-{state}">
        \\  <div class="issue-select-cell"><input type="checkbox" aria-label="Select issue {id}" disabled></div>
        \\  <div class="issue-state-cell"><span class="issue-state-icon {state}" title="{state}" aria-label="{state}"></span></div>
        \\  <div class="issue-row-content">
        \\    <div class="issue-row-title-line"><a class="issue-row-title" href="{href}">{title}</a>
    , .{
        .state = state,
        .id = issue_ref,
        .href = issueHref(issue_ref),
        .title = title,
    });
    try appendIssueRowLabels(buf, allocator, db, id);
    try appendTemplate(buf, allocator,
        \\</div><p class="issue-row-meta">#{id}
    , .{
        .id = issue_ref,
    });
    if (legacy_number > 0) {
        try buf.appendSlice(allocator, " / GitHub ");
        try appendLegacyIssueLink(buf, allocator, legacy_number);
    }
    try appendTemplate(buf, allocator,
        \\ by {author} {verb} {time}</p></div>
        \\  <div class="issue-row-side">
    , .{
        .author = author,
        .verb = if (closed) "was closed" else "opened",
        .time = if (closed) state_at else opened_at,
    });
    if (milestone.len != 0) {
        try appendTemplate(buf, allocator,
            \\<span class="issue-row-milestone" title="Milestone"><span class="issue-milestone-icon" aria-hidden="true"></span>{milestone}</span>
        , .{ .milestone = milestone });
    }
    try appendIssueAssignees(buf, allocator, db, id);
    if (comment_count > 0) {
        try appendTemplate(buf, allocator,
            \\<span class="issue-comments" title="Comments"><span class="issue-comments-icon" aria-hidden="true"></span>{comment_count}</span>
        , .{ .comment_count = comment_count });
    }
    try appendIssueAvatar(buf, allocator, author, "issue-author-avatar");
    try buf.appendSlice(allocator,
        \\  </div>
        \\</article>
    );
}

fn appendIssueRowLabels(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, issue_id: []const u8) !void {
    var stmt = try db.prepare("SELECT DISTINCT label FROM issue_labels WHERE issue_id = ? ORDER BY label");
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    var shown = false;
    while (try stmt.step()) {
        const label = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(label);
        if (!shown) {
            try buf.appendSlice(allocator, "<span class=\"issue-row-labels\">");
            shown = true;
        }
        try appendIssueLabel(buf, allocator, label);
    }
    if (shown) try buf.appendSlice(allocator, "</span>");
}

fn appendIssueLabel(buf: *std.ArrayList(u8), allocator: Allocator, label: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<span class="issue-label {kind}">{label}</span>
    , .{
        .kind = issueLabelKind(label),
        .label = label,
    });
}

fn appendIssueAssignees(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, issue_id: []const u8) !void {
    var stmt = try db.prepare("SELECT DISTINCT assignee FROM issue_assignees WHERE issue_id = ? ORDER BY assignee");
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    var shown = false;
    while (try stmt.step()) {
        const assignee = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(assignee);
        if (!shown) {
            try buf.appendSlice(allocator, "<span class=\"issue-row-assignees\">");
            shown = true;
        }
        try appendIssueAvatar(buf, allocator, assignee, "");
    }
    if (shown) try buf.appendSlice(allocator, "</span>");
}

fn appendIssueAvatar(buf: *std.ArrayList(u8), allocator: Allocator, name: []const u8, extra_class: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<span class="issue-avatar {extra_class}" title="{name}" aria-label="{name}">
    , .{
        .extra_class = extra_class,
        .name = name,
    });
    var initial_buf = [_]u8{'?'};
    for (name) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            initial_buf[0] = std.ascii.toUpper(c);
            break;
        }
    }
    try shared.appendHtml(buf, allocator, initial_buf[0..]);
    try buf.appendSlice(allocator, "</span>");
}

fn issueSearchQuery(filter: IssueStateFilter) []const u8 {
    return switch (filter) {
        .open => "is:issue state:open",
        .closed => "is:issue state:closed",
        .all => "is:issue",
    };
}

fn issueStateValue(filter: IssueStateFilter) []const u8 {
    return switch (filter) {
        .open => "open",
        .closed => "closed",
        .all => "all",
    };
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
        \\SELECT i.id, i.title, i.state, i.author_principal, i.opened_at, i.body,
        \\       COALESCE(m.source_author, ''), COALESCE(m.milestone, ''), COALESCE(a.number, 0),
        \\       i.state_occurred_at,
        \\       (SELECT COUNT(*) FROM comments c WHERE c.parent_kind = 'issue' AND c.parent_id = i.id)
        \\FROM issues i
        \\LEFT JOIN issue_metadata m ON m.issue_id = i.id
        \\LEFT JOIN legacy_aliases a
        \\  ON a.provider = 'github' AND a.object_kind = 'issue' AND a.object_id = i.id
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
    const opened_at = try stmt.columnTextDup(allocator, 4);
    defer allocator.free(opened_at);
    const body = try stmt.columnTextDup(allocator, 5);
    defer allocator.free(body);
    const source_author = try stmt.columnTextDup(allocator, 6);
    defer allocator.free(source_author);
    const milestone = try stmt.columnTextDup(allocator, 7);
    defer allocator.free(milestone);
    const legacy_number = stmt.columnInt64(8);
    const state_at = try stmt.columnTextDup(allocator, 9);
    defer allocator.free(state_at);
    const comment_count = @as(usize, @intCast(stmt.columnInt64(10)));

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const display_author = if (source_author.len != 0) source_author else author_principal;

    try appendShellStart(&buf, allocator, repo, title, "issues");
    try buf.appendSlice(allocator, "<section class=\"issue-page\">");
    try appendIssuePageHeader(&buf, allocator, id, title, state, display_author, opened_at, state_at, comment_count, legacy_number);
    try appendTemplate(&buf, allocator,
        \\  <div class="issue-conversation-layout">
        \\    <div class="issue-conversation">
        \\      <div class="issue-timeline-item">
        \\        <div class="issue-timeline-avatar">
    , .{});
    try appendIssueAvatar(&buf, allocator, display_author, "issue-detail-avatar");
    try appendTemplate(&buf, allocator,
        \\        </div>
        \\        <article class="issue-comment-box">
        \\          <header class="issue-comment-head">
        \\            <div><strong>{author}</strong><span>opened {opened_at}</span></div>
        \\            <button class="issue-kebab-button" type="button" disabled aria-label="Comment actions"></button>
        \\          </header>
        \\          <div class="markdown-body">
    , .{
        .author = display_author,
        .opened_at = opened_at,
    });
    if (body.len == 0) {
        try buf.appendSlice(allocator, "<p class=\"muted\">No description provided.</p>");
    } else {
        try markdown_render.appendMarkdown(&buf, allocator, body);
    }
    try buf.appendSlice(allocator,
        \\          </div>
        \\        </article>
        \\      </div>
    );
    try appendIssueComments(&buf, allocator, &db, id);
    try buf.appendSlice(allocator, "    </div><aside class=\"issue-meta-sidebar\">");
    try appendIssueSidebar(&buf, allocator, &db, id, display_author, milestone);
    try buf.appendSlice(allocator, "</aside></div></section>");
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn appendIssuePageHeader(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    issue_id: []const u8,
    title: []const u8,
    state: []const u8,
    author: []const u8,
    opened_at: []const u8,
    state_at: []const u8,
    comment_count: usize,
    legacy_number: i64,
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
        \\        <button class="button secondary" type="button" disabled>Edit</button>
        \\        <a class="button primary" href="/new-issue">New issue</a>
        \\        <button class="issue-copy-button" type="button" disabled aria-label="Copy issue link"><span class="button-icon icon-copy" aria-hidden="true"></span></button>
        \\      </div>
        \\    </div>
        \\    <div class="issue-status-line">
    , .{});
    try appendIssueStateBadge(buf, allocator, state);
    try appendTemplate(buf, allocator,
        \\      <span><strong>{author}</strong> opened this issue {opened_at}
    , .{
        .author = author,
        .opened_at = opened_at,
    });
    if (std.mem.eql(u8, state, "closed")) {
        try appendTemplate(buf, allocator, " and closed it {state_at}", .{ .state_at = state_at });
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

fn appendLegacyIssueLink(buf: *std.ArrayList(u8), allocator: Allocator, legacy_number: i64) !void {
    const issue_ref = try std.fmt.allocPrint(allocator, "{d}", .{legacy_number});
    defer allocator.free(issue_ref);
    try shared.appendIssueReferenceLink(buf, allocator, issue_ref);
}

fn appendIssueComments(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, issue_id: []const u8) !void {
    var stmt = try db.prepare(
        \\SELECT body, redacted, COALESCE(NULLIF(source_author, ''), author_principal), created_at, reply_parent_id, reply_parent_hash
        \\FROM comments
        \\WHERE parent_kind = 'issue' AND parent_id = ?
        \\ORDER BY created_at, id
    );
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    while (try stmt.step()) {
        const body = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(body);
        const redacted = stmt.columnInt(1) != 0;
        const author = try stmt.columnTextDup(allocator, 2);
        defer allocator.free(author);
        const created_at = try stmt.columnTextDup(allocator, 3);
        defer allocator.free(created_at);
        const reply_parent_id = try stmt.columnTextDup(allocator, 4);
        defer allocator.free(reply_parent_id);
        const reply_parent_hash = try stmt.columnTextDup(allocator, 5);
        defer allocator.free(reply_parent_hash);

        const is_reply = reply_parent_id.len != 0 or reply_parent_hash.len != 0;
        try appendTemplate(buf, allocator,
            \\<div class="{classes}"><div class="issue-timeline-avatar">
        , .{ .classes = shared.classes("issue-timeline-item", &.{shared.class("is-reply", is_reply)}) });
        try appendIssueAvatar(buf, allocator, author, "issue-detail-avatar");
        try appendTemplate(buf, allocator,
            \\</div><article class="issue-comment-box"><header class="issue-comment-head"><div><strong>{author}</strong><span>commented {created_at}</span></div><button class="issue-kebab-button" type="button" disabled aria-label="Comment actions"></button></header>
        , .{
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
        try buf.appendSlice(allocator, "</div></article></div>");
    }
}

fn appendIssueSidebar(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    issue_id: []const u8,
    author: []const u8,
    milestone: []const u8,
) !void {
    try appendIssueSidebarAssignees(buf, allocator, db, issue_id);
    try appendIssueSidebarLabels(buf, allocator, db, issue_id);
    try appendIssueSidebarText(buf, allocator, "Type", "No type");
    try appendIssueSidebarProjects(buf, allocator, db, issue_id);
    try appendIssueSidebarText(buf, allocator, "Milestone", if (milestone.len == 0) "No milestone" else milestone);
    try appendIssueSidebarText(buf, allocator, "Relationships", "None yet");
    try appendIssueSidebarText(buf, allocator, "Development", "No linked branches or pull requests.");
    try appendIssueSidebarNotifications(buf, allocator);
    try appendIssueSidebarParticipants(buf, allocator, db, issue_id, author);
}

fn appendIssueSidebarAssignees(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, issue_id: []const u8) !void {
    try appendIssueSidebarSectionStart(buf, allocator, "Assignees");
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

fn appendIssueSidebarLabels(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, issue_id: []const u8) !void {
    try appendIssueSidebarSectionStart(buf, allocator, "Labels");
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
        try appendIssueLabel(buf, allocator, label);
    }
    if (shown) {
        try buf.appendSlice(allocator, "</div>");
    } else {
        try buf.appendSlice(allocator, "<p class=\"issue-sidebar-empty\">None yet</p>");
    }
    try appendIssueSidebarSectionEnd(buf, allocator);
}

fn appendIssueSidebarProjects(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, issue_id: []const u8) !void {
    try appendIssueSidebarSectionStart(buf, allocator, "Projects");
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
        try buf.appendSlice(allocator, "<span class=\"issue-sidebar-pill\">");
        try appendTemplate(buf, allocator, "{project}", .{ .project = project });
        if (column.len != 0) try appendTemplate(buf, allocator, " / {column}", .{ .column = column });
        try buf.appendSlice(allocator, "</span>");
        shown = true;
    }
    if (!shown) try buf.appendSlice(allocator, "<p class=\"issue-sidebar-empty\">No projects</p>");
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

fn appendIssueSidebarText(buf: *std.ArrayList(u8), allocator: Allocator, title: []const u8, value: []const u8) !void {
    try appendIssueSidebarSectionStart(buf, allocator, title);
    try appendTemplate(buf, allocator, "<p class=\"issue-sidebar-empty\">{value}</p>", .{ .value = value });
    try appendIssueSidebarSectionEnd(buf, allocator);
}

fn appendIssueSidebarSectionStart(buf: *std.ArrayList(u8), allocator: Allocator, title: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<section class="issue-sidebar-section"><h2>{title}</h2>
    , .{ .title = title });
}

fn appendIssueSidebarSectionEnd(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator, "</section>");
}

fn appendIssueSidebarPerson(buf: *std.ArrayList(u8), allocator: Allocator, name: []const u8) !void {
    try buf.appendSlice(allocator, "<div class=\"issue-sidebar-person\">");
    try appendIssueAvatar(buf, allocator, name, "");
    try appendTemplate(buf, allocator, "<span>{name}</span></div>", .{ .name = name });
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

fn queryValueOwned(allocator: Allocator, target: []const u8, wanted_key: []const u8) !?[]u8 {
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
