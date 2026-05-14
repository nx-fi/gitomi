const std = @import("std");
const actions = @import("actions.zig");
const comment = @import("comment.zig");
const errors = @import("errors.zig");
const event_mod = @import("event.zig");
const fsck = @import("fsck.zig");
const git = @import("git.zig");
const github = @import("github.zig");
const index = @import("index.zig");
const io = @import("io.zig");
const issue = @import("issue.zig");
const pull_mod = @import("pull.zig");
const rbac = @import("rbac.zig");
const repo_mod = @import("repo.zig");
const runs = @import("runs.zig");
const sync = @import("sync.zig");
const util = @import("util.zig");
const web = @import("web.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;

pub fn main() void {
    realMain() catch |err| {
        if (!errors.isReported(err)) {
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
    } else if (std.mem.eql(u8, cmd, "pr") or std.mem.eql(u8, cmd, "pull")) {
        try cmdPr(allocator, args[2..], if (std.mem.eql(u8, cmd, "pull")) "gt pull" else "gt pr");
    } else if (std.mem.eql(u8, cmd, "comment")) {
        try cmdComment(allocator, args[2..]);
    } else if (std.mem.eql(u8, cmd, "acl")) {
        try cmdAcl(allocator, args[2..]);
    } else if (std.mem.eql(u8, cmd, "identity")) {
        try cmdIdentity(allocator, args[2..]);
    } else if (std.mem.eql(u8, cmd, "actions") or std.mem.eql(u8, cmd, "action")) {
        try cmdActions(allocator, args[2..], if (std.mem.eql(u8, cmd, "action")) "gt action" else "gt actions");
    } else if (std.mem.eql(u8, cmd, "runs")) {
        try cmdRuns(allocator, args[2..]);
    } else if (std.mem.eql(u8, cmd, "sync")) {
        try cmdSync(allocator, args[2..]);
    } else if (std.mem.eql(u8, cmd, "github")) {
        try github.cmdGithub(allocator, args[2..]);
    } else if (std.mem.eql(u8, cmd, "web")) {
        try cmdWeb(allocator, args[2..]);
    } else {
        try io.eprint("gt: unknown command '{s}'\n\n", .{cmd});
        try printUsage();
        return CliError.InvalidArgument;
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
        \\  gt issue show ISSUE [--json]
        \\  gt issue open --title TITLE [--body BODY] [--label LABEL] [--assignee PRINCIPAL]
        \\  gt issue edit ISSUE [--title TITLE] [--body BODY] [--state open|closed] [--label LABEL] [--unlabel LABEL] [--assignee PRINCIPAL] [--unassign PRINCIPAL]
        \\  gt issue title ISSUE --title TITLE
        \\  gt issue body ISSUE --body BODY
        \\  gt issue close|reopen ISSUE
        \\  gt issue label ISSUE add|remove LABEL
        \\  gt issue assignee ISSUE add|remove PRINCIPAL
        \\  gt pr list [--json]
        \\  gt pr view PR [--json]
        \\  gt pr create --title TITLE --base BASE --head HEAD [--body BODY] [--draft]
        \\  gt pr edit PR [--title TITLE] [--body BODY] [--state open|closed] [--base BASE] [--head HEAD] [--add-label LABEL] [--remove-label LABEL] [--add-assignee PRINCIPAL] [--remove-assignee PRINCIPAL] [--add-reviewer PRINCIPAL] [--remove-reviewer PRINCIPAL]
        \\  gt pr title PR --title TITLE
        \\  gt pr body PR --body BODY
        \\  gt pr close|reopen PR
        \\  gt pr base PR --base BASE
        \\  gt pr head PR --head HEAD
        \\  gt pr label PR add|remove LABEL
        \\  gt pr assignee PR add|remove PRINCIPAL
        \\  gt pr reviewer PR add|remove PRINCIPAL
        \\  gt pr comment PR --body BODY
        \\  gt pr merge PR [--merge-oid OID] [--target-oid OID]
        \\  gt comment list issue|pr OBJECT [--json]
        \\  gt comment add issue|pr OBJECT --body BODY
        \\  gt comment edit COMMENT --body BODY
        \\  gt comment redact COMMENT [--reason REASON]
        \\  gt acl grant PRINCIPAL ROLE
        \\  gt acl revoke PRINCIPAL
        \\  gt acl list [--json]
        \\  gt identity add-device PRINCIPAL DEVICE [--public-key KEY] [--fingerprint FP] [--scheme ssh|openpgp]
        \\  gt identity revoke-device PRINCIPAL DEVICE
        \\  gt identity list [--json]
        \\  gt actions workflows [--json] [--ref REF|--oid OID]
        \\  gt actions request --workflow WORKFLOW [--ref REF|--oid OID] [--event EVENT]
        \\  gt actions complete RUN --conclusion CONCLUSION [--workflow WORKFLOW] [--ref REF|--oid OID] [--event EVENT]
        \\  gt actions run --event EVENT [--ref REF|--oid OID] [--object-id ID] [--dry-run] [--act PATH] [-- ACT_ARGS...]
        \\  gt actions run-requested [RUN] [--dry-run] [--act PATH] [-- ACT_ARGS...]
        \\  gt runs prune [--dry-run] [--max-age-days N] [--max-count N] [--max-bytes N]
        \\  gt sync [--remote REMOTE] [--pull-only|--push-only]
        \\  gt github import [--repo OWNER/REPO] [--token TOKEN] [--from-file PATH] [--no-comments]
        \\  gt github export --repo OWNER/REPO [--token TOKEN] [--dry-run] [--map-file PATH] [--reuse-legacy]
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

    var signing_key = try repo_mod.configuredSigningKey(allocator);
    defer signing_key.deinit();
    if (std.mem.trim(u8, signing_key.public_key, " \t\r\n").len == 0) {
        try io.eprint("gt init: signing public key is required; configure Git signing with user.signingkey\n", .{});
        return CliError.MissingArgument;
    }
    const genesis_manifest = try repo_mod.buildGenesisManifestJson(allocator, cfg, signing_key.public_key, signing_key.fingerprint, signing_key.scheme);
    defer allocator.free(genesis_manifest);

    try repo_mod.writeConfig(repo.config_path, cfg);
    const genesis_oid = try repo_mod.writeGenesisRef(allocator, genesis_manifest, force);
    defer allocator.free(genesis_oid);

    try io.out("initialized Gitomi repository\n", .{});
    try io.out("  repo:      {s}\n", .{repo.root});
    try io.out("  config:    {s}\n", .{repo.config_path});
    try io.out("  repo_id:   {s}\n", .{cfg.repo_id});
    try io.out("  actor:     {s}/{s}\n", .{ cfg.principal, cfg.device });
    try io.out("  genesis:   {s}\n", .{genesis_oid});
    const ref = try repo_mod.inboxRef(allocator, cfg);
    defer allocator.free(ref);
    try io.out("  inbox ref: {s}\n", .{ref});
}

fn cmdStatus(allocator: Allocator) !void {
    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();

    var cfg = repo_mod.loadConfigForWrite(allocator, repo) catch |err| switch (err) {
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
    const genesis_oid = try git.resolveOptionalRef(allocator, repo_mod.genesis_ref);
    defer if (genesis_oid) |oid| allocator.free(oid);

    try index.ensureIndex(allocator, repo);
    const event_count = try index.countIndexedEvents(allocator, repo);

    try io.out("repository: {s}\n", .{repo.root});
    try io.out("git_dir:    {s}\n", .{repo.git_dir});
    try io.out("repo_id:    {s}\n", .{cfg.repo_id});
    try io.out("actor:      {s}/{s}\n", .{ cfg.principal, cfg.device });
    try io.out("seq:        {d}\n", .{cfg.seq});
    try io.out("inbox_ref:  {s}\n", .{inbox_ref});
    try io.out("genesis:    {s}\n", .{if (genesis_oid) |oid| oid else "missing"});
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

    const genesis_oid = try git.resolveOptionalRef(allocator, repo_mod.genesis_ref);
    defer if (genesis_oid) |oid| allocator.free(oid);
    if (genesis_oid) |oid| {
        sync.verifyCommitSignature(allocator, oid) catch try checker.fail("{s}: signature verification failed", .{repo_mod.genesis_ref});
        repo_mod.validateGenesisManifest(allocator, oid) catch try checker.fail("{s}: invalid genesis manifest", .{repo_mod.genesis_ref});
    } else {
        try checker.fail("{s}: missing genesis ref", .{repo_mod.genesis_ref});
    }

    const refs = try git.listRefs(allocator, "refs/gitomi/inbox");
    defer git.freeStringList(allocator, refs);
    if (refs.len > git.max_default_inbox_refs) {
        try checker.fail("refs/gitomi/inbox: {d} inbox refs exceeds v1 default limit {d}", .{ refs.len, git.max_default_inbox_refs });
    }

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
        try io.eprint("gt issue: expected subcommand 'list', 'show', 'open', or an issue update command\n", .{});
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

    if (std.mem.eql(u8, args[0], "show")) {
        if (args.len < 2) {
            try io.eprint("gt issue show: ISSUE is required\n", .{});
            return CliError.UserError;
        }
        var json = false;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--json")) {
                json = true;
            } else {
                try io.eprint("gt issue show: unknown option '{s}'\n", .{arg});
                return CliError.UserError;
            }
        }

        var repo = try repo_mod.discoverRepo(allocator);
        defer repo.deinit();
        try index.ensureIndex(allocator, repo);
        const issue_id = try index.resolveIssueId(allocator, repo, args[1]);
        defer allocator.free(issue_id);
        try index.showIssueFromIndex(allocator, repo, issue_id, json);
        return;
    }

    if (std.mem.eql(u8, args[0], "edit")) {
        if (args.len < 2) {
            try io.eprint("gt issue edit: ISSUE is required\n", .{});
            return CliError.UserError;
        }

        var update = event_mod.IssueUpdate{};
        var labels_added: std.ArrayList([]const u8) = .empty;
        defer labels_added.deinit(allocator);
        var labels_removed: std.ArrayList([]const u8) = .empty;
        defer labels_removed.deinit(allocator);
        var assignees_added: std.ArrayList([]const u8) = .empty;
        defer assignees_added.deinit(allocator);
        var assignees_removed: std.ArrayList([]const u8) = .empty;
        defer assignees_removed.deinit(allocator);

        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--title")) {
                update.title = try util.requireValue(args, &i, "--title");
            } else if (std.mem.eql(u8, arg, "--body")) {
                update.body = try util.requireValue(args, &i, "--body");
            } else if (std.mem.eql(u8, arg, "--state")) {
                const state = try util.requireValue(args, &i, "--state");
                if (!isIssueState(state)) {
                    try io.eprint("gt issue edit: --state must be open or closed\n", .{});
                    return CliError.UserError;
                }
                update.state = state;
            } else if (std.mem.eql(u8, arg, "--label")) {
                const value = try util.requireValue(args, &i, "--label");
                try requireNonEmptyOption("gt issue edit", "--label", value);
                try labels_added.append(allocator, value);
            } else if (std.mem.eql(u8, arg, "--unlabel")) {
                const value = try util.requireValue(args, &i, "--unlabel");
                try requireNonEmptyOption("gt issue edit", "--unlabel", value);
                try labels_removed.append(allocator, value);
            } else if (std.mem.eql(u8, arg, "--assignee")) {
                const value = try util.requireValue(args, &i, "--assignee");
                try requireNonEmptyOption("gt issue edit", "--assignee", value);
                try assignees_added.append(allocator, value);
            } else if (std.mem.eql(u8, arg, "--unassign")) {
                const value = try util.requireValue(args, &i, "--unassign");
                try requireNonEmptyOption("gt issue edit", "--unassign", value);
                try assignees_removed.append(allocator, value);
            } else {
                try io.eprint("gt issue edit: unknown option '{s}'\n", .{arg});
                return CliError.UserError;
            }
        }

        update.labels_added = labels_added.items;
        update.labels_removed = labels_removed.items;
        update.assignees_added = assignees_added.items;
        update.assignees_removed = assignees_removed.items;
        if (!update.hasChanges()) {
            try io.eprint("gt issue edit: at least one update option is required\n", .{});
            return CliError.UserError;
        }
        if (update.title) |title| {
            try requireNonEmptyOption("gt issue edit", "--title", title);
        }

        const issue_id = try resolveIssueIdForCommand(allocator, args[1]);
        defer allocator.free(issue_id);
        try issue.createIssueUpdatedEvent(allocator, issue_id, update);
        return;
    }

    if (std.mem.eql(u8, args[0], "title") or std.mem.eql(u8, args[0], "body")) {
        const payload_key: []const u8 = if (std.mem.eql(u8, args[0], "title")) "title" else "body";
        const event_type: []const u8 = if (std.mem.eql(u8, args[0], "title")) "issue.title_set" else "issue.body_set";
        const option_name: []const u8 = if (std.mem.eql(u8, args[0], "title")) "--title" else "--body";
        if (args.len < 2) {
            try io.eprint("gt issue {s}: ISSUE is required\n", .{args[0]});
            return CliError.UserError;
        }
        var value: ?[]const u8 = null;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, option_name)) {
                value = try util.requireValue(args, &i, option_name);
            } else {
                try io.eprint("gt issue {s}: unknown option '{s}'\n", .{ args[0], arg });
                return CliError.UserError;
            }
        }
        if (value == null or std.mem.trim(u8, value.?, " \t\r\n").len == 0) {
            try io.eprint("gt issue {s}: {s} is required\n", .{ args[0], option_name });
            return CliError.UserError;
        }
        const issue_id = try resolveIssueIdForCommand(allocator, args[1]);
        defer allocator.free(issue_id);
        try issue.createIssueStringEvent(allocator, issue_id, event_type, payload_key, value.?);
        return;
    }

    if (std.mem.eql(u8, args[0], "close") or std.mem.eql(u8, args[0], "reopen")) {
        if (args.len != 2) {
            try io.eprint("gt issue {s}: expected ISSUE\n", .{args[0]});
            return CliError.UserError;
        }
        const issue_id = try resolveIssueIdForCommand(allocator, args[1]);
        defer allocator.free(issue_id);
        const state: []const u8 = if (std.mem.eql(u8, args[0], "close")) "closed" else "open";
        try issue.createIssueStringEvent(allocator, issue_id, "issue.state_set", "state", state);
        return;
    }

    if (std.mem.eql(u8, args[0], "label") or std.mem.eql(u8, args[0], "assignee")) {
        if (args.len != 4) {
            try io.eprint("gt issue {s}: expected ISSUE add|remove VALUE\n", .{args[0]});
            return CliError.UserError;
        }
        const collection = args[0];
        const parsed = try parseCollectionMutation("gt issue", collection, args[1], args[2]);
        const object_ref = parsed.object_ref;
        const op = parsed.op;
        if (!std.mem.eql(u8, op, "add") and !std.mem.eql(u8, op, "remove")) {
            try io.eprint("gt issue {s}: expected add or remove\n", .{collection});
            return CliError.UserError;
        }
        if (std.mem.trim(u8, args[3], " \t\r\n").len == 0) {
            try io.eprint("gt issue {s}: value must not be empty\n", .{collection});
            return CliError.UserError;
        }
        const issue_id = try resolveIssueIdForCommand(allocator, object_ref);
        defer allocator.free(issue_id);
        const event_type = try std.fmt.allocPrint(allocator, "issue.{s}_{s}", .{ collection, if (std.mem.eql(u8, op, "add")) "added" else "removed" });
        defer allocator.free(event_type);
        const payload_key: []const u8 = if (std.mem.eql(u8, collection, "label")) "label" else "assignee";
        try issue.createIssueStringEvent(allocator, issue_id, event_type, payload_key, args[3]);
        return;
    }

    if (!std.mem.eql(u8, args[0], "open")) {
        try io.eprint("gt issue: expected subcommand 'list', 'show', 'open', or an issue update command\n", .{});
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

fn resolveIssueIdForCommand(allocator: Allocator, raw_ref: []const u8) ![]u8 {
    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();
    try index.ensureIndex(allocator, repo);
    return try index.resolveIssueId(allocator, repo, raw_ref);
}

fn resolvePullIdForCommand(allocator: Allocator, raw_ref: []const u8) ![]u8 {
    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();
    try index.ensureIndex(allocator, repo);
    return try index.resolvePullId(allocator, repo, raw_ref);
}

fn resolveCommentIdForCommand(allocator: Allocator, raw_ref: []const u8) ![]u8 {
    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();
    try index.ensureIndex(allocator, repo);
    return try index.resolveCommentId(allocator, repo, raw_ref);
}

fn requireNonEmptyOption(context: []const u8, option: []const u8, value: []const u8) !void {
    if (std.mem.trim(u8, value, " \t\r\n").len != 0) return;
    try io.eprint("{s}: {s} must not be empty\n", .{ context, option });
    return CliError.UserError;
}

fn appendCollectionOptionValues(
    allocator: Allocator,
    list: *std.ArrayList([]const u8),
    context: []const u8,
    option: []const u8,
    value: []const u8,
) !void {
    var fields = try util.splitCommaFields(allocator, value);
    defer fields.deinit(allocator);
    if (fields.items.len == 0) {
        try io.eprint("{s}: {s} must not be empty\n", .{ context, option });
        return CliError.UserError;
    }
    for (fields.items) |field| try list.append(allocator, field);
}

const CollectionMutation = struct {
    object_ref: []const u8,
    op: []const u8,
};

fn parseCollectionMutation(context: []const u8, collection: []const u8, first: []const u8, second: []const u8) !CollectionMutation {
    if (std.mem.eql(u8, second, "add") or std.mem.eql(u8, second, "remove")) {
        return .{ .object_ref = first, .op = second };
    }
    if (std.mem.eql(u8, first, "add") or std.mem.eql(u8, first, "remove")) {
        return .{ .object_ref = second, .op = first };
    }
    try io.eprint("{s} {s}: expected add or remove\n", .{ context, collection });
    return CliError.UserError;
}

fn isIssueState(value: []const u8) bool {
    return std.mem.eql(u8, value, "open") or std.mem.eql(u8, value, "closed");
}

fn cmdPr(allocator: Allocator, args: []const []const u8, command_context: []const u8) !void {
    if (args.len == 0) {
        try io.eprint("{s}: expected subcommand 'list', 'view', 'create', or a PR update command\n", .{command_context});
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
                try io.eprint("{s} list: unknown option '{s}'\n", .{ command_context, arg });
                return CliError.UserError;
            }
        }

        var repo = try repo_mod.discoverRepo(allocator);
        defer repo.deinit();
        try index.ensureIndex(allocator, repo);
        try index.listPullsFromIndex(allocator, repo, json);
        return;
    }

    if (std.mem.eql(u8, args[0], "view") or std.mem.eql(u8, args[0], "show")) {
        if (args.len < 2) {
            try io.eprint("{s} {s}: PR is required\n", .{ command_context, args[0] });
            return CliError.UserError;
        }
        var json = false;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--json")) {
                json = true;
            } else {
                try io.eprint("{s} {s}: unknown option '{s}'\n", .{ command_context, args[0], arg });
                return CliError.UserError;
            }
        }

        var repo = try repo_mod.discoverRepo(allocator);
        defer repo.deinit();
        try index.ensureIndex(allocator, repo);
        const pull_id = try index.resolvePullId(allocator, repo, args[1]);
        defer allocator.free(pull_id);
        try index.showPullFromIndex(allocator, repo, pull_id, json);
        return;
    }

    if (std.mem.eql(u8, args[0], "edit")) {
        if (args.len < 2) {
            try io.eprint("{s} edit: PR is required\n", .{command_context});
            return CliError.UserError;
        }

        var update = event_mod.PullUpdate{};
        var labels_added: std.ArrayList([]const u8) = .empty;
        defer labels_added.deinit(allocator);
        var labels_removed: std.ArrayList([]const u8) = .empty;
        defer labels_removed.deinit(allocator);
        var assignees_added: std.ArrayList([]const u8) = .empty;
        defer assignees_added.deinit(allocator);
        var assignees_removed: std.ArrayList([]const u8) = .empty;
        defer assignees_removed.deinit(allocator);
        var reviewers_added: std.ArrayList([]const u8) = .empty;
        defer reviewers_added.deinit(allocator);
        var reviewers_removed: std.ArrayList([]const u8) = .empty;
        defer reviewers_removed.deinit(allocator);

        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--title") or std.mem.eql(u8, arg, "-t")) {
                update.title = try util.requireValue(args, &i, "--title");
            } else if (std.mem.eql(u8, arg, "--body") or std.mem.eql(u8, arg, "-b")) {
                update.body = try util.requireValue(args, &i, "--body");
            } else if (std.mem.eql(u8, arg, "--state")) {
                const state = try util.requireValue(args, &i, "--state");
                if (!isIssueState(state)) {
                    try io.eprint("{s} edit: --state must be open or closed\n", .{command_context});
                    return CliError.UserError;
                }
                update.state = state;
            } else if (std.mem.eql(u8, arg, "--base") or std.mem.eql(u8, arg, "-B")) {
                update.base_ref = try util.requireValue(args, &i, "--base");
            } else if (std.mem.eql(u8, arg, "--head")) {
                update.head_ref = try util.requireValue(args, &i, "--head");
            } else if (std.mem.eql(u8, arg, "--label") or std.mem.eql(u8, arg, "--add-label")) {
                const value = try util.requireValue(args, &i, arg);
                try appendCollectionOptionValues(allocator, &labels_added, command_context, arg, value);
            } else if (std.mem.eql(u8, arg, "--unlabel") or std.mem.eql(u8, arg, "--remove-label")) {
                const value = try util.requireValue(args, &i, arg);
                try appendCollectionOptionValues(allocator, &labels_removed, command_context, arg, value);
            } else if (std.mem.eql(u8, arg, "--assignee") or std.mem.eql(u8, arg, "--add-assignee")) {
                const value = try util.requireValue(args, &i, arg);
                try appendCollectionOptionValues(allocator, &assignees_added, command_context, arg, value);
            } else if (std.mem.eql(u8, arg, "--unassign") or std.mem.eql(u8, arg, "--remove-assignee")) {
                const value = try util.requireValue(args, &i, arg);
                try appendCollectionOptionValues(allocator, &assignees_removed, command_context, arg, value);
            } else if (std.mem.eql(u8, arg, "--reviewer") or std.mem.eql(u8, arg, "--add-reviewer")) {
                const value = try util.requireValue(args, &i, arg);
                try appendCollectionOptionValues(allocator, &reviewers_added, command_context, arg, value);
            } else if (std.mem.eql(u8, arg, "--unreviewer") or std.mem.eql(u8, arg, "--remove-reviewer")) {
                const value = try util.requireValue(args, &i, arg);
                try appendCollectionOptionValues(allocator, &reviewers_removed, command_context, arg, value);
            } else {
                try io.eprint("{s} edit: unknown option '{s}'\n", .{ command_context, arg });
                return CliError.UserError;
            }
        }

        update.labels_added = labels_added.items;
        update.labels_removed = labels_removed.items;
        update.assignees_added = assignees_added.items;
        update.assignees_removed = assignees_removed.items;
        update.reviewers_added = reviewers_added.items;
        update.reviewers_removed = reviewers_removed.items;
        if (!update.hasChanges()) {
            try io.eprint("{s} edit: at least one update option is required\n", .{command_context});
            return CliError.UserError;
        }
        if (update.title) |title| try requireNonEmptyOption(command_context, "--title", title);
        if (update.base_ref) |base_ref| try requireNonEmptyOption(command_context, "--base", base_ref);
        if (update.head_ref) |head_ref| try requireNonEmptyOption(command_context, "--head", head_ref);

        const pull_id = try resolvePullIdForCommand(allocator, args[1]);
        defer allocator.free(pull_id);
        try pull_mod.createPullUpdatedEvent(allocator, pull_id, update);
        return;
    }

    if (std.mem.eql(u8, args[0], "title") or
        std.mem.eql(u8, args[0], "body") or
        std.mem.eql(u8, args[0], "base") or
        std.mem.eql(u8, args[0], "head"))
    {
        const payload_key: []const u8 = if (std.mem.eql(u8, args[0], "title"))
            "title"
        else if (std.mem.eql(u8, args[0], "body"))
            "body"
        else if (std.mem.eql(u8, args[0], "base"))
            "base_ref"
        else
            "head_ref";
        const event_type: []const u8 = if (std.mem.eql(u8, args[0], "title"))
            "pull.title_set"
        else if (std.mem.eql(u8, args[0], "body"))
            "pull.body_set"
        else if (std.mem.eql(u8, args[0], "base"))
            "pull.base_set"
        else
            "pull.head_set";
        const option_name: []const u8 = if (std.mem.eql(u8, args[0], "title"))
            "--title"
        else if (std.mem.eql(u8, args[0], "body"))
            "--body"
        else if (std.mem.eql(u8, args[0], "base"))
            "--base"
        else
            "--head";
        if (args.len < 2) {
            try io.eprint("{s} {s}: PR is required\n", .{ command_context, args[0] });
            return CliError.UserError;
        }
        var value: ?[]const u8 = null;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, option_name)) {
                value = try util.requireValue(args, &i, option_name);
            } else {
                try io.eprint("{s} {s}: unknown option '{s}'\n", .{ command_context, args[0], arg });
                return CliError.UserError;
            }
        }
        if (value == null or std.mem.trim(u8, value.?, " \t\r\n").len == 0) {
            try io.eprint("{s} {s}: {s} is required\n", .{ command_context, args[0], option_name });
            return CliError.UserError;
        }
        const pull_id = try resolvePullIdForCommand(allocator, args[1]);
        defer allocator.free(pull_id);
        try pull_mod.createPullStringEvent(allocator, pull_id, event_type, payload_key, value.?);
        return;
    }

    if (std.mem.eql(u8, args[0], "close") or std.mem.eql(u8, args[0], "reopen")) {
        if (args.len != 2) {
            try io.eprint("{s} {s}: expected PR\n", .{ command_context, args[0] });
            return CliError.UserError;
        }
        const pull_id = try resolvePullIdForCommand(allocator, args[1]);
        defer allocator.free(pull_id);
        const state: []const u8 = if (std.mem.eql(u8, args[0], "close")) "closed" else "open";
        try pull_mod.createPullStringEvent(allocator, pull_id, "pull.state_set", "state", state);
        return;
    }

    if (std.mem.eql(u8, args[0], "label") or
        std.mem.eql(u8, args[0], "assignee") or
        std.mem.eql(u8, args[0], "reviewer"))
    {
        if (args.len != 4) {
            try io.eprint("{s} {s}: expected PR add|remove VALUE\n", .{ command_context, args[0] });
            return CliError.UserError;
        }
        const collection = args[0];
        const parsed = try parseCollectionMutation(command_context, collection, args[1], args[2]);
        const object_ref = parsed.object_ref;
        const op = parsed.op;
        if (!std.mem.eql(u8, op, "add") and !std.mem.eql(u8, op, "remove")) {
            try io.eprint("{s} {s}: expected add or remove\n", .{ command_context, collection });
            return CliError.UserError;
        }
        if (std.mem.trim(u8, args[3], " \t\r\n").len == 0) {
            try io.eprint("{s} {s}: value must not be empty\n", .{ command_context, collection });
            return CliError.UserError;
        }
        const pull_id = try resolvePullIdForCommand(allocator, object_ref);
        defer allocator.free(pull_id);
        const event_type = try std.fmt.allocPrint(allocator, "pull.{s}_{s}", .{ collection, if (std.mem.eql(u8, op, "add")) "added" else "removed" });
        defer allocator.free(event_type);
        try pull_mod.createPullStringEvent(allocator, pull_id, event_type, collection, args[3]);
        return;
    }

    if (std.mem.eql(u8, args[0], "comment")) {
        if (args.len < 2) {
            try io.eprint("{s} comment: PR is required\n", .{command_context});
            return CliError.UserError;
        }
        var body: ?[]const u8 = null;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--body") or std.mem.eql(u8, args[i], "-b")) {
                body = try util.requireValue(args, &i, "--body");
            } else {
                try io.eprint("{s} comment: unknown option '{s}'\n", .{ command_context, args[i] });
                return CliError.UserError;
            }
        }
        if (body == null or std.mem.trim(u8, body.?, " \t\r\n").len == 0) {
            try io.eprint("{s} comment: --body is required\n", .{command_context});
            return CliError.UserError;
        }
        const pull_id = try resolvePullIdForCommand(allocator, args[1]);
        defer allocator.free(pull_id);
        try comment.createCommentAddedEvent(allocator, "pull", pull_id, body.?);
        return;
    }

    if (std.mem.eql(u8, args[0], "merge")) {
        if (args.len < 2) {
            try io.eprint("{s} merge: PR is required\n", .{command_context});
            return CliError.UserError;
        }
        var merge_oid: ?[]const u8 = null;
        var target_oid: ?[]const u8 = null;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--merge-oid")) {
                merge_oid = try util.requireValue(args, &i, "--merge-oid");
            } else if (std.mem.eql(u8, arg, "--target-oid")) {
                target_oid = try util.requireValue(args, &i, "--target-oid");
            } else {
                try io.eprint("{s} merge: unknown option '{s}'\n", .{ command_context, arg });
                return CliError.UserError;
            }
        }
        if ((merge_oid == null or std.mem.trim(u8, merge_oid.?, " \t\r\n").len == 0) and
            (target_oid == null or std.mem.trim(u8, target_oid.?, " \t\r\n").len == 0))
        {
            try io.eprint("{s} merge: --merge-oid or --target-oid is required\n", .{command_context});
            return CliError.UserError;
        }
        const pull_id = try resolvePullIdForCommand(allocator, args[1]);
        defer allocator.free(pull_id);
        try pull_mod.createPullMergedEvent(allocator, pull_id, merge_oid, target_oid);
        return;
    }

    if (!std.mem.eql(u8, args[0], "create") and !std.mem.eql(u8, args[0], "new") and !std.mem.eql(u8, args[0], "open")) {
        try io.eprint("{s}: expected subcommand 'list', 'view', 'create', or a PR update command\n", .{command_context});
        return CliError.UserError;
    }

    var title: ?[]const u8 = null;
    var body: []const u8 = "";
    var base_ref: ?[]const u8 = null;
    var head_ref: ?[]const u8 = null;
    var draft = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--title") or std.mem.eql(u8, arg, "-t")) {
            title = try util.requireValue(args, &i, "--title");
        } else if (std.mem.eql(u8, arg, "--body") or std.mem.eql(u8, arg, "-b")) {
            body = try util.requireValue(args, &i, "--body");
        } else if (std.mem.eql(u8, arg, "--base") or std.mem.eql(u8, arg, "-B")) {
            base_ref = try util.requireValue(args, &i, "--base");
        } else if (std.mem.eql(u8, arg, "--head") or std.mem.eql(u8, arg, "-H")) {
            head_ref = try util.requireValue(args, &i, "--head");
        } else if (std.mem.eql(u8, arg, "--draft") or std.mem.eql(u8, arg, "-d")) {
            draft = true;
        } else {
            try io.eprint("{s} {s}: unknown option '{s}'\n", .{ command_context, args[0], arg });
            return CliError.UserError;
        }
    }

    if (title == null or std.mem.trim(u8, title.?, " \t\r\n").len == 0) {
        try io.eprint("{s} {s}: --title is required\n", .{ command_context, args[0] });
        return CliError.UserError;
    }
    if (base_ref == null or std.mem.trim(u8, base_ref.?, " \t\r\n").len == 0) {
        try io.eprint("{s} {s}: --base is required\n", .{ command_context, args[0] });
        return CliError.UserError;
    }
    if (head_ref == null or std.mem.trim(u8, head_ref.?, " \t\r\n").len == 0) {
        try io.eprint("{s} {s}: --head is required\n", .{ command_context, args[0] });
        return CliError.UserError;
    }

    try pull_mod.createPullOpenedEvent(allocator, title.?, body, base_ref.?, head_ref.?, draft);
}

