const std = @import("std");

const git = @import("git.zig");
const index_schema = @import("index/schema.zig");
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

const issue_display_author_sql = "COALESCE(NULLIF(m.source_author, ''), NULLIF(si.display_name, ''), i.author_principal)";
const issue_avatar_url_sql = "COALESCE(NULLIF(m.source_avatar_url, ''), NULLIF(si.avatar_url, ''), '')";
const pull_display_author_sql = "COALESCE(NULLIF(pm.source_author, ''), NULLIF(sp.display_name, ''), p.author_principal)";
const pull_avatar_url_sql = "COALESCE(NULLIF(pm.source_avatar_url, ''), NULLIF(sp.avatar_url, ''), '')";
const comment_display_author_sql = "COALESCE(NULLIF(c.source_author, ''), NULLIF(sc.display_name, ''), c.author_principal)";
const comment_avatar_url_sql = "COALESCE(NULLIF(c.source_avatar_url, ''), NULLIF(sc.avatar_url, ''), '')";

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
    offset: ?usize = null,

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
    issue_type: []u8,
    priority: []u8,
    comment_count: usize,
    legacy_number: i64,
    body: []u8,
    author_avatar_url: []u8,

    pub fn deinit(self: IssueListRow, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        allocator.free(self.state);
        allocator.free(self.author);
        allocator.free(self.opened_at);
        allocator.free(self.state_at);
        allocator.free(self.milestone);
        allocator.free(self.issue_type);
        allocator.free(self.priority);
        allocator.free(self.body);
        allocator.free(self.author_avatar_url);
    }
};

pub const IssueDetail = struct {
    id: []u8,
    title: []u8,
    state: []u8,
    author_principal: []u8,
    author_device: []u8,
    source_author: []u8,
    display_author: []u8,
    source_avatar_url: []u8,
    opened_at: []u8,
    state_occurred_at: []u8,
    state_actor_principal: []u8,
    body: []u8,
    milestone: []u8,
    issue_type: []u8,
    priority: []u8,
    status: []u8,
    legacy_number: i64,
    comment_count: usize,

    pub fn deinit(self: IssueDetail, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        allocator.free(self.state);
        allocator.free(self.author_principal);
        allocator.free(self.author_device);
        allocator.free(self.source_author);
        allocator.free(self.display_author);
        allocator.free(self.source_avatar_url);
        allocator.free(self.opened_at);
        allocator.free(self.state_occurred_at);
        allocator.free(self.state_actor_principal);
        allocator.free(self.body);
        allocator.free(self.milestone);
        allocator.free(self.issue_type);
        allocator.free(self.priority);
        allocator.free(self.status);
    }

    pub fn displayAuthor(self: IssueDetail) []const u8 {
        return self.display_author;
    }
};

pub const PullStateFilter = enum {
    open,
    merged,
    closed,
    all,
};

pub const PullSort = enum {
    newest,
    oldest,
    updated,
};

pub const PullCounts = struct {
    open: usize = 0,
    merged: usize = 0,
    closed: usize = 0,
    all: usize = 0,
};

pub const PullListOptions = struct {
    state: PullStateFilter = .all,
    q: ?[]const u8 = null,
    author: ?[]const u8 = null,
    label: ?[]const u8 = null,
    assignee: ?[]const u8 = null,
    reviewer: ?[]const u8 = null,
    base: ?[]const u8 = null,
    head: ?[]const u8 = null,
    sort: PullSort = .newest,
    limit: ?usize = null,
    offset: ?usize = null,
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
    author_avatar_url: []u8,

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
        allocator.free(self.author_avatar_url);
    }
};

pub const PullDetail = struct {
    id: []u8,
    title: []u8,
    state: []u8,
    author_principal: []u8,
    author_device: []u8,
    source_author: []u8,
    display_author: []u8,
    source_avatar_url: []u8,
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
        allocator.free(self.display_author);
        allocator.free(self.source_avatar_url);
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
        return self.display_author;
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
    source_avatar_url: []u8,
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
        allocator.free(self.source_avatar_url);
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
        .all => "is:issue state:all",
    };
}

pub fn issueFilterQueryOwned(allocator: Allocator, filters: IssueListOptions) ![]u8 {
    var query: std.ArrayList(u8) = .empty;
    errdefer query.deinit(allocator);

    try appendSearchFilterToken(&query, allocator, "is", "issue");
    try appendSearchFilterToken(&query, allocator, "state", issueStateValue(filters.state));
    if (filters.author) |value| try appendSearchFilterToken(&query, allocator, "author", value);
    if (filters.label) |value| try appendSearchFilterToken(&query, allocator, "label", value);
    if (filters.project) |value| try appendSearchFilterToken(&query, allocator, "project", value);
    if (filters.milestone) |value| try appendSearchFilterToken(&query, allocator, "milestone", value);
    if (filters.assignee) |value| try appendSearchFilterToken(&query, allocator, "assignee", value);
    if (filters.sort != .newest) try appendSearchFilterToken(&query, allocator, "sort", issueSortValue(filters.sort));
    if (filters.q) |value| try appendSearchValueToken(&query, allocator, value);
    return query.toOwnedSlice(allocator);
}

pub fn issueStateFilterFromValue(value: []const u8) ?IssueStateFilter {
    if (std.mem.eql(u8, value, "open")) return .open;
    if (std.mem.eql(u8, value, "closed")) return .closed;
    if (std.mem.eql(u8, value, "all")) return .all;
    return null;
}

pub const ParsedIssueSearchQuery = struct {
    state: ?IssueStateFilter = null,
    q: ?[]u8 = null,
    author: ?[]u8 = null,
    label: ?[]u8 = null,
    project: ?[]u8 = null,
    milestone: ?[]u8 = null,
    assignee: ?[]u8 = null,
    sort: ?IssueSort = null,

    pub fn deinit(self: *ParsedIssueSearchQuery, allocator: Allocator) void {
        if (self.q) |value| allocator.free(value);
        if (self.author) |value| allocator.free(value);
        if (self.label) |value| allocator.free(value);
        if (self.project) |value| allocator.free(value);
        if (self.milestone) |value| allocator.free(value);
        if (self.assignee) |value| allocator.free(value);
    }
};

pub const ParsedPullSearchQuery = struct {
    state: ?PullStateFilter = null,
    q: ?[]u8 = null,
    author: ?[]u8 = null,
    label: ?[]u8 = null,
    assignee: ?[]u8 = null,
    reviewer: ?[]u8 = null,
    base: ?[]u8 = null,
    head: ?[]u8 = null,
    sort: ?PullSort = null,

    pub fn deinit(self: *ParsedPullSearchQuery, allocator: Allocator) void {
        if (self.q) |value| allocator.free(value);
        if (self.author) |value| allocator.free(value);
        if (self.label) |value| allocator.free(value);
        if (self.assignee) |value| allocator.free(value);
        if (self.reviewer) |value| allocator.free(value);
        if (self.base) |value| allocator.free(value);
        if (self.head) |value| allocator.free(value);
    }
};

const SearchToken = struct {
    value: []u8,
    quoted: bool = false,
};

const SearchPredicate = struct {
    key: []const u8,
    value: []const u8,
};

