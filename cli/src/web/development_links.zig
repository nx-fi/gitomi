const std = @import("std");
const index = @import("../index.zig");
const shared = @import("shared.zig");
const util = @import("../util.zig");

const Allocator = std.mem.Allocator;
const SqliteDb = index.SqliteDb;
const appendTemplate = shared.appendTemplate;
const issueHref = shared.issueHref;
const pullHref = shared.pullHref;

const max_development_links: usize = 25;
const max_outgoing_comments: usize = 100;
const max_incoming_candidates: usize = 200;
const max_incoming_comments_per_candidate: usize = 20;
const max_directive_tokens_per_text: usize = 64;
const max_directive_tokens_per_collection: usize = 512;
const max_hash_ref_index_entries_per_kind: usize = 8192;

pub const DevelopmentLink = struct {
    allocator: Allocator,
    object_kind: []const u8,
    object_id: []u8,
    title: []u8,
    state: []u8,
    legacy_number: i64,

    pub fn deinit(self: *DevelopmentLink) void {
        self.allocator.free(self.object_id);
        self.allocator.free(self.title);
        self.allocator.free(self.state);
    }
};

const CollectionBudget = struct {
    remaining_tokens: usize = max_directive_tokens_per_collection,

    fn takeToken(self: *CollectionBudget) bool {
        if (self.remaining_tokens == 0) return false;
        self.remaining_tokens -= 1;
        return true;
    }

    fn exhausted(self: *const CollectionBudget) bool {
        return self.remaining_tokens == 0;
    }
};

fn collectionDone(links: *const std.ArrayList(DevelopmentLink), budget: *const CollectionBudget) bool {
    return links.items.len >= max_development_links or budget.exhausted();
}

pub fn collectForIssue(
    allocator: Allocator,
    db: *SqliteDb,
    issue_id: []const u8,
    issue_body: []const u8,
    links: *std.ArrayList(DevelopmentLink),
) !void {
    var seen = std.StringHashMap(void).init(allocator);
    defer freeSeenKeys(allocator, &seen);
    var resolver = TargetResolver.init(allocator, db);
    defer resolver.deinit();
    var budget = CollectionBudget{};

    try collectOutgoingTextLinks(allocator, &resolver, issue_body, "pull", &seen, links, &budget);
    if (collectionDone(links, &budget)) return;
    try collectOutgoingCommentLinks(allocator, &resolver, "issue", issue_id, "pull", &seen, links, &budget);
    if (collectionDone(links, &budget)) return;
    try collectIncomingPullLinks(allocator, &resolver, issue_id, &seen, links, &budget);
}

pub fn collectForPull(
    allocator: Allocator,
    db: *SqliteDb,
    pull_id: []const u8,
    pull_body: []const u8,
    links: *std.ArrayList(DevelopmentLink),
) !void {
    var seen = std.StringHashMap(void).init(allocator);
    defer freeSeenKeys(allocator, &seen);
    var resolver = TargetResolver.init(allocator, db);
    defer resolver.deinit();
    var budget = CollectionBudget{};

    try collectOutgoingTextLinks(allocator, &resolver, pull_body, "issue", &seen, links, &budget);
    if (collectionDone(links, &budget)) return;
    try collectOutgoingCommentLinks(allocator, &resolver, "pull", pull_id, "issue", &seen, links, &budget);
    if (collectionDone(links, &budget)) return;
    try collectIncomingIssueLinks(allocator, &resolver, pull_id, &seen, links, &budget);
}

pub fn freeLinks(allocator: Allocator, links: *std.ArrayList(DevelopmentLink)) void {
    for (links.items) |*link| link.deinit();
    links.deinit(allocator);
}

