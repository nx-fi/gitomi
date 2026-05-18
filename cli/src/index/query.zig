const std = @import("std");

const errors = @import("../errors.zig");
const event_mod = @import("../event.zig");
const index_event_row = @import("event_row.zig");
const index_schema = @import("schema.zig");
const io = @import("../io.zig");
const json_writer = @import("../json_writer.zig");
const projection = @import("projection.zig");
const repo_mod = @import("../repo.zig");
const sqlite_db = @import("sqlite_db.zig");
const util = @import("../util.zig");

pub const index_event_columns = "ref, \"commit\", event_hash, tree, subject, empty_tree, valid_json, event_type, object_kind, object_id, actor_principal, actor_device, seq, occurred_at, domain_status, rejection_reason, body";

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const Repo = repo_mod.Repo;
const SqliteDb = sqlite_db.SqliteDb;
const sqlite = sqlite_db.sqlite;
const appendIndexedEventJson = index_event_row.appendIndexedEventJson;
const appendJsonFieldBool = json_writer.appendJsonFieldBool;
const appendJsonFieldInteger = json_writer.appendJsonFieldInteger;
const appendJsonFieldString = json_writer.appendJsonFieldString;
const appendJsonString = json_writer.appendJsonString;
const eprint = io.eprint;
const fileExists = util.fileExists;
const freeIndexedEvent = index_event_row.freeIndexedEvent;
const indexedEventFromStmt = index_event_row.indexedEventFromStmt;
const out = io.out;
const parseValidatedEnvelopeObject = event_mod.parseValidatedEnvelopeObject;
const validateEnvelopeObject = event_mod.validateEnvelopeObject;
const printIndexedEvent = index_event_row.printIndexedEvent;

pub const CommentParentInfo = struct {
    allocator: Allocator,
    parent_kind: []u8,
    parent_id: []u8,
    add_hash: []u8,

    pub fn deinit(self: *CommentParentInfo) void {
        self.allocator.free(self.parent_kind);
        self.allocator.free(self.parent_id);
        self.allocator.free(self.add_hash);
    }
};

pub fn countIndexedEvents(allocator: Allocator, repo: Repo) !usize {
    if (!fileExists(repo.index_path)) return 0;
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    return countIndexedEventsInDb(&db);
}

pub fn countIssueOpenedEvents(allocator: Allocator, repo: Repo) !usize {
    if (!fileExists(repo.index_path)) return 0;
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var stmt = try db.prepare("SELECT COUNT(*) FROM issues");
    defer stmt.deinit();
    if (!try stmt.step()) return 0;
    const count = stmt.columnInt64(0);
    return if (count <= 0) 0 else @as(usize, @intCast(count));
}

pub fn countOpenIssues(allocator: Allocator, repo: Repo) !usize {
    if (!fileExists(repo.index_path)) return 0;
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var stmt = try db.prepare("SELECT COUNT(*) FROM issues WHERE state = 'open'");
    defer stmt.deinit();
    if (!try stmt.step()) return 0;
    const count = stmt.columnInt64(0);
    return if (count <= 0) 0 else @as(usize, @intCast(count));
}

pub fn countPulls(allocator: Allocator, repo: Repo) !usize {
    if (!fileExists(repo.index_path)) return 0;
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var stmt = try db.prepare("SELECT COUNT(*) FROM pulls");
    defer stmt.deinit();
    if (!try stmt.step()) return 0;
    const count = stmt.columnInt64(0);
    return if (count <= 0) 0 else @as(usize, @intCast(count));
}

pub fn countOpenPulls(allocator: Allocator, repo: Repo) !usize {
    if (!fileExists(repo.index_path)) return 0;
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var stmt = try db.prepare("SELECT COUNT(*) FROM pulls WHERE state = 'open'");
    defer stmt.deinit();
    if (!try stmt.step()) return 0;
    const count = stmt.columnInt64(0);
    return if (count <= 0) 0 else @as(usize, @intCast(count));
}

pub fn countIndexedEventsInDb(db: *SqliteDb) !usize {
    var stmt = try db.prepare("SELECT COUNT(*) FROM events");
    defer stmt.deinit();
    if (!try stmt.step()) return 0;
    const count = stmt.columnInt64(0);
    return if (count <= 0) 0 else @as(usize, @intCast(count));
}

pub fn requireAuthorizedWrite(allocator: Allocator, repo: Repo, event_body: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, event_body, .{}) catch {
        try eprint("gt: refusing to create invalid event envelope: event body is not valid JSON\n", .{});
        return CliError.InvalidEvent;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => {
            try eprint("gt: refusing to create invalid event envelope: event body must be a JSON object\n", .{});
            return CliError.InvalidEvent;
        },
    };

    if (try validateEnvelopeObject(allocator, root)) |message| {
        defer allocator.free(message);
        try eprint("gt: refusing to create invalid event envelope: {s}\n", .{message});
        return CliError.InvalidEvent;
    }

    var envelope = parseValidatedEnvelopeObject(allocator, root) catch {
        try eprint("gt: refusing to create invalid event envelope: parser rejected validated envelope\n", .{});
        return CliError.InvalidEvent;
    };
    defer envelope.deinit();

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    if ((try accessModeFromDb(allocator, &db)) == .open and !(try openLocalActorAuthorized(allocator, &db, envelope, event_body))) {
        try eprint("gt: refusing to create unauthorized event: unauthorized_device\n", .{});
        return CliError.Unauthorized;
    }
    if (try projection.authorizationRejection(allocator, &db, null, envelope, event_body)) |reason| {
        if (std.mem.eql(u8, reason, "unauthorized_principal") and try localDelegationAuthorizesWrite(allocator, repo, envelope)) {
            return;
        }
        if (localDomainRejectionCanBeAudited(envelope.event_type, reason)) {
            return;
        }
        try eprint("gt: refusing to create unauthorized event: {s}\n", .{reason});
        return CliError.Unauthorized;
    }
}

fn openLocalActorAuthorized(allocator: Allocator, db: *SqliteDb, envelope: event_mod.ValidatedEnvelope, event_body: []const u8) !bool {
    var signing_key = repo_mod.configuredSigningKey(allocator) catch return false;
    defer signing_key.deinit();

    if (try projection.currentDeviceFingerprint(allocator, db, envelope.actor_principal, envelope.actor_device)) |expected_fingerprint| {
        defer allocator.free(expected_fingerprint);
        return std.mem.eql(u8, expected_fingerprint, signing_key.fingerprint);
    }

    if (!std.mem.eql(u8, envelope.event_type, "identity.device_added")) return false;
    const expected_fingerprint = (try projection.selfRegistrationFingerprint(allocator, envelope, event_body)) orelse return false;
    defer allocator.free(expected_fingerprint);
    return std.mem.eql(u8, expected_fingerprint, signing_key.fingerprint);
}

fn localDomainRejectionCanBeAudited(event_type: []const u8, reason: []const u8) bool {
    if (std.mem.startsWith(u8, event_type, "acl.") or std.mem.startsWith(u8, event_type, "identity.")) return false;
    return std.mem.eql(u8, reason, "insufficient_role") or std.mem.eql(u8, reason, "unauthorized_principal");
}

fn localDelegationAuthorizesWrite(allocator: Allocator, repo: Repo, envelope: event_mod.ValidatedEnvelope) !bool {
    if (!projection.importDelegatesEvent(envelope.event_type)) return false;

    var signing_key = repo_mod.configuredSigningKey(allocator) catch return false;
    defer signing_key.deinit();
    return try hasActiveDelegation(allocator, repo, envelope.actor_principal, envelope.actor_device, "github.import", "github:*", signing_key.fingerprint) or
        try hasActiveDelegation(allocator, repo, envelope.actor_principal, envelope.actor_device, "gitlab.import", "gitlab:*", signing_key.fingerprint);
}

pub fn roleForPrincipal(allocator: Allocator, repo: Repo, principal: []const u8) !?[]u8 {
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    return try projection.currentRole(allocator, &db, principal);
}

pub fn countOwners(allocator: Allocator, repo: Repo) !usize {
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    return try projection.countCurrentOwners(&db);
}

pub fn effectiveWriteRoleForPrincipal(allocator: Allocator, repo: Repo, principal: []const u8) !?[]u8 {
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    if ((try accessModeFromDb(allocator, &db)) == .open) return try allocator.dupe(u8, "owner");
    return try projection.currentRole(allocator, &db, principal);
}

pub fn actorDeviceAuthorizedForWrite(allocator: Allocator, repo: Repo, principal: []const u8, device: []const u8) !bool {
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    if ((try accessModeFromDb(allocator, &db)) == .open) return true;
    return try projection.currentDeviceActive(&db, principal, device);
}

pub fn isIdentityDeviceActive(allocator: Allocator, repo: Repo, principal: []const u8, device: []const u8) !bool {
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    return try projection.currentDeviceActive(&db, principal, device);
}

pub fn hasActiveDelegation(
    allocator: Allocator,
    repo: Repo,
    principal: []const u8,
    device: []const u8,
    capability: []const u8,
    scope: []const u8,
    fingerprint: []const u8,
) !bool {
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var stmt = try db.prepare(
        \\SELECT 1
        \\FROM acl_delegations
        \\WHERE principal = ?
        \\  AND device = ?
        \\  AND capability = ?
        \\  AND scope = ?
        \\  AND key_fingerprint = ?
        \\LIMIT 1
    );
    defer stmt.deinit();
    try stmt.bindText(1, principal);
    try stmt.bindText(2, device);
    try stmt.bindText(3, capability);
    try stmt.bindText(4, scope);
    try stmt.bindText(5, fingerprint);
    return try stmt.step();
}

pub fn authRelatedEventHashes(allocator: Allocator, repo: Repo, principal: []const u8, device: []const u8) ![][]u8 {
    if (!fileExists(repo.index_path)) return try allocator.alloc([]u8, 0);
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    var hashes: std.ArrayList([]u8) = .empty;
    errdefer {
        for (hashes.items) |hash| allocator.free(hash);
        hashes.deinit(allocator);
    }

    try appendSingleHashQuery(
        allocator,
        &db,
        &hashes,
        "SELECT grant_event_hash FROM acl_roles WHERE principal = ?",
        &.{principal},
    );
    try appendSingleHashQuery(
        allocator,
        &db,
        &hashes,
        "SELECT grant_event_hash FROM acl_delegations WHERE principal = ? AND device = ?",
        &.{ principal, device },
    );
    try appendSingleHashQuery(
        allocator,
        &db,
        &hashes,
        "SELECT added_event_hash FROM identity_devices WHERE principal = ? AND device = ? AND revoked_event_hash IS NULL",
        &.{ principal, device },
    );

    return try hashes.toOwnedSlice(allocator);
}

