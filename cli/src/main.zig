const std = @import("std");

const Allocator = std.mem.Allocator;
const max_git_output = 16 * 1024 * 1024;
const max_index_bytes = 256 * 1024 * 1024;
const config_max_size = 128 * 1024;
const event_schema = "urn:gitomi:event:v1";

const CliError = error{
    UserError,
    GitFailed,
    ConfigNotFound,
    ConfigInvalid,
    NotGitRepository,
};

const Repo = struct {
    allocator: Allocator,
    root: []u8,
    git_dir: []u8,
    gitomi_dir: []u8,
    config_path: []u8,
    index_path: []u8,
    index_refs_path: []u8,

    fn deinit(self: *Repo) void {
        self.allocator.free(self.root);
        self.allocator.free(self.git_dir);
        self.allocator.free(self.gitomi_dir);
        self.allocator.free(self.config_path);
        self.allocator.free(self.index_path);
        self.allocator.free(self.index_refs_path);
    }
};

const Config = struct {
    allocator: Allocator,
    repo_id: []u8,
    principal: []u8,
    device: []u8,
    seq: u64,

    fn deinit(self: *Config) void {
        self.allocator.free(self.repo_id);
        self.allocator.free(self.principal);
        self.allocator.free(self.device);
    }
};

const RunOutput = struct {
    allocator: Allocator,
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,

    fn deinit(self: *RunOutput) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }

    fn exitCode(self: RunOutput) ?u8 {
        return switch (self.term) {
            .Exited => |code| code,
            else => null,
        };
    }
};

const EventSummary = struct {
    allocator: Allocator,
    event_type: []u8,
    object_kind: []u8,
    object_id: []u8,
    actor_principal: []u8,
    actor_device: []u8,
    seq: ?i64 = null,
    occurred_at: []u8,

    fn deinit(self: EventSummary) void {
        self.allocator.free(self.event_type);
        self.allocator.free(self.object_kind);
        self.allocator.free(self.object_id);
        self.allocator.free(self.actor_principal);
        self.allocator.free(self.actor_device);
        self.allocator.free(self.occurred_at);
    }
};

const FsckEnvelope = struct {
    allocator: Allocator,
    repo_id: []u8,
    actor_principal: []u8,
    actor_device: []u8,
    seq: u64,

    fn deinit(self: FsckEnvelope) void {
        self.allocator.free(self.repo_id);
        self.allocator.free(self.actor_principal);
        self.allocator.free(self.actor_device);
    }
};

const FsckState = struct {
    allocator: Allocator,
    config_repo_id: ?[]const u8,
    observed_repo_id: ?[]u8 = null,
    actor_seqs: std.BufSet,
    refs: usize = 0,
    commits: usize = 0,
    errors: usize = 0,

    fn init(allocator: Allocator, config_repo_id: ?[]const u8) FsckState {
        return .{
            .allocator = allocator,
            .config_repo_id = config_repo_id,
            .actor_seqs = std.BufSet.init(allocator),
        };
    }

    fn deinit(self: *FsckState) void {
        if (self.observed_repo_id) |repo_id| self.allocator.free(repo_id);
        self.actor_seqs.deinit();
    }

    fn fail(self: *FsckState, comptime fmt: []const u8, args: anytype) !void {
        self.errors += 1;
        try eprint("error: " ++ fmt ++ "\n", args);
    }

    fn checkRepoId(self: *FsckState, commit: []const u8, repo_id: []const u8) !void {
        if (self.config_repo_id) |expected| {
            if (!std.mem.eql(u8, repo_id, expected)) {
                try self.fail("{s}: repo_id {s} does not match config repo_id {s}", .{ commit, repo_id, expected });
            }
            return;
        }

        if (self.observed_repo_id) |expected| {
            if (!std.mem.eql(u8, repo_id, expected)) {
                try self.fail("{s}: repo_id {s} does not match repository repo_id {s}", .{ commit, repo_id, expected });
            }
        } else {
            self.observed_repo_id = try self.allocator.dupe(u8, repo_id);
        }
    }

    fn checkActorSeq(self: *FsckState, commit: []const u8, principal: []const u8, device: []const u8, seq: u64) !void {
        const key = try std.fmt.allocPrint(self.allocator, "{d}:{s}\x1f{d}:{s}\x1f{d}", .{ principal.len, principal, device.len, device, seq });
        defer self.allocator.free(key);

        if (self.actor_seqs.contains(key)) {
            try self.fail("{s}: duplicate actor sequence ({s}, {s}, {d})", .{ commit, principal, device, seq });
            return;
        }
        try self.actor_seqs.insert(key);
    }
};

const IndexStats = struct {
    refs: usize = 0,
    events: usize = 0,
};

pub fn main() void {
    realMain() catch |err| {
        if (err != CliError.UserError and err != CliError.GitFailed) {
            eprint("gt: {s}\n", .{@errorName(err)}) catch {};
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
        try out("gt 0.1.0\n", .{});
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
    } else {
        try eprint("gt: unknown command '{s}'\n\n", .{cmd});
        try printUsage();
        return CliError.UserError;
    }
}

fn printUsage() !void {
    try out(
        \\Usage:
        \\  gt init [--principal ID] [--device ID] [--repo-id UUID] [--force]
        \\  gt status
        \\  gt fsck
        \\  gt index rebuild|status
        \\  gt refs
        \\  gt events list [--json] [--limit N] [--ref REF]
        \\  gt issue open --title TITLE [--body BODY] [--label LABEL] [--assignee PRINCIPAL]
        \\  gt sync [--remote REMOTE] [--pull-only|--push-only]
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
            repo_id_arg = try requireValue(args, &i, "--repo-id");
        } else if (std.mem.eql(u8, arg, "--principal")) {
            principal_arg = try requireValue(args, &i, "--principal");
        } else if (std.mem.eql(u8, arg, "--device")) {
            device_arg = try requireValue(args, &i, "--device");
        } else if (std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else {
            try eprint("gt init: unknown option '{s}'\n", .{arg});
            return CliError.UserError;
        }
    }

    var repo = try discoverRepo(allocator);
    defer repo.deinit();

    if (!force and fileExists(repo.config_path)) {
        try eprint("gt init: {s} already exists; use --force to replace it\n", .{repo.config_path});
        return CliError.UserError;
    }

    try std.fs.cwd().makePath(repo.gitomi_dir);

    const repo_id = if (repo_id_arg) |id| try allocator.dupe(u8, id) else try newUuidV7(allocator);
    defer allocator.free(repo_id);
    if (!looksLikeUuid(repo_id)) {
        try eprint("gt init: repo id must be a UUID string\n", .{});
        return CliError.UserError;
    }

    const principal = if (principal_arg) |id|
        try checkedRefSegment(allocator, id, "principal")
    else
        try defaultPrincipal(allocator);
    defer allocator.free(principal);

    const device = if (device_arg) |id|
        try checkedRefSegment(allocator, id, "device")
    else
        try defaultDevice(allocator);
    defer allocator.free(device);

    var cfg = Config{
        .allocator = allocator,
        .repo_id = try allocator.dupe(u8, repo_id),
        .principal = try allocator.dupe(u8, principal),
        .device = try allocator.dupe(u8, device),
        .seq = 0,
    };
    defer cfg.deinit();

    try writeConfig(repo.config_path, cfg);

    try out("initialized Gitomi repository\n", .{});
    try out("  repo:      {s}\n", .{repo.root});
    try out("  config:    {s}\n", .{repo.config_path});
    try out("  repo_id:   {s}\n", .{cfg.repo_id});
    try out("  actor:     {s}/{s}\n", .{ cfg.principal, cfg.device });
    const ref = try inboxRef(allocator, cfg);
    defer allocator.free(ref);
    try out("  inbox ref: {s}\n", .{ref});
}

fn cmdStatus(allocator: Allocator) !void {
    var repo = try discoverRepo(allocator);
    defer repo.deinit();

    var cfg = loadConfig(allocator, repo.config_path) catch |err| switch (err) {
        CliError.ConfigNotFound => {
            try eprint("gt status: Gitomi is not initialized; run `gt init`\n", .{});
            return CliError.UserError;
        },
        else => return err,
    };
    defer cfg.deinit();

    const inbox_ref = try inboxRef(allocator, cfg);
    defer allocator.free(inbox_ref);

    const inbox_refs = try gitChecked(allocator, &.{
        "for-each-ref",
        "--format=%(refname)",
        "refs/gitomi/inbox",
    });
    defer allocator.free(inbox_refs);

    const staged_refs = try gitChecked(allocator, &.{
        "for-each-ref",
        "--format=%(refname)",
        "refs/gitomi/staging",
    });
    defer allocator.free(staged_refs);

    try ensureIndex(allocator, repo);
    const event_count = try countIndexedEvents(allocator, repo);

    try out("repository: {s}\n", .{repo.root});
    try out("git_dir:    {s}\n", .{repo.git_dir});
    try out("repo_id:    {s}\n", .{cfg.repo_id});
    try out("actor:      {s}/{s}\n", .{ cfg.principal, cfg.device });
    try out("seq:        {d}\n", .{cfg.seq});
    try out("inbox_ref:  {s}\n", .{inbox_ref});
    try out("inbox_refs: {d}\n", .{countNonEmptyLines(inbox_refs)});
    try out("staged:     {d}\n", .{countNonEmptyLines(staged_refs)});
    try out("events:     {d}\n", .{event_count});

    try printGitConfigValue(allocator, "gpg.format", "signing");
    try printGitConfigValue(allocator, "user.signingkey", "signingkey");
    try printGitConfigValue(allocator, "gpg.ssh.allowedSignersFile", "allowed_signers");
}

fn cmdFsck(allocator: Allocator, args: []const []const u8) !void {
    if (args.len != 0) {
        try eprint("gt fsck: unexpected argument '{s}'\n", .{args[0]});
        return CliError.UserError;
    }

    var repo = try discoverRepo(allocator);
    defer repo.deinit();

    var config_invalid = false;
    var cfg_opt: ?Config = loadConfig(allocator, repo.config_path) catch |err| switch (err) {
        CliError.ConfigNotFound => null,
        CliError.ConfigInvalid => blk: {
            config_invalid = true;
            break :blk null;
        },
        else => return err,
    };
    defer if (cfg_opt) |*cfg| cfg.deinit();

    var fsck = FsckState.init(allocator, if (cfg_opt) |cfg| cfg.repo_id else null);
    defer fsck.deinit();

    if (config_invalid) {
        try fsck.fail("{s}: invalid Gitomi config", .{repo.config_path});
    }

    const refs = try listRefs(allocator, "refs/gitomi/inbox");
    defer freeStringList(allocator, refs);

    const empty_tree = try emptyTreeOid(allocator);
    defer allocator.free(empty_tree);

    for (refs) |ref| {
        try fsckCheckInboxRef(allocator, &fsck, ref, empty_tree);
    }

    if (fsck.errors == 0) {
        try out("fsck ok: {d} inbox ref{s}, {d} event{s}\n", .{
            fsck.refs,
            if (fsck.refs == 1) "" else "s",
            fsck.commits,
            if (fsck.commits == 1) "" else "s",
        });
        return;
    }

    try eprint("fsck failed: {d} error{s} across {d} inbox ref{s}, {d} event{s}\n", .{
        fsck.errors,
        if (fsck.errors == 1) "" else "s",
        fsck.refs,
        if (fsck.refs == 1) "" else "s",
        fsck.commits,
        if (fsck.commits == 1) "" else "s",
    });
    return CliError.UserError;
}

fn cmdIndex(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0 or std.mem.eql(u8, args[0], "status")) {
        if (args.len > 1) {
            try eprint("gt index status: unexpected argument '{s}'\n", .{args[1]});
            return CliError.UserError;
        }

        var repo = try discoverRepo(allocator);
        defer repo.deinit();

        const fresh = try isIndexFresh(allocator, repo);
        const event_count = if (fresh) try countIndexedEvents(allocator, repo) else @as(usize, 0);
        try out("index: {s}\n", .{repo.index_path});
        try out("refs:  {s}\n", .{repo.index_refs_path});
        try out("state: {s}\n", .{if (fresh) "fresh" else "stale"});
        if (fresh) try out("events: {d}\n", .{event_count});
        return;
    }

    if (std.mem.eql(u8, args[0], "rebuild")) {
        if (args.len > 1) {
            try eprint("gt index rebuild: unexpected argument '{s}'\n", .{args[1]});
            return CliError.UserError;
        }

        var repo = try discoverRepo(allocator);
        defer repo.deinit();
        const stats = try rebuildIndex(allocator, repo);
        try out("rebuilt index: {d} inbox ref{s}, {d} event{s}\n", .{
            stats.refs,
            if (stats.refs == 1) "" else "s",
            stats.events,
            if (stats.events == 1) "" else "s",
        });
        try out("  {s}\n", .{repo.index_path});
        return;
    }

    try eprint("gt index: expected subcommand 'rebuild' or 'status'\n", .{});
    return CliError.UserError;
}

