const std = @import("std");
const errors = @import("../errors.zig");
const event_mod = @import("../event.zig");
const git = @import("../git.zig");
const index = @import("../index.zig");
const io = @import("../io.zig");
const json_writer = @import("../json_writer.zig");
const repo_mod = @import("../repo.zig");
const sync_mod = @import("../sync.zig");
const util = @import("../util.zig");
const zwf = @import("../zwf.zig");
const common = @import("common.zig");
const exporter = @import("exporter.zig");
const importer = @import("importer.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const GitHubClient = common.GitHubClient;
const RepoSlug = common.RepoSlug;
const appendJsonFieldString = json_writer.appendJsonFieldString;
const eprint = io.eprint;
const out = io.out;

pub const default_host = "127.0.0.1";
pub const default_port: u16 = 12656;
pub const default_path = "/github/webhook";
pub const default_interval_ms: u64 = 5000;
const import_bot_principal = "import-bot";
const import_bot_device = "github";

pub const Options = struct {
    repo: RepoSlug,
    host: []const u8 = default_host,
    port: u16 = default_port,
    path: []const u8 = default_path,
    webhook_url: ?[]const u8 = null,
    secret: ?[]const u8 = null,
    remote: []const u8 = "origin",
    interval_ms: u64 = default_interval_ms,
    once: bool = false,
    subscribe: bool = true,
    dry_run: bool = false,
    git_sync: bool = true,
    bot_principal: []const u8 = import_bot_principal,
    bot_device: []const u8 = import_bot_device,
};

const LiveState = struct {
    last_export_ordinal: i64 = 0,
    webhook_id: ?i64 = null,
};

pub const ResolvedRepo = struct {
    owned: []u8,
    slug: RepoSlug,

    pub fn deinit(self: ResolvedRepo, allocator: Allocator) void {
        allocator.free(self.owned);
    }
};

const LiveAppContext = struct {
    options: Options,
};

pub fn cmdLive(allocator: Allocator, args: []const []const u8) !void {
    var repo_arg: ?RepoSlug = null;
    var resolved_repo: ?ResolvedRepo = null;
    defer if (resolved_repo) |value| value.deinit(allocator);

    var host: []const u8 = default_host;
    var port: u16 = default_port;
    var path: []const u8 = default_path;
    var webhook_url: ?[]const u8 = null;
    var secret: ?[]const u8 = null;
    var remote: []const u8 = "origin";
    var interval_ms: u64 = default_interval_ms;
    var once = false;
    var subscribe = true;
    var dry_run = false;
    var git_sync = true;
    var bot_principal: []const u8 = import_bot_principal;
    var bot_device: []const u8 = import_bot_device;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--repo")) {
            repo_arg = try common.parseRepoSlug(try util.requireValue(args, &i, "--repo"));
        } else if (std.mem.eql(u8, arg, "--host")) {
            host = try util.requireValue(args, &i, "--host");
        } else if (std.mem.eql(u8, arg, "--port")) {
            port = std.fmt.parseUnsigned(u16, try util.requireValue(args, &i, "--port"), 10) catch {
                try eprint("gt github live: --port must be a TCP port\n", .{});
                return CliError.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--path")) {
            path = try util.requireValue(args, &i, "--path");
            if (path.len == 0 or path[0] != '/') {
                try eprint("gt github live: --path must start with '/'\n", .{});
                return CliError.InvalidArgument;
            }
        } else if (std.mem.eql(u8, arg, "--webhook-url")) {
            webhook_url = try util.requireValue(args, &i, "--webhook-url");
        } else if (std.mem.eql(u8, arg, "--secret")) {
            secret = try util.requireValue(args, &i, "--secret");
        } else if (std.mem.eql(u8, arg, "--remote")) {
            remote = try util.requireValue(args, &i, "--remote");
        } else if (std.mem.eql(u8, arg, "--interval-ms")) {
            interval_ms = std.fmt.parseUnsigned(u64, try util.requireValue(args, &i, "--interval-ms"), 10) catch {
                try eprint("gt github live: --interval-ms must be a non-negative integer\n", .{});
                return CliError.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--once")) {
            once = true;
        } else if (std.mem.eql(u8, arg, "--no-subscribe")) {
            subscribe = false;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "--no-git-sync")) {
            git_sync = false;
        } else if (std.mem.eql(u8, arg, "--import-bot")) {
            bot_principal = try util.requireValue(args, &i, "--import-bot");
        } else if (std.mem.eql(u8, arg, "--device")) {
            bot_device = try util.requireValue(args, &i, "--device");
        } else {
            try eprint("gt github live: unknown option '{s}'\n", .{arg});
            return CliError.UserError;
        }
    }

    if (repo_arg == null) {
        resolved_repo = try resolveCurrentRepo(allocator);
        repo_arg = resolved_repo.?.slug;
    }

    if (subscribe and webhook_url == null) {
        try eprint("gt github live: --webhook-url is required unless --no-subscribe is used\n", .{});
        return CliError.MissingArgument;
    }
    try validateSecretPolicy("gt github live", secret, subscribe, dry_run);

    const options = Options{
        .repo = repo_arg.?,
        .host = host,
        .port = port,
        .path = path,
        .webhook_url = webhook_url,
        .secret = secret,
        .remote = remote,
        .interval_ms = interval_ms,
        .once = once,
        .subscribe = subscribe,
        .dry_run = dry_run,
        .git_sync = git_sync,
        .bot_principal = bot_principal,
        .bot_device = bot_device,
    };

    try runForeground(allocator, options);
}

