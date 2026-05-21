const std = @import("std");

const event_model = @import("event/model.zig");
const index = @import("index.zig");
const repo_mod = @import("repo.zig");
const util = @import("util.zig");

const Allocator = std.mem.Allocator;
const ValidatedEnvelope = event_model.ValidatedEnvelope;

pub const CommitRecord = struct {
    ref: []const u8,
    commit: []const u8,
    tree: []const u8,
    subject: []const u8,
    body: []const u8,
};

pub const Verifier = struct {
    allocator: Allocator,
    repo: repo_mod.Repo,
    temp_path: []u8,
    db: index.SqliteDb,
    insert_stmt: index.SqliteStmt,

    pub fn init(allocator: Allocator) !Verifier {
        var repo = try repo_mod.discoverRepo(allocator);
        errdefer repo.deinit();

        try index.ensureIndex(allocator, repo);

        const temp_id = try util.newUuidV7(allocator);
        defer allocator.free(temp_id);

        const temp_path = try std.fmt.allocPrint(allocator, "{s}/auth-binding-{s}.sqlite", .{ repo.gitomi_dir, temp_id });
        errdefer allocator.free(temp_path);

        var source_db = try index.SqliteDb.open(allocator, repo.index_path, index.sqlite.SQLITE_OPEN_READONLY, false);
        defer source_db.deinit();
        try source_db.backupToFile(temp_path);
        errdefer std.Io.Dir.cwd().deleteFile(@import("compat").io(), temp_path) catch {};

        var db = try index.SqliteDb.openWithOptions(allocator, temp_path, index.sqlite.SQLITE_OPEN_READWRITE, false, .{ .enable_wal = false });
        errdefer db.deinit();

        var insert_stmt = try db.prepare(
            \\INSERT INTO events(
            \\  ref, "commit", event_hash, tree, subject, body, empty_tree, valid_json,
            \\  event_type, object_kind, object_id, actor_principal, actor_device, seq, occurred_at,
            \\  domain_status, rejection_reason
            \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        );
        errdefer insert_stmt.deinit();

        return .{
            .allocator = allocator,
            .repo = repo,
            .temp_path = temp_path,
            .db = db,
            .insert_stmt = insert_stmt,
        };
    }

    pub fn initExcludingRef(allocator: Allocator, excluded_ref: []const u8) !Verifier {
        var repo = try repo_mod.discoverRepo(allocator);
        errdefer repo.deinit();

        const temp_id = try util.newUuidV7(allocator);
        defer allocator.free(temp_id);

        const temp_path = try std.fmt.allocPrint(allocator, "{s}/auth-binding-{s}.sqlite", .{ repo.gitomi_dir, temp_id });
        errdefer allocator.free(temp_path);
        errdefer std.Io.Dir.cwd().deleteFile(@import("compat").io(), temp_path) catch {};

        const refs_raw = try index.currentIndexRefsRaw(allocator);
        defer allocator.free(refs_raw);
        const filtered_refs_raw = try refsRawExcludingRef(allocator, refs_raw, excluded_ref);
        defer allocator.free(filtered_refs_raw);

        _ = try index.rebuildScratchIndexFromRefs(allocator, repo, temp_path, filtered_refs_raw);

        var db = try index.SqliteDb.openWithOptions(allocator, temp_path, index.sqlite.SQLITE_OPEN_READWRITE, false, .{ .enable_wal = false });
        errdefer db.deinit();

        var insert_stmt = try db.prepare(
            \\INSERT INTO events(
            \\  ref, "commit", event_hash, tree, subject, body, empty_tree, valid_json,
            \\  event_type, object_kind, object_id, actor_principal, actor_device, seq, occurred_at,
            \\  domain_status, rejection_reason
            \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        );
        errdefer insert_stmt.deinit();

        return .{
            .allocator = allocator,
            .repo = repo,
            .temp_path = temp_path,
            .db = db,
            .insert_stmt = insert_stmt,
        };
    }

    pub fn deinit(self: *Verifier) void {
        self.insert_stmt.deinit();
        self.db.deinit();
        std.Io.Dir.cwd().deleteFile(@import("compat").io(), self.temp_path) catch {};
        self.allocator.free(self.temp_path);
        self.repo.deinit();
    }

    pub fn checkExisting(self: *Verifier, commit: []const u8, envelope: ValidatedEnvelope, body: []const u8) !?[]const u8 {
        return try index.signingKeyBindingRejection(self.allocator, &self.db, commit, envelope, body);
    }

    pub fn checkAndRemember(self: *Verifier, record: CommitRecord, envelope: ValidatedEnvelope) !?[]const u8 {
        if (try self.checkExisting(record.commit, envelope, record.body)) |reason| return reason;

        if (isAuthorizationEvent(envelope.event_type)) {
            if (try indexedEventExists(&self.db, record.commit)) return "duplicate_event_hash";
            try index.insertIndexedEvent(
                self.allocator,
                &self.insert_stmt,
                record.ref,
                record.commit,
                record.tree,
                record.subject,
                record.body,
                true,
            );
            try index.projectStoredEvent(self.allocator, &self.db, record.commit, record.body, true);
        }

        return null;
    }
};

fn isAuthorizationEvent(event_type: []const u8) bool {
    return std.mem.startsWith(u8, event_type, "acl.") or std.mem.startsWith(u8, event_type, "identity.");
}

fn indexedEventExists(db: *index.SqliteDb, event_hash: []const u8) !bool {
    var stmt = try db.prepare("SELECT 1 FROM events WHERE event_hash = ? LIMIT 1");
    defer stmt.deinit();
    try stmt.bindText(1, event_hash);
    return try stmt.step();
}

fn refsRawExcludingRef(allocator: Allocator, refs_raw: []const u8, excluded_ref: []const u8) ![]u8 {
    var filtered: std.ArrayList(u8) = .empty;
    errdefer filtered.deinit(allocator);

    var it = std.mem.splitScalar(u8, refs_raw, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const ref = line[0..tab];
        if (std.mem.eql(u8, ref, excluded_ref)) continue;
        try filtered.appendSlice(allocator, line);
        try filtered.append(allocator, '\n');
    }

    return try filtered.toOwnedSlice(allocator);
}

test "auth verifier detects duplicate indexed event before insert" {
    const allocator = std.testing.allocator;
    var db = try index.SqliteDb.open(allocator, ":memory:", index.sqlite.SQLITE_OPEN_READWRITE | index.sqlite.SQLITE_OPEN_CREATE, true);
    defer db.deinit();
    try index.createIndexSchema(&db);
    try db.exec(
        \\INSERT INTO events(
        \\  ref, "commit", event_hash, tree, subject, body, empty_tree, valid_json,
        \\  event_type, object_kind, object_id, actor_principal, actor_device, seq, occurred_at,
        \\  domain_status, rejection_reason
        \\) VALUES (
        \\  'refs/gitomi/inbox/alice/laptop', 'commit-1', 'commit-1', '', '', '', 1, 0,
        \\  '', '', '', '', '', NULL, '', 'pending', ''
        \\);
    );

    try std.testing.expect(try indexedEventExists(&db, "commit-1"));
    try std.testing.expect(!(try indexedEventExists(&db, "commit-2")));
}

test "refsRawExcludingRef removes only the selected ref" {
    const refs_raw =
        "refs/gitomi/genesis\t1111111111111111111111111111111111111111\n" ++
        "refs/gitomi/inbox/alice/laptop\t2222222222222222222222222222222222222222\n" ++
        "refs/gitomi/inbox/bob/desktop\t3333333333333333333333333333333333333333\n";

    const filtered = try refsRawExcludingRef(std.testing.allocator, refs_raw, "refs/gitomi/inbox/alice/laptop");
    defer std.testing.allocator.free(filtered);

    try std.testing.expectEqualStrings(
        "refs/gitomi/genesis\t1111111111111111111111111111111111111111\n" ++
            "refs/gitomi/inbox/bob/desktop\t3333333333333333333333333333333333333333\n",
        filtered,
    );
}
