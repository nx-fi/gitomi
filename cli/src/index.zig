const std = @import("std");

const errors = @import("errors.zig");
const event_mod = @import("event.zig");
const git = @import("git.zig");
const inbox_commit = @import("inbox_commit.zig");
const index_event_row = @import("index/event_row.zig");
const index_projection = @import("index/projection.zig");
const index_query = @import("index/query.zig");
const index_schema = @import("index/schema.zig");
const index_sqlite = @import("index/sqlite_db.zig");
const io = @import("io.zig");
const json_writer = @import("json_writer.zig");
const repo_mod = @import("repo.zig");
const util = @import("util.zig");

pub const sqlite = index_sqlite.sqlite;
pub const SqliteDb = index_sqlite.SqliteDb;
pub const SqliteStmt = index_sqlite.SqliteStmt;
pub const sqliteFail = index_sqlite.sqliteFail;
pub const IndexedEvent = index_event_row.IndexedEvent;
pub const indexedEventFromStmt = index_event_row.indexedEventFromStmt;
pub const freeIndexedEvent = index_event_row.freeIndexedEvent;
pub const appendIndexedEventJson = index_event_row.appendIndexedEventJson;
pub const printIndexedEvent = index_event_row.printIndexedEvent;
pub const createCursorsSchema = index_schema.createCursorsSchema;
pub const createIndexSchema = index_schema.createIndexSchema;

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const Repo = repo_mod.Repo;
const eprint = io.eprint;
const out = io.out;
const fileExists = util.fileExists;
const gitChecked = git.gitChecked;
const gitCheckedMax = git.gitCheckedMax;
const emptyTreeOid = git.emptyTreeOid;
const runCommand = git.runCommand;
const max_git_output = git.max_git_output;
const parseValidatedEnvelope = event_mod.parseValidatedEnvelope;
const ValidatedEnvelope = event_mod.ValidatedEnvelope;
const appendJsonFieldString = json_writer.appendJsonFieldString;
const appendJsonFieldBool = json_writer.appendJsonFieldBool;
const appendJsonFieldInteger = json_writer.appendJsonFieldInteger;
const appendJsonFieldUnsigned = json_writer.appendJsonFieldUnsigned;
const appendJsonString = json_writer.appendJsonString;

// This shall never be updated. Keep index compatibility checks additive under v1.
const index_schema_version = "1";
pub const index_event_columns = index_query.index_event_columns;
const snapshot_schema = "urn:gitomi:snapshot:v1";
const snapshot_schema_version: u64 = 1;
const snapshot_prefix = "refs/gitomi/snapshots";
const snapshot_manifest_path = "manifest.json";
const snapshot_index_path = "index.sqlite";
pub const default_max_snapshot_tree_bytes: u64 = 64 * 1024 * 1024;
pub const default_max_snapshot_count: usize = 32;
pub const default_max_snapshot_total_bytes: u64 = default_max_snapshot_tree_bytes * default_max_snapshot_count;
pub const default_snapshot_min_new_events: usize = 64;
pub const default_snapshot_min_age_seconds: u64 = 24 * 60 * 60;

pub const IndexStats = struct {
    refs: usize = 0,
    events: usize = 0,
    new_events: usize = 0,
};

pub const SnapshotLimits = struct {
    max_tree_bytes: u64 = default_max_snapshot_tree_bytes,
    max_count: usize = default_max_snapshot_count,
    max_total_bytes: u64 = default_max_snapshot_total_bytes,
};

const SnapshotPolicy = struct {
    min_new_events: usize = default_snapshot_min_new_events,
    min_age_seconds: u64 = default_snapshot_min_age_seconds,
};

pub const SnapshotPruneOptions = struct {
    dry_run: bool = false,
    max_tree_bytes: u64 = default_max_snapshot_tree_bytes,
    max_count: usize = default_max_snapshot_count,
    max_total_bytes: u64 = default_max_snapshot_total_bytes,

    fn limits(self: SnapshotPruneOptions) SnapshotLimits {
        return .{
            .max_tree_bytes = self.max_tree_bytes,
            .max_count = self.max_count,
            .max_total_bytes = self.max_total_bytes,
        };
    }
};

const IndexBuildLock = struct {
    allocator: Allocator,
    path: []u8,
    file: std.fs.File,

    fn deinit(self: *IndexBuildLock) void {
        self.file.close();
        self.allocator.free(self.path);
    }
};

const RefHead = struct {
    allocator: Allocator,
    ref: []u8,
    oid: []u8,

    fn deinit(self: *RefHead) void {
        self.allocator.free(self.ref);
        self.allocator.free(self.oid);
    }
};

const SnapshotRef = struct {
    allocator: Allocator,
    ref: []u8,
    oid: []u8,
    timestamp: i64,
    bytes: u64 = 0,
    prune: bool = false,

    fn deinit(self: *SnapshotRef) void {
        self.allocator.free(self.ref);
        self.allocator.free(self.oid);
    }
};

const LoadedSnapshot = struct {
    allocator: Allocator,
    ref: []u8,
    oid: []u8,
    covered_refs_raw: []u8,
    timestamp: i64,
    exact: bool,

    fn deinit(self: *LoadedSnapshot) void {
        self.allocator.free(self.ref);
        self.allocator.free(self.oid);
        self.allocator.free(self.covered_refs_raw);
    }
};

