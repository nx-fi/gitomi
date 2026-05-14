const std = @import("std");

const errors = @import("../errors.zig");
const event_mod = @import("../event.zig");
const index_event_row = @import("event_row.zig");
const io = @import("../io.zig");
const json_writer = @import("../json_writer.zig");
const projection = @import("projection.zig");
const repo_mod = @import("../repo.zig");
const sqlite_db = @import("sqlite_db.zig");
const util = @import("../util.zig");

pub const index_event_columns = "ref, \"commit\", event_hash, tree, subject, empty_tree, valid_json, event_type, object_kind, object_id, actor_principal, actor_device, seq, occurred_at, domain_status, rejection_reason";

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

pub fn countIndexedEventsInDb(db: *SqliteDb) !usize {
    var stmt = try db.prepare("SELECT COUNT(*) FROM events");
    defer stmt.deinit();
    if (!try stmt.step()) return 0;
    const count = stmt.columnInt64(0);
    return if (count <= 0) 0 else @as(usize, @intCast(count));
}

pub fn requireAuthorizedWrite(allocator: Allocator, repo: Repo, event_body: []const u8) !void {
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

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

    if (try projection.authorizationRejection(allocator, &db, null, envelope, event_body)) |reason| {
        try eprint("gt: refusing to create unauthorized event: {s}\n", .{reason});
        return CliError.Unauthorized;
    }
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

pub fn isIdentityDeviceActive(allocator: Allocator, repo: Repo, principal: []const u8, device: []const u8) !bool {
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    return try projection.currentDeviceActive(&db, principal, device);
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
    if (parseLegacyGithubNumber(raw_ref)) |number| {
        if (try lookupLegacyGithubObjectId(allocator, repo, "issue", number)) |id| return id;
        try eprint("gt issue: no issue has GitHub legacy number #{d}\n", .{number});
        return CliError.NotFound;
    }

    const prefix = if (std.mem.startsWith(u8, raw_ref, "#")) raw_ref[1..] else raw_ref;
    if (prefix.len < 7) {
        try eprint("gt issue: issue reference must be at least 7 hex characters\n", .{});
        return CliError.InvalidReference;
    }
    for (prefix) |c| {
        if (!std.ascii.isHex(c) and c != '-') {
            try eprint("gt issue: issue reference must be a UUID or UUID prefix\n", .{});
            return CliError.InvalidReference;
        }
    }

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    const pattern = try std.fmt.allocPrint(allocator, "{s}%", .{prefix});
    defer allocator.free(pattern);
    var stmt = try db.prepare("SELECT id FROM issues WHERE id LIKE ? ORDER BY id LIMIT 2");
    defer stmt.deinit();
    try stmt.bindText(1, pattern);

    if (!(try stmt.step())) {
        try eprint("gt issue: no issue matches #{s}\n", .{prefix});
        return CliError.NotFound;
    }
    const first = try stmt.columnTextDup(allocator, 0);
    errdefer allocator.free(first);
    if (try stmt.step()) {
        const second = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(second);
        try eprint("gt issue: ambiguous issue reference #{s} matches {s} and {s}\n", .{ prefix, first, second });
        return CliError.AmbiguousReference;
    }
    return first;
}

pub fn resolvePullId(allocator: Allocator, repo: Repo, raw_ref: []const u8) ![]u8 {
    if (parseLegacyGithubNumber(raw_ref)) |number| {
        if (try lookupLegacyGithubObjectId(allocator, repo, "pull", number)) |id| return id;
        try eprint("gt pr: no PR has GitHub legacy number #{d}\n", .{number});
        return CliError.NotFound;
    }

    const prefix = if (std.mem.startsWith(u8, raw_ref, "#")) raw_ref[1..] else raw_ref;
    if (prefix.len < 7) {
        try eprint("gt pr: PR reference must be at least 7 hex characters\n", .{});
        return CliError.InvalidReference;
    }
    for (prefix) |c| {
        if (!std.ascii.isHex(c) and c != '-') {
            try eprint("gt pr: PR reference must be a UUID or UUID prefix\n", .{});
            return CliError.InvalidReference;
        }
    }

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    const pattern = try std.fmt.allocPrint(allocator, "{s}%", .{prefix});
    defer allocator.free(pattern);
    var stmt = try db.prepare("SELECT id FROM pulls WHERE id LIKE ? ORDER BY id LIMIT 2");
    defer stmt.deinit();
    try stmt.bindText(1, pattern);

    if (!(try stmt.step())) {
        try eprint("gt pr: no PR matches #{s}\n", .{prefix});
        return CliError.NotFound;
    }
    const first = try stmt.columnTextDup(allocator, 0);
    errdefer allocator.free(first);
    if (try stmt.step()) {
        const second = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(second);
        try eprint("gt pr: ambiguous PR reference #{s} matches {s} and {s}\n", .{ prefix, first, second });
        return CliError.AmbiguousReference;
    }
    return first;
}

fn parseLegacyGithubNumber(raw_ref: []const u8) ?i64 {
    const trimmed = std.mem.trim(u8, raw_ref, " \t\r\n");
    const value = if (std.mem.startsWith(u8, trimmed, "github#"))
        trimmed["github#".len..]
    else if (std.mem.startsWith(u8, trimmed, "github:"))
        trimmed["github:".len..]
    else if (std.mem.startsWith(u8, trimmed, "gh#"))
        trimmed["gh#".len..]
    else if (std.mem.startsWith(u8, trimmed, "gh:"))
        trimmed["gh:".len..]
    else if (std.mem.startsWith(u8, trimmed, "#"))
        trimmed[1..]
    else
        trimmed;
    if (value.len == 0) return null;
    for (value) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    const number = std.fmt.parseInt(i64, value, 10) catch return null;
    return if (number > 0) number else null;
}

pub fn lookupLegacyGithubObjectId(allocator: Allocator, repo: Repo, object_kind: []const u8, number: i64) !?[]u8 {
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    return try lookupLegacyGithubObjectIdInDb(allocator, &db, object_kind, number);
}

fn lookupLegacyGithubObjectIdInDb(allocator: Allocator, db: *SqliteDb, object_kind: []const u8, number: i64) !?[]u8 {
    var stmt = try db.prepare(
        \\SELECT object_id
        \\FROM legacy_aliases
        \\WHERE provider = 'github' AND object_kind = ? AND number = ?
    );
    defer stmt.deinit();
    try stmt.bindText(1, object_kind);
    try stmt.bindInt64(2, number);
    if (!(try stmt.step())) return null;
    return try stmt.columnTextDup(allocator, 0);
}

pub fn legacyGithubNumberForObject(allocator: Allocator, repo: Repo, object_kind: []const u8, object_id: []const u8) !?i64 {
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    return try legacyGithubNumberForObjectInDb(&db, object_kind, object_id);
}

fn legacyGithubNumberForObjectInDb(db: *SqliteDb, object_kind: []const u8, object_id: []const u8) !?i64 {
    var stmt = try db.prepare(
        \\SELECT number
        \\FROM legacy_aliases
        \\WHERE provider = 'github' AND object_kind = ? AND object_id = ?
    );
    defer stmt.deinit();
    try stmt.bindText(1, object_kind);
    try stmt.bindText(2, object_id);
    if (!(try stmt.step())) return null;
    return stmt.columnInt64(0);
}

pub fn resolveCommentId(allocator: Allocator, repo: Repo, raw_ref: []const u8) ![]u8 {
    const prefix = if (std.mem.startsWith(u8, raw_ref, "#")) raw_ref[1..] else raw_ref;
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

pub fn listIssuesFromIndex(allocator: Allocator, repo: Repo, json: bool) !void {
    if (!fileExists(repo.index_path)) return;
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    var stmt = try db.prepare("SELECT id, title, state, author_principal, opened_at, body FROM issues ORDER BY opened_at DESC, id DESC");
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

        if (json) {
            var line: std.ArrayList(u8) = .empty;
            defer line.deinit(allocator);
            try line.append(allocator, '{');
            try appendJsonFieldString(&line, allocator, "id", id, true);
            try appendJsonFieldString(&line, allocator, "state", state, true);
            try appendJsonFieldString(&line, allocator, "title", title, true);
            try appendJsonFieldString(&line, allocator, "body", body, true);
            try appendJsonFieldString(&line, allocator, "author_principal", author, true);
            try appendJsonFieldString(&line, allocator, "opened_at", opened_at, true);
            if (try legacyGithubNumberForObjectInDb(&db, "issue", id)) |number| {
                try appendJsonFieldInteger(&line, allocator, "legacy_github_issue_number", number, true);
            }
            try appendIssueCollectionJsonField(&line, allocator, &db, "labels", "SELECT DISTINCT label FROM issue_labels WHERE issue_id = ? ORDER BY label", id, true);
            try appendIssueCollectionJsonField(&line, allocator, &db, "assignees", "SELECT DISTINCT assignee FROM issue_assignees WHERE issue_id = ? ORDER BY assignee", id, false);
            try line.append(allocator, '}');
            try out("{s}\n", .{line.items});
        } else {
            try out("#{s} {s} {s}\n", .{ id[0..@min(id.len, 7)], state, title });
        }
    }
}

pub fn showIssueFromIndex(allocator: Allocator, repo: Repo, issue_id: []const u8, json: bool) !void {
    if (!fileExists(repo.index_path)) return;
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    var stmt = try db.prepare(
        \\SELECT id, title, state, author_principal, author_device, opened_at, body
        \\FROM issues
        \\WHERE id = ?
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
        try appendJsonFieldString(&line, allocator, "opened_at", opened_at, true);
        if (try legacyGithubNumberForObjectInDb(&db, "issue", id)) |number| {
            try appendJsonFieldInteger(&line, allocator, "legacy_github_issue_number", number, true);
        }
        try appendIssueCollectionJsonField(&line, allocator, &db, "labels", "SELECT DISTINCT label FROM issue_labels WHERE issue_id = ? ORDER BY label", id, true);
        try appendIssueCollectionJsonField(&line, allocator, &db, "assignees", "SELECT DISTINCT assignee FROM issue_assignees WHERE issue_id = ? ORDER BY assignee", id, true);
        try appendCommitReferencesJsonField(&line, allocator, &db, "commit_references", "issue", id, false);
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

    try out("id:        {s}\n", .{id});
    try out("state:     {s}\n", .{state});
    try out("title:     {s}\n", .{title});
    try out("author:    {s}/{s}\n", .{ author_principal, author_device });
    try out("opened_at: {s}\n", .{opened_at});
    if (try legacyGithubNumberForObjectInDb(&db, "issue", id)) |number| {
        try out("github:    #{d}\n", .{number});
    }
    try out("labels:    {s}\n", .{labels});
    try out("assignees: {s}\n", .{assignees});
    try out("commits:   {s}\n", .{commit_references});
    try out("\n{s}\n", .{body});
}

pub fn listPullsFromIndex(allocator: Allocator, repo: Repo, json: bool) !void {
    if (!fileExists(repo.index_path)) return;
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    var stmt = try db.prepare(
        \\SELECT id, title, state, author_principal, opened_at, body, base_ref, head_ref, draft, merge_oid, target_oid
        \\FROM pulls
        \\ORDER BY opened_at DESC, id DESC
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
            try appendJsonFieldString(&line, allocator, "opened_at", opened_at, true);
            if (try legacyGithubNumberForObjectInDb(&db, "pull", id)) |number| {
                try appendJsonFieldInteger(&line, allocator, "legacy_github_pull_number", number, true);
            }
            try appendIssueCollectionJsonField(&line, allocator, &db, "labels", "SELECT DISTINCT label FROM pull_labels WHERE pull_id = ? ORDER BY label", id, true);
            try appendIssueCollectionJsonField(&line, allocator, &db, "assignees", "SELECT DISTINCT assignee FROM pull_assignees WHERE pull_id = ? ORDER BY assignee", id, true);
            try appendIssueCollectionJsonField(&line, allocator, &db, "reviewers", "SELECT DISTINCT reviewer FROM pull_reviewers WHERE pull_id = ? ORDER BY reviewer", id, false);
            try line.append(allocator, '}');
            try out("{s}\n", .{line.items});
        } else {
            try out("#{s} {s} {s}->{s} {s}\n", .{
                id[0..@min(id.len, 7)],
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
        \\SELECT id, title, state, author_principal, author_device, opened_at, body, base_ref, head_ref, draft, merge_oid, target_oid
        \\FROM pulls
        \\WHERE id = ?
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
        try appendJsonFieldString(&line, allocator, "opened_at", opened_at, true);
        if (try legacyGithubNumberForObjectInDb(&db, "pull", id)) |number| {
            try appendJsonFieldInteger(&line, allocator, "legacy_github_pull_number", number, true);
        }
        try appendIssueCollectionJsonField(&line, allocator, &db, "labels", "SELECT DISTINCT label FROM pull_labels WHERE pull_id = ? ORDER BY label", id, true);
        try appendIssueCollectionJsonField(&line, allocator, &db, "assignees", "SELECT DISTINCT assignee FROM pull_assignees WHERE pull_id = ? ORDER BY assignee", id, true);
        try appendIssueCollectionJsonField(&line, allocator, &db, "reviewers", "SELECT DISTINCT reviewer FROM pull_reviewers WHERE pull_id = ? ORDER BY reviewer", id, true);
        try appendCommitReferencesJsonField(&line, allocator, &db, "commit_references", "pull", id, false);
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

    try out("id:         {s}\n", .{id});
    try out("state:      {s}\n", .{state});
    try out("title:      {s}\n", .{title});
    try out("author:     {s}/{s}\n", .{ author_principal, author_device });
    try out("opened_at:  {s}\n", .{opened_at});
    if (try legacyGithubNumberForObjectInDb(&db, "pull", id)) |number| {
        try out("github:     #{d}\n", .{number});
    }
    try out("base:       {s}\n", .{base_ref});
    try out("head:       {s}\n", .{head_ref});
    try out("draft:      {s}\n", .{if (draft) "true" else "false"});
    try out("merge_oid:  {s}\n", .{if (merge_oid.len == 0) "(none)" else merge_oid});
    try out("target_oid: {s}\n", .{if (target_oid.len == 0) "(none)" else target_oid});
    try out("labels:     {s}\n", .{labels});
    try out("assignees:  {s}\n", .{assignees});
    try out("reviewers:  {s}\n", .{reviewers});
    try out("commits:    {s}\n", .{commit_references});
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
        \\SELECT id, body, redacted, author_principal, created_at
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

        if (json) {
            var line: std.ArrayList(u8) = .empty;
            defer line.deinit(allocator);
            try line.append(allocator, '{');
            try appendJsonFieldString(&line, allocator, "id", id, true);
            try appendJsonFieldBool(&line, allocator, "redacted", redacted, true);
            try appendJsonFieldString(&line, allocator, "body", if (redacted) "" else body, true);
            try appendJsonFieldString(&line, allocator, "author_principal", author, true);
            try appendJsonFieldString(&line, allocator, "created_at", created_at, false);
            try line.append(allocator, '}');
            try out("{s}\n", .{line.items});
        } else {
            try out("#{s} {s}: {s}\n", .{
                id[0..@min(id.len, 7)],
                author,
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
