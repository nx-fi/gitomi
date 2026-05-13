const std = @import("std");
const errors = @import("errors.zig");
const io = @import("io.zig");
const util = @import("util.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const out = io.out;
const eprint = io.eprint;
const countNonEmptyLines = util.countNonEmptyLines;
const trimOwned = util.trimOwned;
const trimDup = util.trimDup;

pub const max_git_output = 16 * 1024 * 1024;
pub const max_causal_parents = 32;
pub const max_event_body_bytes = 1024 * 1024;
pub const max_event_subject_bytes = 512;
pub const max_related_parents = 256;
pub const max_default_inbox_refs = 10_000;
pub const max_default_admit_commits = 100_000;
pub const max_payload_title_bytes = 512;
pub const max_payload_text_bytes = 64 * 1024;
pub const max_payload_key_bytes = 16 * 1024;
pub const max_payload_atom_bytes = 256;
pub const max_payload_ref_bytes = 512;
pub const max_payload_collection_items = 128;

pub fn currentBranch(allocator: Allocator) ![]u8 {
    var branch_argv = [_][]const u8{ "git", "branch", "--show-current" };
    var branch_result = try runCommand(allocator, &branch_argv, null, 512 * 1024);
    defer branch_result.deinit();
    if (branch_result.exitCode() == 0) {
        const trimmed = std.mem.trim(u8, branch_result.stdout, " \t\r\n");
        if (trimmed.len != 0) return allocator.dupe(u8, trimmed);
    }

    var head_argv = [_][]const u8{ "git", "rev-parse", "--short", "HEAD" };
    var head_result = try runCommand(allocator, &head_argv, null, 512 * 1024);
    defer head_result.deinit();
    if (head_result.exitCode() == 0) {
        const trimmed = std.mem.trim(u8, head_result.stdout, " \t\r\n");
        if (trimmed.len != 0) return std.fmt.allocPrint(allocator, "detached at {s}", .{trimmed});
    }

    return allocator.dupe(u8, "unborn");
}

pub fn workingTreeChangeCount(allocator: Allocator) !usize {
    var argv = [_][]const u8{ "git", "status", "--short" };
    var result = try runCommand(allocator, &argv, null, max_git_output);
    defer result.deinit();
    if (result.exitCode() != 0) return 0;
    return countNonEmptyLines(result.stdout);
}

pub const RunOutput = struct {
    allocator: Allocator,
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,

    pub fn deinit(self: *RunOutput) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }

    pub fn exitCode(self: RunOutput) ?u8 {
        return switch (self.term) {
            .Exited => |code| code,
            else => null,
        };
    }
};

pub fn revListRange(allocator: Allocator, base: []const u8, ref: []const u8) ![]u8 {
    const range = try std.fmt.allocPrint(allocator, "{s}..{s}", .{ base, ref });
    defer allocator.free(range);
    return gitChecked(allocator, &.{ "rev-list", "--first-parent", "--reverse", range });
}

pub fn isAncestor(allocator: Allocator, ancestor: []const u8, descendant: []const u8) !bool {
    var argv = [_][]const u8{ "git", "merge-base", "--is-ancestor", ancestor, descendant };
    var result = try runCommand(allocator, &argv, null, max_git_output);
    defer result.deinit();
    if (result.exitCode()) |code| {
        if (code == 0) return true;
        if (code == 1) return false;
    }

    const stderr = std.mem.trim(u8, result.stderr, " \t\r\n");
    if (stderr.len != 0) {
        try eprint("git merge-base failed: {s}\n", .{stderr});
    } else {
        try eprint("git merge-base failed\n", .{});
    }
    return CliError.GitFailed;
}

pub fn listRefs(allocator: Allocator, prefix: []const u8) ![][]u8 {
    const raw = try gitChecked(allocator, &.{
        "for-each-ref",
        "--sort=refname",
        "--format=%(refname)",
        prefix,
    });
    defer allocator.free(raw);

    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |value| allocator.free(value);
        list.deinit(allocator);
    }

    var it = std.mem.tokenizeScalar(u8, raw, '\n');
    while (it.next()) |line| {
        try list.append(allocator, try allocator.dupe(u8, std.mem.trim(u8, line, " \t\r\n")));
    }
    return try list.toOwnedSlice(allocator);
}

pub fn resolveOptionalRef(allocator: Allocator, ref: []const u8) !?[]u8 {
    var argv = [_][]const u8{ "git", "rev-parse", "--verify", ref };
    var result = try runCommand(allocator, &argv, null, max_git_output);
    defer result.deinit();
    if (result.exitCode() == 0) {
        return try trimDup(allocator, result.stdout);
    }
    return null;
}

pub fn inboxHeads(allocator: Allocator) ![][]u8 {
    const raw = try gitChecked(allocator, &.{
        "for-each-ref",
        "--sort=refname",
        "--format=%(objectname)",
        "refs/gitomi/inbox",
    });
    defer allocator.free(raw);

    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |value| allocator.free(value);
        list.deinit(allocator);
    }

    var it = std.mem.tokenizeScalar(u8, raw, '\n');
    while (it.next()) |line| {
        try list.append(allocator, try allocator.dupe(u8, std.mem.trim(u8, line, " \t\r\n")));
    }
    return try list.toOwnedSlice(allocator);
}