pub fn appendLinkRow(buf: *std.ArrayList(u8), allocator: Allocator, link: DevelopmentLink) !void {
    const is_pull = std.mem.eql(u8, link.object_kind, "pull");
    var ref_buf: [util.short_object_ref_len]u8 = undefined;
    const short_ref = util.shortObjectRef(&ref_buf, link.object_id);
    try buf.appendSlice(allocator, "<a class=\"issue-sidebar-link-row\" href=\"");
    try appendLinkHref(buf, allocator, link, short_ref);
    try appendTemplate(buf, allocator,
        \\\"><span class="issue-sidebar-row-kind">{kind}</span><span class="issue-sidebar-row-ref">
    , .{ .kind = if (is_pull) "pull" else "issue" });
    try appendDisplayRef(buf, allocator, link, short_ref);
    try appendTemplate(buf, allocator,
        \\</span><span class="issue-sidebar-row-title">{title}</span></a>
    , .{ .title = link.title });
}

fn collectOutgoingCommentLinks(
    allocator: Allocator,
    resolver: *TargetResolver,
    parent_kind: []const u8,
    parent_id: []const u8,
    wanted_kind: []const u8,
    seen: *std.StringHashMap(void),
    links: *std.ArrayList(DevelopmentLink),
    budget: *CollectionBudget,
) !void {
    var stmt = try resolver.db.prepare(
        \\SELECT body
        \\FROM comments
        \\WHERE parent_kind = ?
        \\  AND parent_id = ?
        \\  AND redacted = 0
        \\ORDER BY created_at, id
        \\LIMIT ?
    );
    defer stmt.deinit();
    try stmt.bindText(1, parent_kind);
    try stmt.bindText(2, parent_id);
    try stmt.bindInt(3, @intCast(max_outgoing_comments));
    while (try stmt.step()) {
        if (collectionDone(links, budget)) return;
        const body = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(body);
        try collectOutgoingTextLinks(allocator, resolver, body, wanted_kind, seen, links, budget);
    }
}

fn collectOutgoingTextLinks(
    allocator: Allocator,
    resolver: *TargetResolver,
    text: []const u8,
    wanted_kind: []const u8,
    seen: *std.StringHashMap(void),
    links: *std.ArrayList(DevelopmentLink),
    budget: *CollectionBudget,
) !void {
    var text_tokens: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        if (collectionDone(links, budget) or text_tokens >= max_directive_tokens_per_text) return;
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        const separator = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!isDevelopmentDirectiveKey(std.mem.trim(u8, line[0..separator], " \t\r\n"))) continue;
        var tokens = std.mem.tokenizeAny(u8, line[separator + 1 ..], " \t\r\n,");
        while (tokens.next()) |raw_token| {
            if (collectionDone(links, budget) or text_tokens >= max_directive_tokens_per_text) return;
            const token = trimReferenceToken(raw_token);
            if (token.len == 0) continue;
            if (!budget.takeToken()) return;
            text_tokens += 1;
            var target = (try resolver.resolveTarget(token)) orelse continue;
            if (!std.mem.eql(u8, target.object_kind, wanted_kind)) {
                target.deinit();
                continue;
            }
            try appendUniqueLink(allocator, seen, links, target);
        }
    }
}

fn collectIncomingPullLinks(
    allocator: Allocator,
    resolver: *TargetResolver,
    issue_id: []const u8,
    seen: *std.StringHashMap(void),
    links: *std.ArrayList(DevelopmentLink),
    budget: *CollectionBudget,
) !void {
    var stmt = try resolver.db.prepare(
        \\SELECT p.id, p.title, p.state, COALESCE(a.number, 0), p.body
        \\FROM pulls p
        \\LEFT JOIN legacy_aliases a
        \\  ON a.provider = 'github' AND a.object_kind = 'pull' AND a.object_id = p.id
        \\ORDER BY p.opened_at DESC, p.id DESC
        \\LIMIT ?
    );
    defer stmt.deinit();
    try stmt.bindInt(1, @intCast(max_incoming_candidates));
    while (try stmt.step()) {
        if (collectionDone(links, budget)) return;
        const source_id = try stmt.columnTextDup(allocator, 0);
        errdefer allocator.free(source_id);
        const title = try stmt.columnTextDup(allocator, 1);
        errdefer allocator.free(title);
        const state = try stmt.columnTextDup(allocator, 2);
        errdefer allocator.free(state);
        const legacy_number = stmt.columnInt64(3);
        const body = try stmt.columnTextDup(allocator, 4);
        defer allocator.free(body);
        const referenced = try textOrCommentsReferenceObject(allocator, resolver, "pull", source_id, body, "issue", issue_id, max_incoming_comments_per_candidate, budget);
        if (!referenced) {
            allocator.free(source_id);
            allocator.free(title);
            allocator.free(state);
            continue;
        }
        try appendUniqueLink(allocator, seen, links, .{
            .allocator = allocator,
            .object_kind = "pull",
            .object_id = source_id,
            .title = title,
            .state = state,
            .legacy_number = legacy_number,
        });
    }
}