const IndexAdmission = struct {
    allocator: Allocator,
    expected_repo_id: ?[]const u8,
    observed_repo_id: ?[]u8 = null,
    actor_seqs: event_mod.ActorSeqAdmissionTracker,
    idempotency_keys: std.BufSet,

    fn init(allocator: Allocator, expected_repo_id: ?[]const u8) IndexAdmission {
        return .{
            .allocator = allocator,
            .expected_repo_id = expected_repo_id,
            .actor_seqs = event_mod.ActorSeqAdmissionTracker.init(allocator),
            .idempotency_keys = std.BufSet.init(allocator),
        };
    }

    fn deinit(self: *IndexAdmission) void {
        if (self.observed_repo_id) |repo_id| self.allocator.free(repo_id);
        self.actor_seqs.deinit();
        self.idempotency_keys.deinit();
    }

    fn accept(self: *IndexAdmission, envelope: ValidatedEnvelope) !bool {
        if (self.expected_repo_id) |expected| {
            if (!std.mem.eql(u8, envelope.repo_id, expected)) return false;
        } else if (self.observed_repo_id) |expected| {
            if (!std.mem.eql(u8, envelope.repo_id, expected)) return false;
        } else {
            self.observed_repo_id = try self.allocator.dupe(u8, envelope.repo_id);
        }

        switch (try self.actor_seqs.accept(envelope.actor_principal, envelope.actor_device, envelope.seq)) {
            .accepted => {},
            .duplicate, .stale => return false,
        }

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

    fn remember(self: *IndexAdmission, envelope: ValidatedEnvelope) !void {
        if (self.expected_repo_id) |expected| {
            if (!std.mem.eql(u8, envelope.repo_id, expected)) return error.InvalidSnapshot;
        } else if (self.observed_repo_id) |expected| {
            if (!std.mem.eql(u8, envelope.repo_id, expected)) return error.InvalidSnapshot;
        } else {
            self.observed_repo_id = try self.allocator.dupe(u8, envelope.repo_id);
        }

        try self.actor_seqs.rememberMax(envelope.actor_principal, envelope.actor_device, envelope.seq);

        const idem_key = try std.fmt.allocPrint(self.allocator, "{d}:{s}\x1f{d}:{s}", .{
            envelope.repo_id.len,
            envelope.repo_id,
            envelope.idempotency_key.len,
            envelope.idempotency_key,
        });
        defer self.allocator.free(idem_key);
        if (!self.idempotency_keys.contains(idem_key)) try self.idempotency_keys.insert(idem_key);
    }
};

pub fn ensureIndex(allocator: Allocator, repo: Repo) !void {
    enforceSnapshotRetention(allocator, SnapshotLimits{}) catch {};
    if (try isIndexFresh(allocator, repo)) return;

    var lock = try acquireIndexBuildLock(allocator, repo);
    defer lock.deinit();

    if (try isIndexFresh(allocator, repo)) return;
    _ = try rebuildIndexUnlocked(allocator, repo);
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
    if (!std.mem.eql(u8, value, index_schema_version)) return false;
    return requiredIndexTablesExist(db);
}

fn requiredIndexTablesExist(db: *SqliteDb) bool {
    var pull_metadata = db.prepare("SELECT pull_id FROM pull_metadata LIMIT 0") catch return false;
    defer pull_metadata.deinit();
    var projects_slug = db.prepare("SELECT slug FROM projects LIMIT 0") catch return false;
    defer projects_slug.deinit();
    var project_columns_ref = db.prepare("SELECT column_ref FROM project_columns LIMIT 0") catch return false;
    defer project_columns_ref.deinit();
    var issue_metadata_fields = db.prepare("SELECT issue_type, priority, status, issue_type_event_hash, priority_event_hash, status_event_hash FROM issue_metadata LIMIT 0") catch return false;
    defer issue_metadata_fields.deinit();
    var issue_relationships = db.prepare("SELECT source_issue_id, relationship, target_issue_id FROM issue_relationships LIMIT 0") catch return false;
    defer issue_relationships.deinit();
    var issue_concurrent_groups = db.prepare("SELECT issue_id, group_key FROM issue_concurrent_groups LIMIT 0") catch return false;
    defer issue_concurrent_groups.deinit();
    var project_memberships = db.prepare("SELECT project_id FROM project_memberships LIMIT 0") catch return false;
    defer project_memberships.deinit();
    var project_fields = db.prepare("SELECT id FROM project_fields LIMIT 0") catch return false;
    defer project_fields.deinit();
    var project_field_options = db.prepare("SELECT id FROM project_field_options LIMIT 0") catch return false;
    defer project_field_options.deinit();
    var project_field_values = db.prepare("SELECT project_id FROM project_field_values LIMIT 0") catch return false;
    defer project_field_values.deinit();
    var project_views = db.prepare("SELECT id FROM project_views LIMIT 0") catch return false;
    defer project_views.deinit();
    var label_definitions = db.prepare("SELECT id, position FROM label_definitions LIMIT 0") catch return false;
    defer label_definitions.deinit();
    return true;
}

pub fn rebuildIndex(allocator: Allocator, repo: Repo) !IndexStats {
    var lock = try acquireIndexBuildLock(allocator, repo);
    defer lock.deinit();
    return try rebuildIndexUnlocked(allocator, repo);
}

fn acquireIndexBuildLock(allocator: Allocator, repo: Repo) !IndexBuildLock {
    try std.fs.cwd().makePath(repo.gitomi_dir);
    const lock_path = try std.fs.path.join(allocator, &.{ repo.gitomi_dir, "index.lock" });
    errdefer allocator.free(lock_path);

    const file = try std.fs.createFileAbsolute(lock_path, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
    });

    return .{
        .allocator = allocator,
        .path = lock_path,
        .file = file,
    };
}

fn rebuildIndexUnlocked(allocator: Allocator, repo: Repo) !IndexStats {
    try std.fs.cwd().makePath(repo.gitomi_dir);

    const refs_raw = try currentIndexRefsRaw(allocator);
    defer allocator.free(refs_raw);

    const expected_repo_id = try expectedRepoIdForIndex(allocator, repo);
    defer if (expected_repo_id) |repo_id| allocator.free(repo_id);
    const genesis_oid = try git.resolveOptionalRef(allocator, repo_mod.genesis_ref);
    defer if (genesis_oid) |oid| allocator.free(oid);
    var admission = IndexAdmission.init(allocator, expected_repo_id);
    defer admission.deinit();

    const empty_tree = try emptyTreeOid(allocator);
    defer allocator.free(empty_tree);

    const limits = SnapshotLimits{};
    enforceSnapshotRetention(allocator, limits) catch {};

    // Do not hydrate the live projection from snapshot SQLite files. Snapshot refs are
    // ordinary Git refs that may arrive from a remote, so their embedded databases
    // cannot be trusted as authoritative projection state unless every covered event
    // has been replay-authenticated. Rebuild from signed event commits instead;
    // snapshots remain only a write-side cache until a verified loader exists.
    var stats = try rebuildIndexFromScratch(allocator, repo, refs_raw, &admission, empty_tree, genesis_oid);

    // For snapshot creation policy, read only the manifest JSON of the newest snapshot
    // (no SQLite data is loaded) to determine whether inbox coverage has advanced.
    // This prevents a snapshot from being written on every branch/tag update when no
    // new inbox events have arrived since the last snapshot.
    var maybe_snapshot_meta = loadNewestCoveringSnapshotMeta(allocator, refs_raw, limits) catch null;
    defer if (maybe_snapshot_meta) |*s| s.deinit();
    if (maybe_snapshot_meta) |*snapshot_meta| {
        stats.new_events = countEventsSinceSnapshot(allocator, snapshot_meta.covered_refs_raw, refs_raw) catch stats.events;
    }

    if (shouldCreateSnapshot(if (maybe_snapshot_meta) |*m| m else null, stats, SnapshotPolicy{}, std.time.timestamp())) {
        createIndexSnapshot(allocator, repo, refs_raw, limits) catch {};
        enforceSnapshotRetention(allocator, limits) catch {};
    }

    try writeCursorsAfterRebuild(allocator, repo);

    return stats;
}

