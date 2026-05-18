const std = @import("std");
const builtin = @import("builtin");
const actions = @import("actions.zig");
const auth_binding = @import("auth_binding.zig");
const build_options = @import("build_options");
const comment = @import("comment.zig");
const errors = @import("errors.zig");
const event_mod = @import("event.zig");
const fsck = @import("fsck.zig");
const git = @import("git.zig");
const index = @import("index.zig");
const io = @import("io.zig");
const issue = @import("issue.zig");
const milestone = @import("milestone.zig");
const notification = @import("notification.zig");
const project = @import("project.zig");
const quarantine = @import("quarantine.zig");
const pr_mod = @import("pr.zig");
const providers = @import("providers.zig");
const rbac = @import("rbac.zig");
const repo_mod = @import("repo.zig");
const reset = @import("reset.zig");
const runs = @import("runs.zig");
const sync = @import("sync.zig");
const util = @import("util.zig");
const web = @import("web.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const github_common = providers.github.common;
const github_live = providers.github.live;

const CommandHandler = *const fn (Allocator, []const []const u8, []const u8) anyerror!void;

const Command = struct {
    handler: CommandHandler,
    command_name: []const u8,
};

const command_dispatch = std.StaticStringMap(Command).initComptime(.{
    .{ "-h", Command{ .handler = runHelp, .command_name = "gt -h" } },
    .{ "--help", Command{ .handler = runHelp, .command_name = "gt --help" } },
    .{ "help", Command{ .handler = runHelp, .command_name = "gt help" } },
    .{ "--version", Command{ .handler = runVersion, .command_name = "gt --version" } },
    .{ "version", Command{ .handler = runVersion, .command_name = "gt version" } },
    .{ "init", Command{ .handler = runInit, .command_name = "gt init" } },
    .{ "status", Command{ .handler = runStatus, .command_name = "gt status" } },
    .{ "doctor", Command{ .handler = runStatus, .command_name = "gt doctor" } },
    .{ "fsck", Command{ .handler = runFsck, .command_name = "gt fsck" } },
    .{ "index", Command{ .handler = runIndex, .command_name = "gt index" } },
    .{ "refs", Command{ .handler = runRefs, .command_name = "gt refs" } },
    .{ "quarantine", Command{ .handler = runQuarantine, .command_name = "gt quarantine" } },
    .{ "clear", Command{ .handler = runClearOrReset, .command_name = "gt clear" } },
    .{ "reset", Command{ .handler = runClearOrReset, .command_name = "gt reset" } },
    .{ "events", Command{ .handler = runEvents, .command_name = "gt events" } },
    .{ "issue", Command{ .handler = runIssue, .command_name = "gt issue" } },
    .{ "project", Command{ .handler = runProject, .command_name = "gt project" } },
    .{ "projects", Command{ .handler = runProject, .command_name = "gt projects" } },
    .{ "milestone", Command{ .handler = runMilestone, .command_name = "gt milestone" } },
    .{ "milestones", Command{ .handler = runMilestone, .command_name = "gt milestones" } },
    .{ "pr", Command{ .handler = runPr, .command_name = "gt pr" } },
    .{ "comment", Command{ .handler = runComment, .command_name = "gt comment" } },
    .{ "inbox", Command{ .handler = runInbox, .command_name = "gt inbox" } },
    .{ "notification", Command{ .handler = runNotification, .command_name = "gt notification" } },
    .{ "notifications", Command{ .handler = runNotification, .command_name = "gt notifications" } },
    .{ "acl", Command{ .handler = runAcl, .command_name = "gt acl" } },
    .{ "identity", Command{ .handler = runIdentity, .command_name = "gt identity" } },
    .{ "actions", Command{ .handler = runActions, .command_name = "gt actions" } },
    .{ "action", Command{ .handler = runActions, .command_name = "gt action" } },
    .{ "runs", Command{ .handler = runRuns, .command_name = "gt runs" } },
    .{ "sync", Command{ .handler = runSync, .command_name = "gt sync" } },
    .{ "web", Command{ .handler = runWeb, .command_name = "gt web" } },
});

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
    scrubSensitiveProcessArgs();

    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();
    try ensureTrustedRepo(allocator, repo);

    if (args.len <= 1) {
        try printUsage();
        return;
    }

    const cmd = args[1];
    const command = command_dispatch.get(cmd) orelse {
        if (providers.get(cmd)) |provider| {
            try provider.run(allocator, args[2..]);
            return;
        }
        try io.eprint("gt: unknown command '{s}'\n\n", .{cmd});
        try printUsage();
        return CliError.InvalidArgument;
    };

    try command.handler(allocator, args[2..], command.command_name);
}

