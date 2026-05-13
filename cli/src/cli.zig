const std = @import("std");
const errors = @import("errors.zig");
const fsck = @import("fsck.zig");
const git = @import("git.zig");
const index = @import("index.zig");
const io = @import("io.zig");
const issue = @import("issue.zig");
const repo_mod = @import("repo.zig");
const sync = @import("sync.zig");
const util = @import("util.zig");
const web = @import("web.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;

pub fn main() void {
    realMain() catch |err| {
        if (err != CliError.UserError and err != CliError.GitFailed and err != CliError.SqliteFailed) {
            io.eprint("gt: {s}\n", .{@errorName(err)}) catch {};
        }
        std.process.exit(1);
    };
}

fn realMain() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len <= 1) {
        try printUsage();
        return;
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "help")) {
        try printUsage();
    } else if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "version")) {
        try io.out("gt 0.1.0\n", .{});
    } else if (std.mem.eql(u8, cmd, "init")) {
        try cmdInit(allocator, args[2..]);
    } else if (std.mem.eql(u8, cmd, "status") or std.mem.eql(u8, cmd, "doctor")) {
        try cmdStatus(allocator);
    } else if (std.mem.eql(u8, cmd, "fsck")) {
        try cmdFsck(allocator, args[2..]);
    } else if (std.mem.eql(u8, cmd, "index")) {
        try cmdIndex(allocator, args[2..]);
    } else if (std.mem.eql(u8, cmd, "refs")) {
        try cmdRefs(allocator);
    } else if (std.mem.eql(u8, cmd, "events")) {
        try cmdEvents(allocator, args[2..]);
    } else if (std.mem.eql(u8, cmd, "issue")) {
        try cmdIssue(allocator, args[2..]);
    } else if (std.mem.eql(u8, cmd, "sync")) {
        try cmdSync(allocator, args[2..]);
    } else if (std.mem.eql(u8, cmd, "web")) {
        try cmdWeb(allocator, args[2..]);
    } else {
        try io.eprint("gt: unknown command '{s}'\n\n", .{cmd});
        try printUsage();
        return CliError.UserError;
    }
}