pub fn parseIssueSearchQuery(allocator: Allocator, query: []const u8) !ParsedIssueSearchQuery {
    var parsed: ParsedIssueSearchQuery = .{};
    errdefer parsed.deinit(allocator);

    var terms: std.ArrayList(u8) = .empty;
    errdefer terms.deinit(allocator);

    var cursor: usize = 0;
    while (try nextSearchTokenOwned(allocator, query, &cursor)) |token| {
        defer allocator.free(token.value);
        if (!token.quoted and try parseIssueSearchPredicate(allocator, &parsed, token.value)) continue;
        try appendSearchTerm(&terms, allocator, token.value);
    }

    if (terms.items.len != 0) parsed.q = try terms.toOwnedSlice(allocator);
    return parsed;
}

pub fn parsePullSearchQuery(allocator: Allocator, query: []const u8) !ParsedPullSearchQuery {
    var parsed: ParsedPullSearchQuery = .{};
    errdefer parsed.deinit(allocator);

    var terms: std.ArrayList(u8) = .empty;
    errdefer terms.deinit(allocator);

    var cursor: usize = 0;
    while (try nextSearchTokenOwned(allocator, query, &cursor)) |token| {
        defer allocator.free(token.value);
        if (!token.quoted and try parsePullSearchPredicate(allocator, &parsed, token.value)) continue;
        try appendSearchTerm(&terms, allocator, token.value);
    }

    if (terms.items.len != 0) parsed.q = try terms.toOwnedSlice(allocator);
    return parsed;
}

fn nextSearchTokenOwned(allocator: Allocator, query: []const u8, cursor: *usize) !?SearchToken {
    while (cursor.* < query.len and std.ascii.isWhitespace(query[cursor.*])) : (cursor.* += 1) {}
    if (cursor.* >= query.len) return null;

    var value: std.ArrayList(u8) = .empty;
    errdefer value.deinit(allocator);
    const starts_quoted = query[cursor.*] == '"';

    while (cursor.* < query.len) {
        const c = query[cursor.*];
        if (std.ascii.isWhitespace(c)) break;

        if (c == '"') {
            cursor.* += 1;
            while (cursor.* < query.len) {
                const quoted = query[cursor.*];
                if (quoted == '"') {
                    cursor.* += 1;
                    break;
                }
                if (quoted == '\\' and cursor.* + 1 < query.len) {
                    try value.append(allocator, query[cursor.* + 1]);
                    cursor.* += 2;
                    continue;
                }
                try value.append(allocator, quoted);
                cursor.* += 1;
            }
            continue;
        }

        try value.append(allocator, c);
        cursor.* += 1;
    }

    return .{ .value = try value.toOwnedSlice(allocator), .quoted = starts_quoted };
}

fn appendSearchTerm(terms: *std.ArrayList(u8), allocator: Allocator, value: []const u8) !void {
    if (value.len == 0) return;
    if (terms.items.len != 0) try terms.append(allocator, ' ');
    try terms.appendSlice(allocator, value);
}

fn parseIssueSearchPredicate(allocator: Allocator, parsed: *ParsedIssueSearchQuery, token: []const u8) !bool {
    const predicate = searchPredicate(token) orelse return false;
    if (std.ascii.eqlIgnoreCase(predicate.key, "is") or std.ascii.eqlIgnoreCase(predicate.key, "type")) {
        if (isIssueObjectValue(predicate.value)) return true;
        if (issueStateFilterFromValueIgnoreCase(predicate.value)) |state| {
            parsed.state = state;
            return true;
        }
        return false;
    }
    if (std.ascii.eqlIgnoreCase(predicate.key, "state")) {
        if (issueStateFilterFromValueIgnoreCase(predicate.value)) |state| {
            parsed.state = state;
            return true;
        }
        return false;
    }
    if (std.ascii.eqlIgnoreCase(predicate.key, "author")) return try setParsedSearchValue(allocator, &parsed.author, predicate.value);
    if (std.ascii.eqlIgnoreCase(predicate.key, "label")) return try setParsedSearchValue(allocator, &parsed.label, predicate.value);
    if (std.ascii.eqlIgnoreCase(predicate.key, "project")) return try setParsedSearchValue(allocator, &parsed.project, predicate.value);
    if (std.ascii.eqlIgnoreCase(predicate.key, "milestone")) return try setParsedSearchValue(allocator, &parsed.milestone, predicate.value);
    if (std.ascii.eqlIgnoreCase(predicate.key, "assignee")) return try setParsedSearchValue(allocator, &parsed.assignee, predicate.value);
    if (std.ascii.eqlIgnoreCase(predicate.key, "sort")) {
        if (issueSortFromValueIgnoreCase(predicate.value)) |sort| {
            parsed.sort = sort;
            return true;
        }
        return false;
    }
    return false;
}

fn parsePullSearchPredicate(allocator: Allocator, parsed: *ParsedPullSearchQuery, token: []const u8) !bool {
    const predicate = searchPredicate(token) orelse return false;
    if (std.ascii.eqlIgnoreCase(predicate.key, "is") or std.ascii.eqlIgnoreCase(predicate.key, "type")) {
        if (isPullObjectValue(predicate.value)) return true;
        if (pullStateFilterFromValueIgnoreCase(predicate.value)) |state| {
            parsed.state = state;
            return true;
        }
        return false;
    }
    if (std.ascii.eqlIgnoreCase(predicate.key, "state")) {
        if (pullStateFilterFromValueIgnoreCase(predicate.value)) |state| {
            parsed.state = state;
            return true;
        }
        return false;
    }
    if (std.ascii.eqlIgnoreCase(predicate.key, "author")) return try setParsedSearchValue(allocator, &parsed.author, predicate.value);
    if (std.ascii.eqlIgnoreCase(predicate.key, "label")) return try setParsedSearchValue(allocator, &parsed.label, predicate.value);
    if (std.ascii.eqlIgnoreCase(predicate.key, "assignee")) return try setParsedSearchValue(allocator, &parsed.assignee, predicate.value);
    if (std.ascii.eqlIgnoreCase(predicate.key, "reviewer")) return try setParsedSearchValue(allocator, &parsed.reviewer, predicate.value);
    if (std.ascii.eqlIgnoreCase(predicate.key, "base")) return try setParsedSearchValue(allocator, &parsed.base, predicate.value);
    if (std.ascii.eqlIgnoreCase(predicate.key, "head")) return try setParsedSearchValue(allocator, &parsed.head, predicate.value);
    if (std.ascii.eqlIgnoreCase(predicate.key, "sort")) {
        if (pullSortFromValueIgnoreCase(predicate.value)) |sort| {
            parsed.sort = sort;
            return true;
        }
        return false;
    }
    return false;
}

fn searchPredicate(token: []const u8) ?SearchPredicate {
    const colon = std.mem.indexOfScalar(u8, token, ':') orelse return null;
    if (colon == 0) return null;
    return .{
        .key = token[0..colon],
        .value = token[colon + 1 ..],
    };
}

fn setParsedSearchValue(allocator: Allocator, slot: *?[]u8, value: []const u8) !bool {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return true;
    const owned = try allocator.dupe(u8, trimmed);
    if (slot.*) |previous| allocator.free(previous);
    slot.* = owned;
    return true;
}