fn collectIncomingIssueLinks(
    allocator: Allocator,
    resolver: *TargetResolver,
    pull_id: []const u8,
    seen: *std.StringHashMap(void),
    links: *std.ArrayList(DevelopmentLink),
    budget: *CollectionBudget,
) !void {
    var stmt = try resolver.db.prepare(
        \\SELECT i.id, i.title, i.state, COALESCE(a.number, 0), i.body
        \\FROM issues i
        \\LEFT JOIN legacy_aliases a
        \\  ON a.provider = 'github' AND a.object_kind = 'issue' AND a.object_id = i.id
        \\ORDER BY i.opened_at DESC, i.id DESC
        \\LIMIT ?
    );
    defer stmt.deinit();
    try stmt.bindInt(1, @intCast(max_incoming_candidates));
    while (try stmt.step()) {
        if (collectionDone(links, budget)) return;
        const source_id = try stmt.columnTextDup(allocator, 0);
        errdefer allocator.free(source_id);
        const title = try stmt.columnTextDup(allocator, 1);
        errdefer allocator.free(title);
        const state = try stmt.columnTextDup(allocator, 2);
        errdefer allocator.free(state);
        const legacy_number = stmt.columnInt64(3);
        const body = try stmt.columnTextDup(allocator, 4);
        defer allocator.free(body);
        const referenced = try textOrCommentsReferenceObject(allocator, resolver, "issue", source_id, body, "pull", pull_id, max_incoming_comments_per_candidate, budget);
        if (!referenced) {
            allocator.free(source_id);
            allocator.free(title);
            allocator.free(state);
            continue;
        }
        try appendUniqueLink(allocator, seen, links, .{
            .allocator = allocator,
            .object_kind = "issue",
            .object_id = source_id,
            .title = title,
            .state = state,
            .legacy_number = legacy_number,
        });
    }
}

fn textOrCommentsReferenceObject(
    allocator: Allocator,
    resolver: *TargetResolver,
    source_kind: []const u8,
    source_id: []const u8,
    body: []const u8,
    target_kind: []const u8,
    target_id: []const u8,
    comment_limit: usize,
    budget: *CollectionBudget,
) !bool {
    if (try textReferencesObject(resolver, body, target_kind, target_id, budget)) return true;
    if (budget.exhausted()) return false;
    var comments = try resolver.db.prepare(
        \\SELECT body
        \\FROM comments
        \\WHERE parent_kind = ?
        \\  AND parent_id = ?
        \\  AND redacted = 0
        \\ORDER BY created_at, id
        \\LIMIT ?
    );
    defer comments.deinit();
    try comments.bindText(1, source_kind);
    try comments.bindText(2, source_id);
    try comments.bindInt(3, @intCast(comment_limit));
    while (try comments.step()) {
        if (budget.exhausted()) return false;
        const comment_body = try comments.columnTextDup(allocator, 0);
        defer allocator.free(comment_body);
        if (try textReferencesObject(resolver, comment_body, target_kind, target_id, budget)) return true;
    }
    return false;
}