fn appendSingleHashQuery(
    allocator: Allocator,
    db: *SqliteDb,
    hashes: *std.ArrayList([]u8),
    comptime sql_text: []const u8,
    params: []const []const u8,
) !void {
    var stmt = try db.prepare(sql_text);
    defer stmt.deinit();
    for (params, 0..) |param, idx| try stmt.bindText(@intCast(idx + 1), param);
    if (!(try stmt.step())) return;
    const hash = try stmt.columnTextDup(allocator, 0);
    errdefer allocator.free(hash);
    if (hash.len == 0) return;
    for (hashes.items) |existing| {
        if (std.mem.eql(u8, existing, hash)) {
            allocator.free(hash);
            return;
        }
    }
    try hashes.append(allocator, hash);
}

fn accessModeFromDb(allocator: Allocator, db: *SqliteDb) !repo_mod.AccessMode {
    var stmt = try db.prepare("SELECT value FROM meta WHERE key = 'access_mode'");
    defer stmt.deinit();
    if (!(try stmt.step())) return .closed;
    const value = try stmt.columnTextDup(allocator, 0);
    defer allocator.free(value);
    return repo_mod.parseAccessMode(value) orelse .closed;
}

pub fn listAclFromIndex(allocator: Allocator, repo: Repo, json: bool) !void {
    if (!fileExists(repo.index_path)) return;
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    var stmt = try db.prepare("SELECT principal, role, grant_event_hash FROM acl_roles ORDER BY principal");
    defer stmt.deinit();
    while (try stmt.step()) {
        const principal = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(principal);
        const role = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(role);
        const grant_event_hash = try stmt.columnTextDup(allocator, 2);
        defer allocator.free(grant_event_hash);
        if (json) {
            var line: std.ArrayList(u8) = .empty;
            defer line.deinit(allocator);
            try line.append(allocator, '{');
            try appendJsonFieldString(&line, allocator, "principal", principal, true);
            try appendJsonFieldString(&line, allocator, "role", role, true);
            try appendJsonFieldString(&line, allocator, "grant_event_hash", grant_event_hash, false);
            try line.append(allocator, '}');
            try out("{s}\n", .{line.items});
        } else {
            try out("{s}\t{s}\n", .{ principal, role });
        }
    }
}

pub fn listIdentityFromIndex(allocator: Allocator, repo: Repo, json: bool) !void {
    if (!fileExists(repo.index_path)) return;
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    var stmt = try db.prepare(
        \\SELECT principal, device, key_fingerprint, public_key, added_event_hash, revoked_event_hash
        \\FROM identity_devices
        \\ORDER BY principal, device, key_fingerprint
    );
    defer stmt.deinit();
    while (try stmt.step()) {
        const principal = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(principal);
        const device = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(device);
        const fingerprint = try stmt.columnTextDup(allocator, 2);
        defer allocator.free(fingerprint);
        const public_key = try stmt.columnTextDup(allocator, 3);
        defer allocator.free(public_key);
        const added_event_hash = try stmt.columnTextDup(allocator, 4);
        defer allocator.free(added_event_hash);
        const revoked_event_hash = try stmt.columnTextDup(allocator, 5);
        defer allocator.free(revoked_event_hash);
        const active = revoked_event_hash.len == 0;
        if (json) {
            var line: std.ArrayList(u8) = .empty;
            defer line.deinit(allocator);
            try line.append(allocator, '{');
            try appendJsonFieldString(&line, allocator, "principal", principal, true);
            try appendJsonFieldString(&line, allocator, "device", device, true);
            try appendJsonFieldString(&line, allocator, "key_fingerprint", fingerprint, true);
            try appendJsonFieldString(&line, allocator, "public_key", public_key, true);
            try appendJsonFieldString(&line, allocator, "added_event_hash", added_event_hash, true);
            try appendJsonFieldString(&line, allocator, "revoked_event_hash", revoked_event_hash, true);
            try appendJsonFieldBool(&line, allocator, "active", active, false);
            try line.append(allocator, '}');
            try out("{s}\n", .{line.items});
        } else {
            try out("{s}/{s}\t{s}\t{s}\n", .{ principal, device, if (active) "active" else "revoked", fingerprint });
        }
    }
}

pub fn resolveIssueId(allocator: Allocator, repo: Repo, raw_ref: []const u8) ![]u8 {
    if (parseExplicitLegacyGithubNumber(raw_ref)) |number| {
        if (try lookupLegacyGithubObjectId(allocator, repo, "issue", number)) |id| return id;
        try eprint("gt issue: no issue has GitHub legacy number #{d}\n", .{number});
        return CliError.NotFound;
    }
    if (parseExplicitLegacyGitlabNumber(raw_ref)) |number| {
        if (try lookupLegacyGitlabObjectId(allocator, repo, "issue", number)) |id| return id;
        try eprint("gt issue: no issue has GitLab legacy IID #{d}\n", .{number});
        return CliError.NotFound;
    }

    const value = issueRefValue(raw_ref);

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    if (util.looksLikeUuid(value)) {
        if (try lookupExactObjectIdInDb(allocator, &db, "issues", value)) |id| return id;
        try eprint("gt issue: no issue matches {s}\n", .{value});
        return CliError.NotFound;
    }

    if (util.isObjectRefPrefix(value)) {
        if (try lookupObjectIdByHashRefInDb(allocator, &db, "issues", "issue", value)) |id| return id;
        if (parsePositiveDecimal(value)) |number| {
            if (try lookupLegacyGithubObjectIdInDb(allocator, &db, "issue", number)) |id| return id;
            if (try lookupLegacyProviderObjectIdInDb(allocator, &db, "gitlab", "issue", number)) |id| return id;
        }
        try eprint("gt issue: no issue matches #{s}\n", .{value});
        return CliError.NotFound;
    }

    if (parsePositiveDecimal(value)) |number| {
        if (try lookupLegacyGithubObjectIdInDb(allocator, &db, "issue", number)) |id| return id;
        if (try lookupLegacyProviderObjectIdInDb(allocator, &db, "gitlab", "issue", number)) |id| return id;
        try eprint("gt issue: no issue has GitHub or GitLab legacy number #{d}\n", .{number});
        return CliError.NotFound;
    }

    try eprint("gt issue: issue reference must be a 7+ hex hash alias, full UUID, or GitHub/GitLab number\n", .{});
    return CliError.InvalidReference;
}

pub fn resolvePullId(allocator: Allocator, repo: Repo, raw_ref: []const u8) ![]u8 {
    if (parseExplicitLegacyGithubNumber(raw_ref)) |number| {
        if (try lookupLegacyGithubObjectId(allocator, repo, "pull", number)) |id| return id;
        try eprint("gt pr: no PR has GitHub legacy number #{d}\n", .{number});
        return CliError.NotFound;
    }
    if (parseExplicitLegacyGitlabNumber(raw_ref)) |number| {
        if (try lookupLegacyGitlabObjectId(allocator, repo, "pull", number)) |id| return id;
        try eprint("gt pr: no PR has GitLab legacy IID !{d}\n", .{number});
        return CliError.NotFound;
    }

    const value = pullRefValue(raw_ref);

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    if (util.looksLikeUuid(value)) {
        if (try lookupExactObjectIdInDb(allocator, &db, "pulls", value)) |id| return id;
        try eprint("gt pr: no PR matches {s}\n", .{value});
        return CliError.NotFound;
    }

    if (util.isObjectRefPrefix(value)) {
        if (try lookupObjectIdByHashRefInDb(allocator, &db, "pulls", "PR", value)) |id| return id;
        if (parsePositiveDecimal(value)) |number| {
            if (try lookupLegacyGithubObjectIdInDb(allocator, &db, "pull", number)) |id| return id;
            if (try lookupLegacyProviderObjectIdInDb(allocator, &db, "gitlab", "pull", number)) |id| return id;
        }
        try eprint("gt pr: no PR matches #{s}\n", .{value});
        return CliError.NotFound;
    }

    if (parsePositiveDecimal(value)) |number| {
        if (try lookupLegacyGithubObjectIdInDb(allocator, &db, "pull", number)) |id| return id;
        if (try lookupLegacyProviderObjectIdInDb(allocator, &db, "gitlab", "pull", number)) |id| return id;
        try eprint("gt pr: no PR has GitHub or GitLab legacy number #{d}\n", .{number});
        return CliError.NotFound;
    }

    try eprint("gt pr: PR reference must be a 7+ hex hash alias, full UUID, or GitHub/GitLab number\n", .{});
    return CliError.InvalidReference;
}

pub fn resolveProjectId(allocator: Allocator, repo: Repo, raw_ref: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw_ref, " \t\r\n");
    const value = if (std.mem.startsWith(u8, trimmed, "project:"))
        trimmed["project:".len..]
    else if (std.mem.startsWith(u8, trimmed, "@"))
        trimmed[1..]
    else
        trimmed;
    if (value.len == 0) {
        try eprint("gt project: project reference must not be empty\n", .{});
        return CliError.InvalidReference;
    }

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    if (isUuidPrefix(value)) {
        if (try resolveProjectIdByColumn(allocator, &db, "id", value, raw_ref)) |id| return id;
    }
    if (try resolveProjectIdByColumn(allocator, &db, "slug", value, raw_ref)) |id| return id;
    if (try resolveProjectIdByColumn(allocator, &db, "name", value, raw_ref)) |id| return id;

    try eprint("gt project: no project matches {s}\n", .{value});
    return CliError.NotFound;
}

fn resolveProjectIdByColumn(
    allocator: Allocator,
    db: *SqliteDb,
    comptime column: []const u8,
    value: []const u8,
    raw_ref: []const u8,
) !?[]u8 {
    const sql = if (std.mem.eql(u8, column, "id"))
        "SELECT id FROM projects WHERE id LIKE ? ORDER BY id LIMIT 2"
    else
        "SELECT id FROM projects WHERE " ++ column ++ " = ? ORDER BY id LIMIT 2";
    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    if (std.mem.eql(u8, column, "id")) {
        const pattern = try std.fmt.allocPrint(allocator, "{s}%", .{value});
        defer allocator.free(pattern);
        try stmt.bindText(1, pattern);
    } else {
        try stmt.bindText(1, value);
    }
    if (!(try stmt.step())) return null;
    const first = try stmt.columnTextDup(allocator, 0);
    errdefer allocator.free(first);
    if (try stmt.step()) {
        const second = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(second);
        try eprint("gt project: ambiguous project reference {s} matches {s} and {s}\n", .{ raw_ref, first, second });
        return CliError.AmbiguousReference;
    }
    return first;
}

pub const ProjectColumnRef = struct {
    column: []u8,
    column_ref: []u8,

    pub fn deinit(self: *ProjectColumnRef, allocator: Allocator) void {
        allocator.free(self.column);
        allocator.free(self.column_ref);
    }
};

pub fn resolveProjectColumnRef(allocator: Allocator, repo: Repo, project_id: []const u8, raw_ref: []const u8) !ProjectColumnRef {
    const value = std.mem.trim(u8, raw_ref, " \t\r\n");
    if (value.len == 0) {
        try eprint("gt project: project column reference must not be empty\n", .{});
        return CliError.InvalidReference;
    }

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    if (try resolveProjectColumnByColumn(allocator, &db, project_id, "column_ref", value)) |resolved| return resolved;
    if (try resolveProjectColumnByColumn(allocator, &db, project_id, "column_name", value)) |resolved| return resolved;
    try eprint("gt project: no column matches {s}\n", .{value});
    return CliError.NotFound;
}

