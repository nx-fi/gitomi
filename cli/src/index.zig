const std = @import("std");
pub const sqlite = @cImport({
    @cInclude("sqlite3.h");
});

const errors = @import("errors.zig");
const event_mod = @import("event.zig");
const git = @import("git.zig");
const io = @import("io.zig");
const json_writer = @import("json_writer.zig");
const repo_mod = @import("repo.zig");
const util = @import("util.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const Repo = repo_mod.Repo;
const eprint = io.eprint;
const out = io.out;
const fileExists = util.fileExists;
const gitChecked = git.gitChecked;
const emptyTreeOid = git.emptyTreeOid;
const parseEventSummary = event_mod.parseEventSummary;
const appendJsonFieldString = json_writer.appendJsonFieldString;
const appendJsonFieldBool = json_writer.appendJsonFieldBool;
const appendJsonFieldInteger = json_writer.appendJsonFieldInteger;

const index_schema_version = "1";
pub const index_event_columns = "ref, \"commit\", tree, subject, empty_tree, valid_json, event_type, object_kind, object_id, actor_principal, actor_device, seq, occurred_at";

pub const IndexStats = struct {
    refs: usize = 0,
    events: usize = 0,
};

pub fn ensureIndex(allocator: Allocator, repo: Repo) !void {
    if (try isIndexFresh(allocator, repo)) return;
    _ = try rebuildIndex(allocator, repo);
}

pub const SqliteDb = struct {
    allocator: Allocator,
    db: *sqlite.sqlite3,
    quiet: bool,

    pub fn open(allocator: Allocator, path: []const u8, flags: c_int, quiet: bool) !SqliteDb {
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        var db_opt: ?*sqlite.sqlite3 = null;
        const rc = sqlite.sqlite3_open_v2(path_z.ptr, &db_opt, flags, null);
        if (rc != sqlite.SQLITE_OK) {
            const db = db_opt;
            if (!quiet) {
                if (db) |handle| {
                    try eprint("gt index: sqlite open {s}: {s}\n", .{ path, std.mem.span(sqlite.sqlite3_errmsg(handle)) });
                } else {
                    try eprint("gt index: sqlite open {s}: failed to allocate handle\n", .{path});
                }
            }
            if (db) |handle| _ = sqlite.sqlite3_close(handle);
            return CliError.SqliteFailed;
        }

        return .{
            .allocator = allocator,
            .db = db_opt.?,
            .quiet = quiet,
        };
    }

    pub fn deinit(self: *SqliteDb) void {
        _ = sqlite.sqlite3_close(self.db);
    }

    pub fn exec(self: *SqliteDb, sql_text: []const u8) !void {
        const sql_z = try self.allocator.dupeZ(u8, sql_text);
        defer self.allocator.free(sql_z);
        const rc = sqlite.sqlite3_exec(self.db, sql_z.ptr, null, null, null);
        if (rc != sqlite.SQLITE_OK) return sqliteFail(self.db, self.quiet, "exec");
    }

    pub fn prepare(self: *SqliteDb, sql_text: []const u8) !SqliteStmt {
        const sql_z = try self.allocator.dupeZ(u8, sql_text);
        defer self.allocator.free(sql_z);
        var stmt_opt: ?*sqlite.sqlite3_stmt = null;
        const rc = sqlite.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &stmt_opt, null);
        if (rc != sqlite.SQLITE_OK) return sqliteFail(self.db, self.quiet, "prepare");
        return .{
            .db = self.db,
            .stmt = stmt_opt.?,
            .quiet = self.quiet,
        };
    }
};