pub fn runForeground(allocator: Allocator, options: Options) !void {
    try validateOptions("gt github live", options);
    try prepareLive(allocator, options);

    const server_options = zwf.ServerOptions{
        .host = options.host,
        .port = options.port,
        .port_supplied = true,
        .once = options.once,
        .worker_count = 4,
    };
    var server = try listenLiveServer(options, server_options);
    defer server.deinit();

    try printLiveServerStarted(options, server.listen_address.getPort());
    if (!options.once) try startTickLoop(allocator, options);

    try zwf.server.serveConnections(LiveAppContext, allocator, .{ .options = options }, &server, server_options, handleConnectionLogged);
    if (options.once) try runLiveTick(allocator, options);
}

pub fn startDaemon(allocator: Allocator, options: Options) !void {
    if (options.once) {
        try eprint("gt github live: background daemon mode does not support --once\n", .{});
        return CliError.InvalidArgument;
    }
    try validateOptions("gt github live", options);

    try prepareLive(allocator, options);

    const server_options = zwf.ServerOptions{
        .host = options.host,
        .port = options.port,
        .port_supplied = true,
        .once = false,
        .worker_count = 4,
    };
    const server_ptr = try allocator.create(std.net.Server);
    errdefer allocator.destroy(server_ptr);
    server_ptr.* = try listenLiveServer(options, server_options);
    errdefer server_ptr.deinit();

    try printLiveServerStarted(options, server_ptr.listen_address.getPort());
    try startTickLoop(allocator, options);

    var thread = try std.Thread.spawn(.{}, serveLiveServerThread, .{ allocator, options, server_ptr, server_options });
    thread.detach();
}

fn prepareLive(allocator: Allocator, options: Options) !void {
    if (options.subscribe) try ensureWebhook(allocator, options);
    try runLiveTick(allocator, options);
}

fn listenLiveServer(options: Options, server_options: zwf.ServerOptions) !std.net.Server {
    const bind_host = zwf.server.bindHost(server_options);
    return zwf.server.listen(bind_host, server_options) catch |err| switch (err) {
        error.InvalidHost => {
            try eprint("gt github live: invalid host or port {s}:{d}\n", .{ options.host, options.port });
            return CliError.InvalidArgument;
        },
        else => return err,
    };
}

fn printLiveServerStarted(options: Options, actual_port: u16) !void {
    try out("GitHub live sync listening at http://{s}:{d}{s}\n", .{ options.host, actual_port, options.path });
}

fn startTickLoop(allocator: Allocator, options: Options) !void {
    var thread = try std.Thread.spawn(.{}, liveTickLoop, .{ allocator, options });
    thread.detach();
    try out("GitHub live sync exporting local events every {d}ms.\n", .{options.interval_ms});
}