fn resolveProjectColumnByColumn(
    allocator: Allocator,
    db: *SqliteDb,
    project_id: []const u8,
    comptime column: []const u8,
    value: []const u8,
) !?ProjectColumnRef {
    var stmt = try db.prepare("SELECT column_name, column_ref FROM project_columns WHERE project_id = ? AND " ++ column ++ " = ? ORDER BY add_hash DESC LIMIT 1");
    defer stmt.deinit();
    try stmt.bindText(1, project_id);
    try stmt.bindText(2, value);
    if (!(try stmt.step())) return null;
    const column_name = try stmt.columnTextDup(allocator, 0);
    errdefer allocator.free(column_name);
    return .{
        .column = column_name,
        .column_ref = try stmt.columnTextDup(allocator, 1),
    };
}

pub fn resolveProjectFieldId(allocator: Allocator, repo: Repo, project_id: []const u8, raw_ref: []const u8) ![]u8 {
    const value = projectChildRefValue(raw_ref, "field:");
    if (value.len == 0) {
        try eprint("gt project field: field reference must not be empty\n", .{});
        return CliError.InvalidReference;
    }
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    if (isUuidPrefix(value)) {
        if (try resolveProjectChildId(allocator, &db, "project_fields", "id", project_id, value, raw_ref)) |id| return id;
    }
    if (try resolveProjectChildId(allocator, &db, "project_fields", "key", project_id, value, raw_ref)) |id| return id;
    if (try resolveProjectChildId(allocator, &db, "project_fields", "name", project_id, value, raw_ref)) |id| return id;
    try eprint("gt project field: no field matches {s}\n", .{value});
    return CliError.NotFound;
}

pub fn resolveProjectFieldOptionId(allocator: Allocator, repo: Repo, project_id: []const u8, field_id: []const u8, raw_ref: []const u8) ![]u8 {
    const value = projectChildRefValue(raw_ref, "option:");
    if (value.len == 0) {
        try eprint("gt project field-option: option reference must not be empty\n", .{});
        return CliError.InvalidReference;
    }
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    if (isUuidPrefix(value)) {
        if (try resolveProjectFieldOptionByColumn(allocator, &db, project_id, field_id, "id", value, raw_ref)) |id| return id;
    }
    if (try resolveProjectFieldOptionByColumn(allocator, &db, project_id, field_id, "name", value, raw_ref)) |id| return id;
    try eprint("gt project field-option: no option matches {s}\n", .{value});
    return CliError.NotFound;
}

pub fn resolveProjectViewId(allocator: Allocator, repo: Repo, project_id: []const u8, raw_ref: []const u8) ![]u8 {
    const value = projectChildRefValue(raw_ref, "view:");
    if (value.len == 0) {
        try eprint("gt project view: view reference must not be empty\n", .{});
        return CliError.InvalidReference;
    }
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    if (isUuidPrefix(value)) {
        if (try resolveProjectChildId(allocator, &db, "project_views", "id", project_id, value, raw_ref)) |id| return id;
    }
    if (try resolveProjectChildId(allocator, &db, "project_views", "name", project_id, value, raw_ref)) |id| return id;
    try eprint("gt project view: no view matches {s}\n", .{value});
    return CliError.NotFound;
}

fn projectChildRefValue(raw_ref: []const u8, prefix: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw_ref, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, prefix)) return trimmed[prefix.len..];
    if (std.mem.startsWith(u8, trimmed, "@")) return trimmed[1..];
    return trimmed;
}

fn resolveProjectChildId(
    allocator: Allocator,
    db: *SqliteDb,
    comptime table: []const u8,
    comptime column: []const u8,
    project_id: []const u8,
    value: []const u8,
    raw_ref: []const u8,
) !?[]u8 {
    const sql = if (std.mem.eql(u8, column, "id"))
        "SELECT id FROM " ++ table ++ " WHERE project_id = ? AND id LIKE ? AND state != 'removed' ORDER BY id LIMIT 2"
    else
        "SELECT id FROM " ++ table ++ " WHERE project_id = ? AND " ++ column ++ " = ? AND state != 'removed' ORDER BY id LIMIT 2";
    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    try stmt.bindText(1, project_id);
    if (std.mem.eql(u8, column, "id")) {
        const pattern = try std.fmt.allocPrint(allocator, "{s}%", .{value});
        defer allocator.free(pattern);
        try stmt.bindText(2, pattern);
    } else {
        try stmt.bindText(2, value);
    }
    return try uniqueIdFromStmt(allocator, &stmt, raw_ref);
}

fn resolveProjectFieldOptionByColumn(
    allocator: Allocator,
    db: *SqliteDb,
    project_id: []const u8,
    field_id: []const u8,
    comptime column: []const u8,
    value: []const u8,
    raw_ref: []const u8,
) !?[]u8 {
    const sql = if (std.mem.eql(u8, column, "id"))
        "SELECT id FROM project_field_options WHERE project_id = ? AND field_id = ? AND id LIKE ? AND state != 'removed' ORDER BY id LIMIT 2"
    else
        "SELECT id FROM project_field_options WHERE project_id = ? AND field_id = ? AND " ++ column ++ " = ? AND state != 'removed' ORDER BY id LIMIT 2";
    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    try stmt.bindText(1, project_id);
    try stmt.bindText(2, field_id);
    if (std.mem.eql(u8, column, "id")) {
        const pattern = try std.fmt.allocPrint(allocator, "{s}%", .{value});
        defer allocator.free(pattern);
        try stmt.bindText(3, pattern);
    } else {
        try stmt.bindText(3, value);
    }
    return try uniqueIdFromStmt(allocator, &stmt, raw_ref);
}

fn uniqueIdFromStmt(allocator: Allocator, stmt: *sqlite_db.SqliteStmt, raw_ref: []const u8) !?[]u8 {
    if (!(try stmt.step())) return null;
    const first = try stmt.columnTextDup(allocator, 0);
    errdefer allocator.free(first);
    if (try stmt.step()) {
        const second = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(second);
        try eprint("gt project: ambiguous reference {s} matches {s} and {s}\n", .{ raw_ref, first, second });
        return CliError.AmbiguousReference;
    }
    return first;
}

pub fn projectNameForId(allocator: Allocator, repo: Repo, project_id: []const u8) ![]u8 {
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var stmt = try db.prepare("SELECT name FROM projects WHERE id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, project_id);
    if (!(try stmt.step())) {
        try eprint("gt project: no project matches {s}\n", .{project_id});
        return CliError.NotFound;
    }
    return try stmt.columnTextDup(allocator, 0);
}

pub fn resolveMilestoneId(allocator: Allocator, repo: Repo, raw_ref: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw_ref, " \t\r\n");
    const typed_uuid_ref = std.mem.startsWith(u8, trimmed, "milestone:");
    const value = if (typed_uuid_ref)
        trimmed["milestone:".len..]
    else if (std.mem.startsWith(u8, trimmed, "#"))
        trimmed[1..]
    else if (std.mem.startsWith(u8, trimmed, "^"))
        trimmed[1..]
    else
        trimmed;
    if (value.len == 0) {
        try eprint("gt milestone: milestone reference must not be empty\n", .{});
        return CliError.InvalidReference;
    }

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    if (typed_uuid_ref and !isUuidPrefix(value)) {
        try eprint("gt milestone: milestone:<uuid-prefix> requires a 7+ hex UUID prefix\n", .{});
        return CliError.InvalidReference;
    }

    if (util.looksLikeUuid(value)) {
        if (try lookupExactObjectIdInDb(allocator, &db, "milestones", value)) |id| return id;
        try eprint("gt milestone: no milestone matches {s}\n", .{value});
        return CliError.NotFound;
    }

    if (!typed_uuid_ref and util.isObjectRefPrefix(value)) {
        if (try lookupObjectIdByHashRefInDb(allocator, &db, "milestones", "milestone", value)) |id| return id;
    }

    if (typed_uuid_ref or isUuidPrefix(value)) {
        const pattern = try std.fmt.allocPrint(allocator, "{s}%", .{value});
        defer allocator.free(pattern);
        var stmt = try db.prepare("SELECT id FROM milestones WHERE id LIKE ? ORDER BY id LIMIT 2");
        defer stmt.deinit();
        try stmt.bindText(1, pattern);
        if (try stmt.step()) {
            const first = try stmt.columnTextDup(allocator, 0);
            errdefer allocator.free(first);
            if (try stmt.step()) {
                const second = try stmt.columnTextDup(allocator, 0);
                defer allocator.free(second);
                try eprint("gt milestone: ambiguous milestone reference {s} matches {s} and {s}\n", .{ raw_ref, first, second });
                return CliError.AmbiguousReference;
            }
            return first;
        }
        if (typed_uuid_ref) {
            try eprint("gt milestone: no milestone matches {s}\n", .{raw_ref});
            return CliError.NotFound;
        }
    }

    var stmt = try db.prepare("SELECT id FROM milestones WHERE title = ? ORDER BY id LIMIT 2");
    defer stmt.deinit();
    try stmt.bindText(1, value);
    if (!(try stmt.step())) {
        try eprint("gt milestone: no milestone named {s}\n", .{value});
        return CliError.NotFound;
    }
    const first = try stmt.columnTextDup(allocator, 0);
    errdefer allocator.free(first);
    if (try stmt.step()) {
        const second = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(second);
        try eprint("gt milestone: ambiguous milestone name {s} matches {s} and {s}\n", .{ value, first, second });
        return CliError.AmbiguousReference;
    }
    return first;
}

fn isUuidPrefix(value: []const u8) bool {
    if (value.len < 7) return false;
    for (value) |c| {
        if (!std.ascii.isHex(c) and c != '-') return false;
    }
    return true;
}

fn issueRefValue(raw_ref: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw_ref, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "issue:")) return trimmed["issue:".len..];
    if (std.mem.startsWith(u8, trimmed, "#")) return trimmed[1..];
    return trimmed;
}

fn pullRefValue(raw_ref: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw_ref, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "pull:")) return trimmed["pull:".len..];
    if (std.mem.startsWith(u8, trimmed, "pr:")) return trimmed["pr:".len..];
    if (std.mem.startsWith(u8, trimmed, "#")) return trimmed[1..];
    return trimmed;
}

fn parseExplicitLegacyGithubNumber(raw_ref: []const u8) ?i64 {
    const trimmed = std.mem.trim(u8, raw_ref, " \t\r\n");
    const value = if (std.mem.startsWith(u8, trimmed, "github#"))
        trimmed["github#".len..]
    else if (std.mem.startsWith(u8, trimmed, "github:"))
        trimmed["github:".len..]
    else if (std.mem.startsWith(u8, trimmed, "gh#"))
        trimmed["gh#".len..]
    else if (std.mem.startsWith(u8, trimmed, "gh:"))
        trimmed["gh:".len..]
    else
        return null;
    return parsePositiveDecimal(value);
}

