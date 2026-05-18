const std = @import("std");
const index = @import("../index.zig");
const shared = @import("shared.zig");
const util = @import("../util.zig");

const Allocator = std.mem.Allocator;
const SqliteDb = index.SqliteDb;
const appendTemplate = shared.appendTemplate;
const issueHref = shared.issueHref;
const pullHref = shared.pullHref;

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

pub fn collectForIssue(
    allocator: Allocator,
    db: *SqliteDb,
    issue_id: []const u8,
    issue_body: []const u8,
    links: *std.ArrayList(DevelopmentLink),
) !void {
    var seen = std.StringHashMap(void).init(allocator);
    defer freeSeenKeys(allocator, &seen);

    try collectOutgoingTextLinks(allocator, db, issue_body, "pull", &seen, links);
    try collectOutgoingCommentLinks(allocator, db, "issue", issue_id, "pull", &seen, links);
    try collectIncomingPullLinks(allocator, db, issue_id, &seen, links);
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

    try collectOutgoingTextLinks(allocator, db, pull_body, "issue", &seen, links);
    try collectOutgoingCommentLinks(allocator, db, "pull", pull_id, "issue", &seen, links);
    try collectIncomingIssueLinks(allocator, db, pull_id, &seen, links);
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
    db: *SqliteDb,
    parent_kind: []const u8,
    parent_id: []const u8,
    wanted_kind: []const u8,
    seen: *std.StringHashMap(void),
    links: *std.ArrayList(DevelopmentLink),
) !void {
    var stmt = try db.prepare(
        \\SELECT body
        \\FROM comments
        \\WHERE parent_kind = ?
        \\  AND parent_id = ?
        \\  AND redacted = 0
        \\ORDER BY created_at, id
    );
    defer stmt.deinit();
    try stmt.bindText(1, parent_kind);
    try stmt.bindText(2, parent_id);
    while (try stmt.step()) {
        const body = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(body);
        try collectOutgoingTextLinks(allocator, db, body, wanted_kind, seen, links);
    }
}