fn cmdRefs(allocator: Allocator) !void {
    var repo = try discoverRepo(allocator);
    defer repo.deinit();
    const refs = try gitChecked(allocator, &.{
        "for-each-ref",
        "--sort=refname",
        "--format=%(refname) %(objectname:short)",
        "refs/gitomi",
    });
    defer allocator.free(refs);

    if (std.mem.trim(u8, refs, " \t\r\n").len == 0) {
        try out("no Gitomi refs\n", .{});
    } else {
        try out("{s}", .{refs});
    }
}

fn cmdEvents(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0 or !std.mem.eql(u8, args[0], "list")) {
        try eprint("gt events: expected subcommand 'list'\n", .{});
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
            const raw = try requireValue(args, &i, "--limit");
            limit = std.fmt.parseUnsigned(usize, raw, 10) catch {
                try eprint("gt events list: --limit must be a positive integer\n", .{});
                return CliError.UserError;
            };
        } else if (std.mem.eql(u8, arg, "--ref")) {
            one_ref = try requireValue(args, &i, "--ref");
        } else {
            try eprint("gt events list: unknown option '{s}'\n", .{arg});
            return CliError.UserError;
        }
    }

    var repo = try discoverRepo(allocator);
    defer repo.deinit();
    try ensureIndex(allocator, repo);
    try listEventsFromIndex(allocator, repo, json, limit, one_ref);
}

fn cmdIssue(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0 or !std.mem.eql(u8, args[0], "open")) {
        try eprint("gt issue: expected subcommand 'open'\n", .{});
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
            title = try requireValue(args, &i, "--title");
        } else if (std.mem.eql(u8, arg, "--body") or std.mem.eql(u8, arg, "-b")) {
            body = try requireValue(args, &i, "--body");
        } else if (std.mem.eql(u8, arg, "--label") or std.mem.eql(u8, arg, "-l")) {
            try labels.append(allocator, try requireValue(args, &i, "--label"));
        } else if (std.mem.eql(u8, arg, "--assignee") or std.mem.eql(u8, arg, "-a")) {
            try assignees.append(allocator, try requireValue(args, &i, "--assignee"));
        } else {
            try eprint("gt issue open: unknown option '{s}'\n", .{arg});
            return CliError.UserError;
        }
    }

    if (title == null or std.mem.trim(u8, title.?, " \t\r\n").len == 0) {
        try eprint("gt issue open: --title is required\n", .{});
        return CliError.UserError;
    }

    try createIssueOpenedEvent(allocator, title.?, body, labels.items, assignees.items);
}

fn cmdSync(allocator: Allocator, args: []const []const u8) !void {
    var remote: []const u8 = "origin";
    var pull = true;
    var push = true;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--remote")) {
            remote = try requireValue(args, &i, "--remote");
        } else if (std.mem.eql(u8, arg, "--pull-only")) {
            pull = true;
            push = false;
        } else if (std.mem.eql(u8, arg, "--push-only")) {
            pull = false;
            push = true;
        } else {
            try eprint("gt sync: unknown option '{s}'\n", .{arg});
            return CliError.UserError;
        }
    }

    var repo = try discoverRepo(allocator);
    defer repo.deinit();

    if (pull) {
        try syncPull(allocator, remote);
    }

    if (push) {
        try syncPush(allocator, remote);
    }
}

fn syncPull(allocator: Allocator, remote: []const u8) !void {
    const remote_segment = try stagingRemoteSegment(allocator, remote);
    defer allocator.free(remote_segment);
    const staging_prefix = try std.fmt.allocPrint(allocator, "refs/gitomi/staging/{s}", .{remote_segment});
    defer allocator.free(staging_prefix);
    const fetch_refspec = try std.fmt.allocPrint(allocator, "+refs/gitomi/inbox/*:{s}/inbox/*", .{staging_prefix});
    defer allocator.free(fetch_refspec);

    try out("fetching Gitomi inbox refs from {s} into {s}\n", .{ remote, staging_prefix });
    const fetched = try gitChecked(allocator, &.{ "fetch", remote, fetch_refspec });
    defer allocator.free(fetched);
    if (fetched.len != 0) try out("{s}", .{fetched});

    try admitStagedInboxRefs(allocator, staging_prefix);
}

fn syncPush(allocator: Allocator, remote: []const u8) !void {
    const refs = try listRefs(allocator, "refs/gitomi/inbox");
    defer freeStringList(allocator, refs);

    if (refs.len == 0) {
        try out("no local Gitomi inbox refs to push\n", .{});
        return;
    }

    var push_args: std.ArrayList([]const u8) = .empty;
    defer push_args.deinit(allocator);
    var refspecs: std.ArrayList([]u8) = .empty;
    defer {
        for (refspecs.items) |refspec| allocator.free(refspec);
        refspecs.deinit(allocator);
    }

    try push_args.append(allocator, "push");
    try push_args.append(allocator, remote);
    for (refs) |ref| {
        const refspec = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ ref, ref });
        try refspecs.append(allocator, refspec);
        try push_args.append(allocator, refspec);
    }

    try out("pushing {d} Gitomi inbox ref{s} to {s}\n", .{ refs.len, if (refs.len == 1) "" else "s", remote });
    const pushed = try gitChecked(allocator, push_args.items);
    defer allocator.free(pushed);
    if (pushed.len != 0) try out("{s}", .{pushed});
}

fn createIssueOpenedEvent(
    allocator: Allocator,
    title: []const u8,
    body: []const u8,
    labels: []const []const u8,
    assignees: []const []const u8,
) !void {
    var repo = try discoverRepo(allocator);
    defer repo.deinit();

    var cfg = loadConfig(allocator, repo.config_path) catch |err| switch (err) {
        CliError.ConfigNotFound => {
            try eprint("gt issue open: Gitomi is not initialized; run `gt init`\n", .{});
            return CliError.UserError;
        },
        else => return err,
    };
    defer cfg.deinit();

    const inbox_ref = try inboxRef(allocator, cfg);
    defer allocator.free(inbox_ref);

    const issue_id = try newUuidV7(allocator);
    defer allocator.free(issue_id);
    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);

    const next_seq = cfg.seq + 1;
    const event_body = try buildIssueOpenedJson(
        allocator,
        cfg,
        next_seq,
        issue_id,
        event_uuid,
        idem,
        occurred_at,
        title,
        body,
        labels,
        assignees,
    );
    defer allocator.free(event_body);

    const empty_tree = try emptyTreeOid(allocator);
    defer allocator.free(empty_tree);

    const old_head = try resolveOptionalRef(allocator, inbox_ref);
    defer if (old_head) |head| allocator.free(head);

    const all_heads = try inboxHeads(allocator);
    defer freeStringList(allocator, all_heads);

    var commit_args: std.ArrayList([]const u8) = .empty;
    defer commit_args.deinit(allocator);
    try commit_args.append(allocator, "commit-tree");
    try commit_args.append(allocator, "-S");
    const subject = try std.fmt.allocPrint(allocator, "issue.opened #{s} {s}", .{ issue_id[0..7], title });
    defer allocator.free(subject);
    try commit_args.append(allocator, "-m");
    try commit_args.append(allocator, subject);
    try commit_args.append(allocator, "-m");
    try commit_args.append(allocator, event_body);
    try commit_args.append(allocator, empty_tree);

    if (old_head) |head| {
        try commit_args.append(allocator, "-p");
        try commit_args.append(allocator, head);
        for (all_heads) |known_head| {
            if (std.mem.eql(u8, known_head, head)) continue;
            try commit_args.append(allocator, "-p");
            try commit_args.append(allocator, known_head);
        }
    }

    const commit_raw = gitChecked(allocator, commit_args.items) catch |err| {
        if (err == CliError.GitFailed) {
            try eprint("gt issue open: failed to create signed event commit; check Git commit signing configuration\n", .{});
        }
        return err;
    };
    const commit_oid = try trimOwned(allocator, commit_raw);
    defer allocator.free(commit_oid);

    if (old_head) |head| {
        const updated = try gitChecked(allocator, &.{ "update-ref", inbox_ref, commit_oid, head });
        defer allocator.free(updated);
    } else {
        const updated = try gitChecked(allocator, &.{ "update-ref", inbox_ref, commit_oid, "" });
        defer allocator.free(updated);
    }

    cfg.seq = next_seq;
    try writeConfig(repo.config_path, cfg);

    try out("opened issue #{s}\n", .{issue_id[0..7]});
    try out("  id:     {s}\n", .{issue_id});
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{inbox_ref});
}

