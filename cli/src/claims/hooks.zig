const std = @import("std");
const compat = @import("compat");
const git = @import("../git.zig");
const io = @import("../io.zig");
const m = @import("model.zig");
const A = std.mem.Allocator;

pub const script =
    "#!/bin/sh\n" ++
    "# Gitomi claim conflict check, v1. Explicit bypass: git commit --no-verify\n" ++
    "if ! command -v gt >/dev/null 2>&1; then\n" ++
    "  printf '%s\\n' 'gt claim: pre-commit could not find gt on PATH; install gt or restore PATH, then retry git commit.' 'To intentionally bypass this advisory hook, use git commit --no-verify.' >&2\n" ++
    "  exit 1\n" ++
    "fi\n" ++
    "exec gt claim check --staged </dev/null\n";

pub fn install(a: A) !void {
    const raw = try git.gitChecked(a, &.{ "rev-parse", "--path-format=absolute", "--git-path", "hooks/pre-commit" });
    defer a.free(raw);
    const path = if (std.mem.endsWith(u8, raw, "\n")) raw[0 .. raw.len - 1] else raw;
    const parent = std.fs.path.dirname(path) orelse return error.InvalidHookPath;
    const name = std.fs.path.basename(path);
    const current_io = compat.io();
    try std.Io.Dir.cwd().createDirPath(current_io, parent);
    var dir = try std.Io.Dir.openDirAbsolute(current_io, parent, .{});
    defer dir.close(current_io);
    var atomic = try dir.createFileAtomic(current_io, name, .{});
    defer atomic.deinit(current_io);
    try atomic.file.writeStreamingAll(current_io, script);
    try atomic.file.setPermissions(current_io, @enumFromInt(0o755));
    // Publish the complete executable script atomically, and never replace an
    // existing hook (including one installed concurrently or a dangling link).
    atomic.link(current_io) catch |err| switch (err) {
        error.PathAlreadyExists => {
            try io.eprint("gt claim: a pre-commit hook already exists at {s}; it was preserved.\n  Run `gt claim hook print` and integrate its check into your existing hook, preserving both exit statuses.\n  Use `gt claim check --staged` to run the check now.\n", .{try m.quoted(a, path)});
            return error.UserError;
        },
        else => return err,
    };
    try io.out("Installed claim conflict hook at {s}.\n  It checks staged paths before commits; ensure gt is on PATH.\n  To intentionally bypass: git commit --no-verify\n", .{try m.quoted(a, path)});
}

/// Query the index Git supplies, including the temporary GIT_INDEX_FILE used
/// for partial commits. No shell parsing, no worktree diff, no path argv limit.
pub fn stagedPaths(a: A, root: []const u8) ![]const []const u8 {
    const raw = try git.gitChecked(a, &.{ "-C", root, "diff", "--cached", "--name-only", "--no-relative", "--no-renames", "--no-ext-diff", "--no-textconv", "-z", "--" });
    defer a.free(raw);
    var paths: std.ArrayList([]const u8) = .empty;
    errdefer paths.deinit(a);
    var it = std.mem.splitScalar(u8, raw, 0);
    while (it.next()) |path| {
        if (path.len == 0) continue;
        // Rename detection is disabled so both old and new paths are checked.
        // Wildcards in a literal filename may over-conflict, never under-conflict.
        try paths.append(a, try m.normalize(a, path));
    }
    return paths.toOwnedSlice(a);
}