fn expectedRepoIdForIndex(allocator: Allocator, repo: Repo) !?[]u8 {
    const genesis_oid = try git.resolveOptionalRef(allocator, repo_mod.genesis_ref);
    defer if (genesis_oid) |oid| allocator.free(oid);
    if (genesis_oid) |oid| {
        var manifest = try repo_mod.loadGenesisManifest(allocator, oid);
        defer manifest.deinit();
        return try allocator.dupe(u8, manifest.repo_id);
    }

    var cfg = repo_mod.loadConfig(allocator, repo.config_path) catch |err| switch (err) {
        CliError.ConfigNotFound, CliError.ConfigInvalid => return null,
        else => return err,
    };
    defer cfg.deinit();
    return try allocator.dupe(u8, cfg.repo_id);
}

pub fn ensureCursors(allocator: Allocator, repo: Repo) !void {
    if (fileExists(repo.cursors_path)) return;
    try std.fs.cwd().makePath(repo.gitomi_dir);
    try createCursorsDb(allocator, repo);
}

fn createCursorsDb(allocator: Allocator, repo: Repo) !void {
    var db = try SqliteDb.open(allocator, repo.cursors_path, sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_CREATE, false);
    defer db.deinit();
    try createCursorsSchema(&db);
}

pub fn updateRefCursor(allocator: Allocator, repo: Repo, ref: []const u8, oid: []const u8, event_count: usize) !void {
    try ensureCursors(allocator, repo);
    var db = try SqliteDb.open(allocator, repo.cursors_path, sqlite.SQLITE_OPEN_READWRITE, false);
    defer db.deinit();
    var stmt = try db.prepare(
        \\INSERT INTO ref_cursors(ref, oid, event_count)
        \\VALUES (?, ?, ?)
        \\ON CONFLICT(ref) DO UPDATE SET oid = excluded.oid, event_count = excluded.event_count
    );
    defer stmt.deinit();
    try stmt.bindText(1, ref);
    try stmt.bindText(2, oid);
    try stmt.bindInt64(3, @intCast(event_count));
    try stmt.stepDone();
}

pub fn refCursorOid(allocator: Allocator, repo: Repo, ref: []const u8) !?[]u8 {
    if (!fileExists(repo.cursors_path)) return null;
    var db = SqliteDb.open(allocator, repo.cursors_path, sqlite.SQLITE_OPEN_READONLY, true) catch return null;
    defer db.deinit();
    var stmt = db.prepare("SELECT oid FROM ref_cursors WHERE ref = ?") catch return null;
    defer stmt.deinit();
    stmt.bindText(1, ref) catch return null;
    if (!(stmt.step() catch return null)) return null;
    return stmt.columnTextDup(allocator, 0) catch null;
}

fn writeCursorsAfterRebuild(allocator: Allocator, repo: Repo) !void {
    try ensureCursors(allocator, repo);
    var db = try SqliteDb.open(allocator, repo.cursors_path, sqlite.SQLITE_OPEN_READWRITE, false);
    defer db.deinit();
    try db.exec("DELETE FROM ref_cursors");

    const refs_raw = try gitChecked(allocator, &.{
        "for-each-ref",
        "--sort=refname",
        "--format=%(refname) %(objectname)",
        "refs/gitomi/inbox",
    });
    defer allocator.free(refs_raw);

    var stmt = try db.prepare(
        \\INSERT INTO ref_cursors(ref, oid, event_count)
        \\VALUES (?, ?, 0)
    );
    defer stmt.deinit();

    var it = std.mem.tokenizeScalar(u8, refs_raw, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        const space = std.mem.indexOfScalar(u8, trimmed, ' ') orelse continue;
        const ref = trimmed[0..space];
        const oid = trimmed[space + 1 ..];
        if (ref.len == 0 or oid.len == 0) continue;
        try stmt.reset();
        try stmt.bindText(1, ref);
        try stmt.bindText(2, oid);
        try stmt.stepDone();
    }
}

fn rebuildIndexFromScratch(
    allocator: Allocator,
    repo: Repo,
    refs_raw: []const u8,
    admission: *IndexAdmission,
    empty_tree: []const u8,
    genesis_oid: ?[]const u8,
) !IndexStats {
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_CREATE, false);
    defer db.deinit();

    try db.exec("BEGIN IMMEDIATE");
    var committed = false;
    errdefer if (!committed) db.exec("ROLLBACK") catch {};

    try dropIndexSchemaTables(&db);
    try createIndexSchema(&db);

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
        stats.events += try indexRefEvents(allocator, &event_stmt, admission, ref, null, empty_tree, genesis_oid);
    }
    stats.new_events = stats.events;

    try projectIndexedEvents(allocator, &db);
    try rebuildDerivedCommitReferences(allocator, &db, refs_raw);

    try db.exec("COMMIT");
    committed = true;

    return stats;
}

fn dropIndexSchemaTables(db: *SqliteDb) !void {
    try db.exec(
        \\DROP TABLE IF EXISTS meta;
        \\DROP TABLE IF EXISTS ref_heads;
        \\DROP TABLE IF EXISTS events;
        \\DROP TABLE IF EXISTS identities;
        \\DROP TABLE IF EXISTS identity_aliases;
        \\DROP TABLE IF EXISTS issues;
        \\DROP TABLE IF EXISTS issue_labels;
        \\DROP TABLE IF EXISTS issue_assignees;
        \\DROP TABLE IF EXISTS issue_metadata;
        \\DROP TABLE IF EXISTS issue_projects;
        \\DROP TABLE IF EXISTS issue_relationships;
        \\DROP TABLE IF EXISTS issue_concurrent_groups;
        \\DROP TABLE IF EXISTS projects;
        \\DROP TABLE IF EXISTS project_columns;
        \\DROP TABLE IF EXISTS project_memberships;
        \\DROP TABLE IF EXISTS project_fields;
        \\DROP TABLE IF EXISTS project_field_options;
        \\DROP TABLE IF EXISTS project_field_values;
        \\DROP TABLE IF EXISTS project_views;
        \\DROP TABLE IF EXISTS milestones;
        \\DROP TABLE IF EXISTS label_definitions;
        \\DROP TABLE IF EXISTS pulls;
        \\DROP TABLE IF EXISTS pull_labels;
        \\DROP TABLE IF EXISTS pull_assignees;
        \\DROP TABLE IF EXISTS pull_reviewers;
        \\DROP TABLE IF EXISTS pull_metadata;
        \\DROP TABLE IF EXISTS comments;
        \\DROP TABLE IF EXISTS reactions;
        \\DROP TABLE IF EXISTS commit_references;
        \\DROP TABLE IF EXISTS legacy_aliases;
        \\DROP TABLE IF EXISTS acl_roles;
        \\DROP TABLE IF EXISTS acl_role_events;
        \\DROP TABLE IF EXISTS acl_delegations;
        \\DROP TABLE IF EXISTS acl_delegation_events;
        \\DROP TABLE IF EXISTS identity_devices;
        \\DROP TABLE IF EXISTS identity_device_events;
    );
}