fn buildIssueOpenedJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    issue_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    title: []const u8,
    body: []const u8,
    labels: []const []const u8,
    assignees: []const []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.append(allocator, '{');
    try appendJsonFieldString(&buf, allocator, "$schema", event_schema, true);
    try appendJsonFieldString(&buf, allocator, "repo_id", cfg.repo_id, true);
    try appendJsonFieldString(&buf, allocator, "event_uuid", event_uuid, true);
    try appendJsonFieldString(&buf, allocator, "event_type", "issue.opened", true);

    try buf.appendSlice(allocator, "\"object\":{");
    try appendJsonFieldString(&buf, allocator, "kind", "issue", true);
    try appendJsonFieldString(&buf, allocator, "id", issue_id, false);
    try buf.appendSlice(allocator, "},");

    try appendJsonFieldString(&buf, allocator, "idempotency_key", idem, true);

    try buf.appendSlice(allocator, "\"actor\":{");
    try appendJsonFieldString(&buf, allocator, "principal", cfg.principal, true);
    try appendJsonFieldString(&buf, allocator, "device", cfg.device, false);
    try buf.appendSlice(allocator, "},");

    try appendJsonFieldUnsigned(&buf, allocator, "seq", seq, true);
    try appendJsonFieldString(&buf, allocator, "occurred_at", occurred_at, true);
    try buf.appendSlice(allocator, "\"legacy\":{},");

    try buf.appendSlice(allocator, "\"payload\":{");
    try appendJsonFieldString(&buf, allocator, "title", title, true);
    if (body.len != 0) {
        try appendJsonFieldString(&buf, allocator, "body", body, true);
    }
    if (labels.len != 0) {
        try appendJsonFieldStringArray(&buf, allocator, "labels", labels, true);
    }
    if (assignees.len != 0) {
        try appendJsonFieldStringArray(&buf, allocator, "assignees", assignees, true);
    }
    if (buf.items[buf.items.len - 1] == ',') {
        buf.items.len -= 1;
    }
    try buf.appendSlice(allocator, "}}");

    return try buf.toOwnedSlice(allocator);
}

fn appendJsonFieldString(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    key: []const u8,
    value: []const u8,
    comma: bool,
) !void {
    try appendJsonString(buf, allocator, key);
    try buf.append(allocator, ':');
    try appendJsonString(buf, allocator, value);
    if (comma) try buf.append(allocator, ',');
}

fn appendJsonFieldUnsigned(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    key: []const u8,
    value: u64,
    comma: bool,
) !void {
    try appendJsonString(buf, allocator, key);
    try buf.append(allocator, ':');
    const raw = try std.fmt.allocPrint(allocator, "{d}", .{value});
    defer allocator.free(raw);
    try buf.appendSlice(allocator, raw);
    if (comma) try buf.append(allocator, ',');
}

fn appendJsonFieldStringArray(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    key: []const u8,
    values: []const []const u8,
    comma: bool,
) !void {
    try appendJsonString(buf, allocator, key);
    try buf.appendSlice(allocator, ":[");
    for (values, 0..) |value, idx| {
        if (idx != 0) try buf.append(allocator, ',');
        try appendJsonString(buf, allocator, value);
    }
    try buf.append(allocator, ']');
    if (comma) try buf.append(allocator, ',');
}

fn appendJsonString(buf: *std.ArrayList(u8), allocator: Allocator, value: []const u8) !void {
    try buf.append(allocator, '"');
    for (value) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            0x08 => try buf.appendSlice(allocator, "\\b"),
            0x0c => try buf.appendSlice(allocator, "\\f"),
            0x00...0x07, 0x0b, 0x0e...0x1f => {
                const escaped = try std.fmt.allocPrint(allocator, "\\u{x:0>4}", .{c});
                defer allocator.free(escaped);
                try buf.appendSlice(allocator, escaped);
            },
            else => try buf.append(allocator, c),
        }
    }
    try buf.append(allocator, '"');
}

fn discoverRepo(allocator: Allocator) !Repo {
    const root_raw = gitChecked(allocator, &.{ "rev-parse", "--show-toplevel" }) catch |err| {
        if (err == CliError.GitFailed) {
            try eprint("gt: not inside a Git repository\n", .{});
            return CliError.NotGitRepository;
        }
        return err;
    };
    const root = try trimOwned(allocator, root_raw);
    errdefer allocator.free(root);

    const git_dir_raw = gitChecked(allocator, &.{ "rev-parse", "--path-format=absolute", "--git-common-dir" }) catch |err| {
        allocator.free(root);
        return err;
    };
    const git_dir = try trimOwned(allocator, git_dir_raw);
    errdefer allocator.free(git_dir);

    const gitomi_dir = try std.fs.path.join(allocator, &.{ git_dir, "gitomi" });
    errdefer allocator.free(gitomi_dir);
    const config_path = try std.fs.path.join(allocator, &.{ gitomi_dir, "config.toml" });
    errdefer allocator.free(config_path);
    const index_path = try std.fs.path.join(allocator, &.{ gitomi_dir, "index.jsonl" });
    errdefer allocator.free(index_path);
    const index_refs_path = try std.fs.path.join(allocator, &.{ gitomi_dir, "index.refs" });
    errdefer allocator.free(index_refs_path);

    return .{
        .allocator = allocator,
        .root = root,
        .git_dir = git_dir,
        .gitomi_dir = gitomi_dir,
        .config_path = config_path,
        .index_path = index_path,
        .index_refs_path = index_refs_path,
    };
}

fn loadConfig(allocator: Allocator, path: []const u8) !Config {
    const bytes = std.fs.cwd().readFileAlloc(allocator, path, config_max_size) catch |err| switch (err) {
        error.FileNotFound => return CliError.ConfigNotFound,
        else => return err,
    };
    defer allocator.free(bytes);
    return parseConfig(allocator, bytes);
}

fn parseConfig(allocator: Allocator, bytes: []const u8) !Config {
    var repo_id: ?[]u8 = null;
    var principal: ?[]u8 = null;
    var device: ?[]u8 = null;
    var seq: ?u64 = null;
    errdefer {
        if (repo_id) |v| allocator.free(v);
        if (principal) |v| allocator.free(v);
        if (device) |v| allocator.free(v);
    }

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const raw_value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        const value = stripTomlString(raw_value) catch return CliError.ConfigInvalid;

        if (std.mem.eql(u8, key, "repo_id")) {
            if (repo_id) |old| allocator.free(old);
            repo_id = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "principal")) {
            if (principal) |old| allocator.free(old);
            principal = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "device")) {
            if (device) |old| allocator.free(old);
            device = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "seq")) {
            seq = std.fmt.parseUnsigned(u64, raw_value, 10) catch return CliError.ConfigInvalid;
        }
    }

    if (repo_id == null or principal == null or device == null) {
        return CliError.ConfigInvalid;
    }

    return .{
        .allocator = allocator,
        .repo_id = repo_id.?,
        .principal = principal.?,
        .device = device.?,
        .seq = seq orelse 0,
    };
}

fn stripTomlString(raw: []const u8) ![]const u8 {
    if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') {
        return raw[1 .. raw.len - 1];
    }
    return raw;
}

fn writeConfig(path: []const u8, cfg: Config) !void {
    const content = try std.fmt.allocPrint(cfg.allocator,
        \\# Gitomi repo-local configuration.
        \\repo_id = "{s}"
        \\principal = "{s}"
        \\device = "{s}"
        \\seq = {d}
        \\
    , .{ cfg.repo_id, cfg.principal, cfg.device, cfg.seq });
    defer cfg.allocator.free(content);

    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);
}

fn inboxRef(allocator: Allocator, cfg: Config) ![]u8 {
    return std.fmt.allocPrint(allocator, "refs/gitomi/inbox/{s}/{s}", .{ cfg.principal, cfg.device });
}

fn stagingRemoteSegment(allocator: Allocator, remote: []const u8) ![]u8 {
    const segment = try sanitizeRefSegment(allocator, remote);
    if (segment.len != 0) return segment;
    allocator.free(segment);
    return allocator.dupe(u8, "remote");
}

fn admitStagedInboxRefs(allocator: Allocator, staging_prefix: []const u8) !void {
    const staged_inbox_prefix = try std.fmt.allocPrint(allocator, "{s}/inbox", .{staging_prefix});
    defer allocator.free(staged_inbox_prefix);

    const refs = try listRefs(allocator, staged_inbox_prefix);
    defer freeStringList(allocator, refs);

    if (refs.len == 0) {
        try out("no staged Gitomi inbox refs to admit\n", .{});
        return;
    }

    const empty_tree = try emptyTreeOid(allocator);
    defer allocator.free(empty_tree);

    for (refs) |staged_ref| {
        try admitStagedInboxRef(allocator, staging_prefix, staged_ref, empty_tree);
    }
}