fn textReferencesObject(
    resolver: *TargetResolver,
    text: []const u8,
    target_kind: []const u8,
    target_id: []const u8,
    budget: *CollectionBudget,
) !bool {
    var text_tokens: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        if (budget.exhausted() or text_tokens >= max_directive_tokens_per_text) return false;
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        const separator = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!isDevelopmentDirectiveKey(std.mem.trim(u8, line[0..separator], " \t\r\n"))) continue;
        var tokens = std.mem.tokenizeAny(u8, line[separator + 1 ..], " \t\r\n,");
        while (tokens.next()) |raw_token| {
            if (budget.exhausted() or text_tokens >= max_directive_tokens_per_text) return false;
            const token = trimReferenceToken(raw_token);
            if (token.len == 0) continue;
            if (!budget.takeToken()) return false;
            text_tokens += 1;
            var target = (try resolver.resolveTarget(token)) orelse continue;
            defer target.deinit();
            if (std.mem.eql(u8, target.object_kind, target_kind) and std.mem.eql(u8, target.object_id, target_id)) return true;
        }
    }
    return false;
}

fn appendUniqueLink(
    allocator: Allocator,
    seen: *std.StringHashMap(void),
    links: *std.ArrayList(DevelopmentLink),
    link: DevelopmentLink,
) !void {
    if (links.items.len >= max_development_links) {
        var cleanup = link;
        cleanup.deinit();
        return;
    }
    errdefer {
        var cleanup = link;
        cleanup.deinit();
    }
    const key = try std.fmt.allocPrint(allocator, "{s}\x1f{s}", .{ link.object_kind, link.object_id });
    errdefer allocator.free(key);
    const entry = try seen.getOrPut(key);
    if (entry.found_existing) {
        allocator.free(key);
        var duplicate = link;
        duplicate.deinit();
        return;
    }
    entry.value_ptr.* = {};
    errdefer _ = seen.remove(key);
    try links.append(allocator, link);
}

const ObjectRefEntry = struct {
    object_ref: [util.max_object_ref_len]u8,
    object_id: []u8,
};

const ObjectRefResolution = union(enum) {
    none,
    ambiguous,
    found: []const u8,
};

const ObjectRefIndex = struct {
    entries: std.ArrayList(ObjectRefEntry) = .empty,

    fn loadBounded(self: *ObjectRefIndex, allocator: Allocator, db: *SqliteDb, sql_text: []const u8) !bool {
        var stmt = try db.prepare(sql_text);
        defer stmt.deinit();
        try stmt.bindInt(1, @intCast(max_hash_ref_index_entries_per_kind + 1));

        var count: usize = 0;
        while (try stmt.step()) {
            count += 1;
            if (count > max_hash_ref_index_entries_per_kind) return false;

            const id = try stmt.columnTextDup(allocator, 0);
            errdefer allocator.free(id);

            var object_ref: [util.max_object_ref_len]u8 = undefined;
            _ = util.objectRefPrefix(object_ref[0..], id);
            try self.entries.append(allocator, .{
                .object_ref = object_ref,
                .object_id = id,
            });
        }

        std.mem.sort(ObjectRefEntry, self.entries.items, {}, objectRefEntryLessThan);
        return true;
    }

    fn resolvePrefix(self: *const ObjectRefIndex, raw_prefix: []const u8) ObjectRefResolution {
        var prefix_buf: [util.max_object_ref_len]u8 = undefined;
        for (raw_prefix, 0..) |c, idx| prefix_buf[idx] = std.ascii.toLower(c);
        const prefix = prefix_buf[0..raw_prefix.len];

        const first = self.lowerBound(prefix);
        if (first >= self.entries.items.len) return .none;
        if (!std.mem.startsWith(u8, self.entries.items[first].object_ref[0..], prefix)) return .none;
        if (first + 1 < self.entries.items.len and std.mem.startsWith(u8, self.entries.items[first + 1].object_ref[0..], prefix)) return .ambiguous;
        return .{ .found = self.entries.items[first].object_id };
    }

    fn lowerBound(self: *const ObjectRefIndex, prefix: []const u8) usize {
        var low: usize = 0;
        var high: usize = self.entries.items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (objectRefLessThanPrefix(self.entries.items[mid].object_ref[0..], prefix)) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        return low;
    }

    fn deinit(self: *ObjectRefIndex, allocator: Allocator) void {
        for (self.entries.items) |entry| allocator.free(entry.object_id);
        self.entries.deinit(allocator);
        self.* = .{};
    }
};