fn serveLiveServerThread(allocator: Allocator, options: Options, server: *std.net.Server, server_options: zwf.ServerOptions) void {
    defer {
        server.deinit();
        allocator.destroy(server);
    }
    zwf.server.serveConnections(LiveAppContext, allocator, .{ .options = options }, server, server_options, handleConnectionLogged) catch |err| {
        if (!errors.isReported(err)) {
            eprint("gt github live: webhook server failed: {s}\n", .{@errorName(err)}) catch {};
        }
    };
}

fn liveTickLoop(allocator: Allocator, options: Options) void {
    while (true) {
        std.Thread.sleep(options.interval_ms * std.time.ns_per_ms);
        runLiveTick(allocator, options) catch |err| {
            if (!errors.isReported(err)) {
                eprint("gt github live: sync tick failed: {s}\n", .{@errorName(err)}) catch {};
            }
        };
    }
}

fn runLiveTick(allocator: Allocator, options: Options) !void {
    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();

    if (options.git_sync and !options.dry_run) {
        sync_mod.syncPull(allocator, options.remote) catch |err| {
            if (!errors.isUserError(err)) return err;
            if (!errors.isReported(err)) try eprint("gt github live: sync pull failed: {s}\n", .{@errorName(err)});
        };
    }
    try index.ensureIndex(allocator, repo);

    var state = try loadState(allocator, repo, options.repo);
    const map_path = try liveMapPath(allocator, repo, options.repo);
    defer allocator.free(map_path);
    const export_result = try exporter.exportToGithub(allocator, .{
        .repo = options.repo,
        .dry_run = options.dry_run,
        .map_file = map_path,
        .reuse_legacy = true,
        .use_gh = true,
        .after_ordinal = state.last_export_ordinal,
        .skip_actor_principal = options.bot_principal,
        .skip_actor_device = options.bot_device,
        .quiet = true,
    });
    if (export_result.max_ordinal > state.last_export_ordinal) {
        state.last_export_ordinal = export_result.max_ordinal;
        if (!options.dry_run) try saveState(allocator, repo, options.repo, state);
    }
    if (export_result.exported != 0) {
        try out("github live: exported {d} local event{s}\n", .{ export_result.exported, if (export_result.exported == 1) "" else "s" });
    }

    if (options.git_sync and !options.dry_run) {
        sync_mod.syncPush(allocator, options.remote) catch |err| {
            if (!errors.isUserError(err)) return err;
            if (!errors.isReported(err)) try eprint("gt github live: sync push failed: {s}\n", .{@errorName(err)});
        };
    }
}

fn handleConnectionLogged(allocator: Allocator, app_context: LiveAppContext, stream: std.net.Stream) !void {
    handleConnection(allocator, app_context, stream) catch |err| {
        if (zwf.server.isClientDisconnect(err)) return;
        try eprint("gt github live: request failed: {s}\n", .{@errorName(err)});
    };
}

fn handleConnection(allocator: Allocator, app_context: LiveAppContext, stream: std.net.Stream) !void {
    const raw = zwf.server.readHttpRequest(allocator, stream) catch {
        try sendPlain(allocator, stream, 400, "Bad Request", "Bad request\n");
        return;
    };
    defer allocator.free(raw);

    var request = zwf.Request.parseOwned(allocator, raw) catch {
        try sendPlain(allocator, stream, 400, "Bad Request", "Bad request\n");
        return;
    };
    defer request.deinit(allocator);

    if (!std.mem.eql(u8, request.path, app_context.options.path)) {
        try sendPlain(allocator, stream, 404, "Not Found", "Not found\n");
        return;
    }
    if (request.method != .POST) {
        try sendPlain(allocator, stream, 405, "Method Not Allowed", "Method not allowed\n");
        return;
    }
    if (!try authenticateWebhookRequest(allocator, stream, app_context.options, request)) return;

    const event_name = request.headerValue("x-github-event") orelse {
        try sendPlain(allocator, stream, 400, "Bad Request", "Missing X-GitHub-Event\n");
        return;
    };
    if (!try validateWebhookRepository(allocator, stream, app_context.options.repo, request.body)) return;

    if (std.mem.eql(u8, event_name, "push")) {
        if (app_context.options.git_sync and !app_context.options.dry_run) {
            sync_mod.syncPull(allocator, app_context.options.remote) catch |err| {
                if (!errors.isUserError(err)) return err;
                if (!errors.isReported(err)) try eprint("gt github live: push webhook sync failed: {s}\n", .{@errorName(err)});
            };
        }
        try sendPlain(allocator, stream, 200, "OK", "ok\n");
        return;
    }
    if (app_context.options.dry_run) {
        try sendPlain(allocator, stream, 200, "OK", "ok dry-run\n");
        return;
    }

    const stats = try importer.importWebhookPayload(allocator, event_name, request.body, .{
        .bot_principal = app_context.options.bot_principal,
        .bot_device = app_context.options.bot_device,
    });
    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();
    try index.ensureIndex(allocator, repo);
    if (app_context.options.git_sync and !app_context.options.dry_run) {
        sync_mod.syncPush(allocator, app_context.options.remote) catch |err| {
            if (!errors.isUserError(err)) return err;
            if (!errors.isReported(err)) try eprint("gt github live: webhook sync push failed: {s}\n", .{@errorName(err)});
        };
    }

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    try std.fmt.format(body.writer(allocator), "ok issues={d} pulls={d} comments={d}\n", .{ stats.issues, stats.pulls, stats.comments });
    try sendPlain(allocator, stream, 200, "OK", body.items);
}

