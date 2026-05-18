const std = @import("std");

const errors = @import("../errors.zig");
const event_mod = @import("../event.zig");
const git = @import("../git.zig");
const index_schema = @import("schema.zig");
const ordering = @import("projection_ordering.zig");
const projection_objects = @import("projection_objects.zig");
const repo_mod = @import("../repo.zig");
const sqlite_db = @import("sqlite_db.zig");
const util = @import("../util.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const SqliteDb = sqlite_db.SqliteDb;
const SqliteStmt = sqlite_db.SqliteStmt;
const parseEventSummary = event_mod.parseEventSummary;
const parseValidatedEnvelope = event_mod.parseValidatedEnvelope;
const ValidatedEnvelope = event_mod.ValidatedEnvelope;
const runCommand = git.runCommand;
const max_git_output = git.max_git_output;
const gitCheckedMax = git.gitCheckedMax;
const eventInFrontier = ordering.eventInFrontier;
const eventWins = ordering.eventWins;

const max_derived_commit_log_bytes = 64 * 1024 * 1024;
const max_derived_reference_tokens_per_commit: usize = 512;
const max_derived_reference_tokens_per_rebuild: usize = 16 * 1024;

const AuthEventVisibility = enum {
    causal_frontier,
    known_revocations,
};

fn isDataPlaneIndexRef(ref: []const u8) bool {
    return std.mem.startsWith(u8, ref, "refs/heads/") or std.mem.startsWith(u8, ref, "refs/tags/");
}

pub fn projectIndexedEvents(allocator: Allocator, db: *SqliteDb) !void {
    try seedGenesisAuthorization(allocator, db);

    try projectEventQuery(allocator, db, "SELECT event_hash, event_type FROM events WHERE valid_json != 0 AND (event_type LIKE 'acl.%' OR event_type LIKE 'identity.%') ORDER BY ordinal", true);
    try projectEventQuery(allocator, db, "SELECT event_hash, event_type FROM events WHERE valid_json != 0 AND event_type NOT LIKE 'acl.%' AND event_type NOT LIKE 'identity.%' ORDER BY ordinal", false);
}

pub fn projectNewIndexedEvents(allocator: Allocator, db: *SqliteDb) !void {
    try projectEventQuery(allocator, db, "SELECT event_hash, event_type FROM events WHERE valid_json != 0 AND domain_status = 'pending' AND (event_type LIKE 'acl.%' OR event_type LIKE 'identity.%') ORDER BY ordinal", true);
    try projectEventQuery(allocator, db, "SELECT event_hash, event_type FROM events WHERE valid_json != 0 AND domain_status = 'pending' AND event_type NOT LIKE 'acl.%' AND event_type NOT LIKE 'identity.%' ORDER BY ordinal", false);
}

fn projectEventQuery(allocator: Allocator, db: *SqliteDb, comptime sql_text: []const u8, auth_phase: bool) !void {
    var event_hashes: std.ArrayList([]u8) = .empty;
    defer freeStringArrayList(allocator, &event_hashes);

    var auth_priorities = std.StringHashMap(u8).init(allocator);
    defer auth_priorities.deinit();

    var stmt = try db.prepare(sql_text);
    defer stmt.deinit();
    while (try stmt.step()) {
        const event_hash = try stmt.columnTextDup(allocator, 0);
        errdefer allocator.free(event_hash);
        try event_hashes.append(allocator, event_hash);

        if (auth_phase) {
            const event_type = try stmt.columnTextDup(allocator, 1);
            defer allocator.free(event_type);
            try auth_priorities.put(event_hash, authEventSortPriority(event_type));
        }
    }

    try orderEventHashesTopologically(allocator, &event_hashes, if (auth_phase) &auth_priorities else null);

    for (event_hashes.items) |event_hash| {
        const body = try eventBodyByHash(allocator, db, event_hash);
        defer allocator.free(body);
        try projectStoredEvent(allocator, db, event_hash, body, auth_phase);
    }
}

fn orderEventHashesTopologically(allocator: Allocator, event_hashes: *std.ArrayList([]u8), auth_priorities: ?*const std.StringHashMap(u8)) !void {
    if (event_hashes.items.len < 2) return;

    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);
    for (event_hashes.items) |event_hash| {
        try input.appendSlice(allocator, event_hash);
        try input.append(allocator, '\n');
    }

    const ordered_raw = try git.gitCheckedInput(allocator, &.{ "rev-list", "--topo-order", "--reverse", "--stdin" }, input.items);
    defer allocator.free(ordered_raw);

    var indexes = std.StringHashMap(usize).init(allocator);
    defer indexes.deinit();
    for (event_hashes.items, 0..) |event_hash, index| {
        try indexes.put(event_hash, index);
    }

    const ordered = try allocator.alloc([]u8, event_hashes.items.len);
    defer allocator.free(ordered);
    const used = try allocator.alloc(bool, event_hashes.items.len);
    defer allocator.free(used);
    @memset(used, false);

    var count: usize = 0;
    var it = std.mem.tokenizeScalar(u8, ordered_raw, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        const index = indexes.get(line) orelse continue;
        if (used[index]) continue;
        ordered[count] = event_hashes.items[index];
        used[index] = true;
        count += 1;
    }
    for (event_hashes.items, 0..) |event_hash, index| {
        if (used[index]) continue;
        ordered[count] = event_hash;
        count += 1;
    }
    @memcpy(event_hashes.items, ordered);
    try orderConcurrentEventHashes(allocator, event_hashes.items, auth_priorities);
}

fn orderConcurrentEventHashes(allocator: Allocator, event_hashes: [][]u8, auth_priorities: ?*const std.StringHashMap(u8)) !void {
    if (event_hashes.len < 2) return;

    var index: usize = 1;
    while (index < event_hashes.len) : (index += 1) {
        var swap_index = index;
        while (swap_index > 0 and try eventShouldSortBefore(allocator, event_hashes[swap_index], event_hashes[swap_index - 1], auth_priorities)) {
            std.mem.swap([]u8, &event_hashes[swap_index], &event_hashes[swap_index - 1]);
            swap_index -= 1;
        }
    }
}

fn eventShouldSortBefore(allocator: Allocator, candidate: []const u8, current: []const u8, auth_priorities: ?*const std.StringHashMap(u8)) !bool {
    if (std.mem.eql(u8, candidate, current)) return false;
    if (candidate.len != 0 and current.len != 0) {
        if (try git.isAncestor(allocator, candidate, current)) return true;
        if (try git.isAncestor(allocator, current, candidate)) return false;
    }
    if (auth_priorities) |priorities| {
        const candidate_priority = priorities.get(candidate) orelse 1;
        const current_priority = priorities.get(current) orelse 1;
        if (candidate_priority != current_priority) return candidate_priority < current_priority;
    }
    return std.mem.order(u8, candidate, current) == .gt;
}

fn authEventSortPriority(event_type: []const u8) u8 {
    if (std.mem.eql(u8, event_type, "acl.role_revoked") or
        std.mem.eql(u8, event_type, "acl.delegation_revoked") or
        std.mem.eql(u8, event_type, "identity.device_revoked"))
    {
        return 0;
    }
    return 1;
}

fn eventBodyByHash(allocator: Allocator, db: *SqliteDb, event_hash: []const u8) ![]u8 {
    var stmt = try db.prepare("SELECT body FROM events WHERE event_hash = ?");
    defer stmt.deinit();
    try stmt.bindText(1, event_hash);
    if (!(try stmt.step())) return CliError.SqliteFailed;
    return try stmt.columnTextDup(allocator, 0);
}

const DerivedReferenceTarget = struct {
    allocator: Allocator,
    object_kind: []u8,
    object_id: []u8,

    fn deinit(self: *DerivedReferenceTarget) void {
        self.allocator.free(self.object_kind);
        self.allocator.free(self.object_id);
    }
};

const DerivedReferenceToken = struct {
    allocator: Allocator,
    prefix: []u8,
    object_kind: ?[]const u8,

    fn deinit(self: *DerivedReferenceToken) void {
        self.allocator.free(self.prefix);
    }
};

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

    fn loadFromTable(self: *ObjectRefIndex, allocator: Allocator, db: *SqliteDb, comptime table: []const u8) !void {
        var stmt = try db.prepare("SELECT id FROM " ++ table);
        defer stmt.deinit();

        while (try stmt.step()) {
            const id = try stmt.columnTextDup(allocator, 0);
            errdefer allocator.free(id);

            var object_ref: [util.max_object_ref_len]u8 = undefined;
            _ = util.objectRefPrefix(object_ref[0..], id);
            try self.entries.append(allocator, .{
                .object_ref = object_ref,
                .object_id = id,
            });
        }
    }

    fn sort(self: *ObjectRefIndex) void {
        std.mem.sort(ObjectRefEntry, self.entries.items, {}, objectRefEntryLessThan);
    }

    fn resolvePrefix(self: *const ObjectRefIndex, prefix: []const u8) ObjectRefResolution {
        const first = self.lowerBound(prefix);
        if (first >= self.entries.items.len) return .none;
        if (!objectRefStartsWith(self.entries.items[first].object_ref[0..], prefix)) return .none;
        if (first + 1 < self.entries.items.len and objectRefStartsWith(self.entries.items[first + 1].object_ref[0..], prefix)) return .ambiguous;
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
    }
};

const DerivedReferenceResolver = struct {
    allocator: Allocator,
    db: *SqliteDb,
    issues: ObjectRefIndex = .{},
    pulls: ObjectRefIndex = .{},

    fn init(allocator: Allocator, db: *SqliteDb) !DerivedReferenceResolver {
        var resolver = DerivedReferenceResolver{
            .allocator = allocator,
            .db = db,
        };
        errdefer resolver.deinit();

        try resolver.issues.loadFromTable(allocator, db, "issues");
        try resolver.pulls.loadFromTable(allocator, db, "pulls");
        resolver.issues.sort();
        resolver.pulls.sort();

        return resolver;
    }

    fn deinit(self: *DerivedReferenceResolver) void {
        self.issues.deinit(self.allocator);
        self.pulls.deinit(self.allocator);
    }

    fn resolve(self: *DerivedReferenceResolver, prefix: []const u8, object_kind: ?[]const u8) !?DerivedReferenceTarget {
        if (util.isObjectRefPrefix(prefix)) {
            if (try self.resolveHashReference(prefix, object_kind)) |target| return target;
        }
        if (parsePositiveDecimal(prefix)) |number| {
            return try resolveDerivedLegacyReference(self.allocator, self.db, number, object_kind);
        }
        return null;
    }

    fn resolveHashReference(self: *DerivedReferenceResolver, prefix: []const u8, expected_kind: ?[]const u8) !?DerivedReferenceTarget {
        if (expected_kind) |kind| {
            if (std.mem.eql(u8, kind, "issue")) return try self.resolveHashInList("issue", &self.issues, prefix);
            if (std.mem.eql(u8, kind, "pull")) return try self.resolveHashInList("pull", &self.pulls, prefix);
            return null;
        }

        const issue_result = self.issues.resolvePrefix(prefix);
        const pull_result = self.pulls.resolvePrefix(prefix);
        if (resolutionIsAmbiguous(issue_result) or resolutionIsAmbiguous(pull_result)) return null;

        const issue_id = resolutionFoundId(issue_result);
        const pull_id = resolutionFoundId(pull_result);
        if (issue_id != null and pull_id != null) return null;
        if (issue_id) |id| return try self.targetFromId("issue", id);
        if (pull_id) |id| return try self.targetFromId("pull", id);
        return null;
    }

    fn resolveHashInList(self: *DerivedReferenceResolver, kind: []const u8, index: *const ObjectRefIndex, prefix: []const u8) !?DerivedReferenceTarget {
        return switch (index.resolvePrefix(prefix)) {
            .none, .ambiguous => null,
            .found => |id| try self.targetFromId(kind, id),
        };
    }

    fn targetFromId(self: *DerivedReferenceResolver, kind: []const u8, object_id: []const u8) !DerivedReferenceTarget {
        const owned_kind = try self.allocator.dupe(u8, kind);
        errdefer self.allocator.free(owned_kind);
        const owned_id = try self.allocator.dupe(u8, object_id);
        errdefer self.allocator.free(owned_id);
        return .{
            .allocator = self.allocator,
            .object_kind = owned_kind,
            .object_id = owned_id,
        };
    }
};

pub fn rebuildDerivedCommitReferences(allocator: Allocator, db: *SqliteDb, refs_raw: []const u8) !void {
    try db.exec("DELETE FROM commit_references");

    const data_refs = try dataPlaneRefsFromRaw(allocator, refs_raw);
    defer git.freeStringList(allocator, data_refs);
    if (data_refs.len == 0) return;

    const log = try dataPlaneCommitLog(allocator, data_refs);
    defer allocator.free(log);

    var insert = try db.prepare(
        \\INSERT OR IGNORE INTO commit_references(commit_oid, object_kind, object_id, prefix)
        \\VALUES (?, ?, ?, ?)
    );
    defer insert.deinit();

    var resolver = try DerivedReferenceResolver.init(allocator, db);
    defer resolver.deinit();

    var remaining_tokens = max_derived_reference_tokens_per_rebuild;
    var records = std.mem.splitScalar(u8, log, 0x1e);
    while (records.next()) |record_raw| {
        if (remaining_tokens == 0) break;
        const record = std.mem.trim(u8, record_raw, "\r\n");
        if (record.len == 0) continue;
        const first = std.mem.indexOfScalar(u8, record, 0) orelse continue;
        const commit_oid = std.mem.trim(u8, record[0..first], " \t\r\n");
        const message = record[first + 1 ..];
        if (commit_oid.len == 0 or message.len == 0) continue;

        var tokens: std.ArrayList(DerivedReferenceToken) = .empty;
        defer freeDerivedReferenceTokens(allocator, &tokens);
        try collectReferenceTokens(allocator, message, @min(max_derived_reference_tokens_per_commit, remaining_tokens), &tokens);
        remaining_tokens -= tokens.items.len;

        for (tokens.items) |token| {
            var target = (try resolver.resolve(token.prefix, token.object_kind)) orelse continue;
            defer target.deinit();
            try insertDerivedCommitReference(&insert, commit_oid, target.object_kind, target.object_id, token.prefix);
        }
    }
}

fn dataPlaneRefsFromRaw(allocator: Allocator, refs_raw: []const u8) ![][]u8 {
    var refs: std.ArrayList([]u8) = .empty;
    errdefer freeStringArrayList(allocator, &refs);

    var it = std.mem.tokenizeScalar(u8, refs_raw, '\n');
    while (it.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const ref = std.mem.trim(u8, line[0..tab], " \t\r\n");
        if (!isDataPlaneIndexRef(ref)) continue;
        try refs.append(allocator, try allocator.dupe(u8, ref));
    }

    return refs.toOwnedSlice(allocator);
}