pub const SqliteStmt = struct {
    db: *sqlite.sqlite3,
    stmt: *sqlite.sqlite3_stmt,
    quiet: bool,

    pub fn deinit(self: *SqliteStmt) void {
        _ = sqlite.sqlite3_finalize(self.stmt);
    }

    pub fn reset(self: *SqliteStmt) !void {
        var rc = sqlite.sqlite3_reset(self.stmt);
        if (rc != sqlite.SQLITE_OK) return sqliteFail(self.db, self.quiet, "reset");
        rc = sqlite.sqlite3_clear_bindings(self.stmt);
        if (rc != sqlite.SQLITE_OK) return sqliteFail(self.db, self.quiet, "clear bindings");
    }

    pub fn step(self: *SqliteStmt) !bool {
        const rc = sqlite.sqlite3_step(self.stmt);
        if (rc == sqlite.SQLITE_ROW) return true;
        if (rc == sqlite.SQLITE_DONE) return false;
        return sqliteFail(self.db, self.quiet, "step");
    }

    pub fn stepDone(self: *SqliteStmt) !void {
        if (try self.step()) return sqliteFail(self.db, self.quiet, "expected done");
    }

    pub fn bindText(self: *SqliteStmt, index: c_int, value: []const u8) !void {
        if (value.len > std.math.maxInt(c_int)) return error.ValueTooLarge;
        const len: c_int = @intCast(value.len);
        const rc = sqlite.sqlite3_bind_text(self.stmt, index, value.ptr, len, null);
        if (rc != sqlite.SQLITE_OK) return sqliteFail(self.db, self.quiet, "bind text");
    }

    pub fn bindInt(self: *SqliteStmt, index: c_int, value: c_int) !void {
        const rc = sqlite.sqlite3_bind_int(self.stmt, index, value);
        if (rc != sqlite.SQLITE_OK) return sqliteFail(self.db, self.quiet, "bind int");
    }

    pub fn bindInt64(self: *SqliteStmt, index: c_int, value: i64) !void {
        const rc = sqlite.sqlite3_bind_int64(self.stmt, index, value);
        if (rc != sqlite.SQLITE_OK) return sqliteFail(self.db, self.quiet, "bind int64");
    }

    pub fn bindNull(self: *SqliteStmt, index: c_int) !void {
        const rc = sqlite.sqlite3_bind_null(self.stmt, index);
        if (rc != sqlite.SQLITE_OK) return sqliteFail(self.db, self.quiet, "bind null");
    }

    pub fn columnTextDup(self: *SqliteStmt, allocator: Allocator, index: c_int) ![]u8 {
        const len_raw = sqlite.sqlite3_column_bytes(self.stmt, index);
        if (len_raw <= 0) return allocator.dupe(u8, "");
        const text_ptr = sqlite.sqlite3_column_text(self.stmt, index);
        if (text_ptr == null) return allocator.dupe(u8, "");
        const ptr: [*]const u8 = @ptrCast(text_ptr);
        return allocator.dupe(u8, ptr[0..@as(usize, @intCast(len_raw))]);
    }

    pub fn columnInt(self: *SqliteStmt, index: c_int) c_int {
        return sqlite.sqlite3_column_int(self.stmt, index);
    }

    pub fn columnInt64(self: *SqliteStmt, index: c_int) i64 {
        return sqlite.sqlite3_column_int64(self.stmt, index);
    }

    pub fn columnIsNull(self: *SqliteStmt, index: c_int) bool {
        return sqlite.sqlite3_column_type(self.stmt, index) == sqlite.SQLITE_NULL;
    }
};

pub fn sqliteFail(db: ?*sqlite.sqlite3, quiet: bool, context: []const u8) CliError {
    if (!quiet) {
        if (db) |handle| {
            eprint("gt index: sqlite {s}: {s}\n", .{ context, std.mem.span(sqlite.sqlite3_errmsg(handle)) }) catch {};
        } else {
            eprint("gt index: sqlite {s} failed\n", .{context}) catch {};
        }
    }
    return CliError.SqliteFailed;
}

pub const IndexedEvent = struct {
    ref: []const u8,
    commit: []const u8,
    tree: []const u8,
    subject: []const u8,
    empty_tree: bool,
    valid_json: bool,
    event_type: []const u8,
    object_kind: []const u8,
    object_id: []const u8,
    actor_principal: []const u8,
    actor_device: []const u8,
    seq: ?i64,
    occurred_at: []const u8,
};