const HashRefIndexState = struct {
    loaded: bool = false,
    over_limit: bool = false,
    refs: ObjectRefIndex = .{},

    fn load(self: *HashRefIndexState, allocator: Allocator, db: *SqliteDb, sql_text: []const u8) !void {
        if (self.loaded) return;
        self.loaded = true;
        errdefer {
            self.refs.deinit(allocator);
            self.* = .{};
        }

        if (!(try self.refs.loadBounded(allocator, db, sql_text))) {
            self.refs.deinit(allocator);
            self.over_limit = true;
        }
    }

    fn deinit(self: *HashRefIndexState, allocator: Allocator) void {
        self.refs.deinit(allocator);
        self.* = .{};
    }
};

const TargetResolver = struct {
    allocator: Allocator,
    db: *SqliteDb,
    issue_refs: HashRefIndexState = .{},
    pull_refs: HashRefIndexState = .{},

    fn init(allocator: Allocator, db: *SqliteDb) TargetResolver {
        return .{
            .allocator = allocator,
            .db = db,
        };
    }

    fn deinit(self: *TargetResolver) void {
        self.issue_refs.deinit(self.allocator);
        self.pull_refs.deinit(self.allocator);
    }

    fn resolveTarget(self: *TargetResolver, token: []const u8) !?DevelopmentLink {
        if (std.mem.startsWith(u8, token, "#")) {
            return try self.resolveUntypedTarget(token[1..]);
        }
        if (asciiStartsWithIgnoreCase(token, "issue:")) {
            return try self.resolveSpecificTarget("issue", stripOptionalHash(token["issue:".len..]));
        }
        if (asciiStartsWithIgnoreCase(token, "pr:")) {
            return try self.resolveSpecificTarget("pull", stripOptionalHash(token["pr:".len..]));
        }
        if (asciiStartsWithIgnoreCase(token, "pull:")) {
            return try self.resolveSpecificTarget("pull", stripOptionalHash(token["pull:".len..]));
        }
        return null;
    }

    fn resolveUntypedTarget(self: *TargetResolver, value: []const u8) !?DevelopmentLink {
        var issue_target = try self.resolveSpecificTarget("issue", value);
        errdefer if (issue_target) |*target| target.deinit();
        var pull_target = try self.resolveSpecificTarget("pull", value);
        errdefer if (pull_target) |*target| target.deinit();
        if (issue_target != null and pull_target != null) {
            issue_target.?.deinit();
            pull_target.?.deinit();
            return null;
        }
        if (issue_target) |target| return target;
        return pull_target;
    }

    fn resolveSpecificTarget(self: *TargetResolver, object_kind: []const u8, raw_value: []const u8) !?DevelopmentLink {
        const value = std.mem.trim(u8, raw_value, " \t\r\n");
        if (value.len == 0) return null;
        if (util.looksLikeUuid(value)) return try self.lookupObjectById(object_kind, value);
        if (util.isObjectRefPrefix(value)) return try self.lookupObjectByHashRef(object_kind, value);
        if (parsePositiveDecimal(value)) |number| return try self.lookupLegacyObject(object_kind, number);
        return null;
    }

    fn lookupObjectById(self: *TargetResolver, object_kind: []const u8, object_id: []const u8) !?DevelopmentLink {
        const sql_text: []const u8 = if (std.mem.eql(u8, object_kind, "pull"))
            \\SELECT p.id, p.title, p.state, COALESCE(a.number, 0)
            \\FROM pulls p
            \\LEFT JOIN legacy_aliases a
            \\  ON a.provider = 'github' AND a.object_kind = 'pull' AND a.object_id = p.id
            \\WHERE p.id = ?
        else
            \\SELECT i.id, i.title, i.state, COALESCE(a.number, 0)
            \\FROM issues i
            \\LEFT JOIN legacy_aliases a
            \\  ON a.provider = 'github' AND a.object_kind = 'issue' AND a.object_id = i.id
            \\WHERE i.id = ?
        ;
        var stmt = try self.db.prepare(sql_text);
        defer stmt.deinit();
        try stmt.bindText(1, object_id);
        if (!(try stmt.step())) return null;
        return .{
            .allocator = self.allocator,
            .object_kind = object_kind,
            .object_id = try stmt.columnTextDup(self.allocator, 0),
            .title = try stmt.columnTextDup(self.allocator, 1),
            .state = try stmt.columnTextDup(self.allocator, 2),
            .legacy_number = stmt.columnInt64(3),
        };
    }

    fn lookupObjectByHashRef(self: *TargetResolver, object_kind: []const u8, value: []const u8) !?DevelopmentLink {
        const refs = try self.hashRefsForKind(object_kind);
        if (refs.over_limit) return null;
        return switch (refs.refs.resolvePrefix(value)) {
            .none, .ambiguous => null,
            .found => |id| try self.lookupObjectById(object_kind, id),
        };
    }

    fn lookupLegacyObject(self: *TargetResolver, object_kind: []const u8, number: i64) !?DevelopmentLink {
        var stmt = try self.db.prepare(
            \\SELECT object_id
            \\FROM legacy_aliases
            \\WHERE provider = 'github'
            \\  AND object_kind = ?
            \\  AND number = ?
        );
        defer stmt.deinit();
        try stmt.bindText(1, object_kind);
        try stmt.bindInt64(2, number);
        if (!(try stmt.step())) return null;
        const object_id = try stmt.columnTextDup(self.allocator, 0);
        defer self.allocator.free(object_id);
        return try self.lookupObjectById(object_kind, object_id);
    }

    fn hashRefsForKind(self: *TargetResolver, object_kind: []const u8) !*HashRefIndexState {
        if (std.mem.eql(u8, object_kind, "pull")) {
            try self.pull_refs.load(self.allocator, self.db,
                \\SELECT id
                \\FROM pulls
                \\ORDER BY id
                \\LIMIT ?
            );
            return &self.pull_refs;
        }

        try self.issue_refs.load(self.allocator, self.db,
            \\SELECT id
            \\FROM issues
            \\ORDER BY id
            \\LIMIT ?
        );
        return &self.issue_refs;
    }
};