fn printUsage() !void {
    try io.out(
        \\Usage:
        \\  gt init [--principal ID] [--device ID] [--repo-id UUID] [--force]
        \\  gt status
        \\  gt fsck
        \\  gt index rebuild|status
        \\  gt refs
        \\  gt events list [--json] [--limit N] [--ref REF]
        \\  gt issue list [--json]
        \\  gt issue open --title TITLE [--body BODY] [--label LABEL] [--assignee PRINCIPAL]
        \\  gt sync [--remote REMOTE] [--pull-only|--push-only]
        \\  gt web [--host 127.0.0.1] [--port 8080]
        \\
        \\Gitomi stores local state in .git/gitomi and signed events in refs/gitomi/inbox/*.
        \\
    , .{});
}

fn cmdInit(allocator: Allocator, args: []const []const u8) !void {
    var repo_id_arg: ?[]const u8 = null;
    var principal_arg: ?[]const u8 = null;
    var device_arg: ?[]const u8 = null;
    var force = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--repo-id")) {
            repo_id_arg = try util.requireValue(args, &i, "--repo-id");
        } else if (std.mem.eql(u8, arg, "--principal")) {
            principal_arg = try util.requireValue(args, &i, "--principal");
        } else if (std.mem.eql(u8, arg, "--device")) {
            device_arg = try util.requireValue(args, &i, "--device");
        } else if (std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else {
            try io.eprint("gt init: unknown option '{s}'\n", .{arg});
            return CliError.UserError;
        }
    }

    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();

    if (!force and util.fileExists(repo.config_path)) {
        try io.eprint("gt init: {s} already exists; use --force to replace it\n", .{repo.config_path});
        return CliError.UserError;
    }

    try std.fs.cwd().makePath(repo.gitomi_dir);

    const repo_id = if (repo_id_arg) |id| try allocator.dupe(u8, id) else try util.newUuidV7(allocator);
    defer allocator.free(repo_id);
    if (!util.looksLikeUuid(repo_id)) {
        try io.eprint("gt init: repo id must be a UUID string\n", .{});
        return CliError.UserError;
    }

    const principal = if (principal_arg) |id|
        try util.checkedRefSegment(allocator, id, "principal")
    else
        try repo_mod.defaultPrincipal(allocator);
    defer allocator.free(principal);

    const device = if (device_arg) |id|
        try util.checkedRefSegment(allocator, id, "device")
    else
        try repo_mod.defaultDevice(allocator);
    defer allocator.free(device);

    var cfg = repo_mod.Config{
        .allocator = allocator,
        .repo_id = try allocator.dupe(u8, repo_id),
        .principal = try allocator.dupe(u8, principal),
        .device = try allocator.dupe(u8, device),
        .seq = 0,
    };
    defer cfg.deinit();

    try repo_mod.writeConfig(repo.config_path, cfg);

    try io.out("initialized Gitomi repository\n", .{});
    try io.out("  repo:      {s}\n", .{repo.root});
    try io.out("  config:    {s}\n", .{repo.config_path});
    try io.out("  repo_id:   {s}\n", .{cfg.repo_id});
    try io.out("  actor:     {s}/{s}\n", .{ cfg.principal, cfg.device });
    const ref = try repo_mod.inboxRef(allocator, cfg);
    defer allocator.free(ref);
    try io.out("  inbox ref: {s}\n", .{ref});
}

fn cmdStatus(allocator: Allocator) !void {
    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();

    var cfg = repo_mod.loadConfig(allocator, repo.config_path) catch |err| switch (err) {
        CliError.ConfigNotFound => {
            try io.eprint("gt status: Gitomi is not initialized; run `gt init`\n", .{});
            return CliError.UserError;
        },
        else => return err,
    };
    defer cfg.deinit();

    const inbox_ref = try repo_mod.inboxRef(allocator, cfg);
    defer allocator.free(inbox_ref);

    const inbox_refs = try git.gitChecked(allocator, &.{
        "for-each-ref",
        "--format=%(refname)",
        "refs/gitomi/inbox",
    });
    defer allocator.free(inbox_refs);

    const staged_refs = try git.gitChecked(allocator, &.{
        "for-each-ref",
        "--format=%(refname)",
        "refs/gitomi/staging",
    });
    defer allocator.free(staged_refs);

    try index.ensureIndex(allocator, repo);
    const event_count = try index.countIndexedEvents(allocator, repo);

    try io.out("repository: {s}\n", .{repo.root});
    try io.out("git_dir:    {s}\n", .{repo.git_dir});
    try io.out("repo_id:    {s}\n", .{cfg.repo_id});
    try io.out("actor:      {s}/{s}\n", .{ cfg.principal, cfg.device });
    try io.out("seq:        {d}\n", .{cfg.seq});
    try io.out("inbox_ref:  {s}\n", .{inbox_ref});
    try io.out("inbox_refs: {d}\n", .{util.countNonEmptyLines(inbox_refs)});
    try io.out("staged:     {d}\n", .{util.countNonEmptyLines(staged_refs)});
    try io.out("events:     {d}\n", .{event_count});

    try git.printGitConfigValue(allocator, "gpg.format", "signing");
    try git.printGitConfigValue(allocator, "user.signingkey", "signingkey");
    try git.printGitConfigValue(allocator, "gpg.ssh.allowedSignersFile", "allowed_signers");
}

fn cmdFsck(allocator: Allocator, args: []const []const u8) !void {
    if (args.len != 0) {
        try io.eprint("gt fsck: unexpected argument '{s}'\n", .{args[0]});
        return CliError.UserError;
    }

    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();

    var config_invalid = false;
    var cfg_opt: ?repo_mod.Config = repo_mod.loadConfig(allocator, repo.config_path) catch |err| switch (err) {
        CliError.ConfigNotFound => null,
        CliError.ConfigInvalid => blk: {
            config_invalid = true;
            break :blk null;
        },
        else => return err,
    };
    defer if (cfg_opt) |*cfg| cfg.deinit();

    var checker = fsck.State.init(allocator, if (cfg_opt) |cfg| cfg.repo_id else null);
    defer checker.deinit();

    if (config_invalid) {
        try checker.fail("{s}: invalid Gitomi config", .{repo.config_path});
    }

    const refs = try git.listRefs(allocator, "refs/gitomi/inbox");
    defer git.freeStringList(allocator, refs);

    const empty_tree = try git.emptyTreeOid(allocator);
    defer allocator.free(empty_tree);

    for (refs) |ref| {
        try fsck.checkInboxRef(allocator, &checker, ref, empty_tree);
    }

    if (checker.errors == 0) {
        try io.out("fsck ok: {d} inbox ref{s}, {d} event{s}\n", .{
            checker.refs,
            if (checker.refs == 1) "" else "s",
            checker.commits,
            if (checker.commits == 1) "" else "s",
        });
        return;
    }

    try io.eprint("fsck failed: {d} error{s} across {d} inbox ref{s}, {d} event{s}\n", .{
        checker.errors,
        if (checker.errors == 1) "" else "s",
        checker.refs,
        if (checker.refs == 1) "" else "s",
        checker.commits,
        if (checker.commits == 1) "" else "s",
    });
    return CliError.UserError;
}

fn cmdIndex(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0 or std.mem.eql(u8, args[0], "status")) {
        if (args.len > 1) {
            try io.eprint("gt index status: unexpected argument '{s}'\n", .{args[1]});
            return CliError.UserError;
        }

        var repo = try repo_mod.discoverRepo(allocator);
        defer repo.deinit();

        const fresh = try index.isIndexFresh(allocator, repo);
        const event_count = if (fresh) try index.countIndexedEvents(allocator, repo) else @as(usize, 0);
        try io.out("index: {s}\n", .{repo.index_path});
        try io.out("state: {s}\n", .{if (fresh) "fresh" else "stale"});
        if (fresh) try io.out("events: {d}\n", .{event_count});
        return;
    }

    if (std.mem.eql(u8, args[0], "rebuild")) {
        if (args.len > 1) {
            try io.eprint("gt index rebuild: unexpected argument '{s}'\n", .{args[1]});
            return CliError.UserError;
        }

        var repo = try repo_mod.discoverRepo(allocator);
        defer repo.deinit();
        const stats = try index.rebuildIndex(allocator, repo);
        try io.out("rebuilt index: {d} inbox ref{s}, {d} event{s}\n", .{
            stats.refs,
            if (stats.refs == 1) "" else "s",
            stats.events,
            if (stats.events == 1) "" else "s",
        });
        try io.out("  {s}\n", .{repo.index_path});
        return;
    }

    try io.eprint("gt index: expected subcommand 'rebuild' or 'status'\n", .{});
    return CliError.UserError;
}

fn cmdRefs(allocator: Allocator) !void {
    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();
    const refs = try git.gitChecked(allocator, &.{
        "for-each-ref",
        "--sort=refname",
        "--format=%(refname) %(objectname:short)",
        "refs/gitomi",
    });
    defer allocator.free(refs);

    if (std.mem.trim(u8, refs, " \t\r\n").len == 0) {
        try io.out("no Gitomi refs\n", .{});
    } else {
        try io.out("{s}", .{refs});
    }
}

fn cmdEvents(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0 or !std.mem.eql(u8, args[0], "list")) {
        try io.eprint("gt events: expected subcommand 'list'\n", .{});
        return CliError.UserError;
    }

    var json = false;
    var limit: ?usize = null;
    var one_ref: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, arg, "--limit")) {
            const raw = try util.requireValue(args, &i, "--limit");
            limit = std.fmt.parseUnsigned(usize, raw, 10) catch {
                try io.eprint("gt events list: --limit must be a positive integer\n", .{});
                return CliError.UserError;
            };
        } else if (std.mem.eql(u8, arg, "--ref")) {
            one_ref = try util.requireValue(args, &i, "--ref");
        } else {
            try io.eprint("gt events list: unknown option '{s}'\n", .{arg});
            return CliError.UserError;
        }
    }

    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();
    try index.ensureIndex(allocator, repo);
    try index.listEventsFromIndex(allocator, repo, json, limit, one_ref);
}

fn cmdIssue(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try io.eprint("gt issue: expected subcommand 'list' or 'open'\n", .{});
        return CliError.UserError;
    }

    if (std.mem.eql(u8, args[0], "list")) {
        var json = false;
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--json")) {
                json = true;
            } else {
                try io.eprint("gt issue list: unknown option '{s}'\n", .{arg});
                return CliError.UserError;
            }
        }

        var repo = try repo_mod.discoverRepo(allocator);
        defer repo.deinit();
        try index.ensureIndex(allocator, repo);
        try index.listIssuesFromIndex(allocator, repo, json);
        return;
    }

    if (!std.mem.eql(u8, args[0], "open")) {
        try io.eprint("gt issue: expected subcommand 'list' or 'open'\n", .{});
        return CliError.UserError;
    }

    var title: ?[]const u8 = null;
    var body: []const u8 = "";
    var labels: std.ArrayList([]const u8) = .empty;
    defer labels.deinit(allocator);
    var assignees: std.ArrayList([]const u8) = .empty;
    defer assignees.deinit(allocator);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--title") or std.mem.eql(u8, arg, "-t")) {
            title = try util.requireValue(args, &i, "--title");
        } else if (std.mem.eql(u8, arg, "--body") or std.mem.eql(u8, arg, "-b")) {
            body = try util.requireValue(args, &i, "--body");
        } else if (std.mem.eql(u8, arg, "--label") or std.mem.eql(u8, arg, "-l")) {
            try labels.append(allocator, try util.requireValue(args, &i, "--label"));
        } else if (std.mem.eql(u8, arg, "--assignee") or std.mem.eql(u8, arg, "-a")) {
            try assignees.append(allocator, try util.requireValue(args, &i, "--assignee"));
        } else {
            try io.eprint("gt issue open: unknown option '{s}'\n", .{arg});
            return CliError.UserError;
        }
    }

    if (title == null or std.mem.trim(u8, title.?, " \t\r\n").len == 0) {
        try io.eprint("gt issue open: --title is required\n", .{});
        return CliError.UserError;
    }

    try issue.createIssueOpenedEvent(allocator, title.?, body, labels.items, assignees.items);
}

fn cmdSync(allocator: Allocator, args: []const []const u8) !void {
    var remote: []const u8 = "origin";
    var pull = true;
    var push = true;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--remote")) {
            remote = try util.requireValue(args, &i, "--remote");
        } else if (std.mem.eql(u8, arg, "--pull-only")) {
            pull = true;
            push = false;
        } else if (std.mem.eql(u8, arg, "--push-only")) {
            pull = false;
            push = true;
        } else {
            try io.eprint("gt sync: unknown option '{s}'\n", .{arg});
            return CliError.UserError;
        }
    }

    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();

    if (pull) {
        try sync.syncPull(allocator, remote);
    }

    if (push) {
        try sync.syncPush(allocator, remote);
    }
}

fn cmdWeb(allocator: Allocator, args: []const []const u8) !void {
    var options = web.Options{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--host")) {
            options.host = try util.requireValue(args, &i, "--host");
        } else if (std.mem.eql(u8, arg, "--port")) {
            const raw = try util.requireValue(args, &i, "--port");
            options.port = std.fmt.parseUnsigned(u16, raw, 10) catch {
                try io.eprint("gt web: --port must be an integer from 1 to 65535\n", .{});
                return CliError.UserError;
            };
        } else if (std.mem.eql(u8, arg, "--once")) {
            options.once = true;
        } else {
            try io.eprint("gt web: unknown option '{s}'\n", .{arg});
            return CliError.UserError;
        }
    }

    if (!web.isLoopbackHost(options.host)) {
        try io.eprint("gt web: refusing to bind non-loopback host '{s}' for local-only mode\n", .{options.host});
        return CliError.UserError;
    }

    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();

    try web.serve(allocator, repo, options);
}
