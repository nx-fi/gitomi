const std = @import("std");

const errors = @import("../errors.zig");
const event_mod = @import("../event.zig");
const git = @import("../git.zig");
const ordering = @import("projection_ordering.zig");
const projection_objects = @import("projection_objects.zig");
const repo_mod = @import("../repo.zig");
const sqlite_db = @import("sqlite_db.zig");

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

const min_reference_prefix_hex = 7;
const max_derived_commit_log_bytes = 64 * 1024 * 1024;

fn isDataPlaneIndexRef(ref: []const u8) bool {
    return std.mem.startsWith(u8, ref, "refs/heads/") or std.mem.startsWith(u8, ref, "refs/tags/");
}

pub fn projectIndexedEvents(allocator: Allocator, db: *SqliteDb) !void {
    try seedGenesisAuthorization(allocator, db);

    try projectEventQuery(allocator, db, "SELECT event_hash FROM events WHERE valid_json != 0 AND (event_type LIKE 'acl.%' OR event_type LIKE 'identity.%') ORDER BY ordinal", true);
    try projectEventQuery(allocator, db, "SELECT event_hash FROM events WHERE valid_json != 0 AND event_type NOT LIKE 'acl.%' AND event_type NOT LIKE 'identity.%' ORDER BY ordinal", false);
}

pub fn projectNewIndexedEvents(allocator: Allocator, db: *SqliteDb) !void {
    try projectEventQuery(allocator, db, "SELECT event_hash FROM events WHERE valid_json != 0 AND domain_status = 'pending' AND (event_type LIKE 'acl.%' OR event_type LIKE 'identity.%') ORDER BY ordinal", true);
    try projectEventQuery(allocator, db, "SELECT event_hash FROM events WHERE valid_json != 0 AND domain_status = 'pending' AND event_type NOT LIKE 'acl.%' AND event_type NOT LIKE 'identity.%' ORDER BY ordinal", false);
}

fn projectEventQuery(allocator: Allocator, db: *SqliteDb, comptime sql_text: []const u8, auth_phase: bool) !void {
    var event_hashes: std.ArrayList([]u8) = .empty;
    defer freeStringArrayList(allocator, &event_hashes);

    var stmt = try db.prepare(sql_text);
    defer stmt.deinit();
    while (try stmt.step()) {
        try event_hashes.append(allocator, try stmt.columnTextDup(allocator, 0));
    }

    try orderEventHashesTopologically(allocator, &event_hashes);

    for (event_hashes.items) |event_hash| {
        const body = try eventBodyByHash(allocator, db, event_hash);
        defer allocator.free(body);
        try projectStoredEvent(allocator, db, event_hash, body, auth_phase);
    }
}