fn parseExplicitLegacyGitlabNumber(raw_ref: []const u8) ?i64 {
    const trimmed = std.mem.trim(u8, raw_ref, " \t\r\n");
    const value = if (std.mem.startsWith(u8, trimmed, "gitlab#"))
        trimmed["gitlab#".len..]
    else if (std.mem.startsWith(u8, trimmed, "gitlab:"))
        trimmed["gitlab:".len..]
    else if (std.mem.startsWith(u8, trimmed, "gl#"))
        trimmed["gl#".len..]
    else if (std.mem.startsWith(u8, trimmed, "gl:"))
        trimmed["gl:".len..]
    else
        return null;
    return parsePositiveDecimal(value);
}

fn parsePositiveDecimal(value: []const u8) ?i64 {
    if (value.len == 0) return null;
    for (value) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    const number = std.fmt.parseInt(i64, value, 10) catch return null;
    return if (number > 0) number else null;
}

fn lookupExactObjectIdInDb(allocator: Allocator, db: *SqliteDb, comptime table: []const u8, object_id: []const u8) !?[]u8 {
    var stmt = try db.prepare("SELECT id FROM " ++ table ++ " WHERE id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, object_id);
    if (!(try stmt.step())) return null;
    return try stmt.columnTextDup(allocator, 0);
}

fn lookupObjectIdByHashRefInDb(
    allocator: Allocator,
    db: *SqliteDb,
    comptime table: []const u8,
    noun: []const u8,
    raw_prefix: []const u8,
) !?[]u8 {
    var prefix = try allocator.alloc(u8, raw_prefix.len);
    defer allocator.free(prefix);
    for (raw_prefix, 0..) |c, i| prefix[i] = std.ascii.toLower(c);

    var stmt = try db.prepare("SELECT id FROM " ++ table ++ " ORDER BY id");
    defer stmt.deinit();

    var first: ?[]u8 = null;
    errdefer if (first) |value| allocator.free(value);
    while (try stmt.step()) {
        const id = try stmt.columnTextDup(allocator, 0);
        errdefer allocator.free(id);

        var ref_buf: [util.max_object_ref_len]u8 = undefined;
        const object_ref = util.objectRefPrefix(ref_buf[0..prefix.len], id);
        if (!std.mem.eql(u8, object_ref, prefix)) {
            allocator.free(id);
            continue;
        }

        if (first) |first_id| {
            const display_len = @min(util.max_object_ref_len, @max(prefix.len + 5, 12));
            var first_ref_buf: [util.max_object_ref_len]u8 = undefined;
            var second_ref_buf: [util.max_object_ref_len]u8 = undefined;
            const first_ref = util.objectRefPrefix(first_ref_buf[0..display_len], first_id);
            const second_ref = util.objectRefPrefix(second_ref_buf[0..display_len], id);
            try eprint("gt: ambiguous {s} reference #{s} matches #{s} ({s}) and #{s} ({s})\n", .{ noun, prefix, first_ref, first_id, second_ref, id });
            allocator.free(first_id);
            allocator.free(id);
            first = null;
            return CliError.AmbiguousReference;
        }

        first = id;
    }

    const result = first orelse return null;
    first = null;
    return result;
}

pub fn lookupLegacyGithubObjectId(allocator: Allocator, repo: Repo, object_kind: []const u8, number: i64) !?[]u8 {
    return try lookupLegacyProviderObjectId(allocator, repo, "github", object_kind, number);
}

pub fn lookupLegacyGitlabObjectId(allocator: Allocator, repo: Repo, object_kind: []const u8, number: i64) !?[]u8 {
    return try lookupLegacyProviderObjectId(allocator, repo, "gitlab", object_kind, number);
}

pub fn lookupLegacyProviderObjectId(allocator: Allocator, repo: Repo, provider: []const u8, object_kind: []const u8, number: i64) !?[]u8 {
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    return try lookupLegacyProviderObjectIdInDb(allocator, &db, provider, object_kind, number);
}

fn lookupLegacyGithubObjectIdInDb(allocator: Allocator, db: *SqliteDb, object_kind: []const u8, number: i64) !?[]u8 {
    return try lookupLegacyProviderObjectIdInDb(allocator, db, "github", object_kind, number);
}

fn lookupLegacyProviderObjectIdInDb(allocator: Allocator, db: *SqliteDb, provider: []const u8, object_kind: []const u8, number: i64) !?[]u8 {
    var stmt = try db.prepare(
        \\SELECT object_id
        \\FROM legacy_aliases
        \\WHERE provider = ? AND object_kind = ? AND number = ?
    );
    defer stmt.deinit();
    try stmt.bindText(1, provider);
    try stmt.bindText(2, object_kind);
    try stmt.bindInt64(3, number);
    if (!(try stmt.step())) return null;
    return try stmt.columnTextDup(allocator, 0);
}

pub fn legacyGithubNumberForObject(allocator: Allocator, repo: Repo, object_kind: []const u8, object_id: []const u8) !?i64 {
    return try legacyProviderNumberForObject(allocator, repo, "github", object_kind, object_id);
}

pub fn legacyGitlabNumberForObject(allocator: Allocator, repo: Repo, object_kind: []const u8, object_id: []const u8) !?i64 {
    return try legacyProviderNumberForObject(allocator, repo, "gitlab", object_kind, object_id);
}

pub fn legacyProviderNumberForObject(allocator: Allocator, repo: Repo, provider: []const u8, object_kind: []const u8, object_id: []const u8) !?i64 {
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    return try legacyProviderNumberForObjectInDb(&db, provider, object_kind, object_id);
}

fn legacyGithubNumberForObjectInDb(db: *SqliteDb, object_kind: []const u8, object_id: []const u8) !?i64 {
    return try legacyProviderNumberForObjectInDb(db, "github", object_kind, object_id);
}

fn legacyProviderNumberForObjectInDb(db: *SqliteDb, provider: []const u8, object_kind: []const u8, object_id: []const u8) !?i64 {
    var stmt = try db.prepare(
        \\SELECT number
        \\FROM legacy_aliases
        \\WHERE provider = ? AND object_kind = ? AND object_id = ?
    );
    defer stmt.deinit();
    try stmt.bindText(1, provider);
    try stmt.bindText(2, object_kind);
    try stmt.bindText(3, object_id);
    if (!(try stmt.step())) return null;
    return stmt.columnInt64(0);
}

pub fn resolveCommentId(allocator: Allocator, repo: Repo, raw_ref: []const u8) ![]u8 {
    const prefix = commentRefValue(raw_ref);
    if (prefix.len < 7) {
        try eprint("gt comment: comment reference must be at least 7 hex characters\n", .{});
        return CliError.InvalidReference;
    }
    for (prefix) |c| {
        if (!std.ascii.isHex(c) and c != '-') {
            try eprint("gt comment: comment reference must be a UUID or UUID prefix\n", .{});
            return CliError.InvalidReference;
        }
    }

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    if (util.looksLikeUuid(prefix)) {
        if (try lookupExactObjectIdInDb(allocator, &db, "comments", prefix)) |id| return id;
    }

    if (try lookupObjectIdByHashRefInDb(allocator, &db, "comments", "comment", prefix)) |id| return id;

    const pattern = try std.fmt.allocPrint(allocator, "{s}%", .{prefix});
    defer allocator.free(pattern);
    var stmt = try db.prepare("SELECT id FROM comments WHERE id LIKE ? ORDER BY id LIMIT 2");
    defer stmt.deinit();
    try stmt.bindText(1, pattern);

    if (!(try stmt.step())) {
        try eprint("gt comment: no comment matches #{s}\n", .{prefix});
        return CliError.NotFound;
    }
    const first = try stmt.columnTextDup(allocator, 0);
    errdefer allocator.free(first);
    if (try stmt.step()) {
        const second = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(second);
        try eprint("gt comment: ambiguous comment reference #{s} matches {s} and {s}\n", .{ prefix, first, second });
        return CliError.AmbiguousReference;
    }
    return first;
}

fn commentRefValue(raw_ref: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw_ref, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "comment:")) return trimmed["comment:".len..];
    if (std.mem.startsWith(u8, trimmed, "~")) return trimmed[1..];
    if (std.mem.startsWith(u8, trimmed, "#")) return trimmed[1..];
    return trimmed;
}

pub fn commentParentInfo(allocator: Allocator, repo: Repo, comment_id: []const u8) !CommentParentInfo {
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    var stmt = try db.prepare(
        \\SELECT c.parent_kind, c.parent_id, COALESCE(e.event_hash, '')
        \\FROM comments c
        \\LEFT JOIN events e
        \\  ON e.object_id = c.id
        \\ AND e.event_type = 'comment.added'
        \\ AND e.domain_status = 'accepted'
        \\WHERE c.id = ?
        \\ORDER BY e.event_hash DESC
        \\LIMIT 1
    );
    defer stmt.deinit();
    try stmt.bindText(1, comment_id);
    if (!(try stmt.step())) {
        try eprint("gt comment: no comment matches {s}\n", .{comment_id});
        return CliError.NotFound;
    }
    return .{
        .allocator = allocator,
        .parent_kind = try stmt.columnTextDup(allocator, 0),
        .parent_id = try stmt.columnTextDup(allocator, 1),
        .add_hash = try stmt.columnTextDup(allocator, 2),
    };
}

pub fn listIssuesFromIndex(allocator: Allocator, repo: Repo, json: bool) !void {
    if (!fileExists(repo.index_path)) return;
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    var stmt = try db.prepare(
        \\SELECT i.id, i.title, i.state, i.author_principal, i.opened_at, i.body,
        \\       COALESCE(m.source_author, ''), COALESCE(m.milestone, ''),
        \\       COALESCE(m.priority, ''), COALESCE(m.status, '')
        \\FROM issues i
        \\LEFT JOIN issue_metadata m ON m.issue_id = i.id
        \\ORDER BY i.opened_at DESC, i.id DESC
    );
    defer stmt.deinit();

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
        const body = try stmt.columnTextDup(allocator, 5);
        defer allocator.free(body);
        const source_author = try stmt.columnTextDup(allocator, 6);
        defer allocator.free(source_author);
        const milestone = try stmt.columnTextDup(allocator, 7);
        defer allocator.free(milestone);
        const priority = try stmt.columnTextDup(allocator, 8);
        defer allocator.free(priority);
        const status = try stmt.columnTextDup(allocator, 9);
        defer allocator.free(status);

        if (json) {
            var line: std.ArrayList(u8) = .empty;
            defer line.deinit(allocator);
            try line.append(allocator, '{');
            try appendJsonFieldString(&line, allocator, "id", id, true);
            try appendJsonFieldString(&line, allocator, "state", state, true);
            try appendJsonFieldString(&line, allocator, "title", title, true);
            try appendJsonFieldString(&line, allocator, "body", body, true);
            try appendJsonFieldString(&line, allocator, "author_principal", author, true);
            if (source_author.len != 0) try appendJsonFieldString(&line, allocator, "source_author", source_author, true);
            try appendJsonFieldString(&line, allocator, "opened_at", opened_at, true);
            if (milestone.len != 0) try appendJsonFieldString(&line, allocator, "milestone", milestone, true);
            if (priority.len != 0) try appendJsonFieldString(&line, allocator, "priority", priority, true);
            if (status.len != 0) try appendJsonFieldString(&line, allocator, "status", status, true);
            if (try legacyGithubNumberForObjectInDb(&db, "issue", id)) |number| {
                try appendJsonFieldInteger(&line, allocator, "legacy_github_issue_number", number, true);
            }
            try appendIssueCollectionJsonField(&line, allocator, &db, "labels", "SELECT DISTINCT label FROM issue_labels WHERE issue_id = ? ORDER BY label", id, true);
            try appendIssueCollectionJsonField(&line, allocator, &db, "assignees", "SELECT DISTINCT assignee FROM issue_assignees WHERE issue_id = ? ORDER BY assignee", id, true);
            try appendIssueProjectsJsonField(&line, allocator, &db, id, true);
            try appendReactionsJsonField(&line, allocator, &db, "issue", id, false);
            try line.append(allocator, '}');
            try out("{s}\n", .{line.items});
        } else {
            var ref_buf: [util.short_object_ref_len]u8 = undefined;
            try out("#{s} {s} {s}\n", .{ util.shortObjectRef(&ref_buf, id), state, title });
        }
    }
}