fn dataPlaneCommitLog(allocator: Allocator, data_refs: []const []u8) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, "log");
    try argv.append(allocator, "--format=%H%x00%B%x1e");
    for (data_refs) |ref| try argv.append(allocator, ref);

    return gitCheckedMax(allocator, argv.items, max_derived_commit_log_bytes);
}

fn collectReferenceTokens(allocator: Allocator, message: []const u8, max_tokens: usize, tokens: *std.ArrayList(DerivedReferenceToken)) !void {
    var i: usize = 0;
    while (i < message.len and tokens.items.len < max_tokens) {
        if (message[i] == '#') {
            if (try appendReferenceTokenAt(allocator, message, i + 1, null, tokens)) |end| {
                i = end;
                continue;
            }
        } else if (startsWithAt(message, i, "issue:")) {
            if (try appendReferenceTokenAt(allocator, message, i + "issue:".len, "issue", tokens)) |end| {
                i = end;
                continue;
            }
        } else if (startsWithAt(message, i, "pr:")) {
            if (try appendReferenceTokenAt(allocator, message, i + "pr:".len, "pull", tokens)) |end| {
                i = end;
                continue;
            }
        }
        i += 1;
    }
}

fn appendReferenceTokenAt(
    allocator: Allocator,
    message: []const u8,
    start: usize,
    object_kind: ?[]const u8,
    tokens: *std.ArrayList(DerivedReferenceToken),
) !?usize {
    if (start >= message.len or !std.ascii.isHex(message[start])) return null;

    var end = start;
    while (end < message.len and std.ascii.isHex(message[end])) : (end += 1) {}
    if (end < message.len and isReferenceTrailingIdentifier(message[end])) return null;
    const raw_prefix = message[start..end];
    if (!isReferencePrefixCandidate(raw_prefix)) return null;
    try appendUniqueReferenceToken(allocator, tokens, raw_prefix, object_kind);
    return end;
}

fn startsWithAt(value: []const u8, index: usize, prefix: []const u8) bool {
    return index <= value.len and value.len - index >= prefix.len and std.mem.eql(u8, value[index .. index + prefix.len], prefix);
}

fn isReferenceTrailingIdentifier(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
}

fn isReferencePrefixCandidate(prefix: []const u8) bool {
    return util.isObjectRefPrefix(prefix) or parsePositiveDecimal(prefix) != null;
}

fn appendUniqueReferenceToken(
    allocator: Allocator,
    tokens: *std.ArrayList(DerivedReferenceToken),
    raw_prefix: []const u8,
    object_kind: ?[]const u8,
) !void {
    var prefix = try allocator.alloc(u8, raw_prefix.len);
    errdefer allocator.free(prefix);
    for (raw_prefix, 0..) |c, idx| prefix[idx] = std.ascii.toLower(c);

    for (tokens.items) |existing| {
        if (optionalStringEql(existing.object_kind, object_kind) and std.mem.eql(u8, existing.prefix, prefix)) {
            allocator.free(prefix);
            return;
        }
    }

    try tokens.append(allocator, .{
        .allocator = allocator,
        .prefix = prefix,
        .object_kind = object_kind,
    });
}

fn optionalStringEql(left: ?[]const u8, right: ?[]const u8) bool {
    if (left) |left_value| {
        const right_value = right orelse return false;
        return std.mem.eql(u8, left_value, right_value);
    }
    return right == null;
}

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

fn objectRefStartsWith(object_ref: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, object_ref, prefix);
}

fn resolutionIsAmbiguous(resolution: ObjectRefResolution) bool {
    return switch (resolution) {
        .ambiguous => true,
        .none, .found => false,
    };
}

fn resolutionFoundId(resolution: ObjectRefResolution) ?[]const u8 {
    return switch (resolution) {
        .found => |id| id,
        .none, .ambiguous => null,
    };
}

fn resolveDerivedLegacyReference(allocator: Allocator, db: *SqliteDb, number: i64, expected_kind: ?[]const u8) !?DerivedReferenceTarget {
    var stmt = try db.prepare(
        \\SELECT object_kind, object_id
        \\FROM legacy_aliases
        \\WHERE provider = 'github'
        \\  AND object_kind IN ('issue', 'pull')
        \\  AND number = ?
        \\ORDER BY object_kind, object_id
    );
    defer stmt.deinit();
    try stmt.bindInt64(1, number);

    var object_kind: ?[]u8 = null;
    var object_id: ?[]u8 = null;
    errdefer if (object_kind) |value| allocator.free(value);
    errdefer if (object_id) |value| allocator.free(value);
    while (try stmt.step()) {
        const candidate_kind = try stmt.columnTextDup(allocator, 0);
        errdefer allocator.free(candidate_kind);
        const candidate_id = try stmt.columnTextDup(allocator, 1);
        errdefer allocator.free(candidate_id);
        if (expected_kind) |kind| {
            if (!std.mem.eql(u8, candidate_kind, kind)) {
                allocator.free(candidate_kind);
                allocator.free(candidate_id);
                continue;
            }
        }

        if (object_id != null) {
            allocator.free(candidate_kind);
            allocator.free(candidate_id);
            allocator.free(object_kind.?);
            allocator.free(object_id.?);
            object_kind = null;
            object_id = null;
            return null;
        }

        object_kind = candidate_kind;
        object_id = candidate_id;
    }
    if (object_id == null) return null;

    const target = DerivedReferenceTarget{
        .allocator = allocator,
        .object_kind = object_kind.?,
        .object_id = object_id.?,
    };
    object_kind = null;
    object_id = null;
    return target;
}

fn parsePositiveDecimal(value: []const u8) ?i64 {
    if (value.len == 0) return null;
    for (value) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    const number = std.fmt.parseInt(i64, value, 10) catch return null;
    return if (number > 0) number else null;
}

fn insertDerivedCommitReference(
    stmt: *SqliteStmt,
    commit_oid: []const u8,
    object_kind: []const u8,
    object_id: []const u8,
    prefix: []const u8,
) !void {
    try stmt.reset();
    try stmt.bindText(1, commit_oid);
    try stmt.bindText(2, object_kind);
    try stmt.bindText(3, object_id);
    try stmt.bindText(4, prefix);
    try stmt.stepDone();
}

fn freeStringArrayList(allocator: Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |value| allocator.free(value);
    list.deinit(allocator);
}

fn freeDerivedReferenceTokens(allocator: Allocator, tokens: *std.ArrayList(DerivedReferenceToken)) void {
    for (tokens.items) |*token| token.deinit();
    tokens.deinit(allocator);
}

pub fn projectStoredEvent(allocator: Allocator, db: *SqliteDb, event_hash: []const u8, body: []const u8, auth_phase: bool) !void {
    var envelope = parseValidatedEnvelope(allocator, body) catch {
        try markDomainRejected(db, event_hash, "invalid_event_envelope");
        return;
    };
    defer envelope.deinit();

    if (try authorizationRejection(allocator, db, event_hash, envelope, body)) |reason| {
        try markDomainRejected(db, event_hash, reason);
        return;
    }

    const savepoint = "gitomi_project_event";
    try db.exec("SAVEPOINT " ++ savepoint);
    var savepoint_active = true;
    errdefer if (savepoint_active) {
        db.exec("ROLLBACK TO " ++ savepoint) catch {};
        db.exec("RELEASE " ++ savepoint) catch {};
    };

    const rejection = if (auth_phase)
        if (std.mem.startsWith(u8, envelope.event_type, "acl."))
            try applyAclProjection(allocator, db, event_hash, envelope, body)
        else
            try applyIdentityProjection(allocator, db, event_hash, envelope, body)
    else if (std.mem.startsWith(u8, envelope.event_type, "issue."))
        try projection_objects.applyIssueProjection(allocator, db, event_hash, envelope, body)
    else if (std.mem.startsWith(u8, envelope.event_type, "pull."))
        try projection_objects.applyPullProjection(allocator, db, event_hash, envelope, body)
    else if (std.mem.startsWith(u8, envelope.event_type, "project."))
        try projection_objects.applyProjectProjection(allocator, db, event_hash, envelope, body)
    else if (std.mem.startsWith(u8, envelope.event_type, "milestone."))
        try projection_objects.applyMilestoneProjection(allocator, db, event_hash, envelope, body)
    else if (std.mem.startsWith(u8, envelope.event_type, "label."))
        try projection_objects.applyLabelProjection(allocator, db, event_hash, envelope, body)
    else if (std.mem.startsWith(u8, envelope.event_type, "comment."))
        try projection_objects.applyCommentProjection(allocator, db, event_hash, envelope, body)
    else if (std.mem.startsWith(u8, envelope.event_type, "notification."))
        try projection_objects.applyNotificationProjection(allocator, db, event_hash, envelope, body)
    else
        null;

    if (rejection) |reason| {
        try db.exec("ROLLBACK TO " ++ savepoint);
        try db.exec("RELEASE " ++ savepoint);
        savepoint_active = false;
        try markDomainRejected(db, event_hash, reason);
    } else {
        if (!auth_phase) {
            try projection_objects.applyNotificationSideEffects(allocator, db, event_hash, envelope, body);
        }
        try db.exec("RELEASE " ++ savepoint);
        savepoint_active = false;
        try markDomainAccepted(db, event_hash);
    }
}

pub fn signingKeyBindingRejection(allocator: Allocator, db: *SqliteDb, event_hash: []const u8, envelope: ValidatedEnvelope, body: ?[]const u8) !?[]const u8 {
    const access_mode = try accessModeFromDb(db);

    if (try identityDeviceFingerprintAtAuthFrontier(allocator, db, envelope.actor_principal, envelope.actor_device, event_hash)) |expected_fingerprint| {
        defer allocator.free(expected_fingerprint);
        const signer_fingerprint = (try git.verifiedCommitSigningKeyFingerprint(allocator, event_hash)) orelse return "signing_key_mismatch";
        defer allocator.free(signer_fingerprint);
        if (!std.mem.eql(u8, expected_fingerprint, signer_fingerprint)) return "signing_key_mismatch";
        return null;
    }

    const role = try aclRoleAtAuthFrontier(allocator, db, envelope.actor_principal, event_hash);
    if (role) |value| {
        allocator.free(value);
        return "unauthorized_device";
    }

    if (importDelegatesEvent(envelope.event_type)) {
        if (try importDelegationFingerprintAtAuthFrontier(
            allocator,
            db,
            envelope.actor_principal,
            envelope.actor_device,
            event_hash,
        )) |delegated_fingerprint| {
            defer allocator.free(delegated_fingerprint);
            const signer_fingerprint = (try git.verifiedCommitSigningKeyFingerprint(allocator, event_hash)) orelse return "signing_key_mismatch";
            defer allocator.free(signer_fingerprint);
            if (!std.mem.eql(u8, delegated_fingerprint, signer_fingerprint)) return "signing_key_mismatch";
            return null;
        }
    }

    if (access_mode == .open) {
        return try openSelfRegistrationRejection(allocator, event_hash, envelope, body);
    }

    return null;
}

fn openSelfRegistrationRejection(allocator: Allocator, event_hash: []const u8, envelope: ValidatedEnvelope, body: ?[]const u8) !?[]const u8 {
    if (!std.mem.eql(u8, envelope.event_type, "identity.device_added")) return "unauthorized_device";
    const expected_fingerprint = (try selfRegistrationFingerprint(allocator, envelope, body orelse return "unauthorized_device")) orelse return "unauthorized_device";
    defer allocator.free(expected_fingerprint);

    const signer_fingerprint = (try git.verifiedCommitSigningKeyFingerprint(allocator, event_hash)) orelse return "signing_key_mismatch";
    defer allocator.free(signer_fingerprint);
    if (!std.mem.eql(u8, expected_fingerprint, signer_fingerprint)) return "signing_key_mismatch";
    return null;
}

pub fn selfRegistrationFingerprint(allocator: Allocator, envelope: ValidatedEnvelope, body: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return null,
    };
    const payload = switch (root.get("payload") orelse return null) {
        .object => |object| object,
        else => return null,
    };
    const principal = event_mod.jsonString(payload.get("principal")) orelse return null;
    const device = event_mod.jsonString(payload.get("device")) orelse return null;
    if (!std.mem.eql(u8, principal, envelope.actor_principal) or !std.mem.eql(u8, device, envelope.actor_device)) return null;

    const signing_key = switch (payload.get("signing_key") orelse return null) {
        .object => |object| object,
        else => return null,
    };
    const fingerprint = event_mod.jsonString(signing_key.get("fingerprint")) orelse return null;
    if (fingerprint.len == 0) return null;
    return try allocator.dupe(u8, fingerprint);
}

fn seedGenesisAuthorization(allocator: Allocator, db: *SqliteDb) !void {
    const genesis_oid = try git.resolveOptionalRef(allocator, repo_mod.genesis_ref);
    defer if (genesis_oid) |oid| allocator.free(oid);
    const oid = genesis_oid orelse return;

    var manifest = repo_mod.loadGenesisManifest(allocator, oid) catch return;
    defer manifest.deinit();

    try upsertMeta(db, "access_mode", repo_mod.accessModeName(manifest.access_mode));
    try upsertAclRole(db, manifest.owner_principal, manifest.owner_role, oid);
    try insertAclHistory(db, manifest.owner_principal, manifest.owner_role, "", "acl.role_granted");
    try upsertIdentityDevice(db, manifest.device_principal, manifest.device_id, manifest.fingerprint, manifest.public_key, oid, null);
    try insertIdentityHistory(db, manifest.device_principal, manifest.device_id, manifest.fingerprint, manifest.public_key, "", "identity.device_added");
}

pub fn authorizationRejection(allocator: Allocator, db: *SqliteDb, event_hash: ?[]const u8, envelope: ValidatedEnvelope, body: []const u8) !?[]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return "invalid_event_envelope",
    };
    const payload = switch (root.get("payload") orelse return "invalid_event_envelope") {
        .object => |object| object,
        else => return "invalid_event_envelope",
    };
    if (event_hash) |hash| {
        if (try signingKeyBindingRejection(allocator, db, hash, envelope, body)) |reason| return reason;
    }
    if (hasGitHubLegacyAlias(envelope.event_type, root)) {
        if (try legacyAliasAuthorizationRejection(allocator, db, envelope, event_hash, "github.import")) |reason| return reason;
    }
    if (hasGitLabLegacyAlias(envelope.event_type, root)) {
        if (try legacyAliasAuthorizationRejection(allocator, db, envelope, event_hash, "gitlab.import")) |reason| return reason;
    }
    if (try sourceIdentityMetadataAuthorizationRejection(allocator, db, envelope, event_hash, root, payload)) |reason| return reason;
    if ((try accessModeFromDb(db)) == .open) {
        return try eventAuthorizationRejection(allocator, db, "owner", envelope, payload, event_hash);
    }

    const role = if (event_hash) |hash|
        try aclRoleAtAuthFrontier(allocator, db, envelope.actor_principal, hash)
    else
        try currentRole(allocator, db, envelope.actor_principal);
    if (role) |value| {
        defer allocator.free(value);
        if (event_hash == null and !(try currentDeviceActive(db, envelope.actor_principal, envelope.actor_device))) {
            return "unauthorized_device";
        }

        if (try eventAuthorizationRejection(allocator, db, value, envelope, payload, event_hash)) |reason| return reason;
        return null;
    }

    return try delegationAuthorizationRejection(allocator, db, event_hash, envelope);
}