fn orderEventHashesTopologically(allocator: Allocator, event_hashes: *std.ArrayList([]u8)) !void {
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

    var records = std.mem.splitScalar(u8, log, 0x1e);
    while (records.next()) |record_raw| {
        const record = std.mem.trim(u8, record_raw, "\r\n");
        if (record.len == 0) continue;
        const first = std.mem.indexOfScalar(u8, record, 0) orelse continue;
        const commit_oid = std.mem.trim(u8, record[0..first], " \t\r\n");
        const message = record[first + 1 ..];
        if (commit_oid.len == 0 or message.len == 0) continue;

        var prefixes: std.ArrayList([]u8) = .empty;
        defer freeStringArrayList(allocator, &prefixes);
        try collectReferencePrefixes(allocator, message, &prefixes);

        for (prefixes.items) |prefix| {
            var target = (try resolveDerivedReference(allocator, db, prefix)) orelse continue;
            defer target.deinit();
            try insertDerivedCommitReference(&insert, commit_oid, target.object_kind, target.object_id, prefix);
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

fn collectReferencePrefixes(allocator: Allocator, message: []const u8, prefixes: *std.ArrayList([]u8)) !void {
    var i: usize = 0;
    while (i < message.len) : (i += 1) {
        if (message[i] != '#') continue;
        const start = i + 1;
        if (start >= message.len or !isUuidPrefixChar(message[start])) continue;

        var end = start;
        while (end < message.len and isUuidPrefixChar(message[end])) : (end += 1) {}
        const raw_prefix = message[start..end];
        i = end;
        if (!isReferencePrefixCandidate(raw_prefix)) continue;
        try appendUniqueLowerPrefix(allocator, prefixes, raw_prefix);
    }
}

fn isUuidPrefixChar(c: u8) bool {
    return std.ascii.isHex(c) or c == '-';
}

fn isReferencePrefixCandidate(prefix: []const u8) bool {
    var hex_count: usize = 0;
    for (prefix) |c| {
        if (std.ascii.isHex(c)) {
            hex_count += 1;
        } else if (c != '-') {
            return false;
        }
    }
    return hex_count >= min_reference_prefix_hex;
}

fn appendUniqueLowerPrefix(allocator: Allocator, prefixes: *std.ArrayList([]u8), raw_prefix: []const u8) !void {
    var prefix = try allocator.alloc(u8, raw_prefix.len);
    errdefer allocator.free(prefix);
    for (raw_prefix, 0..) |c, idx| prefix[idx] = std.ascii.toLower(c);

    for (prefixes.items) |existing| {
        if (std.mem.eql(u8, existing, prefix)) {
            allocator.free(prefix);
            return;
        }
    }

    try prefixes.append(allocator, prefix);
}

fn resolveDerivedReference(allocator: Allocator, db: *SqliteDb, prefix: []const u8) !?DerivedReferenceTarget {
    const pattern = try std.fmt.allocPrint(allocator, "{s}%", .{prefix});
    defer allocator.free(pattern);

    var stmt = try db.prepare(
        \\SELECT object_kind, id FROM (
        \\  SELECT 'issue' AS object_kind, id FROM issues WHERE id LIKE ?
        \\  UNION ALL
        \\  SELECT 'pull' AS object_kind, id FROM pulls WHERE id LIKE ?
        \\)
        \\ORDER BY id, object_kind
        \\LIMIT 2
    );
    defer stmt.deinit();
    try stmt.bindText(1, pattern);
    try stmt.bindText(2, pattern);

    if (!(try stmt.step())) return null;
    var object_kind: ?[]u8 = try stmt.columnTextDup(allocator, 0);
    errdefer if (object_kind) |value| allocator.free(value);
    var object_id: ?[]u8 = try stmt.columnTextDup(allocator, 1);
    errdefer if (object_id) |value| allocator.free(value);

    if (try stmt.step()) {
        allocator.free(object_kind.?);
        allocator.free(object_id.?);
        return null;
    }

    const target = DerivedReferenceTarget{
        .allocator = allocator,
        .object_kind = object_kind.?,
        .object_id = object_id.?,
    };
    object_kind = null;
    object_id = null;
    return target;
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

fn projectStoredEvent(allocator: Allocator, db: *SqliteDb, event_hash: []const u8, body: []const u8, auth_phase: bool) !void {
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
    else if (std.mem.startsWith(u8, envelope.event_type, "comment."))
        try projection_objects.applyCommentProjection(allocator, db, event_hash, envelope, body)
    else
        null;

    if (rejection) |reason| {
        try db.exec("ROLLBACK TO " ++ savepoint);
        try db.exec("RELEASE " ++ savepoint);
        savepoint_active = false;
        try markDomainRejected(db, event_hash, reason);
    } else {
        try db.exec("RELEASE " ++ savepoint);
        savepoint_active = false;
        try markDomainAccepted(db, event_hash);
    }
}

fn seedGenesisAuthorization(allocator: Allocator, db: *SqliteDb) !void {
    const genesis_oid = try git.resolveOptionalRef(allocator, repo_mod.genesis_ref);
    defer if (genesis_oid) |oid| allocator.free(oid);
    const oid = genesis_oid orelse return;

    var manifest = repo_mod.loadGenesisManifest(allocator, oid) catch return;
    defer manifest.deinit();

    try upsertAclRole(db, manifest.owner_principal, manifest.owner_role, oid);
    try insertAclHistory(db, manifest.owner_principal, manifest.owner_role, "", "acl.role_granted");
    try upsertIdentityDevice(db, manifest.device_principal, manifest.device_id, manifest.fingerprint, manifest.public_key, oid, null);
    try insertIdentityHistory(db, manifest.device_principal, manifest.device_id, manifest.fingerprint, manifest.public_key, "", "identity.device_added");
}

pub fn authorizationRejection(allocator: Allocator, db: *SqliteDb, event_hash: ?[]const u8, envelope: ValidatedEnvelope, body: []const u8) !?[]const u8 {
    const role = if (event_hash) |hash|
        (try aclRoleAtFrontier(allocator, db, envelope.actor_principal, hash)) orelse return "unauthorized_principal"
    else
        (try currentRole(allocator, db, envelope.actor_principal)) orelse return "unauthorized_principal";
    defer allocator.free(role);
    if (event_hash) |hash| {
        const expected_fingerprint = (try identityDeviceFingerprintAtFrontier(allocator, db, envelope.actor_principal, envelope.actor_device, hash)) orelse return "unauthorized_device";
        defer allocator.free(expected_fingerprint);
        const signer_fingerprint = (try git.verifiedCommitSigningKeyFingerprint(allocator, hash)) orelse return "signing_key_mismatch";
        defer allocator.free(signer_fingerprint);
        if (!std.mem.eql(u8, expected_fingerprint, signer_fingerprint)) return "signing_key_mismatch";
    } else if (!(try currentDeviceActive(db, envelope.actor_principal, envelope.actor_device))) {
        return "unauthorized_device";
    }

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

    if (try eventAuthorizationRejection(allocator, db, role, envelope, payload)) |reason| return reason;
    return null;
}

fn eventAuthorizationRejection(
    allocator: Allocator,
    db: *SqliteDb,
    role: []const u8,
    envelope: ValidatedEnvelope,
    payload: std.json.ObjectMap,
) !?[]const u8 {
    if (std.mem.eql(u8, envelope.event_type, "issue.opened")) {
        if (!roleAtLeast(role, "reporter")) return "insufficient_role";
        if (payloadContainsNonEmptyArray(payload, "labels") and !roleAtLeast(role, "maintainer")) return "insufficient_role";
        if (payloadContainsNonEmptyArray(payload, "assignees") and !roleAtLeast(role, "maintainer")) return "insufficient_role";
        return null;
    }
    if (std.mem.eql(u8, envelope.event_type, "issue.updated")) {
        if (payloadHasAny(payload, &.{ "title", "body", "state" }) and !(try canEditObject(allocator, db, role, envelope.actor_principal, "issue", envelope.object_id))) return "insufficient_role";
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
        std.mem.eql(u8, envelope.event_type, "issue.state_set"))
    {
        return if (try canEditObject(allocator, db, role, envelope.actor_principal, "issue", envelope.object_id)) null else "insufficient_role";
    }
    if (std.mem.eql(u8, envelope.event_type, "issue.label_added") or std.mem.eql(u8, envelope.event_type, "issue.label_removed")) {
        return if (roleAtLeast(role, "maintainer")) null else "insufficient_role";
    }
    if (std.mem.eql(u8, envelope.event_type, "issue.assignee_added") or std.mem.eql(u8, envelope.event_type, "issue.assignee_removed")) {
        return if (roleAtLeast(role, "maintainer")) null else "insufficient_role";
    }

    if (std.mem.eql(u8, envelope.event_type, "pull.opened")) {
        return if (roleAtLeast(role, "contributor")) null else "insufficient_role";
    }
    if (std.mem.eql(u8, envelope.event_type, "pull.updated")) {
        if (payloadHasAny(payload, &.{ "title", "body", "state", "base_ref", "head_ref" }) and !(try canEditObject(allocator, db, role, envelope.actor_principal, "pull", envelope.object_id))) return "insufficient_role";
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
        return if (try canEditObject(allocator, db, role, envelope.actor_principal, "pull", envelope.object_id)) null else "insufficient_role";
    }
    if (std.mem.eql(u8, envelope.event_type, "pull.label_added") or std.mem.eql(u8, envelope.event_type, "pull.label_removed") or
        std.mem.eql(u8, envelope.event_type, "pull.assignee_added") or std.mem.eql(u8, envelope.event_type, "pull.assignee_removed") or
        std.mem.eql(u8, envelope.event_type, "pull.reviewer_added") or std.mem.eql(u8, envelope.event_type, "pull.reviewer_removed") or
        std.mem.eql(u8, envelope.event_type, "pull.merged"))
    {
        return if (roleAtLeast(role, "maintainer")) null else "insufficient_role";
    }

    if (std.mem.eql(u8, envelope.event_type, "comment.added")) {
        return if (roleAtLeast(role, "reporter")) null else "insufficient_role";
    }
    if (std.mem.eql(u8, envelope.event_type, "comment.body_set")) {
        return if (try canEditObject(allocator, db, role, envelope.actor_principal, "comment", envelope.object_id)) null else "insufficient_role";
    }
    if (std.mem.eql(u8, envelope.event_type, "comment.redacted")) {
        return if (try canRedactComment(allocator, db, role, envelope.actor_principal, envelope.object_id)) null else "insufficient_role";
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

    if (std.mem.eql(u8, envelope.event_type, "identity.device_added") or std.mem.eql(u8, envelope.event_type, "identity.device_revoked")) {
        return if (roleAtLeast(role, "owner")) null else "insufficient_role";
    }

    if (std.mem.eql(u8, envelope.event_type, "action.run_requested") or std.mem.eql(u8, envelope.event_type, "action.run_completed")) {
        return if (roleAtLeast(role, "maintainer")) null else "insufficient_role";
    }

    return "unknown_event_type";
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

fn roleRank(role: []const u8) u8 {
    if (std.mem.eql(u8, role, "reader")) return 1;
    if (std.mem.eql(u8, role, "reporter")) return 2;
    if (std.mem.eql(u8, role, "contributor")) return 3;
    if (std.mem.eql(u8, role, "maintainer")) return 4;
    if (std.mem.eql(u8, role, "owner")) return 5;
    return 0;
}

fn roleAtLeast(actual: []const u8, required: []const u8) bool {
    return roleRank(actual) >= roleRank(required) and roleRank(required) != 0;
}

fn canEditObject(allocator: Allocator, db: *SqliteDb, role: []const u8, actor: []const u8, kind: []const u8, object_id: []const u8) !bool {
    if (roleAtLeast(role, "maintainer")) return true;
    if (!roleAtLeast(role, "contributor")) return false;
    const author = try objectAuthor(allocator, db, kind, object_id);
    defer if (author) |value| allocator.free(value);
    return author != null and std.mem.eql(u8, author.?, actor);
}

fn canRedactComment(allocator: Allocator, db: *SqliteDb, role: []const u8, actor: []const u8, comment_id: []const u8) !bool {
    if (roleAtLeast(role, "maintainer")) return true;
    if (!roleAtLeast(role, "contributor")) return false;
    const author = try objectAuthor(allocator, db, "comment", comment_id);
    defer if (author) |value| allocator.free(value);
    return author != null and std.mem.eql(u8, author.?, actor);
}

fn objectAuthor(allocator: Allocator, db: *SqliteDb, kind: []const u8, object_id: []const u8) !?[]u8 {
    const sql_text = if (std.mem.eql(u8, kind, "issue"))
        "SELECT author_principal FROM issues WHERE id = ?"
    else if (std.mem.eql(u8, kind, "pull"))
        "SELECT author_principal FROM pulls WHERE id = ?"
    else if (std.mem.eql(u8, kind, "comment"))
        "SELECT author_principal FROM comments WHERE id = ?"
    else
        return null;
    var stmt = try db.prepare(sql_text);
    defer stmt.deinit();
    try stmt.bindText(1, object_id);
    if (!(try stmt.step())) return null;
    return try stmt.columnTextDup(allocator, 0);
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

fn creationEventWins(db: *SqliteDb, event_type: []const u8, object_id: []const u8, event_hash: []const u8) !bool {
    var stmt = try db.prepare("SELECT event_hash FROM events WHERE event_type = ? AND object_id = ? ORDER BY event_hash DESC LIMIT 1");
    defer stmt.deinit();
    try stmt.bindText(1, event_type);
    try stmt.bindText(2, object_id);
    if (!(try stmt.step())) return false;
    const winner = try stmt.columnTextDup(db.allocator, 0);
    defer db.allocator.free(winner);
    return std.mem.eql(u8, winner, event_hash);
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
    const role = event_mod.jsonString(payload.get("role")) orelse return "invalid_event_envelope";
    if (!event_mod.isKnownRole(role)) return "invalid_role";

    if (std.mem.eql(u8, envelope.event_type, "acl.role_granted")) {
        const actor_role = (try aclRoleAtFrontier(allocator, db, envelope.actor_principal, event_hash)) orelse return "unauthorized_principal";
        defer allocator.free(actor_role);
        if (!roleAtLeast(actor_role, role)) return "privilege_escalation";
        try insertAclHistory(db, principal, role, event_hash, envelope.event_type);
        try reconcileAclRole(allocator, db, principal);
        return null;
    }

    if (std.mem.eql(u8, envelope.event_type, "acl.role_revoked")) {
        const existing_role = (try aclRoleAtFrontier(allocator, db, principal, event_hash)) orelse return "role_not_granted";
        defer allocator.free(existing_role);
        if (!std.mem.eql(u8, existing_role, role)) return "role_mismatch";
        if (std.mem.eql(u8, principal, envelope.actor_principal) and std.mem.eql(u8, role, "owner")) {
            const owners = try countCurrentOwners(db);
            if (owners <= 1) return "last_owner";
        }
        try insertAclHistory(db, principal, role, event_hash, envelope.event_type);
        try reconcileAclRole(allocator, db, principal);
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
    var events = try loadAclRoleEvents(allocator, db, principal, null);
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
    var events = try loadAclRoleEvents(allocator, db, principal, event_hash);
    defer freeAclRoleEvents(allocator, &events);

    const winner_index = try winningAclRoleEventIndex(allocator, events.items) orelse return null;
    const winner = events.items[winner_index];
    if (!std.mem.eql(u8, winner.event_type, "acl.role_granted")) return null;
    return try allocator.dupe(u8, winner.role);
}

fn loadAclRoleEvents(allocator: Allocator, db: *SqliteDb, principal: []const u8, before_event_hash: ?[]const u8) !std.ArrayList(AclRoleEvent) {
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
        if (!(try eventInFrontier(allocator, event_hash, before_event_hash))) {
            continue;
        }

        var role_value: ?[]u8 = try stmt.columnTextDup(allocator, 0);
        errdefer if (role_value) |value| allocator.free(value);
        var event_type: ?[]u8 = try stmt.columnTextDup(allocator, 2);
        errdefer if (event_type) |value| allocator.free(value);

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
        if (winner == null or try eventWins(allocator, event.event_hash, events[winner.?].event_hash)) {
            winner = index;
        }
    }
    return winner;
}

pub fn countCurrentOwners(db: *SqliteDb) !usize {
    var stmt = try db.prepare("SELECT COUNT(*) FROM acl_roles WHERE role = 'owner'");
    defer stmt.deinit();
    if (!(try stmt.step())) return 0;
    const count = stmt.columnInt64(0);
    return if (count <= 0) 0 else @as(usize, @intCast(count));
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
    var events = try loadIdentityDeviceEvents(allocator, db, principal, device, null);
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
    var events = try loadIdentityDeviceEvents(allocator, db, principal, device, event_hash);
    defer freeIdentityDeviceEvents(allocator, &events);
    return (try activeIdentityAddIndex(allocator, events.items)) != null;
}

fn identityDeviceFingerprintAtFrontier(allocator: Allocator, db: *SqliteDb, principal: []const u8, device: []const u8, event_hash: []const u8) !?[]u8 {
    var events = try loadIdentityDeviceEvents(allocator, db, principal, device, event_hash);
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
        if (!(try eventInFrontier(allocator, event_hash, before_event_hash))) {
            continue;
        }

        var event_type: ?[]u8 = try stmt.columnTextDup(allocator, 1);
        errdefer if (event_type) |value| allocator.free(value);
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
    if (revoke_event_hash.len == 0) return false;
    if (std.mem.eql(u8, revoke_event_hash, add_event_hash)) return true;
    if (add_event_hash.len != 0 and try git.isAncestor(allocator, revoke_event_hash, add_event_hash)) return false;
    return true;
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

test "data commit reference parser extracts unique uuid prefixes" {
    var prefixes: std.ArrayList([]u8) = .empty;
    defer freeStringArrayList(std.testing.allocator, &prefixes);

    try collectReferencePrefixes(
        std.testing.allocator,
        "Fix #018F0000-0000-7000-8000-000000000123 and refs #018f000 #12345 #not-a-ref #018f000",
        &prefixes,
    );

    try std.testing.expectEqual(@as(usize, 2), prefixes.items.len);
    try std.testing.expectEqualStrings("018f0000-0000-7000-8000-000000000123", prefixes.items[0]);
    try std.testing.expectEqualStrings("018f000", prefixes.items[1]);
}
