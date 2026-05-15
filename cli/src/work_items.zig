const std = @import("std");

const git = @import("git.zig");
const json_writer = @import("json_writer.zig");
const repo_mod = @import("repo.zig");
const sqlite_db = @import("index/sqlite_db.zig");
const util = @import("util.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
pub const SqliteDb = sqlite_db.SqliteDb;
pub const SqliteStmt = sqlite_db.SqliteStmt;

const appendJsonFieldBool = json_writer.appendJsonFieldBool;
const appendJsonFieldInteger = json_writer.appendJsonFieldInteger;
const appendJsonFieldString = json_writer.appendJsonFieldString;
const appendJsonString = json_writer.appendJsonString;

pub const max_pull_diff_bytes = 8 * 1024 * 1024;

pub const IssueStateFilter = enum {
    open,
    closed,
    all,
};

pub const IssueSort = enum {
    newest,
    oldest,
    updated,
};

pub const IssueCounts = struct {
    open: usize = 0,
    closed: usize = 0,
    all: usize = 0,
};

pub const IssueListOptions = struct {
    allocator: Allocator,
    state: IssueStateFilter = .all,
    q: ?[]u8 = null,
    author: ?[]u8 = null,
    label: ?[]u8 = null,
    project: ?[]u8 = null,
    milestone: ?[]u8 = null,
    assignee: ?[]u8 = null,
    sort: IssueSort = .newest,
    limit: ?usize = null,

    pub fn deinit(self: *IssueListOptions) void {
        if (self.q) |value| self.allocator.free(value);
        if (self.author) |value| self.allocator.free(value);
        if (self.label) |value| self.allocator.free(value);
        if (self.project) |value| self.allocator.free(value);
        if (self.milestone) |value| self.allocator.free(value);
        if (self.assignee) |value| self.allocator.free(value);
    }
};

pub const IssueListRow = struct {
    id: []u8,
    title: []u8,
    state: []u8,
    author: []u8,
    opened_at: []u8,
    state_at: []u8,
    milestone: []u8,
    comment_count: usize,
    legacy_number: i64,
    body: []u8,

    pub fn deinit(self: IssueListRow, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        allocator.free(self.state);
        allocator.free(self.author);
        allocator.free(self.opened_at);
        allocator.free(self.state_at);
        allocator.free(self.milestone);
        allocator.free(self.body);
    }
};

pub const IssueDetail = struct {
    id: []u8,
    title: []u8,
    state: []u8,
    author_principal: []u8,
    author_device: []u8,
    source_author: []u8,
    opened_at: []u8,
    state_occurred_at: []u8,
    state_actor_principal: []u8,
    body: []u8,
    milestone: []u8,
    legacy_number: i64,
    comment_count: usize,

    pub fn deinit(self: IssueDetail, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        allocator.free(self.state);
        allocator.free(self.author_principal);
        allocator.free(self.author_device);
        allocator.free(self.source_author);
        allocator.free(self.opened_at);
        allocator.free(self.state_occurred_at);
        allocator.free(self.state_actor_principal);
        allocator.free(self.body);
        allocator.free(self.milestone);
    }

    pub fn displayAuthor(self: IssueDetail) []const u8 {
        return if (self.source_author.len != 0) self.source_author else self.author_principal;
    }
};

pub const PullStateFilter = enum {
    open,
    merged,
    closed,
    all,
};

pub const PullCounts = struct {
    open: usize = 0,
    merged: usize = 0,
    closed: usize = 0,
    all: usize = 0,
};

pub const PullListOptions = struct {
    state: PullStateFilter = .all,
    limit: ?usize = null,
};

pub const PullListRow = struct {
    id: []u8,
    title: []u8,
    state: []u8,
    author: []u8,
    opened_at: []u8,
    state_at: []u8,
    base_ref: []u8,
    head_ref: []u8,
    draft: bool,
    comment_count: usize,
    legacy_number: i64,
    body: []u8,

    pub fn deinit(self: PullListRow, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        allocator.free(self.state);
        allocator.free(self.author);
        allocator.free(self.opened_at);
        allocator.free(self.state_at);
        allocator.free(self.base_ref);
        allocator.free(self.head_ref);
        allocator.free(self.body);
    }
};

pub const PullDetail = struct {
    id: []u8,
    title: []u8,
    state: []u8,
    author_principal: []u8,
    author_device: []u8,
    source_author: []u8,
    opened_at: []u8,
    state_occurred_at: []u8,
    state_actor_principal: []u8,
    body: []u8,
    base_ref: []u8,
    head_ref: []u8,
    draft: bool,
    merge_oid: []u8,
    target_oid: []u8,
    legacy_number: i64,
    commit_count: ?usize,
    changed_files: ?usize,
    additions: ?usize,
    deletions: ?usize,

    pub fn deinit(self: PullDetail, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        allocator.free(self.state);
        allocator.free(self.author_principal);
        allocator.free(self.author_device);
        allocator.free(self.source_author);
        allocator.free(self.opened_at);
        allocator.free(self.state_occurred_at);
        allocator.free(self.state_actor_principal);
        allocator.free(self.body);
        allocator.free(self.base_ref);
        allocator.free(self.head_ref);
        allocator.free(self.merge_oid);
        allocator.free(self.target_oid);
    }

    pub fn displayAuthor(self: PullDetail) []const u8 {
        return if (self.source_author.len != 0) self.source_author else self.author_principal;
    }
};

pub const CommentRow = struct {
    id: []u8,
    body: []u8,
    redacted: bool,
    author_principal: []u8,
    author_device: []u8,
    source_author: []u8,
    display_author: []u8,
    created_at: []u8,
    reply_parent_id: []u8,
    reply_parent_hash: []u8,

    pub fn deinit(self: CommentRow, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.body);
        allocator.free(self.author_principal);
        allocator.free(self.author_device);
        allocator.free(self.source_author);
        allocator.free(self.display_author);
        allocator.free(self.created_at);
        allocator.free(self.reply_parent_id);
        allocator.free(self.reply_parent_hash);
    }

    pub fn isReply(self: CommentRow) bool {
        return self.reply_parent_id.len != 0 or self.reply_parent_hash.len != 0;
    }
};

pub const TimelineEvent = struct {
    event_type: []u8,
    actor_principal: []u8,
    occurred_at: []u8,
    body: []u8,
    event_hash: []u8,

    pub fn deinit(self: TimelineEvent, allocator: Allocator) void {
        allocator.free(self.event_type);
        allocator.free(self.actor_principal);
        allocator.free(self.occurred_at);
        allocator.free(self.body);
        allocator.free(self.event_hash);
    }
};

pub const PullGitRefs = struct {
    base: []u8,
    head: []u8,

    pub fn deinit(self: PullGitRefs, allocator: Allocator) void {
        allocator.free(self.base);
        allocator.free(self.head);
    }
};

pub fn issueStateValue(filter: IssueStateFilter) []const u8 {
    return switch (filter) {
        .open => "open",
        .closed => "closed",
        .all => "all",
    };
}

pub fn issueSortValue(sort: IssueSort) []const u8 {
    return switch (sort) {
        .newest => "newest",
        .oldest => "oldest",
        .updated => "updated",
    };
}

pub fn issueSearchQuery(filter: IssueStateFilter) []const u8 {
    return switch (filter) {
        .open => "is:issue state:open",
        .closed => "is:issue state:closed",
        .all => "is:issue",
    };
}

pub fn issueStateFilterFromValue(value: []const u8) ?IssueStateFilter {
    if (std.mem.eql(u8, value, "open")) return .open;
    if (std.mem.eql(u8, value, "closed")) return .closed;
    if (std.mem.eql(u8, value, "all")) return .all;
    return null;
}