fn cmdComment(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try io.eprint("gt comment: expected subcommand 'list', 'add', 'edit', or 'redact'\n", .{});
        return CliError.UserError;
    }

    if (std.mem.eql(u8, args[0], "list")) {
        if (args.len < 3 or (!isCommentParentKind(args[1]))) {
            try io.eprint("gt comment list: expected issue ISSUE or pr PR [--json]\n", .{});
            return CliError.UserError;
        }
        const parent_kind = canonicalCommentParentKind(args[1]);
        var json = false;
        var i: usize = 3;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--json")) {
                json = true;
            } else {
                try io.eprint("gt comment list: unknown option '{s}'\n", .{args[i]});
                return CliError.UserError;
            }
        }
        const parent_id = if (std.mem.eql(u8, parent_kind, "issue"))
            try resolveIssueIdForCommand(allocator, args[2])
        else
            try resolvePullIdForCommand(allocator, args[2]);
        defer allocator.free(parent_id);
        var repo = try repo_mod.discoverRepo(allocator);
        defer repo.deinit();
        try index.ensureIndex(allocator, repo);
        try index.listCommentsFromIndex(allocator, repo, parent_kind, parent_id, json);
        return;
    }

    if (std.mem.eql(u8, args[0], "add")) {
        if (args.len < 3 or (!isCommentParentKind(args[1]))) {
            try io.eprint("gt comment add: expected issue ISSUE or pr PR --body BODY\n", .{});
            return CliError.UserError;
        }
        const parent_kind = canonicalCommentParentKind(args[1]);
        var body: ?[]const u8 = null;
        var i: usize = 3;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--body") or std.mem.eql(u8, args[i], "-b")) {
                body = try util.requireValue(args, &i, "--body");
            } else {
                try io.eprint("gt comment add: unknown option '{s}'\n", .{args[i]});
                return CliError.UserError;
            }
        }
        if (body == null or std.mem.trim(u8, body.?, " \t\r\n").len == 0) {
            try io.eprint("gt comment add: --body is required\n", .{});
            return CliError.UserError;
        }
        const parent_id = if (std.mem.eql(u8, parent_kind, "issue"))
            try resolveIssueIdForCommand(allocator, args[2])
        else
            try resolvePullIdForCommand(allocator, args[2]);
        defer allocator.free(parent_id);
        try comment.createCommentAddedEvent(allocator, parent_kind, parent_id, body.?);
        return;
    }

    if (std.mem.eql(u8, args[0], "edit")) {
        if (args.len < 2) {
            try io.eprint("gt comment edit: COMMENT is required\n", .{});
            return CliError.UserError;
        }
        var body: ?[]const u8 = null;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--body") or std.mem.eql(u8, args[i], "-b")) {
                body = try util.requireValue(args, &i, "--body");
            } else {
                try io.eprint("gt comment edit: unknown option '{s}'\n", .{args[i]});
                return CliError.UserError;
            }
        }
        if (body == null or std.mem.trim(u8, body.?, " \t\r\n").len == 0) {
            try io.eprint("gt comment edit: --body is required\n", .{});
            return CliError.UserError;
        }
        const comment_id = try resolveCommentIdForCommand(allocator, args[1]);
        defer allocator.free(comment_id);
        try comment.createCommentBodySetEvent(allocator, comment_id, body.?);
        return;
    }

    if (std.mem.eql(u8, args[0], "redact")) {
        if (args.len < 2) {
            try io.eprint("gt comment redact: COMMENT is required\n", .{});
            return CliError.UserError;
        }
        var reason: ?[]const u8 = null;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--reason")) {
                reason = try util.requireValue(args, &i, "--reason");
            } else {
                try io.eprint("gt comment redact: unknown option '{s}'\n", .{args[i]});
                return CliError.UserError;
            }
        }
        const comment_id = try resolveCommentIdForCommand(allocator, args[1]);
        defer allocator.free(comment_id);
        try comment.createCommentRedactedEvent(allocator, comment_id, reason);
        return;
    }

    try io.eprint("gt comment: expected subcommand 'list', 'add', 'edit', or 'redact'\n", .{});
    return CliError.UserError;
}