pub fn currentIndexRefsRaw(allocator: Allocator) ![]u8 {
    return gitChecked(allocator, &.{
        "for-each-ref",
        "--sort=refname",
        "--format=%(refname)%09%(objectname)",
        "refs/gitomi/genesis",
        "refs/gitomi/inbox",
        "refs/heads",
        "refs/tags",
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

pub fn enforceSnapshotRetention(allocator: Allocator, limits: SnapshotLimits) !void {
    var refs = try loadSnapshotRefs(allocator);
    defer freeSnapshotRefs(allocator, &refs);

    try markSnapshotRetention(allocator, &refs, limits);
    for (refs.items) |*ref| {
        if (!ref.prune) continue;
        const deleted = try gitChecked(allocator, &.{ "update-ref", "-d", ref.ref });
        defer allocator.free(deleted);
    }
}

pub fn pruneSnapshots(allocator: Allocator, options: SnapshotPruneOptions) !void {
    var refs = try loadSnapshotRefs(allocator);
    defer freeSnapshotRefs(allocator, &refs);

    if (refs.items.len == 0) {
        try out("no Gitomi index snapshot refs\n", .{});
        return;
    }

    try markSnapshotRetention(allocator, &refs, options.limits());

    var pruned: usize = 0;
    for (refs.items) |*ref| {
        if (!ref.prune) continue;
        pruned += 1;
        if (options.dry_run) {
            try out("would prune {s} ({d} bytes)\n", .{ ref.ref, ref.bytes });
        } else {
            const deleted = try gitChecked(allocator, &.{ "update-ref", "-d", ref.ref });
            defer allocator.free(deleted);
            try out("pruned {s} ({d} bytes)\n", .{ ref.ref, ref.bytes });
        }
    }

    try out("{s}: {d} pruned, {d} retained\n", .{
        if (options.dry_run) "index snapshots prune dry-run" else "index snapshots prune",
        pruned,
        refs.items.len - pruned,
    });
}

fn markSnapshotRetention(allocator: Allocator, refs: *std.ArrayList(SnapshotRef), limits: SnapshotLimits) !void {
    var retained_count: usize = 0;
    var retained_bytes: u64 = 0;
    for (refs.items) |*ref| {
        ref.bytes = snapshotTreeBytes(allocator, ref.oid) catch limits.max_tree_bytes +| 1;
        ref.prune = false;
        if (limits.max_tree_bytes != 0 and ref.bytes > limits.max_tree_bytes) ref.prune = true;
        if (!ref.prune and limits.max_count != 0 and retained_count >= limits.max_count) ref.prune = true;
        if (!ref.prune and limits.max_total_bytes != 0 and retained_bytes +| ref.bytes > limits.max_total_bytes) ref.prune = true;

        if (!ref.prune) {
            retained_count += 1;
            retained_bytes += ref.bytes;
        }
    }
}

pub fn parseSnapshotPruneNumber(raw: []const u8, label: []const u8) !u64 {
    return std.fmt.parseUnsigned(u64, raw, 10) catch {
        try eprint("gt index snapshots prune: {s} must be a non-negative integer\n", .{label});
        return CliError.UserError;
    };
}

fn shouldCreateSnapshot(snapshot: ?*const LoadedSnapshot, stats: IndexStats, policy: SnapshotPolicy, now: i64) bool {
    if (stats.events == 0) return false;

    const loaded = snapshot orelse return true;
    if (loaded.exact) return false;
    if (stats.new_events == 0) return false;
    if (policy.min_new_events == 0 or stats.new_events >= policy.min_new_events) return true;
    if (policy.min_age_seconds == 0) return false;

    const age_seconds: u64 = if (now > loaded.timestamp) @intCast(now - loaded.timestamp) else 0;
    return age_seconds >= policy.min_age_seconds;
}

test "snapshot policy checkpoints first, threshold, and aged incremental rebuilds" {
    const policy = SnapshotPolicy{ .min_new_events = 64, .min_age_seconds = 100 };

    try std.testing.expect(!shouldCreateSnapshot(null, .{ .events = 0, .new_events = 0 }, policy, 1000));
    try std.testing.expect(shouldCreateSnapshot(null, .{ .events = 1, .new_events = 1 }, policy, 1000));

    const exact = LoadedSnapshot{
        .allocator = std.testing.allocator,
        .ref = "",
        .oid = "",
        .covered_refs_raw = "",
        .timestamp = 900,
        .exact = true,
    };
    try std.testing.expect(!shouldCreateSnapshot(&exact, .{ .events = 10, .new_events = 64 }, policy, 1000));

    const stale = LoadedSnapshot{
        .allocator = std.testing.allocator,
        .ref = "",
        .oid = "",
        .covered_refs_raw = "",
        .timestamp = 900,
        .exact = false,
    };
    try std.testing.expect(!shouldCreateSnapshot(&stale, .{ .events = 10, .new_events = 0 }, policy, 1000));
    try std.testing.expect(!shouldCreateSnapshot(&stale, .{ .events = 10, .new_events = 63 }, policy, 999));
    try std.testing.expect(shouldCreateSnapshot(&stale, .{ .events = 10, .new_events = 64 }, policy, 999));
    try std.testing.expect(shouldCreateSnapshot(&stale, .{ .events = 10, .new_events = 1 }, policy, 1000));
}

test "index schema reset drops identity tables" {
    const allocator = std.testing.allocator;
    var db = try SqliteDb.openWithOptions(allocator, ":memory:", sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_CREATE, true, .{ .enable_wal = false });
    defer db.deinit();

    try createIndexSchema(&db);
    try dropIndexSchemaTables(&db);
    try createIndexSchema(&db);

    var identities = try db.prepare("SELECT id FROM identities LIMIT 0");
    defer identities.deinit();
    var identity_aliases = try db.prepare("SELECT alias_kind FROM identity_aliases LIMIT 0");
    defer identity_aliases.deinit();
}

test "index admission rejects repo, sequence, and idempotency conflicts" {
    var admission = IndexAdmission.init(std.testing.allocator, "repo-a");
    defer admission.deinit();

    var first = try testEnvelope(std.testing.allocator, "repo-a", "alice", "laptop", 1, "idem-1");
    defer first.deinit();
    try std.testing.expect(try admission.accept(first));

    var next = try testEnvelope(std.testing.allocator, "repo-a", "alice", "laptop", 2, "idem-2");
    defer next.deinit();
    try std.testing.expect(try admission.accept(next));

    var stale_seq = try testEnvelope(std.testing.allocator, "repo-a", "alice", "laptop", 2, "idem-3");
    defer stale_seq.deinit();
    try std.testing.expect(!try admission.accept(stale_seq));

    var duplicate_idem = try testEnvelope(std.testing.allocator, "repo-a", "bob", "desktop", 1, "idem-1");
    defer duplicate_idem.deinit();
    try std.testing.expect(!try admission.accept(duplicate_idem));

    var wrong_repo = try testEnvelope(std.testing.allocator, "repo-b", "alice", "laptop", 3, "idem-4");
    defer wrong_repo.deinit();
    try std.testing.expect(!try admission.accept(wrong_repo));
}

test "index admission can be seeded from remembered snapshot events" {
    var admission = IndexAdmission.init(std.testing.allocator, null);
    defer admission.deinit();

    var remembered = try testEnvelope(std.testing.allocator, "repo-a", "alice", "laptop", 5, "idem-5");
    defer remembered.deinit();
    try admission.remember(remembered);

    var stale = try testEnvelope(std.testing.allocator, "repo-a", "alice", "laptop", 4, "idem-6");
    defer stale.deinit();
    try std.testing.expect(!try admission.accept(stale));

    var wrong_repo = try testEnvelope(std.testing.allocator, "repo-b", "alice", "laptop", 6, "idem-7");
    defer wrong_repo.deinit();
    try std.testing.expectError(error.InvalidSnapshot, admission.remember(wrong_repo));
}

test "first parent matcher handles root and merge histories" {
    try std.testing.expect(firstParentMatches("", null));
    try std.testing.expect(!firstParentMatches("parent-a", null));
    try std.testing.expect(firstParentMatches("parent-a parent-b", "parent-a"));
    try std.testing.expect(!firstParentMatches("parent-b parent-a", "parent-a"));
}

test "ref head parsing skips malformed rows and finds oids" {
    const raw =
        " refs/gitomi/genesis \tabc123\n" ++
        "malformed\n" ++
        "refs/gitomi/inbox/alice/laptop\tdef456\n" ++
        "\n" ++
        "\tblank-ref\n" ++
        "refs/heads/main\t\n";
    var refs = try parseRefsRaw(std.testing.allocator, raw);
    defer freeRefHeads(std.testing.allocator, &refs);

    try std.testing.expectEqual(@as(usize, 2), refs.items.len);
    try std.testing.expectEqualStrings("abc123", findRefOid(refs.items, "refs/gitomi/genesis").?);
    try std.testing.expectEqualStrings("def456", findRefOid(refs.items, "refs/gitomi/inbox/alice/laptop").?);
    try std.testing.expect(findRefOid(refs.items, "refs/heads/main") == null);
}

test "snapshot manifest round trips covered refs and rejects invalid metadata" {
    const refs_raw =
        "refs/gitomi/genesis\tabc123\n" ++
        "refs/gitomi/inbox/alice/laptop\tdef456\n" ++
        "\n";
    const manifest = try buildSnapshotManifest(std.testing.allocator, refs_raw);
    defer std.testing.allocator.free(manifest);

    const covered = try parseSnapshotManifest(std.testing.allocator, manifest);
    defer std.testing.allocator.free(covered);
    try std.testing.expectEqualStrings(refs_raw, covered);

    try std.testing.expectError(
        error.InvalidSnapshot,
        parseSnapshotManifest(std.testing.allocator, "{\"$schema\":\"wrong\"}"),
    );
}

test "snapshot prune numbers require unsigned integers" {
    try std.testing.expectEqual(@as(u64, 42), try parseSnapshotPruneNumber("42", "max-count"));
    try std.testing.expectError(CliError.UserError, parseSnapshotPruneNumber("-1", "max-count"));
    try std.testing.expectError(CliError.UserError, parseSnapshotPruneNumber("many", "max-count"));
}

fn testEnvelope(
    allocator: Allocator,
    repo_id: []const u8,
    actor_principal: []const u8,
    actor_device: []const u8,
    seq: i64,
    idempotency_key: []const u8,
) !ValidatedEnvelope {
    return .{
        .allocator = allocator,
        .repo_id = try allocator.dupe(u8, repo_id),
        .event_uuid = try allocator.dupe(u8, "018f0000-0000-7000-8000-000000000000"),
        .event_type = try allocator.dupe(u8, "issue.opened"),
        .object_kind = try allocator.dupe(u8, "issue"),
        .object_id = try allocator.dupe(u8, "018f0000-0000-7000-8000-000000000001"),
        .idempotency_key = try allocator.dupe(u8, idempotency_key),
        .actor_principal = try allocator.dupe(u8, actor_principal),
        .actor_device = try allocator.dupe(u8, actor_device),
        .seq = seq,
        .occurred_at = try allocator.dupe(u8, "2026-05-15T12:00:00Z"),
    };
}

fn createIndexSnapshot(allocator: Allocator, repo: Repo, refs_raw: []const u8, limits: SnapshotLimits) !void {
    if (std.mem.trim(u8, refs_raw, " \t\r\n").len == 0) return;

    const stat = std.fs.cwd().statFile(repo.index_path) catch return;
    if (stat.size == 0) return;
    if (limits.max_tree_bytes != 0 and stat.size > limits.max_tree_bytes) return;

    const max_bytes = snapshotMaxOutputBytes(limits);
    const index_bytes = std.fs.cwd().readFileAlloc(allocator, repo.index_path, max_bytes) catch return;
    defer allocator.free(index_bytes);

    const manifest = try buildSnapshotManifest(allocator, refs_raw);
    defer allocator.free(manifest);
    if (limits.max_tree_bytes != 0 and index_bytes.len + manifest.len > limits.max_tree_bytes) return;

    const manifest_oid_raw = try git.gitCheckedInput(allocator, &.{ "hash-object", "-w", "--stdin" }, manifest);
    const manifest_oid = try util.trimOwned(allocator, manifest_oid_raw);
    defer allocator.free(manifest_oid);

    const index_oid_raw = try git.gitCheckedInput(allocator, &.{ "hash-object", "-w", "--stdin" }, index_bytes);
    const index_oid = try util.trimOwned(allocator, index_oid_raw);
    defer allocator.free(index_oid);

    const tree_input = try std.fmt.allocPrint(allocator, "100644 blob {s}\t{s}\n100644 blob {s}\t{s}\n", .{
        manifest_oid,
        snapshot_manifest_path,
        index_oid,
        snapshot_index_path,
    });
    defer allocator.free(tree_input);

    const tree_oid_raw = try git.gitCheckedInput(allocator, &.{"mktree"}, tree_input);
    const tree_oid = try util.trimOwned(allocator, tree_oid_raw);
    defer allocator.free(tree_oid);

    const snapshot_id = try util.newUuidV7(allocator);
    defer allocator.free(snapshot_id);
    const message = try std.fmt.allocPrint(allocator, "gitomi snapshot {s}", .{snapshot_id});
    defer allocator.free(message);

    const commit_oid_raw = try gitChecked(allocator, &.{ "commit-tree", tree_oid, "-m", message });
    const commit_oid = try util.trimOwned(allocator, commit_oid_raw);
    defer allocator.free(commit_oid);

    const snapshot_ref = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ snapshot_prefix, snapshot_id });
    defer allocator.free(snapshot_ref);
    const updated = try gitChecked(allocator, &.{ "update-ref", snapshot_ref, commit_oid });
    defer allocator.free(updated);
}

fn buildSnapshotManifest(allocator: Allocator, refs_raw: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.append(allocator, '{');
    try appendJsonFieldString(&buf, allocator, "$schema", snapshot_schema, true);
    try appendJsonFieldUnsigned(&buf, allocator, "schema_version", snapshot_schema_version, true);
    try appendJsonFieldString(&buf, allocator, "index_schema_version", index_schema_version, true);
    try appendJsonFieldInteger(&buf, allocator, "created_at_unix", std.time.timestamp(), true);
    try appendJsonFieldString(&buf, allocator, "covered_refs_raw", refs_raw, true);

    try appendJsonString(&buf, allocator, "covered_refs");
    try buf.appendSlice(allocator, ":[");
    var first = true;
    var it = std.mem.tokenizeScalar(u8, refs_raw, '\n');
    while (it.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const ref = std.mem.trim(u8, line[0..tab], " \t\r\n");
        const oid = std.mem.trim(u8, line[tab + 1 ..], " \t\r\n");
        if (ref.len == 0 or oid.len == 0) continue;
        if (!first) try buf.append(allocator, ',');
        first = false;
        try buf.append(allocator, '{');
        try appendJsonFieldString(&buf, allocator, "ref", ref, true);
        try appendJsonFieldString(&buf, allocator, "oid", oid, false);
        try buf.append(allocator, '}');
    }
    try buf.appendSlice(allocator, "],");

    try appendJsonString(&buf, allocator, "state");
    try buf.appendSlice(allocator, ":{");
    try appendJsonFieldString(&buf, allocator, "format", "sqlite-index", true);
    try appendJsonFieldString(&buf, allocator, "path", snapshot_index_path, false);
    try buf.appendSlice(allocator, "},");

    try appendJsonString(&buf, allocator, "legacy_aliases");
    try buf.appendSlice(allocator, ":{}");
    try buf.append(allocator, '}');
    return buf.toOwnedSlice(allocator);
}

fn loadSnapshotRefs(allocator: Allocator) !std.ArrayList(SnapshotRef) {
    const raw = try gitChecked(allocator, &.{
        "for-each-ref",
        "--sort=-committerdate",
        "--format=%(refname)%09%(objectname)%09%(committerdate:unix)",
        snapshot_prefix,
    });
    defer allocator.free(raw);

    var refs: std.ArrayList(SnapshotRef) = .empty;
    errdefer freeSnapshotRefs(allocator, &refs);

    var lines = std.mem.tokenizeScalar(u8, raw, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeScalar(u8, line, '\t');
        const ref = fields.next() orelse continue;
        const oid = fields.next() orelse continue;
        const ts_raw = fields.next() orelse "0";
        const timestamp = std.fmt.parseInt(i64, ts_raw, 10) catch 0;
        try refs.append(allocator, .{
            .allocator = allocator,
            .ref = try allocator.dupe(u8, ref),
            .oid = try allocator.dupe(u8, oid),
            .timestamp = timestamp,
        });
    }

    std.mem.sort(SnapshotRef, refs.items, {}, snapshotRefNewerThan);
    return refs;
}

fn snapshotRefNewerThan(_: void, left: SnapshotRef, right: SnapshotRef) bool {
    if (left.timestamp != right.timestamp) return left.timestamp > right.timestamp;
    return std.mem.order(u8, left.ref, right.ref) == .gt;
}

fn freeSnapshotRefs(allocator: Allocator, refs: *std.ArrayList(SnapshotRef)) void {
    for (refs.items) |*ref| ref.deinit();
    refs.deinit(allocator);
}

fn snapshotTreeBytes(allocator: Allocator, oid: []const u8) !u64 {
    const raw = try gitChecked(allocator, &.{ "ls-tree", "-r", "-l", oid });
    defer allocator.free(raw);

    var total: u64 = 0;
    var lines = std.mem.tokenizeScalar(u8, raw, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        _ = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const size_raw = fields.next() orelse continue;
        if (std.mem.eql(u8, size_raw, "-")) continue;
        total += std.fmt.parseUnsigned(u64, size_raw, 10) catch 0;
    }
    return total;
}

fn snapshotMaxOutputBytes(limits: SnapshotLimits) usize {
    const max = if (limits.max_tree_bytes == 0) default_max_snapshot_tree_bytes else limits.max_tree_bytes;
    const capped = @min(max +| (1024 * 1024), @as(u64, std.math.maxInt(usize)));
    return @intCast(capped);
}

fn parseRefsRaw(allocator: Allocator, raw: []const u8) !std.ArrayList(RefHead) {
    var refs: std.ArrayList(RefHead) = .empty;
    errdefer freeRefHeads(allocator, &refs);

    var it = std.mem.tokenizeScalar(u8, raw, '\n');
    while (it.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const ref = std.mem.trim(u8, line[0..tab], " \t\r\n");
        const oid = std.mem.trim(u8, line[tab + 1 ..], " \t\r\n");
        if (ref.len == 0 or oid.len == 0) continue;
        try refs.append(allocator, .{
            .allocator = allocator,
            .ref = try allocator.dupe(u8, ref),
            .oid = try allocator.dupe(u8, oid),
        });
    }

    return refs;
}

fn freeRefHeads(allocator: Allocator, refs: *std.ArrayList(RefHead)) void {
    for (refs.items) |*ref| ref.deinit();
    refs.deinit(allocator);
}

fn findRefOid(refs: []const RefHead, wanted: []const u8) ?[]const u8 {
    for (refs) |ref| {
        if (std.mem.eql(u8, ref.ref, wanted)) return ref.oid;
    }
    return null;
}

fn isDataPlaneIndexRef(ref: []const u8) bool {
    return std.mem.startsWith(u8, ref, "refs/heads/") or std.mem.startsWith(u8, ref, "refs/tags/");
}

fn snapshotShowFile(allocator: Allocator, oid: []const u8, path: []const u8, limits: SnapshotLimits) ![]u8 {
    const object_path = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ oid, path });
    defer allocator.free(object_path);
    return gitCheckedMax(allocator, &.{ "show", object_path }, snapshotMaxOutputBytes(limits));
}