pub fn indexedEventFromStmt(allocator: Allocator, stmt: *SqliteStmt) !IndexedEvent {
    var ref: ?[]u8 = try stmt.columnTextDup(allocator, 0);
    errdefer if (ref) |value| allocator.free(value);
    var commit: ?[]u8 = try stmt.columnTextDup(allocator, 1);
    errdefer if (commit) |value| allocator.free(value);
    var tree: ?[]u8 = try stmt.columnTextDup(allocator, 2);
    errdefer if (tree) |value| allocator.free(value);
    var subject: ?[]u8 = try stmt.columnTextDup(allocator, 3);
    errdefer if (subject) |value| allocator.free(value);
    var event_type: ?[]u8 = try stmt.columnTextDup(allocator, 6);
    errdefer if (event_type) |value| allocator.free(value);
    var object_kind: ?[]u8 = try stmt.columnTextDup(allocator, 7);
    errdefer if (object_kind) |value| allocator.free(value);
    var object_id: ?[]u8 = try stmt.columnTextDup(allocator, 8);
    errdefer if (object_id) |value| allocator.free(value);
    var actor_principal: ?[]u8 = try stmt.columnTextDup(allocator, 9);
    errdefer if (actor_principal) |value| allocator.free(value);
    var actor_device: ?[]u8 = try stmt.columnTextDup(allocator, 10);
    errdefer if (actor_device) |value| allocator.free(value);
    var occurred_at: ?[]u8 = try stmt.columnTextDup(allocator, 12);
    errdefer if (occurred_at) |value| allocator.free(value);

    const event = IndexedEvent{
        .ref = ref.?,
        .commit = commit.?,
        .tree = tree.?,
        .subject = subject.?,
        .empty_tree = stmt.columnInt(4) != 0,
        .valid_json = stmt.columnInt(5) != 0,
        .event_type = event_type.?,
        .object_kind = object_kind.?,
        .object_id = object_id.?,
        .actor_principal = actor_principal.?,
        .actor_device = actor_device.?,
        .seq = if (stmt.columnIsNull(11)) null else stmt.columnInt64(11),
        .occurred_at = occurred_at.?,
    };
    ref = null;
    commit = null;
    tree = null;
    subject = null;
    event_type = null;
    object_kind = null;
    object_id = null;
    actor_principal = null;
    actor_device = null;
    occurred_at = null;
    return event;
}

pub fn freeIndexedEvent(allocator: Allocator, event: IndexedEvent) void {
    allocator.free(event.ref);
    allocator.free(event.commit);
    allocator.free(event.tree);
    allocator.free(event.subject);
    allocator.free(event.event_type);
    allocator.free(event.object_kind);
    allocator.free(event.object_id);
    allocator.free(event.actor_principal);
    allocator.free(event.actor_device);
    allocator.free(event.occurred_at);
}

pub fn isIndexFresh(allocator: Allocator, repo: Repo) !bool {
    if (!fileExists(repo.index_path)) return false;

    const current_refs = try currentIndexRefsRaw(allocator);
    defer allocator.free(current_refs);

    var db = SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, true) catch return false;
    defer db.deinit();

    const indexed_refs = indexedRefsRaw(allocator, &db) catch return false;
    defer allocator.free(indexed_refs);

    if (!std.mem.eql(u8, current_refs, indexed_refs)) return false;
    if (std.mem.trim(u8, current_refs, " \t\r\n").len != 0 and (countIndexedEventsInDb(&db) catch return false) == 0) {
        return false;
    }
    return true;
}

pub fn rebuildIndex(allocator: Allocator, repo: Repo) !IndexStats {
    try std.fs.cwd().makePath(repo.gitomi_dir);

    const refs_raw = try currentIndexRefsRaw(allocator);
    defer allocator.free(refs_raw);

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_CREATE, false);
    defer db.deinit();

    try db.exec("BEGIN IMMEDIATE");
    var committed = false;
    errdefer if (!committed) db.exec("ROLLBACK") catch {};

    try db.exec(
        \\DROP TABLE IF EXISTS meta;
        \\DROP TABLE IF EXISTS ref_heads;
        \\DROP TABLE IF EXISTS events;
    );
    try createIndexSchema(&db);

    const empty_tree = try emptyTreeOid(allocator);
    defer allocator.free(empty_tree);

    var meta_stmt = try db.prepare("INSERT INTO meta(key, value) VALUES (?, ?)");
    defer meta_stmt.deinit();
    try meta_stmt.reset();
    try meta_stmt.bindText(1, "schema_version");
    try meta_stmt.bindText(2, index_schema_version);
    try meta_stmt.stepDone();

    var ref_stmt = try db.prepare("INSERT INTO ref_heads(ref, oid) VALUES (?, ?)");
    defer ref_stmt.deinit();

    var event_stmt = try db.prepare(
        \\INSERT INTO events(
        \\  ref, "commit", tree, subject, empty_tree, valid_json,
        \\  event_type, object_kind, object_id, actor_principal, actor_device, seq, occurred_at
        \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    );
    defer event_stmt.deinit();

    var stats = IndexStats{};
    var it = std.mem.tokenizeScalar(u8, refs_raw, '\n');
    while (it.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const ref = std.mem.trim(u8, line[0..tab], " \t\r\n");
        const oid = std.mem.trim(u8, line[tab + 1 ..], " \t\r\n");
        if (ref.len == 0) continue;
        try ref_stmt.reset();
        try ref_stmt.bindText(1, ref);
        try ref_stmt.bindText(2, oid);
        try ref_stmt.stepDone();
        stats.refs += 1;
        stats.events += try indexRefEvents(allocator, &event_stmt, ref, empty_tree);
    }

    try db.exec("COMMIT");
    committed = true;

    return stats;
}