fn ensureTrustedRepo(allocator: Allocator, repo: repo_mod.Repo) !void {
    const trust_path = try std.fs.path.join(allocator, &.{ repo.gitomi_dir, "trust" });
    defer allocator.free(trust_path);

    if (util.fileExists(trust_path)) return;

    try io.eprint("do you trust contents of this git repo? [y/N] ", .{});
    const answer = try readStdinLine(allocator, 1024);
    defer allocator.free(answer);

    if (!answerIsYes(std.mem.trim(u8, answer, " \t\r\n"))) {
        try io.eprint("gt: repository not trusted\n", .{});
        return CliError.UserError;
    }

    try std.fs.cwd().makePath(repo.gitomi_dir);
    const file = try std.fs.createFileAbsolute(trust_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll("trusted\n");
}

fn answerIsYes(answer: []const u8) bool {
    if (answer.len == 1) return std.ascii.toLower(answer[0]) == 'y';
    if (answer.len != 3) return false;
    return std.ascii.toLower(answer[0]) == 'y' and
        std.ascii.toLower(answer[1]) == 'e' and
        std.ascii.toLower(answer[2]) == 's';
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
            try io.eprint("input is too long\n", .{});
            return CliError.UserError;
        }
        if (byte[0] != '\r') try line.append(allocator, byte[0]);
    }

    return try line.toOwnedSlice(allocator);
}

fn scrubSensitiveProcessArgs() void {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;

    var i: usize = 0;
    while (i < std.os.argv.len) : (i += 1) {
        const arg = std.mem.sliceTo(std.os.argv[i], 0);
        if (std.mem.eql(u8, arg, "--secret") or std.mem.eql(u8, arg, "--token")) {
            if (i + 1 < std.os.argv.len) {
                scrubArgvValue(std.os.argv[i + 1]);
                i += 1;
            }
        } else if (std.mem.startsWith(u8, arg, "--secret=") or std.mem.startsWith(u8, arg, "--token=")) {
            const eq = std.mem.indexOfScalar(u8, arg, '=') orelse continue;
            @memset(arg[eq + 1 ..], 'x');
        }
    }
}

fn scrubArgvValue(value_z: [*:0]u8) void {
    const value = std.mem.sliceTo(value_z, 0);
    @memset(value, 'x');
}

fn runHelp(_: Allocator, _: []const []const u8, _: []const u8) !void {
    try printUsage();
}

fn runVersion(_: Allocator, _: []const []const u8, _: []const u8) !void {
    try io.out("gt {s}\n", .{build_options.version});
}

fn runInit(allocator: Allocator, args: []const []const u8, _: []const u8) !void {
    try cmdInit(allocator, args);
}

fn runStatus(allocator: Allocator, _: []const []const u8, _: []const u8) !void {
    try cmdStatus(allocator);
}

fn runFsck(allocator: Allocator, args: []const []const u8, _: []const u8) !void {
    try cmdFsck(allocator, args);
}

fn runIndex(allocator: Allocator, args: []const []const u8, _: []const u8) !void {
    try cmdIndex(allocator, args);
}

fn runRefs(allocator: Allocator, _: []const []const u8, _: []const u8) !void {
    try cmdRefs(allocator);
}

fn runQuarantine(allocator: Allocator, args: []const []const u8, _: []const u8) !void {
    try quarantine.cmdQuarantine(allocator, args);
}

fn runClearOrReset(allocator: Allocator, args: []const []const u8, command_name: []const u8) !void {
    try reset.cmdClearOrReset(allocator, args, command_name);
}