fn parseSnapshotManifest(allocator: Allocator, bytes: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidSnapshot,
    };

    const schema = event_mod.jsonString(root.get("$schema")) orelse return error.InvalidSnapshot;
    if (!std.mem.eql(u8, schema, snapshot_schema)) return error.InvalidSnapshot;

    const version_value = root.get("schema_version") orelse return error.InvalidSnapshot;
    const version = switch (version_value) {
        .integer => |value| value,
        else => return error.InvalidSnapshot,
    };
    if (version < 0 or @as(u64, @intCast(version)) != snapshot_schema_version) return error.InvalidSnapshot;

    const index_version = event_mod.jsonString(root.get("index_schema_version")) orelse return error.InvalidSnapshot;
    if (!std.mem.eql(u8, index_version, index_schema_version)) return error.InvalidSnapshot;

    const covered_refs_raw = event_mod.jsonString(root.get("covered_refs_raw")) orelse return error.InvalidSnapshot;
    if (std.mem.trim(u8, covered_refs_raw, " \t\r\n").len == 0) return error.InvalidSnapshot;

    const state = switch (root.get("state") orelse return error.InvalidSnapshot) {
        .object => |object| object,
        else => return error.InvalidSnapshot,
    };
    const state_format = event_mod.jsonString(state.get("format")) orelse return error.InvalidSnapshot;
    const state_path = event_mod.jsonString(state.get("path")) orelse return error.InvalidSnapshot;
    if (!std.mem.eql(u8, state_format, "sqlite-index")) return error.InvalidSnapshot;
    if (!std.mem.eql(u8, state_path, snapshot_index_path)) return error.InvalidSnapshot;

    return allocator.dupe(u8, covered_refs_raw);
}