fn admitStagedInboxRef(
    allocator: Allocator,
    staging_prefix: []const u8,
    staged_ref: []const u8,
    empty_tree: []const u8,
) !void {
    const staged_oid = (try resolveOptionalRef(allocator, staged_ref)) orelse return;
    defer allocator.free(staged_oid);

    const local_ref = try localRefFromStaged(allocator, staging_prefix, staged_ref);
    defer allocator.free(local_ref);

    const local_oid = try resolveOptionalRef(allocator, local_ref);
    defer if (local_oid) |oid| allocator.free(oid);

    if (local_oid) |old_oid| {
        if (std.mem.eql(u8, old_oid, staged_oid)) {
            try out("unchanged {s}\n", .{local_ref});
            return;
        }

        if (try isAncestor(allocator, old_oid, staged_oid)) {
            const admitted = try validateInboxRange(allocator, staged_ref, old_oid, empty_tree);
            const updated = try gitChecked(allocator, &.{ "update-ref", local_ref, staged_oid, old_oid });
            defer allocator.free(updated);
            try out("fast-forwarded {s} by {d} event{s}\n", .{ local_ref, admitted, if (admitted == 1) "" else "s" });
            return;
        }

        if (try isAncestor(allocator, staged_oid, old_oid)) {
            try out("stale remote {s}; local ref is ahead\n", .{local_ref});
            return;
        }

        try out("diverged {s}; staged ref left at {s}\n", .{ local_ref, staged_ref });
        return;
    }

    const admitted = try validateInboxRange(allocator, staged_ref, null, empty_tree);
    const updated = try gitChecked(allocator, &.{ "update-ref", local_ref, staged_oid, "" });
    defer allocator.free(updated);
    try out("created {s} with {d} event{s}\n", .{ local_ref, admitted, if (admitted == 1) "" else "s" });
}

fn localRefFromStaged(allocator: Allocator, staging_prefix: []const u8, staged_ref: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, staged_ref, staging_prefix) or staged_ref.len <= staging_prefix.len or staged_ref[staging_prefix.len] != '/') {
        try eprint("gt sync: staged ref {s} is outside {s}\n", .{ staged_ref, staging_prefix });
        return CliError.UserError;
    }
    const suffix = staged_ref[staging_prefix.len + 1 ..];
    if (!std.mem.startsWith(u8, suffix, "inbox/")) {
        try eprint("gt sync: refusing to admit non-inbox staged ref {s}\n", .{staged_ref});
        return CliError.UserError;
    }
    return std.fmt.allocPrint(allocator, "refs/gitomi/{s}", .{suffix});
}

fn validateInboxRange(
    allocator: Allocator,
    ref: []const u8,
    local_base: ?[]const u8,
    empty_tree: []const u8,
) !usize {
    const commits = if (local_base) |base|
        try revListRange(allocator, base, ref)
    else
        try gitChecked(allocator, &.{ "rev-list", "--first-parent", "--reverse", ref });
    defer allocator.free(commits);

    var count: usize = 0;
    var expected_first_parent = local_base;
    var it = std.mem.tokenizeScalar(u8, commits, '\n');
    while (it.next()) |commit_raw| {
        const commit = std.mem.trim(u8, commit_raw, " \t\r\n");
        if (commit.len == 0) continue;
        try validateInboxCommit(allocator, commit, expected_first_parent, empty_tree);
        expected_first_parent = commit;
        count += 1;
    }
    return count;
}

fn validateInboxCommit(
    allocator: Allocator,
    commit: []const u8,
    expected_first_parent: ?[]const u8,
    empty_tree: []const u8,
) !void {
    const tree_raw = try gitChecked(allocator, &.{ "show", "-s", "--format=%T", commit });
    defer allocator.free(tree_raw);
    const tree = std.mem.trim(u8, tree_raw, " \t\r\n");
    if (!std.mem.eql(u8, tree, empty_tree)) {
        try eprint("gt sync: rejecting {s}: inbox event does not use the empty tree\n", .{commit});
        return CliError.UserError;
    }

    try validateFirstParent(allocator, commit, expected_first_parent);
    try verifyCommitSignature(allocator, commit);

    const body_raw = try gitChecked(allocator, &.{ "show", "-s", "--format=%b", commit });
    defer allocator.free(body_raw);
    const body = std.mem.trim(u8, body_raw, " \t\r\n");
    try validateEventEnvelope(allocator, commit, body);
}

fn validateFirstParent(allocator: Allocator, commit: []const u8, expected_first_parent: ?[]const u8) !void {
    const parents_raw = try gitChecked(allocator, &.{ "show", "-s", "--format=%P", commit });
    defer allocator.free(parents_raw);
    const parents = std.mem.trim(u8, parents_raw, " \t\r\n");
    var it = std.mem.tokenizeScalar(u8, parents, ' ');
    const first_parent = it.next();

    if (expected_first_parent) |expected| {
        if (first_parent == null or !std.mem.eql(u8, first_parent.?, expected)) {
            try eprint("gt sync: rejecting {s}: first parent is not the previous inbox head\n", .{commit});
            return CliError.UserError;
        }
    } else if (first_parent != null) {
        try eprint("gt sync: rejecting {s}: root inbox event has a first parent\n", .{commit});
        return CliError.UserError;
    }
}

fn verifyCommitSignature(allocator: Allocator, commit: []const u8) !void {
    var argv = [_][]const u8{ "git", "verify-commit", commit };
    var result = try runCommand(allocator, &argv, null, max_git_output);
    defer result.deinit();
    if (result.exitCode() == 0) return;

    const stderr = std.mem.trim(u8, result.stderr, " \t\r\n");
    if (stderr.len != 0) {
        try eprint("gt sync: rejecting {s}: signature verification failed: {s}\n", .{ commit, stderr });
    } else {
        try eprint("gt sync: rejecting {s}: signature verification failed\n", .{commit});
    }
    return CliError.UserError;
}

fn validateEventEnvelope(allocator: Allocator, commit: []const u8, body: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        try eprint("gt sync: rejecting {s}: event body is not valid JSON\n", .{commit});
        return CliError.UserError;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => {
            try eprint("gt sync: rejecting {s}: event body must be a JSON object\n", .{commit});
            return CliError.UserError;
        },
    };

    try requireJsonStringEq(commit, root, "$schema", event_schema);
    try requireJsonUuid(commit, root, "repo_id");
    try requireJsonUuid(commit, root, "event_uuid");
    _ = try requireJsonString(commit, root, "event_type");
    try requireJsonUuid(commit, root, "idempotency_key");
    _ = try requireJsonObject(commit, root, "legacy");
    _ = try requireJsonObject(commit, root, "payload");

    const seq_value = root.get("seq") orelse {
        try eprint("gt sync: rejecting {s}: missing seq\n", .{commit});
        return CliError.UserError;
    };
    if (seq_value != .integer or seq_value.integer < 0) {
        try eprint("gt sync: rejecting {s}: seq must be a non-negative integer\n", .{commit});
        return CliError.UserError;
    }

    const occurred_at = try requireJsonString(commit, root, "occurred_at");
    if (occurred_at.len == 0 or occurred_at[occurred_at.len - 1] != 'Z') {
        try eprint("gt sync: rejecting {s}: occurred_at must be a UTC RFC3339 timestamp\n", .{commit});
        return CliError.UserError;
    }

    const object = try requireJsonObject(commit, root, "object");
    const kind = try requireJsonString(commit, object, "kind");
    if (!isKnownObjectKind(kind)) {
        try eprint("gt sync: rejecting {s}: unknown object kind '{s}'\n", .{ commit, kind });
        return CliError.UserError;
    }
    try requireJsonUuid(commit, object, "id");

    const actor = try requireJsonObject(commit, root, "actor");
    const principal = try requireJsonString(commit, actor, "principal");
    const device = try requireJsonString(commit, actor, "device");
    if (principal.len == 0 or device.len == 0) {
        try eprint("gt sync: rejecting {s}: actor principal and device are required\n", .{commit});
        return CliError.UserError;
    }
}

fn fsckCheckInboxRef(allocator: Allocator, fsck: *FsckState, ref: []const u8, empty_tree: []const u8) !void {
    fsck.refs += 1;
    try fsckCheckInboxRefName(fsck, ref);

    const commits = try gitChecked(allocator, &.{ "rev-list", "--first-parent", "--reverse", ref });
    defer allocator.free(commits);

    var expected_first_parent: ?[]const u8 = null;
    var it = std.mem.tokenizeScalar(u8, commits, '\n');
    while (it.next()) |commit_raw| {
        const commit = std.mem.trim(u8, commit_raw, " \t\r\n");
        if (commit.len == 0) continue;
        try fsckCheckInboxCommit(allocator, fsck, ref, commit, expected_first_parent, empty_tree);
        expected_first_parent = commit;
    }
}

fn fsckCheckInboxRefName(fsck: *FsckState, ref: []const u8) !void {
    const prefix = "refs/gitomi/inbox/";
    if (!std.mem.startsWith(u8, ref, prefix)) {
        try fsck.fail("{s}: inbox ref is outside {s}", .{ ref, prefix });
        return;
    }

    const suffix = ref[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, suffix, '/') orelse {
        try fsck.fail("{s}: inbox ref must be refs/gitomi/inbox/<principal>/<device>", .{ref});
        return;
    };
    const principal = suffix[0..slash];
    const device = suffix[slash + 1 ..];

    if (std.mem.indexOfScalar(u8, device, '/') != null) {
        try fsck.fail("{s}: inbox ref has extra path segments", .{ref});
    }
    if (!isRefSafeSegment(principal)) {
        try fsck.fail("{s}: principal segment is not ref-safe", .{ref});
    }
    if (!isRefSafeSegment(device)) {
        try fsck.fail("{s}: device segment is not ref-safe", .{ref});
    }
}

fn fsckCheckInboxCommit(
    allocator: Allocator,
    fsck: *FsckState,
    ref: []const u8,
    commit: []const u8,
    expected_first_parent: ?[]const u8,
    empty_tree: []const u8,
) !void {
    fsck.commits += 1;

    const tree_raw = try gitChecked(allocator, &.{ "show", "-s", "--format=%T", commit });
    defer allocator.free(tree_raw);
    const tree = std.mem.trim(u8, tree_raw, " \t\r\n");
    if (!std.mem.eql(u8, tree, empty_tree)) {
        try fsck.fail("{s}: {s}: inbox event does not use the empty tree", .{ ref, commit });
    }

    try fsckCheckFirstParent(allocator, fsck, ref, commit, expected_first_parent);
    try fsckVerifyCommitSignature(allocator, fsck, ref, commit);

    const body_raw = try gitChecked(allocator, &.{ "show", "-s", "--format=%b", commit });
    defer allocator.free(body_raw);
    const body = std.mem.trim(u8, body_raw, " \t\r\n");

    const envelope = try fsckParseEnvelope(allocator, fsck, ref, commit, body);
    if (envelope) |parsed| {
        defer parsed.deinit();
        try fsck.checkRepoId(commit, parsed.repo_id);
        try fsck.checkActorSeq(commit, parsed.actor_principal, parsed.actor_device, parsed.seq);
    }
}