fn runEvents(allocator: Allocator, args: []const []const u8, _: []const u8) !void {
    try cmdEvents(allocator, args);
}

fn runIssue(allocator: Allocator, args: []const []const u8, _: []const u8) !void {
    try issue.cmdIssue(allocator, args);
}

fn runProject(allocator: Allocator, args: []const []const u8, _: []const u8) !void {
    try project.cmdProject(allocator, args);
}

fn runMilestone(allocator: Allocator, args: []const []const u8, _: []const u8) !void {
    try milestone.cmdMilestone(allocator, args);
}

fn runPr(allocator: Allocator, args: []const []const u8, command_name: []const u8) !void {
    try pr_mod.cmdPr(allocator, args, command_name);
}

fn runComment(allocator: Allocator, args: []const []const u8, _: []const u8) !void {
    try comment.cmdComment(allocator, args);
}

fn runInbox(allocator: Allocator, args: []const []const u8, _: []const u8) !void {
    try notification.cmdInbox(allocator, args);
}

fn runNotification(allocator: Allocator, args: []const []const u8, _: []const u8) !void {
    try notification.cmdNotification(allocator, args);
}

fn runAcl(allocator: Allocator, args: []const []const u8, _: []const u8) !void {
    try cmdAcl(allocator, args);
}

fn runIdentity(allocator: Allocator, args: []const []const u8, _: []const u8) !void {
    try cmdIdentity(allocator, args);
}

fn runActions(allocator: Allocator, args: []const []const u8, command_name: []const u8) !void {
    try cmdActions(allocator, args, command_name);
}

fn runRuns(allocator: Allocator, args: []const []const u8, _: []const u8) !void {
    try cmdRuns(allocator, args);
}

fn runSync(allocator: Allocator, args: []const []const u8, _: []const u8) !void {
    try cmdSync(allocator, args);
}

fn runWeb(allocator: Allocator, args: []const []const u8, _: []const u8) !void {
    try cmdWeb(allocator, args);
}