fn upsertMeta(db: *SqliteDb, key: []const u8, value: []const u8) !void {
    var stmt = try db.prepare(
        \\INSERT INTO meta(key, value)
        \\VALUES (?, ?)
        \\ON CONFLICT(key) DO UPDATE SET value = excluded.value
    );
    defer stmt.deinit();
    try stmt.bindText(1, key);
    try stmt.bindText(2, value);
    try stmt.stepDone();
}

fn accessModeFromDb(db: *SqliteDb) !repo_mod.AccessMode {
    var stmt = try db.prepare("SELECT value FROM meta WHERE key = 'access_mode'");
    defer stmt.deinit();
    if (!(try stmt.step())) return .closed;
    const value = try stmt.columnTextDup(db.allocator, 0);
    defer db.allocator.free(value);
    return repo_mod.parseAccessMode(value) orelse .closed;
}

fn eventInAuthFrontier(allocator: Allocator, candidate_hash: []const u8, before_event_hash: ?[]const u8) !bool {
    return try eventInFrontier(allocator, candidate_hash, before_event_hash);
}

fn authEventVisible(
    allocator: Allocator,
    candidate_hash: []const u8,
    before_event_hash: ?[]const u8,
    event_type: []const u8,
    revocation_type: []const u8,
    visibility: AuthEventVisibility,
) !bool {
    if (try eventInAuthFrontier(allocator, candidate_hash, before_event_hash)) return true;
    return visibility == .known_revocations and std.mem.eql(u8, event_type, revocation_type);
}

fn eventAuthorizationRejection(
    allocator: Allocator,
    db: *SqliteDb,
    role: []const u8,
    envelope: ValidatedEnvelope,
    payload: std.json.ObjectMap,
    event_hash: ?[]const u8,
) !?[]const u8 {
    if (std.mem.eql(u8, envelope.event_type, "issue.opened")) {
        if (!roleAtLeast(role, "reporter")) return "insufficient_role";
        if (payloadContainsNonEmptyArray(payload, "labels") and !roleAtLeast(role, "maintainer")) return "insufficient_role";
        if (payloadContainsNonEmptyArray(payload, "assignees") and !roleAtLeast(role, "maintainer")) return "insufficient_role";
        if (payloadHasAny(payload, &.{"milestone"}) and !roleAtLeast(role, "maintainer")) return "insufficient_role";
        if (payloadContainsNonEmptyArray(payload, "projects") and !roleAtLeast(role, "maintainer")) return "insufficient_role";
        return null;
    }
    if (std.mem.eql(u8, envelope.event_type, "issue.updated")) {
        if (payloadHasAny(payload, &.{ "title", "body", "state", "type", "priority", "status" }) and !(try canEditObject(allocator, db, role, envelope.actor_principal, "issue", envelope.object_id, event_hash))) return "insufficient_role";
        if (payloadHasAny(payload, &.{"milestone"}) and !roleAtLeast(role, "maintainer")) return "insufficient_role";
        if (payloadContainsNonEmptyArray(payload, "projects") and !roleAtLeast(role, "maintainer")) return "insufficient_role";
        if (payloadContainsNonEmptyArray(payload, "labels_added") or payloadContainsNonEmptyArray(payload, "labels_removed")) {
            if (!roleAtLeast(role, "maintainer")) return "insufficient_role";
        }
        if (payloadContainsNonEmptyArray(payload, "assignees_added") or payloadContainsNonEmptyArray(payload, "assignees_removed")) {
            if (!roleAtLeast(role, "maintainer")) return "insufficient_role";
        }
        return null;
    }
    if (std.mem.eql(u8, envelope.event_type, "issue.title_set") or
        std.mem.eql(u8, envelope.event_type, "issue.body_set") or
        std.mem.eql(u8, envelope.event_type, "issue.state_set") or
        std.mem.eql(u8, envelope.event_type, "issue.type_set") or
        std.mem.eql(u8, envelope.event_type, "issue.priority_set") or
        std.mem.eql(u8, envelope.event_type, "issue.status_set"))
    {
        return if (try canEditObject(allocator, db, role, envelope.actor_principal, "issue", envelope.object_id, event_hash)) null else "insufficient_role";
    }
    if (std.mem.eql(u8, envelope.event_type, "issue.label_added") or std.mem.eql(u8, envelope.event_type, "issue.label_removed")) {
        return if (roleAtLeast(role, "maintainer")) null else "insufficient_role";
    }
    if (std.mem.eql(u8, envelope.event_type, "issue.assignee_added") or std.mem.eql(u8, envelope.event_type, "issue.assignee_removed")) {
        return if (roleAtLeast(role, "maintainer")) null else "insufficient_role";
    }
    if (std.mem.eql(u8, envelope.event_type, "issue.milestone_set") or
        std.mem.eql(u8, envelope.event_type, "issue.project_added") or
        std.mem.eql(u8, envelope.event_type, "issue.project_removed") or
        std.mem.eql(u8, envelope.event_type, "issue.relationship_added") or
        std.mem.eql(u8, envelope.event_type, "issue.relationship_removed") or
        std.mem.eql(u8, envelope.event_type, "issue.concurrent_group_added") or
        std.mem.eql(u8, envelope.event_type, "issue.concurrent_group_removed") or
        std.mem.eql(u8, envelope.event_type, "issue.project_field_set") or
        std.mem.eql(u8, envelope.event_type, "issue.project_field_cleared"))
    {
        return if (roleAtLeast(role, "maintainer")) null else "insufficient_role";
    }
    if (std.mem.eql(u8, envelope.event_type, "issue.reaction_added") or
        std.mem.eql(u8, envelope.event_type, "issue.reaction_removed"))
    {
        return if (roleAtLeast(role, "reporter")) null else "insufficient_role";
    }

    if (std.mem.eql(u8, envelope.event_type, "pull.opened")) {
        if (!roleAtLeast(role, "contributor")) return "insufficient_role";
        if (payloadContainsNonEmptyArray(payload, "labels") and !roleAtLeast(role, "maintainer")) return "insufficient_role";
        if (payloadContainsNonEmptyArray(payload, "assignees") and !roleAtLeast(role, "maintainer")) return "insufficient_role";
        if (payloadContainsNonEmptyArray(payload, "reviewers") and !roleAtLeast(role, "maintainer")) return "insufficient_role";
        return null;
    }
    if (std.mem.eql(u8, envelope.event_type, "pull.updated")) {
        if (payloadHasAny(payload, &.{ "title", "body", "state", "base_ref", "head_ref" }) and !(try canEditObject(allocator, db, role, envelope.actor_principal, "pull", envelope.object_id, event_hash))) return "insufficient_role";
        if (payloadContainsNonEmptyArray(payload, "labels_added") or payloadContainsNonEmptyArray(payload, "labels_removed")) {
            if (!roleAtLeast(role, "maintainer")) return "insufficient_role";
        }
        if (payloadContainsNonEmptyArray(payload, "assignees_added") or payloadContainsNonEmptyArray(payload, "assignees_removed")) {
            if (!roleAtLeast(role, "maintainer")) return "insufficient_role";
        }
        if (payloadContainsNonEmptyArray(payload, "reviewers_added") or payloadContainsNonEmptyArray(payload, "reviewers_removed")) {
            if (!roleAtLeast(role, "maintainer")) return "insufficient_role";
        }
        return null;
    }
    if (std.mem.eql(u8, envelope.event_type, "pull.title_set") or
        std.mem.eql(u8, envelope.event_type, "pull.body_set") or
        std.mem.eql(u8, envelope.event_type, "pull.state_set") or
        std.mem.eql(u8, envelope.event_type, "pull.base_set") or
        std.mem.eql(u8, envelope.event_type, "pull.head_set"))
    {
        return if (try canEditObject(allocator, db, role, envelope.actor_principal, "pull", envelope.object_id, event_hash)) null else "insufficient_role";
    }
    if (std.mem.eql(u8, envelope.event_type, "pull.label_added") or std.mem.eql(u8, envelope.event_type, "pull.label_removed") or
        std.mem.eql(u8, envelope.event_type, "pull.assignee_added") or std.mem.eql(u8, envelope.event_type, "pull.assignee_removed") or
        std.mem.eql(u8, envelope.event_type, "pull.reviewer_added") or std.mem.eql(u8, envelope.event_type, "pull.reviewer_removed") or
        std.mem.eql(u8, envelope.event_type, "pull.merged"))
    {
        return if (roleAtLeast(role, "maintainer")) null else "insufficient_role";
    }
    if (std.mem.eql(u8, envelope.event_type, "pull.reaction_added") or
        std.mem.eql(u8, envelope.event_type, "pull.reaction_removed"))
    {
        return if (roleAtLeast(role, "reporter")) null else "insufficient_role";
    }

    if (std.mem.startsWith(u8, envelope.event_type, "project.") or
        std.mem.startsWith(u8, envelope.event_type, "milestone."))
    {
        return if (roleAtLeast(role, "maintainer")) null else "insufficient_role";
    }

    if (std.mem.eql(u8, envelope.event_type, "label.created") or
        std.mem.eql(u8, envelope.event_type, "label.updated") or
        std.mem.eql(u8, envelope.event_type, "label.deleted"))
    {
        return if (roleAtLeast(role, "maintainer")) null else "insufficient_role";
    }

    if (std.mem.eql(u8, envelope.event_type, "comment.added")) {
        return if (roleAtLeast(role, "reporter")) null else "insufficient_role";
    }
    if (std.mem.eql(u8, envelope.event_type, "comment.body_set")) {
        return if (try canEditObject(allocator, db, role, envelope.actor_principal, "comment", envelope.object_id, event_hash)) null else "insufficient_role";
    }
    if (std.mem.eql(u8, envelope.event_type, "comment.redacted")) {
        return if (try canRedactComment(allocator, db, role, envelope.actor_principal, envelope.object_id, event_hash)) null else "insufficient_role";
    }
    if (std.mem.eql(u8, envelope.event_type, "comment.reaction_added") or
        std.mem.eql(u8, envelope.event_type, "comment.reaction_removed"))
    {
        return if (roleAtLeast(role, "reporter")) null else "insufficient_role";
    }

    if (std.mem.eql(u8, envelope.event_type, "notification.subscribed") or
        std.mem.eql(u8, envelope.event_type, "notification.unsubscribed") or
        std.mem.eql(u8, envelope.event_type, "notification.read") or
        std.mem.eql(u8, envelope.event_type, "notification.read_all"))
    {
        if (!roleAtLeast(role, "reporter")) return "insufficient_role";
        const principal = event_mod.jsonString(payload.get("principal")) orelse return "invalid_event_envelope";
        if (std.mem.eql(u8, principal, envelope.actor_principal)) return null;
        return if (roleAtLeast(role, "maintainer")) null else "insufficient_role";
    }

    if (std.mem.eql(u8, envelope.event_type, "acl.role_granted")) {
        if (!roleAtLeast(role, "owner")) return "insufficient_role";
        const target_role = event_mod.jsonString(payload.get("role")) orelse return "invalid_event_envelope";
        if (!event_mod.isKnownRole(target_role)) return "invalid_role";
        if (!roleAtLeast(role, target_role)) return "privilege_escalation";
        return null;
    }
    if (std.mem.eql(u8, envelope.event_type, "acl.role_revoked")) {
        return if (roleAtLeast(role, "owner")) null else "insufficient_role";
    }
    if (std.mem.eql(u8, envelope.event_type, "acl.delegation_granted") or
        std.mem.eql(u8, envelope.event_type, "acl.delegation_revoked"))
    {
        return if (roleAtLeast(role, "maintainer")) null else "insufficient_role";
    }

    if (std.mem.eql(u8, envelope.event_type, "identity.device_added") or std.mem.eql(u8, envelope.event_type, "identity.device_revoked")) {
        return if (roleAtLeast(role, "owner")) null else "insufficient_role";
    }

    if (std.mem.eql(u8, envelope.event_type, "action.run_requested") or std.mem.eql(u8, envelope.event_type, "action.run_completed")) {
        return if (roleAtLeast(role, "maintainer")) null else "insufficient_role";
    }

    return "unknown_event_type";
}

fn delegationAuthorizationRejection(
    allocator: Allocator,
    db: *SqliteDb,
    event_hash: ?[]const u8,
    envelope: ValidatedEnvelope,
) !?[]const u8 {
    const hash = event_hash orelse return "unauthorized_principal";
    if (!importDelegatesEvent(envelope.event_type)) return "unauthorized_principal";

    const signer_fingerprint = (try git.verifiedCommitSigningKeyFingerprint(allocator, hash)) orelse return "signing_key_mismatch";
    defer allocator.free(signer_fingerprint);

    const delegated_fingerprint = (try importDelegationFingerprintAtAuthFrontier(
        allocator,
        db,
        envelope.actor_principal,
        envelope.actor_device,
        hash,
    )) orelse return "unauthorized_principal";
    defer allocator.free(delegated_fingerprint);

    if (!std.mem.eql(u8, delegated_fingerprint, signer_fingerprint)) return "signing_key_mismatch";
    return null;
}

pub fn githubImportDelegatesEvent(event_type: []const u8) bool {
    return importDelegatesEvent(event_type);
}

