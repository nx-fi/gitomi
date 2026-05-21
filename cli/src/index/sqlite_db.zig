const std = @import("std");

pub const sqlite = @cImport({
    @cInclude("sqlite3.h");
});

extern fn sqlite_bind_text_transient(stmt: ?*sqlite.sqlite3_stmt, index: c_int, value: [*c]const u8, len: c_int) c_int;

const errors = @import("../errors.zig");
const io = @import("../io.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const eprint = io.eprint;

const busy_timeout_ms = 30_000;
const backup_pages_per_step = 256;
const backup_retry_sleep_ms = 50;

pub const OpenOptions = struct {
    enable_wal: bool = true,
};

pub const SqliteDb = struct {
    allocator: Allocator,
    db: *sqlite.sqlite3,
    quiet: bool,

    pub fn open(allocator: Allocator, path: []const u8, flags: c_int, quiet: bool) !SqliteDb {
        return openWithOptions(allocator, path, flags, quiet, .{});
    }

    pub fn openWithOptions(allocator: Allocator, path: []const u8, flags: c_int, quiet: bool, options: OpenOptions) !SqliteDb {
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

        const busy_rc = sqlite.sqlite3_busy_timeout(db_opt.?, busy_timeout_ms);
        if (busy_rc != sqlite.SQLITE_OK) {
            if (!quiet) {
                try eprint("gt index: sqlite open {s}: failed to set busy timeout: {s}\n", .{ path, std.mem.span(sqlite.sqlite3_errmsg(db_opt.?)) });
            }
            _ = sqlite.sqlite3_close(db_opt.?);
            return CliError.SqliteFailed;
        }

        var db = SqliteDb{
            .allocator = allocator,
            .db = db_opt.?,
            .quiet = quiet,
        };
        errdefer db.deinit();

        if (shouldEnableWal(flags, options)) {
            try db.exec("PRAGMA journal_mode=WAL");
            try db.exec("PRAGMA synchronous=NORMAL");
        }

        return db;
    }

    pub fn deinit(self: *SqliteDb) void {
        _ = sqlite.sqlite3_close(self.db);
    }

    pub fn checkpointWal(self: *SqliteDb) !void {
        var log_frames: c_int = 0;
        var checkpointed_frames: c_int = 0;
        const rc = sqlite.sqlite3_wal_checkpoint_v2(
            self.db,
            null,
            sqlite.SQLITE_CHECKPOINT_TRUNCATE,
            &log_frames,
            &checkpointed_frames,
        );
        if (rc != sqlite.SQLITE_OK) return sqliteFail(self.db, self.quiet, "checkpoint WAL");
    }

    pub fn backupToFile(self: *SqliteDb, dest_path: []const u8) !void {
        deleteSidecarFiles(self.allocator, dest_path);

        const dest_path_z = try self.allocator.dupeZ(u8, dest_path);
        defer self.allocator.free(dest_path_z);

        var dest_opt: ?*sqlite.sqlite3 = null;
        const open_rc = sqlite.sqlite3_open_v2(
            dest_path_z.ptr,
            &dest_opt,
            sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_CREATE,
            null,
        );
        if (open_rc != sqlite.SQLITE_OK) {
            const dest = dest_opt;
            if (!self.quiet) {
                if (dest) |handle| {
                    try eprint("gt index: sqlite backup open {s}: {s}\n", .{ dest_path, std.mem.span(sqlite.sqlite3_errmsg(handle)) });
                } else {
                    try eprint("gt index: sqlite backup open {s}: failed to allocate handle\n", .{dest_path});
                }
            }
            if (dest) |handle| _ = sqlite.sqlite3_close(handle);
            return CliError.SqliteFailed;
        }

        const dest = dest_opt.?;
        defer _ = sqlite.sqlite3_close(dest);

        const busy_rc = sqlite.sqlite3_busy_timeout(dest, busy_timeout_ms);
        if (busy_rc != sqlite.SQLITE_OK) return sqliteFail(dest, self.quiet, "backup busy timeout");

        const backup = sqlite.sqlite3_backup_init(dest, "main", self.db, "main") orelse {
            return sqliteFail(dest, self.quiet, "backup init");
        };
        var backup_finished = false;
        defer {
            if (!backup_finished) _ = sqlite.sqlite3_backup_finish(backup);
        }

        var waited_ms: usize = 0;
        while (true) {
            const step_rc = sqlite.sqlite3_backup_step(backup, backup_pages_per_step);
            switch (step_rc) {
                sqlite.SQLITE_OK => {},
                sqlite.SQLITE_DONE => break,
                sqlite.SQLITE_BUSY, sqlite.SQLITE_LOCKED => {
                    if (waited_ms >= busy_timeout_ms) return sqliteFail(dest, self.quiet, "backup step");
                    @import("compat").sleep(backup_retry_sleep_ms * std.time.ns_per_ms);
                    waited_ms += backup_retry_sleep_ms;
                },
                else => return sqliteFail(dest, self.quiet, "backup step"),
            }
        }

        const finish_rc = sqlite.sqlite3_backup_finish(backup);
        backup_finished = true;
        if (finish_rc != sqlite.SQLITE_OK) return sqliteFail(dest, self.quiet, "backup finish");

        try execRaw(self.allocator, dest, self.quiet, "PRAGMA journal_mode=DELETE", "backup journal mode");
        deleteSidecarFiles(self.allocator, dest_path);
    }

    pub fn exec(self: *SqliteDb, sql_text: []const u8) !void {
        try execRaw(self.allocator, self.db, self.quiet, sql_text, "exec");
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

fn shouldEnableWal(flags: c_int, options: OpenOptions) bool {
    return options.enable_wal and (flags & sqlite.SQLITE_OPEN_READWRITE) != 0;
}

fn execRaw(allocator: Allocator, db: *sqlite.sqlite3, quiet: bool, sql_text: []const u8, context: []const u8) !void {
    const sql_z = try allocator.dupeZ(u8, sql_text);
    defer allocator.free(sql_z);
    const rc = sqlite.sqlite3_exec(db, sql_z.ptr, null, null, null);
    if (rc != sqlite.SQLITE_OK) return sqliteFail(db, quiet, context);
}

pub fn deleteSidecarFiles(allocator: Allocator, path: []const u8) void {
    deletePath(allocator, path, "-wal");
    deletePath(allocator, path, "-shm");
}

fn deletePath(allocator: Allocator, path: []const u8, suffix: []const u8) void {
    const sidecar = std.fmt.allocPrint(allocator, "{s}{s}", .{ path, suffix }) catch return;
    defer allocator.free(sidecar);
    if (std.fs.path.isAbsolute(sidecar)) {
        std.Io.Dir.deleteFileAbsolute(@import("compat").io(), sidecar) catch {};
    } else {
        std.Io.Dir.cwd().deleteFile(@import("compat").io(), sidecar) catch {};
    }
}

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
        const rc = sqlite_bind_text_transient(self.stmt, index, value.ptr, len);
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
