const std = @import("std");

const errors = @import("../errors.zig");
const event_mod = @import("../event.zig");
const git = @import("../git.zig");
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

const DerivedReferenceToken = struct {
    allocator: Allocator,
    prefix: []u8,
    object_kind: ?[]const u8,

    fn deinit(self: *DerivedReferenceToken) void {
        self.allocator.free(self.prefix);
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

        var tokens: std.ArrayList(DerivedReferenceToken) = .empty;
        defer freeDerivedReferenceTokens(allocator, &tokens);
        try collectReferenceTokens(allocator, message, &tokens);

        for (tokens.items) |token| {
            var target = (try resolveDerivedReference(allocator, db, token.prefix, token.object_kind)) orelse continue;
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

fn collectReferenceTokens(allocator: Allocator, message: []const u8, tokens: *std.ArrayList(DerivedReferenceToken)) !void {
    var i: usize = 0;
    while (i < message.len) {
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

fn resolveDerivedReference(allocator: Allocator, db: *SqliteDb, prefix: []const u8, object_kind: ?[]const u8) !?DerivedReferenceTarget {
    if (util.isObjectRefPrefix(prefix)) {
        if (try resolveDerivedHashReference(allocator, db, prefix, object_kind)) |target| return target;
    }
    if (parsePositiveDecimal(prefix)) |number| {
        return try resolveDerivedLegacyReference(allocator, db, number, object_kind);
    }
    return null;
}

fn resolveDerivedHashReference(allocator: Allocator, db: *SqliteDb, prefix: []const u8, expected_kind: ?[]const u8) !?DerivedReferenceTarget {
    var stmt = try db.prepare(
        \\SELECT object_kind, id FROM (
        \\  SELECT 'issue' AS object_kind, id FROM issues
        \\  UNION ALL
        \\  SELECT 'pull' AS object_kind, id FROM pulls
        \\)
        \\ORDER BY id, object_kind
    );
    defer stmt.deinit();

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

        var ref_buf: [util.max_object_ref_len]u8 = undefined;
        const object_ref = util.objectRefPrefix(ref_buf[0..prefix.len], candidate_id);
        if (!std.mem.eql(u8, object_ref, prefix)) {
            allocator.free(candidate_kind);
            allocator.free(candidate_id);
            continue;
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

pub fn signingKeyBindingRejection(allocator: Allocator, db: *SqliteDb, event_hash: []const u8, envelope: ValidatedEnvelope) !?[]const u8 {
    if ((try accessModeFromDb(db)) == .open) return null;

    const role = try aclRoleAtAuthFrontier(allocator, db, envelope.actor_principal, event_hash);
    if (role) |value| {
        allocator.free(value);
        const expected_fingerprint = (try identityDeviceFingerprintAtAuthFrontier(allocator, db, envelope.actor_principal, envelope.actor_device, event_hash)) orelse return "unauthorized_device";
        defer allocator.free(expected_fingerprint);
        const signer_fingerprint = (try git.verifiedCommitSigningKeyFingerprint(allocator, event_hash)) orelse return "signing_key_mismatch";
        defer allocator.free(signer_fingerprint);
        if (!std.mem.eql(u8, expected_fingerprint, signer_fingerprint)) return "signing_key_mismatch";
        return null;
    }

    if (!githubImportDelegatesEvent(envelope.event_type)) return null;

    const delegated_fingerprint = (try delegationFingerprintAtAuthFrontier(
        allocator,
        db,
        envelope.actor_principal,
        envelope.actor_device,
        "github.import",
        event_hash,
    )) orelse return null;
    defer allocator.free(delegated_fingerprint);

    const signer_fingerprint = (try git.verifiedCommitSigningKeyFingerprint(allocator, event_hash)) orelse return "signing_key_mismatch";
    defer allocator.free(signer_fingerprint);

    if (!std.mem.eql(u8, delegated_fingerprint, signer_fingerprint)) return "signing_key_mismatch";
    return null;
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
    if ((try accessModeFromDb(db)) == .open) {
        return try eventAuthorizationRejection(allocator, db, "owner", envelope, payload);
    }

    const role = if (event_hash) |hash|
        try aclRoleAtAuthFrontier(allocator, db, envelope.actor_principal, hash)
    else
        try currentRole(allocator, db, envelope.actor_principal);
    if (role) |value| {
        defer allocator.free(value);
        if (event_hash) |hash| {
            const expected_fingerprint = (try identityDeviceFingerprintAtAuthFrontier(allocator, db, envelope.actor_principal, envelope.actor_device, hash)) orelse return "unauthorized_device";
            defer allocator.free(expected_fingerprint);
            const signer_fingerprint = (try git.verifiedCommitSigningKeyFingerprint(allocator, hash)) orelse return "signing_key_mismatch";
            defer allocator.free(signer_fingerprint);
            if (!std.mem.eql(u8, expected_fingerprint, signer_fingerprint)) return "signing_key_mismatch";
        } else if (!(try currentDeviceActive(db, envelope.actor_principal, envelope.actor_device))) {
            return "unauthorized_device";
        }

        if (try eventAuthorizationRejection(allocator, db, value, envelope, payload)) |reason| return reason;
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
        if (payloadHasAny(payload, &.{"milestone"}) and !roleAtLeast(role, "maintainer")) return "insufficient_role";
        if (payloadContainsNonEmptyArray(payload, "projects") and !roleAtLeast(role, "maintainer")) return "insufficient_role";
        return null;
    }
    if (std.mem.eql(u8, envelope.event_type, "issue.updated")) {
        if (payloadHasAny(payload, &.{ "title", "body", "state" }) and !(try canEditObject(allocator, db, role, envelope.actor_principal, "issue", envelope.object_id))) return "insufficient_role";
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
    if (std.mem.eql(u8, envelope.event_type, "issue.milestone_set") or
        std.mem.eql(u8, envelope.event_type, "issue.project_added") or
        std.mem.eql(u8, envelope.event_type, "issue.project_removed"))
    {
        return if (roleAtLeast(role, "maintainer")) null else "insufficient_role";
    }
    if (std.mem.eql(u8, envelope.event_type, "issue.project_field_set") or
        std.mem.eql(u8, envelope.event_type, "issue.project_field_cleared"))
    {
        return if (try canEditObject(allocator, db, role, envelope.actor_principal, "issue", envelope.object_id)) null else "insufficient_role";
    }
    if (std.mem.eql(u8, envelope.event_type, "issue.reaction_added") or
        std.mem.eql(u8, envelope.event_type, "issue.reaction_removed"))
    {
        return if (roleAtLeast(role, "reporter")) null else "insufficient_role";
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
        return if (try canEditObject(allocator, db, role, envelope.actor_principal, "comment", envelope.object_id)) null else "insufficient_role";
    }
    if (std.mem.eql(u8, envelope.event_type, "comment.redacted")) {
        return if (try canRedactComment(allocator, db, role, envelope.actor_principal, envelope.object_id)) null else "insufficient_role";
    }
    if (std.mem.eql(u8, envelope.event_type, "comment.reaction_added") or
        std.mem.eql(u8, envelope.event_type, "comment.reaction_removed"))
    {
        return if (roleAtLeast(role, "reporter")) null else "insufficient_role";
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
    if (!githubImportDelegatesEvent(envelope.event_type)) return "unauthorized_principal";

    const signer_fingerprint = (try git.verifiedCommitSigningKeyFingerprint(allocator, hash)) orelse return "signing_key_mismatch";
    defer allocator.free(signer_fingerprint);

    const delegated_fingerprint = (try delegationFingerprintAtAuthFrontier(
        allocator,
        db,
        envelope.actor_principal,
        envelope.actor_device,
        "github.import",
        hash,
    )) orelse return "unauthorized_principal";
    defer allocator.free(delegated_fingerprint);

    if (!std.mem.eql(u8, delegated_fingerprint, signer_fingerprint)) return "signing_key_mismatch";
    return null;
}

fn githubImportDelegatesEvent(event_type: []const u8) bool {
    return std.mem.eql(u8, event_type, "issue.opened") or
        std.mem.eql(u8, event_type, "issue.state_set") or
        std.mem.eql(u8, event_type, "issue.project_added") or
        std.mem.eql(u8, event_type, "pull.opened") or
        std.mem.eql(u8, event_type, "pull.state_set") or
        std.mem.eql(u8, event_type, "pull.merged") or
        std.mem.eql(u8, event_type, "comment.added");
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
        const actor_role = (try aclRoleAtFrontier(allocator, db, envelope.actor_principal, event_hash)) orelse return "unauthorized_principal";
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
            const owners = try countCurrentOwners(db);
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
        if (!std.mem.eql(u8, capability, "github.import")) return "unknown_capability";
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
        if (!std.mem.eql(u8, capability, "github.import")) return "unknown_capability";
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

fn aclRoleAtAuthFrontier(allocator: Allocator, db: *SqliteDb, principal: []const u8, event_hash: []const u8) !?[]u8 {
    var events = try loadAclRoleEvents(allocator, db, principal, event_hash);
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
        if (!(try eventInAuthFrontier(allocator, event_hash, before_event_hash))) {
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
    var events = try loadDelegationEvents(allocator, db, principal, device, capability, scope, null);
    defer freeDelegationEvents(allocator, &events);

    if (try activeDelegationGrantIndex(allocator, events.items)) |active_index| {
        const active = events.items[active_index];
        try replaceDelegation(db, principal, device, capability, scope, active.key_fingerprint, active.public_key, active.event_hash);
        return;
    }

    try deleteDelegation(db, principal, device, capability, scope);
}

fn delegationActiveAtFrontier(allocator: Allocator, db: *SqliteDb, principal: []const u8, device: []const u8, capability: []const u8, scope: []const u8, event_hash: []const u8) !bool {
    var events = try loadDelegationEvents(allocator, db, principal, device, capability, scope, event_hash);
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
    var events = try loadDelegationEvents(allocator, db, principal, device, capability, "github:*", before_event_hash);
    defer freeDelegationEvents(allocator, &events);
    const active_index = (try activeDelegationGrantIndex(allocator, events.items)) orelse return null;
    return try allocator.dupe(u8, events.items[active_index].key_fingerprint);
}

fn loadDelegationEvents(
    allocator: Allocator,
    db: *SqliteDb,
    principal: []const u8,
    device: []const u8,
    capability: []const u8,
    scope: []const u8,
    before_event_hash: ?[]const u8,
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
        if (!(try eventInAuthFrontier(allocator, event_hash, before_event_hash))) {
            continue;
        }

        var event_type: ?[]u8 = try stmt.columnTextDup(allocator, 1);
        errdefer if (event_type) |value| allocator.free(value);
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

fn identityDeviceFingerprintAtAuthFrontier(allocator: Allocator, db: *SqliteDb, principal: []const u8, device: []const u8, event_hash: []const u8) !?[]u8 {
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
        if (!(try eventInAuthFrontier(allocator, event_hash, before_event_hash))) {
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

test "data commit reference parser extracts unique typed hash and legacy refs" {
    var tokens: std.ArrayList(DerivedReferenceToken) = .empty;
    defer freeDerivedReferenceTokens(std.testing.allocator, &tokens);

    try collectReferenceTokens(
        std.testing.allocator,
        "Fix #A1B2C3D and refs #a1b2c3d #42 issue:0ABCDEF pr:123 #not-a-ref #abcdef0g #018f000 issue:0abcdef",
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
