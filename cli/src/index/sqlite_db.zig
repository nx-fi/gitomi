const std = @import("std");

pub const sqlite = @cImport({
    @cInclude("sqlite3.h");
});

const errors = @import("../errors.zig");
const io = @import("../io.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const eprint = io.eprint;

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
