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
const runCommand = git.runCommand;
const max_git_output = git.max_git_output;
const parseEventSummary = event_mod.parseEventSummary;
const parseValidatedEnvelope = event_mod.parseValidatedEnvelope;
const ValidatedEnvelope = event_mod.ValidatedEnvelope;
const appendJsonFieldString = json_writer.appendJsonFieldString;
const appendJsonFieldBool = json_writer.appendJsonFieldBool;
const appendJsonFieldInteger = json_writer.appendJsonFieldInteger;
const appendJsonString = json_writer.appendJsonString;

const index_schema_version = "8";
pub const index_event_columns = "ref, \"commit\", event_hash, tree, subject, empty_tree, valid_json, event_type, object_kind, object_id, actor_principal, actor_device, seq, occurred_at, domain_status, rejection_reason";

pub const IndexStats = struct {
    refs: usize = 0,
    events: usize = 0,
};

const IndexAdmission = struct {
    allocator: Allocator,
    expected_repo_id: ?[]const u8,
    observed_repo_id: ?[]u8 = null,
    actor_seqs: std.BufSet,
    idempotency_keys: std.BufSet,
    actor_last_seq: std.StringHashMap(i64),

    fn init(allocator: Allocator, expected_repo_id: ?[]const u8) IndexAdmission {
        return .{
            .allocator = allocator,
            .expected_repo_id = expected_repo_id,
            .actor_seqs = std.BufSet.init(allocator),
            .idempotency_keys = std.BufSet.init(allocator),
            .actor_last_seq = std.StringHashMap(i64).init(allocator),
        };
    }

    fn deinit(self: *IndexAdmission) void {
        if (self.observed_repo_id) |repo_id| self.allocator.free(repo_id);
        self.actor_seqs.deinit();
        self.idempotency_keys.deinit();
        var keys = self.actor_last_seq.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        self.actor_last_seq.deinit();
    }

    fn accept(self: *IndexAdmission, envelope: ValidatedEnvelope) !bool {
        if (self.expected_repo_id) |expected| {
            if (!std.mem.eql(u8, envelope.repo_id, expected)) return false;
        } else if (self.observed_repo_id) |expected| {
            if (!std.mem.eql(u8, envelope.repo_id, expected)) return false;
        } else {
            self.observed_repo_id = try self.allocator.dupe(u8, envelope.repo_id);
        }

        const seq_key = try std.fmt.allocPrint(self.allocator, "{d}:{s}\x1f{d}:{s}\x1f{d}", .{
            envelope.actor_principal.len,
            envelope.actor_principal,
            envelope.actor_device.len,
            envelope.actor_device,
            envelope.seq,
        });
        defer self.allocator.free(seq_key);
        if (self.actor_seqs.contains(seq_key)) return false;
        try self.actor_seqs.insert(seq_key);

        const actor_key = try std.fmt.allocPrint(self.allocator, "{d}:{s}\x1f{d}:{s}", .{
            envelope.actor_principal.len,
            envelope.actor_principal,
            envelope.actor_device.len,
            envelope.actor_device,
        });
        errdefer self.allocator.free(actor_key);
        const seq_entry = try self.actor_last_seq.getOrPut(actor_key);
        if (seq_entry.found_existing) {
            self.allocator.free(actor_key);
            if (envelope.seq <= seq_entry.value_ptr.*) return false;
        }
        seq_entry.value_ptr.* = envelope.seq;

        const idem_key = try std.fmt.allocPrint(self.allocator, "{d}:{s}\x1f{d}:{s}", .{
            envelope.repo_id.len,
            envelope.repo_id,
            envelope.idempotency_key.len,
            envelope.idempotency_key,
        });
        defer self.allocator.free(idem_key);
        if (self.idempotency_keys.contains(idem_key)) return false;
        try self.idempotency_keys.insert(idem_key);

        return true;
    }
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
    event_hash: []const u8,
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
    domain_status: []const u8,
    rejection_reason: []const u8,
};

pub fn indexedEventFromStmt(allocator: Allocator, stmt: *SqliteStmt) !IndexedEvent {
    var ref: ?[]u8 = try stmt.columnTextDup(allocator, 0);
    errdefer if (ref) |value| allocator.free(value);
    var commit: ?[]u8 = try stmt.columnTextDup(allocator, 1);
    errdefer if (commit) |value| allocator.free(value);
    var event_hash: ?[]u8 = try stmt.columnTextDup(allocator, 2);
    errdefer if (event_hash) |value| allocator.free(value);
    var tree: ?[]u8 = try stmt.columnTextDup(allocator, 3);
    errdefer if (tree) |value| allocator.free(value);
    var subject: ?[]u8 = try stmt.columnTextDup(allocator, 4);
    errdefer if (subject) |value| allocator.free(value);
    var event_type: ?[]u8 = try stmt.columnTextDup(allocator, 7);
    errdefer if (event_type) |value| allocator.free(value);
    var object_kind: ?[]u8 = try stmt.columnTextDup(allocator, 8);
    errdefer if (object_kind) |value| allocator.free(value);
    var object_id: ?[]u8 = try stmt.columnTextDup(allocator, 9);
    errdefer if (object_id) |value| allocator.free(value);
    var actor_principal: ?[]u8 = try stmt.columnTextDup(allocator, 10);
    errdefer if (actor_principal) |value| allocator.free(value);
    var actor_device: ?[]u8 = try stmt.columnTextDup(allocator, 11);
    errdefer if (actor_device) |value| allocator.free(value);
    var occurred_at: ?[]u8 = try stmt.columnTextDup(allocator, 13);
    errdefer if (occurred_at) |value| allocator.free(value);
    var domain_status: ?[]u8 = try stmt.columnTextDup(allocator, 14);
    errdefer if (domain_status) |value| allocator.free(value);
    var rejection_reason: ?[]u8 = try stmt.columnTextDup(allocator, 15);
    errdefer if (rejection_reason) |value| allocator.free(value);

    const event = IndexedEvent{
        .ref = ref.?,
        .commit = commit.?,
        .event_hash = event_hash.?,
        .tree = tree.?,
        .subject = subject.?,
        .empty_tree = stmt.columnInt(5) != 0,
        .valid_json = stmt.columnInt(6) != 0,
        .event_type = event_type.?,
        .object_kind = object_kind.?,
        .object_id = object_id.?,
        .actor_principal = actor_principal.?,
        .actor_device = actor_device.?,
        .seq = if (stmt.columnIsNull(12)) null else stmt.columnInt64(12),
        .occurred_at = occurred_at.?,
        .domain_status = domain_status.?,
        .rejection_reason = rejection_reason.?,
    };
    ref = null;
    commit = null;
    event_hash = null;
    tree = null;
    subject = null;
    event_type = null;
    object_kind = null;
    object_id = null;
    actor_principal = null;
    actor_device = null;
    occurred_at = null;
    domain_status = null;
    rejection_reason = null;
    return event;
}

pub fn freeIndexedEvent(allocator: Allocator, event: IndexedEvent) void {
    allocator.free(event.ref);
    allocator.free(event.commit);
    allocator.free(event.event_hash);
    allocator.free(event.tree);
    allocator.free(event.subject);
    allocator.free(event.event_type);
    allocator.free(event.object_kind);
    allocator.free(event.object_id);
    allocator.free(event.actor_principal);
    allocator.free(event.actor_device);
    allocator.free(event.occurred_at);
    allocator.free(event.domain_status);
    allocator.free(event.rejection_reason);
}

pub fn isIndexFresh(allocator: Allocator, repo: Repo) !bool {
    if (!fileExists(repo.index_path)) return false;

    const current_refs = try currentIndexRefsRaw(allocator);
    defer allocator.free(current_refs);

    var db = SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, true) catch return false;
    defer db.deinit();

    if (!(try isSchemaFresh(allocator, &db))) return false;

    const indexed_refs = indexedRefsRaw(allocator, &db) catch return false;
    defer allocator.free(indexed_refs);

    if (!std.mem.eql(u8, current_refs, indexed_refs)) return false;
    return true;
}

fn isSchemaFresh(allocator: Allocator, db: *SqliteDb) !bool {
    var stmt = db.prepare("SELECT value FROM meta WHERE key = 'schema_version'") catch return false;
    defer stmt.deinit();
    if (!(stmt.step() catch return false)) return false;
    const value = stmt.columnTextDup(allocator, 0) catch return false;
    defer allocator.free(value);
    return std.mem.eql(u8, value, index_schema_version);
}