fn ensureWebhook(allocator: Allocator, options: Options) !void {
    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();

    var state = try loadState(allocator, repo, options.repo);
    if (state.webhook_id != null) return;

    const body = try webhookCreateBody(allocator, options);
    defer allocator.free(body);
    const path = try std.fmt.allocPrint(allocator, "/repos/{s}/hooks", .{options.repo.slug});
    defer allocator.free(path);

    if (options.dry_run) {
        try out("POST {s} {s}\n", .{ path, body });
        return;
    }

    const client = GitHubClient{
        .allocator = allocator,
        .api_url = common.default_api_url,
        .repo = options.repo,
        .token = null,
        .use_gh = true,
    };
    const raw = try client.request("POST", path, body);
    defer allocator.free(raw);
    state.webhook_id = common.parseResponseNumber(allocator, raw, "id") orelse {
        try eprint("gt github live: GitHub hook create response did not contain id\n", .{});
        return CliError.UserError;
    };
    try saveState(allocator, repo, options.repo, state);
    try out("github live: subscribed webhook id {d}\n", .{state.webhook_id.?});
}

fn webhookCreateBody(allocator: Allocator, options: Options) ![]u8 {
    const secret = nonEmptySecret(options.secret) orelse {
        try eprint("gt github live: --secret is required when creating a GitHub webhook subscription\n", .{});
        return CliError.MissingArgument;
    };

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"name\":\"web\",\"active\":true,\"events\":[\"issues\",\"pull_request\",\"issue_comment\",\"push\"],\"config\":{");
    try appendJsonFieldString(&buf, allocator, "url", options.webhook_url.?, true);
    try appendJsonFieldString(&buf, allocator, "content_type", "json", true);
    try appendJsonFieldString(&buf, allocator, "insecure_ssl", "0", true);
    try appendJsonFieldString(&buf, allocator, "secret", secret, false);
    try buf.appendSlice(allocator, "}}");
    return try buf.toOwnedSlice(allocator);
}

fn loadState(allocator: Allocator, repo: repo_mod.Repo, slug: RepoSlug) !LiveState {
    const path = try statePath(allocator, repo, slug);
    defer allocator.free(path);
    const bytes = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer allocator.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return .{};
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return .{},
    };
    return .{
        .last_export_ordinal = common.jsonInteger(root.get("last_export_ordinal")) orelse 0,
        .webhook_id = common.jsonInteger(root.get("webhook_id")),
    };
}

fn saveState(allocator: Allocator, repo: repo_mod.Repo, slug: RepoSlug, state: LiveState) !void {
    const path = try statePath(allocator, repo, slug);
    defer allocator.free(path);
    if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    if (state.webhook_id) |hook_id| {
        const bytes = try std.fmt.allocPrint(allocator, "{{\"last_export_ordinal\":{d},\"webhook_id\":{d}}}\n", .{ state.last_export_ordinal, hook_id });
        defer allocator.free(bytes);
        try file.writeAll(bytes);
    } else {
        const bytes = try std.fmt.allocPrint(allocator, "{{\"last_export_ordinal\":{d},\"webhook_id\":null}}\n", .{state.last_export_ordinal});
        defer allocator.free(bytes);
        try file.writeAll(bytes);
    }
}