fn printUsage() !void {
    try io.out(
        \\Usage:
        \\  gt init [--principal ID] [--device ID] [--repo-id UUID] [--access open|closed] [--force]
        \\  gt status
        \\  gt fsck
        \\  gt index rebuild|status
        \\  gt index snapshots prune [--dry-run] [--max-count N] [--max-bytes N] [--max-tree-bytes N]
        \\  gt refs
        \\  gt quarantine list
        \\  gt quarantine inspect REF
        \\  gt quarantine adopt REF [--replace-local] [--keep] [--yes]
        \\  gt quarantine restore-local-to-remote REF [--remote REMOTE] [--keep] [--yes]
        \\  gt quarantine drop REF [--yes]
        \\  gt clear local [--yes]
        \\  gt clear remote [--remote REMOTE] [--yes]
        \\  gt reset local [--yes]
        \\  gt reset remote [--remote REMOTE] [--yes]
        \\  gt events list [--json] [--limit N] [--ref REF]
        \\  gt issue list [--json] [--view agent] [--state open|closed|all] [--author PRINCIPAL] [--label LABEL] [--project PROJECT] [--milestone MILESTONE] [--assignee PRINCIPAL] [--sort newest|oldest|updated] [--limit N]
        \\  gt issue show ISSUE [--json] [--view agent]
        \\  gt issue open --title TITLE [--body BODY] [--parent ISSUE] [--type bug|feature|task] [--priority P0|P1|P2|P3] [--status Draft|Todo|WIP|Review|Done|Failed] [--label LABEL] [--assignee PRINCIPAL]
        \\  gt issue edit ISSUE [--title TITLE] [--body BODY] [--state open|closed] [--type bug|feature|task] [--priority P0|P1|P2|P3] [--status Draft|Todo|WIP|Review|Done|Failed] [--label LABEL] [--unlabel LABEL] [--assignee PRINCIPAL] [--unassign PRINCIPAL]
        \\  gt issue title ISSUE --title TITLE
        \\  gt issue body ISSUE --body BODY
        \\  gt issue type ISSUE --type bug|feature|task
        \\  gt issue priority ISSUE --priority P0|P1|P2|P3
        \\  gt issue status ISSUE --status Draft|Todo|WIP|Review|Done|Failed
        \\  gt issue comment ISSUE --body BODY [--reply COMMENT]
        \\  gt issue close|reopen ISSUE [--body BODY]
        \\  gt issue label ISSUE add|remove LABEL
        \\  gt issue assignee ISSUE add|remove PRINCIPAL
        \\  gt issue milestone ISSUE --milestone MILESTONE
        \\  gt issue project ISSUE add|remove PROJECT --column COLUMN
        \\  gt issue parent ISSUE add|remove PARENT_ISSUE
        \\  gt issue sub-issue ISSUE add|remove CHILD_ISSUE
        \\  gt issue blocked-by ISSUE add|remove BLOCKING_ISSUE
        \\  gt issue blocking ISSUE add|remove BLOCKED_ISSUE
        \\  gt issue concurrent-group ISSUE add|remove GROUP
        \\  gt issue react|unreact ISSUE EMOJI
        \\  gt project list [--json]
        \\  gt project create --name NAME [--description TEXT] [--column COLUMN]
        \\  gt project column PROJECT add|remove COLUMN
        \\  gt project add|remove PROJECT ISSUE --column COLUMN
        \\  gt milestone list [--json]
        \\  gt milestone create --title TITLE [--description TEXT] [--due DATE]
        \\  gt milestone edit MILESTONE [--title TITLE] [--description TEXT] [--due DATE] [--state open|closed]
        \\  gt milestone close|reopen MILESTONE
        \\  gt pr list [--json] [--view agent] [--state open|merged|closed|all] [--limit N]
        \\  gt pr view PR [--json] [--view agent] [--include-diff]
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
        \\  gt pr comment PR --body BODY [--reply COMMENT]
        \\  gt pr comment PR --body BODY --file PATH --side old|new --line LINE
        \\  gt pr comment PR --body BODY --file PATH --side old|new --start-line LINE [--end-line LINE]
        \\  gt pr react|unreact PR EMOJI
        \\  gt pr merge PR [--merge-oid OID] [--target-oid OID]
        \\  gt comment list issue|pr OBJECT [--json]
        \\  gt comment add issue|pr OBJECT --body BODY
        \\  gt comment reply COMMENT --body BODY
        \\  gt comment edit COMMENT --body BODY
        \\  gt comment redact COMMENT [--reason REASON]
        \\  gt comment react|unreact COMMENT EMOJI
        \\  gt inbox [--json] [--all|--unread] [--principal PRINCIPAL] [--limit N]
        \\  gt notification subscribe issue|pr OBJECT [--principal PRINCIPAL]
        \\  gt notification unsubscribe issue|pr OBJECT [--principal PRINCIPAL]
        \\  gt notification subscriptions [--json] [--principal PRINCIPAL]
        \\  gt notification read EVENT|--all [--principal PRINCIPAL]
        \\  gt acl grant PRINCIPAL ROLE
        \\  gt acl revoke PRINCIPAL
        \\  gt acl list [--json]
        \\  gt identity add-device PRINCIPAL DEVICE [--public-key KEY] [--fingerprint FP] [--scheme ssh|openpgp]
        \\  gt identity revoke-device PRINCIPAL DEVICE
        \\  gt identity list [--json]
        \\  gt actions workflows [--json] [--ref REF|--oid OID]
        \\  gt actions request --workflow WORKFLOW [--ref REF|--oid OID] [--event EVENT]
        \\  gt actions complete RUN --conclusion CONCLUSION [--workflow WORKFLOW] [--ref REF|--oid OID] [--event EVENT]
        \\  gt actions run --event EVENT [--ref REF|--oid OID] [--object-id ID] [--dry-run] [--act PATH] [--agent-runner PATH] [-- ACT_ARGS...]
        \\  gt actions run-requested [RUN] [--dry-run] [--act PATH] [--agent-runner PATH] [-- ACT_ARGS...]
        \\  gt actions daemon [--once] [--replay] [--interval-ms N] [--dry-run] [--act PATH] [--agent-runner PATH] [-- ACT_ARGS...]
        \\  gt runs prune [--dry-run] [--max-age-days N] [--max-count N] [--max-bytes N]
        \\  gt sync [--remote REMOTE] [--pull-only|--push-only]
        \\  gt github import [--repo OWNER/REPO] [--token-env NAME|--token-file PATH] [--from-file PATH] [--no-comments] [--no-projects] [--rest|--graphql]
        \\  gt github export --repo OWNER/REPO [--token-env NAME|--token-file PATH|--use-gh] [--dry-run] [--map-file PATH] [--reuse-legacy] [--rest|--graphql]
        \\  gt github sync [--repo OWNER/REPO] [--token-env NAME|--token-file PATH|--use-gh] [--remote REMOTE] [--interval-ms N] [--max-pages N] [--dry-run] [--no-git-sync] [--import-only] [--rest|--graphql]
        \\  gt github live [--repo OWNER/REPO] --webhook-url URL (--secret-env NAME|--secret-file PATH) [--host 127.0.0.1] [--port 12656] [--path /github/webhook] [--remote REMOTE] [--interval-ms N] [--once] [--no-subscribe] [--dry-run] [--no-git-sync] [--rest|--graphql]
        \\  gt gitlab import [--project GROUP/PROJECT] [--token-env NAME|--token-file PATH] [--from-file PATH] [--no-comments]
        \\  gt gitlab export --project GROUP/PROJECT [--token-env NAME|--token-file PATH] [--dry-run] [--map-file PATH] [--reuse-legacy]
        \\  gt gitlab sync --project GROUP/PROJECT [--token-env NAME|--token-file PATH] [--remote REMOTE] [--interval-ms N] [--max-pages N] [--dry-run] [--no-git-sync]
        \\  gt web [--local] [--host 127.0.0.1] [--port 12655] [--once]
        \\  gt web --live [--host 127.0.0.1] [--port 12655] [--repo OWNER/REPO] [--webhook-url URL] (--secret-env NAME|--secret-file PATH) [--live-host 127.0.0.1] [--live-port 12656] [--live-path /github/webhook] [--remote REMOTE] [--interval-ms N] [--no-subscribe] [--dry-run] [--no-git-sync] [--rest|--graphql]
        \\
        \\Gitomi stores local state in .git/gitomi and signed events in refs/gitomi/inbox/*.
        \\
    , .{});
}

fn cmdInit(allocator: Allocator, args: []const []const u8) !void {
    var repo_id_arg: ?[]const u8 = null;
    var principal_arg: ?[]const u8 = null;
    var device_arg: ?[]const u8 = null;
    var access_mode: repo_mod.AccessMode = .closed;
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
        } else if (std.mem.eql(u8, arg, "--access")) {
            const raw = try util.requireValue(args, &i, "--access");
            access_mode = repo_mod.parseAccessMode(raw) orelse {
                try io.eprint("gt init: --access must be open or closed\n", .{});
                return CliError.UserError;
            };
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
    const genesis_manifest = try repo_mod.buildGenesisManifestJson(allocator, cfg, signing_key.public_key, signing_key.fingerprint, signing_key.scheme, access_mode);
    defer allocator.free(genesis_manifest);

    try repo_mod.writeConfig(repo.config_path, cfg);
    const genesis_oid = try repo_mod.writeGenesisRef(allocator, genesis_manifest, force);
    defer allocator.free(genesis_oid);

    try io.out("initialized Gitomi repository\n", .{});
    try io.out("  repo:      {s}\n", .{repo.root});
    try io.out("  config:    {s}\n", .{repo.config_path});
    try io.out("  repo_id:   {s}\n", .{cfg.repo_id});
    try io.out("  access:    {s}\n", .{repo_mod.accessModeName(access_mode)});
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
    var genesis_valid_for_auth = false;
    if (genesis_oid) |oid| {
        if (repo_mod.loadGenesisManifest(allocator, oid)) |manifest_value| {
            var manifest = manifest_value;
            defer manifest.deinit();
            sync.verifyGenesisCommitSignature(allocator, oid, manifest.fingerprint) catch try checker.fail("{s}: signature verification failed", .{repo_mod.genesis_ref});
            genesis_valid_for_auth = true;
        } else |_| {
            try checker.fail("{s}: invalid genesis manifest", .{repo_mod.genesis_ref});
        }
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

    var auth_verifier: ?auth_binding.Verifier = if (genesis_valid_for_auth) try auth_binding.Verifier.init(allocator) else null;
    defer if (auth_verifier) |*verifier| verifier.deinit();

    for (refs) |ref| {
        if (genesis_oid) |oid| {
            const verifier_ptr = if (auth_verifier) |*verifier| verifier else null;
            try fsck.checkInboxRef(allocator, &checker, verifier_ptr, ref, empty_tree, oid);
        }
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

    if (std.mem.eql(u8, args[0], "snapshots")) {
        try cmdIndexSnapshots(allocator, args[1..]);
        return;
    }

    try io.eprint("gt index: expected subcommand 'rebuild', 'status', or 'snapshots'\n", .{});
    return CliError.UserError;
}

fn cmdIndexSnapshots(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0 or !std.mem.eql(u8, args[0], "prune")) {
        try io.eprint("gt index snapshots: expected subcommand 'prune'\n", .{});
        return CliError.UserError;
    }

    var options = index.SnapshotPruneOptions{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--dry-run")) {
            options.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--max-count")) {
            const value = try index.parseSnapshotPruneNumber(try util.requireValue(args, &i, "--max-count"), "--max-count");
            options.max_count = std.math.cast(usize, value) orelse {
                try io.eprint("gt index snapshots prune: --max-count is too large\n", .{});
                return CliError.UserError;
            };
        } else if (std.mem.eql(u8, arg, "--max-bytes")) {
            options.max_total_bytes = try index.parseSnapshotPruneNumber(try util.requireValue(args, &i, "--max-bytes"), "--max-bytes");
        } else if (std.mem.eql(u8, arg, "--max-tree-bytes")) {
            options.max_tree_bytes = try index.parseSnapshotPruneNumber(try util.requireValue(args, &i, "--max-tree-bytes"), "--max-tree-bytes");
        } else {
            try io.eprint("gt index snapshots prune: unknown option '{s}'\n", .{arg});
            return CliError.UserError;
        }
    }

    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();
    try index.pruneSnapshots(allocator, options);
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
        try io.eprint("{s}: expected subcommand 'workflows', 'request', 'complete', 'run', 'run-requested', or 'daemon'\n", .{command_name});
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
        var agent_runner_path: ?[]const u8 = null;
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
            } else if (std.mem.eql(u8, arg, "--agent-runner")) {
                agent_runner_path = try util.requireValue(args, &i, "--agent-runner");
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
            .agent_runner_path = agent_runner_path,
            .dry_run = dry_run,
            .extra_args = extra_args,
        });
        return;
    }

    if (std.mem.eql(u8, args[0], "run-requested")) {
        var run_filter: ?[]const u8 = null;
        var act_path: []const u8 = "act";
        var agent_runner_path: ?[]const u8 = null;
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
            } else if (std.mem.eql(u8, arg, "--agent-runner")) {
                agent_runner_path = try util.requireValue(args, &i, "--agent-runner");
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
            .agent_runner_path = agent_runner_path,
            .dry_run = dry_run,
            .extra_args = extra_args,
        });
        return;
    }

    if (std.mem.eql(u8, args[0], "daemon") or std.mem.eql(u8, args[0], "watch")) {
        var options = actions.DaemonOptions{};
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--")) {
                options.extra_args = args[i + 1 ..];
                break;
            } else if (std.mem.eql(u8, arg, "--act")) {
                options.act_path = try util.requireValue(args, &i, "--act");
            } else if (std.mem.eql(u8, arg, "--agent-runner")) {
                options.agent_runner_path = try util.requireValue(args, &i, "--agent-runner");
            } else if (std.mem.eql(u8, arg, "--dry-run")) {
                options.dry_run = true;
            } else if (std.mem.eql(u8, arg, "--once")) {
                options.once = true;
            } else if (std.mem.eql(u8, arg, "--replay")) {
                options.replay = true;
            } else if (std.mem.eql(u8, arg, "--interval-ms")) {
                const raw = try util.requireValue(args, &i, "--interval-ms");
                options.interval_ms = std.fmt.parseUnsigned(u64, raw, 10) catch {
                    try io.eprint("{s} daemon: --interval-ms must be a non-negative integer\n", .{command_name});
                    return CliError.UserError;
                };
            } else {
                try io.eprint("{s} daemon: unknown option '{s}'\n", .{ command_name, arg });
                return CliError.UserError;
            }
        }
        try actions.runDaemon(allocator, options);
        return;
    }

    try io.eprint("{s}: expected subcommand 'workflows', 'request', 'complete', 'run', 'run-requested', or 'daemon'\n", .{command_name});
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
    const WebMode = enum { local, live };
    var mode: WebMode = .local;
    var mode_set = false;

    var live_repo_arg: ?github_common.RepoSlug = null;
    var live_resolved_repo: ?github_live.ResolvedRepo = null;
    defer if (live_resolved_repo) |value| value.deinit(allocator);
    var live_host: []const u8 = github_live.default_host;
    var live_port: u16 = github_live.default_port;
    var live_path: []const u8 = github_live.default_path;
    var live_webhook_url: ?[]const u8 = null;
    var live_secret: ?[]const u8 = null;
    var live_secret_source_owned: ?[]u8 = null;
    defer if (live_secret_source_owned) |value| allocator.free(value);
    var live_remote: []const u8 = "origin";
    var live_interval_ms: u64 = github_live.default_interval_ms;
    var live_subscribe = true;
    var live_dry_run = false;
    var live_git_sync = true;
    var live_bot_principal: []const u8 = "import-bot";
    var live_bot_device: []const u8 = "github";
    var live_mode: github_common.ApiMode = .graphql;
    var live_option_seen = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--local")) {
            if (mode_set and mode != .local) {
                try io.eprint("gt web: --local and --live are mutually exclusive\n", .{});
                return CliError.InvalidArgument;
            }
            mode = .local;
            mode_set = true;
        } else if (std.mem.eql(u8, arg, "--live")) {
            if (mode_set and mode != .live) {
                try io.eprint("gt web: --local and --live are mutually exclusive\n", .{});
                return CliError.InvalidArgument;
            }
            mode = .live;
            mode_set = true;
        } else if (std.mem.eql(u8, arg, "--host")) {
            options.host = try util.requireValue(args, &i, "--host");
        } else if (std.mem.eql(u8, arg, "--port")) {
            const raw = try util.requireValue(args, &i, "--port");
            options.port = std.fmt.parseUnsigned(u16, raw, 10) catch {
                try io.eprint("gt web: --port must be an integer from 1 to 65535\n", .{});
                return CliError.InvalidArgument;
            };
            options.port_supplied = true;
        } else if (std.mem.eql(u8, arg, "--once")) {
            options.once = true;
        } else if (std.mem.eql(u8, arg, "--repo")) {
            live_option_seen = true;
            live_repo_arg = try github_common.parseRepoSlug(try util.requireValue(args, &i, "--repo"));
        } else if (std.mem.eql(u8, arg, "--webhook-url")) {
            live_option_seen = true;
            live_webhook_url = try util.requireValue(args, &i, "--webhook-url");
        } else if (std.mem.eql(u8, arg, "--secret")) {
            live_option_seen = true;
            _ = try util.requireValue(args, &i, "--secret");
            try io.eprint("gt web: --secret exposes credentials in process lists; use --secret-env or --secret-file\n", .{});
            return CliError.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "--secret-env")) {
            live_option_seen = true;
            const env_name = try util.requireValue(args, &i, "--secret-env");
            if (live_secret_source_owned) |value| allocator.free(value);
            live_secret_source_owned = null;
            live_secret_source_owned = try github_common.secretFromEnv(allocator, "gt web", env_name);
            live_secret = live_secret_source_owned;
        } else if (std.mem.eql(u8, arg, "--secret-file")) {
            live_option_seen = true;
            const path_arg = try util.requireValue(args, &i, "--secret-file");
            if (live_secret_source_owned) |value| allocator.free(value);
            live_secret_source_owned = null;
            live_secret_source_owned = try github_common.secretFromFile(allocator, "gt web", path_arg);
            live_secret = live_secret_source_owned;
        } else if (std.mem.eql(u8, arg, "--remote")) {
            live_option_seen = true;
            live_remote = try util.requireValue(args, &i, "--remote");
        } else if (std.mem.eql(u8, arg, "--interval-ms")) {
            live_option_seen = true;
            live_interval_ms = std.fmt.parseUnsigned(u64, try util.requireValue(args, &i, "--interval-ms"), 10) catch {
                try io.eprint("gt web: --interval-ms must be a non-negative integer\n", .{});
                return CliError.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--live-host")) {
            live_option_seen = true;
            live_host = try util.requireValue(args, &i, "--live-host");
        } else if (std.mem.eql(u8, arg, "--live-port")) {
            live_option_seen = true;
            live_port = std.fmt.parseUnsigned(u16, try util.requireValue(args, &i, "--live-port"), 10) catch {
                try io.eprint("gt web: --live-port must be an integer from 1 to 65535\n", .{});
                return CliError.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--live-path") or std.mem.eql(u8, arg, "--path")) {
            live_option_seen = true;
            live_path = try util.requireValue(args, &i, arg);
            if (live_path.len == 0 or live_path[0] != '/') {
                try io.eprint("gt web: --live-path must start with '/'\n", .{});
                return CliError.InvalidArgument;
            }
        } else if (std.mem.eql(u8, arg, "--no-subscribe")) {
            live_option_seen = true;
            live_subscribe = false;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            live_option_seen = true;
            live_dry_run = true;
        } else if (std.mem.eql(u8, arg, "--no-git-sync")) {
            live_option_seen = true;
            live_git_sync = false;
        } else if (std.mem.eql(u8, arg, "--import-bot")) {
            live_option_seen = true;
            live_bot_principal = try util.requireValue(args, &i, "--import-bot");
        } else if (std.mem.eql(u8, arg, "--device")) {
            live_option_seen = true;
            live_bot_device = try util.requireValue(args, &i, "--device");
        } else if (std.mem.eql(u8, arg, "--rest")) {
            live_option_seen = true;
            live_mode = .rest;
        } else if (std.mem.eql(u8, arg, "--graphql")) {
            live_option_seen = true;
            live_mode = .graphql;
        } else {
            try io.eprint("gt web: unknown option '{s}'\n", .{arg});
            return CliError.InvalidArgument;
        }
    }

    if (live_option_seen and mode != .live) {
        try io.eprint("gt web: GitHub live options require --live\n", .{});
        return CliError.InvalidArgument;
    }
    if (mode == .live and options.once) {
        try io.eprint("gt web: --live cannot be combined with --once\n", .{});
        return CliError.InvalidArgument;
    }

    if (!web.isLoopbackHost(options.host)) {
        try io.eprint("gt web: refusing to bind non-loopback host '{s}' for local-only mode\n", .{options.host});
        return CliError.Unauthorized;
    }

    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();

    if (mode == .live) {
        if (live_repo_arg == null) {
            live_resolved_repo = try github_live.resolveCurrentRepo(allocator);
            live_repo_arg = live_resolved_repo.?.slug;
        }
        if (live_subscribe and live_webhook_url == null) {
            try io.eprint("gt web: --webhook-url is required with --live unless --no-subscribe is used\n", .{});
            return CliError.MissingArgument;
        }
        try github_live.validateSecretPolicy("gt web", live_secret, live_subscribe, live_dry_run);
        try github_live.startDaemon(allocator, .{
            .repo = live_repo_arg.?,
            .host = live_host,
            .port = live_port,
            .path = live_path,
            .webhook_url = live_webhook_url,
            .secret = live_secret,
            .remote = live_remote,
            .interval_ms = live_interval_ms,
            .once = false,
            .subscribe = live_subscribe,
            .dry_run = live_dry_run,
            .git_sync = live_git_sync,
            .bot_principal = live_bot_principal,
            .bot_device = live_bot_device,
            .mode = live_mode,
        });
    }

    try web.serve(allocator, repo, options);
}