fn snapshotCoverageValid(allocator: Allocator, covered_refs_raw: []const u8, current_refs_raw: []const u8) !bool {
    var covered_refs = try parseRefsRaw(allocator, covered_refs_raw);
    defer freeRefHeads(allocator, &covered_refs);
    if (covered_refs.items.len == 0) return false;

    var current_refs = try parseRefsRaw(allocator, current_refs_raw);
    defer freeRefHeads(allocator, &current_refs);

    for (covered_refs.items) |covered| {
        if (isDataPlaneIndexRef(covered.ref)) continue;

        const current_oid = findRefOid(current_refs.items, covered.ref) orelse return false;
        if (std.mem.eql(u8, covered.ref, repo_mod.genesis_ref)) {
            if (!std.mem.eql(u8, current_oid, covered.oid)) return false;
        } else if (std.mem.startsWith(u8, covered.ref, "refs/gitomi/inbox/")) {
            if (!(try git.isAncestor(allocator, covered.oid, current_oid))) return false;
        } else {
            return false;
        }
    }

    return true;
}

fn countEventsSinceSnapshot(allocator: Allocator, covered_refs_raw: []const u8, current_refs_raw: []const u8) !usize {
    var covered_refs = try parseRefsRaw(allocator, covered_refs_raw);
    defer freeRefHeads(allocator, &covered_refs);

    var current_refs = try parseRefsRaw(allocator, current_refs_raw);
    defer freeRefHeads(allocator, &current_refs);

    const genesis_oid = findRefOid(current_refs.items, repo_mod.genesis_ref);
    var count: usize = 0;
    for (current_refs.items) |current| {
        if (!std.mem.startsWith(u8, current.ref, "refs/gitomi/inbox/")) continue;

        const covered_oid = findRefOid(covered_refs.items, current.ref);
        const target = if (covered_oid) |old_oid|
            try std.fmt.allocPrint(allocator, "{s}..{s}", .{ old_oid, current.oid })
        else if (genesis_oid) |oid|
            try std.fmt.allocPrint(allocator, "{s}..{s}", .{ oid, current.oid })
        else
            try allocator.dupe(u8, current.oid);
        defer allocator.free(target);

        const raw = try gitChecked(allocator, &.{ "rev-list", "--first-parent", "--count", target });
        defer allocator.free(raw);
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        count += std.fmt.parseUnsigned(usize, trimmed, 10) catch 0;
    }
    return count;
}