fn statePath(allocator: Allocator, repo: repo_mod.Repo, slug: RepoSlug) ![]u8 {
    const dir = try githubLiveDir(allocator, repo, slug);
    defer allocator.free(dir);
    return try std.fs.path.join(allocator, &.{ dir, "live.json" });
}

fn liveMapPath(allocator: Allocator, repo: repo_mod.Repo, slug: RepoSlug) ![]u8 {
    const dir = try githubLiveDir(allocator, repo, slug);
    defer allocator.free(dir);
    return try std.fs.path.join(allocator, &.{ dir, "map.jsonl" });
}

fn githubLiveDir(allocator: Allocator, repo: repo_mod.Repo, slug: RepoSlug) ![]u8 {
    const owner = try util.sanitizeRefSegment(allocator, slug.owner);
    defer allocator.free(owner);
    const name = try util.sanitizeRefSegment(allocator, slug.name);
    defer allocator.free(name);
    return try std.fs.path.join(allocator, &.{ repo.gitomi_dir, "github", owner, name });
}

pub fn resolveCurrentRepo(allocator: Allocator) !ResolvedRepo {
    var result = try git.runCommand(allocator, &.{ "gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner" }, null, 512 * 1024);
    defer result.deinit();
    if (result.exitCode() != 0) {
        const stderr = std.mem.trim(u8, result.stderr, " \t\r\n");
        if (stderr.len != 0) {
            try eprint("gt github live: failed to resolve current GitHub repository with gh: {s}\n", .{stderr});
        } else {
            try eprint("gt github live: failed to resolve current GitHub repository with gh\n", .{});
        }
        return CliError.UserError;
    }
    const owned = try util.trimOwned(allocator, result.stdout);
    errdefer allocator.free(owned);
    return .{
        .owned = owned,
        .slug = try common.parseRepoSlug(owned),
    };
}

fn validateOptions(command: []const u8, options: Options) !void {
    if (options.subscribe and options.webhook_url == null) {
        try eprint("{s}: --webhook-url is required unless --no-subscribe is used\n", .{command});
        return CliError.MissingArgument;
    }
    try validateSecretPolicy(command, options.secret, options.subscribe, options.dry_run);
}

pub fn validateSecretPolicy(
    command: []const u8,
    secret: ?[]const u8,
    subscribe: bool,
    dry_run: bool,
) !void {
    if (nonEmptySecret(secret) != null) return;
    if (secret != null) {
        try eprint("{s}: --secret must not be empty\n", .{command});
        return CliError.MissingArgument;
    }
    if (subscribe) {
        try eprint("{s}: --secret is required when creating a GitHub webhook subscription\n", .{command});
        return CliError.MissingArgument;
    }
    if (!dry_run) {
        try eprint("{s}: --secret is required for non-dry-run webhook imports\n", .{command});
        return CliError.MissingArgument;
    }
}

fn nonEmptySecret(secret: ?[]const u8) ?[]const u8 {
    const value = secret orelse return null;
    if (std.mem.trim(u8, value, " \t\r\n").len == 0) return null;
    return value;
}

fn authenticateWebhookRequest(
    allocator: Allocator,
    stream: std.net.Stream,
    options: Options,
    request: zwf.Request,
) !bool {
    const secret = nonEmptySecret(options.secret) orelse {
        if (options.dry_run) return true;
        try sendPlain(allocator, stream, 401, "Unauthorized", "Webhook secret required\n");
        return false;
    };
    const signature = request.headerValue("x-hub-signature-256") orelse {
        try sendPlain(allocator, stream, 401, "Unauthorized", "Missing signature\n");
        return false;
    };
    if (!verifyWebhookSignature(secret, request.body, signature)) {
        try sendPlain(allocator, stream, 401, "Unauthorized", "Invalid signature\n");
        return false;
    }
    return true;
}

const WebhookRepositoryCheck = enum {
    matches,
    missing,
    mismatch,
    invalid_payload,
};

