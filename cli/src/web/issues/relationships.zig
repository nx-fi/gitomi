const std = @import("std");
const index = @import("../../index.zig");
const shared = @import("../shared.zig");
const util = @import("../../util.zig");

const Allocator = std.mem.Allocator;
const SqliteDb = index.SqliteDb;
const appendTemplate = shared.appendTemplate;
const issueHref = shared.issueHref;
const pullHref = shared.pullHref;

const RelationshipKind = enum {
    parent,
    sub_issue,
    concurrent,
    refs,
    relates_to,
    blocks,
    blocked_by,
    duplicates,
    duplicate_of,
};

pub const ResolvedObjectRef = struct {
    allocator: Allocator,
    object_kind: []const u8,
    object_id: []u8,
    title: []u8,
    state: []u8,
    legacy_number: i64,

    pub fn deinit(self: *ResolvedObjectRef) void {
        self.allocator.free(self.object_id);
        self.allocator.free(self.title);
        self.allocator.free(self.state);
    }
};

pub const RelationshipItem = struct {
    kind: RelationshipKind,
    target: ResolvedObjectRef,
    group: ?[]u8 = null,
    stored: bool = false,

    pub fn deinit(self: *RelationshipItem) void {
        self.target.deinit();
        if (self.group) |group| self.target.allocator.free(group);
    }
};

pub fn collectDirectivesFromText(
    allocator: Allocator,
    db: *SqliteDb,
    issue_id: []const u8,
    text: []const u8,
    seen: *std.StringHashMap(void),
    relationships: *std.ArrayList(RelationshipItem),
) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        const separator = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const kind = relationshipKindFromKey(std.mem.trim(u8, line[0..separator], " \t\r\n")) orelse continue;
        var tokens = std.mem.tokenizeAny(u8, line[separator + 1 ..], " \t\r\n,");
        while (tokens.next()) |raw_token| {
            const token = trimRelationshipToken(raw_token);
            if (token.len == 0) continue;
            var target = (try resolveRelationshipTarget(allocator, db, token)) orelse continue;
            if (std.mem.eql(u8, target.object_kind, "issue") and std.mem.eql(u8, target.object_id, issue_id)) {
                target.deinit();
                continue;
            }
            try collectRelationshipTarget(allocator, kind, target, null, false, seen, relationships);
        }
    }
}

pub fn collectStoredIssueRelationships(
    allocator: Allocator,
    db: *SqliteDb,
    issue_id: []const u8,
    seen: *std.StringHashMap(void),
    relationships: *std.ArrayList(RelationshipItem),
) !void {
    var stmt = try db.prepare(
        \\SELECT DISTINCT rel.display_kind,
        \\       rel.group_key,
        \\       i.id,
        \\       i.title,
        \\       i.state,
        \\       COALESCE(a.number, 0)
        \\FROM (
        \\  SELECT 'parent' AS display_kind, '' AS group_key, r.target_issue_id AS target_issue_id
        \\  FROM issue_relationships r
        \\  WHERE r.source_issue_id = ? AND r.relationship = 'parent'
        \\  UNION ALL
        \\  SELECT 'sub_issue' AS display_kind, '' AS group_key, r.source_issue_id AS target_issue_id
        \\  FROM issue_relationships r
        \\  WHERE r.target_issue_id = ? AND r.relationship = 'parent'
        \\  UNION ALL
        \\  SELECT 'blocks' AS display_kind, '' AS group_key, r.target_issue_id AS target_issue_id
        \\  FROM issue_relationships r
        \\  WHERE r.source_issue_id = ? AND r.relationship = 'blocks'
        \\  UNION ALL
        \\  SELECT 'blocked_by' AS display_kind, '' AS group_key, r.source_issue_id AS target_issue_id
        \\  FROM issue_relationships r
        \\  WHERE r.target_issue_id = ? AND r.relationship = 'blocks'
        \\  UNION ALL
        \\  SELECT 'concurrent' AS display_kind, mine.group_key AS group_key, peer.issue_id AS target_issue_id
        \\  FROM issue_concurrent_groups mine
        \\  JOIN issue_concurrent_groups peer ON peer.group_key = mine.group_key
        \\  WHERE mine.issue_id = ?
        \\) rel
        \\JOIN issues i ON i.id = rel.target_issue_id
        \\LEFT JOIN legacy_aliases a
        \\  ON a.provider = 'github' AND a.object_kind = 'issue' AND a.object_id = i.id
        \\ORDER BY rel.display_kind, lower(rel.group_key), rel.group_key, i.opened_at, i.id
    );
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    try stmt.bindText(2, issue_id);
    try stmt.bindText(3, issue_id);
    try stmt.bindText(4, issue_id);
    try stmt.bindText(5, issue_id);

    while (try stmt.step()) {
        const display_kind = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(display_kind);
        const kind = relationshipKindFromStoredDisplay(display_kind) orelse continue;
        const group_key = try stmt.columnTextDup(allocator, 1);
        const group: ?[]u8 = if (group_key.len == 0) blk: {
            allocator.free(group_key);
            break :blk null;
        } else group_key;
        errdefer if (group) |value| allocator.free(value);
        var target = ResolvedObjectRef{
            .allocator = allocator,
            .object_kind = "issue",
            .object_id = try stmt.columnTextDup(allocator, 2),
            .title = try stmt.columnTextDup(allocator, 3),
            .state = try stmt.columnTextDup(allocator, 4),
            .legacy_number = stmt.columnInt64(5),
        };
        errdefer target.deinit();
        try collectRelationshipTarget(allocator, kind, target, group, true, seen, relationships);
    }
}