pub fn issueSortFromValue(value: []const u8) ?IssueSort {
    if (std.mem.eql(u8, value, "newest")) return .newest;
    if (std.mem.eql(u8, value, "oldest")) return .oldest;
    if (std.mem.eql(u8, value, "updated")) return .updated;
    return null;
}

pub fn hasRestrictiveIssueFilters(filters: IssueListOptions) bool {
    return filters.q != null or
        filters.author != null or
        filters.label != null or
        filters.project != null or
        filters.milestone != null or
        filters.assignee != null;
}

pub fn pullStateValue(filter: PullStateFilter) []const u8 {
    return switch (filter) {
        .open => "open",
        .merged => "merged",
        .closed => "closed",
        .all => "all",
    };
}

pub fn pullSearchQuery(filter: PullStateFilter) []const u8 {
    return switch (filter) {
        .open => "is:pr state:open",
        .merged => "is:pr state:merged",
        .closed => "is:pr state:closed",
        .all => "is:pr",
    };
}

pub fn pullStateFilterFromValue(value: []const u8) ?PullStateFilter {
    if (std.mem.eql(u8, value, "open")) return .open;
    if (std.mem.eql(u8, value, "merged")) return .merged;
    if (std.mem.eql(u8, value, "closed")) return .closed;
    if (std.mem.eql(u8, value, "all")) return .all;
    return null;
}