pub fn importDelegatesEvent(event_type: []const u8) bool {
    return std.mem.eql(u8, event_type, "issue.opened") or
        std.mem.eql(u8, event_type, "issue.updated") or
        std.mem.eql(u8, event_type, "issue.title_set") or
        std.mem.eql(u8, event_type, "issue.body_set") or
        std.mem.eql(u8, event_type, "issue.state_set") or
        std.mem.eql(u8, event_type, "issue.label_added") or
        std.mem.eql(u8, event_type, "issue.label_removed") or
        std.mem.eql(u8, event_type, "issue.assignee_added") or
        std.mem.eql(u8, event_type, "issue.assignee_removed") or
        std.mem.eql(u8, event_type, "issue.milestone_set") or
        std.mem.eql(u8, event_type, "issue.type_set") or
        std.mem.eql(u8, event_type, "issue.priority_set") or
        std.mem.eql(u8, event_type, "issue.status_set") or
        std.mem.eql(u8, event_type, "issue.project_added") or
        std.mem.eql(u8, event_type, "milestone.created") or
        std.mem.eql(u8, event_type, "pull.opened") or
        std.mem.eql(u8, event_type, "pull.updated") or
        std.mem.eql(u8, event_type, "pull.title_set") or
        std.mem.eql(u8, event_type, "pull.body_set") or
        std.mem.eql(u8, event_type, "pull.state_set") or
        std.mem.eql(u8, event_type, "pull.base_set") or
        std.mem.eql(u8, event_type, "pull.head_set") or
        std.mem.eql(u8, event_type, "pull.label_added") or
        std.mem.eql(u8, event_type, "pull.label_removed") or
        std.mem.eql(u8, event_type, "pull.assignee_added") or
        std.mem.eql(u8, event_type, "pull.assignee_removed") or
        std.mem.eql(u8, event_type, "pull.reviewer_added") or
        std.mem.eql(u8, event_type, "pull.reviewer_removed") or
        std.mem.eql(u8, event_type, "pull.merged") or
        std.mem.eql(u8, event_type, "comment.added") or
        std.mem.eql(u8, event_type, "comment.body_set") or
        std.mem.eql(u8, event_type, "comment.redacted");
}

test "import delegation includes milestone creation" {
    try std.testing.expect(importDelegatesEvent("milestone.created"));
}

test "known import capabilities include GitHub and GitLab" {
    try std.testing.expect(isKnownImportCapability("github.import"));
    try std.testing.expect(isKnownImportCapability("gitlab.import"));
    try std.testing.expect(!isKnownImportCapability("ci.run"));
}

fn legacyAliasAuthorizationRejection(
    allocator: Allocator,
    db: *SqliteDb,
    envelope: ValidatedEnvelope,
    event_hash: ?[]const u8,
    capability: []const u8,
) !?[]const u8 {
    return try delegatedImportCapabilityAuthorizationRejection(
        allocator,
        db,
        envelope,
        event_hash,
        capability,
        "unauthorized_legacy_alias",
    );
}

fn sourceIdentityMetadataAuthorizationRejection(
    allocator: Allocator,
    db: *SqliteDb,
    envelope: ValidatedEnvelope,
    event_hash: ?[]const u8,
    root: std.json.ObjectMap,
    payload: std.json.ObjectMap,
) !?[]const u8 {
    if (!payloadHasSourceIdentityMetadata(payload)) return null;
    const capability = sourceIdentityImportCapability(envelope.event_type, root, payload) orelse return "unauthorized_source_identity";
    return try delegatedImportCapabilityAuthorizationRejection(
        allocator,
        db,
        envelope,
        event_hash,
        capability,
        "unauthorized_source_identity",
    );
}

fn delegatedImportCapabilityAuthorizationRejection(
    allocator: Allocator,
    db: *SqliteDb,
    envelope: ValidatedEnvelope,
    event_hash: ?[]const u8,
    capability: []const u8,
    unauthorized_reason: []const u8,
) !?[]const u8 {
    const hash = event_hash orelse return unauthorized_reason;
    if (!importDelegatesEvent(envelope.event_type)) return unauthorized_reason;
    const delegated_fingerprint = (try delegationFingerprintAtAuthFrontier(
        allocator,
        db,
        envelope.actor_principal,
        envelope.actor_device,
        capability,
        hash,
    )) orelse return unauthorized_reason;
    defer allocator.free(delegated_fingerprint);

    const signer_fingerprint = (try git.verifiedCommitSigningKeyFingerprint(allocator, hash)) orelse return "signing_key_mismatch";
    defer allocator.free(signer_fingerprint);
    if (!std.mem.eql(u8, delegated_fingerprint, signer_fingerprint)) return "signing_key_mismatch";
    return null;
}

fn payloadHasSourceIdentityMetadata(payload: std.json.ObjectMap) bool {
    return payloadHasNonEmptyString(payload, "source_author") or
        payloadHasNonEmptyString(payload, "source_identity") or
        payloadHasNonEmptyString(payload, "source_email") or
        payloadHasNonEmptyString(payload, "source_avatar_url");
}

fn payloadHasNonEmptyString(payload: std.json.ObjectMap, key: []const u8) bool {
    const value = event_mod.jsonString(payload.get(key)) orelse return false;
    return value.len != 0;
}

fn sourceIdentityImportCapability(event_type: []const u8, root: std.json.ObjectMap, payload: std.json.ObjectMap) ?[]const u8 {
    const source_identity = event_mod.jsonString(payload.get("source_identity")) orelse "";
    if (source_identity.len != 0) return capabilityForSourceIdentity(source_identity);
    if (hasGitHubLegacyAlias(event_type, root)) return "github.import";
    if (hasGitLabLegacyAlias(event_type, root)) return "gitlab.import";
    return null;
}

fn capabilityForSourceIdentity(source_identity: []const u8) ?[]const u8 {
    const split = std.mem.indexOfScalar(u8, source_identity, ':') orelse return null;
    if (split == 0 or split + 1 >= source_identity.len) return null;
    const provider = source_identity[0..split];
    if (std.mem.eql(u8, provider, "github")) return "github.import";
    if (std.mem.eql(u8, provider, "gitlab")) return "gitlab.import";
    return null;
}

fn hasGitHubLegacyAlias(event_type: []const u8, root: std.json.ObjectMap) bool {
    const legacy = switch (root.get("legacy") orelse return false) {
        .object => |object| object,
        else => return false,
    };
    if (std.mem.startsWith(u8, event_type, "issue.")) return legacyPositiveInteger(legacy, "github_issue_number");
    if (std.mem.startsWith(u8, event_type, "pull.")) return legacyPositiveInteger(legacy, "github_pull_number");
    return false;
}

fn hasGitLabLegacyAlias(event_type: []const u8, root: std.json.ObjectMap) bool {
    const legacy = switch (root.get("legacy") orelse return false) {
        .object => |object| object,
        else => return false,
    };
    if (std.mem.startsWith(u8, event_type, "issue.")) return legacyPositiveInteger(legacy, "gitlab_issue_iid");
    if (std.mem.startsWith(u8, event_type, "pull.")) return legacyPositiveInteger(legacy, "gitlab_merge_request_iid");
    return false;
}

fn legacyPositiveInteger(legacy: std.json.ObjectMap, key: []const u8) bool {
    const value = legacy.get(key) orelse return false;
    return switch (value) {
        .integer => |integer| integer > 0,
        else => false,
    };
}

fn payloadHasAny(payload: std.json.ObjectMap, keys: []const []const u8) bool {
    for (keys) |key| {
        if (payload.get(key) != null) return true;
    }
    return false;
}

fn payloadContainsNonEmptyArray(payload: std.json.ObjectMap, key: []const u8) bool {
    const value = payload.get(key) orelse return false;
    return switch (value) {
        .array => |items| items.items.len != 0,
        else => false,
    };
}

fn roleAtLeast(actual: []const u8, required: []const u8) bool {
    return event_mod.roleAtLeast(actual, required);
}

fn canEditObject(allocator: Allocator, db: *SqliteDb, role: []const u8, actor: []const u8, kind: []const u8, object_id: []const u8, before_event_hash: ?[]const u8) !bool {
    if (roleAtLeast(role, "maintainer")) return true;
    if (!roleAtLeast(role, "contributor")) return false;
    const author = try objectAuthorAtFrontier(allocator, db, kind, object_id, before_event_hash);
    defer if (author) |value| allocator.free(value);
    return author != null and std.mem.eql(u8, author.?, actor);
}

fn canRedactComment(allocator: Allocator, db: *SqliteDb, role: []const u8, actor: []const u8, comment_id: []const u8, before_event_hash: ?[]const u8) !bool {
    if (roleAtLeast(role, "maintainer")) return true;
    if (!roleAtLeast(role, "contributor")) return false;
    const author = try objectAuthorAtFrontier(allocator, db, "comment", comment_id, before_event_hash);
    defer if (author) |value| allocator.free(value);
    return author != null and std.mem.eql(u8, author.?, actor);
}

fn objectAuthorAtFrontier(allocator: Allocator, db: *SqliteDb, kind: []const u8, object_id: []const u8, before_event_hash: ?[]const u8) !?[]u8 {
    const creation_event_type = creationEventTypeForObjectKind(kind) orelse return null;
    var stmt = try db.prepare(
        \\SELECT event_hash, actor_principal
        \\FROM events
        \\WHERE event_type = ?
        \\  AND object_id = ?
        \\  AND domain_status = 'accepted'
        \\ORDER BY event_hash DESC
    );
    defer stmt.deinit();
    try stmt.bindText(1, creation_event_type);
    try stmt.bindText(2, object_id);
    while (try stmt.step()) {
        const creation_hash = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(creation_hash);
        if (!(try eventInAuthFrontier(allocator, creation_hash, before_event_hash))) continue;
        return try stmt.columnTextDup(allocator, 1);
    }
    return null;
}

fn creationEventTypeForObjectKind(kind: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, kind, "issue")) return "issue.opened";
    if (std.mem.eql(u8, kind, "pull")) return "pull.opened";
    if (std.mem.eql(u8, kind, "comment")) return "comment.added";
    return null;
}

pub fn currentRole(allocator: Allocator, db: *SqliteDb, principal: []const u8) !?[]u8 {
    var stmt = try db.prepare("SELECT role FROM acl_roles WHERE principal = ?");
    defer stmt.deinit();
    try stmt.bindText(1, principal);
    if (!(try stmt.step())) return null;
    return try stmt.columnTextDup(allocator, 0);
}

pub fn currentDeviceActive(db: *SqliteDb, principal: []const u8, device: []const u8) !bool {
    var stmt = try db.prepare("SELECT 1 FROM identity_devices WHERE principal = ? AND device = ? AND revoked_event_hash IS NULL");
    defer stmt.deinit();
    try stmt.bindText(1, principal);
    try stmt.bindText(2, device);
    return try stmt.step();
}

pub fn currentDeviceFingerprint(allocator: Allocator, db: *SqliteDb, principal: []const u8, device: []const u8) !?[]u8 {
    var stmt = try db.prepare("SELECT key_fingerprint FROM identity_devices WHERE principal = ? AND device = ? AND revoked_event_hash IS NULL");
    defer stmt.deinit();
    try stmt.bindText(1, principal);
    try stmt.bindText(2, device);
    if (!(try stmt.step())) return null;
    return try stmt.columnTextDup(allocator, 0);
}

fn markDomainAccepted(db: *SqliteDb, event_hash: []const u8) !void {
    var stmt = try db.prepare("UPDATE events SET domain_status = 'accepted', rejection_reason = '' WHERE event_hash = ?");
    defer stmt.deinit();
    try stmt.bindText(1, event_hash);
    try stmt.stepDone();
}

fn markDomainRejected(db: *SqliteDb, event_hash: []const u8, reason: []const u8) !void {
    var stmt = try db.prepare("UPDATE events SET domain_status = 'rejected', rejection_reason = ? WHERE event_hash = ?");
    defer stmt.deinit();
    try stmt.bindText(1, reason);
    try stmt.bindText(2, event_hash);
    try stmt.stepDone();
}

fn applyAclProjection(allocator: Allocator, db: *SqliteDb, event_hash: []const u8, envelope: ValidatedEnvelope, body: []const u8) !?[]const u8 {
    if (!std.mem.startsWith(u8, envelope.event_type, "acl.")) return null;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return "invalid_event_envelope",
    };
    const payload = switch (root.get("payload") orelse return "invalid_event_envelope") {
        .object => |object| object,
        else => return "invalid_event_envelope",
    };
    const principal = event_mod.jsonString(payload.get("principal")) orelse return "invalid_event_envelope";

    if (std.mem.eql(u8, envelope.event_type, "acl.role_granted")) {
        const role = event_mod.jsonString(payload.get("role")) orelse return "invalid_event_envelope";
        if (!event_mod.isKnownRole(role)) return "invalid_role";
        const actor_role = (try aclRoleAtAuthFrontier(allocator, db, envelope.actor_principal, event_hash)) orelse return "unauthorized_principal";
        defer allocator.free(actor_role);
        if (!roleAtLeast(actor_role, role)) return "privilege_escalation";
        try insertAclHistory(db, principal, role, event_hash, envelope.event_type);
        try reconcileAclRole(allocator, db, principal);
        return null;
    }

    if (std.mem.eql(u8, envelope.event_type, "acl.role_revoked")) {
        const role = event_mod.jsonString(payload.get("role")) orelse return "invalid_event_envelope";
        if (!event_mod.isKnownRole(role)) return "invalid_role";
        const existing_role = (try aclRoleAtFrontier(allocator, db, principal, event_hash)) orelse return "role_not_granted";
        defer allocator.free(existing_role);
        if (!std.mem.eql(u8, existing_role, role)) return "role_mismatch";
        if (std.mem.eql(u8, principal, envelope.actor_principal) and std.mem.eql(u8, role, "owner")) {
            const owners = try countOwnersAtFrontier(allocator, db, event_hash);
            if (owners <= 1) return "last_owner";
        }
        try insertAclHistory(db, principal, role, event_hash, envelope.event_type);
        try reconcileAclRole(allocator, db, principal);
        return null;
    }

    if (std.mem.eql(u8, envelope.event_type, "acl.delegation_granted")) {
        const device = event_mod.jsonString(payload.get("device")) orelse return "invalid_event_envelope";
        const capability = event_mod.jsonString(payload.get("capability")) orelse return "invalid_event_envelope";
        const scope = event_mod.jsonString(payload.get("scope")) orelse return "invalid_event_envelope";
        if (!isKnownImportCapability(capability)) return "unknown_capability";
        const signing_key = switch (payload.get("signing_key") orelse return "invalid_event_envelope") {
            .object => |object| object,
            else => return "invalid_event_envelope",
        };
        const public_key = event_mod.jsonString(signing_key.get("public_key")) orelse return "invalid_event_envelope";
        const fingerprint = event_mod.jsonString(signing_key.get("fingerprint")) orelse return "invalid_event_envelope";
        try insertDelegationHistory(db, principal, device, capability, scope, fingerprint, public_key, event_hash, envelope.event_type);
        try reconcileDelegation(allocator, db, principal, device, capability, scope);
        return null;
    }

    if (std.mem.eql(u8, envelope.event_type, "acl.delegation_revoked")) {
        const device = event_mod.jsonString(payload.get("device")) orelse return "invalid_event_envelope";
        const capability = event_mod.jsonString(payload.get("capability")) orelse return "invalid_event_envelope";
        const scope = event_mod.jsonString(payload.get("scope")) orelse return "invalid_event_envelope";
        if (!isKnownImportCapability(capability)) return "unknown_capability";
        if (!(try delegationActiveAtFrontier(allocator, db, principal, device, capability, scope, event_hash))) return "delegation_not_active";
        try insertDelegationHistory(db, principal, device, capability, scope, "", "", event_hash, envelope.event_type);
        try reconcileDelegation(allocator, db, principal, device, capability, scope);
        return null;
    }

    return "unknown_event_type";
}