fn collectRelationshipTarget(
    allocator: Allocator,
    kind: RelationshipKind,
    target: ResolvedObjectRef,
    group: ?[]u8,
    stored: bool,
    seen: *std.StringHashMap(void),
    relationships: *std.ArrayList(RelationshipItem),
) !void {
    errdefer {
        var cleanup = target;
        cleanup.deinit();
        if (group) |value| allocator.free(value);
    }

    const key = try std.fmt.allocPrint(allocator, "{s}\x1f{s}\x1f{s}\x1f{s}", .{ @tagName(kind), target.object_kind, target.object_id, group orelse "" });
    errdefer allocator.free(key);
    const entry = try seen.getOrPut(key);
    if (entry.found_existing) {
        allocator.free(key);
        var duplicate = target;
        duplicate.deinit();
        if (group) |value| allocator.free(value);
        return;
    }
    entry.value_ptr.* = {};
    errdefer _ = seen.remove(key);
    try relationships.append(allocator, .{ .kind = kind, .target = target, .group = group, .stored = stored });
}

fn trimRelationshipToken(raw: []const u8) []const u8 {
    return std.mem.trim(u8, raw, " \t\r\n.,;()[]{}<>\"'`");
}

fn relationshipKindFromKey(key: []const u8) ?RelationshipKind {
    if (asciiEqlIgnoreCase(key, "Parent") or asciiEqlIgnoreCase(key, "Parent-Issue")) return .parent;
    if (asciiEqlIgnoreCase(key, "Sub-Issue") or asciiEqlIgnoreCase(key, "Subissue") or asciiEqlIgnoreCase(key, "Child")) return .sub_issue;
    if (asciiEqlIgnoreCase(key, "Concurrent") or asciiEqlIgnoreCase(key, "Concurrent-With")) return .concurrent;
    if (asciiEqlIgnoreCase(key, "Refs")) return .refs;
    if (asciiEqlIgnoreCase(key, "Relates-To") or asciiEqlIgnoreCase(key, "Related-To")) return .relates_to;
    if (asciiEqlIgnoreCase(key, "Blocks")) return .blocks;
    if (asciiEqlIgnoreCase(key, "Blocked-By")) return .blocked_by;
    if (asciiEqlIgnoreCase(key, "Duplicates")) return .duplicates;
    if (asciiEqlIgnoreCase(key, "Duplicate-Of")) return .duplicate_of;
    return null;
}

fn relationshipKindFromStoredDisplay(value: []const u8) ?RelationshipKind {
    if (std.mem.eql(u8, value, "parent")) return .parent;
    if (std.mem.eql(u8, value, "sub_issue")) return .sub_issue;
    if (std.mem.eql(u8, value, "blocks")) return .blocks;
    if (std.mem.eql(u8, value, "blocked_by")) return .blocked_by;
    if (std.mem.eql(u8, value, "concurrent")) return .concurrent;
    return null;
}

fn relationshipGroupTitle(kind: RelationshipKind, object_kind: []const u8) []const u8 {
    const is_pull = std.mem.eql(u8, object_kind, "pull");
    return switch (kind) {
        .parent => "Parent issue",
        .sub_issue => "Sub-issues",
        .concurrent => "Concurrent group",
        .refs => if (is_pull) "Referenced pull request" else "Referenced issue",
        .relates_to => if (is_pull) "Related pull request" else "Related issue",
        .blocks => if (is_pull) "Is blocking pull request" else "Is blocking",
        .blocked_by => if (is_pull) "Blocked by pull request" else "Blocked by",
        .duplicates => if (is_pull) "Duplicate pull request" else "Duplicate issue",
        .duplicate_of => if (is_pull) "Original pull request" else "Original issue",
    };
}