fn isCommentParentKind(value: []const u8) bool {
    return std.mem.eql(u8, value, "issue") or std.mem.eql(u8, value, "pr") or std.mem.eql(u8, value, "pull");
}

fn canonicalCommentParentKind(value: []const u8) []const u8 {
    return if (std.mem.eql(u8, value, "pr")) "pull" else value;
}

fn cmdAcl(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try io.eprint("gt acl: expected subcommand 'grant', 'revoke', or 'list'\n", .{});
        return CliError.UserError;
    }

    if (std.mem.eql(u8, args[0], "list")) {
        var json = false;
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--json")) {
                json = true;
            } else {
                try io.eprint("gt acl list: unknown option '{s}'\n", .{args[i]});
                return CliError.UserError;
            }
        }
        var repo = try repo_mod.discoverRepo(allocator);
        defer repo.deinit();
        try index.ensureIndex(allocator, repo);
        try index.listAclFromIndex(allocator, repo, json);
        return;
    }

    if (std.mem.eql(u8, args[0], "grant")) {
        if (args.len != 3) {
            try io.eprint("gt acl grant: expected PRINCIPAL ROLE\n", .{});
            return CliError.UserError;
        }
        try rbac.createAclGrantEvent(allocator, args[1], args[2]);
        return;
    }

    if (std.mem.eql(u8, args[0], "revoke")) {
        if (args.len != 2) {
            try io.eprint("gt acl revoke: expected PRINCIPAL\n", .{});
            return CliError.UserError;
        }
        try rbac.createAclRevokeEvent(allocator, args[1]);
        return;
    }

    try io.eprint("gt acl: expected subcommand 'grant', 'revoke', or 'list'\n", .{});
    return CliError.UserError;
}