fn validateWebhookRepository(
    allocator: Allocator,
    stream: std.net.Stream,
    expected: RepoSlug,
    body: []const u8,
) !bool {
    switch (try checkWebhookRepository(allocator, expected, body)) {
        .matches => return true,
        .invalid_payload => try sendPlain(allocator, stream, 400, "Bad Request", "Webhook payload must contain a JSON object\n"),
        .missing => try sendPlain(allocator, stream, 400, "Bad Request", "Webhook payload repository.full_name is required\n"),
        .mismatch => try sendPlain(allocator, stream, 403, "Forbidden", "Webhook payload repository mismatch\n"),
    }
    return false;
}

fn checkWebhookRepository(allocator: Allocator, expected: RepoSlug, body: []const u8) !WebhookRepositoryCheck {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .invalid_payload,
    };
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return .invalid_payload,
    };
    const repository = switch (root.get("repository") orelse return .missing) {
        .object => |object| object,
        else => return .missing,
    };
    const full_name = event_mod.jsonString(repository.get("full_name")) orelse return .missing;
    if (std.ascii.eqlIgnoreCase(full_name, expected.slug)) return .matches;
    return .mismatch;
}

fn verifyWebhookSignature(secret: []const u8, body: []const u8, signature: []const u8) bool {
    const prefix = "sha256=";
    if (!std.mem.startsWith(u8, signature, prefix)) return false;
    const actual = signature[prefix.len..];
    if (actual.len != 64) return false;
    var mac: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(mac[0..], body, secret);
    const expected = std.fmt.bytesToHex(mac, .lower);
    return std.crypto.timing_safe.eql([expected.len]u8, expected, actual[0..expected.len].*);
}

fn sendPlain(allocator: Allocator, stream: std.net.Stream, status: u16, reason: []const u8, body: []const u8) !void {
    var response = zwf.Response.init(allocator, stream);
    try response.plain(status, reason, body);
}

test "github live webhook body requires secret" {
    const slug = try common.parseRepoSlug("owner/repo");
    const body = try webhookCreateBody(std.testing.allocator, .{
        .repo = slug,
        .webhook_url = "https://example.test/github",
        .secret = "s3",
    });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"secret\":\"s3\"") != null);

    try std.testing.expectError(CliError.MissingArgument, webhookCreateBody(std.testing.allocator, .{
        .repo = slug,
        .webhook_url = "https://example.test/github",
    }));
}

test "github live requires secret for subscriptions and mutating imports" {
    try std.testing.expectError(
        CliError.MissingArgument,
        validateSecretPolicy("gt github live", null, true, true),
    );
    try std.testing.expectError(
        CliError.MissingArgument,
        validateSecretPolicy("gt github live", null, false, false),
    );
    try std.testing.expectError(
        CliError.MissingArgument,
        validateSecretPolicy("gt github live", "", false, true),
    );
    try validateSecretPolicy("gt github live", null, false, true);
    try validateSecretPolicy("gt github live", "s3", true, false);
}

test "github live validates webhook repository" {
    const slug = try common.parseRepoSlug("owner/repo");
    try std.testing.expectEqual(
        WebhookRepositoryCheck.matches,
        try checkWebhookRepository(std.testing.allocator, slug, "{\"repository\":{\"full_name\":\"Owner/Repo\"}}"),
    );
    try std.testing.expectEqual(
        WebhookRepositoryCheck.mismatch,
        try checkWebhookRepository(std.testing.allocator, slug, "{\"repository\":{\"full_name\":\"attacker/forged-repo\"}}"),
    );
    try std.testing.expectEqual(
        WebhookRepositoryCheck.missing,
        try checkWebhookRepository(std.testing.allocator, slug, "{\"repository\":{}}"),
    );
    try std.testing.expectEqual(
        WebhookRepositoryCheck.invalid_payload,
        try checkWebhookRepository(std.testing.allocator, slug, "not json"),
    );
}

test "github live verifies sha256 webhook signatures" {
    try std.testing.expect(verifyWebhookSignature(
        "secret",
        "payload",
        "sha256=b82fcb791acec57859b989b430a826488ce2e479fdf92326bd0a2e8375a42ba4",
    ));
    try std.testing.expect(!verifyWebhookSignature("secret", "payload", "sha256=bad"));
}