fn applyIdentityProjection(allocator: Allocator, db: *SqliteDb, event_hash: []const u8, envelope: ValidatedEnvelope, body: []const u8) !?[]const u8 {
    if (!std.mem.startsWith(u8, envelope.event_type, "identity.")) return null;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return "invalid_event_envelope",
    };
    const payload = switch (root.get("payload") orelse return "invalid_event_envelope") {
        .object => |object| object,
        else => return "invalid_event_envelope",
    };
    const principal = event_mod.jsonString(payload.get("principal")) orelse return "invalid_event_envelope";
    const device = event_mod.jsonString(payload.get("device")) orelse return "invalid_event_envelope";

    if (std.mem.eql(u8, envelope.event_type, "identity.device_added")) {
        const signing_key = switch (payload.get("signing_key") orelse return "invalid_event_envelope") {
            .object => |object| object,
            else => return "invalid_event_envelope",
        };
        const public_key = event_mod.jsonString(signing_key.get("public_key")) orelse return "invalid_event_envelope";
        const fingerprint = event_mod.jsonString(signing_key.get("fingerprint")) orelse return "invalid_event_envelope";
        try insertIdentityHistory(db, principal, device, fingerprint, public_key, event_hash, envelope.event_type);
        try reconcileIdentityDevice(allocator, db, principal, device);
        return null;
    }

    if (std.mem.eql(u8, envelope.event_type, "identity.device_revoked")) {
        if (!(try identityDeviceActiveAtFrontier(allocator, db, principal, device, event_hash))) return "device_not_active";
        try insertIdentityHistory(db, principal, device, "", "", event_hash, envelope.event_type);
        try reconcileIdentityDevice(allocator, db, principal, device);
        return null;
    }

    return "unknown_event_type";
}

fn upsertAclRole(db: *SqliteDb, principal: []const u8, role: []const u8, grant_event_hash: []const u8) !void {
    var stmt = try db.prepare(
        \\INSERT INTO acl_roles(principal, role, grant_event_hash)
        \\VALUES (?, ?, ?)
        \\ON CONFLICT(principal) DO UPDATE SET role = excluded.role, grant_event_hash = excluded.grant_event_hash
    );
    defer stmt.deinit();
    try stmt.bindText(1, principal);
    try stmt.bindText(2, role);
    try stmt.bindText(3, grant_event_hash);
    try stmt.stepDone();
}

fn deleteAclRole(db: *SqliteDb, principal: []const u8) !void {
    var stmt = try db.prepare("DELETE FROM acl_roles WHERE principal = ?");
    defer stmt.deinit();
    try stmt.bindText(1, principal);
    try stmt.stepDone();
}

fn insertAclHistory(db: *SqliteDb, principal: []const u8, role: []const u8, event_hash: []const u8, event_type: []const u8) !void {
    var stmt = try db.prepare("INSERT OR IGNORE INTO acl_role_events(principal, role, event_hash, event_type) VALUES (?, ?, ?, ?)");
    defer stmt.deinit();
    try stmt.bindText(1, principal);
    try stmt.bindText(2, role);
    try stmt.bindText(3, event_hash);
    try stmt.bindText(4, event_type);
    try stmt.stepDone();
}

const AclRoleEvent = struct {
    allocator: Allocator,
    role: []u8,
    event_hash: []u8,
    event_type: []u8,

    fn deinit(self: *AclRoleEvent) void {
        self.allocator.free(self.role);
        self.allocator.free(self.event_hash);
        self.allocator.free(self.event_type);
    }
};

fn reconcileAclRole(allocator: Allocator, db: *SqliteDb, principal: []const u8) !void {
    var events = try loadAclRoleEvents(allocator, db, principal, null, .causal_frontier);
    defer freeAclRoleEvents(allocator, &events);

    const winner_index = try winningAclRoleEventIndex(allocator, events.items);
    if (winner_index) |index| {
        const winner = events.items[index];
        if (std.mem.eql(u8, winner.event_type, "acl.role_granted")) {
            try upsertAclRole(db, principal, winner.role, winner.event_hash);
            return;
        }
    }
    try deleteAclRole(db, principal);
}

fn aclRoleAtFrontier(allocator: Allocator, db: *SqliteDb, principal: []const u8, event_hash: []const u8) !?[]u8 {
    var events = try loadAclRoleEvents(allocator, db, principal, event_hash, .causal_frontier);
    defer freeAclRoleEvents(allocator, &events);

    const winner_index = try winningAclRoleEventIndex(allocator, events.items) orelse return null;
    const winner = events.items[winner_index];
    if (!std.mem.eql(u8, winner.event_type, "acl.role_granted")) return null;
    return try allocator.dupe(u8, winner.role);
}

fn aclRoleAtAuthFrontier(allocator: Allocator, db: *SqliteDb, principal: []const u8, event_hash: []const u8) !?[]u8 {
    var events = try loadAclRoleEvents(allocator, db, principal, event_hash, .known_revocations);
    defer freeAclRoleEvents(allocator, &events);

    const winner_index = try winningAclRoleEventIndex(allocator, events.items) orelse return null;
    const winner = events.items[winner_index];
    if (!std.mem.eql(u8, winner.event_type, "acl.role_granted")) return null;
    return try allocator.dupe(u8, winner.role);
}

fn loadAclRoleEvents(
    allocator: Allocator,
    db: *SqliteDb,
    principal: []const u8,
    before_event_hash: ?[]const u8,
    visibility: AuthEventVisibility,
) !std.ArrayList(AclRoleEvent) {
    var stmt = try db.prepare(
        \\SELECT role, event_hash, event_type
        \\FROM acl_role_events
        \\WHERE principal = ?
        \\ORDER BY event_hash
    );
    defer stmt.deinit();
    try stmt.bindText(1, principal);

    var events: std.ArrayList(AclRoleEvent) = .empty;
    errdefer freeAclRoleEvents(allocator, &events);

    while (try stmt.step()) {
        const event_hash = try stmt.columnTextDup(allocator, 1);
        var keep_event_hash = false;
        defer if (!keep_event_hash) allocator.free(event_hash);
        var event_type: ?[]u8 = try stmt.columnTextDup(allocator, 2);
        errdefer if (event_type) |value| allocator.free(value);

        if (!(try authEventVisible(allocator, event_hash, before_event_hash, event_type.?, "acl.role_revoked", visibility))) {
            allocator.free(event_type.?);
            event_type = null;
            continue;
        }

        var role_value: ?[]u8 = try stmt.columnTextDup(allocator, 0);
        errdefer if (role_value) |value| allocator.free(value);

        var event = AclRoleEvent{
            .allocator = allocator,
            .role = role_value.?,
            .event_hash = event_hash,
            .event_type = event_type.?,
        };
        role_value = null;
        event_type = null;
        keep_event_hash = true;
        errdefer event.deinit();
        try events.append(allocator, event);
    }

    return events;
}

fn freeAclRoleEvents(allocator: Allocator, events: *std.ArrayList(AclRoleEvent)) void {
    for (events.items) |*event| event.deinit();
    events.deinit(allocator);
}

fn winningAclRoleEventIndex(allocator: Allocator, events: []const AclRoleEvent) !?usize {
    var winner: ?usize = null;
    for (events, 0..) |event, index| {
        if (!std.mem.eql(u8, event.event_type, "acl.role_granted")) continue;
        if (try aclRoleGrantDisabledByRevocation(allocator, events, event.event_hash)) continue;
        if (winner == null or try eventWins(allocator, event.event_hash, events[winner.?].event_hash)) {
            winner = index;
        }
    }
    return winner;
}

fn aclRoleGrantDisabledByRevocation(allocator: Allocator, events: []const AclRoleEvent, grant_event_hash: []const u8) !bool {
    for (events) |event| {
        if (!std.mem.eql(u8, event.event_type, "acl.role_revoked")) continue;
        if (try authRevocationDisablesGrant(allocator, event.event_hash, grant_event_hash)) return true;
    }
    return false;
}

pub fn countCurrentOwners(db: *SqliteDb) !usize {
    var stmt = try db.prepare("SELECT COUNT(*) FROM acl_roles WHERE role = 'owner'");
    defer stmt.deinit();
    if (!(try stmt.step())) return 0;
    const count = stmt.columnInt64(0);
    return if (count <= 0) 0 else @as(usize, @intCast(count));
}

fn countOwnersAtFrontier(allocator: Allocator, db: *SqliteDb, event_hash: []const u8) !usize {
    var stmt = try db.prepare("SELECT DISTINCT principal FROM acl_role_events");
    defer stmt.deinit();

    var count: usize = 0;
    while (try stmt.step()) {
        const principal = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(principal);
        const role = try aclRoleAtFrontier(allocator, db, principal, event_hash);
        defer if (role) |value| allocator.free(value);
        if (role != null and std.mem.eql(u8, role.?, "owner")) count += 1;
    }
    return count;
}

