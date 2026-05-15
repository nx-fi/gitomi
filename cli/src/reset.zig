const std = @import("std");
const errors = @import("errors.zig");
const git = @import("git.zig");
const io = @import("io.zig");
const repo_mod = @import("repo.zig");
const util = @import("util.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;

const Scope = enum {
    local,
    remote,
};

const Options = struct {
    scope: Scope,
    remote: []const u8 = "origin",
    yes: bool = false,
};

pub fn cmdClearOrReset(allocator: Allocator, args: []const []const u8, command_name: []const u8) !void {
    const options = try parseOptions(args, command_name);

    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();

    switch (options.scope) {
        .local => if (std.mem.eql(u8, command_name, "gt reset"))
            try resetLocalState(allocator, repo, command_name, options.yes)
        else
            try clearLocalRefs(allocator, command_name, options.yes),
        .remote => try clearRemoteRefs(allocator, command_name, options.remote, options.yes),
    }
}

fn parseOptions(args: []const []const u8, command_name: []const u8) !Options {
    if (args.len == 0) {
        try io.eprint("{s}: expected subcommand 'local' or 'remote'\n", .{command_name});
        return CliError.UserError;
    }

    const scope: Scope = if (std.mem.eql(u8, args[0], "local"))
        .local
    else if (std.mem.eql(u8, args[0], "remote"))
        .remote
    else {
        try io.eprint("{s}: expected subcommand 'local' or 'remote'\n", .{command_name});
        return CliError.UserError;
    };

    var options = Options{ .scope = scope };
    var remote_set = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "-y")) {
            options.yes = true;
        } else if (std.mem.eql(u8, arg, "--remote")) {
            if (scope != .remote) {
                try io.eprint("{s} local: --remote is only valid with the remote subcommand\n", .{command_name});
                return CliError.UserError;
            }
            options.remote = try util.requireValue(args, &i, "--remote");
            remote_set = true;
        } else if (scope == .remote and !std.mem.startsWith(u8, arg, "-") and !remote_set) {
            options.remote = arg;
            remote_set = true;
        } else {
            try io.eprint("{s} {s}: unknown option '{s}'\n", .{ command_name, @tagName(scope), arg });
            return CliError.UserError;
        }
    }

    if (scope == .remote and std.mem.trim(u8, options.remote, " \t\r\n").len == 0) {
        try io.eprint("{s} remote: remote name is empty\n", .{command_name});
        return CliError.UserError;
    }

    return options;
}

fn clearLocalRefs(allocator: Allocator, command_name: []const u8, yes: bool) !void {
    const refs = try git.listRefs(allocator, "refs/gitomi");
    defer git.freeStringList(allocator, refs);

    if (refs.len == 0) {
        try io.out("no local Gitomi refs\n", .{});
        return;
    }

    try io.out("{s}: deleting {d} local Gitomi ref{s} under refs/gitomi\n", .{
        command_name,
        refs.len,
        if (refs.len == 1) "" else "s",
    });
    if (!yes) try requireConfirmation(allocator, command_name, "delete local gitomi refs");

    for (refs) |ref| {
        const deleted = try git.gitChecked(allocator, &.{ "update-ref", "-d", ref });
        allocator.free(deleted);
        try io.out("deleted {s}\n", .{ref});
    }

    try io.out("{s}: deleted {d} local Gitomi ref{s}\n", .{
        command_name,
        refs.len,
        if (refs.len == 1) "" else "s",
    });
}

fn resetLocalState(allocator: Allocator, repo: repo_mod.Repo, command_name: []const u8, yes: bool) !void {
    const refs = try git.listRefs(allocator, "refs/gitomi");
    defer git.freeStringList(allocator, refs);

    const has_state_dir = util.fileExists(repo.gitomi_dir);
    if (refs.len == 0 and !has_state_dir) {
        try io.out("no local Gitomi state\n", .{});
        return;
    }

    try io.out("{s}: deleting local Gitomi state ({d} ref{s} and {s})\n", .{
        command_name,
        refs.len,
        if (refs.len == 1) "" else "s",
        repo.gitomi_dir,
    });
    if (!yes) try requireConfirmation(allocator, command_name, "delete local gitomi state");

    for (refs) |ref| {
        const deleted = try git.gitChecked(allocator, &.{ "update-ref", "-d", ref });
        allocator.free(deleted);
        try io.out("deleted {s}\n", .{ref});
    }

    if (has_state_dir) {
        std.fs.deleteTreeAbsolute(repo.gitomi_dir) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        try io.out("deleted {s}\n", .{repo.gitomi_dir});
    }

    try io.out("{s}: deleted local Gitomi state\n", .{command_name});
}