fn fsckCheckFirstParent(
    allocator: Allocator,
    fsck: *FsckState,
    ref: []const u8,
    commit: []const u8,
    expected_first_parent: ?[]const u8,
) !void {
    const parents_raw = try gitChecked(allocator, &.{ "show", "-s", "--format=%P", commit });
    defer allocator.free(parents_raw);
    const parents = std.mem.trim(u8, parents_raw, " \t\r\n");
    var it = std.mem.tokenizeScalar(u8, parents, ' ');
    const first_parent = it.next();

    if (expected_first_parent) |expected| {
        if (first_parent == null or !std.mem.eql(u8, first_parent.?, expected)) {
            try fsck.fail("{s}: {s}: first parent is not previous inbox event {s}", .{ ref, commit, expected });
        }
    } else if (first_parent != null) {
        try fsck.fail("{s}: {s}: root inbox event has a parent", .{ ref, commit });
    }
}

fn fsckVerifyCommitSignature(allocator: Allocator, fsck: *FsckState, ref: []const u8, commit: []const u8) !void {
    var argv = [_][]const u8{ "git", "verify-commit", commit };
    var result = try runCommand(allocator, &argv, null, max_git_output);
    defer result.deinit();
    if (result.exitCode() == 0) return;

    const stderr = std.mem.trim(u8, result.stderr, " \t\r\n");
    if (stderr.len != 0) {
        try fsck.fail("{s}: {s}: signature verification failed: {s}", .{ ref, commit, stderr });
    } else {
        try fsck.fail("{s}: {s}: signature verification failed", .{ ref, commit });
    }
}

fn fsckParseEnvelope(
    allocator: Allocator,
    fsck: *FsckState,
    ref: []const u8,
    commit: []const u8,
    body: []const u8,
) !?FsckEnvelope {
    var ok = true;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        try fsck.fail("{s}: {s}: event body is not valid JSON", .{ ref, commit });
        return null;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => {
            try fsck.fail("{s}: {s}: event body must be a JSON object", .{ ref, commit });
            return null;
        },
    };

    const schema = try fsckRequireString(fsck, ref, commit, root, "$schema", &ok);
    if (schema) |value| {
        if (!std.mem.eql(u8, value, event_schema)) {
            try fsck.fail("{s}: {s}: $schema must be {s}", .{ ref, commit, event_schema });
            ok = false;
        }
    }

    const repo_id = try fsckRequireUuid(fsck, ref, commit, root, "repo_id", &ok);
    _ = try fsckRequireUuid(fsck, ref, commit, root, "event_uuid", &ok);
    _ = try fsckRequireString(fsck, ref, commit, root, "event_type", &ok);
    _ = try fsckRequireUuid(fsck, ref, commit, root, "idempotency_key", &ok);
    _ = try fsckRequireObject(fsck, ref, commit, root, "legacy", &ok);
    _ = try fsckRequireObject(fsck, ref, commit, root, "payload", &ok);

    const seq = try fsckRequireSeq(fsck, ref, commit, root, &ok);

    const occurred_at = try fsckRequireString(fsck, ref, commit, root, "occurred_at", &ok);
    if (occurred_at) |value| {
        if (value.len == 0 or value[value.len - 1] != 'Z') {
            try fsck.fail("{s}: {s}: occurred_at must be a UTC RFC3339 timestamp", .{ ref, commit });
            ok = false;
        }
    }

    const object = try fsckRequireObject(fsck, ref, commit, root, "object", &ok);
    if (object) |object_map| {
        const kind = try fsckRequireString(fsck, ref, commit, object_map, "kind", &ok);
        if (kind) |value| {
            if (!isKnownObjectKind(value)) {
                try fsck.fail("{s}: {s}: unknown object kind '{s}'", .{ ref, commit, value });
                ok = false;
            }
        }
        _ = try fsckRequireUuid(fsck, ref, commit, object_map, "id", &ok);
    }

    const actor = try fsckRequireObject(fsck, ref, commit, root, "actor", &ok);
    var actor_principal: ?[]const u8 = null;
    var actor_device: ?[]const u8 = null;
    if (actor) |actor_map| {
        actor_principal = try fsckRequireString(fsck, ref, commit, actor_map, "principal", &ok);
        actor_device = try fsckRequireString(fsck, ref, commit, actor_map, "device", &ok);
    }

    if (!ok or repo_id == null or actor_principal == null or actor_device == null or seq == null) {
        return null;
    }

    var repo_id_owned: ?[]u8 = try allocator.dupe(u8, repo_id.?);
    errdefer if (repo_id_owned) |value| allocator.free(value);
    var principal_owned: ?[]u8 = try allocator.dupe(u8, actor_principal.?);
    errdefer if (principal_owned) |value| allocator.free(value);
    var device_owned: ?[]u8 = try allocator.dupe(u8, actor_device.?);
    errdefer if (device_owned) |value| allocator.free(value);

    const envelope = FsckEnvelope{
        .allocator = allocator,
        .repo_id = repo_id_owned.?,
        .actor_principal = principal_owned.?,
        .actor_device = device_owned.?,
        .seq = seq.?,
    };
    repo_id_owned = null;
    principal_owned = null;
    device_owned = null;
    return envelope;
}

fn fsckRequireObject(
    fsck: *FsckState,
    ref: []const u8,
    commit: []const u8,
    object: std.json.ObjectMap,
    key: []const u8,
    ok: *bool,
) !?std.json.ObjectMap {
    const value = object.get(key) orelse {
        try fsck.fail("{s}: {s}: missing {s}", .{ ref, commit, key });
        ok.* = false;
        return null;
    };
    return switch (value) {
        .object => |child| child,
        else => {
            try fsck.fail("{s}: {s}: {s} must be an object", .{ ref, commit, key });
            ok.* = false;
            return null;
        },
    };
}

fn fsckRequireString(
    fsck: *FsckState,
    ref: []const u8,
    commit: []const u8,
    object: std.json.ObjectMap,
    key: []const u8,
    ok: *bool,
) !?[]const u8 {
    const value = object.get(key) orelse {
        try fsck.fail("{s}: {s}: missing {s}", .{ ref, commit, key });
        ok.* = false;
        return null;
    };
    const string = switch (value) {
        .string => |s| s,
        else => {
            try fsck.fail("{s}: {s}: {s} must be a string", .{ ref, commit, key });
            ok.* = false;
            return null;
        },
    };
    if (string.len == 0) {
        try fsck.fail("{s}: {s}: {s} must not be empty", .{ ref, commit, key });
        ok.* = false;
        return null;
    }
    return string;
}

fn fsckRequireUuid(
    fsck: *FsckState,
    ref: []const u8,
    commit: []const u8,
    object: std.json.ObjectMap,
    key: []const u8,
    ok: *bool,
) !?[]const u8 {
    const value = try fsckRequireString(fsck, ref, commit, object, key, ok);
    if (value) |string| {
        if (!looksLikeUuid(string)) {
            try fsck.fail("{s}: {s}: {s} must be a UUID", .{ ref, commit, key });
            ok.* = false;
            return null;
        }
    }
    return value;
}

fn fsckRequireSeq(
    fsck: *FsckState,
    ref: []const u8,
    commit: []const u8,
    object: std.json.ObjectMap,
    ok: *bool,
) !?u64 {
    const value = object.get("seq") orelse {
        try fsck.fail("{s}: {s}: missing seq", .{ ref, commit });
        ok.* = false;
        return null;
    };
    return switch (value) {
        .integer => |seq| {
            if (seq < 0) {
                try fsck.fail("{s}: {s}: seq must be a non-negative integer", .{ ref, commit });
                ok.* = false;
                return null;
            }
            return @as(u64, @intCast(seq));
        },
        else => {
            try fsck.fail("{s}: {s}: seq must be a non-negative integer", .{ ref, commit });
            ok.* = false;
            return null;
        },
    };
}

fn requireJsonObject(commit: []const u8, object: std.json.ObjectMap, key: []const u8) !std.json.ObjectMap {
    const value = object.get(key) orelse {
        try eprint("gt sync: rejecting {s}: missing {s}\n", .{ commit, key });
        return CliError.UserError;
    };
    return switch (value) {
        .object => |child| child,
        else => {
            try eprint("gt sync: rejecting {s}: {s} must be an object\n", .{ commit, key });
            return CliError.UserError;
        },
    };
}

fn requireJsonString(commit: []const u8, object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse {
        try eprint("gt sync: rejecting {s}: missing {s}\n", .{ commit, key });
        return CliError.UserError;
    };
    const string = switch (value) {
        .string => |s| s,
        else => {
            try eprint("gt sync: rejecting {s}: {s} must be a string\n", .{ commit, key });
            return CliError.UserError;
        },
    };
    if (string.len == 0) {
        try eprint("gt sync: rejecting {s}: {s} must not be empty\n", .{ commit, key });
        return CliError.UserError;
    }
    return string;
}

fn requireJsonStringEq(commit: []const u8, object: std.json.ObjectMap, key: []const u8, expected: []const u8) !void {
    const value = try requireJsonString(commit, object, key);
    if (!std.mem.eql(u8, value, expected)) {
        try eprint("gt sync: rejecting {s}: {s} must be {s}\n", .{ commit, key, expected });
        return CliError.UserError;
    }
}

fn requireJsonUuid(commit: []const u8, object: std.json.ObjectMap, key: []const u8) !void {
    const value = try requireJsonString(commit, object, key);
    if (!looksLikeUuid(value)) {
        try eprint("gt sync: rejecting {s}: {s} must be a UUID\n", .{ commit, key });
        return CliError.UserError;
    }
}

fn isKnownObjectKind(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "issue") or
        std.mem.eql(u8, kind, "pull") or
        std.mem.eql(u8, kind, "comment") or
        std.mem.eql(u8, kind, "acl") or
        std.mem.eql(u8, kind, "identity") or
        std.mem.eql(u8, kind, "action");
}