fn upsertDelegation(
    db: *SqliteDb,
    principal: []const u8,
    device: []const u8,
    capability: []const u8,
    scope: []const u8,
    fingerprint: []const u8,
    public_key: []const u8,
    grant_event_hash: []const u8,
) !void {
    var stmt = try db.prepare(
        \\INSERT INTO acl_delegations(principal, device, capability, scope, key_fingerprint, public_key, grant_event_hash)
        \\VALUES (?, ?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(principal, device, capability, scope, key_fingerprint) DO UPDATE SET
        \\  public_key = excluded.public_key,
        \\  grant_event_hash = excluded.grant_event_hash
    );
    defer stmt.deinit();
    try stmt.bindText(1, principal);
    try stmt.bindText(2, device);
    try stmt.bindText(3, capability);
    try stmt.bindText(4, scope);
    try stmt.bindText(5, fingerprint);
    try stmt.bindText(6, public_key);
    try stmt.bindText(7, grant_event_hash);
    try stmt.stepDone();
}

fn replaceDelegation(
    db: *SqliteDb,
    principal: []const u8,
    device: []const u8,
    capability: []const u8,
    scope: []const u8,
    fingerprint: []const u8,
    public_key: []const u8,
    grant_event_hash: []const u8,
) !void {
    try deleteDelegation(db, principal, device, capability, scope);
    try upsertDelegation(db, principal, device, capability, scope, fingerprint, public_key, grant_event_hash);
}

fn deleteDelegation(db: *SqliteDb, principal: []const u8, device: []const u8, capability: []const u8, scope: []const u8) !void {
    var stmt = try db.prepare("DELETE FROM acl_delegations WHERE principal = ? AND device = ? AND capability = ? AND scope = ?");
    defer stmt.deinit();
    try stmt.bindText(1, principal);
    try stmt.bindText(2, device);
    try stmt.bindText(3, capability);
    try stmt.bindText(4, scope);
    try stmt.stepDone();
}

fn insertDelegationHistory(
    db: *SqliteDb,
    principal: []const u8,
    device: []const u8,
    capability: []const u8,
    scope: []const u8,
    fingerprint: []const u8,
    public_key: []const u8,
    event_hash: []const u8,
    event_type: []const u8,
) !void {
    var stmt = try db.prepare(
        \\INSERT OR IGNORE INTO acl_delegation_events(principal, device, capability, scope, key_fingerprint, public_key, event_hash, event_type)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    );
    defer stmt.deinit();
    try stmt.bindText(1, principal);
    try stmt.bindText(2, device);
    try stmt.bindText(3, capability);
    try stmt.bindText(4, scope);
    try stmt.bindText(5, fingerprint);
    try stmt.bindText(6, public_key);
    try stmt.bindText(7, event_hash);
    try stmt.bindText(8, event_type);
    try stmt.stepDone();
}

const DelegationEvent = struct {
    allocator: Allocator,
    event_hash: []u8,
    event_type: []u8,
    key_fingerprint: []u8,
    public_key: []u8,

    fn deinit(self: *DelegationEvent) void {
        self.allocator.free(self.event_hash);
        self.allocator.free(self.event_type);
        self.allocator.free(self.key_fingerprint);
        self.allocator.free(self.public_key);
    }
};

fn reconcileDelegation(allocator: Allocator, db: *SqliteDb, principal: []const u8, device: []const u8, capability: []const u8, scope: []const u8) !void {
    var events = try loadDelegationEvents(allocator, db, principal, device, capability, scope, null, .causal_frontier);
    defer freeDelegationEvents(allocator, &events);

    if (try activeDelegationGrantIndex(allocator, events.items)) |active_index| {
        const active = events.items[active_index];
        try replaceDelegation(db, principal, device, capability, scope, active.key_fingerprint, active.public_key, active.event_hash);
        return;
    }

    try deleteDelegation(db, principal, device, capability, scope);
}

fn delegationActiveAtFrontier(allocator: Allocator, db: *SqliteDb, principal: []const u8, device: []const u8, capability: []const u8, scope: []const u8, event_hash: []const u8) !bool {
    var events = try loadDelegationEvents(allocator, db, principal, device, capability, scope, event_hash, .causal_frontier);
    defer freeDelegationEvents(allocator, &events);
    return (try activeDelegationGrantIndex(allocator, events.items)) != null;
}

fn delegationFingerprintAtAuthFrontier(
    allocator: Allocator,
    db: *SqliteDb,
    principal: []const u8,
    device: []const u8,
    capability: []const u8,
    before_event_hash: []const u8,
) !?[]u8 {
    const scope: []const u8 = if (std.mem.eql(u8, capability, "gitlab.import")) "gitlab:*" else "github:*";
    var events = try loadDelegationEvents(allocator, db, principal, device, capability, scope, before_event_hash, .known_revocations);
    defer freeDelegationEvents(allocator, &events);
    const active_index = (try activeDelegationGrantIndex(allocator, events.items)) orelse return null;
    return try allocator.dupe(u8, events.items[active_index].key_fingerprint);
}

fn importDelegationFingerprintAtAuthFrontier(
    allocator: Allocator,
    db: *SqliteDb,
    principal: []const u8,
    device: []const u8,
    before_event_hash: []const u8,
) !?[]u8 {
    if (try delegationFingerprintAtAuthFrontier(allocator, db, principal, device, "github.import", before_event_hash)) |value| return value;
    return try delegationFingerprintAtAuthFrontier(allocator, db, principal, device, "gitlab.import", before_event_hash);
}

fn isKnownImportCapability(capability: []const u8) bool {
    return std.mem.eql(u8, capability, "github.import") or std.mem.eql(u8, capability, "gitlab.import");
}

fn loadDelegationEvents(
    allocator: Allocator,
    db: *SqliteDb,
    principal: []const u8,
    device: []const u8,
    capability: []const u8,
    scope: []const u8,
    before_event_hash: ?[]const u8,
    visibility: AuthEventVisibility,
) !std.ArrayList(DelegationEvent) {
    var stmt = try db.prepare(
        \\SELECT event_hash, event_type, key_fingerprint, public_key
        \\FROM acl_delegation_events
        \\WHERE principal = ? AND device = ? AND capability = ? AND scope = ?
        \\ORDER BY event_hash
    );
    defer stmt.deinit();
    try stmt.bindText(1, principal);
    try stmt.bindText(2, device);
    try stmt.bindText(3, capability);
    try stmt.bindText(4, scope);

    var events: std.ArrayList(DelegationEvent) = .empty;
    errdefer freeDelegationEvents(allocator, &events);

    while (try stmt.step()) {
        const event_hash = try stmt.columnTextDup(allocator, 0);
        var keep_event_hash = false;
        defer if (!keep_event_hash) allocator.free(event_hash);
        var event_type: ?[]u8 = try stmt.columnTextDup(allocator, 1);
        errdefer if (event_type) |value| allocator.free(value);

        if (!(try authEventVisible(allocator, event_hash, before_event_hash, event_type.?, "acl.delegation_revoked", visibility))) {
            allocator.free(event_type.?);
            event_type = null;
            continue;
        }

        var key_fingerprint: ?[]u8 = try stmt.columnTextDup(allocator, 2);
        errdefer if (key_fingerprint) |value| allocator.free(value);
        var public_key: ?[]u8 = try stmt.columnTextDup(allocator, 3);
        errdefer if (public_key) |value| allocator.free(value);

        var event = DelegationEvent{
            .allocator = allocator,
            .event_hash = event_hash,
            .event_type = event_type.?,
            .key_fingerprint = key_fingerprint.?,
            .public_key = public_key.?,
        };
        event_type = null;
        key_fingerprint = null;
        public_key = null;
        keep_event_hash = true;
        errdefer event.deinit();
        try events.append(allocator, event);
    }

    return events;
}

fn freeDelegationEvents(allocator: Allocator, events: *std.ArrayList(DelegationEvent)) void {
    for (events.items) |*event| event.deinit();
    events.deinit(allocator);
}

fn activeDelegationGrantIndex(allocator: Allocator, events: []const DelegationEvent) !?usize {
    var winner: ?usize = null;
    for (events, 0..) |event, index| {
        if (!std.mem.eql(u8, event.event_type, "acl.delegation_granted")) continue;
        if (try delegationGrantDisabledByRevocation(allocator, events, event.event_hash)) continue;
        if (winner == null or try eventWins(allocator, event.event_hash, events[winner.?].event_hash)) {
            winner = index;
        }
    }
    return winner;
}

fn delegationGrantDisabledByRevocation(allocator: Allocator, events: []const DelegationEvent, grant_event_hash: []const u8) !bool {
    for (events) |event| {
        if (!std.mem.eql(u8, event.event_type, "acl.delegation_revoked")) continue;
        if (try delegationRevocationDisablesGrant(allocator, event.event_hash, grant_event_hash)) return true;
    }
    return false;
}

fn delegationRevocationDisablesGrant(allocator: Allocator, revoke_event_hash: []const u8, grant_event_hash: []const u8) !bool {
    return authRevocationDisablesGrant(allocator, revoke_event_hash, grant_event_hash);
}

fn authRevocationDisablesGrant(allocator: Allocator, revoke_event_hash: []const u8, grant_event_hash: []const u8) !bool {
    if (revoke_event_hash.len == 0) return false;
    if (std.mem.eql(u8, revoke_event_hash, grant_event_hash)) return true;
    if (grant_event_hash.len != 0 and try git.isAncestor(allocator, revoke_event_hash, grant_event_hash)) return false;
    return true;
}

fn upsertIdentityDevice(
    db: *SqliteDb,
    principal: []const u8,
    device: []const u8,
    fingerprint: []const u8,
    public_key: []const u8,
    added_event_hash: []const u8,
    revoked_event_hash: ?[]const u8,
) !void {
    var stmt = try db.prepare(
        \\INSERT INTO identity_devices(principal, device, key_fingerprint, public_key, added_event_hash, revoked_event_hash)
        \\VALUES (?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(principal, device, key_fingerprint) DO UPDATE SET
        \\  public_key = excluded.public_key,
        \\  added_event_hash = excluded.added_event_hash,
        \\  revoked_event_hash = excluded.revoked_event_hash
    );
    defer stmt.deinit();
    try stmt.bindText(1, principal);
    try stmt.bindText(2, device);
    try stmt.bindText(3, fingerprint);
    try stmt.bindText(4, public_key);
    try stmt.bindText(5, added_event_hash);
    if (revoked_event_hash) |hash| {
        try stmt.bindText(6, hash);
    } else {
        try stmt.bindNull(6);
    }
    try stmt.stepDone();
}

fn replaceIdentityDevice(
    db: *SqliteDb,
    principal: []const u8,
    device: []const u8,
    fingerprint: []const u8,
    public_key: []const u8,
    added_event_hash: []const u8,
    revoked_event_hash: ?[]const u8,
) !void {
    var delete = try db.prepare("DELETE FROM identity_devices WHERE principal = ? AND device = ?");
    defer delete.deinit();
    try delete.bindText(1, principal);
    try delete.bindText(2, device);
    try delete.stepDone();
    try upsertIdentityDevice(db, principal, device, fingerprint, public_key, added_event_hash, revoked_event_hash);
}

fn deleteIdentityDevice(db: *SqliteDb, principal: []const u8, device: []const u8) !void {
    var stmt = try db.prepare("DELETE FROM identity_devices WHERE principal = ? AND device = ?");
    defer stmt.deinit();
    try stmt.bindText(1, principal);
    try stmt.bindText(2, device);
    try stmt.stepDone();
}

fn revokeIdentityDevice(db: *SqliteDb, principal: []const u8, device: []const u8, revoked_event_hash: []const u8) !void {
    var stmt = try db.prepare("UPDATE identity_devices SET revoked_event_hash = ? WHERE principal = ? AND device = ? AND revoked_event_hash IS NULL");
    defer stmt.deinit();
    try stmt.bindText(1, revoked_event_hash);
    try stmt.bindText(2, principal);
    try stmt.bindText(3, device);
    try stmt.stepDone();
}

const IdentityDeviceEvent = struct {
    allocator: Allocator,
    event_hash: []u8,
    event_type: []u8,
    key_fingerprint: []u8,
    public_key: []u8,

    fn deinit(self: *IdentityDeviceEvent) void {
        self.allocator.free(self.event_hash);
        self.allocator.free(self.event_type);
        self.allocator.free(self.key_fingerprint);
        self.allocator.free(self.public_key);
    }
};

fn reconcileIdentityDevice(allocator: Allocator, db: *SqliteDb, principal: []const u8, device: []const u8) !void {
    var events = try loadIdentityDeviceEvents(allocator, db, principal, device, null, .causal_frontier);
    defer freeIdentityDeviceEvents(allocator, &events);

    if (try activeIdentityAddIndex(allocator, events.items)) |active_index| {
        const active = events.items[active_index];
        try replaceIdentityDevice(db, principal, device, active.key_fingerprint, active.public_key, active.event_hash, null);
        return;
    }

    if (try bestIdentityAddIndex(allocator, events.items)) |add_index| {
        if (try bestIdentityRevocationIndex(allocator, events.items, events.items[add_index].event_hash)) |revoke_index| {
            const add = events.items[add_index];
            const revoke = events.items[revoke_index];
            try replaceIdentityDevice(db, principal, device, add.key_fingerprint, add.public_key, add.event_hash, revoke.event_hash);
            return;
        }
    }

    try deleteIdentityDevice(db, principal, device);
}

fn identityDeviceActiveAtFrontier(allocator: Allocator, db: *SqliteDb, principal: []const u8, device: []const u8, event_hash: []const u8) !bool {
    var events = try loadIdentityDeviceEvents(allocator, db, principal, device, event_hash, .causal_frontier);
    defer freeIdentityDeviceEvents(allocator, &events);
    return (try activeIdentityAddIndex(allocator, events.items)) != null;
}

fn identityDeviceFingerprintAtFrontier(allocator: Allocator, db: *SqliteDb, principal: []const u8, device: []const u8, event_hash: []const u8) !?[]u8 {
    var events = try loadIdentityDeviceEvents(allocator, db, principal, device, event_hash, .causal_frontier);
    defer freeIdentityDeviceEvents(allocator, &events);
    const active_index = (try activeIdentityAddIndex(allocator, events.items)) orelse return null;
    return try allocator.dupe(u8, events.items[active_index].key_fingerprint);
}

fn identityDeviceFingerprintAtAuthFrontier(allocator: Allocator, db: *SqliteDb, principal: []const u8, device: []const u8, event_hash: []const u8) !?[]u8 {
    var events = try loadIdentityDeviceEvents(allocator, db, principal, device, event_hash, .known_revocations);
    defer freeIdentityDeviceEvents(allocator, &events);
    const active_index = (try activeIdentityAddIndex(allocator, events.items)) orelse return null;
    return try allocator.dupe(u8, events.items[active_index].key_fingerprint);
}

fn loadIdentityDeviceEvents(
    allocator: Allocator,
    db: *SqliteDb,
    principal: []const u8,
    device: []const u8,
    before_event_hash: ?[]const u8,
    visibility: AuthEventVisibility,
) !std.ArrayList(IdentityDeviceEvent) {
    var stmt = try db.prepare(
        \\SELECT event_hash, event_type, key_fingerprint, public_key
        \\FROM identity_device_events
        \\WHERE principal = ? AND device = ?
        \\ORDER BY event_hash
    );
    defer stmt.deinit();
    try stmt.bindText(1, principal);
    try stmt.bindText(2, device);

    var events: std.ArrayList(IdentityDeviceEvent) = .empty;
    errdefer freeIdentityDeviceEvents(allocator, &events);

    while (try stmt.step()) {
        const event_hash = try stmt.columnTextDup(allocator, 0);
        var keep_event_hash = false;
        defer if (!keep_event_hash) allocator.free(event_hash);
        var event_type: ?[]u8 = try stmt.columnTextDup(allocator, 1);
        errdefer if (event_type) |value| allocator.free(value);

        if (!(try authEventVisible(allocator, event_hash, before_event_hash, event_type.?, "identity.device_revoked", visibility))) {
            allocator.free(event_type.?);
            event_type = null;
            continue;
        }

        var key_fingerprint: ?[]u8 = try stmt.columnTextDup(allocator, 2);
        errdefer if (key_fingerprint) |value| allocator.free(value);
        var public_key: ?[]u8 = try stmt.columnTextDup(allocator, 3);
        errdefer if (public_key) |value| allocator.free(value);

        var event = IdentityDeviceEvent{
            .allocator = allocator,
            .event_hash = event_hash,
            .event_type = event_type.?,
            .key_fingerprint = key_fingerprint.?,
            .public_key = public_key.?,
        };
        event_type = null;
        key_fingerprint = null;
        public_key = null;
        keep_event_hash = true;
        errdefer event.deinit();
        try events.append(allocator, event);
    }

    return events;
}

fn freeIdentityDeviceEvents(allocator: Allocator, events: *std.ArrayList(IdentityDeviceEvent)) void {
    for (events.items) |*event| event.deinit();
    events.deinit(allocator);
}

fn activeIdentityAddIndex(allocator: Allocator, events: []const IdentityDeviceEvent) !?usize {
    var winner: ?usize = null;
    for (events, 0..) |event, index| {
        if (!std.mem.eql(u8, event.event_type, "identity.device_added")) continue;
        if (try identityAddDisabledByRevocation(allocator, events, event.event_hash)) continue;
        if (winner == null or try eventWins(allocator, event.event_hash, events[winner.?].event_hash)) {
            winner = index;
        }
    }
    return winner;
}

fn bestIdentityAddIndex(allocator: Allocator, events: []const IdentityDeviceEvent) !?usize {
    var winner: ?usize = null;
    for (events, 0..) |event, index| {
        if (!std.mem.eql(u8, event.event_type, "identity.device_added")) continue;
        if (winner == null or try eventWins(allocator, event.event_hash, events[winner.?].event_hash)) {
            winner = index;
        }
    }
    return winner;
}

fn bestIdentityRevocationIndex(allocator: Allocator, events: []const IdentityDeviceEvent, add_event_hash: []const u8) !?usize {
    var winner: ?usize = null;
    for (events, 0..) |event, index| {
        if (!std.mem.eql(u8, event.event_type, "identity.device_revoked")) continue;
        if (!(try identityRevocationDisablesAdd(allocator, event.event_hash, add_event_hash))) continue;
        if (winner == null or try eventWins(allocator, event.event_hash, events[winner.?].event_hash)) {
            winner = index;
        }
    }
    return winner;
}

fn identityAddDisabledByRevocation(allocator: Allocator, events: []const IdentityDeviceEvent, add_event_hash: []const u8) !bool {
    for (events) |event| {
        if (!std.mem.eql(u8, event.event_type, "identity.device_revoked")) continue;
        if (try identityRevocationDisablesAdd(allocator, event.event_hash, add_event_hash)) return true;
    }
    return false;
}

fn identityRevocationDisablesAdd(allocator: Allocator, revoke_event_hash: []const u8, add_event_hash: []const u8) !bool {
    return authRevocationDisablesGrant(allocator, revoke_event_hash, add_event_hash);
}

fn insertIdentityHistory(
    db: *SqliteDb,
    principal: []const u8,
    device: []const u8,
    fingerprint: []const u8,
    public_key: []const u8,
    event_hash: []const u8,
    event_type: []const u8,
) !void {
    var stmt = try db.prepare("INSERT OR IGNORE INTO identity_device_events(principal, device, key_fingerprint, public_key, event_hash, event_type) VALUES (?, ?, ?, ?, ?, ?)");
    defer stmt.deinit();
    try stmt.bindText(1, principal);
    try stmt.bindText(2, device);
    try stmt.bindText(3, fingerprint);
    try stmt.bindText(4, public_key);
    try stmt.bindText(5, event_hash);
    try stmt.bindText(6, event_type);
    try stmt.stepDone();
}

pub fn insertIndexedEvent(
    allocator: Allocator,
    stmt: *SqliteStmt,
    ref: []const u8,
    commit: []const u8,
    tree: []const u8,
    subject: []const u8,
    body: []const u8,
    empty_tree: bool,
) !void {
    const summary = parseEventSummary(allocator, body);
    defer if (summary) |parsed| parsed.deinit();

    try stmt.reset();
    try stmt.bindText(1, ref);
    try stmt.bindText(2, commit);
    try stmt.bindText(3, commit);
    try stmt.bindText(4, tree);
    try stmt.bindText(5, subject);
    try stmt.bindText(6, body);
    try stmt.bindInt(7, if (empty_tree) 1 else 0);
    if (summary) |parsed| {
        try stmt.bindInt(8, 1);
        try stmt.bindText(9, parsed.event_type);
        try stmt.bindText(10, parsed.object_kind);
        try stmt.bindText(11, parsed.object_id);
        try stmt.bindText(12, parsed.actor_principal);
        try stmt.bindText(13, parsed.actor_device);
        if (parsed.seq) |seq| {
            try stmt.bindInt64(14, seq);
        } else try stmt.bindNull(14);
        try stmt.bindText(15, parsed.occurred_at);
        try stmt.bindText(16, "pending");
        try stmt.bindText(17, "");
    } else {
        try stmt.bindInt(8, 0);
        try stmt.bindText(9, "");
        try stmt.bindText(10, "");
        try stmt.bindText(11, "");
        try stmt.bindText(12, "");
        try stmt.bindText(13, "");
        try stmt.bindNull(14);
        try stmt.bindText(15, "");
        try stmt.bindText(16, "structural_invalid");
        try stmt.bindText(17, "invalid_event_envelope");
    }
    try stmt.stepDone();
}

fn testEnvelopeForObjectEventType(allocator: Allocator, event_type: []const u8, object_kind: []const u8, object_id: []const u8) !ValidatedEnvelope {
    return ValidatedEnvelope{
        .allocator = allocator,
        .repo_id = try allocator.dupe(u8, "repo"),
        .event_uuid = try allocator.dupe(u8, "018f0000-0000-7000-8000-000000000000"),
        .event_type = try allocator.dupe(u8, event_type),
        .object_kind = try allocator.dupe(u8, object_kind),
        .object_id = try allocator.dupe(u8, object_id),
        .idempotency_key = try allocator.dupe(u8, "idem"),
        .actor_principal = try allocator.dupe(u8, "alice"),
        .actor_device = try allocator.dupe(u8, "laptop"),
        .seq = 1,
        .occurred_at = try allocator.dupe(u8, "2026-05-16T00:00:00Z"),
    };
}

fn testEnvelopeForEventType(allocator: Allocator, event_type: []const u8) !ValidatedEnvelope {
    return testEnvelopeForObjectEventType(allocator, event_type, "pull", "pull-1");
}

test "open access still requires actor device binding" {
    const allocator = std.testing.allocator;
    var db = try SqliteDb.open(allocator, ":memory:", sqlite_db.sqlite.SQLITE_OPEN_READWRITE | sqlite_db.sqlite.SQLITE_OPEN_CREATE, true);
    defer db.deinit();
    try index_schema.createIndexSchema(&db);
    try db.exec("INSERT INTO meta(key, value) VALUES ('access_mode', 'open')");

    var envelope = try testEnvelopeForObjectEventType(allocator, "issue.opened", "issue", "018f0000-0000-7000-8000-000000000100");
    defer envelope.deinit();

    const rejection = try authorizationRejection(allocator, &db, "fake-event-hash", envelope, "{\"payload\":{\"title\":\"Smoke\"}}");
    try std.testing.expect(rejection != null);
    try std.testing.expectEqualStrings("unauthorized_device", rejection.?);
}

test "role authorization rejects provider legacy aliases on work item events" {
    const allocator = std.testing.allocator;
    var db = try SqliteDb.open(allocator, ":memory:", sqlite_db.sqlite.SQLITE_OPEN_READWRITE | sqlite_db.sqlite.SQLITE_OPEN_CREATE, true);
    defer db.deinit();
    try index_schema.createIndexSchema(&db);
    try upsertMeta(&db, "access_mode", "open");

    const issue_body =
        \\{
        \\  "$schema": "urn:gitomi:event:v1",
        \\  "repo_id": "018f0000-0000-7000-8000-000000000001",
        \\  "event_uuid": "018f0000-0000-7000-8000-000000000103",
        \\  "event_type": "issue.opened",
        \\  "object": {"kind": "issue", "id": "018f0000-0000-7000-8000-000000000100"},
        \\  "idempotency_key": "018f0000-0000-7000-8000-000000000104",
        \\  "actor": {"principal": "alice", "device": "laptop"},
        \\  "seq": 1,
        \\  "occurred_at": "2026-05-16T00:00:01Z",
        \\  "parent_hashes": {"log": "", "anchor": "", "causal": [], "related": []},
        \\  "legacy": {"gitlab_issue_iid": 4242},
        \\  "payload": {"title": "Forged", "body": "", "state": "open"}
        \\}
    ;
    var issue_envelope = try parseValidatedEnvelope(allocator, issue_body);
    defer issue_envelope.deinit();
    try std.testing.expectEqualStrings("unauthorized_legacy_alias", (try authorizationRejection(allocator, &db, null, issue_envelope, issue_body)).?);

    const issue_update_body =
        \\{
        \\  "$schema": "urn:gitomi:event:v1",
        \\  "repo_id": "018f0000-0000-7000-8000-000000000001",
        \\  "event_uuid": "018f0000-0000-7000-8000-000000000107",
        \\  "event_type": "issue.updated",
        \\  "object": {"kind": "issue", "id": "018f0000-0000-7000-8000-000000000100"},
        \\  "idempotency_key": "018f0000-0000-7000-8000-000000000108",
        \\  "actor": {"principal": "alice", "device": "laptop"},
        \\  "seq": 2,
        \\  "occurred_at": "2026-05-16T00:00:02Z",
        \\  "parent_hashes": {"log": "", "anchor": "", "causal": [], "related": []},
        \\  "legacy": {"github_issue_number": 31337},
        \\  "payload": {}
        \\}
    ;
    var issue_update_envelope = try parseValidatedEnvelope(allocator, issue_update_body);
    defer issue_update_envelope.deinit();
    try std.testing.expectEqualStrings("unauthorized_legacy_alias", (try authorizationRejection(allocator, &db, null, issue_update_envelope, issue_update_body)).?);

    const pull_body =
        \\{
        \\  "$schema": "urn:gitomi:event:v1",
        \\  "repo_id": "018f0000-0000-7000-8000-000000000001",
        \\  "event_uuid": "018f0000-0000-7000-8000-000000000109",
        \\  "event_type": "pull.opened",
        \\  "object": {"kind": "pull", "id": "018f0000-0000-7000-8000-000000000101"},
        \\  "idempotency_key": "018f0000-0000-7000-8000-00000000010a",
        \\  "actor": {"principal": "alice", "device": "laptop"},
        \\  "seq": 3,
        \\  "occurred_at": "2026-05-16T00:00:03Z",
        \\  "parent_hashes": {"log": "", "anchor": "", "causal": [], "related": []},
        \\  "legacy": {"gitlab_merge_request_iid": 77},
        \\  "payload": {"title": "Forged", "body": "", "state": "open", "base_ref": "main", "head_ref": "feature"}
        \\}
    ;
    var pull_envelope = try parseValidatedEnvelope(allocator, pull_body);
    defer pull_envelope.deinit();
    try std.testing.expectEqualStrings("unauthorized_legacy_alias", (try authorizationRejection(allocator, &db, null, pull_envelope, pull_body)).?);

    const pull_update_body =
        \\{
        \\  "$schema": "urn:gitomi:event:v1",
        \\  "repo_id": "018f0000-0000-7000-8000-000000000001",
        \\  "event_uuid": "018f0000-0000-7000-8000-00000000010b",
        \\  "event_type": "pull.updated",
        \\  "object": {"kind": "pull", "id": "018f0000-0000-7000-8000-000000000101"},
        \\  "idempotency_key": "018f0000-0000-7000-8000-00000000010c",
        \\  "actor": {"principal": "alice", "device": "laptop"},
        \\  "seq": 4,
        \\  "occurred_at": "2026-05-16T00:00:04Z",
        \\  "parent_hashes": {"log": "", "anchor": "", "causal": [], "related": []},
        \\  "legacy": {"github_pull_number": 31338},
        \\  "payload": {}
        \\}
    ;
    var pull_update_envelope = try parseValidatedEnvelope(allocator, pull_update_body);
    defer pull_update_envelope.deinit();
    try std.testing.expectEqualStrings("unauthorized_legacy_alias", (try authorizationRejection(allocator, &db, null, pull_update_envelope, pull_update_body)).?);
}

test "role authorization rejects source identity metadata without import delegation" {
    const allocator = std.testing.allocator;
    var db = try SqliteDb.open(allocator, ":memory:", sqlite_db.sqlite.SQLITE_OPEN_READWRITE | sqlite_db.sqlite.SQLITE_OPEN_CREATE, true);
    defer db.deinit();
    try index_schema.createIndexSchema(&db);
    try upsertMeta(&db, "access_mode", "open");

    var envelope = try testEnvelopeForObjectEventType(allocator, "issue.opened", "issue", "018f0000-0000-7000-8000-000000000100");
    defer envelope.deinit();

    const plain_body =
        \\{
        \\  "payload": {
        \\    "title": "Smoke"
        \\  },
        \\  "legacy": {}
        \\}
    ;
    try std.testing.expect((try authorizationRejection(allocator, &db, null, envelope, plain_body)) == null);

    const identity_body =
        \\{
        \\  "payload": {
        \\    "title": "Smoke",
        \\    "source_author": "Mallory",
        \\    "source_identity": "github:123",
        \\    "source_email": "mallory@example.test",
        \\    "source_avatar_url": "https://attacker.invalid/avatar.png"
        \\  },
        \\  "legacy": {}
        \\}
    ;
    try std.testing.expectEqualStrings("unauthorized_source_identity", (try authorizationRejection(allocator, &db, null, envelope, identity_body)).?);

    const display_only_body =
        \\{
        \\  "payload": {
        \\    "title": "Smoke",
        \\    "source_author": "Mallory"
        \\  },
        \\  "legacy": {}
        \\}
    ;
    try std.testing.expectEqualStrings("unauthorized_source_identity", (try authorizationRejection(allocator, &db, null, envelope, display_only_body)).?);
}

test "open access self-registration fingerprint requires matching actor" {
    const allocator = std.testing.allocator;
    var envelope = try testEnvelopeForObjectEventType(allocator, "identity.device_added", "identity", "identity-1");
    defer envelope.deinit();

    const body =
        \\{
        \\  "payload": {
        \\    "principal": "alice",
        \\    "device": "laptop",
        \\    "signing_key": {
        \\      "fingerprint": "SHA256:alice",
        \\      "public_key": "ssh-ed25519 AAAA"
        \\    }
        \\  }
        \\}
    ;
    const fingerprint = (try selfRegistrationFingerprint(allocator, envelope, body)) orelse return error.TestExpectedEqual;
    defer allocator.free(fingerprint);
    try std.testing.expectEqualStrings("SHA256:alice", fingerprint);

    const mismatched_body =
        \\{
        \\  "payload": {
        \\    "principal": "bob",
        \\    "device": "laptop",
        \\    "signing_key": {
        \\      "fingerprint": "SHA256:bob",
        \\      "public_key": "ssh-ed25519 AAAA"
        \\    }
        \\  }
        \\}
    ;
    try std.testing.expect((try selfRegistrationFingerprint(allocator, envelope, mismatched_body)) == null);
}

test "project field key collision is domain rejected" {
    const allocator = std.testing.allocator;
    var db = try SqliteDb.open(allocator, ":memory:", sqlite_db.sqlite.SQLITE_OPEN_READWRITE | sqlite_db.sqlite.SQLITE_OPEN_CREATE, true);
    defer db.deinit();
    try index_schema.createIndexSchema(&db);
    try db.exec(
        \\INSERT INTO projects(
        \\  id, name, slug, name_occurred_at, name_actor_principal, name_event_hash,
        \\  description, description_occurred_at, description_actor_principal, description_event_hash,
        \\  state, state_occurred_at, state_actor_principal, state_event_hash,
        \\  status, status_occurred_at, status_actor_principal, status_event_hash,
        \\  priority, priority_occurred_at, priority_actor_principal, priority_event_hash,
        \\  start_at, start_at_occurred_at, start_at_actor_principal, start_at_event_hash,
        \\  end_at, end_at_occurred_at, end_at_actor_principal, end_at_event_hash,
        \\  created_at, author_principal, author_device
        \\) VALUES (
        \\  '018f0000-0000-7000-8000-000000000100', 'Roadmap', 'roadmap',
        \\  '2026-05-16T00:00:00Z', 'alice', '',
        \\  '', '2026-05-16T00:00:00Z', 'alice', '',
        \\  'open', '2026-05-16T00:00:00Z', 'alice', '',
        \\  'WIP', '2026-05-16T00:00:00Z', 'alice', '',
        \\  '', '2026-05-16T00:00:00Z', 'alice', '',
        \\  '2026-05-16', '2026-05-16T00:00:00Z', 'alice', '',
        \\  '', '2026-05-16T00:00:00Z', 'alice', '',
        \\  '2026-05-16T00:00:00Z', 'alice', 'laptop'
        \\);
        \\INSERT INTO events(
        \\  ref, "commit", event_hash, tree, subject, body, empty_tree, valid_json,
        \\  event_type, object_kind, object_id, actor_principal, actor_device, seq, occurred_at,
        \\  domain_status, rejection_reason
        \\) VALUES (
        \\  'refs/gitomi/inbox/alice/laptop', '', '', '', 'project.created',
        \\  '{}', 1, 1, 'project.created', 'project',
        \\  '018f0000-0000-7000-8000-000000000100', 'alice', 'laptop', 1,
        \\  '2026-05-16T00:00:00Z', 'accepted', ''
        \\);
        \\INSERT INTO project_fields(
        \\  id, project_id, key, name, field_type, position, required, default_value_json,
        \\  state, created_at, actor_principal, event_hash
        \\) VALUES
        \\  (
        \\    '018f0000-0000-7000-8000-000000000101',
        \\    '018f0000-0000-7000-8000-000000000100',
        \\    'priority', 'Priority', 'text', 0, 0, 'null', 'active',
        \\    '2026-05-16T00:00:00Z', 'alice', ''
        \\  ),
        \\  (
        \\    '018f0000-0000-7000-8000-000000000102',
        \\    '018f0000-0000-7000-8000-000000000100',
        \\    'status', 'Status', 'text', 1, 0, 'null', 'active',
        \\    '2026-05-16T00:00:00Z', 'alice', ''
        \\  );
    );

    const body =
        \\{
        \\  "$schema": "urn:gitomi:event:v1",
        \\  "repo_id": "018f0000-0000-7000-8000-000000000001",
        \\  "event_uuid": "018f0000-0000-7000-8000-000000000103",
        \\  "event_type": "project.field_updated",
        \\  "object": {
        \\    "kind": "project",
        \\    "id": "018f0000-0000-7000-8000-000000000100"
        \\  },
        \\  "idempotency_key": "018f0000-0000-7000-8000-000000000104",
        \\  "actor": {
        \\    "principal": "alice",
        \\    "device": "laptop"
        \\  },
        \\  "seq": 1,
        \\  "occurred_at": "2026-05-16T00:00:01Z",
        \\  "parent_hashes": {
        \\    "log": "",
        \\    "anchor": "",
        \\    "causal": [],
        \\    "related": []
        \\  },
        \\  "legacy": {},
        \\  "payload": {
        \\    "field_id": "018f0000-0000-7000-8000-000000000101",
        \\    "key": "status"
        \\  }
        \\}
    ;
    var envelope = try parseValidatedEnvelope(allocator, body);
    defer envelope.deinit();
    const rejection = try projection_objects.applyProjectProjection(allocator, &db, "update-event", envelope, body);
    try std.testing.expect(rejection != null);
    try std.testing.expectEqualStrings("duplicate_project_field_key", rejection.?);
    try expectProjectFieldKey(allocator, &db, "018f0000-0000-7000-8000-000000000101", "priority");
}

fn insertPendingTestEvent(db: *SqliteDb, event_hash: []const u8, body: []const u8) !void {
    var stmt = try db.prepare(
        \\INSERT INTO events(
        \\  ref, "commit", event_hash, tree, subject, body, empty_tree, valid_json,
        \\  event_type, object_kind, object_id, actor_principal, actor_device, seq, occurred_at,
        \\  domain_status, rejection_reason
        \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    );
    defer stmt.deinit();
    try stmt.bindText(1, "refs/gitomi/inbox/alice/laptop");
    try stmt.bindText(2, event_hash);
    try stmt.bindText(3, event_hash);
    try stmt.bindText(4, "");
    try stmt.bindText(5, "project.field_updated @018f000 018f000");
    try stmt.bindText(6, body);
    try stmt.bindInt(7, 0);
    try stmt.bindInt(8, 1);
    try stmt.bindText(9, "project.field_updated");
    try stmt.bindText(10, "project");
    try stmt.bindText(11, "018f0000-0000-7000-8000-000000000100");
    try stmt.bindText(12, "alice");
    try stmt.bindText(13, "laptop");
    try stmt.bindInt64(14, 1);
    try stmt.bindText(15, "2026-05-16T00:00:01Z");
    try stmt.bindText(16, "pending");
    try stmt.bindText(17, "");
    try stmt.stepDone();
}

fn expectDomainRejection(allocator: Allocator, db: *SqliteDb, event_hash: []const u8, reason: []const u8) !void {
    var stmt = try db.prepare("SELECT domain_status, rejection_reason FROM events WHERE event_hash = ?");
    defer stmt.deinit();
    try stmt.bindText(1, event_hash);
    try std.testing.expect(try stmt.step());
    const status = try stmt.columnTextDup(allocator, 0);
    defer allocator.free(status);
    const rejection_reason = try stmt.columnTextDup(allocator, 1);
    defer allocator.free(rejection_reason);
    try std.testing.expectEqualStrings("rejected", status);
    try std.testing.expectEqualStrings(reason, rejection_reason);
}

fn expectProjectFieldKey(allocator: Allocator, db: *SqliteDb, field_id: []const u8, expected_key: []const u8) !void {
    var stmt = try db.prepare("SELECT key FROM project_fields WHERE id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, field_id);
    try std.testing.expect(try stmt.step());
    const key = try stmt.columnTextDup(allocator, 0);
    defer allocator.free(key);
    try std.testing.expectEqualStrings(expected_key, key);
}

test "pull opened metadata collections require maintainer role" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{
        \\  "title": "PR",
        \\  "base_ref": "main",
        \\  "head_ref": "feature",
        \\  "labels": ["security"],
        \\  "assignees": ["maintainer-user"],
        \\  "reviewers": ["owner-user"]
        \\}
    , .{});
    defer parsed.deinit();
    const payload = switch (parsed.value) {
        .object => |object| object,
        else => unreachable,
    };
    const envelope = try testEnvelopeForEventType(allocator, "pull.opened");
    defer envelope.deinit();
    var db = try SqliteDb.open(allocator, ":memory:", sqlite_db.sqlite.SQLITE_OPEN_READWRITE | sqlite_db.sqlite.SQLITE_OPEN_CREATE, true);
    defer db.deinit();

    try std.testing.expectEqualStrings("insufficient_role", (try eventAuthorizationRejection(allocator, &db, "contributor", envelope, payload, null)).?);
    try std.testing.expect((try eventAuthorizationRejection(allocator, &db, "maintainer", envelope, payload, null)) == null);
}

test "pull opened without metadata collections remains contributor allowed" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{
        \\  "title": "PR",
        \\  "base_ref": "main",
        \\  "head_ref": "feature",
        \\  "labels": [],
        \\  "assignees": [],
        \\  "reviewers": []
        \\}
    , .{});
    defer parsed.deinit();
    const payload = switch (parsed.value) {
        .object => |object| object,
        else => unreachable,
    };
    const envelope = try testEnvelopeForEventType(allocator, "pull.opened");
    defer envelope.deinit();
    var db = try SqliteDb.open(allocator, ":memory:", sqlite_db.sqlite.SQLITE_OPEN_READWRITE | sqlite_db.sqlite.SQLITE_OPEN_CREATE, true);
    defer db.deinit();

    try std.testing.expect((try eventAuthorizationRejection(allocator, &db, "contributor", envelope, payload, null)) == null);
}