/// Reads only the manifest JSON of the newest snapshot ref (no SQLite data is loaded)
/// and returns a synthetic LoadedSnapshot for use by shouldCreateSnapshot.  This
/// allows the snapshot creation policy to suppress redundant snapshots when no new
/// inbox events have arrived since the last snapshot (e.g. on a bare branch/tag update).
fn loadNewestCoveringSnapshotMeta(
    allocator: Allocator,
    current_refs_raw: []const u8,
    limits: SnapshotLimits,
) !?LoadedSnapshot {
    var refs = try loadSnapshotRefs(allocator);
    defer freeSnapshotRefs(allocator, &refs);

    for (refs.items) |*ref| {
        const manifest_bytes = snapshotShowFile(allocator, ref.oid, snapshot_manifest_path, limits) catch continue;
        defer allocator.free(manifest_bytes);

        const covered_refs_raw = parseSnapshotManifest(allocator, manifest_bytes) catch continue;
        errdefer allocator.free(covered_refs_raw);

        const coverage_ok = snapshotCoverageValid(allocator, covered_refs_raw, current_refs_raw) catch {
            allocator.free(covered_refs_raw);
            continue;
        };
        if (!coverage_ok) {
            allocator.free(covered_refs_raw);
            continue;
        }

        return .{
            .allocator = allocator,
            .ref = try allocator.dupe(u8, ref.ref),
            .oid = try allocator.dupe(u8, ref.oid),
            .covered_refs_raw = covered_refs_raw,
            .timestamp = ref.timestamp,
            .exact = std.mem.eql(u8, covered_refs_raw, current_refs_raw),
        };
    }
    return null;
}