fn revListRange(allocator: Allocator, base: []const u8, ref: []const u8) ![]u8 {
    const range = try std.fmt.allocPrint(allocator, "{s}..{s}", .{ base, ref });
    defer allocator.free(range);
    return gitChecked(allocator, &.{ "rev-list", "--first-parent", "--reverse", range });
}

fn isAncestor(allocator: Allocator, ancestor: []const u8, descendant: []const u8) !bool {
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

fn listRefs(allocator: Allocator, prefix: []const u8) ![][]u8 {
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

fn ensureIndex(allocator: Allocator, repo: Repo) !void {
    if (try isIndexFresh(allocator, repo)) return;
    _ = try rebuildIndex(allocator, repo);
}

fn isIndexFresh(allocator: Allocator, repo: Repo) !bool {
    if (!fileExists(repo.index_path) or !fileExists(repo.index_refs_path)) return false;

    const current_refs = try currentIndexRefsRaw(allocator);
    defer allocator.free(current_refs);
    const indexed_refs = std.fs.cwd().readFileAlloc(allocator, repo.index_refs_path, max_index_bytes) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer allocator.free(indexed_refs);

    if (!std.mem.eql(u8, current_refs, indexed_refs)) return false;
    if (std.mem.trim(u8, current_refs, " \t\r\n").len != 0 and (try countIndexedEvents(allocator, repo)) == 0) {
        return false;
    }
    return true;
}

fn rebuildIndex(allocator: Allocator, repo: Repo) !IndexStats {
    try std.fs.cwd().makePath(repo.gitomi_dir);

    const refs_raw = try currentIndexRefsRaw(allocator);
    defer allocator.free(refs_raw);

    const index_file = try std.fs.createFileAbsolute(repo.index_path, .{ .truncate = true });
    defer index_file.close();

    const empty_tree = try emptyTreeOid(allocator);
    defer allocator.free(empty_tree);

    var stats = IndexStats{};
    var it = std.mem.tokenizeScalar(u8, refs_raw, '\n');
    while (it.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const ref = std.mem.trim(u8, line[0..tab], " \t\r\n");
        if (ref.len == 0) continue;
        stats.refs += 1;
        stats.events += try indexRefEvents(allocator, index_file, ref, empty_tree);
    }

    const refs_file = try std.fs.createFileAbsolute(repo.index_refs_path, .{ .truncate = true });
    defer refs_file.close();
    try refs_file.writeAll(refs_raw);

    return stats;
}

fn currentIndexRefsRaw(allocator: Allocator) ![]u8 {
    return gitChecked(allocator, &.{
        "for-each-ref",
        "--sort=refname",
        "--format=%(refname)%09%(objectname)",
        "refs/gitomi/inbox",
    });
}

fn indexRefEvents(allocator: Allocator, index_file: std.fs.File, ref: []const u8, empty_tree: []const u8) !usize {
    const log = try gitChecked(allocator, &.{
        "log",
        "--first-parent",
        "--reverse",
        "--format=%H%x00%T%x00%s%x00%b%x1e",
        ref,
    });
    defer allocator.free(log);

    var count: usize = 0;
    var records = std.mem.splitScalar(u8, log, 0x1e);
    while (records.next()) |record_raw| {
        const record = std.mem.trim(u8, record_raw, "\r\n");
        if (record.len == 0) continue;

        const first = std.mem.indexOfScalar(u8, record, 0) orelse continue;
        const second_rel = std.mem.indexOfScalar(u8, record[first + 1 ..], 0) orelse continue;
        const second = first + 1 + second_rel;
        const third_rel = std.mem.indexOfScalar(u8, record[second + 1 ..], 0) orelse continue;
        const third = second + 1 + third_rel;

        const commit = std.mem.trim(u8, record[0..first], " \t\r\n");
        const tree = std.mem.trim(u8, record[first + 1 .. second], " \t\r\n");
        const subject = record[second + 1 .. third];
        const body = std.mem.trim(u8, record[third + 1 ..], " \t\r\n");

        if (commit.len == 0) continue;
        const line = try buildIndexLine(allocator, ref, commit, tree, subject, body, std.mem.eql(u8, tree, empty_tree));
        defer allocator.free(line);
        try index_file.writeAll(line);
        try index_file.writeAll("\n");
        count += 1;
    }

    return count;
}

fn buildIndexLine(
    allocator: Allocator,
    ref: []const u8,
    commit: []const u8,
    tree: []const u8,
    subject: []const u8,
    body: []const u8,
    empty_tree: bool,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const summary = parseEventSummary(allocator, body);
    defer if (summary) |parsed| parsed.deinit();

    try buf.append(allocator, '{');
    try appendJsonFieldString(&buf, allocator, "ref", ref, true);
    try appendJsonFieldString(&buf, allocator, "commit", commit, true);
    try appendJsonFieldString(&buf, allocator, "tree", tree, true);
    try appendJsonFieldString(&buf, allocator, "subject", subject, true);
    try buf.appendSlice(allocator, "\"empty_tree\":");
    try buf.appendSlice(allocator, if (empty_tree) "true," else "false,");
    if (summary) |parsed| {
        try buf.appendSlice(allocator, "\"valid_json\":true,");
        try appendJsonFieldString(&buf, allocator, "event_type", parsed.event_type, true);
        try appendJsonFieldString(&buf, allocator, "object_kind", parsed.object_kind, true);
        try appendJsonFieldString(&buf, allocator, "object_id", parsed.object_id, true);
        try appendJsonFieldString(&buf, allocator, "actor_principal", parsed.actor_principal, true);
        try appendJsonFieldString(&buf, allocator, "actor_device", parsed.actor_device, true);
        if (parsed.seq) |seq| {
            try buf.appendSlice(allocator, "\"seq\":");
            const seq_raw = try std.fmt.allocPrint(allocator, "{d}", .{seq});
            defer allocator.free(seq_raw);
            try buf.appendSlice(allocator, seq_raw);
            try buf.append(allocator, ',');
        }
        try appendJsonFieldString(&buf, allocator, "occurred_at", parsed.occurred_at, false);
    } else {
        try buf.appendSlice(allocator, "\"valid_json\":false");
    }
    try buf.append(allocator, '}');
    return buf.toOwnedSlice(allocator);
}

fn countIndexedEvents(allocator: Allocator, repo: Repo) !usize {
    const bytes = std.fs.cwd().readFileAlloc(allocator, repo.index_path, max_index_bytes) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer allocator.free(bytes);
    return countNonEmptyLines(bytes);
}

fn listEventsFromIndex(
    allocator: Allocator,
    repo: Repo,
    json: bool,
    limit: ?usize,
    one_ref: ?[]const u8,
) !void {
    const bytes = std.fs.cwd().readFileAlloc(allocator, repo.index_path, max_index_bytes) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(bytes);

    var shown: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line_raw| {
        if (limit) |max| {
            if (shown >= max) break;
        }

        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
            if (one_ref == null) {
                if (json) {
                    try out("{s}\n", .{line});
                } else {
                    try out("invalid-index-line\n", .{});
                }
                shown += 1;
            }
            continue;
        };
        defer parsed.deinit();

        const root = switch (parsed.value) {
            .object => |object| object,
            else => continue,
        };
        const ref = jsonString(root.get("ref")) orelse "";
        if (one_ref) |wanted| {
            if (!std.mem.eql(u8, ref, wanted)) continue;
        }

        if (json) {
            try out("{s}\n", .{line});
        } else {
            try printIndexedEvent(root);
        }
        shown += 1;
    }
}

fn printIndexedEvent(root: std.json.ObjectMap) !void {
    const commit = jsonString(root.get("commit")) orelse "";
    const ref = jsonString(root.get("ref")) orelse "";
    const subject = jsonString(root.get("subject")) orelse "";
    const valid_json = jsonBool(root.get("valid_json")) orelse false;
    const short = commit[0..@min(commit.len, 12)];

    if (valid_json) {
        const event_type = jsonString(root.get("event_type")) orelse "";
        const object_id = jsonString(root.get("object_id")) orelse "";
        try out("{s} {s} {s} #{s} {s}\n", .{
            short,
            ref,
            event_type,
            object_id[0..@min(object_id.len, 7)],
            subject,
        });
    } else {
        try out("{s} {s} invalid-event {s}\n", .{ short, ref, subject });
    }
}

fn resolveOptionalRef(allocator: Allocator, ref: []const u8) !?[]u8 {
    var argv = [_][]const u8{ "git", "rev-parse", "--verify", ref };
    var result = try runCommand(allocator, &argv, null, max_git_output);
    defer result.deinit();
    if (result.exitCode() == 0) {
        return try trimDup(allocator, result.stdout);
    }
    return null;
}

fn inboxHeads(allocator: Allocator) ![][]u8 {
    const raw = try gitChecked(allocator, &.{
        "for-each-ref",
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

fn freeStringList(allocator: Allocator, values: [][]u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn emptyTreeOid(allocator: Allocator) ![]u8 {
    const raw = try gitCheckedInput(allocator, &.{
        "hash-object",
        "-w",
        "-t",
        "tree",
        "--stdin",
    }, "");
    return trimOwned(allocator, raw);
}

fn listEventsForRef(
    allocator: Allocator,
    ref: []const u8,
    empty_tree: []const u8,
    json: bool,
    limit: ?usize,
) !void {
    var total: usize = 0;
    try listEventsForRefCounted(allocator, ref, empty_tree, json, limit, &total);
}

fn listEventsForRefCounted(
    allocator: Allocator,
    ref: []const u8,
    empty_tree: []const u8,
    json: bool,
    limit: ?usize,
    total: *usize,
) !void {
    var rev_args: std.ArrayList([]const u8) = .empty;
    defer rev_args.deinit(allocator);
    try rev_args.append(allocator, "rev-list");
    try rev_args.append(allocator, "--first-parent");
    try rev_args.append(allocator, "--reverse");
    if (limit) |max| {
        const max_arg = try std.fmt.allocPrint(allocator, "--max-count={d}", .{max});
        defer allocator.free(max_arg);
        try rev_args.append(allocator, max_arg);
        try rev_args.append(allocator, ref);
        const commits = try gitChecked(allocator, rev_args.items);
        defer allocator.free(commits);
        try printCommitList(allocator, ref, commits, empty_tree, json, total);
    } else {
        try rev_args.append(allocator, ref);
        const commits = try gitChecked(allocator, rev_args.items);
        defer allocator.free(commits);
        try printCommitList(allocator, ref, commits, empty_tree, json, total);
    }
}

fn printCommitList(
    allocator: Allocator,
    ref: []const u8,
    commits: []const u8,
    empty_tree: []const u8,
    json: bool,
    total: *usize,
) !void {
    var it = std.mem.tokenizeScalar(u8, commits, '\n');
    while (it.next()) |commit_raw| {
        const commit = std.mem.trim(u8, commit_raw, " \t\r\n");
        if (commit.len == 0) continue;
        try printOneEvent(allocator, ref, commit, empty_tree, json);
        total.* += 1;
    }
}

fn printOneEvent(
    allocator: Allocator,
    ref: []const u8,
    commit: []const u8,
    empty_tree: []const u8,
    json: bool,
) !void {
    const tree_raw = try gitChecked(allocator, &.{ "show", "-s", "--format=%T", commit });
    defer allocator.free(tree_raw);
    const tree = std.mem.trim(u8, tree_raw, " \t\r\n");

    const subject_raw = try gitChecked(allocator, &.{ "show", "-s", "--format=%s", commit });
    defer allocator.free(subject_raw);
    const subject = std.mem.trim(u8, subject_raw, " \t\r\n");

    const body_raw = try gitChecked(allocator, &.{ "show", "-s", "--format=%b", commit });
    defer allocator.free(body_raw);
    const body = std.mem.trim(u8, body_raw, " \t\r\n");
    const summary = parseEventSummary(allocator, body);
    defer if (summary) |parsed| parsed.deinit();

    const short = commit[0..@min(commit.len, 12)];
    const is_empty_tree = std.mem.eql(u8, tree, empty_tree);

    if (json) {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(allocator);
        try line.append(allocator, '{');
        try appendJsonFieldString(&line, allocator, "commit", commit, true);
        try appendJsonFieldString(&line, allocator, "ref", ref, true);
        try appendJsonFieldString(&line, allocator, "subject", subject, true);
        try line.appendSlice(allocator, "\"empty_tree\":");
        try line.appendSlice(allocator, if (is_empty_tree) "true," else "false,");
        if (summary) |parsed| {
            try line.appendSlice(allocator, "\"valid_json\":true,");
            try appendJsonFieldString(&line, allocator, "event_type", parsed.event_type, true);
            try appendJsonFieldString(&line, allocator, "object_kind", parsed.object_kind, true);
            try appendJsonFieldString(&line, allocator, "object_id", parsed.object_id, true);
            try appendJsonFieldString(&line, allocator, "actor_principal", parsed.actor_principal, true);
            try appendJsonFieldString(&line, allocator, "actor_device", parsed.actor_device, true);
            if (parsed.seq) |seq| {
                try line.appendSlice(allocator, "\"seq\":");
                const seq_raw = try std.fmt.allocPrint(allocator, "{d}", .{seq});
                defer allocator.free(seq_raw);
                try line.appendSlice(allocator, seq_raw);
                try line.append(allocator, ',');
            }
            try appendJsonFieldString(&line, allocator, "occurred_at", parsed.occurred_at, false);
        } else {
            try line.appendSlice(allocator, "\"valid_json\":false");
        }
        try line.append(allocator, '}');
        try out("{s}\n", .{line.items});
    } else if (summary) |parsed| {
        try out("{s} {s} {s} #{s} {s}\n", .{
            short,
            ref,
            parsed.event_type,
            parsed.object_id[0..@min(parsed.object_id.len, 7)],
            subject,
        });
    } else {
        try out("{s} {s} invalid-event {s}\n", .{ short, ref, subject });
    }
}

fn parseEventSummary(allocator: Allocator, body: []const u8) ?EventSummary {
    return parseEventSummaryInner(allocator, body) catch null;
}

fn parseEventSummaryInner(allocator: Allocator, body: []const u8) !EventSummary {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidEventJson,
    };

    var event_type: ?[]u8 = try dupeJsonString(allocator, object.get("event_type"));
    errdefer if (event_type) |value| allocator.free(value);
    var object_kind: ?[]u8 = try allocator.dupe(u8, "");
    errdefer if (object_kind) |value| allocator.free(value);
    var object_id: ?[]u8 = try allocator.dupe(u8, "");
    errdefer if (object_id) |value| allocator.free(value);
    var actor_principal: ?[]u8 = try allocator.dupe(u8, "");
    errdefer if (actor_principal) |value| allocator.free(value);
    var actor_device: ?[]u8 = try allocator.dupe(u8, "");
    errdefer if (actor_device) |value| allocator.free(value);
    var occurred_at: ?[]u8 = try dupeJsonString(allocator, object.get("occurred_at"));
    errdefer if (occurred_at) |value| allocator.free(value);

    var summary = EventSummary{
        .allocator = allocator,
        .event_type = event_type.?,
        .object_kind = object_kind.?,
        .object_id = object_id.?,
        .actor_principal = actor_principal.?,
        .actor_device = actor_device.?,
        .seq = jsonInteger(object.get("seq")),
        .occurred_at = occurred_at.?,
    };
    event_type = null;
    object_kind = null;
    object_id = null;
    actor_principal = null;
    actor_device = null;
    occurred_at = null;
    errdefer summary.deinit();

    if (object.get("object")) |obj_value| {
        if (obj_value == .object) {
            var next_object_kind: ?[]u8 = try dupeJsonString(allocator, obj_value.object.get("kind"));
            errdefer if (next_object_kind) |value| allocator.free(value);
            var next_object_id: ?[]u8 = try dupeJsonString(allocator, obj_value.object.get("id"));
            errdefer if (next_object_id) |value| allocator.free(value);
            allocator.free(summary.object_kind);
            summary.object_kind = next_object_kind.?;
            next_object_kind = null;
            allocator.free(summary.object_id);
            summary.object_id = next_object_id.?;
            next_object_id = null;
        }
    }

    if (object.get("actor")) |actor_value| {
        if (actor_value == .object) {
            var next_actor_principal: ?[]u8 = try dupeJsonString(allocator, actor_value.object.get("principal"));
            errdefer if (next_actor_principal) |value| allocator.free(value);
            var next_actor_device: ?[]u8 = try dupeJsonString(allocator, actor_value.object.get("device"));
            errdefer if (next_actor_device) |value| allocator.free(value);
            allocator.free(summary.actor_principal);
            summary.actor_principal = next_actor_principal.?;
            next_actor_principal = null;
            allocator.free(summary.actor_device);
            summary.actor_device = next_actor_device.?;
            next_actor_device = null;
        }
    }

    return summary;
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    if (value) |v| {
        return switch (v) {
            .string => |s| s,
            else => null,
        };
    }
    return null;
}

fn jsonBool(value: ?std.json.Value) ?bool {
    if (value) |v| {
        return switch (v) {
            .bool => |b| b,
            else => null,
        };
    }
    return null;
}

fn dupeJsonString(allocator: Allocator, value: ?std.json.Value) ![]u8 {
    return allocator.dupe(u8, jsonString(value) orelse "");
}

fn jsonInteger(value: ?std.json.Value) ?i64 {
    if (value) |v| {
        return switch (v) {
            .integer => |i| i,
            else => null,
        };
    }
    return null;
}

fn countInboxEvents(allocator: Allocator) !usize {
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

fn printGitConfigValue(allocator: Allocator, key: []const u8, label: []const u8) !void {
    var argv = [_][]const u8{ "git", "config", "--get", key };
    var result = try runCommand(allocator, &argv, null, 512 * 1024);
    defer result.deinit();
    if (result.exitCode() == 0) {
        try out("{s}: {s}\n", .{ label, std.mem.trim(u8, result.stdout, " \t\r\n") });
    } else {
        try out("{s}: unset\n", .{label});
    }
}

fn gitChecked(allocator: Allocator, git_args: []const []const u8) ![]u8 {
    return gitCheckedInput(allocator, git_args, null);
}

fn gitCheckedInput(allocator: Allocator, git_args: []const []const u8, input: ?[]const u8) ![]u8 {
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

fn runCommand(
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

fn defaultPrincipal(allocator: Allocator) ![]u8 {
    if (gitConfigValue(allocator, "user.email")) |value| {
        defer allocator.free(value);
        const sanitized = try sanitizeRefSegment(allocator, value);
        if (sanitized.len != 0) return sanitized;
        allocator.free(sanitized);
    } else |_| {}

    if (gitConfigValue(allocator, "user.name")) |value| {
        defer allocator.free(value);
        const sanitized = try sanitizeRefSegment(allocator, value);
        if (sanitized.len != 0) return sanitized;
        allocator.free(sanitized);
    } else |_| {}

    const id = try newUuidV7(allocator);
    defer allocator.free(id);
    return std.fmt.allocPrint(allocator, "principal-{s}", .{id[0..7]});
}

fn defaultDevice(allocator: Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "HOSTNAME")) |value| {
        defer allocator.free(value);
        const sanitized = try sanitizeRefSegment(allocator, value);
        if (sanitized.len != 0) return sanitized;
        allocator.free(sanitized);
    } else |_| {}

    const id = try newUuidV7(allocator);
    defer allocator.free(id);
    return std.fmt.allocPrint(allocator, "device-{s}", .{id[0..7]});
}

fn gitConfigValue(allocator: Allocator, key: []const u8) ![]u8 {
    var argv = [_][]const u8{ "git", "config", "--get", key };
    var result = try runCommand(allocator, &argv, null, 512 * 1024);
    defer result.deinit();
    if (result.exitCode() != 0) return CliError.GitFailed;
    return trimDup(allocator, result.stdout);
}

fn checkedRefSegment(allocator: Allocator, raw: []const u8, label: []const u8) ![]u8 {
    if (!isRefSafeSegment(raw)) {
        try eprint("gt init: {s} must be a ref-safe segment using letters, digits, '.', '_' or '-'\n", .{label});
        return CliError.UserError;
    }
    return allocator.dupe(u8, raw);
}

fn sanitizeRefSegment(allocator: Allocator, raw: []const u8) ![]u8 {
    var out_buf: std.ArrayList(u8) = .empty;
    errdefer out_buf.deinit(allocator);

    var last_dash = false;
    for (raw) |c| {
        const lower = std.ascii.toLower(c);
        const keep = (lower >= 'a' and lower <= 'z') or (lower >= '0' and lower <= '9') or lower == '_' or lower == '.';
        if (keep) {
            try out_buf.append(allocator, lower);
            last_dash = false;
        } else if (!last_dash) {
            try out_buf.append(allocator, '-');
            last_dash = true;
        }
    }

    while (out_buf.items.len > 0 and (out_buf.items[0] == '-' or out_buf.items[0] == '.')) {
        _ = out_buf.orderedRemove(0);
    }
    while (out_buf.items.len > 0 and (out_buf.items[out_buf.items.len - 1] == '-' or out_buf.items[out_buf.items.len - 1] == '.')) {
        out_buf.items.len -= 1;
    }

    if (!isRefSafeSegment(out_buf.items)) {
        out_buf.clearRetainingCapacity();
    }

    return out_buf.toOwnedSlice(allocator);
}

fn isRefSafeSegment(value: []const u8) bool {
    if (value.len == 0) return false;
    if (std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, "..")) return false;
    if (std.mem.endsWith(u8, value, ".lock")) return false;
    if (std.mem.indexOf(u8, value, "..") != null) return false;
    for (value) |c| {
        const ok = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_' or c == '-' or c == '.';
        if (!ok) return false;
    }
    return true;
}

fn looksLikeUuid(value: []const u8) bool {
    if (value.len != 36) return false;
    for (value, 0..) |c, idx| {
        if (idx == 8 or idx == 13 or idx == 18 or idx == 23) {
            if (c != '-') return false;
        } else if (!std.ascii.isHex(c)) {
            return false;
        }
    }
    return true;
}

fn newUuidV7(allocator: Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);

    const ts = @as(u64, @intCast(std.time.milliTimestamp()));
    bytes[0] = @as(u8, @intCast((ts >> 40) & 0xff));
    bytes[1] = @as(u8, @intCast((ts >> 32) & 0xff));
    bytes[2] = @as(u8, @intCast((ts >> 24) & 0xff));
    bytes[3] = @as(u8, @intCast((ts >> 16) & 0xff));
    bytes[4] = @as(u8, @intCast((ts >> 8) & 0xff));
    bytes[5] = @as(u8, @intCast(ts & 0xff));
    bytes[6] = (bytes[6] & 0x0f) | 0x70;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    const out_buf = try allocator.alloc(u8, 36);
    formatUuid(bytes, out_buf);
    return out_buf;
}

fn formatUuid(bytes: [16]u8, out_buf: []u8) void {
    const hex = "0123456789abcdef";
    var j: usize = 0;
    for (bytes, 0..) |b, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out_buf[j] = '-';
            j += 1;
        }
        out_buf[j] = hex[b >> 4];
        out_buf[j + 1] = hex[b & 0x0f];
        j += 2;
    }
}

fn rfc3339Now(allocator: Allocator) ![]u8 {
    const timestamp = std.time.timestamp();
    if (timestamp < 0) return error.InvalidTimestamp;

    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @as(u64, @intCast(timestamp)) };
    const day = epoch_seconds.getEpochDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{
            year_day.year,
            @intFromEnum(month_day.month),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    );
}