fn cmdIdentity(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try io.eprint("gt identity: expected subcommand 'add-device', 'revoke-device', or 'list'\n", .{});
        return CliError.UserError;
    }

    if (std.mem.eql(u8, args[0], "list")) {
        var json = false;
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--json")) {
                json = true;
            } else {
                try io.eprint("gt identity list: unknown option '{s}'\n", .{args[i]});
                return CliError.UserError;
            }
        }
        var repo = try repo_mod.discoverRepo(allocator);
        defer repo.deinit();
        try index.ensureIndex(allocator, repo);
        try index.listIdentityFromIndex(allocator, repo, json);
        return;
    }

    if (std.mem.eql(u8, args[0], "add-device")) {
        if (args.len < 3) {
            try io.eprint("gt identity add-device: expected PRINCIPAL DEVICE\n", .{});
            return CliError.UserError;
        }
        var public_key: ?[]const u8 = null;
        var fingerprint: ?[]const u8 = null;
        var scheme: []const u8 = "ssh";
        var i: usize = 3;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--public-key")) {
                public_key = try util.requireValue(args, &i, "--public-key");
            } else if (std.mem.eql(u8, args[i], "--fingerprint")) {
                fingerprint = try util.requireValue(args, &i, "--fingerprint");
            } else if (std.mem.eql(u8, args[i], "--scheme")) {
                scheme = try util.requireValue(args, &i, "--scheme");
            } else {
                try io.eprint("gt identity add-device: unknown option '{s}'\n", .{args[i]});
                return CliError.UserError;
            }
        }
        if (std.mem.trim(u8, scheme, " \t\r\n").len == 0) {
            try io.eprint("gt identity add-device: --scheme must not be empty\n", .{});
            return CliError.UserError;
        }
        try rbac.createIdentityDeviceAddedEvent(allocator, args[1], args[2], public_key, fingerprint, scheme);
        return;
    }

    if (std.mem.eql(u8, args[0], "revoke-device")) {
        if (args.len != 3) {
            try io.eprint("gt identity revoke-device: expected PRINCIPAL DEVICE\n", .{});
            return CliError.UserError;
        }
        try rbac.createIdentityDeviceRevokedEvent(allocator, args[1], args[2]);
        return;
    }

    try io.eprint("gt identity: expected subcommand 'add-device', 'revoke-device', or 'list'\n", .{});
    return CliError.UserError;
}