pub fn createIndexSchema(db: *SqliteDb) !void {
    try db.exec(
        \\CREATE TABLE meta (
        \\  key TEXT PRIMARY KEY,
        \\  value TEXT NOT NULL
        \\);
        \\CREATE TABLE ref_heads (
        \\  ref TEXT PRIMARY KEY,
        \\  oid TEXT NOT NULL
        \\);
        \\CREATE TABLE events (
        \\  ordinal INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  ref TEXT NOT NULL,
        \\  "commit" TEXT NOT NULL,
        \\  tree TEXT NOT NULL,
        \\  subject TEXT NOT NULL,
        \\  empty_tree INTEGER NOT NULL,
        \\  valid_json INTEGER NOT NULL,
        \\  event_type TEXT NOT NULL,
        \\  object_kind TEXT NOT NULL,
        \\  object_id TEXT NOT NULL,
        \\  actor_principal TEXT NOT NULL,
        \\  actor_device TEXT NOT NULL,
        \\  seq INTEGER,
        \\  occurred_at TEXT NOT NULL,
        \\  UNIQUE(ref, "commit")
        \\);
        \\CREATE INDEX events_ref_ordinal_idx ON events(ref, ordinal);
        \\CREATE INDEX events_type_ordinal_idx ON events(event_type, ordinal);
    );
}

pub fn currentIndexRefsRaw(allocator: Allocator) ![]u8 {
    return gitChecked(allocator, &.{
        "for-each-ref",
        "--sort=refname",
        "--format=%(refname)%09%(objectname)",
        "refs/gitomi/inbox",
    });
}

pub fn indexedRefsRaw(allocator: Allocator, db: *SqliteDb) ![]u8 {
    var stmt = try db.prepare("SELECT ref, oid FROM ref_heads ORDER BY ref");
    defer stmt.deinit();

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    while (try stmt.step()) {
        const ref = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(ref);
        const oid = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(oid);
        try buf.appendSlice(allocator, ref);
        try buf.append(allocator, '\t');
        try buf.appendSlice(allocator, oid);
        try buf.append(allocator, '\n');
    }
    return buf.toOwnedSlice(allocator);
}

pub fn indexRefEvents(allocator: Allocator, event_stmt: *SqliteStmt, ref: []const u8, empty_tree: []const u8) !usize {
    const log = try gitChecked(allocator, &.{
        "log",
        "--first-parent",
        "--reverse",
        "--format=%H%x00%T%x00%s%x00%b%x1e",
        ref,
    });
    defer allocator.free(log);

    var count: usize = 0;
    var records = std.mem.splitScalar(u8, log, 0x1e);
    while (records.next()) |record_raw| {
        const record = std.mem.trim(u8, record_raw, "\r\n");
        if (record.len == 0) continue;

        const first = std.mem.indexOfScalar(u8, record, 0) orelse continue;
        const second_rel = std.mem.indexOfScalar(u8, record[first + 1 ..], 0) orelse continue;
        const second = first + 1 + second_rel;
        const third_rel = std.mem.indexOfScalar(u8, record[second + 1 ..], 0) orelse continue;
        const third = second + 1 + third_rel;

        const commit = std.mem.trim(u8, record[0..first], " \t\r\n");
        const tree = std.mem.trim(u8, record[first + 1 .. second], " \t\r\n");
        const subject = record[second + 1 .. third];
        const body = std.mem.trim(u8, record[third + 1 ..], " \t\r\n");

        if (commit.len == 0) continue;
        try insertIndexedEvent(allocator, event_stmt, ref, commit, tree, subject, body, std.mem.eql(u8, tree, empty_tree));
        count += 1;
    }

    return count;
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
    try stmt.bindText(3, tree);
    try stmt.bindText(4, subject);
    try stmt.bindInt(5, if (empty_tree) 1 else 0);
    if (summary) |parsed| {
        try stmt.bindInt(6, 1);
        try stmt.bindText(7, parsed.event_type);
        try stmt.bindText(8, parsed.object_kind);
        try stmt.bindText(9, parsed.object_id);
        try stmt.bindText(10, parsed.actor_principal);
        try stmt.bindText(11, parsed.actor_device);
        if (parsed.seq) |seq| {
            try stmt.bindInt64(12, seq);
        } else try stmt.bindNull(12);
        try stmt.bindText(13, parsed.occurred_at);
    } else {
        try stmt.bindInt(6, 0);
        try stmt.bindText(7, "");
        try stmt.bindText(8, "");
        try stmt.bindText(9, "");
        try stmt.bindText(10, "");
        try stmt.bindText(11, "");
        try stmt.bindNull(12);
        try stmt.bindText(13, "");
    }
    try stmt.stepDone();
}

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
    var stmt = try db.prepare("SELECT COUNT(*) FROM events WHERE event_type = 'issue.opened'");
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

