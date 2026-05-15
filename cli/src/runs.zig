const std = @import("std");
const errors = @import("errors.zig");
const git = @import("git.zig");
const io = @import("io.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;

const runs_prefix = "refs/gitomi/runs";
pub const default_max_age_days: u64 = 30;
pub const default_max_count: usize = 100;
pub const default_max_bytes: u64 = 256 * 1024 * 1024;

pub const PruneOptions = struct {
    dry_run: bool = false,
    max_age_days: u64 = default_max_age_days,
    max_count: usize = default_max_count,
    max_bytes: u64 = default_max_bytes,
};

const RunRef = struct {
    allocator: Allocator,
    ref: []u8,
    oid: []u8,
    timestamp: i64,
    bytes: u64 = 0,
    prune: bool = false,

    fn deinit(self: *RunRef) void {
        self.allocator.free(self.ref);
        self.allocator.free(self.oid);
    }
};

pub fn prune(allocator: Allocator, options: PruneOptions) !void {
    var refs = try loadRunRefs(allocator);
    defer {
        for (refs.items) |*ref| ref.deinit();
        refs.deinit(allocator);
    }

    if (refs.items.len == 0) {
        try io.out("no Gitomi run refs\n", .{});
        return;
    }

    const now = std.time.timestamp();
    const max_age_seconds = options.max_age_days * 24 * 60 * 60;
    var retained_bytes: u64 = 0;

    for (refs.items, 0..) |*ref, idx| {
        ref.bytes = objectGraphBytes(allocator, ref.oid) catch 0;
        const age_seconds: u64 = if (now > ref.timestamp) @intCast(now - ref.timestamp) else 0;
        if (options.max_age_days != 0 and age_seconds > max_age_seconds) {
            ref.prune = true;
        }
        if (options.max_count != 0 and idx >= options.max_count) {
            ref.prune = true;
        }
        if (!ref.prune) {
            if (options.max_bytes != 0 and retained_bytes + ref.bytes > options.max_bytes) {
                ref.prune = true;
            } else {
                retained_bytes += ref.bytes;
            }
        }
    }

    var pruned: usize = 0;
    for (refs.items) |*ref| {
        if (!ref.prune) continue;
        pruned += 1;
        if (options.dry_run) {
            try io.out("would prune {s} ({d} bytes)\n", .{ ref.ref, ref.bytes });
        } else {
            const deleted = try git.gitChecked(allocator, &.{ "update-ref", "-d", ref.ref });
            defer allocator.free(deleted);
            try io.out("pruned {s} ({d} bytes)\n", .{ ref.ref, ref.bytes });
        }
    }

    try io.out("{s}: {d} pruned, {d} retained\n", .{
        if (options.dry_run) "runs prune dry-run" else "runs prune",
        pruned,
        refs.items.len - pruned,
    });
}

fn loadRunRefs(allocator: Allocator) !std.ArrayList(RunRef) {
    const raw = try git.gitChecked(allocator, &.{
        "for-each-ref",
        "--sort=-committerdate",
        "--format=%(refname) %(objectname) %(committerdate:unix)",
        runs_prefix,
    });
    defer allocator.free(raw);

    var refs: std.ArrayList(RunRef) = .empty;
    errdefer {
        for (refs.items) |*ref| ref.deinit();
        refs.deinit(allocator);
    }

    var lines = std.mem.tokenizeScalar(u8, raw, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
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

    return refs;
}

fn objectGraphBytes(allocator: Allocator, oid: []const u8) !u64 {
    const objects = try git.gitChecked(allocator, &.{ "rev-list", "--objects", oid });
    defer allocator.free(objects);

    var total: u64 = 0;
    var lines = std.mem.tokenizeScalar(u8, objects, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const object_oid = fields.next() orelse continue;
        {
            const size_raw = try git.gitChecked(allocator, &.{ "cat-file", "-s", object_oid });
            defer allocator.free(size_raw);
            const size_text = std.mem.trim(u8, size_raw, " \t\r\n");
            total += std.fmt.parseUnsigned(u64, size_text, 10) catch 0;
        }
    }
    return total;
}

pub fn parsePruneNumber(raw: []const u8, label: []const u8) !u64 {
    return std.fmt.parseUnsigned(u64, raw, 10) catch {
        try io.eprint("gt runs prune: {s} must be a non-negative integer\n", .{label});
        return CliError.UserError;
    };
}

test "run retention defaults cap diagnostics at 256 MiB" {
    const options = PruneOptions{};
    try std.testing.expectEqual(@as(u64, 256 * 1024 * 1024), default_max_bytes);
    try std.testing.expectEqual(default_max_bytes, options.max_bytes);
}