fn cmdActions(allocator: Allocator, args: []const []const u8, command_name: []const u8) !void {
    if (args.len == 0) {
        try io.eprint("{s}: expected subcommand 'workflows', 'request', 'complete', 'run', or 'run-requested'\n", .{command_name});
        return CliError.UserError;
    }

    if (std.mem.eql(u8, args[0], "workflows") or std.mem.eql(u8, args[0], "list")) {
        var json = false;
        var target_ref: ?[]const u8 = null;
        var target_oid: ?[]const u8 = null;
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--json")) {
                json = true;
            } else if (std.mem.eql(u8, arg, "--ref")) {
                target_ref = try util.requireValue(args, &i, "--ref");
            } else if (std.mem.eql(u8, arg, "--oid")) {
                target_oid = try util.requireValue(args, &i, "--oid");
            } else {
                try io.eprint("{s} workflows: unknown option '{s}'\n", .{ command_name, arg });
                return CliError.UserError;
            }
        }
        try actions.printWorkflows(allocator, target_ref, target_oid, json);
        return;
    }

    if (std.mem.eql(u8, args[0], "request")) {
        var workflow: ?[]const u8 = null;
        var target_ref: ?[]const u8 = null;
        var target_oid: ?[]const u8 = null;
        var event_name: ?[]const u8 = null;
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--workflow") or std.mem.eql(u8, arg, "-W")) {
                workflow = try util.requireValue(args, &i, "--workflow");
            } else if (std.mem.eql(u8, arg, "--ref")) {
                target_ref = try util.requireValue(args, &i, "--ref");
            } else if (std.mem.eql(u8, arg, "--oid")) {
                target_oid = try util.requireValue(args, &i, "--oid");
            } else if (std.mem.eql(u8, arg, "--event")) {
                event_name = try util.requireValue(args, &i, "--event");
            } else {
                try io.eprint("{s} request: unknown option '{s}'\n", .{ command_name, arg });
                return CliError.UserError;
            }
        }
        if (workflow == null or std.mem.trim(u8, workflow.?, " \t\r\n").len == 0) {
            try io.eprint("{s} request: --workflow is required\n", .{command_name});
            return CliError.UserError;
        }
        var result = try actions.requestWorkflow(allocator, workflow.?, target_ref, target_oid, event_name, null);
        defer result.deinit();
        return;
    }

    if (std.mem.eql(u8, args[0], "complete")) {
        if (args.len < 2) {
            try io.eprint("{s} complete: RUN is required\n", .{command_name});
            return CliError.UserError;
        }
        var conclusion: ?[]const u8 = null;
        var target_ref: ?[]const u8 = null;
        var target_oid: ?[]const u8 = null;
        var workflow: ?[]const u8 = null;
        var event_name: ?[]const u8 = null;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--conclusion")) {
                conclusion = try util.requireValue(args, &i, "--conclusion");
            } else if (std.mem.eql(u8, arg, "--ref")) {
                target_ref = try util.requireValue(args, &i, "--ref");
            } else if (std.mem.eql(u8, arg, "--oid")) {
                target_oid = try util.requireValue(args, &i, "--oid");
            } else if (std.mem.eql(u8, arg, "--workflow") or std.mem.eql(u8, arg, "-W")) {
                workflow = try util.requireValue(args, &i, "--workflow");
            } else if (std.mem.eql(u8, arg, "--event")) {
                event_name = try util.requireValue(args, &i, "--event");
            } else {
                try io.eprint("{s} complete: unknown option '{s}'\n", .{ command_name, arg });
                return CliError.UserError;
            }
        }
        if (conclusion == null) {
            try io.eprint("{s} complete: --conclusion is required\n", .{command_name});
            return CliError.UserError;
        }
        var result = try actions.completeRun(allocator, args[1], conclusion.?, target_ref, target_oid, workflow, event_name);
        defer result.deinit();
        return;
    }

    if (std.mem.eql(u8, args[0], "run") or std.mem.eql(u8, args[0], "schedule")) {
        var event_type: ?[]const u8 = null;
        var target_ref: ?[]const u8 = null;
        var target_oid: ?[]const u8 = null;
        var object_id: ?[]const u8 = null;
        var act_path: []const u8 = "act";
        var dry_run = false;
        var extra_args: []const []const u8 = &.{};
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--")) {
                extra_args = args[i + 1 ..];
                break;
            } else if (std.mem.eql(u8, arg, "--event")) {
                event_type = try util.requireValue(args, &i, "--event");
            } else if (std.mem.eql(u8, arg, "--ref")) {
                target_ref = try util.requireValue(args, &i, "--ref");
            } else if (std.mem.eql(u8, arg, "--oid")) {
                target_oid = try util.requireValue(args, &i, "--oid");
            } else if (std.mem.eql(u8, arg, "--object-id")) {
                object_id = try util.requireValue(args, &i, "--object-id");
            } else if (std.mem.eql(u8, arg, "--act")) {
                act_path = try util.requireValue(args, &i, "--act");
            } else if (std.mem.eql(u8, arg, "--dry-run")) {
                dry_run = true;
            } else {
                try io.eprint("{s} run: unknown option '{s}'\n", .{ command_name, arg });
                return CliError.UserError;
            }
        }
        if (event_type == null or std.mem.trim(u8, event_type.?, " \t\r\n").len == 0) {
            try io.eprint("{s} run: --event is required\n", .{command_name});
            return CliError.UserError;
        }
        try actions.scheduleEvent(allocator, event_type.?, target_ref, target_oid, object_id, .{
            .act_path = act_path,
            .dry_run = dry_run,
            .extra_args = extra_args,
        });
        return;
    }

    if (std.mem.eql(u8, args[0], "run-requested")) {
        var run_filter: ?[]const u8 = null;
        var act_path: []const u8 = "act";
        var dry_run = false;
        var extra_args: []const []const u8 = &.{};
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--")) {
                extra_args = args[i + 1 ..];
                break;
            } else if (std.mem.eql(u8, arg, "--act")) {
                act_path = try util.requireValue(args, &i, "--act");
            } else if (std.mem.eql(u8, arg, "--dry-run")) {
                dry_run = true;
            } else if (std.mem.startsWith(u8, arg, "-")) {
                try io.eprint("{s} run-requested: unknown option '{s}'\n", .{ command_name, arg });
                return CliError.UserError;
            } else if (run_filter == null) {
                run_filter = arg;
            } else {
                try io.eprint("{s} run-requested: unexpected argument '{s}'\n", .{ command_name, arg });
                return CliError.UserError;
            }
        }
        try actions.runRequested(allocator, run_filter, .{
            .act_path = act_path,
            .dry_run = dry_run,
            .extra_args = extra_args,
        });
        return;
    }

    try io.eprint("{s}: expected subcommand 'workflows', 'request', 'complete', 'run', or 'run-requested'\n", .{command_name});
    return CliError.UserError;
}