pub fn showIssueFromIndex(allocator: Allocator, repo: Repo, issue_id: []const u8, json: bool) !void {
    if (!fileExists(repo.index_path)) return;
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    var stmt = try db.prepare(
        \\SELECT i.id, i.title, i.state, i.author_principal, i.author_device, i.opened_at, i.body,
        \\       COALESCE(m.source_author, ''), COALESCE(m.milestone, ''),
        \\       COALESCE(m.priority, ''), COALESCE(m.status, '')
        \\FROM issues i
        \\LEFT JOIN issue_metadata m ON m.issue_id = i.id
        \\WHERE i.id = ?
    );
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);

    if (!(try stmt.step())) {
        try eprint("gt issue: no issue matches {s}\n", .{issue_id});
        return CliError.NotFound;
    }

    const id = try stmt.columnTextDup(allocator, 0);
    defer allocator.free(id);
    const title = try stmt.columnTextDup(allocator, 1);
    defer allocator.free(title);
    const state = try stmt.columnTextDup(allocator, 2);
    defer allocator.free(state);
    const author_principal = try stmt.columnTextDup(allocator, 3);
    defer allocator.free(author_principal);
    const author_device = try stmt.columnTextDup(allocator, 4);
    defer allocator.free(author_device);
    const opened_at = try stmt.columnTextDup(allocator, 5);
    defer allocator.free(opened_at);
    const body = try stmt.columnTextDup(allocator, 6);
    defer allocator.free(body);
    const source_author = try stmt.columnTextDup(allocator, 7);
    defer allocator.free(source_author);
    const milestone = try stmt.columnTextDup(allocator, 8);
    defer allocator.free(milestone);
    const priority = try stmt.columnTextDup(allocator, 9);
    defer allocator.free(priority);
    const status = try stmt.columnTextDup(allocator, 10);
    defer allocator.free(status);

    if (json) {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(allocator);
        try line.append(allocator, '{');
        try appendJsonFieldString(&line, allocator, "id", id, true);
        try appendJsonFieldString(&line, allocator, "state", state, true);
        try appendJsonFieldString(&line, allocator, "title", title, true);
        try appendJsonFieldString(&line, allocator, "body", body, true);
        try appendJsonFieldString(&line, allocator, "author_principal", author_principal, true);
        try appendJsonFieldString(&line, allocator, "author_device", author_device, true);
        if (source_author.len != 0) try appendJsonFieldString(&line, allocator, "source_author", source_author, true);
        try appendJsonFieldString(&line, allocator, "opened_at", opened_at, true);
        if (milestone.len != 0) try appendJsonFieldString(&line, allocator, "milestone", milestone, true);
        if (priority.len != 0) try appendJsonFieldString(&line, allocator, "priority", priority, true);
        if (status.len != 0) try appendJsonFieldString(&line, allocator, "status", status, true);
        if (try legacyGithubNumberForObjectInDb(&db, "issue", id)) |number| {
            try appendJsonFieldInteger(&line, allocator, "legacy_github_issue_number", number, true);
        }
        try appendIssueCollectionJsonField(&line, allocator, &db, "labels", "SELECT DISTINCT label FROM issue_labels WHERE issue_id = ? ORDER BY label", id, true);
        try appendIssueCollectionJsonField(&line, allocator, &db, "assignees", "SELECT DISTINCT assignee FROM issue_assignees WHERE issue_id = ? ORDER BY assignee", id, true);
        try appendIssueProjectsJsonField(&line, allocator, &db, id, true);
        try appendCommitReferencesJsonField(&line, allocator, &db, "commit_references", "issue", id, true);
        try appendReactionsJsonField(&line, allocator, &db, "issue", id, false);
        try line.append(allocator, '}');
        try out("{s}\n", .{line.items});
        return;
    }

    const labels = try collectionText(allocator, &db, "SELECT DISTINCT label FROM issue_labels WHERE issue_id = ? ORDER BY label", id);
    defer allocator.free(labels);
    const assignees = try collectionText(allocator, &db, "SELECT DISTINCT assignee FROM issue_assignees WHERE issue_id = ? ORDER BY assignee", id);
    defer allocator.free(assignees);
    const commit_references = try commitReferencesText(allocator, &db, "issue", id);
    defer allocator.free(commit_references);
    const reactions = try reactionsText(allocator, &db, "issue", id);
    defer allocator.free(reactions);

    try out("id:        {s}\n", .{id});
    try out("state:     {s}\n", .{state});
    try out("title:     {s}\n", .{title});
    try out("author:    {s}/{s}\n", .{ author_principal, author_device });
    if (source_author.len != 0) {
        try out("source:    {s}\n", .{source_author});
    }
    try out("opened_at: {s}\n", .{opened_at});
    if (try legacyGithubNumberForObjectInDb(&db, "issue", id)) |number| {
        try out("github:    #{d}\n", .{number});
    }
    if (try legacyProviderNumberForObjectInDb(&db, "gitlab", "issue", id)) |number| {
        try out("gitlab:    #{d}\n", .{number});
    }
    try out("labels:    {s}\n", .{labels});
    try out("assignees: {s}\n", .{assignees});
    if (milestone.len != 0) {
        try out("milestone: {s}\n", .{milestone});
    }
    if (priority.len != 0) {
        try out("priority:  {s}\n", .{priority});
    }
    if (status.len != 0) {
        try out("status:    {s}\n", .{status});
    }
    const projects = try issueProjectsText(allocator, &db, id);
    defer allocator.free(projects);
    if (projects.len != 0) {
        try out("projects:  {s}\n", .{projects});
    }
    try out("commits:   {s}\n", .{commit_references});
    try out("reactions: {s}\n", .{reactions});
    try out("\n{s}\n", .{body});
}

pub fn listProjectsFromIndex(allocator: Allocator, repo: Repo, json: bool) !void {
    if (!fileExists(repo.index_path)) return;
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    var stmt = try db.prepare(
        \\SELECT id, name, slug, description, state, author_principal, created_at
        \\FROM projects
        \\ORDER BY created_at DESC, id DESC
    );
    defer stmt.deinit();

    while (try stmt.step()) {
        const id = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(id);
        const name = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(name);
        const slug = try stmt.columnTextDup(allocator, 2);
        defer allocator.free(slug);
        const description = try stmt.columnTextDup(allocator, 3);
        defer allocator.free(description);
        const state = try stmt.columnTextDup(allocator, 4);
        defer allocator.free(state);
        const author = try stmt.columnTextDup(allocator, 5);
        defer allocator.free(author);
        const created_at = try stmt.columnTextDup(allocator, 6);
        defer allocator.free(created_at);

        if (json) {
            var line: std.ArrayList(u8) = .empty;
            defer line.deinit(allocator);
            try line.append(allocator, '{');
            try appendJsonFieldString(&line, allocator, "id", id, true);
            try appendJsonFieldString(&line, allocator, "state", state, true);
            try appendJsonFieldString(&line, allocator, "name", name, true);
            try appendJsonFieldString(&line, allocator, "slug", slug, true);
            try appendJsonFieldString(&line, allocator, "description", description, true);
            try appendJsonFieldString(&line, allocator, "author_principal", author, true);
            try appendJsonFieldString(&line, allocator, "created_at", created_at, true);
            try appendProjectColumnsJsonField(&line, allocator, &db, id, true);
            try appendProjectColumnRefsJsonField(&line, allocator, &db, id, true);
            try appendProjectFieldsJsonField(&line, allocator, &db, id, true);
            try appendProjectViewsJsonField(&line, allocator, &db, id, false);
            try line.append(allocator, '}');
            try out("{s}\n", .{line.items});
        } else {
            try out("@{s} {s} {s}\n", .{ id[0..@min(id.len, 7)], state, name });
        }
    }
}

pub fn listMilestonesFromIndex(allocator: Allocator, repo: Repo, json: bool) !void {
    if (!fileExists(repo.index_path)) return;
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    var stmt = try db.prepare(
        \\SELECT id, title, description, due_at, state, author_principal, created_at
        \\FROM milestones
        \\ORDER BY due_at = '', due_at, created_at DESC, id DESC
    );
    defer stmt.deinit();

    while (try stmt.step()) {
        const id = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(id);
        const title = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(title);
        const description = try stmt.columnTextDup(allocator, 2);
        defer allocator.free(description);
        const due_at = try stmt.columnTextDup(allocator, 3);
        defer allocator.free(due_at);
        const state = try stmt.columnTextDup(allocator, 4);
        defer allocator.free(state);
        const author = try stmt.columnTextDup(allocator, 5);
        defer allocator.free(author);
        const created_at = try stmt.columnTextDup(allocator, 6);
        defer allocator.free(created_at);

        if (json) {
            var line: std.ArrayList(u8) = .empty;
            defer line.deinit(allocator);
            try line.append(allocator, '{');
            try appendJsonFieldString(&line, allocator, "id", id, true);
            try appendJsonFieldString(&line, allocator, "state", state, true);
            try appendJsonFieldString(&line, allocator, "title", title, true);
            try appendJsonFieldString(&line, allocator, "description", description, true);
            try appendJsonFieldString(&line, allocator, "due_at", due_at, true);
            try appendJsonFieldString(&line, allocator, "author_principal", author, true);
            try appendJsonFieldString(&line, allocator, "created_at", created_at, false);
            try line.append(allocator, '}');
            try out("{s}\n", .{line.items});
        } else {
            try out("^{s} {s} {s}", .{ id[0..@min(id.len, 7)], state, title });
            if (due_at.len != 0) try out(" due {s}", .{due_at});
            try out("\n", .{});
        }
    }
}