test "pull merged requires maintainer role" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{
        \\  "merge_oid": "cccccccccccccccccccccccccccccccccccccccc"
        \\}
    , .{});
    defer parsed.deinit();
    const payload = switch (parsed.value) {
        .object => |object| object,
        else => unreachable,
    };
    const envelope = try testEnvelopeForEventType(allocator, "pull.merged");
    defer envelope.deinit();
    var db = try SqliteDb.open(allocator, ":memory:", sqlite_db.sqlite.SQLITE_OPEN_READWRITE | sqlite_db.sqlite.SQLITE_OPEN_CREATE, true);
    defer db.deinit();

    try std.testing.expectEqualStrings("insufficient_role", (try eventAuthorizationRejection(allocator, &db, "contributor", envelope, payload, null)).?);
    try std.testing.expect((try eventAuthorizationRejection(allocator, &db, "maintainer", envelope, payload, null)) == null);
}

test "own object authorization uses accepted creation events, not projection rows" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{
        \\  "title": "Updated"
        \\}
    , .{});
    defer parsed.deinit();
    const payload = switch (parsed.value) {
        .object => |object| object,
        else => unreachable,
    };

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
        \\  'Old', '2026-05-16T00:00:00Z', 'alice', '',
        \\  '', '2026-05-16T00:00:00Z', 'alice', '',
        \\  'open', '2026-05-16T00:00:00Z', 'alice', '',
        \\  '2026-05-16T00:00:00Z', 'alice', 'laptop'
        \\);
    );

    var envelope = try testEnvelopeForObjectEventType(allocator, "issue.title_set", "issue", "issue-1");
    defer envelope.deinit();
    try std.testing.expectEqualStrings("insufficient_role", (try eventAuthorizationRejection(allocator, &db, "contributor", envelope, payload, null)).?);

    try insertAcceptedCreationEvent(&db, "", "issue.opened", "issue", "issue-1", "alice", "laptop");
    try std.testing.expect((try eventAuthorizationRejection(allocator, &db, "contributor", envelope, payload, null)) == null);

    var bob_envelope = try testEnvelopeForObjectEventType(allocator, "issue.title_set", "issue", "issue-1");
    defer bob_envelope.deinit();
    allocator.free(bob_envelope.actor_principal);
    bob_envelope.actor_principal = try allocator.dupe(u8, "bob");
    try std.testing.expectEqualStrings("insufficient_role", (try eventAuthorizationRejection(allocator, &db, "contributor", bob_envelope, payload, null)).?);
}