fn requireValue(args: []const []const u8, index: *usize, name: []const u8) ![]const u8 {
    if (index.* + 1 >= args.len) {
        try eprint("{s} requires a value\n", .{name});
        return CliError.UserError;
    }
    index.* += 1;
    return args[index.*];
}

fn countNonEmptyLines(bytes: []const u8) usize {
    var count: usize = 0;
    var it = std.mem.tokenizeScalar(u8, bytes, '\n');
    while (it.next()) |_| count += 1;
    return count;
}

fn trimOwned(allocator: Allocator, owned: []u8) ![]u8 {
    const duped = try trimDup(allocator, owned);
    allocator.free(owned);
    return duped;
}

fn trimDup(allocator: Allocator, bytes: []const u8) ![]u8 {
    return allocator.dupe(u8, std.mem.trim(u8, bytes, " \t\r\n"));
}

fn fileExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn out(comptime fmt: []const u8, args: anytype) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(fmt, args);
    try stdout.flush();
}

fn eprint(comptime fmt: []const u8, args: anytype) !void {
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;
    try stderr.print(fmt, args);
    try stderr.flush();
}

test "uuid formatter emits canonical lowercase form" {
    const bytes = [16]u8{
        0x01, 0x23, 0x45, 0x67,
        0x89, 0xab, 0xcd, 0xef,
        0x10, 0x32, 0x54, 0x76,
        0x98, 0xba, 0xdc, 0xfe,
    };
    var out_buf: [36]u8 = undefined;
    formatUuid(bytes, &out_buf);
    try std.testing.expectEqualStrings("01234567-89ab-cdef-1032-547698badcfe", &out_buf);
}