pub fn appendGroups(buf: *std.ArrayList(u8), allocator: Allocator, relationships: []const RelationshipItem) !void {
    try appendGroupsInternal(buf, allocator, relationships, .{});
}

pub fn appendEditableGroups(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_ref: []const u8,
    csrf_token: []const u8,
    relationships: []const RelationshipItem,
) !void {
    try appendGroupsInternal(buf, allocator, relationships, .{
        .editable = true,
        .raw_ref = raw_ref,
        .csrf_token = csrf_token,
    });
}

const RelationshipRenderOptions = struct {
    editable: bool = false,
    raw_ref: []const u8 = "",
    csrf_token: []const u8 = "",
};

fn appendGroupsInternal(buf: *std.ArrayList(u8), allocator: Allocator, relationships: []const RelationshipItem, options: RelationshipRenderOptions) !void {
    try buf.appendSlice(allocator, "<div class=\"issue-relationships\">");
    inline for (.{ RelationshipKind.parent, .sub_issue, .blocked_by, .blocks, .duplicate_of, .duplicates, .relates_to, .refs }) |kind| {
        try appendRelationshipGroup(buf, allocator, relationships, kind, "issue", options);
        try appendRelationshipGroup(buf, allocator, relationships, kind, "pull", options);
    }
    try appendConcurrentRelationshipGroups(buf, allocator, relationships, options);
    try buf.appendSlice(allocator, "</div>");
}

fn appendConcurrentRelationshipGroups(buf: *std.ArrayList(u8), allocator: Allocator, relationships: []const RelationshipItem, options: RelationshipRenderOptions) !void {
    for (relationships, 0..) |item, idx| {
        if (item.kind != .concurrent) continue;
        var first_for_group = true;
        for (relationships[0..idx]) |previous| {
            if (previous.kind == .concurrent and optionalStringEql(previous.group, item.group)) {
                first_for_group = false;
                break;
            }
        }
        if (!first_for_group) continue;

        try appendTemplate(buf, allocator,
            \\<div class="issue-relationship-group"><div class="issue-relationship-group-title"><span>{title}
        , .{ .title = relationshipGroupTitle(.concurrent, "issue") });
        if (item.group) |group| {
            try appendTemplate(buf, allocator, ": {group}", .{ .group = group });
        }
        try buf.appendSlice(allocator, "</span>");
        if (options.editable and item.stored) {
            if (item.group) |group| {
                try appendRelationshipRemoveForm(buf, allocator, options, "remove-concurrent-group", "group", group, "Remove concurrent group");
            }
        }
        try buf.appendSlice(allocator, "</div><div class=\"issue-relationship-list\">");
        for (relationships) |candidate| {
            if (candidate.kind != .concurrent or !optionalStringEql(candidate.group, item.group)) continue;
            try appendRelationshipRow(buf, allocator, candidate.target);
        }
        try buf.appendSlice(allocator, "</div></div>");
    }
}

fn appendRelationshipGroup(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    relationships: []const RelationshipItem,
    kind: RelationshipKind,
    object_kind: []const u8,
    options: RelationshipRenderOptions,
) !void {
    var shown = false;
    for (relationships) |item| {
        if (item.kind != kind or !std.mem.eql(u8, item.target.object_kind, object_kind)) continue;
        if (!shown) {
            try appendTemplate(buf, allocator,
                \\<div class="issue-relationship-group"><div class="issue-relationship-group-title">{title}</div><div class="issue-relationship-list">
            , .{ .title = relationshipGroupTitle(kind, object_kind) });
            shown = true;
        }
        try appendRelationshipEntry(buf, allocator, item, options);
    }
    if (shown) try buf.appendSlice(allocator, "</div></div>");
}

fn appendRelationshipEntry(buf: *std.ArrayList(u8), allocator: Allocator, item: RelationshipItem, options: RelationshipRenderOptions) !void {
    if (options.editable and item.stored) {
        if (removeActionForKind(item.kind)) |action| {
            try buf.appendSlice(allocator, "<div class=\"issue-relationship-entry\">");
            try appendRelationshipRow(buf, allocator, item.target);
            try appendRelationshipRemoveForm(buf, allocator, options, action, "target", item.target.object_id, "Remove relationship");
            try buf.appendSlice(allocator, "</div>");
            return;
        }
    }
    try appendRelationshipRow(buf, allocator, item.target);
}