pub fn listPullsFromIndex(allocator: Allocator, repo: Repo, json: bool) !void {
    if (!fileExists(repo.index_path)) return;
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    var stmt = try db.prepare(
        \\SELECT p.id, p.title, p.state, p.author_principal, p.opened_at, p.body, p.base_ref, p.head_ref,
        \\       p.draft, p.merge_oid, p.target_oid,
        \\       COALESCE(pm.source_author, ''), COALESCE(pm.commit_count, -1), COALESCE(pm.changed_files, -1),
        \\       COALESCE(pm.additions, -1), COALESCE(pm.deletions, -1)
        \\FROM pulls p
        \\LEFT JOIN pull_metadata pm ON pm.pull_id = p.id
        \\ORDER BY p.opened_at DESC, p.id DESC
    );
    defer stmt.deinit();

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
        const body = try stmt.columnTextDup(allocator, 5);
        defer allocator.free(body);
        const base_ref = try stmt.columnTextDup(allocator, 6);
        defer allocator.free(base_ref);
        const head_ref = try stmt.columnTextDup(allocator, 7);
        defer allocator.free(head_ref);
        const draft = stmt.columnInt(8) != 0;
        const merge_oid = try stmt.columnTextDup(allocator, 9);
        defer allocator.free(merge_oid);
        const target_oid = try stmt.columnTextDup(allocator, 10);
        defer allocator.free(target_oid);
        const source_author = try stmt.columnTextDup(allocator, 11);
        defer allocator.free(source_author);
        const commit_count = stmt.columnInt64(12);
        const changed_files = stmt.columnInt64(13);
        const additions = stmt.columnInt64(14);
        const deletions = stmt.columnInt64(15);

        if (json) {
            var line: std.ArrayList(u8) = .empty;
            defer line.deinit(allocator);
            try line.append(allocator, '{');
            try appendJsonFieldString(&line, allocator, "id", id, true);
            try appendJsonFieldString(&line, allocator, "state", state, true);
            try appendJsonFieldString(&line, allocator, "title", title, true);
            try appendJsonFieldString(&line, allocator, "body", body, true);
            try appendJsonFieldString(&line, allocator, "base_ref", base_ref, true);
            try appendJsonFieldString(&line, allocator, "head_ref", head_ref, true);
            try appendJsonFieldBool(&line, allocator, "draft", draft, true);
            try appendJsonFieldString(&line, allocator, "merge_oid", merge_oid, true);
            try appendJsonFieldString(&line, allocator, "target_oid", target_oid, true);
            try appendJsonFieldString(&line, allocator, "author_principal", author, true);
            if (source_author.len != 0) try appendJsonFieldString(&line, allocator, "source_author", source_author, true);
            try appendJsonFieldString(&line, allocator, "opened_at", opened_at, true);
            if (commit_count >= 0) try appendJsonFieldInteger(&line, allocator, "commit_count", commit_count, true);
            if (changed_files >= 0) try appendJsonFieldInteger(&line, allocator, "changed_files", changed_files, true);
            if (additions >= 0) try appendJsonFieldInteger(&line, allocator, "additions", additions, true);
            if (deletions >= 0) try appendJsonFieldInteger(&line, allocator, "deletions", deletions, true);
            if (try legacyGithubNumberForObjectInDb(&db, "pull", id)) |number| {
                try appendJsonFieldInteger(&line, allocator, "legacy_github_pull_number", number, true);
            }
            try appendIssueCollectionJsonField(&line, allocator, &db, "labels", "SELECT DISTINCT label FROM pull_labels WHERE pull_id = ? ORDER BY label", id, true);
            try appendIssueCollectionJsonField(&line, allocator, &db, "assignees", "SELECT DISTINCT assignee FROM pull_assignees WHERE pull_id = ? ORDER BY assignee", id, true);
            try appendIssueCollectionJsonField(&line, allocator, &db, "reviewers", "SELECT DISTINCT reviewer FROM pull_reviewers WHERE pull_id = ? ORDER BY reviewer", id, true);
            try appendReactionsJsonField(&line, allocator, &db, "pull", id, false);
            try line.append(allocator, '}');
            try out("{s}\n", .{line.items});
        } else {
            var ref_buf: [util.short_object_ref_len]u8 = undefined;
            try out("#{s} {s} {s}->{s} {s}\n", .{
                util.shortObjectRef(&ref_buf, id),
                state,
                head_ref,
                base_ref,
                title,
            });
        }
    }
}

pub fn showPullFromIndex(allocator: Allocator, repo: Repo, pull_id: []const u8, json: bool) !void {
    if (!fileExists(repo.index_path)) return;
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    var stmt = try db.prepare(
        \\SELECT p.id, p.title, p.state, p.author_principal, p.author_device, p.opened_at, p.body, p.base_ref,
        \\       p.head_ref, p.draft, p.merge_oid, p.target_oid,
        \\       COALESCE(pm.source_author, ''), COALESCE(pm.commit_count, -1), COALESCE(pm.changed_files, -1),
        \\       COALESCE(pm.additions, -1), COALESCE(pm.deletions, -1)
        \\FROM pulls p
        \\LEFT JOIN pull_metadata pm ON pm.pull_id = p.id
        \\WHERE p.id = ?
    );
    defer stmt.deinit();
    try stmt.bindText(1, pull_id);

    if (!(try stmt.step())) {
        try eprint("gt pr: no PR matches {s}\n", .{pull_id});
        return CliError.NotFound;
    }

    const id = try stmt.columnTextDup(allocator, 0);
    defer allocator.free(id);
    const title = try stmt.columnTextDup(allocator, 1);
    defer allocator.free(title);
    const state = try stmt.columnTextDup(allocator, 2);
    defer allocator.free(state);
    const author_principal = try stmt.columnTextDup(allocator, 3);
    defer allocator.free(author_principal);
    const author_device = try stmt.columnTextDup(allocator, 4);
    defer allocator.free(author_device);
    const opened_at = try stmt.columnTextDup(allocator, 5);
    defer allocator.free(opened_at);
    const body = try stmt.columnTextDup(allocator, 6);
    defer allocator.free(body);
    const base_ref = try stmt.columnTextDup(allocator, 7);
    defer allocator.free(base_ref);
    const head_ref = try stmt.columnTextDup(allocator, 8);
    defer allocator.free(head_ref);
    const draft = stmt.columnInt(9) != 0;
    const merge_oid = try stmt.columnTextDup(allocator, 10);
    defer allocator.free(merge_oid);
    const target_oid = try stmt.columnTextDup(allocator, 11);
    defer allocator.free(target_oid);
    const source_author = try stmt.columnTextDup(allocator, 12);
    defer allocator.free(source_author);
    const commit_count = stmt.columnInt64(13);
    const changed_files = stmt.columnInt64(14);
    const additions = stmt.columnInt64(15);
    const deletions = stmt.columnInt64(16);

    if (json) {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(allocator);
        try line.append(allocator, '{');
        try appendJsonFieldString(&line, allocator, "id", id, true);
        try appendJsonFieldString(&line, allocator, "state", state, true);
        try appendJsonFieldString(&line, allocator, "title", title, true);
        try appendJsonFieldString(&line, allocator, "body", body, true);
        try appendJsonFieldString(&line, allocator, "base_ref", base_ref, true);
        try appendJsonFieldString(&line, allocator, "head_ref", head_ref, true);
        try appendJsonFieldBool(&line, allocator, "draft", draft, true);
        try appendJsonFieldString(&line, allocator, "merge_oid", merge_oid, true);
        try appendJsonFieldString(&line, allocator, "target_oid", target_oid, true);
        try appendJsonFieldString(&line, allocator, "author_principal", author_principal, true);
        try appendJsonFieldString(&line, allocator, "author_device", author_device, true);
        if (source_author.len != 0) try appendJsonFieldString(&line, allocator, "source_author", source_author, true);
        try appendJsonFieldString(&line, allocator, "opened_at", opened_at, true);
        if (commit_count >= 0) try appendJsonFieldInteger(&line, allocator, "commit_count", commit_count, true);
        if (changed_files >= 0) try appendJsonFieldInteger(&line, allocator, "changed_files", changed_files, true);
        if (additions >= 0) try appendJsonFieldInteger(&line, allocator, "additions", additions, true);
        if (deletions >= 0) try appendJsonFieldInteger(&line, allocator, "deletions", deletions, true);
        if (try legacyGithubNumberForObjectInDb(&db, "pull", id)) |number| {
            try appendJsonFieldInteger(&line, allocator, "legacy_github_pull_number", number, true);
        }
        try appendIssueCollectionJsonField(&line, allocator, &db, "labels", "SELECT DISTINCT label FROM pull_labels WHERE pull_id = ? ORDER BY label", id, true);
        try appendIssueCollectionJsonField(&line, allocator, &db, "assignees", "SELECT DISTINCT assignee FROM pull_assignees WHERE pull_id = ? ORDER BY assignee", id, true);
        try appendIssueCollectionJsonField(&line, allocator, &db, "reviewers", "SELECT DISTINCT reviewer FROM pull_reviewers WHERE pull_id = ? ORDER BY reviewer", id, true);
        try appendCommitReferencesJsonField(&line, allocator, &db, "commit_references", "pull", id, true);
        try appendReactionsJsonField(&line, allocator, &db, "pull", id, false);
        try line.append(allocator, '}');
        try out("{s}\n", .{line.items});
        return;
    }

    const labels = try collectionText(allocator, &db, "SELECT DISTINCT label FROM pull_labels WHERE pull_id = ? ORDER BY label", id);
    defer allocator.free(labels);
    const assignees = try collectionText(allocator, &db, "SELECT DISTINCT assignee FROM pull_assignees WHERE pull_id = ? ORDER BY assignee", id);
    defer allocator.free(assignees);
    const reviewers = try collectionText(allocator, &db, "SELECT DISTINCT reviewer FROM pull_reviewers WHERE pull_id = ? ORDER BY reviewer", id);
    defer allocator.free(reviewers);
    const commit_references = try commitReferencesText(allocator, &db, "pull", id);
    defer allocator.free(commit_references);
    const reactions = try reactionsText(allocator, &db, "pull", id);
    defer allocator.free(reactions);

    try out("id:         {s}\n", .{id});
    try out("state:      {s}\n", .{state});
    try out("title:      {s}\n", .{title});
    try out("author:     {s}/{s}\n", .{ author_principal, author_device });
    if (source_author.len != 0) try out("source:     {s}\n", .{source_author});
    try out("opened_at:  {s}\n", .{opened_at});
    if (try legacyGithubNumberForObjectInDb(&db, "pull", id)) |number| {
        try out("github:     #{d}\n", .{number});
    }
    if (try legacyProviderNumberForObjectInDb(&db, "gitlab", "pull", id)) |number| {
        try out("gitlab:     !{d}\n", .{number});
    }
    try out("base:       {s}\n", .{base_ref});
    try out("head:       {s}\n", .{head_ref});
    try out("draft:      {s}\n", .{if (draft) "true" else "false"});
    try out("merge_oid:  {s}\n", .{if (merge_oid.len == 0) "(none)" else merge_oid});
    try out("target_oid: {s}\n", .{if (target_oid.len == 0) "(none)" else target_oid});
    if (commit_count >= 0) try out("commit_count: {d}\n", .{commit_count});
    if (changed_files >= 0) try out("changed_files: {d}\n", .{changed_files});
    if (additions >= 0 or deletions >= 0) try out("diffstat:   +{d} -{d}\n", .{ if (additions >= 0) additions else 0, if (deletions >= 0) deletions else 0 });
    try out("labels:     {s}\n", .{labels});
    try out("assignees:  {s}\n", .{assignees});
    try out("reviewers:  {s}\n", .{reviewers});
    try out("commits:    {s}\n", .{commit_references});
    try out("reactions:  {s}\n", .{reactions});
    try out("\n{s}\n", .{body});
}