test "issue project field updates require maintainer role" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{
        \\  "project_id": "project-1",
        \\  "field_id": "field-1",
        \\  "value": "Done"
        \\}
    , .{});
    defer parsed.deinit();
    const payload = switch (parsed.value) {
        .object => |object| object,
        else => unreachable,
    };
    var db = try SqliteDb.open(allocator, ":memory:", sqlite_db.sqlite.SQLITE_OPEN_READWRITE | sqlite_db.sqlite.SQLITE_OPEN_CREATE, true);
    defer db.deinit();
    try db.exec(
        \\CREATE TABLE issues(id TEXT PRIMARY KEY, author_principal TEXT NOT NULL);
        \\INSERT INTO issues(id, author_principal) VALUES ('issue-1', 'alice');
    );

    inline for (.{ "issue.project_field_set", "issue.project_field_cleared" }) |event_type| {
        const envelope = try testEnvelopeForObjectEventType(allocator, event_type, "issue", "issue-1");
        defer envelope.deinit();
        try std.testing.expectEqualStrings("insufficient_role", (try eventAuthorizationRejection(allocator, &db, "contributor", envelope, payload, null)).?);
        try std.testing.expect((try eventAuthorizationRejection(allocator, &db, "maintainer", envelope, payload, null)) == null);
    }
}

fn insertAcceptedCreationEvent(
    db: *SqliteDb,
    event_hash: []const u8,
    event_type: []const u8,
    object_kind: []const u8,
    object_id: []const u8,
    actor_principal: []const u8,
    actor_device: []const u8,
) !void {
    var stmt = try db.prepare(
        \\INSERT INTO events(
        \\  ref, "commit", event_hash, tree, subject, body, empty_tree, valid_json,
        \\  event_type, object_kind, object_id, actor_principal, actor_device, seq, occurred_at,
        \\  domain_status, rejection_reason
        \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    );
    defer stmt.deinit();
    try stmt.bindText(1, "refs/gitomi/inbox/alice/laptop");
    try stmt.bindText(2, event_hash);
    try stmt.bindText(3, event_hash);
    try stmt.bindText(4, "");
    try stmt.bindText(5, event_type);
    try stmt.bindText(6, "{}");
    try stmt.bindInt(7, 0);
    try stmt.bindInt(8, 1);
    try stmt.bindText(9, event_type);
    try stmt.bindText(10, object_kind);
    try stmt.bindText(11, object_id);
    try stmt.bindText(12, actor_principal);
    try stmt.bindText(13, actor_device);
    try stmt.bindInt64(14, 1);
    try stmt.bindText(15, "2026-05-16T00:00:00Z");
    try stmt.bindText(16, "accepted");
    try stmt.bindText(17, "");
    try stmt.stepDone();
}

test "data commit reference parser extracts unique typed hash and legacy refs" {
    var tokens: std.ArrayList(DerivedReferenceToken) = .empty;
    defer freeDerivedReferenceTokens(std.testing.allocator, &tokens);

    try collectReferenceTokens(
        std.testing.allocator,
        "Fix #A1B2C3D and refs #a1b2c3d #42 issue:0ABCDEF pr:123 #not-a-ref #abcdef0g #018f000 issue:0abcdef",
        max_derived_reference_tokens_per_commit,
        &tokens,
    );

    try std.testing.expectEqual(@as(usize, 5), tokens.items.len);
    try std.testing.expectEqualStrings("a1b2c3d", tokens.items[0].prefix);
    try std.testing.expect(tokens.items[0].object_kind == null);
    try std.testing.expectEqualStrings("42", tokens.items[1].prefix);
    try std.testing.expect(tokens.items[1].object_kind == null);
    try std.testing.expectEqualStrings("0abcdef", tokens.items[2].prefix);
    try std.testing.expectEqualStrings("issue", tokens.items[2].object_kind.?);
    try std.testing.expectEqualStrings("123", tokens.items[3].prefix);
    try std.testing.expectEqualStrings("pull", tokens.items[3].object_kind.?);
    try std.testing.expectEqualStrings("018f000", tokens.items[4].prefix);
    try std.testing.expect(tokens.items[4].object_kind == null);
}

test "data commit reference parser caps unique refs" {
    var tokens: std.ArrayList(DerivedReferenceToken) = .empty;
    defer freeDerivedReferenceTokens(std.testing.allocator, &tokens);

    try collectReferenceTokens(
        std.testing.allocator,
        "#0000000 #0000001 #0000002 #0000003",
        2,
        &tokens,
    );

    try std.testing.expectEqual(@as(usize, 2), tokens.items.len);
    try std.testing.expectEqualStrings("0000000", tokens.items[0].prefix);
    try std.testing.expectEqualStrings("0000001", tokens.items[1].prefix);
}

test "derived hash resolver uses precomputed object ref index" {
    const allocator = std.testing.allocator;
    var db = try SqliteDb.open(allocator, ":memory:", sqlite_db.sqlite.SQLITE_OPEN_READWRITE | sqlite_db.sqlite.SQLITE_OPEN_CREATE, true);
    defer db.deinit();
    try db.exec(
        \\CREATE TABLE issues(id TEXT PRIMARY KEY);
        \\CREATE TABLE pulls(id TEXT PRIMARY KEY);
        \\CREATE TABLE legacy_aliases(
        \\  provider TEXT NOT NULL,
        \\  object_kind TEXT NOT NULL,
        \\  object_id TEXT NOT NULL,
        \\  number INTEGER NOT NULL
        \\);
        \\INSERT INTO issues(id) VALUES ('issue-object-1');
        \\INSERT INTO issues(id) VALUES ('shared-object-id');
        \\INSERT INTO pulls(id) VALUES ('shared-object-id');
    );

    var resolver = try DerivedReferenceResolver.init(allocator, &db);
    defer resolver.deinit();

    var issue_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const issue_ref = util.shortObjectRef(&issue_ref_buf, "issue-object-1");
    var issue_target = (try resolver.resolve(issue_ref, null)).?;
    defer issue_target.deinit();
    try std.testing.expectEqualStrings("issue", issue_target.object_kind);
    try std.testing.expectEqualStrings("issue-object-1", issue_target.object_id);

    var shared_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const shared_ref = util.shortObjectRef(&shared_ref_buf, "shared-object-id");
    try std.testing.expect((try resolver.resolve(shared_ref, null)) == null);

    var typed_target = (try resolver.resolve(shared_ref, "pull")).?;
    defer typed_target.deinit();
    try std.testing.expectEqualStrings("pull", typed_target.object_kind);
    try std.testing.expectEqualStrings("shared-object-id", typed_target.object_id);
}