pub fn appendIndexedEventJson(buf: *std.ArrayList(u8), allocator: Allocator, event: IndexedEvent) !void {
    try buf.append(allocator, '{');
    try appendJsonFieldString(buf, allocator, "ref", event.ref, true);
    try appendJsonFieldString(buf, allocator, "commit", event.commit, true);
    try appendJsonFieldString(buf, allocator, "tree", event.tree, true);
    try appendJsonFieldString(buf, allocator, "subject", event.subject, true);
    try appendJsonFieldBool(buf, allocator, "empty_tree", event.empty_tree, true);
    try appendJsonFieldBool(buf, allocator, "valid_json", event.valid_json, event.valid_json);
    if (event.valid_json) {
        try appendJsonFieldString(buf, allocator, "event_type", event.event_type, true);
        try appendJsonFieldString(buf, allocator, "object_kind", event.object_kind, true);
        try appendJsonFieldString(buf, allocator, "object_id", event.object_id, true);
        try appendJsonFieldString(buf, allocator, "actor_principal", event.actor_principal, true);
        try appendJsonFieldString(buf, allocator, "actor_device", event.actor_device, true);
        if (event.seq) |seq| try appendJsonFieldInteger(buf, allocator, "seq", seq, true);
        try appendJsonFieldString(buf, allocator, "occurred_at", event.occurred_at, false);
    }
    try buf.append(allocator, '}');
}

pub fn printIndexedEvent(event: IndexedEvent) !void {
    const short = event.commit[0..@min(event.commit.len, 12)];

    if (event.valid_json) {
        try out("{s} {s} {s} #{s} {s}\n", .{
            short,
            event.ref,
            event.event_type,
            event.object_id[0..@min(event.object_id.len, 7)],
            event.subject,
        });
    } else {
        try out("{s} {s} invalid-event {s}\n", .{ short, event.ref, event.subject });
    }
}

test "indexed event json carries projection fields" {
    const event = IndexedEvent{
        .ref = "refs/gitomi/inbox/alice/laptop",
        .commit = "0123456789abcdef0123456789abcdef01234567",
        .tree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904",
        .subject = "issue.opened #018f000 Indexed",
        .empty_tree = true,
        .valid_json = true,
        .event_type = "issue.opened",
        .object_kind = "issue",
        .object_id = "018f0000-0000-7000-8000-000000000002",
        .actor_principal = "alice",
        .actor_device = "laptop",
        .seq = 7,
        .occurred_at = "2026-05-13T18:30:59Z",
    };

    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(std.testing.allocator);
    try appendIndexedEventJson(&line, std.testing.allocator, event);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line.items, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("refs/gitomi/inbox/alice/laptop", root.get("ref").?.string);
    try std.testing.expectEqual(true, root.get("empty_tree").?.bool);
    try std.testing.expectEqual(true, root.get("valid_json").?.bool);
    try std.testing.expectEqualStrings("issue.opened", root.get("event_type").?.string);
    try std.testing.expectEqual(@as(i64, 7), root.get("seq").?.integer);
}