fn appendRelationshipRow(buf: *std.ArrayList(u8), allocator: Allocator, target: ResolvedObjectRef) !void {
    const is_pull = std.mem.eql(u8, target.object_kind, "pull");
    var object_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const object_ref = util.shortObjectRef(&object_ref_buf, target.object_id);
    try buf.appendSlice(allocator, "<a class=\"issue-relationship-row\" href=\"");
    try appendRelationshipTargetHref(buf, allocator, target, object_ref);
    try appendTemplate(buf, allocator,
        \\" aria-label="{kind} {title}">
        \\  <span class="{icon_classes}" aria-hidden="true"></span>
        \\  <span class="issue-relationship-main"><span class="issue-relationship-title">{title}</span><span class="issue-relationship-ref">
    , .{
        .kind = if (is_pull) "Pull request" else "Issue",
        .title = target.title,
        .icon_classes = shared.classes("issue-relationship-icon", &.{
            shared.class("is-issue", !is_pull),
            shared.class("is-pull", is_pull),
            shared.class("is-open", std.mem.eql(u8, target.state, "open")),
            shared.class("is-closed", std.mem.eql(u8, target.state, "closed")),
            shared.class("is-merged", std.mem.eql(u8, target.state, "merged")),
        }),
    });
    try appendRelationshipDisplayRef(buf, allocator, target, object_ref);
    try appendTemplate(buf, allocator,
        \\</span></span><span class="{badge_classes}">{state}</span></a>
    , .{
        .badge_classes = shared.classes("issue-relationship-badge", &.{
            shared.class("is-open", std.mem.eql(u8, target.state, "open")),
            shared.class("is-closed", std.mem.eql(u8, target.state, "closed")),
            shared.class("is-merged", std.mem.eql(u8, target.state, "merged")),
        }),
        .state = relationshipStateLabel(target.state),
    });
}

fn removeActionForKind(kind: RelationshipKind) ?[]const u8 {
    return switch (kind) {
        .parent => "remove-parent",
        .sub_issue => "remove-sub-issue",
        .blocks => "remove-blocking",
        .blocked_by => "remove-blocked-by",
        else => null,
    };
}

fn appendRelationshipRemoveForm(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    options: RelationshipRenderOptions,
    action: []const u8,
    input_name: []const u8,
    value: []const u8,
    label: []const u8,
) !void {
    try buf.appendSlice(allocator, "<form class=\"issue-relationship-remove-form\" method=\"post\" action=\"/issues/");
    try shared.appendUrlEncoded(buf, allocator, options.raw_ref);
    try appendTemplate(buf, allocator,
        \\/sidebar"><input type="hidden" name="csrf_token" value="{csrf_token}"><input type="hidden" name="action" value="{action}"><input type="hidden" name="{input_name}" value="{value}"><button type="submit" aria-label="{label}" title="{label}">x</button></form>
    , .{
        .csrf_token = options.csrf_token,
        .action = action,
        .input_name = input_name,
        .value = value,
        .label = label,
    });
}

fn appendRelationshipTargetHref(buf: *std.ArrayList(u8), allocator: Allocator, target: ResolvedObjectRef, object_ref: []const u8) !void {
    if (target.legacy_number > 0) {
        const number_ref = try std.fmt.allocPrint(allocator, "{d}", .{target.legacy_number});
        defer allocator.free(number_ref);
        try shared.appendHref(buf, allocator, if (std.mem.eql(u8, target.object_kind, "pull")) pullHref(number_ref) else issueHref(number_ref));
        return;
    }
    try shared.appendHref(buf, allocator, if (std.mem.eql(u8, target.object_kind, "pull")) pullHref(object_ref) else issueHref(object_ref));
}

fn appendRelationshipDisplayRef(buf: *std.ArrayList(u8), allocator: Allocator, target: ResolvedObjectRef, object_ref: []const u8) !void {
    if (std.mem.eql(u8, target.object_kind, "pull")) try buf.appendSlice(allocator, "PR ");
    try buf.append(allocator, '#');
    if (target.legacy_number > 0) {
        try std.fmt.format(buf.writer(allocator), "{d}", .{target.legacy_number});
    } else {
        try shared.appendHtml(buf, allocator, object_ref);
    }
}

fn relationshipStateLabel(state: []const u8) []const u8 {
    if (std.mem.eql(u8, state, "open")) return "Open";
    if (std.mem.eql(u8, state, "closed")) return "Closed";
    if (std.mem.eql(u8, state, "merged")) return "Merged";
    return state;
}