pub const PreparedEventParents = struct {
    allocator: Allocator,
    old_head: ?[]u8,
    all_heads: [][]u8,
    causal_heads: [][]const u8,

    pub fn deinit(self: *PreparedEventParents) void {
        if (self.old_head) |head| self.allocator.free(head);
        freeStringList(self.allocator, self.all_heads);
        self.allocator.free(self.causal_heads);
    }
};

pub fn prepareEventParents(allocator: Allocator, inbox_ref: []const u8) !PreparedEventParents {
    const old_head = try resolveOptionalRef(allocator, inbox_ref);
    errdefer if (old_head) |head| allocator.free(head);

    const all_heads = try inboxHeads(allocator);
    errdefer freeStringList(allocator, all_heads);

    var causal: std.ArrayList([]const u8) = .empty;
    errdefer causal.deinit(allocator);

    if (old_head) |head| {
        for (all_heads) |known_head| {
            if (std.mem.eql(u8, known_head, head)) continue;
            if (try isAncestor(allocator, known_head, head)) continue;
            if (containsString(causal.items, known_head)) continue;
            if (causal.items.len >= max_causal_parents) break;
            try causal.append(allocator, known_head);
        }
    }

    return .{
        .allocator = allocator,
        .old_head = old_head,
        .all_heads = all_heads,
        .causal_heads = try causal.toOwnedSlice(allocator),
    };
}

fn containsString(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

pub fn freeStringList(allocator: Allocator, values: [][]u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

pub fn emptyTreeOid(allocator: Allocator) ![]u8 {
    const raw = try gitCheckedInput(allocator, &.{
        "hash-object",
        "-w",
        "-t",
        "tree",
        "--stdin",
    }, "");
    return trimOwned(allocator, raw);
}

pub fn countInboxEvents(allocator: Allocator) !usize {
    const refs = try gitChecked(allocator, &.{
        "for-each-ref",
        "--format=%(refname)",
        "refs/gitomi/inbox",
    });
    defer allocator.free(refs);

    var count: usize = 0;
    var it = std.mem.tokenizeScalar(u8, refs, '\n');
    while (it.next()) |ref| {
        const raw = try gitChecked(allocator, &.{ "rev-list", "--first-parent", "--count", ref });
        defer allocator.free(raw);
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        count += std.fmt.parseUnsigned(usize, trimmed, 10) catch 0;
    }
    return count;
}

pub fn printGitConfigValue(allocator: Allocator, key: []const u8, label: []const u8) !void {
    var argv = [_][]const u8{ "git", "config", "--get", key };
    var result = try runCommand(allocator, &argv, null, 512 * 1024);
    defer result.deinit();
    if (result.exitCode() == 0) {
        try out("{s}: {s}\n", .{ label, std.mem.trim(u8, result.stdout, " \t\r\n") });
    } else {
        try out("{s}: unset\n", .{label});
    }
}

pub fn gitChecked(allocator: Allocator, git_args: []const []const u8) ![]u8 {
    return gitCheckedInput(allocator, git_args, null);
}

pub fn gitCheckedInput(allocator: Allocator, git_args: []const []const u8, input: ?[]const u8) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    for (git_args) |arg| try argv.append(allocator, arg);

    var result = try runCommand(allocator, argv.items, input, max_git_output);
    if (result.exitCode() == 0) {
        const stdout = result.stdout;
        allocator.free(result.stderr);
        return stdout;
    }

    defer result.deinit();
    const stderr = std.mem.trim(u8, result.stderr, " \t\r\n");
    if (stderr.len != 0) {
        try eprint("git {s} failed: {s}\n", .{ git_args[0], stderr });
    } else {
        try eprint("git {s} failed\n", .{git_args[0]});
    }
    return CliError.GitFailed;
}

pub fn runCommand(
    allocator: Allocator,
    argv: []const []const u8,
    input: ?[]const u8,
    max_output_bytes: usize,
) !RunOutput {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = if (input == null) .Ignore else .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    var stdout: std.ArrayList(u8) = .empty;
    errdefer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    errdefer stderr.deinit(allocator);

    try child.spawn();
    errdefer _ = child.kill() catch {};

    if (input) |bytes| {
        try child.stdin.?.writeAll(bytes);
        child.stdin.?.close();
        child.stdin = null;
    }

    try child.collectOutput(allocator, &stdout, &stderr, max_output_bytes);
    const term = try child.wait();

    return .{
        .allocator = allocator,
        .stdout = try stdout.toOwnedSlice(allocator),
        .stderr = try stderr.toOwnedSlice(allocator),
        .term = term,
    };
}

pub fn gitConfigValue(allocator: Allocator, key: []const u8) ![]u8 {
    var argv = [_][]const u8{ "git", "config", "--get", key };
    var result = try runCommand(allocator, &argv, null, 512 * 1024);
    defer result.deinit();
    if (result.exitCode() != 0) return CliError.GitFailed;
    return trimDup(allocator, result.stdout);
}