fn objectRefEntryLessThan(_: void, a: ObjectRefEntry, b: ObjectRefEntry) bool {
    return std.mem.lessThan(u8, a.object_ref[0..], b.object_ref[0..]);
}

fn objectRefLessThanPrefix(object_ref: []const u8, prefix: []const u8) bool {
    std.debug.assert(object_ref.len >= prefix.len);
    for (prefix, 0..) |c, idx| {
        if (object_ref[idx] < c) return true;
        if (object_ref[idx] > c) return false;
    }
    return false;
}

fn appendLinkHref(buf: *std.ArrayList(u8), allocator: Allocator, link: DevelopmentLink, short_ref: []const u8) !void {
    if (link.legacy_number > 0) {
        const number_ref = try std.fmt.allocPrint(allocator, "{d}", .{link.legacy_number});
        defer allocator.free(number_ref);
        try shared.appendHref(buf, allocator, if (std.mem.eql(u8, link.object_kind, "pull")) pullHref(number_ref) else issueHref(number_ref));
        return;
    }
    try shared.appendHref(buf, allocator, if (std.mem.eql(u8, link.object_kind, "pull")) pullHref(short_ref) else issueHref(short_ref));
}

fn appendDisplayRef(buf: *std.ArrayList(u8), allocator: Allocator, link: DevelopmentLink, short_ref: []const u8) !void {
    try buf.append(allocator, '#');
    if (link.legacy_number > 0) {
        try @import("compat").appendPrint(allocator, buf, "{d}", .{link.legacy_number});
    } else {
        try shared.appendHtml(buf, allocator, short_ref);
    }
}

fn isDevelopmentDirectiveKey(key: []const u8) bool {
    return asciiEqlIgnoreCase(key, "Refs") or
        asciiEqlIgnoreCase(key, "Relates-To") or
        asciiEqlIgnoreCase(key, "Related-To") or
        asciiEqlIgnoreCase(key, "Blocks") or
        asciiEqlIgnoreCase(key, "Blocked-By") or
        asciiEqlIgnoreCase(key, "Duplicates") or
        asciiEqlIgnoreCase(key, "Duplicate-Of");
}