fn cmdRuns(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0 or !std.mem.eql(u8, args[0], "prune")) {
        try io.eprint("gt runs: expected subcommand 'prune'\n", .{});
        return CliError.UserError;
    }

    var options = runs.PruneOptions{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--dry-run")) {
            options.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--max-age-days")) {
            options.max_age_days = try runs.parsePruneNumber(try util.requireValue(args, &i, "--max-age-days"), "--max-age-days");
        } else if (std.mem.eql(u8, arg, "--max-count")) {
            const value = try runs.parsePruneNumber(try util.requireValue(args, &i, "--max-count"), "--max-count");
            options.max_count = std.math.cast(usize, value) orelse {
                try io.eprint("gt runs prune: --max-count is too large\n", .{});
                return CliError.UserError;
            };
        } else if (std.mem.eql(u8, arg, "--max-bytes")) {
            options.max_bytes = try runs.parsePruneNumber(try util.requireValue(args, &i, "--max-bytes"), "--max-bytes");
        } else {
            try io.eprint("gt runs prune: unknown option '{s}'\n", .{arg});
            return CliError.UserError;
        }
    }

    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();
    try runs.prune(allocator, options);
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
                return CliError.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--once")) {
            options.once = true;
        } else {
            try io.eprint("gt web: unknown option '{s}'\n", .{arg});
            return CliError.InvalidArgument;
        }
    }

    if (!web.isLoopbackHost(options.host)) {
        try io.eprint("gt web: refusing to bind non-loopback host '{s}' for local-only mode\n", .{options.host});
        return CliError.Unauthorized;
    }

    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();

    try web.serve(allocator, repo, options);
}