fn resolveRelationshipTarget(allocator: Allocator, db: *SqliteDb, token: []const u8) !?ResolvedObjectRef {
    if (std.mem.startsWith(u8, token, "#")) {
        return try resolveUntypedRelationshipTarget(allocator, db, token[1..]);
    }
    if (asciiStartsWithIgnoreCase(token, "issue:")) {
        return try resolveSpecificRelationshipTarget(allocator, db, "issue", stripOptionalHash(token["issue:".len..]));
    }
    if (asciiStartsWithIgnoreCase(token, "pr:")) {
        return try resolveSpecificRelationshipTarget(allocator, db, "pull", stripOptionalHash(token["pr:".len..]));
    }
    if (asciiStartsWithIgnoreCase(token, "pull:")) {
        return try resolveSpecificRelationshipTarget(allocator, db, "pull", stripOptionalHash(token["pull:".len..]));
    }
    return null;
}

fn resolveUntypedRelationshipTarget(allocator: Allocator, db: *SqliteDb, value: []const u8) !?ResolvedObjectRef {
    var issue_target = try resolveSpecificRelationshipTarget(allocator, db, "issue", value);
    errdefer if (issue_target) |*target| target.deinit();
    var pull_target = try resolveSpecificRelationshipTarget(allocator, db, "pull", value);
    if (issue_target != null and pull_target != null) {
        issue_target.?.deinit();
        pull_target.?.deinit();
        return null;
    }
    if (issue_target) |target| return target;
    return pull_target;
}

fn resolveSpecificRelationshipTarget(allocator: Allocator, db: *SqliteDb, object_kind: []const u8, raw_value: []const u8) !?ResolvedObjectRef {
    const value = std.mem.trim(u8, raw_value, " \t\r\n");
    if (value.len == 0) return null;
    if (util.looksLikeUuid(value)) return try lookupResolvedObjectById(allocator, db, object_kind, value);
    if (util.isObjectRefPrefix(value)) return try lookupResolvedObjectByHashRef(allocator, db, object_kind, value);
    if (parsePositiveDecimal(value)) |number| return try lookupResolvedLegacyObject(allocator, db, object_kind, number);
    return null;
}

fn lookupResolvedObjectById(allocator: Allocator, db: *SqliteDb, object_kind: []const u8, object_id: []const u8) !?ResolvedObjectRef {
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

fn lookupResolvedObjectByHashRef(allocator: Allocator, db: *SqliteDb, object_kind: []const u8, value: []const u8) !?ResolvedObjectRef {
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
    return try lookupResolvedObjectById(allocator, db, object_kind, id);
}

fn lookupResolvedLegacyObject(allocator: Allocator, db: *SqliteDb, object_kind: []const u8, number: i64) !?ResolvedObjectRef {
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
    return try lookupResolvedObjectById(allocator, db, object_kind, object_id);
}

fn stripOptionalHash(value: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "#")) return trimmed[1..];
    return trimmed;
}

fn asciiStartsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and asciiEqlIgnoreCase(value[0..prefix.len], prefix);
}

fn optionalStringEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |left| {
        const right = b orelse return false;
        return std.mem.eql(u8, left, right);
    }
    return b == null;
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (std.ascii.toLower(left) != std.ascii.toLower(right)) return false;
    }
    return true;
}

fn parsePositiveDecimal(value: []const u8) ?i64 {
    if (value.len == 0) return null;
    for (value) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    const number = std.fmt.parseInt(i64, value, 10) catch return null;
    return if (number > 0) number else null;
}

test "relationship directive keys are case-insensitive" {
    try std.testing.expectEqual(RelationshipKind.blocks, relationshipKindFromKey("blocks").?);
    try std.testing.expectEqual(RelationshipKind.blocked_by, relationshipKindFromKey("Blocked-By").?);
    try std.testing.expectEqual(RelationshipKind.relates_to, relationshipKindFromKey("related-to").?);
    try std.testing.expect(relationshipKindFromKey("mentions") == null);
    try std.testing.expectEqualStrings("#abc123", trimRelationshipToken("(#abc123,"));
}

test "relationship groups render stateful issue rows" {
    var target = ResolvedObjectRef{
        .allocator = std.testing.allocator,
        .object_kind = "issue",
        .object_id = try std.testing.allocator.dupe(u8, "018f0000-0000-7000-8000-000000000010"),
        .title = try std.testing.allocator.dupe(u8, "Parent issue"),
        .state = try std.testing.allocator.dupe(u8, "open"),
        .legacy_number = 1,
    };
    defer target.deinit();

    const relationships = [_]RelationshipItem{.{ .kind = .blocked_by, .target = target }};

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendGroups(&buf, std.testing.allocator, relationships[0..]);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Blocked by") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Parent issue") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "href=\"/issues/1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "is-open") != null);
}