test "config parser accepts minimal config" {
    var cfg = try parseConfig(std.testing.allocator,
        \\repo_id = "018f0000-0000-7000-8000-000000000001"
        \\principal = "alice"
        \\device = "laptop"
        \\seq = 42
        \\
    );
    defer cfg.deinit();
    try std.testing.expectEqualStrings("018f0000-0000-7000-8000-000000000001", cfg.repo_id);
    try std.testing.expectEqualStrings("alice", cfg.principal);
    try std.testing.expectEqualStrings("laptop", cfg.device);
    try std.testing.expectEqual(@as(u64, 42), cfg.seq);
}

test "json string escaping handles control characters" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendJsonString(&buf, std.testing.allocator, "a\n\"b\\");
    try std.testing.expectEqualStrings("\"a\\n\\\"b\\\\\"", buf.items);
}

test "issue opened event json contains required envelope fields" {
    var cfg = Config{
        .allocator = std.testing.allocator,
        .repo_id = try std.testing.allocator.dupe(u8, "018f0000-0000-7000-8000-000000000001"),
        .principal = try std.testing.allocator.dupe(u8, "alice"),
        .device = try std.testing.allocator.dupe(u8, "laptop"),
        .seq = 0,
    };
    defer cfg.deinit();

    const labels = [_][]const u8{"bug"};
    const assignees = [_][]const u8{"alice"};
    const body = try buildIssueOpenedJson(
        std.testing.allocator,
        cfg,
        1,
        "018f0000-0000-7000-8000-000000000002",
        "018f0000-0000-7000-8000-000000000003",
        "018f0000-0000-7000-8000-000000000004",
        "2026-05-13T18:30:59Z",
        "Smoke",
        "Body",
        &labels,
        &assignees,
    );
    defer std.testing.allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings(event_schema, root.get("$schema").?.string);
    try std.testing.expectEqualStrings("issue.opened", root.get("event_type").?.string);
    try std.testing.expectEqual(@as(i64, 1), root.get("seq").?.integer);
    try std.testing.expectEqualStrings("issue", root.get("object").?.object.get("kind").?.string);
    try std.testing.expectEqualStrings("Smoke", root.get("payload").?.object.get("title").?.string);
}

test "issue opened event json passes envelope validation" {
    var cfg = Config{
        .allocator = std.testing.allocator,
        .repo_id = try std.testing.allocator.dupe(u8, "018f0000-0000-7000-8000-000000000001"),
        .principal = try std.testing.allocator.dupe(u8, "alice"),
        .device = try std.testing.allocator.dupe(u8, "laptop"),
        .seq = 0,
    };
    defer cfg.deinit();

    const body = try buildIssueOpenedJson(
        std.testing.allocator,
        cfg,
        1,
        "018f0000-0000-7000-8000-000000000002",
        "018f0000-0000-7000-8000-000000000003",
        "018f0000-0000-7000-8000-000000000004",
        "2026-05-13T18:30:59Z",
        "Smoke",
        "",
        &.{},
        &.{},
    );
    defer std.testing.allocator.free(body);

    try validateEventEnvelope(std.testing.allocator, "test-commit", body);
}

test "index line carries event projection fields" {
    var cfg = Config{
        .allocator = std.testing.allocator,
        .repo_id = try std.testing.allocator.dupe(u8, "018f0000-0000-7000-8000-000000000001"),
        .principal = try std.testing.allocator.dupe(u8, "alice"),
        .device = try std.testing.allocator.dupe(u8, "laptop"),
        .seq = 0,
    };
    defer cfg.deinit();

    const body = try buildIssueOpenedJson(
        std.testing.allocator,
        cfg,
        7,
        "018f0000-0000-7000-8000-000000000002",
        "018f0000-0000-7000-8000-000000000003",
        "018f0000-0000-7000-8000-000000000004",
        "2026-05-13T18:30:59Z",
        "Indexed",
        "",
        &.{},
        &.{},
    );
    defer std.testing.allocator.free(body);

    const line = try buildIndexLine(
        std.testing.allocator,
        "refs/gitomi/inbox/alice/laptop",
        "0123456789abcdef0123456789abcdef01234567",
        "4b825dc642cb6eb9a060e54bf8d69288fbee4904",
        "issue.opened #018f000 Indexed",
        body,
        true,
    );
    defer std.testing.allocator.free(line);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("refs/gitomi/inbox/alice/laptop", root.get("ref").?.string);
    try std.testing.expectEqual(true, root.get("empty_tree").?.bool);
    try std.testing.expectEqual(true, root.get("valid_json").?.bool);
    try std.testing.expectEqualStrings("issue.opened", root.get("event_type").?.string);
    try std.testing.expectEqual(@as(i64, 7), root.get("seq").?.integer);
}

test "staged refs map back to authoritative inbox refs" {
    const local_ref = try localRefFromStaged(
        std.testing.allocator,
        "refs/gitomi/staging/origin",
        "refs/gitomi/staging/origin/inbox/alice/laptop",
    );
    defer std.testing.allocator.free(local_ref);
    try std.testing.expectEqualStrings("refs/gitomi/inbox/alice/laptop", local_ref);
}

test "ref segment sanitization" {
    const sanitized = try sanitizeRefSegment(std.testing.allocator, "Dev User@example.com");
    defer std.testing.allocator.free(sanitized);
    try std.testing.expectEqualStrings("dev-user-example.com", sanitized);
    try std.testing.expect(isRefSafeSegment(sanitized));
    try std.testing.expect(!isRefSafeSegment("../bad"));
}