fn collectOutgoingTextLinks(
    allocator: Allocator,
    db: *SqliteDb,
    text: []const u8,
    wanted_kind: []const u8,
    seen: *std.StringHashMap(void),
    links: *std.ArrayList(DevelopmentLink),
) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        const separator = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!isDevelopmentDirectiveKey(std.mem.trim(u8, line[0..separator], " \t\r\n"))) continue;
        var tokens = std.mem.tokenizeAny(u8, line[separator + 1 ..], " \t\r\n,");
        while (tokens.next()) |raw_token| {
            const token = trimReferenceToken(raw_token);
            if (token.len == 0) continue;
            var target = (try resolveTarget(allocator, db, token)) orelse continue;
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
    db: *SqliteDb,
    issue_id: []const u8,
    seen: *std.StringHashMap(void),
    links: *std.ArrayList(DevelopmentLink),
) !void {
    var stmt = try db.prepare(
        \\SELECT p.id, p.title, p.state, COALESCE(a.number, 0), p.body
        \\FROM pulls p
        \\LEFT JOIN legacy_aliases a
        \\  ON a.provider = 'github' AND a.object_kind = 'pull' AND a.object_id = p.id
        \\ORDER BY p.opened_at DESC, p.id DESC
    );
    defer stmt.deinit();
    while (try stmt.step()) {
        const source_id = try stmt.columnTextDup(allocator, 0);
        errdefer allocator.free(source_id);
        const title = try stmt.columnTextDup(allocator, 1);
        errdefer allocator.free(title);
        const state = try stmt.columnTextDup(allocator, 2);
        errdefer allocator.free(state);
        const legacy_number = stmt.columnInt64(3);
        const body = try stmt.columnTextDup(allocator, 4);
        defer allocator.free(body);
        const referenced = try textOrCommentsReferenceObject(allocator, db, "pull", source_id, body, "issue", issue_id);
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
    db: *SqliteDb,
    pull_id: []const u8,
    seen: *std.StringHashMap(void),
    links: *std.ArrayList(DevelopmentLink),
) !void {
    var stmt = try db.prepare(
        \\SELECT i.id, i.title, i.state, COALESCE(a.number, 0), i.body
        \\FROM issues i
        \\LEFT JOIN legacy_aliases a
        \\  ON a.provider = 'github' AND a.object_kind = 'issue' AND a.object_id = i.id
        \\ORDER BY i.opened_at DESC, i.id DESC
    );
    defer stmt.deinit();
    while (try stmt.step()) {
        const source_id = try stmt.columnTextDup(allocator, 0);
        errdefer allocator.free(source_id);
        const title = try stmt.columnTextDup(allocator, 1);
        errdefer allocator.free(title);
        const state = try stmt.columnTextDup(allocator, 2);
        errdefer allocator.free(state);
        const legacy_number = stmt.columnInt64(3);
        const body = try stmt.columnTextDup(allocator, 4);
        defer allocator.free(body);
        const referenced = try textOrCommentsReferenceObject(allocator, db, "issue", source_id, body, "pull", pull_id);
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
    db: *SqliteDb,
    source_kind: []const u8,
    source_id: []const u8,
    body: []const u8,
    target_kind: []const u8,
    target_id: []const u8,
) !bool {
    if (try textReferencesObject(allocator, db, body, target_kind, target_id)) return true;
    var comments = try db.prepare(
        \\SELECT body
        \\FROM comments
        \\WHERE parent_kind = ?
        \\  AND parent_id = ?
        \\  AND redacted = 0
        \\ORDER BY created_at, id
    );
    defer comments.deinit();
    try comments.bindText(1, source_kind);
    try comments.bindText(2, source_id);
    while (try comments.step()) {
        const comment_body = try comments.columnTextDup(allocator, 0);
        defer allocator.free(comment_body);
        if (try textReferencesObject(allocator, db, comment_body, target_kind, target_id)) return true;
    }
    return false;
}

fn textReferencesObject(
    allocator: Allocator,
    db: *SqliteDb,
    text: []const u8,
    target_kind: []const u8,
    target_id: []const u8,
) !bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        const separator = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!isDevelopmentDirectiveKey(std.mem.trim(u8, line[0..separator], " \t\r\n"))) continue;
        var tokens = std.mem.tokenizeAny(u8, line[separator + 1 ..], " \t\r\n,");
        while (tokens.next()) |raw_token| {
            const token = trimReferenceToken(raw_token);
            if (token.len == 0) continue;
            var target = (try resolveTarget(allocator, db, token)) orelse continue;
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

fn resolveTarget(allocator: Allocator, db: *SqliteDb, token: []const u8) !?DevelopmentLink {
    if (std.mem.startsWith(u8, token, "#")) {
        return try resolveUntypedTarget(allocator, db, token[1..]);
    }
    if (asciiStartsWithIgnoreCase(token, "issue:")) {
        return try resolveSpecificTarget(allocator, db, "issue", stripOptionalHash(token["issue:".len..]));
    }
    if (asciiStartsWithIgnoreCase(token, "pr:")) {
        return try resolveSpecificTarget(allocator, db, "pull", stripOptionalHash(token["pr:".len..]));
    }
    if (asciiStartsWithIgnoreCase(token, "pull:")) {
        return try resolveSpecificTarget(allocator, db, "pull", stripOptionalHash(token["pull:".len..]));
    }
    return null;
}

fn resolveUntypedTarget(allocator: Allocator, db: *SqliteDb, value: []const u8) !?DevelopmentLink {
    var issue_target = try resolveSpecificTarget(allocator, db, "issue", value);
    errdefer if (issue_target) |*target| target.deinit();
    var pull_target = try resolveSpecificTarget(allocator, db, "pull", value);
    if (issue_target != null and pull_target != null) {
        issue_target.?.deinit();
        pull_target.?.deinit();
        return null;
    }
    if (issue_target) |target| return target;
    return pull_target;
}

fn resolveSpecificTarget(allocator: Allocator, db: *SqliteDb, object_kind: []const u8, raw_value: []const u8) !?DevelopmentLink {
    const value = std.mem.trim(u8, raw_value, " \t\r\n");
    if (value.len == 0) return null;
    if (util.looksLikeUuid(value)) return try lookupObjectById(allocator, db, object_kind, value);
    if (util.isObjectRefPrefix(value)) return try lookupObjectByHashRef(allocator, db, object_kind, value);
    if (parsePositiveDecimal(value)) |number| return try lookupLegacyObject(allocator, db, object_kind, number);
    return null;
}

fn lookupObjectById(allocator: Allocator, db: *SqliteDb, object_kind: []const u8, object_id: []const u8) !?DevelopmentLink {
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
    var stmt = try db.prepare(sql_text);
    defer stmt.deinit();
    try stmt.bindText(1, object_id);
    if (!(try stmt.step())) return null;
    return .{
        .allocator = allocator,
        .object_kind = object_kind,
        .object_id = try stmt.columnTextDup(allocator, 0),
        .title = try stmt.columnTextDup(allocator, 1),
        .state = try stmt.columnTextDup(allocator, 2),
        .legacy_number = stmt.columnInt64(3),
    };
}

fn lookupObjectByHashRef(allocator: Allocator, db: *SqliteDb, object_kind: []const u8, value: []const u8) !?DevelopmentLink {
    const sql_text: []const u8 = if (std.mem.eql(u8, object_kind, "pull"))
        "SELECT id FROM pulls ORDER BY id"
    else
        "SELECT id FROM issues ORDER BY id";
    var stmt = try db.prepare(sql_text);
    defer stmt.deinit();

    var matched_id: ?[]u8 = null;
    errdefer if (matched_id) |id| allocator.free(id);
    while (try stmt.step()) {
        const candidate_id = try stmt.columnTextDup(allocator, 0);
        errdefer allocator.free(candidate_id);
        var ref_buf: [util.max_object_ref_len]u8 = undefined;
        const candidate_ref = util.objectRefPrefix(ref_buf[0..value.len], candidate_id);
        if (!asciiEqlIgnoreCase(candidate_ref, value)) {
            allocator.free(candidate_id);
            continue;
        }
        if (matched_id != null) {
            allocator.free(candidate_id);
            allocator.free(matched_id.?);
            return null;
        }
        matched_id = candidate_id;
    }
    const id = matched_id orelse return null;
    defer allocator.free(id);
    return try lookupObjectById(allocator, db, object_kind, id);
}

fn lookupLegacyObject(allocator: Allocator, db: *SqliteDb, object_kind: []const u8, number: i64) !?DevelopmentLink {
    var stmt = try db.prepare(
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
    const object_id = try stmt.columnTextDup(allocator, 0);
    defer allocator.free(object_id);
    return try lookupObjectById(allocator, db, object_kind, object_id);
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
        try std.fmt.format(buf.writer(allocator), "{d}", .{link.legacy_number});
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