fn isIssueObjectValue(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "issue") or std.ascii.eqlIgnoreCase(value, "issues");
}

fn isPullObjectValue(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "pr") or
        std.ascii.eqlIgnoreCase(value, "prs") or
        std.ascii.eqlIgnoreCase(value, "pull") or
        std.ascii.eqlIgnoreCase(value, "pulls") or
        std.ascii.eqlIgnoreCase(value, "pull-request") or
        std.ascii.eqlIgnoreCase(value, "pull-requests");
}

fn issueStateFilterFromValueIgnoreCase(value: []const u8) ?IssueStateFilter {
    if (std.ascii.eqlIgnoreCase(value, "open")) return .open;
    if (std.ascii.eqlIgnoreCase(value, "closed")) return .closed;
    if (std.ascii.eqlIgnoreCase(value, "all")) return .all;
    return null;
}

fn pullStateFilterFromValueIgnoreCase(value: []const u8) ?PullStateFilter {
    if (std.ascii.eqlIgnoreCase(value, "open")) return .open;
    if (std.ascii.eqlIgnoreCase(value, "merged")) return .merged;
    if (std.ascii.eqlIgnoreCase(value, "closed")) return .closed;
    if (std.ascii.eqlIgnoreCase(value, "all")) return .all;
    return null;
}

fn issueSortFromValueIgnoreCase(value: []const u8) ?IssueSort {
    if (std.ascii.eqlIgnoreCase(value, "newest")) return .newest;
    if (std.ascii.eqlIgnoreCase(value, "oldest")) return .oldest;
    if (std.ascii.eqlIgnoreCase(value, "updated")) return .updated;
    return null;
}

pub fn issueSortFromValue(value: []const u8) ?IssueSort {
    if (std.mem.eql(u8, value, "newest")) return .newest;
    if (std.mem.eql(u8, value, "oldest")) return .oldest;
    if (std.mem.eql(u8, value, "updated")) return .updated;
    return null;
}

fn pullSortFromValueIgnoreCase(value: []const u8) ?PullSort {
    if (std.ascii.eqlIgnoreCase(value, "newest")) return .newest;
    if (std.ascii.eqlIgnoreCase(value, "oldest")) return .oldest;
    if (std.ascii.eqlIgnoreCase(value, "updated")) return .updated;
    return null;
}