pub fn listCommentsFromIndex(
    allocator: Allocator,
    repo: Repo,
    parent_kind: []const u8,
    parent_id: []const u8,
    json: bool,
) !void {
    if (!fileExists(repo.index_path)) return;
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    var stmt = try db.prepare(
        \\SELECT id, body, redacted, author_principal, created_at, source_author, reply_parent_id, reply_parent_hash
        \\FROM comments
        \\WHERE parent_kind = ? AND parent_id = ?
        \\ORDER BY created_at, id
    );
    defer stmt.deinit();
    try stmt.bindText(1, parent_kind);
    try stmt.bindText(2, parent_id);

    while (try stmt.step()) {
        const id = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(id);
        const body = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(body);
        const redacted = stmt.columnInt(2) != 0;
        const author = try stmt.columnTextDup(allocator, 3);
        defer allocator.free(author);
        const created_at = try stmt.columnTextDup(allocator, 4);
        defer allocator.free(created_at);
        const source_author = try stmt.columnTextDup(allocator, 5);
        defer allocator.free(source_author);
        const reply_parent_id = try stmt.columnTextDup(allocator, 6);
        defer allocator.free(reply_parent_id);
        const reply_parent_hash = try stmt.columnTextDup(allocator, 7);
        defer allocator.free(reply_parent_hash);

        if (json) {
            var line: std.ArrayList(u8) = .empty;
            defer line.deinit(allocator);
            try line.append(allocator, '{');
            try appendJsonFieldString(&line, allocator, "id", id, true);
            try appendJsonFieldBool(&line, allocator, "redacted", redacted, true);
            try appendJsonFieldString(&line, allocator, "body", if (redacted) "" else body, true);
            try appendJsonFieldString(&line, allocator, "author_principal", author, true);
            if (source_author.len != 0) try appendJsonFieldString(&line, allocator, "source_author", source_author, true);
            if (reply_parent_id.len != 0) try appendJsonFieldString(&line, allocator, "reply_parent_id", reply_parent_id, true);
            if (reply_parent_hash.len != 0) try appendJsonFieldString(&line, allocator, "reply_parent_hash", reply_parent_hash, true);
            try appendJsonFieldString(&line, allocator, "created_at", created_at, true);
            try appendReactionsJsonField(&line, allocator, &db, "comment", id, false);
            try line.append(allocator, '}');
            try out("{s}\n", .{line.items});
        } else {
            var comment_ref_buf: [util.short_object_ref_len]u8 = undefined;
            try out("comment:{s} {s}: {s}\n", .{
                util.shortObjectRef(&comment_ref_buf, id),
                if (source_author.len != 0) source_author else author,
                if (redacted) "[redacted]" else body,
            });
        }
    }
}

fn appendIssueCollectionJsonField(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    key: []const u8,
    comptime sql_text: []const u8,
    issue_id: []const u8,
    comma: bool,
) !void {
    try appendJsonString(buf, allocator, key);
    try buf.appendSlice(allocator, ":[");
    var stmt = try db.prepare(sql_text);
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);

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