pub fn rebuildIndex(allocator: Allocator, repo: Repo) !IndexStats {
    try std.fs.cwd().makePath(repo.gitomi_dir);

    const refs_raw = try currentIndexRefsRaw(allocator);
    defer allocator.free(refs_raw);

    var cfg_opt: ?repo_mod.Config = repo_mod.loadConfig(allocator, repo.config_path) catch |err| switch (err) {
        CliError.ConfigNotFound, CliError.ConfigInvalid => null,
        else => return err,
    };
    defer if (cfg_opt) |*cfg| cfg.deinit();
    var admission = IndexAdmission.init(allocator, if (cfg_opt) |cfg| cfg.repo_id else null);
    defer admission.deinit();

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_CREATE, false);
    defer db.deinit();

    try db.exec("BEGIN IMMEDIATE");
    var committed = false;
    errdefer if (!committed) db.exec("ROLLBACK") catch {};

    try db.exec(
        \\DROP TABLE IF EXISTS meta;
        \\DROP TABLE IF EXISTS ref_heads;
        \\DROP TABLE IF EXISTS events;
        \\DROP TABLE IF EXISTS issues;
        \\DROP TABLE IF EXISTS issue_labels;
        \\DROP TABLE IF EXISTS issue_assignees;
        \\DROP TABLE IF EXISTS pulls;
        \\DROP TABLE IF EXISTS pull_labels;
        \\DROP TABLE IF EXISTS pull_assignees;
        \\DROP TABLE IF EXISTS pull_reviewers;
        \\DROP TABLE IF EXISTS comments;
        \\DROP TABLE IF EXISTS acl_roles;
        \\DROP TABLE IF EXISTS acl_role_events;
        \\DROP TABLE IF EXISTS identity_devices;
        \\DROP TABLE IF EXISTS identity_device_events;
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
        \\  ref, "commit", event_hash, tree, subject, body, empty_tree, valid_json,
        \\  event_type, object_kind, object_id, actor_principal, actor_device, seq, occurred_at,
        \\  domain_status, rejection_reason
        \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
        if (!std.mem.startsWith(u8, ref, "refs/gitomi/inbox/")) continue;
        stats.refs += 1;
        stats.events += try indexRefEvents(allocator, &event_stmt, &admission, ref, empty_tree);
    }

    try projectIndexedEvents(allocator, &db);

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
        \\  event_hash TEXT NOT NULL,
        \\  tree TEXT NOT NULL,
        \\  subject TEXT NOT NULL,
        \\  body TEXT NOT NULL,
        \\  empty_tree INTEGER NOT NULL,
        \\  valid_json INTEGER NOT NULL,
        \\  event_type TEXT NOT NULL,
        \\  object_kind TEXT NOT NULL,
        \\  object_id TEXT NOT NULL,
        \\  actor_principal TEXT NOT NULL,
        \\  actor_device TEXT NOT NULL,
        \\  seq INTEGER,
        \\  occurred_at TEXT NOT NULL,
        \\  domain_status TEXT NOT NULL,
        \\  rejection_reason TEXT NOT NULL,
        \\  UNIQUE(ref, "commit"),
        \\  UNIQUE(event_hash)
        \\);
        \\CREATE INDEX events_ref_ordinal_idx ON events(ref, ordinal);
        \\CREATE INDEX events_type_ordinal_idx ON events(event_type, ordinal);
        \\CREATE TABLE issues (
        \\  id TEXT PRIMARY KEY,
        \\  title TEXT NOT NULL,
        \\  title_occurred_at TEXT NOT NULL,
        \\  title_actor_principal TEXT NOT NULL,
        \\  title_event_hash TEXT NOT NULL,
        \\  body TEXT NOT NULL,
        \\  body_occurred_at TEXT NOT NULL,
        \\  body_actor_principal TEXT NOT NULL,
        \\  body_event_hash TEXT NOT NULL,
        \\  state TEXT NOT NULL,
        \\  state_occurred_at TEXT NOT NULL,
        \\  state_actor_principal TEXT NOT NULL,
        \\  state_event_hash TEXT NOT NULL,
        \\  opened_at TEXT NOT NULL,
        \\  author_principal TEXT NOT NULL,
        \\  author_device TEXT NOT NULL
        \\);
        \\CREATE INDEX issues_state_opened_idx ON issues(state, opened_at);
        \\CREATE TABLE issue_labels (
        \\  issue_id TEXT NOT NULL,
        \\  label TEXT NOT NULL,
        \\  add_hash TEXT NOT NULL,
        \\  PRIMARY KEY(issue_id, label, add_hash)
        \\);
        \\CREATE TABLE issue_assignees (
        \\  issue_id TEXT NOT NULL,
        \\  assignee TEXT NOT NULL,
        \\  add_hash TEXT NOT NULL,
        \\  PRIMARY KEY(issue_id, assignee, add_hash)
        \\);
        \\CREATE TABLE pulls (
        \\  id TEXT PRIMARY KEY,
        \\  title TEXT NOT NULL,
        \\  title_occurred_at TEXT NOT NULL,
        \\  title_actor_principal TEXT NOT NULL,
        \\  title_event_hash TEXT NOT NULL,
        \\  body TEXT NOT NULL,
        \\  body_occurred_at TEXT NOT NULL,
        \\  body_actor_principal TEXT NOT NULL,
        \\  body_event_hash TEXT NOT NULL,
        \\  state TEXT NOT NULL,
        \\  state_occurred_at TEXT NOT NULL,
        \\  state_actor_principal TEXT NOT NULL,
        \\  state_event_hash TEXT NOT NULL,
        \\  base_ref TEXT NOT NULL,
        \\  base_occurred_at TEXT NOT NULL,
        \\  base_actor_principal TEXT NOT NULL,
        \\  base_event_hash TEXT NOT NULL,
        \\  head_ref TEXT NOT NULL,
        \\  head_occurred_at TEXT NOT NULL,
        \\  head_actor_principal TEXT NOT NULL,
        \\  head_event_hash TEXT NOT NULL,
        \\  draft INTEGER NOT NULL,
        \\  merge_oid TEXT NOT NULL,
        \\  target_oid TEXT NOT NULL,
        \\  opened_at TEXT NOT NULL,
        \\  author_principal TEXT NOT NULL,
        \\  author_device TEXT NOT NULL
        \\);
        \\CREATE INDEX pulls_state_opened_idx ON pulls(state, opened_at);
        \\CREATE TABLE pull_labels (
        \\  pull_id TEXT NOT NULL,
        \\  label TEXT NOT NULL,
        \\  add_hash TEXT NOT NULL,
        \\  PRIMARY KEY(pull_id, label, add_hash)
        \\);
        \\CREATE TABLE pull_assignees (
        \\  pull_id TEXT NOT NULL,
        \\  assignee TEXT NOT NULL,
        \\  add_hash TEXT NOT NULL,
        \\  PRIMARY KEY(pull_id, assignee, add_hash)
        \\);
        \\CREATE TABLE pull_reviewers (
        \\  pull_id TEXT NOT NULL,
        \\  reviewer TEXT NOT NULL,
        \\  add_hash TEXT NOT NULL,
        \\  PRIMARY KEY(pull_id, reviewer, add_hash)
        \\);
        \\CREATE TABLE comments (
        \\  id TEXT PRIMARY KEY,
        \\  parent_kind TEXT NOT NULL,
        \\  parent_id TEXT NOT NULL,
        \\  body TEXT NOT NULL,
        \\  body_occurred_at TEXT NOT NULL,
        \\  body_actor_principal TEXT NOT NULL,
        \\  body_event_hash TEXT NOT NULL,
        \\  redacted INTEGER NOT NULL,
        \\  redacted_at TEXT NOT NULL,
        \\  redacted_actor_principal TEXT NOT NULL,
        \\  redacted_event_hash TEXT NOT NULL,
        \\  created_at TEXT NOT NULL,
        \\  author_principal TEXT NOT NULL,
        \\  author_device TEXT NOT NULL
        \\);
        \\CREATE INDEX comments_parent_created_idx ON comments(parent_kind, parent_id, created_at);
        \\CREATE TABLE acl_roles (
        \\  principal TEXT PRIMARY KEY,
        \\  role TEXT NOT NULL,
        \\  grant_event_hash TEXT NOT NULL
        \\);
        \\CREATE TABLE acl_role_events (
        \\  principal TEXT NOT NULL,
        \\  role TEXT NOT NULL,
        \\  event_hash TEXT NOT NULL,
        \\  event_type TEXT NOT NULL,
        \\  PRIMARY KEY(principal, event_hash)
        \\);
        \\CREATE INDEX acl_role_events_principal_idx ON acl_role_events(principal);
        \\CREATE TABLE identity_devices (
        \\  principal TEXT NOT NULL,
        \\  device TEXT NOT NULL,
        \\  key_fingerprint TEXT NOT NULL,
        \\  public_key TEXT NOT NULL,
        \\  added_event_hash TEXT NOT NULL,
        \\  revoked_event_hash TEXT,
        \\  PRIMARY KEY(principal, device, key_fingerprint)
        \\);
        \\CREATE INDEX identity_devices_principal_idx ON identity_devices(principal);
        \\CREATE TABLE identity_device_events (
        \\  principal TEXT NOT NULL,
        \\  device TEXT NOT NULL,
        \\  key_fingerprint TEXT NOT NULL,
        \\  public_key TEXT NOT NULL,
        \\  event_hash TEXT NOT NULL,
        \\  event_type TEXT NOT NULL,
        \\  PRIMARY KEY(principal, device, event_hash)
        \\);
        \\CREATE INDEX identity_device_events_device_idx ON identity_device_events(principal, device);
    );
}