pub fn pullSortFromValue(value: []const u8) ?PullSort {
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

pub fn hasRestrictivePullFilters(filters: PullListOptions) bool {
    return filters.q != null or
        filters.author != null or
        filters.label != null or
        filters.assignee != null or
        filters.reviewer != null or
        filters.base != null or
        filters.head != null;
}

pub fn pullStateValue(filter: PullStateFilter) []const u8 {
    return switch (filter) {
        .open => "open",
        .merged => "merged",
        .closed => "closed",
        .all => "all",
    };
}

pub fn pullSortValue(sort: PullSort) []const u8 {
    return switch (sort) {
        .newest => "newest",
        .oldest => "oldest",
        .updated => "updated",
    };
}

pub fn pullSearchQuery(filter: PullStateFilter) []const u8 {
    return switch (filter) {
        .open => "is:pr state:open",
        .merged => "is:pr state:merged",
        .closed => "is:pr state:closed",
        .all => "is:pr state:all",
    };
}

pub fn pullFilterQueryOwned(allocator: Allocator, filters: PullListOptions) ![]u8 {
    var query: std.ArrayList(u8) = .empty;
    errdefer query.deinit(allocator);

    try appendSearchFilterToken(&query, allocator, "is", "pr");
    try appendSearchFilterToken(&query, allocator, "state", pullStateValue(filters.state));
    if (filters.author) |value| try appendSearchFilterToken(&query, allocator, "author", value);
    if (filters.label) |value| try appendSearchFilterToken(&query, allocator, "label", value);
    if (filters.assignee) |value| try appendSearchFilterToken(&query, allocator, "assignee", value);
    if (filters.reviewer) |value| try appendSearchFilterToken(&query, allocator, "reviewer", value);
    if (filters.base) |value| try appendSearchFilterToken(&query, allocator, "base", value);
    if (filters.head) |value| try appendSearchFilterToken(&query, allocator, "head", value);
    if (filters.sort != .newest) try appendSearchFilterToken(&query, allocator, "sort", pullSortValue(filters.sort));
    if (filters.q) |value| try appendSearchValueToken(&query, allocator, value);
    return query.toOwnedSlice(allocator);
}

fn appendSearchFilterToken(query: *std.ArrayList(u8), allocator: Allocator, key: []const u8, value: []const u8) !void {
    if (value.len == 0) return;
    try appendSearchTokenSeparator(query, allocator);
    try query.appendSlice(allocator, key);
    try query.append(allocator, ':');
    try appendSearchTokenValue(query, allocator, value);
}

fn appendSearchValueToken(query: *std.ArrayList(u8), allocator: Allocator, value: []const u8) !void {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return;
    try appendSearchTokenSeparator(query, allocator);
    try appendSearchTokenValue(query, allocator, trimmed);
}

fn appendSearchTokenSeparator(query: *std.ArrayList(u8), allocator: Allocator) !void {
    if (query.items.len != 0) try query.append(allocator, ' ');
}

fn appendSearchTokenValue(query: *std.ArrayList(u8), allocator: Allocator, value: []const u8) !void {
    if (!searchTokenNeedsQuote(value)) {
        try query.appendSlice(allocator, value);
        return;
    }

    try query.append(allocator, '"');
    for (value) |c| {
        if (c == '"' or c == '\\') try query.append(allocator, '\\');
        try query.append(allocator, c);
    }
    try query.append(allocator, '"');
}

fn searchTokenNeedsQuote(value: []const u8) bool {
    if (value.len == 0) return true;
    for (value) |c| {
        if (std.ascii.isWhitespace(c) or c == ':' or c == '"' or c == '\\') return true;
    }
    return false;
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
        \\
    ++ issue_display_author_sql ++
        \\,
        \\       i.opened_at, i.state_occurred_at, COALESCE(m.milestone, ''),
        \\       COALESCE(m.issue_type, ''), COALESCE(m.priority, ''),
        \\       (SELECT COUNT(*) FROM comments c WHERE c.parent_kind = 'issue' AND c.parent_id = i.id),
        \\       COALESCE(a.number, 0), i.body,
        \\
    ++ issue_avatar_url_sql ++
        \\
        \\FROM issues i
        \\LEFT JOIN issue_metadata m ON m.issue_id = i.id
        \\LEFT JOIN identities si ON si.id = m.source_identity
        \\LEFT JOIN legacy_aliases a
        \\  ON a.provider = 'github' AND a.object_kind = 'issue' AND a.object_id = i.id
    );

    var conditions: usize = 0;
    if (filters.state != .all) try appendIssueListCondition(&sql, allocator, &conditions, "i.state = ?");
    if (filters.q != null) {
        try appendIssueListCondition(&sql, allocator, &conditions,
            \\(i.title LIKE ? ESCAPE '\' OR i.body LIKE ? ESCAPE '\' OR
        ++ issue_display_author_sql ++
            \\ LIKE ? ESCAPE '\' OR EXISTS (SELECT 1 FROM comments c WHERE c.parent_kind = 'issue' AND c.parent_id = i.id AND c.body LIKE ? ESCAPE '\'))
        );
    }
    if (filters.author != null) try appendIssueListCondition(&sql, allocator, &conditions, issue_display_author_sql ++ " = ?");
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
    if (filters.limit != null and filters.offset != null) try sql.appendSlice(allocator, "\nOFFSET ?");
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
        idx += 1;
    }
    if (filters.limit != null) {
        if (filters.offset) |value| {
            try stmt.bindInt64(idx, @intCast(value));
        }
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
        .issue_type = try stmt.columnTextDup(allocator, 7),
        .priority = try stmt.columnTextDup(allocator, 8),
        .comment_count = @as(usize, @intCast(stmt.columnInt64(9))),
        .legacy_number = stmt.columnInt64(10),
        .body = try stmt.columnTextDup(allocator, 11),
        .author_avatar_url = try stmt.columnTextDup(allocator, 12),
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
        \\       COALESCE(m.source_author, ''),
    ++ issue_display_author_sql ++
        \\,
    ++ issue_avatar_url_sql ++
        \\, COALESCE(m.milestone, ''),
        \\       COALESCE(m.issue_type, ''), COALESCE(m.priority, ''), COALESCE(m.status, ''), COALESCE(a.number, 0),
        \\       i.state_occurred_at, i.state_actor_principal,
        \\       (SELECT COUNT(*) FROM comments c WHERE c.parent_kind = 'issue' AND c.parent_id = i.id)
        \\FROM issues i
        \\LEFT JOIN issue_metadata m ON m.issue_id = i.id
        \\LEFT JOIN identities si ON si.id = m.source_identity
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
        .display_author = try stmt.columnTextDup(allocator, 8),
        .source_avatar_url = try stmt.columnTextDup(allocator, 9),
        .milestone = try stmt.columnTextDup(allocator, 10),
        .issue_type = try stmt.columnTextDup(allocator, 11),
        .priority = try stmt.columnTextDup(allocator, 12),
        .status = try stmt.columnTextDup(allocator, 13),
        .legacy_number = stmt.columnInt64(14),
        .state_occurred_at = try stmt.columnTextDup(allocator, 15),
        .state_actor_principal = try stmt.columnTextDup(allocator, 16),
        .comment_count = @as(usize, @intCast(stmt.columnInt64(17))),
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

pub fn pullListSql(allocator: Allocator, options: PullListOptions) ![]u8 {
    var sql: std.ArrayList(u8) = .empty;
    errdefer sql.deinit(allocator);

    try sql.appendSlice(allocator,
        \\SELECT p.id, p.title, p.state,
    ++ pull_display_author_sql ++
        \\, p.opened_at, p.state_occurred_at,
        \\       p.base_ref, p.head_ref, p.draft,
        \\       (SELECT COUNT(*) FROM comments c WHERE c.parent_kind = 'pull' AND c.parent_id = p.id),
        \\       COALESCE(a.number, 0), p.body,
        \\
    ++ pull_avatar_url_sql ++
        \\
        \\FROM pulls p
        \\LEFT JOIN legacy_aliases a
        \\  ON a.provider = 'github' AND a.object_kind = 'pull' AND a.object_id = p.id
        \\LEFT JOIN pull_metadata pm ON pm.pull_id = p.id
        \\LEFT JOIN identities sp ON sp.id = pm.source_identity
    );

    var conditions: usize = 0;
    if (options.state != .all) try appendPullListCondition(&sql, allocator, &conditions, "p.state = ?");
    if (options.q != null) {
        try appendPullListCondition(&sql, allocator, &conditions,
            \\(p.title LIKE ? ESCAPE '\' OR p.body LIKE ? ESCAPE '\' OR
        ++ pull_display_author_sql ++
            \\ LIKE ? ESCAPE '\' OR p.base_ref LIKE ? ESCAPE '\' OR p.head_ref LIKE ? ESCAPE '\' OR EXISTS (SELECT 1 FROM comments c WHERE c.parent_kind = 'pull' AND c.parent_id = p.id AND c.body LIKE ? ESCAPE '\'))
        );
    }
    if (options.author != null) try appendPullListCondition(&sql, allocator, &conditions, pull_display_author_sql ++ " = ?");
    if (options.label != null) try appendPullListCondition(&sql, allocator, &conditions, "EXISTS (SELECT 1 FROM pull_labels pl WHERE pl.pull_id = p.id AND pl.label = ?)");
    if (options.assignee != null) try appendPullListCondition(&sql, allocator, &conditions, "EXISTS (SELECT 1 FROM pull_assignees pa WHERE pa.pull_id = p.id AND pa.assignee = ?)");
    if (options.reviewer != null) try appendPullListCondition(&sql, allocator, &conditions, "EXISTS (SELECT 1 FROM pull_reviewers pr WHERE pr.pull_id = p.id AND pr.reviewer = ?)");
    if (options.base != null) try appendPullListCondition(&sql, allocator, &conditions, "p.base_ref = ?");
    if (options.head != null) try appendPullListCondition(&sql, allocator, &conditions, "p.head_ref = ?");

    try sql.appendSlice(allocator, switch (options.sort) {
        .newest => "\nORDER BY p.opened_at DESC, p.id DESC",
        .oldest => "\nORDER BY p.opened_at ASC, p.id ASC",
        .updated => "\nORDER BY p.state_occurred_at DESC, p.opened_at DESC, p.id DESC",
    });
    if (options.limit) |_| try sql.appendSlice(allocator, "\nLIMIT ?");
    if (options.limit != null and options.offset != null) try sql.appendSlice(allocator, "\nOFFSET ?");
    return sql.toOwnedSlice(allocator);
}

fn appendPullListCondition(sql: *std.ArrayList(u8), allocator: Allocator, conditions: *usize, condition: []const u8) !void {
    try sql.appendSlice(allocator, if (conditions.* == 0) "\nWHERE " else "\n  AND ");
    try sql.appendSlice(allocator, condition);
    conditions.* += 1;
}

pub fn preparePullListStmt(allocator: Allocator, db: *SqliteDb, options: PullListOptions) !SqliteStmt {
    const sql = try pullListSql(allocator, options);
    defer allocator.free(sql);
    var stmt = try db.prepare(sql);
    errdefer stmt.deinit();
    const search_pattern = if (options.q) |query| try sqliteLikePatternOwned(allocator, query) else null;
    defer if (search_pattern) |pattern| allocator.free(pattern);
    try bindPullListFilters(&stmt, options, search_pattern);
    return stmt;
}

pub fn bindPullListFilters(stmt: *SqliteStmt, filters: PullListOptions, search_pattern: ?[]const u8) !void {
    var idx: c_int = 1;
    if (filters.state != .all) {
        try stmt.bindText(idx, pullStateValue(filters.state));
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
    if (filters.assignee) |value| {
        try stmt.bindText(idx, value);
        idx += 1;
    }
    if (filters.reviewer) |value| {
        try stmt.bindText(idx, value);
        idx += 1;
    }
    if (filters.base) |value| {
        try stmt.bindText(idx, value);
        idx += 1;
    }
    if (filters.head) |value| {
        try stmt.bindText(idx, value);
        idx += 1;
    }
    if (filters.limit) |value| {
        try stmt.bindInt64(idx, @intCast(value));
        idx += 1;
    }
    if (filters.limit != null) {
        if (filters.offset) |value| {
            try stmt.bindInt64(idx, @intCast(value));
        }
    }
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
        .author_avatar_url = try stmt.columnTextDup(allocator, 12),
    };
}

pub fn loadPullDetail(allocator: Allocator, db: *SqliteDb, pull_id: []const u8) !?PullDetail {
    var stmt = try db.prepare(
        \\SELECT p.id, p.title, p.state, p.author_principal, p.author_device, p.opened_at, p.body,
        \\       p.base_ref, p.head_ref, p.draft, p.merge_oid, p.target_oid, COALESCE(a.number, 0),
        \\       p.state_occurred_at, p.state_actor_principal,
        \\       COALESCE(pm.source_author, ''),
    ++ pull_display_author_sql ++
        \\,
    ++ pull_avatar_url_sql ++
        \\, COALESCE(pm.commit_count, -1), COALESCE(pm.changed_files, -1),
        \\       COALESCE(pm.additions, -1), COALESCE(pm.deletions, -1)
        \\FROM pulls p
        \\LEFT JOIN legacy_aliases a
        \\  ON a.provider = 'github' AND a.object_kind = 'pull' AND a.object_id = p.id
        \\LEFT JOIN pull_metadata pm ON pm.pull_id = p.id
        \\LEFT JOIN identities sp ON sp.id = pm.source_identity
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
        .display_author = try stmt.columnTextDup(allocator, 16),
        .source_avatar_url = try stmt.columnTextDup(allocator, 17),
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
        .commit_count = optionalCount(stmt.columnInt64(18)),
        .changed_files = optionalCount(stmt.columnInt64(19)),
        .additions = optionalCount(stmt.columnInt64(20)),
        .deletions = optionalCount(stmt.columnInt64(21)),
    };
}

pub fn optionalCount(value: i64) ?usize {
    return if (value >= 0) @as(usize, @intCast(value)) else null;
}

pub fn prepareCommentsStmt(db: *SqliteDb, parent_kind: []const u8, parent_id: []const u8) !SqliteStmt {
    var stmt = try db.prepare(
        \\SELECT c.id, c.body, c.redacted, c.author_principal, c.author_device, c.source_author,
        \\
    ++ comment_display_author_sql ++
        \\,
    ++ comment_avatar_url_sql ++
        \\,
        \\       c.created_at, c.reply_parent_id, c.reply_parent_hash
        \\FROM comments c
        \\LEFT JOIN identities sc ON sc.id = c.source_identity
        \\WHERE c.parent_kind = ? AND c.parent_id = ?
        \\ORDER BY c.created_at, c.id
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
        .source_avatar_url = try stmt.columnTextDup(allocator, 7),
        .created_at = try stmt.columnTextDup(allocator, 8),
        .reply_parent_id = try stmt.columnTextDup(allocator, 9),
        .reply_parent_hash = try stmt.columnTextDup(allocator, 10),
    };
}

pub fn prepareTimelineStmt(db: *SqliteDb, object_kind: []const u8, object_id: []const u8) !SqliteStmt {
    const event_types = if (std.mem.eql(u8, object_kind, "issue"))
        \\(
        \\    'issue.title_set',
        \\    'issue.body_set',
        \\    'issue.state_set',
        \\    'issue.type_set',
        \\    'issue.priority_set',
        \\    'issue.status_set',
        \\    'issue.updated',
        \\    'issue.label_added',
        \\    'issue.label_removed',
        \\    'issue.assignee_added',
        \\    'issue.assignee_removed',
        \\    'issue.milestone_set',
        \\    'issue.project_added',
        \\    'issue.project_removed',
        \\    'issue.relationship_added',
        \\    'issue.relationship_removed',
        \\    'issue.concurrent_group_added',
        \\    'issue.concurrent_group_removed'
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
    var stmt = try preparePullListStmt(allocator, db, filters);
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
    if (detail.source_avatar_url.len != 0) try appendJsonFieldString(buf, allocator, "source_avatar_url", detail.source_avatar_url, true);
    try appendJsonFieldString(buf, allocator, "opened_at", detail.opened_at, true);
    try appendJsonFieldString(buf, allocator, "state_occurred_at", detail.state_occurred_at, true);
    try appendJsonFieldString(buf, allocator, "state_actor_principal", detail.state_actor_principal, true);
    if (detail.legacy_number > 0) try appendJsonFieldInteger(buf, allocator, "legacy_github_issue_number", detail.legacy_number, true);
    if (detail.milestone.len != 0) try appendJsonFieldString(buf, allocator, "milestone", detail.milestone, true);
    if (detail.issue_type.len != 0) try appendJsonFieldString(buf, allocator, "type", detail.issue_type, true);
    if (detail.priority.len != 0) try appendJsonFieldString(buf, allocator, "priority", detail.priority, true);
    if (detail.status.len != 0) try appendJsonFieldString(buf, allocator, "status", detail.status, true);
    try appendJsonFieldInteger(buf, allocator, "comment_count", @intCast(detail.comment_count), true);
    try appendStringArrayFieldFromQuery(buf, allocator, db, "labels", "SELECT DISTINCT label FROM issue_labels WHERE issue_id = ? ORDER BY label", detail.id, true);
    try appendStringArrayFieldFromQuery(buf, allocator, db, "assignees", "SELECT DISTINCT assignee FROM issue_assignees WHERE issue_id = ? ORDER BY assignee", detail.id, true);
    try appendIssueProjectsJsonField(buf, allocator, db, detail.id, true);
    try appendCommitReferencesJsonField(buf, allocator, db, "commit_references", "issue", detail.id, true);
    try appendIssueRelationshipsJsonField(buf, allocator, db, detail.id, true);
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
    if (detail.source_avatar_url.len != 0) try appendJsonFieldString(buf, allocator, "source_avatar_url", detail.source_avatar_url, true);
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
    if (row.author_avatar_url.len != 0) try appendJsonFieldString(buf, allocator, "author_avatar_url", row.author_avatar_url, true);
    try appendJsonFieldString(buf, allocator, "opened_at", row.opened_at, true);
    try appendJsonFieldString(buf, allocator, "state_at", row.state_at, true);
    if (row.legacy_number > 0) try appendJsonFieldInteger(buf, allocator, "legacy_github_issue_number", row.legacy_number, true);
    if (row.milestone.len != 0) try appendJsonFieldString(buf, allocator, "milestone", row.milestone, true);
    if (row.issue_type.len != 0) try appendJsonFieldString(buf, allocator, "type", row.issue_type, true);
    if (row.priority.len != 0) try appendJsonFieldString(buf, allocator, "priority", row.priority, true);
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
    if (row.author_avatar_url.len != 0) try appendJsonFieldString(buf, allocator, "author_avatar_url", row.author_avatar_url, true);
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
    try appendJsonFieldString(buf, allocator, "state", pullStateValue(filters.state), true);
    try appendJsonFieldString(buf, allocator, "sort", pullSortValue(filters.sort), true);
    try appendOptionalStringJsonField(buf, allocator, "q", filters.q, true);
    try appendOptionalStringJsonField(buf, allocator, "author", filters.author, true);
    try appendOptionalStringJsonField(buf, allocator, "label", filters.label, true);
    try appendOptionalStringJsonField(buf, allocator, "assignee", filters.assignee, true);
    try appendOptionalStringJsonField(buf, allocator, "reviewer", filters.reviewer, true);
    try appendOptionalStringJsonField(buf, allocator, "base", filters.base, true);
    try appendOptionalStringJsonField(buf, allocator, "head", filters.head, filters.limit != null);
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

pub fn appendIssueRelationshipsJsonField(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, issue_id: []const u8, comma: bool) !void {
    try appendJsonString(buf, allocator, "relationships");
    try buf.appendSlice(allocator, ":{");
    try appendIssueRelationshipArrayJsonField(buf, allocator, db, "parent", issue_id,
        \\SELECT DISTINCT i.id, i.title, i.state, COALESCE(m.status, ''), COALESCE(a.number, 0)
        \\FROM issue_relationships r
        \\JOIN issues i ON i.id = r.target_issue_id
        \\LEFT JOIN issue_metadata m ON m.issue_id = i.id
        \\LEFT JOIN legacy_aliases a ON a.provider = 'github' AND a.object_kind = 'issue' AND a.object_id = i.id
        \\WHERE r.source_issue_id = ? AND r.relationship = 'parent'
        \\ORDER BY i.opened_at, i.id
    , true);
    try appendIssueRelationshipArrayJsonField(buf, allocator, db, "sub_issues", issue_id,
        \\SELECT DISTINCT i.id, i.title, i.state, COALESCE(m.status, ''), COALESCE(a.number, 0)
        \\FROM issue_relationships r
        \\JOIN issues i ON i.id = r.source_issue_id
        \\LEFT JOIN issue_metadata m ON m.issue_id = i.id
        \\LEFT JOIN legacy_aliases a ON a.provider = 'github' AND a.object_kind = 'issue' AND a.object_id = i.id
        \\WHERE r.target_issue_id = ? AND r.relationship = 'parent'
        \\ORDER BY i.opened_at, i.id
    , true);
    try appendIssueRelationshipArrayJsonField(buf, allocator, db, "blocked_by", issue_id,
        \\SELECT DISTINCT i.id, i.title, i.state, COALESCE(m.status, ''), COALESCE(a.number, 0)
        \\FROM issue_relationships r
        \\JOIN issues i ON i.id = r.source_issue_id
        \\LEFT JOIN issue_metadata m ON m.issue_id = i.id
        \\LEFT JOIN legacy_aliases a ON a.provider = 'github' AND a.object_kind = 'issue' AND a.object_id = i.id
        \\WHERE r.target_issue_id = ? AND r.relationship = 'blocks'
        \\ORDER BY i.opened_at, i.id
    , true);
    try appendIssueRelationshipArrayJsonField(buf, allocator, db, "blocking", issue_id,
        \\SELECT DISTINCT i.id, i.title, i.state, COALESCE(m.status, ''), COALESCE(a.number, 0)
        \\FROM issue_relationships r
        \\JOIN issues i ON i.id = r.target_issue_id
        \\LEFT JOIN issue_metadata m ON m.issue_id = i.id
        \\LEFT JOIN legacy_aliases a ON a.provider = 'github' AND a.object_kind = 'issue' AND a.object_id = i.id
        \\WHERE r.source_issue_id = ? AND r.relationship = 'blocks'
        \\ORDER BY i.opened_at, i.id
    , true);
    try appendConcurrentGroupsJsonField(buf, allocator, db, issue_id, false);
    try buf.append(allocator, '}');
    if (comma) try buf.append(allocator, ',');
}

fn appendIssueRelationshipArrayJsonField(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    key: []const u8,
    issue_id: []const u8,
    comptime sql_text: []const u8,
    comma: bool,
) !void {
    try appendJsonString(buf, allocator, key);
    try buf.appendSlice(allocator, ":[");
    var stmt = try db.prepare(sql_text);
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    var first = true;
    while (try stmt.step()) {
        if (!first) try buf.append(allocator, ',');
        first = false;
        try appendIssueRelationshipTargetJson(buf, allocator, &stmt);
    }
    try buf.append(allocator, ']');
    if (comma) try buf.append(allocator, ',');
}

fn appendConcurrentGroupsJsonField(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, issue_id: []const u8, comma: bool) !void {
    try appendJsonString(buf, allocator, "concurrent_groups");
    try buf.appendSlice(allocator, ":[");
    var groups = try db.prepare(
        \\SELECT DISTINCT group_key
        \\FROM issue_concurrent_groups
        \\WHERE issue_id = ?
        \\ORDER BY lower(group_key), group_key
    );
    defer groups.deinit();
    try groups.bindText(1, issue_id);
    var first_group = true;
    while (try groups.step()) {
        const group = try groups.columnTextDup(allocator, 0);
        defer allocator.free(group);
        if (!first_group) try buf.append(allocator, ',');
        first_group = false;
        try buf.append(allocator, '{');
        try appendJsonFieldString(buf, allocator, "group", group, true);
        try appendJsonString(buf, allocator, "members");
        try buf.appendSlice(allocator, ":[");
        var members = try db.prepare(
            \\SELECT DISTINCT i.id, i.title, i.state, COALESCE(m.status, ''), COALESCE(a.number, 0)
            \\FROM issue_concurrent_groups g
            \\JOIN issues i ON i.id = g.issue_id
            \\LEFT JOIN issue_metadata m ON m.issue_id = i.id
            \\LEFT JOIN legacy_aliases a ON a.provider = 'github' AND a.object_kind = 'issue' AND a.object_id = i.id
            \\WHERE g.group_key = ?
            \\ORDER BY CASE WHEN i.id = ? THEN 0 ELSE 1 END, i.opened_at, i.id
        );
        defer members.deinit();
        try members.bindText(1, group);
        try members.bindText(2, issue_id);
        var first_member = true;
        while (try members.step()) {
            if (!first_member) try buf.append(allocator, ',');
            first_member = false;
            try appendIssueRelationshipTargetJson(buf, allocator, &members);
        }
        try buf.appendSlice(allocator, "]}");
    }
    try buf.append(allocator, ']');
    if (comma) try buf.append(allocator, ',');
}

fn appendIssueRelationshipTargetJson(buf: *std.ArrayList(u8), allocator: Allocator, stmt: *SqliteStmt) !void {
    const id = try stmt.columnTextDup(allocator, 0);
    defer allocator.free(id);
    const title = try stmt.columnTextDup(allocator, 1);
    defer allocator.free(title);
    const state = try stmt.columnTextDup(allocator, 2);
    defer allocator.free(state);
    const status = try stmt.columnTextDup(allocator, 3);
    defer allocator.free(status);
    const legacy_number = stmt.columnInt64(4);
    var ref_buf: [util.short_object_ref_len]u8 = undefined;
    const short_ref = util.shortObjectRef(&ref_buf, id);
    try buf.append(allocator, '{');
    try appendJsonFieldString(buf, allocator, "id", id, true);
    try appendJsonFieldString(buf, allocator, "ref", short_ref, true);
    if (legacy_number > 0) try appendJsonFieldInteger(buf, allocator, "legacy_github_issue_number", legacy_number, true);
    try appendJsonFieldString(buf, allocator, "title", title, true);
    try appendJsonFieldString(buf, allocator, "state", state, true);
    try appendJsonFieldString(buf, allocator, "status", status, false);
    try buf.append(allocator, '}');
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
    if (row.source_avatar_url.len != 0) try appendJsonFieldString(buf, allocator, "source_avatar_url", row.source_avatar_url, true);
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
    try appendCommandField(buf, allocator, "edit", "gt issue edit #{s} --title TITLE --body BODY", issue_ref, true);
    try appendCommandField(buf, allocator, "create_sub_issue", "gt issue open --parent #{s} --title TITLE --body BODY", issue_ref, true);
    try appendCommandField(buf, allocator, "add_parent", "gt issue parent #{s} add PARENT_ISSUE", issue_ref, true);
    try appendCommandField(buf, allocator, "add_sub_issue", "gt issue sub-issue #{s} add CHILD_ISSUE", issue_ref, true);
    try appendCommandField(buf, allocator, "add_blocked_by", "gt issue blocked-by #{s} add BLOCKING_ISSUE", issue_ref, true);
    try appendCommandField(buf, allocator, "add_blocking", "gt issue blocking #{s} add BLOCKED_ISSUE", issue_ref, true);
    try appendCommandField(buf, allocator, "join_concurrent_group", "gt issue concurrent-group #{s} add GROUP", issue_ref, true);
    try appendCommandField(buf, allocator, "remove_parent", "gt issue parent #{s} remove PARENT_ISSUE", issue_ref, true);
    try appendCommandField(buf, allocator, "remove_sub_issue", "gt issue sub-issue #{s} remove CHILD_ISSUE", issue_ref, true);
    try appendCommandField(buf, allocator, "remove_blocked_by", "gt issue blocked-by #{s} remove BLOCKING_ISSUE", issue_ref, true);
    try appendCommandField(buf, allocator, "remove_blocking", "gt issue blocking #{s} remove BLOCKED_ISSUE", issue_ref, true);
    try appendCommandField(buf, allocator, "leave_concurrent_group", "gt issue concurrent-group #{s} remove GROUP", issue_ref, false);
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
    const head = try resolvePullHeadGitCommit(allocator, repo, detail, prefer_remote);
    const owned_head = head orelse {
        allocator.free(base);
        return null;
    };
    return .{ .base = base, .head = owned_head };
}

fn resolvePullHeadGitCommit(allocator: Allocator, repo: Repo, detail: PullDetail, prefer_remote: bool) !?[]u8 {
    if (detail.legacy_number > 0) {
        if (try resolveGithubPullHeadCommit(allocator, repo, detail.legacy_number)) |github_head| {
            if (try resolveLocalPullBranchCommit(allocator, repo, detail.head_ref)) |local_head| {
                if (try gitCommitIsAncestor(allocator, repo, github_head, local_head)) {
                    allocator.free(github_head);
                    return local_head;
                }
                allocator.free(local_head);
            }
            return github_head;
        }
    }
    return try resolvePullGitCommit(allocator, repo, detail.head_ref, prefer_remote);
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

fn resolveLocalPullBranchCommit(allocator: Allocator, repo: Repo, raw_ref: []const u8) !?[]u8 {
    const local_ref = (try localPullBranchRef(allocator, raw_ref)) orelse return null;
    defer allocator.free(local_ref);
    return try resolveGitCommit(allocator, repo, local_ref);
}

fn localPullBranchRef(allocator: Allocator, raw_ref: []const u8) !?[]u8 {
    const heads_prefix = "refs/heads/";
    if (std.mem.startsWith(u8, raw_ref, heads_prefix)) {
        const branch_name = raw_ref[heads_prefix.len..];
        if (!isSafeLocalBranchName(branch_name)) return null;
        return try allocator.dupe(u8, raw_ref);
    }
    if (!isBranchShorthand(raw_ref)) return null;
    return try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{raw_ref});
}

fn gitCommitIsAncestor(allocator: Allocator, repo: Repo, ancestor: []const u8, descendant: []const u8) !bool {
    var result = try gitRun(allocator, repo, &.{ "merge-base", "--is-ancestor", ancestor, descendant }, 1024 * 1024);
    defer result.deinit();
    if (result.exitCode()) |code| {
        if (code == 0) return true;
        if (code == 1) return false;
    }
    return error.GitFailed;
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

pub fn gitMaybe(allocator: Allocator, repo: Repo, git_args: []const []const u8, max_output_bytes: usize) !?[]u8 {
    var result = try gitRun(allocator, repo, git_args, max_output_bytes);
    if (result.exitCode() == 0) {
        const stdout = result.stdout;
        allocator.free(result.stderr);
        return stdout;
    }
    result.deinit();
    return null;
}

fn gitRun(allocator: Allocator, repo: Repo, git_args: []const []const u8, max_output_bytes: usize) !git.RunOutput {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    try argv.append(allocator, "-C");
    try argv.append(allocator, repo.root);
    for (git_args) |arg| try argv.append(allocator, arg);
    return git.runCommand(allocator, argv.items, null, max_output_bytes);
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

test "issue detail display prefers event-local source identity metadata" {
    const allocator = std.testing.allocator;
    var db = try SqliteDb.open(allocator, ":memory:", sqlite_db.sqlite.SQLITE_OPEN_READWRITE | sqlite_db.sqlite.SQLITE_OPEN_CREATE, true);
    defer db.deinit();
    try index_schema.createIndexSchema(&db);
    try db.exec(
        \\INSERT INTO issues(
        \\  id,
        \\  title, title_occurred_at, title_actor_principal, title_event_hash,
        \\  body, body_occurred_at, body_actor_principal, body_event_hash,
        \\  state, state_occurred_at, state_actor_principal, state_event_hash,
        \\  opened_at, author_principal, author_device
        \\) VALUES (
        \\  'issue-1',
        \\  'Imported issue', '2026-05-16T00:00:00Z', 'did:key:victim', 'open-event',
        \\  '', '2026-05-16T00:00:00Z', 'did:key:victim', 'open-event',
        \\  'open', '2026-05-16T00:00:00Z', 'did:key:victim', 'open-event',
        \\  '2026-05-16T00:00:00Z', 'did:key:victim', 'laptop'
        \\);
        \\INSERT INTO issue_metadata(
        \\  issue_id, source_author, source_identity, source_email, source_avatar_url, milestone,
        \\  issue_type, issue_type_occurred_at, issue_type_actor_principal, issue_type_event_hash,
        \\  priority, priority_occurred_at, priority_actor_principal, priority_event_hash,
        \\  status, status_occurred_at, status_actor_principal, status_event_hash
        \\) VALUES (
        \\  'issue-1', 'Victim', 'github:123', 'victim@example.test', 'https://avatars.githubusercontent.com/u/123?v=4', '',
        \\  '', '', '', '',
        \\  '', '', '', '',
        \\  '', '', '', ''
        \\);
        \\INSERT INTO identities(id, provider, provider_user_id, display_name, email, avatar_url)
        \\VALUES ('github:123', 'github', '123', 'Mallory', 'mallory@example.test', 'https://attacker.invalid/avatar.png');
    );

    const detail = (try loadIssueDetail(allocator, &db, "issue-1")).?;
    defer detail.deinit(allocator);
    try std.testing.expectEqualStrings("Victim", detail.display_author);
    try std.testing.expectEqualStrings("https://avatars.githubusercontent.com/u/123?v=4", detail.source_avatar_url);
}

test "pull git refs derive local branch refs only from safe branch names" {
    const shorthand = (try localPullBranchRef(std.testing.allocator, "feature/conflict-fix")).?;
    defer std.testing.allocator.free(shorthand);
    try std.testing.expectEqualStrings("refs/heads/feature/conflict-fix", shorthand);

    const full = (try localPullBranchRef(std.testing.allocator, "refs/heads/origin/feature")).?;
    defer std.testing.allocator.free(full);
    try std.testing.expectEqualStrings("refs/heads/origin/feature", full);

    try std.testing.expect((try localPullBranchRef(std.testing.allocator, "origin/feature")) == null);
    try std.testing.expect((try localPullBranchRef(std.testing.allocator, "refs/remotes/origin/feature")) == null);
    try std.testing.expect((try localPullBranchRef(std.testing.allocator, "HEAD")) == null);
    try std.testing.expect((try localPullBranchRef(std.testing.allocator, "feature^{commit}")) == null);
}

test "work item search query filters state and keeps text terms" {
    var issue_query = try parseIssueSearchQuery(std.testing.allocator, "is:issue state:open web new test");
    defer issue_query.deinit(std.testing.allocator);
    try std.testing.expectEqual(IssueStateFilter.open, issue_query.state.?);
    try std.testing.expectEqualStrings("web new test", issue_query.q.?);

    var quoted_issue_query = try parseIssueSearchQuery(std.testing.allocator, "is:closed label:\"good first issue\" assignee:alice sort:updated \"manual filter\"");
    defer quoted_issue_query.deinit(std.testing.allocator);
    try std.testing.expectEqual(IssueStateFilter.closed, quoted_issue_query.state.?);
    try std.testing.expectEqual(IssueSort.updated, quoted_issue_query.sort.?);
    try std.testing.expectEqualStrings("good first issue", quoted_issue_query.label.?);
    try std.testing.expectEqualStrings("alice", quoted_issue_query.assignee.?);
    try std.testing.expectEqualStrings("manual filter", quoted_issue_query.q.?);

    var pull_query = try parsePullSearchQuery(std.testing.allocator, "is:pr state:merged author:alice label:review reviewer:bob base:main head:\"feature branch\" sort:updated branch search");
    defer pull_query.deinit(std.testing.allocator);
    try std.testing.expectEqual(PullStateFilter.merged, pull_query.state.?);
    try std.testing.expectEqualStrings("alice", pull_query.author.?);
    try std.testing.expectEqualStrings("review", pull_query.label.?);
    try std.testing.expectEqualStrings("bob", pull_query.reviewer.?);
    try std.testing.expectEqualStrings("main", pull_query.base.?);
    try std.testing.expectEqualStrings("feature branch", pull_query.head.?);
    try std.testing.expectEqual(PullSort.updated, pull_query.sort.?);
    try std.testing.expectEqualStrings("branch search", pull_query.q.?);
}

test "work item search query formatter emits canonical filters" {
    var issue_filters = IssueListOptions{
        .allocator = std.testing.allocator,
        .state = .closed,
        .q = try std.testing.allocator.dupe(u8, "manual filter"),
        .label = try std.testing.allocator.dupe(u8, "good first issue"),
        .assignee = try std.testing.allocator.dupe(u8, "alice"),
        .sort = .updated,
    };
    defer issue_filters.deinit();
    const issue_query = try issueFilterQueryOwned(std.testing.allocator, issue_filters);
    defer std.testing.allocator.free(issue_query);
    try std.testing.expectEqualStrings("is:issue state:closed label:\"good first issue\" assignee:alice sort:updated \"manual filter\"", issue_query);

    const pull_query = try pullFilterQueryOwned(std.testing.allocator, .{
        .state = .all,
        .q = "branch search",
        .reviewer = "bob",
        .head = "feature branch",
        .sort = .updated,
    });
    defer std.testing.allocator.free(pull_query);
    try std.testing.expectEqualStrings("is:pr state:all reviewer:bob head:\"feature branch\" sort:updated \"branch search\"", pull_query);
}

test "work item filter JSON emits valid defaults" {
    var issue_buf: std.ArrayList(u8) = .empty;
    defer issue_buf.deinit(std.testing.allocator);
    try issue_buf.append(std.testing.allocator, '{');
    try appendIssueFiltersJsonField(&issue_buf, std.testing.allocator, .{
        .allocator = std.testing.allocator,
        .state = .open,
    }, false);
    try issue_buf.append(std.testing.allocator, '}');

    var issue_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, issue_buf.items, .{});
    defer issue_parsed.deinit();
    const issue_filters = issue_parsed.value.object.get("filters").?.object;
    try std.testing.expectEqualStrings("newest", issue_filters.get("sort").?.string);

    var pull_buf: std.ArrayList(u8) = .empty;
    defer pull_buf.deinit(std.testing.allocator);
    try pull_buf.append(std.testing.allocator, '{');
    try appendPullFiltersJsonField(&pull_buf, std.testing.allocator, .{
        .state = .open,
    }, false);
    try pull_buf.append(std.testing.allocator, '}');

    var pull_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, pull_buf.items, .{});
    defer pull_parsed.deinit();
    const pull_filters = pull_parsed.value.object.get("filters").?.object;
    try std.testing.expectEqualStrings("newest", pull_filters.get("sort").?.string);
}

test "pull list SQL includes search filter" {
    const sql = try pullListSql(std.testing.allocator, .{
        .state = .open,
        .q = "feature",
        .label = "review",
        .reviewer = "alice",
        .sort = .updated,
    });
    defer std.testing.allocator.free(sql);
    try std.testing.expect(std.mem.indexOf(u8, sql, "p.state = ?") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "p.title LIKE ?") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "p.base_ref LIKE ?") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "comments c") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "pull_labels") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "pull_reviewers") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "ORDER BY p.state_occurred_at DESC") != null);
}

test "work item list SQL supports limit and offset pagination" {
    const issue_sql = try issueListSql(std.testing.allocator, .{
        .allocator = std.testing.allocator,
        .state = .open,
        .limit = 26,
        .offset = 50,
    });
    defer std.testing.allocator.free(issue_sql);
    try std.testing.expect(std.mem.indexOf(u8, issue_sql, "LIMIT ?") != null);
    try std.testing.expect(std.mem.indexOf(u8, issue_sql, "OFFSET ?") != null);

    const pull_sql = try pullListSql(std.testing.allocator, .{
        .state = .closed,
        .limit = 26,
        .offset = 50,
    });
    defer std.testing.allocator.free(pull_sql);
    try std.testing.expect(std.mem.indexOf(u8, pull_sql, "LIMIT ?") != null);
    try std.testing.expect(std.mem.indexOf(u8, pull_sql, "OFFSET ?") != null);
}