fn trimReferenceToken(raw: []const u8) []const u8 {
    return std.mem.trim(u8, raw, " \t\r\n.,;()[]{}<>\"'`");
}

fn stripOptionalHash(value: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "#")) return trimmed[1..];
    return trimmed;
}

fn parsePositiveDecimal(value: []const u8) ?i64 {
    if (value.len == 0) return null;
    for (value) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    const number = std.fmt.parseInt(i64, value, 10) catch return null;
    return if (number > 0) number else null;
}

fn asciiStartsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and asciiEqlIgnoreCase(value[0..prefix.len], prefix);
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (std.ascii.toLower(left) != std.ascii.toLower(right)) return false;
    }
    return true;
}

fn freeSeenKeys(allocator: Allocator, seen: *std.StringHashMap(void)) void {
    var keys = seen.keyIterator();
    while (keys.next()) |key| allocator.free(key.*);
    seen.deinit();
}

test "development directive keys match issue reference directives" {
    try std.testing.expect(isDevelopmentDirectiveKey("refs"));
    try std.testing.expect(isDevelopmentDirectiveKey("Blocked-By"));
    try std.testing.expect(!isDevelopmentDirectiveKey("mentions"));
    try std.testing.expectEqualStrings("#abc123", trimReferenceToken("(#abc123,"));
}

test "development links resolve outgoing typed legacy refs" {
    const allocator = std.testing.allocator;
    var db = try openDevelopmentLinksTestDb(allocator);
    defer db.deinit();

    try insertIssue(&db, "issue-1", "Issue one", "open", "", "2026-01-01T00:00:00Z");
    try insertPull(&db, "pull-1", "Pull one", "open", "", "2026-01-02T00:00:00Z");
    try insertLegacy(&db, "issue", "issue-1", 10);
    try insertLegacy(&db, "pull", "pull-1", 20);

    var issue_links: std.ArrayList(DevelopmentLink) = .empty;
    defer freeLinks(allocator, &issue_links);
    try collectForIssue(allocator, &db, "issue-1", "Refs: pr:20", &issue_links);
    try std.testing.expectEqual(@as(usize, 1), issue_links.items.len);
    try std.testing.expectEqualStrings("pull", issue_links.items[0].object_kind);
    try std.testing.expectEqualStrings("pull-1", issue_links.items[0].object_id);

    var pull_links: std.ArrayList(DevelopmentLink) = .empty;
    defer freeLinks(allocator, &pull_links);
    try collectForPull(allocator, &db, "pull-1", "Refs: issue:10", &pull_links);
    try std.testing.expectEqual(@as(usize, 1), pull_links.items.len);
    try std.testing.expectEqualStrings("issue", pull_links.items[0].object_kind);
    try std.testing.expectEqualStrings("issue-1", pull_links.items[0].object_id);
}

test "development link text scan caps directive tokens" {
    const allocator = std.testing.allocator;
    var db = try openDevelopmentLinksTestDb(allocator);
    defer db.deinit();

    try insertIssue(&db, "issue-1", "Issue one", "open", "", "2026-01-01T00:00:00Z");
    try insertPull(&db, "pull-1", "Pull one", "open", "", "2026-01-02T00:00:00Z");
    try insertLegacy(&db, "pull", "pull-1", 20);

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    try body.appendSlice(allocator, "Refs:");
    for (0..max_directive_tokens_per_text) |idx| {
        try @import("compat").appendPrint(allocator, &body, " issue:{d}", .{1000 + idx});
    }
    try body.appendSlice(allocator, " pr:20");

    var links: std.ArrayList(DevelopmentLink) = .empty;
    defer freeLinks(allocator, &links);
    try collectForIssue(allocator, &db, "issue-1", body.items, &links);
    try std.testing.expectEqual(@as(usize, 0), links.items.len);
}