pub fn loadIssueCounts(db: *SqliteDb) !IssueCounts {
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

pub fn issueListSql(allocator: Allocator, filters: IssueListOptions) ![]u8 {
    var sql: std.ArrayList(u8) = .empty;
    errdefer sql.deinit(allocator);

    try sql.appendSlice(allocator,
        \\SELECT i.id, i.title, i.state,
        \\       COALESCE(NULLIF(m.source_author, ''), i.author_principal),
        \\       i.opened_at, i.state_occurred_at, COALESCE(m.milestone, ''),
        \\       (SELECT COUNT(*) FROM comments c WHERE c.parent_kind = 'issue' AND c.parent_id = i.id),
        \\       COALESCE(a.number, 0), i.body
        \\FROM issues i
        \\LEFT JOIN issue_metadata m ON m.issue_id = i.id
        \\LEFT JOIN legacy_aliases a
        \\  ON a.provider = 'github' AND a.object_kind = 'issue' AND a.object_id = i.id
    );

    var conditions: usize = 0;
    if (filters.state != .all) try appendIssueListCondition(&sql, allocator, &conditions, "i.state = ?");
    if (filters.q != null) {
        try appendIssueListCondition(&sql, allocator, &conditions,
            \\(i.title LIKE ? ESCAPE '\' OR i.body LIKE ? ESCAPE '\' OR COALESCE(NULLIF(m.source_author, ''), i.author_principal) LIKE ? ESCAPE '\' OR EXISTS (SELECT 1 FROM comments c WHERE c.parent_kind = 'issue' AND c.parent_id = i.id AND c.body LIKE ? ESCAPE '\'))
        );
    }
    if (filters.author != null) try appendIssueListCondition(&sql, allocator, &conditions, "COALESCE(NULLIF(m.source_author, ''), i.author_principal) = ?");
    if (filters.label != null) try appendIssueListCondition(&sql, allocator, &conditions, "EXISTS (SELECT 1 FROM issue_labels il WHERE il.issue_id = i.id AND il.label = ?)");
    if (filters.project != null) try appendIssueListCondition(&sql, allocator, &conditions, "EXISTS (SELECT 1 FROM issue_projects ip WHERE ip.issue_id = i.id AND ip.project = ?)");
    if (filters.milestone != null) try appendIssueListCondition(&sql, allocator, &conditions, "COALESCE(m.milestone, '') = ?");
    if (filters.assignee != null) try appendIssueListCondition(&sql, allocator, &conditions, "EXISTS (SELECT 1 FROM issue_assignees ia WHERE ia.issue_id = i.id AND ia.assignee = ?)");

    try sql.appendSlice(allocator, switch (filters.sort) {
        .newest => "\nORDER BY i.opened_at DESC, i.id DESC",
        .oldest => "\nORDER BY i.opened_at ASC, i.id ASC",
        .updated => "\nORDER BY i.state_occurred_at DESC, i.opened_at DESC, i.id DESC",
    });
    if (filters.limit) |_| try sql.appendSlice(allocator, "\nLIMIT ?");
    return sql.toOwnedSlice(allocator);
}

fn appendIssueListCondition(sql: *std.ArrayList(u8), allocator: Allocator, conditions: *usize, condition: []const u8) !void {
    try sql.appendSlice(allocator, if (conditions.* == 0) "\nWHERE " else "\n  AND ");
    try sql.appendSlice(allocator, condition);
    conditions.* += 1;
}

pub fn prepareIssueListStmt(allocator: Allocator, db: *SqliteDb, filters: IssueListOptions) !SqliteStmt {
    const sql = try issueListSql(allocator, filters);
    defer allocator.free(sql);
    var stmt = try db.prepare(sql);
    errdefer stmt.deinit();
    const search_pattern = if (filters.q) |query| try sqliteLikePatternOwned(allocator, query) else null;
    defer if (search_pattern) |pattern| allocator.free(pattern);
    try bindIssueListFilters(&stmt, filters, search_pattern);
    return stmt;
}

pub fn bindIssueListFilters(stmt: *SqliteStmt, filters: IssueListOptions, search_pattern: ?[]const u8) !void {
    var idx: c_int = 1;
    if (filters.state != .all) {
        try stmt.bindText(idx, issueStateValue(filters.state));
        idx += 1;
    }
    if (search_pattern) |pattern| {
        try stmt.bindText(idx, pattern);
        idx += 1;
        try stmt.bindText(idx, pattern);
        idx += 1;
        try stmt.bindText(idx, pattern);
        idx += 1;
        try stmt.bindText(idx, pattern);
        idx += 1;
    }
    if (filters.author) |value| {
        try stmt.bindText(idx, value);
        idx += 1;
    }
    if (filters.label) |value| {
        try stmt.bindText(idx, value);
        idx += 1;
    }
    if (filters.project) |value| {
        try stmt.bindText(idx, value);
        idx += 1;
    }
    if (filters.milestone) |value| {
        try stmt.bindText(idx, value);
        idx += 1;
    }
    if (filters.assignee) |value| {
        try stmt.bindText(idx, value);
        idx += 1;
    }
    if (filters.limit) |value| {
        try stmt.bindInt64(idx, @intCast(value));
    }
}

pub fn issueListRowFromStmt(allocator: Allocator, stmt: *SqliteStmt) !IssueListRow {
    return .{
        .id = try stmt.columnTextDup(allocator, 0),
        .title = try stmt.columnTextDup(allocator, 1),
        .state = try stmt.columnTextDup(allocator, 2),
        .author = try stmt.columnTextDup(allocator, 3),
        .opened_at = try stmt.columnTextDup(allocator, 4),
        .state_at = try stmt.columnTextDup(allocator, 5),
        .milestone = try stmt.columnTextDup(allocator, 6),
        .comment_count = @as(usize, @intCast(stmt.columnInt64(7))),
        .legacy_number = stmt.columnInt64(8),
        .body = try stmt.columnTextDup(allocator, 9),
    };
}

pub fn sqliteLikePatternOwned(allocator: Allocator, value: []const u8) ![]u8 {
    var pattern: std.ArrayList(u8) = .empty;
    errdefer pattern.deinit(allocator);
    try pattern.append(allocator, '%');
    for (value) |c| {
        if (c == '%' or c == '_' or c == '\\') try pattern.append(allocator, '\\');
        try pattern.append(allocator, c);
    }
    try pattern.append(allocator, '%');
    return pattern.toOwnedSlice(allocator);
}

pub fn loadIssueDetail(allocator: Allocator, db: *SqliteDb, issue_id: []const u8) !?IssueDetail {
    var stmt = try db.prepare(
        \\SELECT i.id, i.title, i.state, i.author_principal, i.author_device, i.opened_at, i.body,
        \\       COALESCE(m.source_author, ''), COALESCE(m.milestone, ''), COALESCE(a.number, 0),
        \\       i.state_occurred_at, i.state_actor_principal,
        \\       (SELECT COUNT(*) FROM comments c WHERE c.parent_kind = 'issue' AND c.parent_id = i.id)
        \\FROM issues i
        \\LEFT JOIN issue_metadata m ON m.issue_id = i.id
        \\LEFT JOIN legacy_aliases a
        \\  ON a.provider = 'github' AND a.object_kind = 'issue' AND a.object_id = i.id
        \\WHERE i.id = ?
    );
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    if (!(try stmt.step())) return null;
    return .{
        .id = try stmt.columnTextDup(allocator, 0),
        .title = try stmt.columnTextDup(allocator, 1),
        .state = try stmt.columnTextDup(allocator, 2),
        .author_principal = try stmt.columnTextDup(allocator, 3),
        .author_device = try stmt.columnTextDup(allocator, 4),
        .opened_at = try stmt.columnTextDup(allocator, 5),
        .body = try stmt.columnTextDup(allocator, 6),
        .source_author = try stmt.columnTextDup(allocator, 7),
        .milestone = try stmt.columnTextDup(allocator, 8),
        .legacy_number = stmt.columnInt64(9),
        .state_occurred_at = try stmt.columnTextDup(allocator, 10),
        .state_actor_principal = try stmt.columnTextDup(allocator, 11),
        .comment_count = @as(usize, @intCast(stmt.columnInt64(12))),
    };
}

pub fn loadPullCounts(db: *SqliteDb) !PullCounts {
    var counts: PullCounts = .{};
    var stmt = try db.prepare("SELECT state, COUNT(*) FROM pulls GROUP BY state");
    defer stmt.deinit();
    while (try stmt.step()) {
        const state = try stmt.columnTextDup(db.allocator, 0);
        defer db.allocator.free(state);
        const count = @as(usize, @intCast(stmt.columnInt64(1)));
        counts.all += count;
        if (std.mem.eql(u8, state, "open")) {
            counts.open = count;
        } else if (std.mem.eql(u8, state, "merged")) {
            counts.merged = count;
        } else if (std.mem.eql(u8, state, "closed")) {
            counts.closed = count;
        }
    }
    return counts;
}

pub fn pullListSql(options: PullListOptions) []const u8 {
    const select =
        \\SELECT p.id, p.title, p.state, COALESCE(NULLIF(pm.source_author, ''), p.author_principal), p.opened_at, p.state_occurred_at,
        \\       p.base_ref, p.head_ref, p.draft,
        \\       (SELECT COUNT(*) FROM comments c WHERE c.parent_kind = 'pull' AND c.parent_id = p.id),
        \\       COALESCE(a.number, 0), p.body
        \\FROM pulls p
        \\LEFT JOIN legacy_aliases a
        \\  ON a.provider = 'github' AND a.object_kind = 'pull' AND a.object_id = p.id
        \\LEFT JOIN pull_metadata pm ON pm.pull_id = p.id
    ;
    return switch (options.state) {
        .open => select ++
            \\ WHERE p.state = 'open'
            \\ ORDER BY p.opened_at DESC, p.id DESC
        ,
        .merged => select ++
            \\ WHERE p.state = 'merged'
            \\ ORDER BY p.state_occurred_at DESC, p.opened_at DESC, p.id DESC
        ,
        .closed => select ++
            \\ WHERE p.state = 'closed'
            \\ ORDER BY p.state_occurred_at DESC, p.opened_at DESC, p.id DESC
        ,
        .all => select ++
            \\ ORDER BY p.state_occurred_at DESC, p.opened_at DESC, p.id DESC
        ,
    };
}

pub fn preparePullListStmt(db: *SqliteDb, options: PullListOptions) !SqliteStmt {
    var stmt = try db.prepare(pullListSql(options));
    errdefer stmt.deinit();
    return stmt;
}

pub fn pullListRowFromStmt(allocator: Allocator, stmt: *SqliteStmt) !PullListRow {
    return .{
        .id = try stmt.columnTextDup(allocator, 0),
        .title = try stmt.columnTextDup(allocator, 1),
        .state = try stmt.columnTextDup(allocator, 2),
        .author = try stmt.columnTextDup(allocator, 3),
        .opened_at = try stmt.columnTextDup(allocator, 4),
        .state_at = try stmt.columnTextDup(allocator, 5),
        .base_ref = try stmt.columnTextDup(allocator, 6),
        .head_ref = try stmt.columnTextDup(allocator, 7),
        .draft = stmt.columnInt(8) != 0,
        .comment_count = @as(usize, @intCast(stmt.columnInt64(9))),
        .legacy_number = stmt.columnInt64(10),
        .body = try stmt.columnTextDup(allocator, 11),
    };
}

pub fn loadPullDetail(allocator: Allocator, db: *SqliteDb, pull_id: []const u8) !?PullDetail {
    var stmt = try db.prepare(
        \\SELECT p.id, p.title, p.state, p.author_principal, p.author_device, p.opened_at, p.body,
        \\       p.base_ref, p.head_ref, p.draft, p.merge_oid, p.target_oid, COALESCE(a.number, 0),
        \\       p.state_occurred_at, p.state_actor_principal,
        \\       COALESCE(pm.source_author, ''), COALESCE(pm.commit_count, -1), COALESCE(pm.changed_files, -1),
        \\       COALESCE(pm.additions, -1), COALESCE(pm.deletions, -1)
        \\FROM pulls p
        \\LEFT JOIN legacy_aliases a
        \\  ON a.provider = 'github' AND a.object_kind = 'pull' AND a.object_id = p.id
        \\LEFT JOIN pull_metadata pm ON pm.pull_id = p.id
        \\WHERE p.id = ?
    );
    defer stmt.deinit();
    try stmt.bindText(1, pull_id);
    if (!(try stmt.step())) return null;
    return .{
        .id = try stmt.columnTextDup(allocator, 0),
        .title = try stmt.columnTextDup(allocator, 1),
        .state = try stmt.columnTextDup(allocator, 2),
        .author_principal = try stmt.columnTextDup(allocator, 3),
        .author_device = try stmt.columnTextDup(allocator, 4),
        .source_author = try stmt.columnTextDup(allocator, 15),
        .opened_at = try stmt.columnTextDup(allocator, 5),
        .state_occurred_at = try stmt.columnTextDup(allocator, 13),
        .state_actor_principal = try stmt.columnTextDup(allocator, 14),
        .body = try stmt.columnTextDup(allocator, 6),
        .base_ref = try stmt.columnTextDup(allocator, 7),
        .head_ref = try stmt.columnTextDup(allocator, 8),
        .draft = stmt.columnInt(9) != 0,
        .merge_oid = try stmt.columnTextDup(allocator, 10),
        .target_oid = try stmt.columnTextDup(allocator, 11),
        .legacy_number = stmt.columnInt64(12),
        .commit_count = optionalCount(stmt.columnInt64(16)),
        .changed_files = optionalCount(stmt.columnInt64(17)),
        .additions = optionalCount(stmt.columnInt64(18)),
        .deletions = optionalCount(stmt.columnInt64(19)),
    };
}

pub fn optionalCount(value: i64) ?usize {
    return if (value >= 0) @as(usize, @intCast(value)) else null;
}

pub fn prepareCommentsStmt(db: *SqliteDb, parent_kind: []const u8, parent_id: []const u8) !SqliteStmt {
    var stmt = try db.prepare(
        \\SELECT id, body, redacted, author_principal, author_device, source_author,
        \\       COALESCE(NULLIF(source_author, ''), author_principal),
        \\       created_at, reply_parent_id, reply_parent_hash
        \\FROM comments
        \\WHERE parent_kind = ? AND parent_id = ?
        \\ORDER BY created_at, id
    );
    errdefer stmt.deinit();
    try stmt.bindText(1, parent_kind);
    try stmt.bindText(2, parent_id);
    return stmt;
}

pub fn commentRowFromStmt(allocator: Allocator, stmt: *SqliteStmt) !CommentRow {
    return .{
        .id = try stmt.columnTextDup(allocator, 0),
        .body = try stmt.columnTextDup(allocator, 1),
        .redacted = stmt.columnInt(2) != 0,
        .author_principal = try stmt.columnTextDup(allocator, 3),
        .author_device = try stmt.columnTextDup(allocator, 4),
        .source_author = try stmt.columnTextDup(allocator, 5),
        .display_author = try stmt.columnTextDup(allocator, 6),
        .created_at = try stmt.columnTextDup(allocator, 7),
        .reply_parent_id = try stmt.columnTextDup(allocator, 8),
        .reply_parent_hash = try stmt.columnTextDup(allocator, 9),
    };
}

pub fn prepareTimelineStmt(db: *SqliteDb, object_kind: []const u8, object_id: []const u8) !SqliteStmt {
    const event_types = if (std.mem.eql(u8, object_kind, "issue"))
        \\(
        \\    'issue.title_set',
        \\    'issue.body_set',
        \\    'issue.state_set',
        \\    'issue.updated',
        \\    'issue.label_added',
        \\    'issue.label_removed',
        \\    'issue.assignee_added',
        \\    'issue.assignee_removed',
        \\    'issue.milestone_set',
        \\    'issue.project_added',
        \\    'issue.project_removed'
        \\  )
    else
        \\(
        \\    'pull.title_set',
        \\    'pull.body_set',
        \\    'pull.state_set',
        \\    'pull.updated',
        \\    'pull.label_added',
        \\    'pull.label_removed',
        \\    'pull.assignee_added',
        \\    'pull.assignee_removed',
        \\    'pull.reviewer_added',
        \\    'pull.reviewer_removed',
        \\    'pull.merged'
        \\  )
    ;
    const sql = try std.fmt.allocPrint(db.allocator,
        \\SELECT event_type, actor_principal, occurred_at, body, event_hash
        \\FROM events
        \\WHERE object_kind = ?
        \\  AND object_id = ?
        \\  AND domain_status = 'accepted'
        \\  AND event_type IN {s}
        \\ORDER BY occurred_at, ordinal
    , .{event_types});
    defer db.allocator.free(sql);
    var stmt = try db.prepare(sql);
    errdefer stmt.deinit();
    try stmt.bindText(1, object_kind);
    try stmt.bindText(2, object_id);
    return stmt;
}

pub fn timelineEventFromStmt(allocator: Allocator, stmt: *SqliteStmt) !TimelineEvent {
    return .{
        .event_type = try stmt.columnTextDup(allocator, 0),
        .actor_principal = try stmt.columnTextDup(allocator, 1),
        .occurred_at = try stmt.columnTextDup(allocator, 2),
        .body = try stmt.columnTextDup(allocator, 3),
        .event_hash = try stmt.columnTextDup(allocator, 4),
    };
}

pub fn appendIssueAgentJson(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, detail: IssueDetail) !void {
    var ref_buf: [util.short_object_ref_len]u8 = undefined;
    const short_ref = util.shortObjectRef(&ref_buf, detail.id);
    try buf.append(allocator, '{');
    try appendJsonFieldString(buf, allocator, "kind", "issue", true);
    try appendJsonFieldString(buf, allocator, "ref", short_ref, true);
    try appendIssueDetailJsonFields(buf, allocator, db, detail, true);
    try appendCommentsJsonField(buf, allocator, db, "comments", "issue", detail.id, true);
    try appendTimelineJsonField(buf, allocator, db, "timeline_events", "issue", detail.id, true);
    try appendIssueCommandsJsonField(buf, allocator, short_ref, false);
    try buf.append(allocator, '}');
}

pub fn appendPullAgentJson(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, repo: Repo, detail: PullDetail, include_diff: bool) !void {
    var ref_buf: [util.short_object_ref_len]u8 = undefined;
    const short_ref = util.shortObjectRef(&ref_buf, detail.id);
    try buf.append(allocator, '{');
    try appendJsonFieldString(buf, allocator, "kind", "pull_request", true);
    try appendJsonFieldString(buf, allocator, "ref", short_ref, true);
    try appendPullDetailJsonFields(buf, allocator, db, detail, true);
    try appendCommentsJsonField(buf, allocator, db, "comments", "pull", detail.id, true);
    try appendTimelineJsonField(buf, allocator, db, "timeline_events", "pull", detail.id, true);
    if (include_diff) {
        if (try loadPullDiff(allocator, repo, detail, 3)) |diff| {
            defer allocator.free(diff);
            try appendJsonFieldString(buf, allocator, "diff", diff, true);
            try appendJsonFieldBool(buf, allocator, "diff_available", true, true);
        } else {
            try appendJsonFieldString(buf, allocator, "diff", "", true);
            try appendJsonFieldBool(buf, allocator, "diff_available", false, true);
        }
    }
    try appendPullCommandsJsonField(buf, allocator, short_ref, false);
    try buf.append(allocator, '}');
}

pub fn appendIssueListAgentJson(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, filters: IssueListOptions) !void {
    const counts = try loadIssueCounts(db);
    try buf.append(allocator, '{');
    try appendJsonFieldString(buf, allocator, "kind", "issue_list", true);
    try appendIssueFiltersJsonField(buf, allocator, filters, true);
    try appendIssueCountsJsonField(buf, allocator, counts, true);
    try appendJsonString(buf, allocator, "issues");
    try buf.appendSlice(allocator, ":[");
    var stmt = try prepareIssueListStmt(allocator, db, filters);
    defer stmt.deinit();
    var first = true;
    while (try stmt.step()) {
        var row = try issueListRowFromStmt(allocator, &stmt);
        defer row.deinit(allocator);
        if (!first) try buf.append(allocator, ',');
        first = false;
        try appendIssueListRowJson(buf, allocator, db, row);
    }
    try buf.appendSlice(allocator, "],");
    try appendIssueListCommandsJsonField(buf, allocator, false);
    try buf.append(allocator, '}');
}

pub fn appendPullListAgentJson(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, filters: PullListOptions) !void {
    const counts = try loadPullCounts(db);
    try buf.append(allocator, '{');
    try appendJsonFieldString(buf, allocator, "kind", "pull_request_list", true);
    try appendPullFiltersJsonField(buf, allocator, filters, true);
    try appendPullCountsJsonField(buf, allocator, counts, true);
    try appendJsonString(buf, allocator, "pull_requests");
    try buf.appendSlice(allocator, ":[");
    var stmt = try preparePullListStmt(db, filters);
    defer stmt.deinit();
    var first = true;
    var shown: usize = 0;
    while (try stmt.step()) {
        if (filters.limit) |limit| {
            if (shown >= limit) break;
        }
        var row = try pullListRowFromStmt(allocator, &stmt);
        defer row.deinit(allocator);
        if (!first) try buf.append(allocator, ',');
        first = false;
        try appendPullListRowJson(buf, allocator, db, row);
        shown += 1;
    }
    try buf.appendSlice(allocator, "],");
    try appendPullListCommandsJsonField(buf, allocator, false);
    try buf.append(allocator, '}');
}

pub fn appendIssueDetailJsonFields(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, detail: IssueDetail, comma: bool) !void {
    try appendJsonFieldString(buf, allocator, "id", detail.id, true);
    try appendJsonFieldString(buf, allocator, "state", detail.state, true);
    try appendJsonFieldString(buf, allocator, "title", detail.title, true);
    try appendJsonFieldString(buf, allocator, "body", detail.body, true);
    try appendJsonFieldString(buf, allocator, "author_principal", detail.author_principal, true);
    try appendJsonFieldString(buf, allocator, "author_device", detail.author_device, true);
    try appendJsonFieldString(buf, allocator, "display_author", detail.displayAuthor(), true);
    if (detail.source_author.len != 0) try appendJsonFieldString(buf, allocator, "source_author", detail.source_author, true);
    try appendJsonFieldString(buf, allocator, "opened_at", detail.opened_at, true);
    try appendJsonFieldString(buf, allocator, "state_occurred_at", detail.state_occurred_at, true);
    try appendJsonFieldString(buf, allocator, "state_actor_principal", detail.state_actor_principal, true);
    if (detail.legacy_number > 0) try appendJsonFieldInteger(buf, allocator, "legacy_github_issue_number", detail.legacy_number, true);
    if (detail.milestone.len != 0) try appendJsonFieldString(buf, allocator, "milestone", detail.milestone, true);
    try appendJsonFieldInteger(buf, allocator, "comment_count", @intCast(detail.comment_count), true);
    try appendStringArrayFieldFromQuery(buf, allocator, db, "labels", "SELECT DISTINCT label FROM issue_labels WHERE issue_id = ? ORDER BY label", detail.id, true);
    try appendStringArrayFieldFromQuery(buf, allocator, db, "assignees", "SELECT DISTINCT assignee FROM issue_assignees WHERE issue_id = ? ORDER BY assignee", detail.id, true);
    try appendIssueProjectsJsonField(buf, allocator, db, detail.id, true);
    try appendCommitReferencesJsonField(buf, allocator, db, "commit_references", "issue", detail.id, true);
    try appendReactionsJsonField(buf, allocator, db, "reactions", "issue", detail.id, comma);
}

pub fn appendPullDetailJsonFields(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, detail: PullDetail, comma: bool) !void {
    try appendJsonFieldString(buf, allocator, "id", detail.id, true);
    try appendJsonFieldString(buf, allocator, "state", detail.state, true);
    try appendJsonFieldString(buf, allocator, "title", detail.title, true);
    try appendJsonFieldString(buf, allocator, "body", detail.body, true);
    try appendJsonFieldString(buf, allocator, "base_ref", detail.base_ref, true);
    try appendJsonFieldString(buf, allocator, "head_ref", detail.head_ref, true);
    try appendJsonFieldBool(buf, allocator, "draft", detail.draft, true);
    try appendJsonFieldString(buf, allocator, "merge_oid", detail.merge_oid, true);
    try appendJsonFieldString(buf, allocator, "target_oid", detail.target_oid, true);
    try appendJsonFieldString(buf, allocator, "author_principal", detail.author_principal, true);
    try appendJsonFieldString(buf, allocator, "author_device", detail.author_device, true);
    try appendJsonFieldString(buf, allocator, "display_author", detail.displayAuthor(), true);
    if (detail.source_author.len != 0) try appendJsonFieldString(buf, allocator, "source_author", detail.source_author, true);
    try appendJsonFieldString(buf, allocator, "opened_at", detail.opened_at, true);
    try appendJsonFieldString(buf, allocator, "state_occurred_at", detail.state_occurred_at, true);
    try appendJsonFieldString(buf, allocator, "state_actor_principal", detail.state_actor_principal, true);
    if (detail.commit_count) |value| try appendJsonFieldInteger(buf, allocator, "commit_count", @intCast(value), true);
    if (detail.changed_files) |value| try appendJsonFieldInteger(buf, allocator, "changed_files", @intCast(value), true);
    if (detail.additions) |value| try appendJsonFieldInteger(buf, allocator, "additions", @intCast(value), true);
    if (detail.deletions) |value| try appendJsonFieldInteger(buf, allocator, "deletions", @intCast(value), true);
    if (detail.legacy_number > 0) try appendJsonFieldInteger(buf, allocator, "legacy_github_pull_number", detail.legacy_number, true);
    try appendStringArrayFieldFromQuery(buf, allocator, db, "labels", "SELECT DISTINCT label FROM pull_labels WHERE pull_id = ? ORDER BY label", detail.id, true);
    try appendStringArrayFieldFromQuery(buf, allocator, db, "assignees", "SELECT DISTINCT assignee FROM pull_assignees WHERE pull_id = ? ORDER BY assignee", detail.id, true);
    try appendStringArrayFieldFromQuery(buf, allocator, db, "reviewers", "SELECT DISTINCT reviewer FROM pull_reviewers WHERE pull_id = ? ORDER BY reviewer", detail.id, true);
    try appendCommitReferencesJsonField(buf, allocator, db, "commit_references", "pull", detail.id, true);
    try appendReactionsJsonField(buf, allocator, db, "reactions", "pull", detail.id, comma);
}

fn appendIssueListRowJson(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, row: IssueListRow) !void {
    var ref_buf: [util.short_object_ref_len]u8 = undefined;
    const short_ref = util.shortObjectRef(&ref_buf, row.id);
    try buf.append(allocator, '{');
    try appendJsonFieldString(buf, allocator, "ref", short_ref, true);
    try appendJsonFieldString(buf, allocator, "id", row.id, true);
    try appendJsonFieldString(buf, allocator, "state", row.state, true);
    try appendJsonFieldString(buf, allocator, "title", row.title, true);
    try appendJsonFieldString(buf, allocator, "author", row.author, true);
    try appendJsonFieldString(buf, allocator, "opened_at", row.opened_at, true);
    try appendJsonFieldString(buf, allocator, "state_at", row.state_at, true);
    if (row.legacy_number > 0) try appendJsonFieldInteger(buf, allocator, "legacy_github_issue_number", row.legacy_number, true);
    if (row.milestone.len != 0) try appendJsonFieldString(buf, allocator, "milestone", row.milestone, true);
    try appendJsonFieldInteger(buf, allocator, "comment_count", @intCast(row.comment_count), true);
    try appendStringArrayFieldFromQuery(buf, allocator, db, "labels", "SELECT DISTINCT label FROM issue_labels WHERE issue_id = ? ORDER BY label", row.id, true);
    try appendStringArrayFieldFromQuery(buf, allocator, db, "assignees", "SELECT DISTINCT assignee FROM issue_assignees WHERE issue_id = ? ORDER BY assignee", row.id, true);
    try appendIssueProjectsJsonField(buf, allocator, db, row.id, false);
    try buf.append(allocator, '}');
}

fn appendPullListRowJson(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, row: PullListRow) !void {
    var ref_buf: [util.short_object_ref_len]u8 = undefined;
    const short_ref = util.shortObjectRef(&ref_buf, row.id);
    try buf.append(allocator, '{');
    try appendJsonFieldString(buf, allocator, "ref", short_ref, true);
    try appendJsonFieldString(buf, allocator, "id", row.id, true);
    try appendJsonFieldString(buf, allocator, "state", row.state, true);
    try appendJsonFieldString(buf, allocator, "title", row.title, true);
    try appendJsonFieldString(buf, allocator, "author", row.author, true);
    try appendJsonFieldString(buf, allocator, "opened_at", row.opened_at, true);
    try appendJsonFieldString(buf, allocator, "state_at", row.state_at, true);
    try appendJsonFieldString(buf, allocator, "base_ref", row.base_ref, true);
    try appendJsonFieldString(buf, allocator, "head_ref", row.head_ref, true);
    try appendJsonFieldBool(buf, allocator, "draft", row.draft, true);
    if (row.legacy_number > 0) try appendJsonFieldInteger(buf, allocator, "legacy_github_pull_number", row.legacy_number, true);
    try appendJsonFieldInteger(buf, allocator, "comment_count", @intCast(row.comment_count), true);
    try appendStringArrayFieldFromQuery(buf, allocator, db, "labels", "SELECT DISTINCT label FROM pull_labels WHERE pull_id = ? ORDER BY label", row.id, true);
    try appendStringArrayFieldFromQuery(buf, allocator, db, "assignees", "SELECT DISTINCT assignee FROM pull_assignees WHERE pull_id = ? ORDER BY assignee", row.id, true);
    try appendStringArrayFieldFromQuery(buf, allocator, db, "reviewers", "SELECT DISTINCT reviewer FROM pull_reviewers WHERE pull_id = ? ORDER BY reviewer", row.id, false);
    try buf.append(allocator, '}');
}

fn appendIssueFiltersJsonField(buf: *std.ArrayList(u8), allocator: Allocator, filters: IssueListOptions, comma: bool) !void {
    try appendJsonString(buf, allocator, "filters");
    try buf.append(allocator, ':');
    try buf.append(allocator, '{');
    try appendJsonFieldString(buf, allocator, "state", issueStateValue(filters.state), true);
    try appendJsonFieldString(buf, allocator, "sort", issueSortValue(filters.sort), true);
    try appendOptionalStringJsonField(buf, allocator, "q", filters.q, true);
    try appendOptionalStringJsonField(buf, allocator, "author", filters.author, true);
    try appendOptionalStringJsonField(buf, allocator, "label", filters.label, true);
    try appendOptionalStringJsonField(buf, allocator, "project", filters.project, true);
    try appendOptionalStringJsonField(buf, allocator, "milestone", filters.milestone, true);
    try appendOptionalStringJsonField(buf, allocator, "assignee", filters.assignee, filters.limit != null);
    if (filters.limit) |value| try appendJsonFieldInteger(buf, allocator, "limit", @intCast(value), false);
    try buf.append(allocator, '}');
    if (comma) try buf.append(allocator, ',');
}

fn appendPullFiltersJsonField(buf: *std.ArrayList(u8), allocator: Allocator, filters: PullListOptions, comma: bool) !void {
    try appendJsonString(buf, allocator, "filters");
    try buf.append(allocator, ':');
    try buf.append(allocator, '{');
    try appendJsonFieldString(buf, allocator, "state", pullStateValue(filters.state), filters.limit != null);
    if (filters.limit) |value| try appendJsonFieldInteger(buf, allocator, "limit", @intCast(value), false);
    try buf.append(allocator, '}');
    if (comma) try buf.append(allocator, ',');
}

fn appendOptionalStringJsonField(buf: *std.ArrayList(u8), allocator: Allocator, key: []const u8, value: ?[]const u8, comma: bool) !void {
    if (value) |payload| {
        try appendJsonFieldString(buf, allocator, key, payload, comma);
    } else {
        try appendJsonString(buf, allocator, key);
        try buf.appendSlice(allocator, ":null");
        if (comma) try buf.append(allocator, ',');
    }
}

fn appendIssueCountsJsonField(buf: *std.ArrayList(u8), allocator: Allocator, counts: IssueCounts, comma: bool) !void {
    try appendJsonString(buf, allocator, "counts");
    try buf.appendSlice(allocator, ":{");
    try appendJsonFieldInteger(buf, allocator, "open", @intCast(counts.open), true);
    try appendJsonFieldInteger(buf, allocator, "closed", @intCast(counts.closed), true);
    try appendJsonFieldInteger(buf, allocator, "all", @intCast(counts.all), false);
    try buf.append(allocator, '}');
    if (comma) try buf.append(allocator, ',');
}

fn appendPullCountsJsonField(buf: *std.ArrayList(u8), allocator: Allocator, counts: PullCounts, comma: bool) !void {
    try appendJsonString(buf, allocator, "counts");
    try buf.appendSlice(allocator, ":{");
    try appendJsonFieldInteger(buf, allocator, "open", @intCast(counts.open), true);
    try appendJsonFieldInteger(buf, allocator, "merged", @intCast(counts.merged), true);
    try appendJsonFieldInteger(buf, allocator, "closed", @intCast(counts.closed), true);
    try appendJsonFieldInteger(buf, allocator, "all", @intCast(counts.all), false);
    try buf.append(allocator, '}');
    if (comma) try buf.append(allocator, ',');
}

pub fn appendStringArrayFieldFromQuery(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    key: []const u8,
    comptime sql_text: []const u8,
    object_id: []const u8,
    comma: bool,
) !void {
    try appendJsonString(buf, allocator, key);
    try buf.appendSlice(allocator, ":[");
    var stmt = try db.prepare(sql_text);
    defer stmt.deinit();
    try stmt.bindText(1, object_id);
    var first = true;
    while (try stmt.step()) {
        const value = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(value);
        if (!first) try buf.append(allocator, ',');
        first = false;
        try appendJsonString(buf, allocator, value);
    }
    try buf.append(allocator, ']');
    if (comma) try buf.append(allocator, ',');
}

pub fn appendIssueProjectsJsonField(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, issue_id: []const u8, comma: bool) !void {
    try appendJsonString(buf, allocator, "projects");
    try buf.appendSlice(allocator, ":[");
    var stmt = try db.prepare(
        \\SELECT DISTINCT project, column_name
        \\FROM issue_projects
        \\WHERE issue_id = ?
        \\ORDER BY project, column_name
    );
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    var first = true;
    while (try stmt.step()) {
        const project = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(project);
        const column = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(column);
        if (!first) try buf.append(allocator, ',');
        first = false;
        try buf.append(allocator, '{');
        try appendJsonFieldString(buf, allocator, "project", project, true);
        try appendJsonFieldString(buf, allocator, "column", column, false);
        try buf.append(allocator, '}');
    }
    try buf.append(allocator, ']');
    if (comma) try buf.append(allocator, ',');
}

pub fn appendCommitReferencesJsonField(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, key: []const u8, object_kind: []const u8, object_id: []const u8, comma: bool) !void {
    try appendJsonString(buf, allocator, key);
    try buf.appendSlice(allocator, ":[");
    var stmt = try db.prepare(
        \\SELECT commit_oid, prefix
        \\FROM commit_references
        \\WHERE object_kind = ? AND object_id = ?
        \\ORDER BY commit_oid
    );
    defer stmt.deinit();
    try stmt.bindText(1, object_kind);
    try stmt.bindText(2, object_id);
    var first = true;
    while (try stmt.step()) {
        const oid = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(oid);
        const prefix = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(prefix);
        if (!first) try buf.append(allocator, ',');
        first = false;
        try buf.append(allocator, '{');
        try appendJsonFieldString(buf, allocator, "commit_oid", oid, true);
        try appendJsonFieldString(buf, allocator, "prefix", prefix, false);
        try buf.append(allocator, '}');
    }
    try buf.append(allocator, ']');
    if (comma) try buf.append(allocator, ',');
}

pub fn appendReactionsJsonField(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, key: []const u8, object_kind: []const u8, object_id: []const u8, comma: bool) !void {
    try appendJsonString(buf, allocator, key);
    try buf.appendSlice(allocator, ":[");
    var stmt = try db.prepare(
        \\SELECT emoji, COUNT(DISTINCT actor_principal)
        \\FROM reactions
        \\WHERE object_kind = ? AND object_id = ?
        \\GROUP BY emoji
        \\ORDER BY MIN(created_at), emoji
    );
    defer stmt.deinit();
    try stmt.bindText(1, object_kind);
    try stmt.bindText(2, object_id);
    var first = true;
    while (try stmt.step()) {
        const emoji = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(emoji);
        const count = stmt.columnInt64(1);
        if (!first) try buf.append(allocator, ',');
        first = false;
        try buf.append(allocator, '{');
        try appendJsonFieldString(buf, allocator, "emoji", emoji, true);
        try appendJsonFieldInteger(buf, allocator, "count", count, true);
        try appendReactionActorsJsonField(buf, allocator, db, object_kind, object_id, emoji, false);
        try buf.append(allocator, '}');
    }
    try buf.append(allocator, ']');
    if (comma) try buf.append(allocator, ',');
}

fn appendReactionActorsJsonField(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, object_kind: []const u8, object_id: []const u8, emoji: []const u8, comma: bool) !void {
    try appendJsonString(buf, allocator, "actors");
    try buf.appendSlice(allocator, ":[");
    var stmt = try db.prepare(
        \\SELECT DISTINCT actor_principal
        \\FROM reactions
        \\WHERE object_kind = ? AND object_id = ? AND emoji = ?
        \\ORDER BY actor_principal
    );
    defer stmt.deinit();
    try stmt.bindText(1, object_kind);
    try stmt.bindText(2, object_id);
    try stmt.bindText(3, emoji);
    var first = true;
    while (try stmt.step()) {
        const actor = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(actor);
        if (!first) try buf.append(allocator, ',');
        first = false;
        try appendJsonString(buf, allocator, actor);
    }
    try buf.append(allocator, ']');
    if (comma) try buf.append(allocator, ',');
}

fn appendCommentsJsonField(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, key: []const u8, parent_kind: []const u8, parent_id: []const u8, comma: bool) !void {
    try appendJsonString(buf, allocator, key);
    try buf.appendSlice(allocator, ":[");
    var stmt = try prepareCommentsStmt(db, parent_kind, parent_id);
    defer stmt.deinit();
    var first = true;
    while (try stmt.step()) {
        var row = try commentRowFromStmt(allocator, &stmt);
        defer row.deinit(allocator);
        if (!first) try buf.append(allocator, ',');
        first = false;
        try appendCommentJson(buf, allocator, db, row);
    }
    try buf.append(allocator, ']');
    if (comma) try buf.append(allocator, ',');
}

fn appendCommentJson(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, row: CommentRow) !void {
    var ref_buf: [util.short_object_ref_len]u8 = undefined;
    const short_ref = util.shortObjectRef(&ref_buf, row.id);
    try buf.append(allocator, '{');
    try appendJsonFieldString(buf, allocator, "ref", short_ref, true);
    try appendJsonFieldString(buf, allocator, "id", row.id, true);
    try appendJsonFieldBool(buf, allocator, "redacted", row.redacted, true);
    try appendJsonFieldString(buf, allocator, "body", if (row.redacted) "" else row.body, true);
    try appendJsonFieldString(buf, allocator, "author_principal", row.author_principal, true);
    try appendJsonFieldString(buf, allocator, "author_device", row.author_device, true);
    try appendJsonFieldString(buf, allocator, "display_author", row.display_author, true);
    if (row.source_author.len != 0) try appendJsonFieldString(buf, allocator, "source_author", row.source_author, true);
    if (row.reply_parent_id.len != 0) try appendJsonFieldString(buf, allocator, "reply_parent_id", row.reply_parent_id, true);
    if (row.reply_parent_hash.len != 0) try appendJsonFieldString(buf, allocator, "reply_parent_hash", row.reply_parent_hash, true);
    try appendJsonFieldString(buf, allocator, "created_at", row.created_at, true);
    try appendReactionsJsonField(buf, allocator, db, "reactions", "comment", row.id, false);
    try buf.append(allocator, '}');
}

fn appendTimelineJsonField(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, key: []const u8, object_kind: []const u8, object_id: []const u8, comma: bool) !void {
    try appendJsonString(buf, allocator, key);
    try buf.appendSlice(allocator, ":[");
    var stmt = try prepareTimelineStmt(db, object_kind, object_id);
    defer stmt.deinit();
    var first = true;
    while (try stmt.step()) {
        var row = try timelineEventFromStmt(allocator, &stmt);
        defer row.deinit(allocator);
        if (!first) try buf.append(allocator, ',');
        first = false;
        try buf.append(allocator, '{');
        try appendJsonFieldString(buf, allocator, "event_type", row.event_type, true);
        try appendJsonFieldString(buf, allocator, "actor_principal", row.actor_principal, true);
        try appendJsonFieldString(buf, allocator, "occurred_at", row.occurred_at, true);
        try appendJsonFieldString(buf, allocator, "event_hash", row.event_hash, true);
        try appendJsonFieldString(buf, allocator, "body", row.body, false);
        try buf.append(allocator, '}');
    }
    try buf.append(allocator, ']');
    if (comma) try buf.append(allocator, ',');
}

fn appendIssueCommandsJsonField(buf: *std.ArrayList(u8), allocator: Allocator, issue_ref: []const u8, comma: bool) !void {
    try appendJsonString(buf, allocator, "cli_commands");
    try buf.appendSlice(allocator, ":{");
    try appendCommandField(buf, allocator, "refresh", "gt issue show #{s} --view agent", issue_ref, true);
    try appendCommandField(buf, allocator, "comment", "gt issue comment #{s} --body BODY", issue_ref, true);
    try appendCommandField(buf, allocator, "close", "gt issue close #{s} --body BODY", issue_ref, true);
    try appendCommandField(buf, allocator, "reopen", "gt issue reopen #{s} --body BODY", issue_ref, true);
    try appendCommandField(buf, allocator, "edit", "gt issue edit #{s} --title TITLE --body BODY", issue_ref, false);
    try buf.append(allocator, '}');
    if (comma) try buf.append(allocator, ',');
}

fn appendPullCommandsJsonField(buf: *std.ArrayList(u8), allocator: Allocator, pull_ref: []const u8, comma: bool) !void {
    try appendJsonString(buf, allocator, "cli_commands");
    try buf.appendSlice(allocator, ":{");
    try appendCommandField(buf, allocator, "refresh", "gt pr view #{s} --view agent", pull_ref, true);
    try appendCommandField(buf, allocator, "refresh_with_diff", "gt pr view #{s} --view agent --include-diff", pull_ref, true);
    try appendCommandField(buf, allocator, "comment", "gt pr comment #{s} --body BODY", pull_ref, true);
    try appendCommandField(buf, allocator, "review_line", "gt pr comment #{s} --body BODY --file PATH --side new --line LINE", pull_ref, true);
    try appendCommandField(buf, allocator, "merge", "gt pr merge #{s}", pull_ref, false);
    try buf.append(allocator, '}');
    if (comma) try buf.append(allocator, ',');
}

fn appendIssueListCommandsJsonField(buf: *std.ArrayList(u8), allocator: Allocator, comma: bool) !void {
    try appendJsonString(buf, allocator, "cli_commands");
    try buf.appendSlice(allocator, ":{");
    try appendJsonFieldString(buf, allocator, "show_agent", "gt issue show ISSUE --view agent", true);
    try appendJsonFieldString(buf, allocator, "open", "gt issue open --title TITLE --body BODY", false);
    try buf.append(allocator, '}');
    if (comma) try buf.append(allocator, ',');
}

fn appendPullListCommandsJsonField(buf: *std.ArrayList(u8), allocator: Allocator, comma: bool) !void {
    try appendJsonString(buf, allocator, "cli_commands");
    try buf.appendSlice(allocator, ":{");
    try appendJsonFieldString(buf, allocator, "show_agent", "gt pr view PR --view agent", true);
    try appendJsonFieldString(buf, allocator, "show_agent_with_diff", "gt pr view PR --view agent --include-diff", true);
    try appendJsonFieldString(buf, allocator, "create", "gt pr create --title TITLE --body BODY --base BASE --head HEAD", false);
    try buf.append(allocator, '}');
    if (comma) try buf.append(allocator, ',');
}

fn appendCommandField(buf: *std.ArrayList(u8), allocator: Allocator, key: []const u8, comptime pattern: []const u8, object_ref: []const u8, comma: bool) !void {
    const value = try std.fmt.allocPrint(allocator, pattern, .{object_ref});
    defer allocator.free(value);
    try appendJsonFieldString(buf, allocator, key, value, comma);
}

pub fn loadPullDiff(allocator: Allocator, repo: Repo, detail: PullDetail, context: usize) !?[]u8 {
    const git_refs = (try loadPullGitRefs(allocator, repo, detail)) orelse return null;
    defer git_refs.deinit(allocator);
    const merge_base = try loadMergeBase(allocator, repo, git_refs.base, git_refs.head);
    defer if (merge_base) |value| allocator.free(value);
    const base = merge_base orelse return null;
    const unified = try std.fmt.allocPrint(allocator, "--unified={d}", .{context});
    defer allocator.free(unified);
    return gitMaybe(allocator, repo, &.{ "diff", "--no-ext-diff", "--find-renames", "--patch", unified, base, git_refs.head }, max_pull_diff_bytes);
}

pub fn loadMergeBase(allocator: Allocator, repo: Repo, base_ref: []const u8, head_ref: []const u8) !?[]u8 {
    const raw = try gitMaybe(allocator, repo, &.{ "merge-base", base_ref, head_ref }, 1024 * 1024) orelse return null;
    defer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

pub fn loadPullGitRefs(allocator: Allocator, repo: Repo, detail: PullDetail) !?PullGitRefs {
    const prefer_remote = detail.legacy_number > 0;
    const base = (try resolvePullGitCommit(allocator, repo, detail.base_ref, prefer_remote)) orelse return null;
    errdefer allocator.free(base);
    const head: ?[]u8 = if (detail.legacy_number > 0) blk: {
        if (try resolveGithubPullHeadCommit(allocator, repo, detail.legacy_number)) |oid| break :blk oid;
        break :blk try resolvePullGitCommit(allocator, repo, detail.head_ref, prefer_remote);
    } else try resolvePullGitCommit(allocator, repo, detail.head_ref, prefer_remote);
    const owned_head = head orelse {
        allocator.free(base);
        return null;
    };
    return .{ .base = base, .head = owned_head };
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

fn resolvePullGitCommit(allocator: Allocator, repo: Repo, raw_ref: []const u8, prefer_remote: bool) !?[]u8 {
    if (prefer_remote and isBranchShorthand(raw_ref)) {
        const remote_ref = try std.fmt.allocPrint(allocator, "refs/remotes/origin/{s}", .{raw_ref});
        defer allocator.free(remote_ref);
        if (try resolveGitCommit(allocator, repo, remote_ref)) |oid| return oid;
    }
    if (try resolveGitCommit(allocator, repo, raw_ref)) |oid| return oid;
    if (!prefer_remote and isBranchShorthand(raw_ref)) {
        const remote_ref = try std.fmt.allocPrint(allocator, "refs/remotes/origin/{s}", .{raw_ref});
        defer allocator.free(remote_ref);
        if (try resolveGitCommit(allocator, repo, remote_ref)) |oid| return oid;
    }
    return null;
}

fn resolveGitCommit(allocator: Allocator, repo: Repo, ref: []const u8) !?[]u8 {
    const commit_ref = try std.fmt.allocPrint(allocator, "{s}^{{commit}}", .{ref});
    defer allocator.free(commit_ref);
    const raw = try gitMaybe(allocator, repo, &.{ "rev-parse", "--verify", "--quiet", commit_ref }, 1024 * 1024) orelse return null;
    defer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

fn isBranchShorthand(ref: []const u8) bool {
    if (ref.len == 0) return false;
    if (std.mem.startsWith(u8, ref, "refs/")) return false;
    if (std.mem.startsWith(u8, ref, "origin/")) return false;
    if (std.mem.startsWith(u8, ref, "-")) return false;
    if (std.mem.endsWith(u8, ref, ".lock")) return false;
    if (std.mem.indexOf(u8, ref, "..") != null) return false;
    if (std.mem.indexOf(u8, ref, "//") != null) return false;
    if (std.mem.indexOf(u8, ref, "@{") != null) return false;
    if (std.mem.indexOfAny(u8, ref, " \t\r\n\x00:^~?*[\\") != null) return false;
    return true;
}

pub fn gitMaybe(allocator: Allocator, repo: Repo, git_args: []const []const u8, max_output_bytes: usize) !?[]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    try argv.append(allocator, "-C");
    try argv.append(allocator, repo.root);
    for (git_args) |arg| try argv.append(allocator, arg);
    var result = try git.runCommand(allocator, argv.items, null, max_output_bytes);
    if (result.exitCode() == 0) {
        const stdout = result.stdout;
        allocator.free(result.stderr);
        return stdout;
    }
    result.deinit();
    return null;
}

pub const DiffCommentSide = enum {
    old,
    new,
};

pub const DiffCommentContext = struct {
    file: []const u8,
    side: DiffCommentSide,
    start_line: usize,
    end_line: usize,
};

pub fn formatDiffCommentBody(allocator: Allocator, context: DiffCommentContext, body: []const u8) ![]u8 {
    const side = switch (context.side) {
        .old => "old",
        .new => "new",
    };
    if (context.start_line == context.end_line) {
        return std.fmt.allocPrint(allocator, "Review comment on `{s}` ({s} line {d}).\n\n{s}", .{ context.file, side, context.start_line, body });
    }
    return std.fmt.allocPrint(allocator, "Review comment on `{s}` ({s} lines {d}-{d}).\n\n{s}", .{ context.file, side, context.start_line, context.end_line, body });
}

pub fn validateDiffCommentPath(path: []const u8) bool {
    return path.len != 0 and path.len <= 4096 and std.mem.indexOfAny(u8, path, "\r\n\x00") == null;
}

test "formats single-line and range diff comments" {
    const single = try formatDiffCommentBody(std.testing.allocator, .{
        .file = "src/main.zig",
        .side = .new,
        .start_line = 7,
        .end_line = 7,
    }, "Looks good");
    defer std.testing.allocator.free(single);
    try std.testing.expectEqualStrings("Review comment on `src/main.zig` (new line 7).\n\nLooks good", single);

    const range = try formatDiffCommentBody(std.testing.allocator, .{
        .file = "src/main.zig",
        .side = .old,
        .start_line = 3,
        .end_line = 5,
    }, "Needs work");
    defer std.testing.allocator.free(range);
    try std.testing.expectEqualStrings("Review comment on `src/main.zig` (old lines 3-5).\n\nNeeds work", range);
}