fn appendIssueProjectsJsonField(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    issue_id: []const u8,
    comma: bool,
) !void {
    try appendJsonString(buf, allocator, "projects");
    try buf.appendSlice(allocator, ":[");
    var stmt = try db.prepare(
        \\SELECT DISTINCT project, column_name
        \\FROM (
        \\  SELECT project, column_name
        \\  FROM issue_projects
        \\  WHERE issue_id = ?
        \\  UNION
        \\  SELECT p.name AS project,
        \\         COALESCE(CASE WHEN pfv.value_json IS NULL THEN '' ELSE json_extract(pfv.value_json, '$') END, '') AS column_name
        \\  FROM project_memberships pm
        \\  JOIN projects p ON p.id = pm.project_id
        \\  LEFT JOIN project_fields pf
        \\    ON pf.project_id = pm.project_id
        \\   AND pf.key = 'status'
        \\   AND pf.state != 'removed'
        \\  LEFT JOIN project_field_values pfv
        \\    ON pfv.project_id = pm.project_id
        \\   AND pfv.issue_id = pm.issue_id
        \\   AND pfv.field_id = pf.id
        \\  WHERE pm.issue_id = ?
        \\)
        \\ORDER BY project, column_name
    );
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    try stmt.bindText(2, issue_id);

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

fn appendReactionsJsonField(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    object_kind: []const u8,
    object_id: []const u8,
    comma: bool,
) !void {
    try appendJsonString(buf, allocator, "reactions");
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

fn appendReactionActorsJsonField(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    object_kind: []const u8,
    object_id: []const u8,
    emoji: []const u8,
    comma: bool,
) !void {
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

fn reactionsText(allocator: Allocator, db: *SqliteDb, object_kind: []const u8, object_id: []const u8) ![]u8 {
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

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var first = true;
    while (try stmt.step()) {
        const emoji = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(emoji);
        const count = stmt.columnInt64(1);
        if (!first) try buf.appendSlice(allocator, ", ");
        first = false;
        try buf.appendSlice(allocator, emoji);
        try std.fmt.format(buf.writer(allocator), " {d}", .{count});
    }
    if (first) try buf.appendSlice(allocator, "(none)");
    return buf.toOwnedSlice(allocator);
}

fn appendProjectColumnsJsonField(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    project_id: []const u8,
    comma: bool,
) !void {
    try appendJsonString(buf, allocator, "columns");
    try buf.appendSlice(allocator, ":[");
    var stmt = try db.prepare(
        \\SELECT DISTINCT column_name
        \\FROM project_columns
        \\WHERE project_id = ?
        \\ORDER BY column_name
    );
    defer stmt.deinit();
    try stmt.bindText(1, project_id);

    var first = true;
    while (try stmt.step()) {
        const column = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(column);
        if (!first) try buf.append(allocator, ',');
        first = false;
        try appendJsonString(buf, allocator, column);
    }
    try buf.append(allocator, ']');
    if (comma) try buf.append(allocator, ',');
}

fn appendProjectFieldsJsonField(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    project_id: []const u8,
    comma: bool,
) !void {
    try appendJsonString(buf, allocator, "fields");
    try buf.appendSlice(allocator, ":[");
    var stmt = try db.prepare(
        \\SELECT id, key, name, field_type, position, required, default_value_json, state
        \\FROM project_fields
        \\WHERE project_id = ?
        \\ORDER BY position, key, id
    );
    defer stmt.deinit();
    try stmt.bindText(1, project_id);

    var first = true;
    while (try stmt.step()) {
        const id = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(id);
        const key = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(key);
        const name = try stmt.columnTextDup(allocator, 2);
        defer allocator.free(name);
        const field_type = try stmt.columnTextDup(allocator, 3);
        defer allocator.free(field_type);
        const default_value_json = try stmt.columnTextDup(allocator, 6);
        defer allocator.free(default_value_json);
        const state = try stmt.columnTextDup(allocator, 7);
        defer allocator.free(state);
        if (!first) try buf.append(allocator, ',');
        first = false;
        try buf.append(allocator, '{');
        try appendJsonFieldString(buf, allocator, "id", id, true);
        try appendJsonFieldString(buf, allocator, "key", key, true);
        try appendJsonFieldString(buf, allocator, "name", name, true);
        try appendJsonFieldString(buf, allocator, "type", field_type, true);
        try appendJsonFieldInteger(buf, allocator, "position", stmt.columnInt64(4), true);
        try appendJsonFieldBool(buf, allocator, "required", stmt.columnInt64(5) != 0, true);
        try appendJsonFieldRaw(buf, allocator, "default_value", default_value_json, true);
        try appendJsonFieldString(buf, allocator, "state", state, true);
        try appendProjectFieldOptionsJsonField(buf, allocator, db, id, false);
        try buf.append(allocator, '}');
    }
    try buf.append(allocator, ']');
    if (comma) try buf.append(allocator, ',');
}

fn appendProjectFieldOptionsJsonField(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    field_id: []const u8,
    comma: bool,
) !void {
    try appendJsonString(buf, allocator, "options");
    try buf.appendSlice(allocator, ":[");
    var stmt = try db.prepare(
        \\SELECT id, name, color, position, state
        \\FROM project_field_options
        \\WHERE field_id = ?
        \\ORDER BY position, name, id
    );
    defer stmt.deinit();
    try stmt.bindText(1, field_id);

    var first = true;
    while (try stmt.step()) {
        const id = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(id);
        const name = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(name);
        const color = try stmt.columnTextDup(allocator, 2);
        defer allocator.free(color);
        const state = try stmt.columnTextDup(allocator, 4);
        defer allocator.free(state);
        if (!first) try buf.append(allocator, ',');
        first = false;
        try buf.append(allocator, '{');
        try appendJsonFieldString(buf, allocator, "id", id, true);
        try appendJsonFieldString(buf, allocator, "name", name, true);
        try appendJsonFieldString(buf, allocator, "color", color, true);
        try appendJsonFieldInteger(buf, allocator, "position", stmt.columnInt64(3), true);
        try appendJsonFieldString(buf, allocator, "state", state, false);
        try buf.append(allocator, '}');
    }
    try buf.append(allocator, ']');
    if (comma) try buf.append(allocator, ',');
}

fn appendProjectColumnRefsJsonField(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    project_id: []const u8,
    comma: bool,
) !void {
    try appendJsonString(buf, allocator, "column_refs");
    try buf.appendSlice(allocator, ":[");
    var stmt = try db.prepare(
        \\SELECT column_name, column_ref
        \\FROM project_columns
        \\WHERE project_id = ?
        \\ORDER BY column_name, column_ref
    );
    defer stmt.deinit();
    try stmt.bindText(1, project_id);

    var first = true;
    while (try stmt.step()) {
        const column = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(column);
        const column_ref = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(column_ref);
        if (!first) try buf.append(allocator, ',');
        first = false;
        try buf.append(allocator, '{');
        try appendJsonFieldString(buf, allocator, "name", column, true);
        try appendJsonFieldString(buf, allocator, "ref", column_ref, false);
        try buf.append(allocator, '}');
    }
    try buf.append(allocator, ']');
    if (comma) try buf.append(allocator, ',');
}

fn appendProjectViewsJsonField(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    project_id: []const u8,
    comma: bool,
) !void {
    try appendJsonString(buf, allocator, "views");
    try buf.appendSlice(allocator, ":[");
    var stmt = try db.prepare(
        \\SELECT id, name, layout, position, config_json, state
        \\FROM project_views
        \\WHERE project_id = ?
        \\ORDER BY position, name, id
    );
    defer stmt.deinit();
    try stmt.bindText(1, project_id);

    var first = true;
    while (try stmt.step()) {
        const id = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(id);
        const name = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(name);
        const layout = try stmt.columnTextDup(allocator, 2);
        defer allocator.free(layout);
        const config_json = try stmt.columnTextDup(allocator, 4);
        defer allocator.free(config_json);
        const state = try stmt.columnTextDup(allocator, 5);
        defer allocator.free(state);
        if (!first) try buf.append(allocator, ',');
        first = false;
        try buf.append(allocator, '{');
        try appendJsonFieldString(buf, allocator, "id", id, true);
        try appendJsonFieldString(buf, allocator, "name", name, true);
        try appendJsonFieldString(buf, allocator, "layout", layout, true);
        try appendJsonFieldInteger(buf, allocator, "position", stmt.columnInt64(3), true);
        try appendJsonFieldRaw(buf, allocator, "config", config_json, true);
        try appendJsonFieldString(buf, allocator, "state", state, false);
        try buf.append(allocator, '}');
    }
    try buf.append(allocator, ']');
    if (comma) try buf.append(allocator, ',');
}

fn appendJsonFieldRaw(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    key: []const u8,
    raw_json: []const u8,
    comma: bool,
) !void {
    try appendJsonString(buf, allocator, key);
    try buf.append(allocator, ':');
    try buf.appendSlice(allocator, raw_json);
    if (comma) try buf.append(allocator, ',');
}

fn appendCommitReferencesJsonField(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    key: []const u8,
    object_kind: []const u8,
    object_id: []const u8,
    comma: bool,
) !void {
    try appendJsonString(buf, allocator, key);
    try buf.appendSlice(allocator, ":[");
    var stmt = try db.prepare(
        \\SELECT commit_oid
        \\FROM commit_references
        \\WHERE object_kind = ? AND object_id = ?
        \\ORDER BY commit_oid
    );
    defer stmt.deinit();
    try stmt.bindText(1, object_kind);
    try stmt.bindText(2, object_id);

    var first = true;
    while (try stmt.step()) {
        const commit_oid = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(commit_oid);
        if (!first) try buf.append(allocator, ',');
        first = false;
        try appendJsonString(buf, allocator, commit_oid);
    }
    try buf.append(allocator, ']');
    if (comma) try buf.append(allocator, ',');
}

fn issueProjectsText(allocator: Allocator, db: *SqliteDb, issue_id: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var stmt = try db.prepare(
        \\SELECT DISTINCT project, column_name
        \\FROM (
        \\  SELECT project, column_name
        \\  FROM issue_projects
        \\  WHERE issue_id = ?
        \\  UNION
        \\  SELECT p.name AS project,
        \\         COALESCE(CASE WHEN pfv.value_json IS NULL THEN '' ELSE json_extract(pfv.value_json, '$') END, '') AS column_name
        \\  FROM project_memberships pm
        \\  JOIN projects p ON p.id = pm.project_id
        \\  LEFT JOIN project_fields pf
        \\    ON pf.project_id = pm.project_id
        \\   AND pf.key = 'status'
        \\   AND pf.state != 'removed'
        \\  LEFT JOIN project_field_values pfv
        \\    ON pfv.project_id = pm.project_id
        \\   AND pfv.issue_id = pm.issue_id
        \\   AND pfv.field_id = pf.id
        \\  WHERE pm.issue_id = ?
        \\)
        \\ORDER BY project, column_name
    );
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    try stmt.bindText(2, issue_id);

    var first = true;
    while (try stmt.step()) {
        const project = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(project);
        const column = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(column);
        if (!first) try buf.appendSlice(allocator, ", ");
        first = false;
        try buf.appendSlice(allocator, project);
        if (column.len != 0) {
            try buf.appendSlice(allocator, " / ");
            try buf.appendSlice(allocator, column);
        }
    }
    return buf.toOwnedSlice(allocator);
}

fn collectionText(
    allocator: Allocator,
    db: *SqliteDb,
    comptime sql_text: []const u8,
    object_id: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var stmt = try db.prepare(sql_text);
    defer stmt.deinit();
    try stmt.bindText(1, object_id);

    var first = true;
    while (try stmt.step()) {
        const value = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(value);
        if (!first) try buf.appendSlice(allocator, ", ");
        first = false;
        try buf.appendSlice(allocator, value);
    }
    if (first) try buf.appendSlice(allocator, "(none)");
    return buf.toOwnedSlice(allocator);
}

fn commitReferencesText(allocator: Allocator, db: *SqliteDb, object_kind: []const u8, object_id: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var stmt = try db.prepare(
        \\SELECT commit_oid
        \\FROM commit_references
        \\WHERE object_kind = ? AND object_id = ?
        \\ORDER BY commit_oid
    );
    defer stmt.deinit();
    try stmt.bindText(1, object_kind);
    try stmt.bindText(2, object_id);

    var first = true;
    while (try stmt.step()) {
        const commit_oid = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(commit_oid);
        if (!first) try buf.appendSlice(allocator, ", ");
        first = false;
        try buf.appendSlice(allocator, commit_oid[0..@min(commit_oid.len, 12)]);
    }
    if (first) try buf.appendSlice(allocator, "(none)");
    return buf.toOwnedSlice(allocator);
}

pub fn listEventsFromIndex(
    allocator: Allocator,
    repo: Repo,
    json: bool,
    limit: ?usize,
    one_ref: ?[]const u8,
) !void {
    if (!fileExists(repo.index_path)) return;
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    const limit_value = try sqliteLimitValue(limit);
    const sql_text = if (one_ref == null)
        "SELECT " ++ index_event_columns ++ " FROM events ORDER BY ordinal LIMIT ?"
    else
        "SELECT " ++ index_event_columns ++ " FROM events WHERE ref = ? ORDER BY ordinal LIMIT ?";
    var stmt = try db.prepare(sql_text);
    defer stmt.deinit();
    if (one_ref) |wanted| {
        try stmt.bindText(1, wanted);
        try stmt.bindInt64(2, limit_value);
    } else {
        try stmt.bindInt64(1, limit_value);
    }

    while (try stmt.step()) {
        const event = try indexedEventFromStmt(allocator, &stmt);
        defer freeIndexedEvent(allocator, event);
        if (json) {
            var line: std.ArrayList(u8) = .empty;
            defer line.deinit(allocator);
            try appendIndexedEventJson(&line, allocator, event);
            try out("{s}\n", .{line.items});
        } else {
            try printIndexedEvent(event);
        }
    }
}

pub fn sqliteLimitValue(limit: ?usize) !i64 {
    if (limit) |max| {
        if (max > std.math.maxInt(i64)) {
            try eprint("gt events list: --limit is too large\n", .{});
            return CliError.UserError;
        }
        return @intCast(max);
    }
    return -1;
}

test "write preflight enforces current RBAC" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const index_path = try std.fs.path.join(allocator, &.{ root, "index.sqlite" });
    defer allocator.free(index_path);

    var db = try SqliteDb.open(allocator, index_path, sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_CREATE, true);
    try index_schema.createIndexSchema(&db);
    try db.exec("INSERT INTO meta(key, value) VALUES ('access_mode', 'closed')");
    db.deinit();

    var repo = try testRepo(allocator, root, index_path);
    defer repo.deinit();

    try requireAuthorizedWrite(allocator, repo, test_issue_opened_body);
    try std.testing.expectError(CliError.Unauthorized, requireAuthorizedWrite(allocator, repo, test_acl_grant_body));

    db = try SqliteDb.open(allocator, index_path, sqlite.SQLITE_OPEN_READWRITE, false);
    try db.exec(
        \\INSERT INTO acl_roles(principal, role, grant_event_hash)
        \\VALUES ('alice', 'reporter', '');
        \\INSERT INTO identity_devices(principal, device, key_fingerprint, public_key, added_event_hash, revoked_event_hash)
        \\VALUES ('alice', 'laptop', 'SHA256:alice', 'ssh-ed25519 AAAA', '', NULL);
    );
    db.deinit();

    try requireAuthorizedWrite(allocator, repo, test_issue_opened_body);
}

fn testRepo(allocator: Allocator, root: []const u8, index_path: []const u8) !Repo {
    return .{
        .allocator = allocator,
        .root = try allocator.dupe(u8, root),
        .git_dir = try allocator.dupe(u8, root),
        .gitomi_dir = try allocator.dupe(u8, root),
        .config_path = try std.fs.path.join(allocator, &.{ root, "config.toml" }),
        .index_path = try allocator.dupe(u8, index_path),
        .cursors_path = try std.fs.path.join(allocator, &.{ root, "cursors.sqlite" }),
        .settings_path = try std.fs.path.join(allocator, &.{ root, "settings.sqlite" }),
    };
}

const test_issue_opened_body =
    \\{
    \\  "$schema": "urn:gitomi:event:v1",
    \\  "repo_id": "018f0000-0000-7000-8000-000000000001",
    \\  "event_uuid": "018f0000-0000-7000-8000-000000000101",
    \\  "event_type": "issue.opened",
    \\  "object": {
    \\    "kind": "issue",
    \\    "id": "018f0000-0000-7000-8000-000000000100"
    \\  },
    \\  "idempotency_key": "018f0000-0000-7000-8000-000000000102",
    \\  "actor": {
    \\    "principal": "alice",
    \\    "device": "laptop"
    \\  },
    \\  "seq": 1,
    \\  "occurred_at": "2026-05-16T00:00:00Z",
    \\  "parent_hashes": {
    \\    "log": "",
    \\    "anchor": "",
    \\    "causal": [],
    \\    "related": []
    \\  },
    \\  "legacy": {},
    \\  "payload": {
    \\    "title": "Smoke"
    \\  }
    \\}
;

const test_acl_grant_body =
    \\{
    \\  "$schema": "urn:gitomi:event:v1",
    \\  "repo_id": "018f0000-0000-7000-8000-000000000001",
    \\  "event_uuid": "018f0000-0000-7000-8000-000000000201",
    \\  "event_type": "acl.role_granted",
    \\  "object": {
    \\    "kind": "acl",
    \\    "id": "acl:bob"
    \\  },
    \\  "idempotency_key": "018f0000-0000-7000-8000-000000000202",
    \\  "actor": {
    \\    "principal": "alice",
    \\    "device": "laptop"
    \\  },
    \\  "seq": 1,
    \\  "occurred_at": "2026-05-16T00:00:00Z",
    \\  "parent_hashes": {
    \\    "log": "",
    \\    "anchor": "",
    \\    "causal": [],
    \\    "related": []
    \\  },
    \\  "legacy": {},
    \\  "payload": {
    \\    "principal": "bob",
    \\    "role": "reporter"
    \\  }
    \\}
;