test "development link incoming scan is capped to newest candidates" {
    const allocator = std.testing.allocator;
    var db = try openDevelopmentLinksTestDb(allocator);
    defer db.deinit();

    try insertIssue(&db, "issue-target", "Target issue", "open", "", "2026-01-01T00:00:00Z");
    try insertLegacy(&db, "issue", "issue-target", 10);

    for (0..max_incoming_candidates) |idx| {
        const pull_id = try std.fmt.allocPrint(allocator, "pull-new-{d:0>3}", .{idx});
        defer allocator.free(pull_id);
        try insertPull(&db, pull_id, "New pull", "open", "", "2026-02-01T00:00:00Z");
    }
    try insertPull(&db, "pull-old-linked", "Old linked pull", "open", "Refs: issue:10", "2026-01-01T00:00:00Z");

    var links: std.ArrayList(DevelopmentLink) = .empty;
    defer freeLinks(allocator, &links);
    try collectForIssue(allocator, &db, "issue-target", "", &links);
    try std.testing.expectEqual(@as(usize, 0), links.items.len);
}

fn openDevelopmentLinksTestDb(allocator: Allocator) !SqliteDb {
    var db = try SqliteDb.openWithOptions(allocator, ":memory:", index.sqlite.SQLITE_OPEN_READWRITE | index.sqlite.SQLITE_OPEN_CREATE, true, .{ .enable_wal = false });
    errdefer db.deinit();
    try db.exec(
        \\CREATE TABLE issues (
        \\  id TEXT PRIMARY KEY,
        \\  title TEXT NOT NULL,
        \\  state TEXT NOT NULL,
        \\  body TEXT NOT NULL,
        \\  opened_at TEXT NOT NULL
        \\);
        \\CREATE TABLE pulls (
        \\  id TEXT PRIMARY KEY,
        \\  title TEXT NOT NULL,
        \\  state TEXT NOT NULL,
        \\  body TEXT NOT NULL,
        \\  opened_at TEXT NOT NULL
        \\);
        \\CREATE TABLE comments (
        \\  id TEXT PRIMARY KEY,
        \\  parent_kind TEXT NOT NULL,
        \\  parent_id TEXT NOT NULL,
        \\  body TEXT NOT NULL,
        \\  redacted INTEGER NOT NULL,
        \\  created_at TEXT NOT NULL
        \\);
        \\CREATE TABLE legacy_aliases (
        \\  provider TEXT NOT NULL,
        \\  object_kind TEXT NOT NULL,
        \\  object_id TEXT NOT NULL,
        \\  number INTEGER NOT NULL,
        \\  PRIMARY KEY(provider, object_kind, number),
        \\  UNIQUE(provider, object_kind, object_id)
        \\);
    );
    return db;
}

fn insertIssue(db: *SqliteDb, id: []const u8, title: []const u8, state: []const u8, body: []const u8, opened_at: []const u8) !void {
    var stmt = try db.prepare("INSERT INTO issues(id, title, state, body, opened_at) VALUES (?, ?, ?, ?, ?)");
    defer stmt.deinit();
    try stmt.bindText(1, id);
    try stmt.bindText(2, title);
    try stmt.bindText(3, state);
    try stmt.bindText(4, body);
    try stmt.bindText(5, opened_at);
    try stmt.stepDone();
}

fn insertPull(db: *SqliteDb, id: []const u8, title: []const u8, state: []const u8, body: []const u8, opened_at: []const u8) !void {
    var stmt = try db.prepare("INSERT INTO pulls(id, title, state, body, opened_at) VALUES (?, ?, ?, ?, ?)");
    defer stmt.deinit();
    try stmt.bindText(1, id);
    try stmt.bindText(2, title);
    try stmt.bindText(3, state);
    try stmt.bindText(4, body);
    try stmt.bindText(5, opened_at);
    try stmt.stepDone();
}

fn insertLegacy(db: *SqliteDb, object_kind: []const u8, object_id: []const u8, number: i64) !void {
    var stmt = try db.prepare("INSERT INTO legacy_aliases(provider, object_kind, object_id, number) VALUES ('github', ?, ?, ?)");
    defer stmt.deinit();
    try stmt.bindText(1, object_kind);
    try stmt.bindText(2, object_id);
    try stmt.bindInt64(3, number);
    try stmt.stepDone();
}