pub fn currentIndexRefsRaw(allocator: Allocator) ![]u8 {
    return gitChecked(allocator, &.{
        "for-each-ref",
        "--sort=refname",
        "--format=%(refname)%09%(objectname)",
        "refs/gitomi/genesis",
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

fn indexRefEvents(
    allocator: Allocator,
    event_stmt: *SqliteStmt,
    admission: *IndexAdmission,
    ref: []const u8,
    empty_tree: []const u8,
) !usize {
    const log = try gitChecked(allocator, &.{
        "log",
        "--first-parent",
        "--reverse",
        "--format=%H%x00%T%x00%P%x00%s%x00%b%x1e",
        ref,
    });
    defer allocator.free(log);

    var count: usize = 0;
    var expected_first_parent: ?[]const u8 = null;
    var records = std.mem.splitScalar(u8, log, 0x1e);
    while (records.next()) |record_raw| {
        const record = std.mem.trim(u8, record_raw, "\r\n");
        if (record.len == 0) continue;

        const first = std.mem.indexOfScalar(u8, record, 0) orelse continue;
        const second_rel = std.mem.indexOfScalar(u8, record[first + 1 ..], 0) orelse continue;
        const second = first + 1 + second_rel;
        const third_rel = std.mem.indexOfScalar(u8, record[second + 1 ..], 0) orelse continue;
        const third = second + 1 + third_rel;
        const fourth_rel = std.mem.indexOfScalar(u8, record[third + 1 ..], 0) orelse continue;
        const fourth = third + 1 + fourth_rel;

        const commit = std.mem.trim(u8, record[0..first], " \t\r\n");
        const tree = std.mem.trim(u8, record[first + 1 .. second], " \t\r\n");
        const parents = std.mem.trim(u8, record[second + 1 .. third], " \t\r\n");
        const subject = record[third + 1 .. fourth];
        const body = std.mem.trim(u8, record[fourth + 1 ..], " \t\r\n");

        if (commit.len == 0) continue;
        defer expected_first_parent = commit;

        const empty_tree_ok = std.mem.eql(u8, tree, empty_tree);
        if (!empty_tree_ok) continue;
        if (subject.len > git.max_event_subject_bytes) continue;
        if (body.len > git.max_event_body_bytes) continue;
        if (!firstParentMatches(parents, expected_first_parent)) continue;
        if (!(try verifyCommitSignatureQuiet(allocator, commit))) continue;

        var envelope = parseValidatedEnvelope(allocator, body) catch continue;
        defer envelope.deinit();
        if (!(try admission.accept(envelope))) continue;

        try insertValidatedIndexedEvent(event_stmt, ref, commit, tree, subject, body, envelope);
        count += 1;
    }

    return count;
}

fn firstParentMatches(parents: []const u8, expected_first_parent: ?[]const u8) bool {
    var it = std.mem.tokenizeScalar(u8, parents, ' ');
    const first_parent = it.next();
    if (expected_first_parent) |expected| {
        return first_parent != null and std.mem.eql(u8, first_parent.?, expected);
    }
    return first_parent == null;
}

fn verifyCommitSignatureQuiet(allocator: Allocator, commit: []const u8) !bool {
    var argv = [_][]const u8{ "git", "verify-commit", commit };
    var result = try runCommand(allocator, &argv, null, max_git_output);
    defer result.deinit();
    return result.exitCode() == 0;
}

fn insertValidatedIndexedEvent(
    stmt: *SqliteStmt,
    ref: []const u8,
    commit: []const u8,
    tree: []const u8,
    subject: []const u8,
    body: []const u8,
    envelope: ValidatedEnvelope,
) !void {
    try stmt.reset();
    try stmt.bindText(1, ref);
    try stmt.bindText(2, commit);
    try stmt.bindText(3, commit);
    try stmt.bindText(4, tree);
    try stmt.bindText(5, subject);
    try stmt.bindText(6, body);
    try stmt.bindInt(7, 1);
    try stmt.bindInt(8, 1);
    try stmt.bindText(9, envelope.event_type);
    try stmt.bindText(10, envelope.object_kind);
    try stmt.bindText(11, envelope.object_id);
    try stmt.bindText(12, envelope.actor_principal);
    try stmt.bindText(13, envelope.actor_device);
    try stmt.bindInt64(14, envelope.seq);
    try stmt.bindText(15, envelope.occurred_at);
    try stmt.bindText(16, "pending");
    try stmt.bindText(17, "");
    try stmt.stepDone();
}

fn projectIndexedEvents(allocator: Allocator, db: *SqliteDb) !void {
    try seedGenesisAuthorization(allocator, db);

    var auth_stmt = try db.prepare("SELECT event_hash, body FROM events WHERE valid_json != 0 AND (event_type LIKE 'acl.%' OR event_type LIKE 'identity.%') ORDER BY ordinal");
    defer auth_stmt.deinit();
    while (try auth_stmt.step()) {
        const event_hash = try auth_stmt.columnTextDup(allocator, 0);
        defer allocator.free(event_hash);
        const body = try auth_stmt.columnTextDup(allocator, 1);
        defer allocator.free(body);
        try projectStoredEvent(allocator, db, event_hash, body, true);
    }

    var stmt = try db.prepare("SELECT event_hash, body FROM events WHERE valid_json != 0 AND event_type NOT LIKE 'acl.%' AND event_type NOT LIKE 'identity.%' ORDER BY ordinal");
    defer stmt.deinit();

    while (try stmt.step()) {
        const event_hash = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(event_hash);
        const body = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(body);
        try projectStoredEvent(allocator, db, event_hash, body, false);
    }
}

fn projectStoredEvent(allocator: Allocator, db: *SqliteDb, event_hash: []const u8, body: []const u8, auth_phase: bool) !void {
    var envelope = parseValidatedEnvelope(allocator, body) catch {
        try markDomainRejected(db, event_hash, "invalid_event_envelope");
        return;
    };
    defer envelope.deinit();

    if (try authorizationRejection(allocator, db, envelope, body)) |reason| {
        try markDomainRejected(db, event_hash, reason);
        return;
    }

    const rejection = if (auth_phase)
        if (std.mem.startsWith(u8, envelope.event_type, "acl."))
            try applyAclProjection(allocator, db, event_hash, envelope, body)
        else
            try applyIdentityProjection(allocator, db, event_hash, envelope, body)
    else if (std.mem.startsWith(u8, envelope.event_type, "issue."))
        try applyIssueProjection(allocator, db, event_hash, envelope, body)
    else if (std.mem.startsWith(u8, envelope.event_type, "pull."))
        try applyPullProjection(allocator, db, event_hash, envelope, body)
    else if (std.mem.startsWith(u8, envelope.event_type, "comment."))
        try applyCommentProjection(allocator, db, event_hash, envelope, body)
    else
        null;

    if (rejection) |reason| {
        try markDomainRejected(db, event_hash, reason);
    } else {
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

fn authorizationRejection(allocator: Allocator, db: *SqliteDb, envelope: ValidatedEnvelope, body: []const u8) !?[]const u8 {
    const role = (try currentRole(allocator, db, envelope.actor_principal)) orelse return "unauthorized_principal";
    defer allocator.free(role);
    if (!(try currentDeviceActive(db, envelope.actor_principal, envelope.actor_device))) return "unauthorized_device";

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

fn currentRole(allocator: Allocator, db: *SqliteDb, principal: []const u8) !?[]u8 {
    var stmt = try db.prepare("SELECT role FROM acl_roles WHERE principal = ?");
    defer stmt.deinit();
    try stmt.bindText(1, principal);
    if (!(try stmt.step())) return null;
    return try stmt.columnTextDup(allocator, 0);
}

fn currentDeviceActive(db: *SqliteDb, principal: []const u8, device: []const u8) !bool {
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
        const actor_role = (try currentRole(allocator, db, envelope.actor_principal)) orelse return "unauthorized_principal";
        defer allocator.free(actor_role);
        if (!roleAtLeast(actor_role, role)) return "privilege_escalation";
        try insertAclHistory(db, principal, role, event_hash, envelope.event_type);
        try upsertAclRole(db, principal, role, event_hash);
        return null;
    }

    if (std.mem.eql(u8, envelope.event_type, "acl.role_revoked")) {
        const existing_role = (try currentRole(allocator, db, principal)) orelse return "role_not_granted";
        defer allocator.free(existing_role);
        if (!std.mem.eql(u8, existing_role, role)) return "role_mismatch";
        if (std.mem.eql(u8, principal, envelope.actor_principal) and std.mem.eql(u8, role, "owner")) {
            const owners = try countCurrentOwners(db);
            if (owners <= 1) return "last_owner";
        }
        try insertAclHistory(db, principal, role, event_hash, envelope.event_type);
        try deleteAclRole(db, principal);
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
        try replaceIdentityDevice(db, principal, device, fingerprint, public_key, event_hash, null);
        return null;
    }

    if (std.mem.eql(u8, envelope.event_type, "identity.device_revoked")) {
        if (!(try currentDeviceActive(db, principal, device))) return "device_not_active";
        try insertIdentityHistory(db, principal, device, "", "", event_hash, envelope.event_type);
        try revokeIdentityDevice(db, principal, device, event_hash);
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

fn countCurrentOwners(db: *SqliteDb) !usize {
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

fn revokeIdentityDevice(db: *SqliteDb, principal: []const u8, device: []const u8, revoked_event_hash: []const u8) !void {
    var stmt = try db.prepare("UPDATE identity_devices SET revoked_event_hash = ? WHERE principal = ? AND device = ? AND revoked_event_hash IS NULL");
    defer stmt.deinit();
    try stmt.bindText(1, revoked_event_hash);
    try stmt.bindText(2, principal);
    try stmt.bindText(3, device);
    try stmt.stepDone();
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

fn applyIssueProjection(allocator: Allocator, db: *SqliteDb, event_hash: []const u8, envelope: ValidatedEnvelope, body: []const u8) !?[]const u8 {
    if (!std.mem.startsWith(u8, envelope.event_type, "issue.")) return null;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return "invalid_event_envelope",
    };
    const payload_value = root.get("payload") orelse return "invalid_event_envelope";
    const payload = switch (payload_value) {
        .object => |object| object,
        else => return "invalid_event_envelope",
    };

    if (std.mem.eql(u8, envelope.event_type, "issue.opened")) {
        if (!(try creationEventWins(db, "issue.opened", envelope.object_id, event_hash))) return "duplicate_object_id";
        const title = event_mod.jsonString(payload.get("title")) orelse return "invalid_event_envelope";
        const body_value = event_mod.jsonString(payload.get("body")) orelse "";
        try insertIssueOpened(db, event_hash, envelope, title, body_value);
        try insertPayloadStringArray(db, payload, "labels", insert_issue_label_sql, envelope.object_id, event_hash);
        try insertPayloadStringArray(db, payload, "assignees", insert_issue_assignee_sql, envelope.object_id, event_hash);
        return null;
    }

    if (!(try issueExists(db, envelope.object_id))) return "object_not_created";

    if (std.mem.eql(u8, envelope.event_type, "issue.updated")) {
        try applyIssueUpdated(allocator, db, payload, event_hash, envelope);
    } else if (std.mem.eql(u8, envelope.event_type, "issue.title_set")) {
        const title = event_mod.jsonString(payload.get("title")) orelse return "invalid_event_envelope";
        try updateIssueScalar(allocator, db, envelope.object_id, title, event_hash, envelope, "title", "title_occurred_at", "title_actor_principal", "title_event_hash");
    } else if (std.mem.eql(u8, envelope.event_type, "issue.body_set")) {
        const body_value = event_mod.jsonString(payload.get("body")) orelse return "invalid_event_envelope";
        try updateIssueScalar(allocator, db, envelope.object_id, body_value, event_hash, envelope, "body", "body_occurred_at", "body_actor_principal", "body_event_hash");
    } else if (std.mem.eql(u8, envelope.event_type, "issue.state_set")) {
        const state = event_mod.jsonString(payload.get("state")) orelse return "invalid_event_envelope";
        try updateIssueScalar(allocator, db, envelope.object_id, state, event_hash, envelope, "state", "state_occurred_at", "state_actor_principal", "state_event_hash");
    } else if (std.mem.eql(u8, envelope.event_type, "issue.label_added")) {
        const label = event_mod.jsonString(payload.get("label")) orelse return "invalid_event_envelope";
        try insertIssueCollectionValue(db, insert_issue_label_sql, envelope.object_id, label, event_hash);
    } else if (std.mem.eql(u8, envelope.event_type, "issue.label_removed")) {
        const label = event_mod.jsonString(payload.get("label")) orelse return "invalid_event_envelope";
        try deleteIssueCollectionValue(allocator, db, "SELECT add_hash FROM issue_labels WHERE issue_id = ? AND label = ?", "DELETE FROM issue_labels WHERE issue_id = ? AND label = ? AND add_hash = ?", envelope.object_id, label, event_hash);
    } else if (std.mem.eql(u8, envelope.event_type, "issue.assignee_added")) {
        const assignee = event_mod.jsonString(payload.get("assignee")) orelse return "invalid_event_envelope";
        try insertIssueCollectionValue(db, insert_issue_assignee_sql, envelope.object_id, assignee, event_hash);
    } else if (std.mem.eql(u8, envelope.event_type, "issue.assignee_removed")) {
        const assignee = event_mod.jsonString(payload.get("assignee")) orelse return "invalid_event_envelope";
        try deleteIssueCollectionValue(allocator, db, "SELECT add_hash FROM issue_assignees WHERE issue_id = ? AND assignee = ?", "DELETE FROM issue_assignees WHERE issue_id = ? AND assignee = ? AND add_hash = ?", envelope.object_id, assignee, event_hash);
    }
    return null;
}

const insert_issue_label_sql = "INSERT OR IGNORE INTO issue_labels(issue_id, label, add_hash) VALUES (?, ?, ?)";
const insert_issue_assignee_sql = "INSERT OR IGNORE INTO issue_assignees(issue_id, assignee, add_hash) VALUES (?, ?, ?)";

fn applyIssueUpdated(
    allocator: Allocator,
    db: *SqliteDb,
    payload: std.json.ObjectMap,
    event_hash: []const u8,
    envelope: ValidatedEnvelope,
) !void {
    if (event_mod.jsonString(payload.get("title"))) |title| {
        try updateIssueScalar(allocator, db, envelope.object_id, title, event_hash, envelope, "title", "title_occurred_at", "title_actor_principal", "title_event_hash");
    }
    if (event_mod.jsonString(payload.get("body"))) |body_value| {
        try updateIssueScalar(allocator, db, envelope.object_id, body_value, event_hash, envelope, "body", "body_occurred_at", "body_actor_principal", "body_event_hash");
    }
    if (event_mod.jsonString(payload.get("state"))) |state| {
        try updateIssueScalar(allocator, db, envelope.object_id, state, event_hash, envelope, "state", "state_occurred_at", "state_actor_principal", "state_event_hash");
    }
    try insertPayloadStringArray(db, payload, "labels_added", insert_issue_label_sql, envelope.object_id, event_hash);
    try insertPayloadStringArray(db, payload, "assignees_added", insert_issue_assignee_sql, envelope.object_id, event_hash);
    try deleteIssuePayloadStringArray(allocator, db, payload, "labels_removed", "SELECT add_hash FROM issue_labels WHERE issue_id = ? AND label = ?", "DELETE FROM issue_labels WHERE issue_id = ? AND label = ? AND add_hash = ?", envelope.object_id, event_hash);
    try deleteIssuePayloadStringArray(allocator, db, payload, "assignees_removed", "SELECT add_hash FROM issue_assignees WHERE issue_id = ? AND assignee = ?", "DELETE FROM issue_assignees WHERE issue_id = ? AND assignee = ? AND add_hash = ?", envelope.object_id, event_hash);
}

fn insertIssueOpened(db: *SqliteDb, event_hash: []const u8, envelope: ValidatedEnvelope, title: []const u8, body: []const u8) !void {
    var stmt = try db.prepare(
        \\INSERT OR IGNORE INTO issues(
        \\  id,
        \\  title, title_occurred_at, title_actor_principal, title_event_hash,
        \\  body, body_occurred_at, body_actor_principal, body_event_hash,
        \\  state, state_occurred_at, state_actor_principal, state_event_hash,
        \\  opened_at, author_principal, author_device
        \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    );
    defer stmt.deinit();
    try stmt.bindText(1, envelope.object_id);
    try stmt.bindText(2, title);
    try stmt.bindText(3, envelope.occurred_at);
    try stmt.bindText(4, envelope.actor_principal);
    try stmt.bindText(5, event_hash);
    try stmt.bindText(6, body);
    try stmt.bindText(7, envelope.occurred_at);
    try stmt.bindText(8, envelope.actor_principal);
    try stmt.bindText(9, event_hash);
    try stmt.bindText(10, "open");
    try stmt.bindText(11, envelope.occurred_at);
    try stmt.bindText(12, envelope.actor_principal);
    try stmt.bindText(13, event_hash);
    try stmt.bindText(14, envelope.occurred_at);
    try stmt.bindText(15, envelope.actor_principal);
    try stmt.bindText(16, envelope.actor_device);
    try stmt.stepDone();
}

fn issueExists(db: *SqliteDb, issue_id: []const u8) !bool {
    var stmt = try db.prepare("SELECT 1 FROM issues WHERE id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    return try stmt.step();
}

fn updateIssueScalar(
    allocator: Allocator,
    db: *SqliteDb,
    issue_id: []const u8,
    value: []const u8,
    event_hash: []const u8,
    envelope: ValidatedEnvelope,
    comptime value_col: []const u8,
    comptime occurred_at_col: []const u8,
    comptime actor_col: []const u8,
    comptime event_hash_col: []const u8,
) !void {
    var select = try db.prepare("SELECT " ++ occurred_at_col ++ ", " ++ actor_col ++ ", " ++ event_hash_col ++ " FROM issues WHERE id = ?");
    defer select.deinit();
    try select.bindText(1, issue_id);
    if (!(try select.step())) return;
    const old_occurred_at = try select.columnTextDup(allocator, 0);
    defer allocator.free(old_occurred_at);
    const old_actor = try select.columnTextDup(allocator, 1);
    defer allocator.free(old_actor);
    const old_event_hash = try select.columnTextDup(allocator, 2);
    defer allocator.free(old_event_hash);

    if (!(try eventWins(allocator, event_hash, old_event_hash))) {
        return;
    }

    var update = try db.prepare("UPDATE issues SET " ++ value_col ++ " = ?, " ++ occurred_at_col ++ " = ?, " ++ actor_col ++ " = ?, " ++ event_hash_col ++ " = ? WHERE id = ?");
    defer update.deinit();
    try update.bindText(1, value);
    try update.bindText(2, envelope.occurred_at);
    try update.bindText(3, envelope.actor_principal);
    try update.bindText(4, event_hash);
    try update.bindText(5, issue_id);
    try update.stepDone();
}

fn eventWins(allocator: Allocator, new_event_hash: []const u8, old_event_hash: []const u8) !bool {
    if (old_event_hash.len == 0) return true;
    if (std.mem.eql(u8, new_event_hash, old_event_hash)) return false;
    if (try git.isAncestor(allocator, old_event_hash, new_event_hash)) return true;
    if (try git.isAncestor(allocator, new_event_hash, old_event_hash)) return false;
    return std.mem.order(u8, new_event_hash, old_event_hash) == .gt;
}

fn insertPayloadStringArray(
    db: *SqliteDb,
    payload: std.json.ObjectMap,
    key: []const u8,
    comptime sql_text: []const u8,
    issue_id: []const u8,
    event_hash: []const u8,
) !void {
    const value = payload.get(key) orelse return;
    const array = switch (value) {
        .array => |items| items,
        else => return,
    };
    for (array.items) |item| {
        if (item != .string) continue;
        try insertIssueCollectionValue(db, sql_text, issue_id, item.string, event_hash);
    }
}

fn deleteIssuePayloadStringArray(
    allocator: Allocator,
    db: *SqliteDb,
    payload: std.json.ObjectMap,
    key: []const u8,
    comptime select_sql: []const u8,
    comptime delete_sql: []const u8,
    issue_id: []const u8,
    event_hash: []const u8,
) !void {
    const value = payload.get(key) orelse return;
    const array = switch (value) {
        .array => |items| items,
        else => return,
    };
    for (array.items) |item| {
        if (item != .string) continue;
        try deleteIssueCollectionValue(allocator, db, select_sql, delete_sql, issue_id, item.string, event_hash);
    }
}

fn insertIssueCollectionValue(db: *SqliteDb, comptime sql_text: []const u8, issue_id: []const u8, value: []const u8, event_hash: []const u8) !void {
    var stmt = try db.prepare(sql_text);
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    try stmt.bindText(2, value);
    try stmt.bindText(3, event_hash);
    try stmt.stepDone();
}

fn deleteIssueCollectionValue(
    allocator: Allocator,
    db: *SqliteDb,
    comptime select_sql: []const u8,
    comptime delete_sql: []const u8,
    issue_id: []const u8,
    value: []const u8,
    remove_hash: []const u8,
) !void {
    var select = try db.prepare(select_sql);
    defer select.deinit();
    try select.bindText(1, issue_id);
    try select.bindText(2, value);
    while (try select.step()) {
        const add_hash = try select.columnTextDup(allocator, 0);
        defer allocator.free(add_hash);
        if (!(try git.isAncestor(allocator, add_hash, remove_hash))) continue;
        var delete = try db.prepare(delete_sql);
        defer delete.deinit();
        try delete.bindText(1, issue_id);
        try delete.bindText(2, value);
        try delete.bindText(3, add_hash);
        try delete.stepDone();
    }
}

fn applyPullProjection(allocator: Allocator, db: *SqliteDb, event_hash: []const u8, envelope: ValidatedEnvelope, body: []const u8) !?[]const u8 {
    if (!std.mem.startsWith(u8, envelope.event_type, "pull.")) return null;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return "invalid_event_envelope",
    };
    const payload_value = root.get("payload") orelse return "invalid_event_envelope";
    const payload = switch (payload_value) {
        .object => |object| object,
        else => return "invalid_event_envelope",
    };

    if (std.mem.eql(u8, envelope.event_type, "pull.opened")) {
        if (!(try creationEventWins(db, "pull.opened", envelope.object_id, event_hash))) return "duplicate_object_id";
        const title = event_mod.jsonString(payload.get("title")) orelse return "invalid_event_envelope";
        const base_ref = event_mod.jsonString(payload.get("base_ref")) orelse return "invalid_event_envelope";
        const head_ref = event_mod.jsonString(payload.get("head_ref")) orelse return "invalid_event_envelope";
        const body_value = event_mod.jsonString(payload.get("body")) orelse "";
        const draft = event_mod.jsonBool(payload.get("draft")) orelse false;
        try insertPullOpened(db, event_hash, envelope, title, body_value, base_ref, head_ref, draft);
        return null;
    }

    if (!(try pullExists(db, envelope.object_id))) return "object_not_created";

    if (std.mem.eql(u8, envelope.event_type, "pull.updated")) {
        try applyPullUpdated(allocator, db, payload, event_hash, envelope);
    } else if (std.mem.eql(u8, envelope.event_type, "pull.title_set")) {
        const title = event_mod.jsonString(payload.get("title")) orelse return "invalid_event_envelope";
        _ = try updatePullScalar(allocator, db, envelope.object_id, title, event_hash, envelope, "title", "title_occurred_at", "title_actor_principal", "title_event_hash");
    } else if (std.mem.eql(u8, envelope.event_type, "pull.body_set")) {
        const body_value = event_mod.jsonString(payload.get("body")) orelse return "invalid_event_envelope";
        _ = try updatePullScalar(allocator, db, envelope.object_id, body_value, event_hash, envelope, "body", "body_occurred_at", "body_actor_principal", "body_event_hash");
    } else if (std.mem.eql(u8, envelope.event_type, "pull.state_set")) {
        const state = event_mod.jsonString(payload.get("state")) orelse return "invalid_event_envelope";
        _ = try updatePullScalar(allocator, db, envelope.object_id, state, event_hash, envelope, "state", "state_occurred_at", "state_actor_principal", "state_event_hash");
    } else if (std.mem.eql(u8, envelope.event_type, "pull.base_set")) {
        const base_ref = event_mod.jsonString(payload.get("base_ref")) orelse return "invalid_event_envelope";
        _ = try updatePullScalar(allocator, db, envelope.object_id, base_ref, event_hash, envelope, "base_ref", "base_occurred_at", "base_actor_principal", "base_event_hash");
    } else if (std.mem.eql(u8, envelope.event_type, "pull.head_set")) {
        const head_ref = event_mod.jsonString(payload.get("head_ref")) orelse return "invalid_event_envelope";
        _ = try updatePullScalar(allocator, db, envelope.object_id, head_ref, event_hash, envelope, "head_ref", "head_occurred_at", "head_actor_principal", "head_event_hash");
    } else if (std.mem.eql(u8, envelope.event_type, "pull.label_added")) {
        const label = event_mod.jsonString(payload.get("label")) orelse return "invalid_event_envelope";
        try insertPullCollectionValue(db, insert_pull_label_sql, envelope.object_id, label, event_hash);
    } else if (std.mem.eql(u8, envelope.event_type, "pull.label_removed")) {
        const label = event_mod.jsonString(payload.get("label")) orelse return "invalid_event_envelope";
        try deletePullCollectionValue(allocator, db, "SELECT add_hash FROM pull_labels WHERE pull_id = ? AND label = ?", "DELETE FROM pull_labels WHERE pull_id = ? AND label = ? AND add_hash = ?", envelope.object_id, label, event_hash);
    } else if (std.mem.eql(u8, envelope.event_type, "pull.assignee_added")) {
        const assignee = event_mod.jsonString(payload.get("assignee")) orelse return "invalid_event_envelope";
        try insertPullCollectionValue(db, insert_pull_assignee_sql, envelope.object_id, assignee, event_hash);
    } else if (std.mem.eql(u8, envelope.event_type, "pull.assignee_removed")) {
        const assignee = event_mod.jsonString(payload.get("assignee")) orelse return "invalid_event_envelope";
        try deletePullCollectionValue(allocator, db, "SELECT add_hash FROM pull_assignees WHERE pull_id = ? AND assignee = ?", "DELETE FROM pull_assignees WHERE pull_id = ? AND assignee = ? AND add_hash = ?", envelope.object_id, assignee, event_hash);
    } else if (std.mem.eql(u8, envelope.event_type, "pull.reviewer_added")) {
        const reviewer = event_mod.jsonString(payload.get("reviewer")) orelse return "invalid_event_envelope";
        try insertPullCollectionValue(db, insert_pull_reviewer_sql, envelope.object_id, reviewer, event_hash);
    } else if (std.mem.eql(u8, envelope.event_type, "pull.reviewer_removed")) {
        const reviewer = event_mod.jsonString(payload.get("reviewer")) orelse return "invalid_event_envelope";
        try deletePullCollectionValue(allocator, db, "SELECT add_hash FROM pull_reviewers WHERE pull_id = ? AND reviewer = ?", "DELETE FROM pull_reviewers WHERE pull_id = ? AND reviewer = ? AND add_hash = ?", envelope.object_id, reviewer, event_hash);
    } else if (std.mem.eql(u8, envelope.event_type, "pull.merged")) {
        try applyPullMerged(allocator, db, envelope.object_id, event_mod.jsonString(payload.get("merge_oid")) orelse "", event_mod.jsonString(payload.get("target_oid")) orelse "", event_hash, envelope);
    }
    return null;
}

const insert_pull_label_sql = "INSERT OR IGNORE INTO pull_labels(pull_id, label, add_hash) VALUES (?, ?, ?)";
const insert_pull_assignee_sql = "INSERT OR IGNORE INTO pull_assignees(pull_id, assignee, add_hash) VALUES (?, ?, ?)";
const insert_pull_reviewer_sql = "INSERT OR IGNORE INTO pull_reviewers(pull_id, reviewer, add_hash) VALUES (?, ?, ?)";

fn applyPullUpdated(
    allocator: Allocator,
    db: *SqliteDb,
    payload: std.json.ObjectMap,
    event_hash: []const u8,
    envelope: ValidatedEnvelope,
) !void {
    if (event_mod.jsonString(payload.get("title"))) |title| {
        _ = try updatePullScalar(allocator, db, envelope.object_id, title, event_hash, envelope, "title", "title_occurred_at", "title_actor_principal", "title_event_hash");
    }
    if (event_mod.jsonString(payload.get("body"))) |body_value| {
        _ = try updatePullScalar(allocator, db, envelope.object_id, body_value, event_hash, envelope, "body", "body_occurred_at", "body_actor_principal", "body_event_hash");
    }
    if (event_mod.jsonString(payload.get("state"))) |state| {
        _ = try updatePullScalar(allocator, db, envelope.object_id, state, event_hash, envelope, "state", "state_occurred_at", "state_actor_principal", "state_event_hash");
    }
    if (event_mod.jsonString(payload.get("base_ref"))) |base_ref| {
        _ = try updatePullScalar(allocator, db, envelope.object_id, base_ref, event_hash, envelope, "base_ref", "base_occurred_at", "base_actor_principal", "base_event_hash");
    }
    if (event_mod.jsonString(payload.get("head_ref"))) |head_ref| {
        _ = try updatePullScalar(allocator, db, envelope.object_id, head_ref, event_hash, envelope, "head_ref", "head_occurred_at", "head_actor_principal", "head_event_hash");
    }
    try insertPullPayloadStringArray(db, payload, "labels_added", insert_pull_label_sql, envelope.object_id, event_hash);
    try insertPullPayloadStringArray(db, payload, "assignees_added", insert_pull_assignee_sql, envelope.object_id, event_hash);
    try insertPullPayloadStringArray(db, payload, "reviewers_added", insert_pull_reviewer_sql, envelope.object_id, event_hash);
    try deletePullPayloadStringArray(allocator, db, payload, "labels_removed", "SELECT add_hash FROM pull_labels WHERE pull_id = ? AND label = ?", "DELETE FROM pull_labels WHERE pull_id = ? AND label = ? AND add_hash = ?", envelope.object_id, event_hash);
    try deletePullPayloadStringArray(allocator, db, payload, "assignees_removed", "SELECT add_hash FROM pull_assignees WHERE pull_id = ? AND assignee = ?", "DELETE FROM pull_assignees WHERE pull_id = ? AND assignee = ? AND add_hash = ?", envelope.object_id, event_hash);
    try deletePullPayloadStringArray(allocator, db, payload, "reviewers_removed", "SELECT add_hash FROM pull_reviewers WHERE pull_id = ? AND reviewer = ?", "DELETE FROM pull_reviewers WHERE pull_id = ? AND reviewer = ? AND add_hash = ?", envelope.object_id, event_hash);
}

fn insertPullOpened(
    db: *SqliteDb,
    event_hash: []const u8,
    envelope: ValidatedEnvelope,
    title: []const u8,
    body: []const u8,
    base_ref: []const u8,
    head_ref: []const u8,
    draft: bool,
) !void {
    var stmt = try db.prepare(
        \\INSERT OR IGNORE INTO pulls(
        \\  id,
        \\  title, title_occurred_at, title_actor_principal, title_event_hash,
        \\  body, body_occurred_at, body_actor_principal, body_event_hash,
        \\  state, state_occurred_at, state_actor_principal, state_event_hash,
        \\  base_ref, base_occurred_at, base_actor_principal, base_event_hash,
        \\  head_ref, head_occurred_at, head_actor_principal, head_event_hash,
        \\  draft, merge_oid, target_oid,
        \\  opened_at, author_principal, author_device
        \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    );
    defer stmt.deinit();
    try stmt.bindText(1, envelope.object_id);
    try stmt.bindText(2, title);
    try stmt.bindText(3, envelope.occurred_at);
    try stmt.bindText(4, envelope.actor_principal);
    try stmt.bindText(5, event_hash);
    try stmt.bindText(6, body);
    try stmt.bindText(7, envelope.occurred_at);
    try stmt.bindText(8, envelope.actor_principal);
    try stmt.bindText(9, event_hash);
    try stmt.bindText(10, "open");
    try stmt.bindText(11, envelope.occurred_at);
    try stmt.bindText(12, envelope.actor_principal);
    try stmt.bindText(13, event_hash);
    try stmt.bindText(14, base_ref);
    try stmt.bindText(15, envelope.occurred_at);
    try stmt.bindText(16, envelope.actor_principal);
    try stmt.bindText(17, event_hash);
    try stmt.bindText(18, head_ref);
    try stmt.bindText(19, envelope.occurred_at);
    try stmt.bindText(20, envelope.actor_principal);
    try stmt.bindText(21, event_hash);
    try stmt.bindInt(22, if (draft) 1 else 0);
    try stmt.bindText(23, "");
    try stmt.bindText(24, "");
    try stmt.bindText(25, envelope.occurred_at);
    try stmt.bindText(26, envelope.actor_principal);
    try stmt.bindText(27, envelope.actor_device);
    try stmt.stepDone();
}

fn pullExists(db: *SqliteDb, pull_id: []const u8) !bool {
    var stmt = try db.prepare("SELECT 1 FROM pulls WHERE id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, pull_id);
    return try stmt.step();
}

fn updatePullScalar(
    allocator: Allocator,
    db: *SqliteDb,
    pull_id: []const u8,
    value: []const u8,
    event_hash: []const u8,
    envelope: ValidatedEnvelope,
    comptime value_col: []const u8,
    comptime occurred_at_col: []const u8,
    comptime actor_col: []const u8,
    comptime event_hash_col: []const u8,
) !bool {
    var select = try db.prepare("SELECT " ++ occurred_at_col ++ ", " ++ actor_col ++ ", " ++ event_hash_col ++ " FROM pulls WHERE id = ?");
    defer select.deinit();
    try select.bindText(1, pull_id);
    if (!(try select.step())) return false;
    const old_occurred_at = try select.columnTextDup(allocator, 0);
    defer allocator.free(old_occurred_at);
    const old_actor = try select.columnTextDup(allocator, 1);
    defer allocator.free(old_actor);
    const old_event_hash = try select.columnTextDup(allocator, 2);
    defer allocator.free(old_event_hash);

    if (!(try eventWins(allocator, event_hash, old_event_hash))) {
        return false;
    }

    var update = try db.prepare("UPDATE pulls SET " ++ value_col ++ " = ?, " ++ occurred_at_col ++ " = ?, " ++ actor_col ++ " = ?, " ++ event_hash_col ++ " = ? WHERE id = ?");
    defer update.deinit();
    try update.bindText(1, value);
    try update.bindText(2, envelope.occurred_at);
    try update.bindText(3, envelope.actor_principal);
    try update.bindText(4, event_hash);
    try update.bindText(5, pull_id);
    try update.stepDone();
    return true;
}

fn applyPullMerged(
    allocator: Allocator,
    db: *SqliteDb,
    pull_id: []const u8,
    merge_oid: []const u8,
    target_oid: []const u8,
    event_hash: []const u8,
    envelope: ValidatedEnvelope,
) !void {
    if (!(try updatePullScalar(allocator, db, pull_id, "merged", event_hash, envelope, "state", "state_occurred_at", "state_actor_principal", "state_event_hash"))) return;
    var update = try db.prepare("UPDATE pulls SET merge_oid = ?, target_oid = ? WHERE id = ?");
    defer update.deinit();
    try update.bindText(1, merge_oid);
    try update.bindText(2, target_oid);
    try update.bindText(3, pull_id);
    try update.stepDone();
}

fn insertPullCollectionValue(db: *SqliteDb, comptime sql_text: []const u8, pull_id: []const u8, value: []const u8, event_hash: []const u8) !void {
    var stmt = try db.prepare(sql_text);
    defer stmt.deinit();
    try stmt.bindText(1, pull_id);
    try stmt.bindText(2, value);
    try stmt.bindText(3, event_hash);
    try stmt.stepDone();
}

fn insertPullPayloadStringArray(
    db: *SqliteDb,
    payload: std.json.ObjectMap,
    key: []const u8,
    comptime sql_text: []const u8,
    pull_id: []const u8,
    event_hash: []const u8,
) !void {
    const value = payload.get(key) orelse return;
    const array = switch (value) {
        .array => |items| items,
        else => return,
    };
    for (array.items) |item| {
        if (item != .string) continue;
        try insertPullCollectionValue(db, sql_text, pull_id, item.string, event_hash);
    }
}

fn deletePullPayloadStringArray(
    allocator: Allocator,
    db: *SqliteDb,
    payload: std.json.ObjectMap,
    key: []const u8,
    comptime select_sql: []const u8,
    comptime delete_sql: []const u8,
    pull_id: []const u8,
    event_hash: []const u8,
) !void {
    const value = payload.get(key) orelse return;
    const array = switch (value) {
        .array => |items| items,
        else => return,
    };
    for (array.items) |item| {
        if (item != .string) continue;
        try deletePullCollectionValue(allocator, db, select_sql, delete_sql, pull_id, item.string, event_hash);
    }
}

fn deletePullCollectionValue(
    allocator: Allocator,
    db: *SqliteDb,
    comptime select_sql: []const u8,
    comptime delete_sql: []const u8,
    pull_id: []const u8,
    value: []const u8,
    remove_hash: []const u8,
) !void {
    var select = try db.prepare(select_sql);
    defer select.deinit();
    try select.bindText(1, pull_id);
    try select.bindText(2, value);
    while (try select.step()) {
        const add_hash = try select.columnTextDup(allocator, 0);
        defer allocator.free(add_hash);
        if (!(try git.isAncestor(allocator, add_hash, remove_hash))) continue;
        var delete = try db.prepare(delete_sql);
        defer delete.deinit();
        try delete.bindText(1, pull_id);
        try delete.bindText(2, value);
        try delete.bindText(3, add_hash);
        try delete.stepDone();
    }
}

fn applyCommentProjection(allocator: Allocator, db: *SqliteDb, event_hash: []const u8, envelope: ValidatedEnvelope, body: []const u8) !?[]const u8 {
    if (!std.mem.startsWith(u8, envelope.event_type, "comment.")) return null;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return "invalid_event_envelope",
    };
    const payload_value = root.get("payload") orelse return "invalid_event_envelope";
    const payload = switch (payload_value) {
        .object => |object| object,
        else => return "invalid_event_envelope",
    };

    if (std.mem.eql(u8, envelope.event_type, "comment.added")) {
        if (!(try creationEventWins(db, "comment.added", envelope.object_id, event_hash))) return "duplicate_object_id";
        const parent_kind = event_mod.jsonString(payload.get("parent_kind")) orelse return "invalid_event_envelope";
        const parent_id = event_mod.jsonString(payload.get("parent_id")) orelse return "invalid_event_envelope";
        if (std.mem.eql(u8, parent_kind, "issue")) {
            if (!(try issueExists(db, parent_id))) return "parent_not_created";
        } else if (std.mem.eql(u8, parent_kind, "pull")) {
            if (!(try pullExists(db, parent_id))) return "parent_not_created";
        }
        const comment_body = event_mod.jsonString(payload.get("body")) orelse return "invalid_event_envelope";
        try insertCommentAdded(db, event_hash, envelope, parent_kind, parent_id, comment_body);
    } else if (std.mem.eql(u8, envelope.event_type, "comment.body_set")) {
        if (!(try commentExists(db, envelope.object_id))) return "object_not_created";
        const comment_body = event_mod.jsonString(payload.get("body")) orelse return "invalid_event_envelope";
        try updateCommentBody(allocator, db, envelope.object_id, comment_body, event_hash, envelope);
    } else if (std.mem.eql(u8, envelope.event_type, "comment.redacted")) {
        if (!(try commentExists(db, envelope.object_id))) return "object_not_created";
        try redactComment(allocator, db, envelope.object_id, event_hash, envelope);
    }
    return null;
}

fn insertCommentAdded(
    db: *SqliteDb,
    event_hash: []const u8,
    envelope: ValidatedEnvelope,
    parent_kind: []const u8,
    parent_id: []const u8,
    body: []const u8,
) !void {
    var stmt = try db.prepare(
        \\INSERT OR IGNORE INTO comments(
        \\  id, parent_kind, parent_id,
        \\  body, body_occurred_at, body_actor_principal, body_event_hash,
        \\  redacted, redacted_at, redacted_actor_principal, redacted_event_hash,
        \\  created_at, author_principal, author_device
        \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    );
    defer stmt.deinit();
    try stmt.bindText(1, envelope.object_id);
    try stmt.bindText(2, parent_kind);
    try stmt.bindText(3, parent_id);
    try stmt.bindText(4, body);
    try stmt.bindText(5, envelope.occurred_at);
    try stmt.bindText(6, envelope.actor_principal);
    try stmt.bindText(7, event_hash);
    try stmt.bindInt(8, 0);
    try stmt.bindText(9, "");
    try stmt.bindText(10, "");
    try stmt.bindText(11, "");
    try stmt.bindText(12, envelope.occurred_at);
    try stmt.bindText(13, envelope.actor_principal);
    try stmt.bindText(14, envelope.actor_device);
    try stmt.stepDone();
}

fn commentExists(db: *SqliteDb, comment_id: []const u8) !bool {
    var stmt = try db.prepare("SELECT 1 FROM comments WHERE id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, comment_id);
    return try stmt.step();
}

fn updateCommentBody(allocator: Allocator, db: *SqliteDb, comment_id: []const u8, body: []const u8, event_hash: []const u8, envelope: ValidatedEnvelope) !void {
    var select = try db.prepare("SELECT body_occurred_at, body_actor_principal, body_event_hash FROM comments WHERE id = ?");
    defer select.deinit();
    try select.bindText(1, comment_id);
    if (!(try select.step())) return;
    const old_occurred_at = try select.columnTextDup(allocator, 0);
    defer allocator.free(old_occurred_at);
    const old_actor = try select.columnTextDup(allocator, 1);
    defer allocator.free(old_actor);
    const old_event_hash = try select.columnTextDup(allocator, 2);
    defer allocator.free(old_event_hash);

    if (!(try eventWins(allocator, event_hash, old_event_hash))) {
        return;
    }

    var update = try db.prepare("UPDATE comments SET body = ?, body_occurred_at = ?, body_actor_principal = ?, body_event_hash = ? WHERE id = ?");
    defer update.deinit();
    try update.bindText(1, body);
    try update.bindText(2, envelope.occurred_at);
    try update.bindText(3, envelope.actor_principal);
    try update.bindText(4, event_hash);
    try update.bindText(5, comment_id);
    try update.stepDone();
}

fn redactComment(allocator: Allocator, db: *SqliteDb, comment_id: []const u8, event_hash: []const u8, envelope: ValidatedEnvelope) !void {
    var select = try db.prepare("SELECT redacted, redacted_event_hash FROM comments WHERE id = ?");
    defer select.deinit();
    try select.bindText(1, comment_id);
    if (try select.step()) {
        const was_redacted = select.columnInt(0) != 0;
        const old_hash = try select.columnTextDup(allocator, 1);
        defer allocator.free(old_hash);
        if (was_redacted and !(try eventWins(allocator, event_hash, old_hash))) return;
    }
    var update = try db.prepare(
        \\UPDATE comments
        \\SET redacted = 1, redacted_at = ?, redacted_actor_principal = ?, redacted_event_hash = ?
        \\WHERE id = ?
    );
    defer update.deinit();
    try update.bindText(1, envelope.occurred_at);
    try update.bindText(2, envelope.actor_principal);
    try update.bindText(3, event_hash);
    try update.bindText(4, comment_id);
    try update.stepDone();
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
    try ensureIndex(allocator, repo);
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    var envelope = parseValidatedEnvelope(allocator, event_body) catch {
        try eprint("gt: refusing to create invalid event envelope\n", .{});
        return CliError.InvalidEvent;
    };
    defer envelope.deinit();

    if (try authorizationRejection(allocator, &db, envelope, event_body)) |reason| {
        try eprint("gt: refusing to create unauthorized event: {s}\n", .{reason});
        return CliError.Unauthorized;
    }
}

pub fn roleForPrincipal(allocator: Allocator, repo: Repo, principal: []const u8) !?[]u8 {
    try ensureIndex(allocator, repo);
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    return try currentRole(allocator, &db, principal);
}

pub fn countOwners(allocator: Allocator, repo: Repo) !usize {
    try ensureIndex(allocator, repo);
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    return try countCurrentOwners(&db);
}

pub fn isIdentityDeviceActive(allocator: Allocator, repo: Repo, principal: []const u8, device: []const u8) !bool {
    try ensureIndex(allocator, repo);
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    return try currentDeviceActive(&db, principal, device);
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
    const prefix = if (std.mem.startsWith(u8, raw_ref, "#")) raw_ref[1..] else raw_ref;
    if (prefix.len < 7) {
        try eprint("gt pull: pull reference must be at least 7 hex characters\n", .{});
        return CliError.InvalidReference;
    }
    for (prefix) |c| {
        if (!std.ascii.isHex(c) and c != '-') {
            try eprint("gt pull: pull reference must be a UUID or UUID prefix\n", .{});
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
        try eprint("gt pull: no pull matches #{s}\n", .{prefix});
        return CliError.NotFound;
    }
    const first = try stmt.columnTextDup(allocator, 0);
    errdefer allocator.free(first);
    if (try stmt.step()) {
        const second = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(second);
        try eprint("gt pull: ambiguous pull reference #{s} matches {s} and {s}\n", .{ prefix, first, second });
        return CliError.AmbiguousReference;
    }
    return first;
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
            try appendIssueCollectionJsonField(&line, allocator, &db, "labels", "SELECT DISTINCT label FROM issue_labels WHERE issue_id = ? ORDER BY label", id, true);
            try appendIssueCollectionJsonField(&line, allocator, &db, "assignees", "SELECT DISTINCT assignee FROM issue_assignees WHERE issue_id = ? ORDER BY assignee", id, false);
            try line.append(allocator, '}');
            try out("{s}\n", .{line.items});
        } else {
            try out("#{s} {s} {s}\n", .{ id[0..@min(id.len, 7)], state, title });
        }
    }
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
    try appendJsonFieldString(buf, allocator, "event_hash", event.event_hash, true);
    try appendJsonFieldString(buf, allocator, "tree", event.tree, true);
    try appendJsonFieldString(buf, allocator, "subject", event.subject, true);
    try appendJsonFieldBool(buf, allocator, "empty_tree", event.empty_tree, true);
    try appendJsonFieldBool(buf, allocator, "valid_json", event.valid_json, true);
    try appendJsonFieldString(buf, allocator, "domain_status", event.domain_status, event.rejection_reason.len != 0 or event.valid_json);
    if (event.rejection_reason.len != 0) {
        try appendJsonFieldString(buf, allocator, "rejection_reason", event.rejection_reason, event.valid_json);
    }
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
        try out("{s} {s} {s} #{s} {s}{s}{s}\n", .{
            short,
            event.ref,
            event.event_type,
            event.object_id[0..@min(event.object_id.len, 7)],
            event.subject,
            if (std.mem.eql(u8, event.domain_status, "rejected")) " rejected:" else "",
            if (std.mem.eql(u8, event.domain_status, "rejected")) event.rejection_reason else "",
        });
    } else {
        try out("{s} {s} invalid-event {s}\n", .{ short, event.ref, event.subject });
    }
}

test "indexed event json carries projection fields" {
    const event = IndexedEvent{
        .ref = "refs/gitomi/inbox/alice/laptop",
        .commit = "0123456789abcdef0123456789abcdef01234567",
        .event_hash = "0123456789abcdef0123456789abcdef01234567",
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
        .domain_status = "accepted",
        .rejection_reason = "",
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
    try std.testing.expectEqualStrings("accepted", root.get("domain_status").?.string);
    try std.testing.expectEqualStrings("issue.opened", root.get("event_type").?.string);
    try std.testing.expectEqual(@as(i64, 7), root.get("seq").?.integer);
}