fn clearRemoteRefs(allocator: Allocator, command_name: []const u8, remote: []const u8, yes: bool) !void {
    const refs = try listRemoteGitomiRefs(allocator, remote);
    defer git.freeStringList(allocator, refs);

    if (refs.len == 0) {
        try io.out("no remote Gitomi refs at {s}\n", .{remote});
        return;
    }

    try io.out("{s}: deleting {d} remote Gitomi ref{s} from {s}\n", .{
        command_name,
        refs.len,
        if (refs.len == 1) "" else "s",
        remote,
    });
    if (!yes) {
        const phrase = try std.fmt.allocPrint(allocator, "delete remote gitomi refs from {s}", .{remote});
        defer allocator.free(phrase);
        try requireConfirmation(allocator, command_name, phrase);
    }

    for (refs) |ref| {
        const refspec = try std.fmt.allocPrint(allocator, ":{s}", .{ref});
        defer allocator.free(refspec);
        const deleted = try git.gitChecked(allocator, &.{ "push", remote, refspec });
        allocator.free(deleted);
        try io.out("deleted {s} from {s}\n", .{ ref, remote });
    }

    try io.out("{s}: deleted {d} remote Gitomi ref{s} from {s}\n", .{
        command_name,
        refs.len,
        if (refs.len == 1) "" else "s",
        remote,
    });
}

fn listRemoteGitomiRefs(allocator: Allocator, remote: []const u8) ![][]u8 {
    var argv = [_][]const u8{ "git", "ls-remote", "--refs", remote };
    var result = try git.runCommand(allocator, &argv, null, git.max_git_output);
    defer result.deinit();

    if (result.exitCode() != 0) {
        const stderr = std.mem.trim(u8, result.stderr, " \t\r\n");
        if (stderr.len != 0) {
            try io.eprint("git ls-remote failed: {s}\n", .{stderr});
        } else {
            try io.eprint("git ls-remote failed\n", .{});
        }
        return CliError.GitFailed;
    }

    var refs: std.ArrayList([]u8) = .empty;
    errdefer {
        for (refs.items) |ref| allocator.free(ref);
        refs.deinit(allocator);
    }

    var lines = std.mem.tokenizeScalar(u8, result.stdout, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;

        var fields = std.mem.tokenizeAny(u8, line, " \t");
        _ = fields.next() orelse continue;
        const ref = fields.next() orelse continue;
        if (!std.mem.startsWith(u8, ref, "refs/gitomi/")) continue;
        try refs.append(allocator, try allocator.dupe(u8, ref));
    }

    std.mem.sort([]u8, refs.items, {}, stringLessThan);
    return try refs.toOwnedSlice(allocator);
}

fn requireConfirmation(allocator: Allocator, command_name: []const u8, phrase: []const u8) !void {
    try io.out("Type '{s}' to continue: ", .{phrase});
    const answer = try readStdinLine(allocator, 1024);
    defer allocator.free(answer);

    if (!std.mem.eql(u8, std.mem.trim(u8, answer, " \t\r\n"), phrase)) {
        try io.eprint("{s}: aborted\n", .{command_name});
        return CliError.UserError;
    }
}

fn readStdinLine(allocator: Allocator, max_bytes: usize) ![]u8 {
    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(allocator);

    const stdin = std.fs.File.stdin();
    var byte: [1]u8 = undefined;
    while (true) {
        const read_len = try stdin.read(&byte);
        if (read_len == 0 or byte[0] == '\n') break;
        if (line.items.len >= max_bytes) {
            try io.eprint("confirmation input is too long\n", .{});
            return CliError.UserError;
        }
        if (byte[0] != '\r') try line.append(allocator, byte[0]);
    }

    return try line.toOwnedSlice(allocator);
}

fn stringLessThan(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}
