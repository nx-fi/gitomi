const std = @import("std");

const event_mod = @import("event.zig");
const index = @import("index.zig");
const repo_mod = @import("repo.zig");
const util = @import("util.zig");

const Allocator = std.mem.Allocator;
const ValidatedEnvelope = event_mod.ValidatedEnvelope;

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
        errdefer std.fs.cwd().deleteFile(temp_path) catch {};

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
        std.fs.cwd().deleteFile(self.temp_path) catch {};
        self.allocator.free(self.temp_path);
        self.repo.deinit();
    }

    pub fn checkExisting(self: *Verifier, commit: []const u8, envelope: ValidatedEnvelope) !?[]const u8 {
        return try index.signingKeyBindingRejection(self.allocator, &self.db, commit, envelope);
    }

    pub fn checkAndRemember(self: *Verifier, record: CommitRecord, envelope: ValidatedEnvelope) !?[]const u8 {
        if (try self.checkExisting(record.commit, envelope)) |reason| return reason;

        if (isAuthorizationEvent(envelope.event_type)) {
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