fn indexRefEvents(
    allocator: Allocator,
    event_stmt: *SqliteStmt,
    admission: *IndexAdmission,
    ref: []const u8,
    base: ?[]const u8,
    empty_tree: []const u8,
    genesis_oid: ?[]const u8,
) !usize {
    const target = if (base) |base_oid|
        try std.fmt.allocPrint(allocator, "{s}..{s}", .{ base_oid, ref })
    else if (genesis_oid) |anchor|
        try std.fmt.allocPrint(allocator, "{s}..{s}", .{ anchor, ref })
    else
        try allocator.dupe(u8, ref);
    defer allocator.free(target);

    const log = try gitChecked(allocator, &.{
        "log",
        "--first-parent",
        "--reverse",
        inbox_commit.log_format,
        target,
    });
    defer allocator.free(log);

    const ref_identity = inbox_commit.parseRefIdentity(ref) orelse return 0;

    var count: usize = 0;
    var expected_first_parent: ?[]const u8 = if (base) |base_oid| base_oid else genesis_oid;
    var records = std.mem.splitScalar(u8, log, 0x1e);
    while (records.next()) |record_raw| {
        const record = inbox_commit.parseRecord(record_raw) orelse continue;

        if (record.commit.len == 0) continue;
        defer expected_first_parent = record.commit;

        const empty_tree_ok = std.mem.eql(u8, record.tree, empty_tree);
        if (!empty_tree_ok) continue;
        if (record.subject.len > git.max_event_subject_bytes) continue;
        if (record.body.len > git.max_event_body_bytes) continue;
        if (!firstParentMatches(record.parents, expected_first_parent)) continue;
        if (!(try eventParentHashesMatch(allocator, record.parents, record.body))) continue;
        if (!(try verifyCommitSignatureQuiet(allocator, record.commit))) continue;

        var envelope = parseValidatedEnvelope(allocator, record.body) catch continue;
        defer envelope.deinit();
        if (!inbox_commit.actorMatchesRefIdentity(ref_identity, envelope.actor_principal, envelope.actor_device)) continue;
        if (!(try admission.accept(envelope))) continue;

        try insertValidatedIndexedEvent(event_stmt, ref, record.commit, record.tree, record.subject, record.body, envelope);
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

fn eventParentHashesMatch(allocator: Allocator, parents: []const u8, body: []const u8) !bool {
    return (try event_mod.validateParentHashes(allocator, parents, body)) == null;
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

const projectIndexedEvents = index_projection.projectIndexedEvents;
const rebuildDerivedCommitReferences = index_projection.rebuildDerivedCommitReferences;
pub const projectStoredEvent = index_projection.projectStoredEvent;
pub const signingKeyBindingRejection = index_projection.signingKeyBindingRejection;
pub const insertIndexedEvent = index_projection.insertIndexedEvent;

pub const countIndexedEvents = index_query.countIndexedEvents;
pub const countIssueOpenedEvents = index_query.countIssueOpenedEvents;
pub const countOpenIssues = index_query.countOpenIssues;
pub const countPulls = index_query.countPulls;
pub const countOpenPulls = index_query.countOpenPulls;
pub const countIndexedEventsInDb = index_query.countIndexedEventsInDb;
pub const listAclFromIndex = index_query.listAclFromIndex;
pub const listIdentityFromIndex = index_query.listIdentityFromIndex;
pub const listIssuesFromIndex = index_query.listIssuesFromIndex;
pub const showIssueFromIndex = index_query.showIssueFromIndex;
pub const listProjectsFromIndex = index_query.listProjectsFromIndex;
pub const listMilestonesFromIndex = index_query.listMilestonesFromIndex;
pub const listPullsFromIndex = index_query.listPullsFromIndex;
pub const showPullFromIndex = index_query.showPullFromIndex;
pub const listCommentsFromIndex = index_query.listCommentsFromIndex;
pub const listEventsFromIndex = index_query.listEventsFromIndex;
pub const CommentParentInfo = index_query.CommentParentInfo;
pub const resolveProjectId = index_query.resolveProjectId;
pub const ProjectColumnRef = index_query.ProjectColumnRef;
pub const resolveProjectColumnRef = index_query.resolveProjectColumnRef;
pub const resolveProjectFieldId = index_query.resolveProjectFieldId;
pub const resolveProjectFieldOptionId = index_query.resolveProjectFieldOptionId;
pub const resolveProjectViewId = index_query.resolveProjectViewId;
pub const projectNameForId = index_query.projectNameForId;
pub const resolveMilestoneId = index_query.resolveMilestoneId;
pub const sqliteLimitValue = index_query.sqliteLimitValue;

pub fn requireAuthorizedWrite(allocator: Allocator, repo: Repo, event_body: []const u8) !void {
    try ensureIndex(allocator, repo);
    try index_query.requireAuthorizedWrite(allocator, repo, event_body);
}

pub fn roleForPrincipal(allocator: Allocator, repo: Repo, principal: []const u8) !?[]u8 {
    try ensureIndex(allocator, repo);
    return try index_query.roleForPrincipal(allocator, repo, principal);
}

pub fn countOwners(allocator: Allocator, repo: Repo) !usize {
    try ensureIndex(allocator, repo);
    return try index_query.countOwners(allocator, repo);
}

pub fn effectiveWriteRoleForPrincipal(allocator: Allocator, repo: Repo, principal: []const u8) !?[]u8 {
    try ensureIndex(allocator, repo);
    return try index_query.effectiveWriteRoleForPrincipal(allocator, repo, principal);
}

pub fn actorDeviceAuthorizedForWrite(allocator: Allocator, repo: Repo, principal: []const u8, device: []const u8) !bool {
    try ensureIndex(allocator, repo);
    return try index_query.actorDeviceAuthorizedForWrite(allocator, repo, principal, device);
}

pub fn isIdentityDeviceActive(allocator: Allocator, repo: Repo, principal: []const u8, device: []const u8) !bool {
    try ensureIndex(allocator, repo);
    return try index_query.isIdentityDeviceActive(allocator, repo, principal, device);
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
    try ensureIndex(allocator, repo);
    return try index_query.hasActiveDelegation(allocator, repo, principal, device, capability, scope, fingerprint);
}

pub fn authRelatedEventHashes(allocator: Allocator, repo: Repo, principal: []const u8, device: []const u8) ![][]u8 {
    try ensureIndex(allocator, repo);
    return try index_query.authRelatedEventHashes(allocator, repo, principal, device);
}

pub fn resolveIssueId(allocator: Allocator, repo: Repo, raw_ref: []const u8) ![]u8 {
    try ensureIndex(allocator, repo);
    return try index_query.resolveIssueId(allocator, repo, raw_ref);
}

pub fn resolvePullId(allocator: Allocator, repo: Repo, raw_ref: []const u8) ![]u8 {
    try ensureIndex(allocator, repo);
    return try index_query.resolvePullId(allocator, repo, raw_ref);
}

pub fn lookupLegacyGithubObjectId(allocator: Allocator, repo: Repo, object_kind: []const u8, number: i64) !?[]u8 {
    try ensureIndex(allocator, repo);
    return try index_query.lookupLegacyGithubObjectId(allocator, repo, object_kind, number);
}

pub fn lookupLegacyGitlabObjectId(allocator: Allocator, repo: Repo, object_kind: []const u8, number: i64) !?[]u8 {
    try ensureIndex(allocator, repo);
    return try index_query.lookupLegacyGitlabObjectId(allocator, repo, object_kind, number);
}

pub fn legacyGithubNumberForObject(allocator: Allocator, repo: Repo, object_kind: []const u8, object_id: []const u8) !?i64 {
    try ensureIndex(allocator, repo);
    return try index_query.legacyGithubNumberForObject(allocator, repo, object_kind, object_id);
}

pub fn legacyGitlabNumberForObject(allocator: Allocator, repo: Repo, object_kind: []const u8, object_id: []const u8) !?i64 {
    try ensureIndex(allocator, repo);
    return try index_query.legacyGitlabNumberForObject(allocator, repo, object_kind, object_id);
}

pub fn resolveCommentId(allocator: Allocator, repo: Repo, raw_ref: []const u8) ![]u8 {
    try ensureIndex(allocator, repo);
    return try index_query.resolveCommentId(allocator, repo, raw_ref);
}

pub fn commentParentInfo(allocator: Allocator, repo: Repo, comment_id: []const u8) !index_query.CommentParentInfo {
    try ensureIndex(allocator, repo);
    return try index_query.commentParentInfo(allocator, repo, comment_id);
}
