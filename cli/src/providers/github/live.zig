const std = @import("std");
const errors = @import("../../errors.zig");
const event_mod = @import("../../event.zig");
const git = @import("../../git.zig");
const index = @import("../../index.zig");
const io = @import("../../io.zig");
const json_writer = @import("../../json_writer.zig");
const repo_mod = @import("../../repo.zig");
const sync_mod = @import("../../sync.zig");
const util = @import("../../util.zig");
const zwf = @import("../../zwf.zig");
const common = @import("common.zig");
const exporter = @import("exporter.zig");
const importer = @import("importer.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const ApiMode = common.ApiMode;
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
const max_delivery_log_bytes = 64 * 1024 * 1024;
const max_delivery_id_bytes = 128;
const max_export_events_per_tick = 50;
const min_error_backoff_ms: u64 = 1000;
const max_error_backoff_ms: u64 = 60_000;
var live_mutex = std.Thread.Mutex{};
var runtime_available = std.atomic.Value(bool).init(false);
var runtime_active = std.atomic.Value(bool).init(false);

pub const RuntimeStatus = struct {
    available: bool = false,
    active: bool = false,
};

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
    mode: ApiMode = .graphql,
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

const LiveLock = struct {
    file: std.fs.File,

    fn deinit(self: *LiveLock) void {
        self.file.close();
        live_mutex.unlock();
    }
};

pub fn runtimeStatus() RuntimeStatus {
    return .{
        .available = runtime_available.load(.acquire),
        .active = runtime_active.load(.acquire),
    };
}

pub fn setRuntimeActive(active: bool) bool {
    if (!runtime_available.load(.acquire)) return false;
    runtime_active.store(active, .release);
    return true;
}

fn enableRuntimeControl(active: bool) void {
    runtime_active.store(active, .release);
    runtime_available.store(true, .release);
}

fn disableRuntimeControl() void {
    runtime_active.store(false, .release);
    runtime_available.store(false, .release);
}

fn isRuntimeActive() bool {
    return runtime_active.load(.acquire);
}

pub fn cmdLive(allocator: Allocator, args: []const []const u8) !void {
    var repo_arg: ?RepoSlug = null;
    var resolved_repo: ?ResolvedRepo = null;
    defer if (resolved_repo) |value| value.deinit(allocator);

    var host: []const u8 = default_host;
    var port: u16 = default_port;
    var path: []const u8 = default_path;
    var webhook_url: ?[]const u8 = null;
    var secret: ?[]const u8 = null;
    var secret_source_owned: ?[]u8 = null;
    defer if (secret_source_owned) |value| allocator.free(value);
    var remote: []const u8 = "origin";
    var interval_ms: u64 = default_interval_ms;
    var once = false;
    var subscribe = true;
    var dry_run = false;
    var git_sync = true;
    var bot_principal: []const u8 = import_bot_principal;
    var bot_device: []const u8 = import_bot_device;
    var mode: ApiMode = .graphql;

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
            _ = try util.requireValue(args, &i, "--secret");
            try eprint("gt github live: --secret exposes credentials in process lists; use --secret-env or --secret-file\n", .{});
            return CliError.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "--secret-env")) {
            const env_name = try util.requireValue(args, &i, "--secret-env");
            if (secret_source_owned) |value| allocator.free(value);
            secret_source_owned = null;
            secret_source_owned = try common.secretFromEnv(allocator, "gt github live", env_name);
            secret = secret_source_owned;
        } else if (std.mem.eql(u8, arg, "--secret-file")) {
            const path_arg = try util.requireValue(args, &i, "--secret-file");
            if (secret_source_owned) |value| allocator.free(value);
            secret_source_owned = null;
            secret_source_owned = try common.secretFromFile(allocator, "gt github live", path_arg);
            secret = secret_source_owned;
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
        } else if (std.mem.eql(u8, arg, "--rest")) {
            mode = .rest;
        } else if (std.mem.eql(u8, arg, "--graphql")) {
            mode = .graphql;
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
        .mode = mode,
    };

    try runForeground(allocator, options);
}

pub fn runForeground(allocator: Allocator, options: Options) !void {
    try validateOptions("gt github live", options);
    enableRuntimeControl(true);
    errdefer disableRuntimeControl();
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

    enableRuntimeControl(true);
    errdefer disableRuntimeControl();
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
    var next_server: ?*std.net.Server = server;
    var backoff_ms: u64 = min_error_backoff_ms;
    while (true) {
        const server_ptr = next_server orelse blk: {
            const fresh = allocator.create(std.net.Server) catch |err| {
                eprint("gt github live: webhook server restart allocation failed: {s}\n", .{@errorName(err)}) catch {};
                sleepMs(backoff_ms);
                backoff_ms = nextBackoffMs(backoff_ms);
                continue;
            };
            fresh.* = listenLiveServer(options, server_options) catch |err| {
                allocator.destroy(fresh);
                if (!errors.isReported(err)) {
                    eprint("gt github live: webhook server restart failed: {s}\n", .{@errorName(err)}) catch {};
                }
                sleepMs(backoff_ms);
                backoff_ms = nextBackoffMs(backoff_ms);
                continue;
            };
            eprint("gt github live: webhook server restarted\n", .{}) catch {};
            break :blk fresh;
        };
        next_server = null;

        zwf.server.serveConnections(LiveAppContext, allocator, .{ .options = options }, server_ptr, server_options, handleConnectionLogged) catch |err| {
            if (!errors.isReported(err)) {
                eprint("gt github live: webhook server failed: {s}; restarting in {d}ms\n", .{ @errorName(err), backoff_ms }) catch {};
            }
        };
        server_ptr.deinit();
        allocator.destroy(server_ptr);
        sleepMs(backoff_ms);
        backoff_ms = nextBackoffMs(backoff_ms);
    }
}

fn liveTickLoop(allocator: Allocator, options: Options) void {
    var delay_ms = options.interval_ms;
    while (true) {
        sleepMs(delay_ms);
        if (!isRuntimeActive()) {
            delay_ms = options.interval_ms;
            continue;
        }
        runLiveTick(allocator, options) catch |err| {
            const next_delay = nextBackoffMs(@max(delay_ms, baseBackoffMs(options.interval_ms)));
            if (!errors.isReported(err)) {
                eprint("gt github live: sync tick failed: {s}; retrying in {d}ms\n", .{ @errorName(err), next_delay }) catch {};
            }
            delay_ms = next_delay;
            continue;
        };
        delay_ms = options.interval_ms;
    }
}

fn baseBackoffMs(interval_ms: u64) u64 {
    return @max(interval_ms, min_error_backoff_ms);
}

fn nextBackoffMs(current_ms: u64) u64 {
    const base = @max(current_ms, min_error_backoff_ms);
    const doubled = std.math.mul(u64, base, 2) catch max_error_backoff_ms;
    return @min(doubled, max_error_backoff_ms);
}

fn sleepMs(ms: u64) void {
    const ns = std.math.mul(u64, ms, std.time.ns_per_ms) catch std.math.maxInt(u64);
    std.Thread.sleep(ns);
}

fn runLiveTick(allocator: Allocator, options: Options) !void {
    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();

    var live_lock = if (!options.dry_run) try acquireLiveLock(allocator, repo, options.repo) else null;
    defer if (live_lock) |*lock| lock.deinit();

    if (options.git_sync and !options.dry_run) {
        sync_mod.syncPull(allocator, options.remote) catch |err| {
            if (!errors.isReported(err)) try eprint("gt github live: sync pull failed: {s}\n", .{@errorName(err)});
            return err;
        };
    }
    try index.ensureIndex(allocator, repo);

    var state = try loadState(allocator, repo, options.repo);
    const map_path = try liveMapPath(allocator, repo, options.repo);
    defer allocator.free(map_path);
    var export_result = try exporter.exportToGithub(allocator, .{
        .repo = options.repo,
        .dry_run = options.dry_run,
        .map_file = map_path,
        .reuse_legacy = true,
        .use_gh = true,
        .after_ordinal = state.last_export_ordinal,
        .skip_actor_principal = options.bot_principal,
        .skip_actor_device = options.bot_device,
        .max_events = max_export_events_per_tick,
        .quiet = true,
        .mode = options.mode,
        .reuse_index_aliases = true,
    });
    defer export_result.deinit(allocator);
    if (export_result.max_ordinal > state.last_export_ordinal) {
        state.last_export_ordinal = export_result.max_ordinal;
        if (!options.dry_run) try saveState(allocator, repo, options.repo, state);
    }
    if (export_result.exported != 0) {
        try out("github live: exported {d} local event{s}\n", .{ export_result.exported, if (export_result.exported == 1) "" else "s" });
    }

    if (options.git_sync and !options.dry_run) {
        sync_mod.syncPush(allocator, options.remote) catch |err| {
            if (!errors.isReported(err)) try eprint("gt github live: sync push failed: {s}\n", .{@errorName(err)});
            return err;
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
    if (!isRuntimeActive()) {
        try sendPlain(allocator, stream, 202, "Accepted", "live mode off\n");
        return;
    }

    const event_name = request.headerValue("x-github-event") orelse {
        try sendPlain(allocator, stream, 400, "Bad Request", "Missing X-GitHub-Event\n");
        return;
    };
    if (!try validateWebhookRepository(allocator, stream, app_context.options.repo, request.body)) return;

    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();

    var live_lock = if (!app_context.options.dry_run) try acquireLiveLock(allocator, repo, app_context.options.repo) else null;
    defer if (live_lock) |*lock| lock.deinit();

    const delivery_id: ?[]const u8 = if (!app_context.options.dry_run) blk: {
        const state = try loadState(allocator, repo, app_context.options.repo);
        if (!try validateWebhookHookId(allocator, stream, state, request)) return;
        const id = (try checkedWebhookDeliveryId(allocator, stream, request)) orelse return;
        if (try deliveryAlreadyProcessed(allocator, repo, app_context.options.repo, id)) {
            try sendPlain(allocator, stream, 200, "OK", "ok duplicate\n");
            return;
        }
        break :blk id;
    } else null;

    if (std.mem.eql(u8, event_name, "push")) {
        if (app_context.options.git_sync and !app_context.options.dry_run) {
            sync_mod.syncPull(allocator, app_context.options.remote) catch |err| {
                if (!errors.isReported(err)) try eprint("gt github live: push webhook sync failed: {s}\n", .{@errorName(err)});
                try sendPlain(allocator, stream, 503, "Service Unavailable", "sync pull failed\n");
                return;
            };
        }
        if (delivery_id) |id| try recordWebhookDelivery(allocator, repo, app_context.options.repo, id);
        try sendPlain(allocator, stream, 200, "OK", "ok\n");
        return;
    }
    if (app_context.options.dry_run) {
        try sendPlain(allocator, stream, 200, "OK", "ok dry-run\n");
        return;
    }

    const map_path = try liveMapPath(allocator, repo, app_context.options.repo);
    defer allocator.free(map_path);
    const stats = try importer.importWebhookPayload(allocator, event_name, request.body, .{
        .bot_principal = app_context.options.bot_principal,
        .bot_device = app_context.options.bot_device,
        .map_file = map_path,
    });
    try index.ensureIndex(allocator, repo);
    if (app_context.options.git_sync and !app_context.options.dry_run) {
        sync_mod.syncPush(allocator, app_context.options.remote) catch |err| {
            if (!errors.isUserError(err)) return err;
            if (!errors.isReported(err)) try eprint("gt github live: webhook sync push failed: {s}\n", .{@errorName(err)});
        };
    }
    if (delivery_id) |id| try recordWebhookDelivery(allocator, repo, app_context.options.repo, id);

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    try std.fmt.format(body.writer(allocator), "ok issues={d} pulls={d} comments={d}\n", .{ stats.issues, stats.pulls, stats.comments });
    try sendPlain(allocator, stream, 200, "OK", body.items);
}

fn ensureWebhook(allocator: Allocator, options: Options) !void {
    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();

    var live_lock = if (!options.dry_run) try acquireLiveLock(allocator, repo, options.repo) else null;
    defer if (live_lock) |*lock| lock.deinit();

    const hooks_path = try std.fmt.allocPrint(allocator, "/repos/{s}/hooks", .{options.repo.slug});
    defer allocator.free(hooks_path);

    if (options.dry_run) {
        const body = try webhookCreateBody(allocator, options, true);
        defer allocator.free(body);
        try out("GET {s}?per_page=100\n", .{hooks_path});
        try out("POST {s} {s}\n", .{ hooks_path, body });
        return;
    }

    const client = GitHubClient{
        .allocator = allocator,
        .api_url = common.default_api_url,
        .repo = options.repo,
        .token = null,
        .use_gh = true,
    };

    var state = try loadState(allocator, repo, options.repo);
    if (state.webhook_id) |hook_id| {
        if (try fetchRemoteWebhook(allocator, client, options, hook_id)) |remote| {
            if (remote.needs_update) try updateRemoteWebhook(allocator, client, options, remote.id);
            state.webhook_id = remote.id;
            try saveState(allocator, repo, options.repo, state);
            return;
        }
        state.webhook_id = null;
    }

    if (try findExistingRemoteWebhook(allocator, client, options)) |remote| {
        if (remote.needs_update) try updateRemoteWebhook(allocator, client, options, remote.id);
        state.webhook_id = remote.id;
        try saveState(allocator, repo, options.repo, state);
        try out("github live: using webhook id {d}\n", .{remote.id});
        return;
    }

    const body = try webhookCreateBody(allocator, options, false);
    defer allocator.free(body);
    const raw = try client.request("POST", hooks_path, body);
    defer allocator.free(raw);
    state.webhook_id = common.parseResponseNumber(allocator, raw, "id") orelse {
        try eprint("gt github live: GitHub hook create response did not contain id\n", .{});
        return CliError.UserError;
    };
    try saveState(allocator, repo, options.repo, state);
    try out("github live: subscribed webhook id {d}\n", .{state.webhook_id.?});
}

const RemoteWebhook = struct {
    id: i64,
    needs_update: bool,
};

fn fetchRemoteWebhook(allocator: Allocator, client: GitHubClient, options: Options, hook_id: i64) !?RemoteWebhook {
    const path = try std.fmt.allocPrint(allocator, "/repos/{s}/hooks/{d}", .{ options.repo.slug, hook_id });
    defer allocator.free(path);
    const raw = (try client.requestAllowNotFound("GET", path, null)) orelse return null;
    defer allocator.free(raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return null,
    };
    return .{
        .id = common.jsonInteger(root.get("id")) orelse hook_id,
        .needs_update = remoteWebhookNeedsUpdate(root, options),
    };
}

fn findExistingRemoteWebhook(allocator: Allocator, client: GitHubClient, options: Options) !?RemoteWebhook {
    const path = try std.fmt.allocPrint(allocator, "/repos/{s}/hooks?per_page=100", .{options.repo.slug});
    defer allocator.free(path);
    const raw = try client.request("GET", path, null);
    defer allocator.free(raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const hooks = switch (parsed.value) {
        .array => |array| array,
        else => return null,
    };

    var selected: ?RemoteWebhook = null;
    for (hooks.items) |item| {
        const root = switch (item) {
            .object => |object| object,
            else => continue,
        };
        if (!remoteWebhookUrlMatches(root, options)) continue;
        const id = common.jsonInteger(root.get("id")) orelse continue;
        const candidate = RemoteWebhook{
            .id = id,
            .needs_update = remoteWebhookNeedsUpdate(root, options),
        };
        selected = candidate;
        if (!candidate.needs_update) break;
    }
    return selected;
}

fn updateRemoteWebhook(allocator: Allocator, client: GitHubClient, options: Options, hook_id: i64) !void {
    const path = try std.fmt.allocPrint(allocator, "/repos/{s}/hooks/{d}", .{ options.repo.slug, hook_id });
    defer allocator.free(path);
    const body = try webhookUpdateBody(allocator, options, false);
    defer allocator.free(body);
    const raw = try client.request("PATCH", path, body);
    allocator.free(raw);
    try out("github live: updated webhook id {d}\n", .{hook_id});
}

fn remoteWebhookNeedsUpdate(root: std.json.ObjectMap, options: Options) bool {
    if ((common.jsonBool(root.get("active")) orelse false) != true) return true;
    if (!remoteWebhookEventsMatch(root.get("events"))) return true;

    const config = jsonObject(root.get("config")) orelse return true;
    const expected_url = options.webhook_url orelse return true;
    const url = event_mod.jsonString(config.get("url")) orelse return true;
    if (!std.mem.eql(u8, url, expected_url)) return true;
    const content_type = event_mod.jsonString(config.get("content_type")) orelse return true;
    if (!std.mem.eql(u8, content_type, "json")) return true;
    const insecure_ssl = event_mod.jsonString(config.get("insecure_ssl")) orelse return true;
    if (!std.mem.eql(u8, insecure_ssl, "0")) return true;
    return false;
}

fn remoteWebhookUrlMatches(root: std.json.ObjectMap, options: Options) bool {
    const expected_url = options.webhook_url orelse return false;
    const config = jsonObject(root.get("config")) orelse return false;
    const url = event_mod.jsonString(config.get("url")) orelse return false;
    return std.mem.eql(u8, url, expected_url);
}

fn remoteWebhookEventsMatch(value: ?std.json.Value) bool {
    const events = common.jsonArray(value) orelse return false;
    const expected = [_][]const u8{ "issues", "pull_request", "issue_comment", "push" };
    if (events.items.len != expected.len) return false;
    for (expected) |event_name| {
        var found = false;
        for (events.items) |item| {
            const actual = event_mod.jsonString(item) orelse return false;
            if (std.mem.eql(u8, actual, event_name)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn jsonObject(value: ?std.json.Value) ?std.json.ObjectMap {
    const actual = value orelse return null;
    return switch (actual) {
        .object => |object| object,
        else => null,
    };
}

fn webhookCreateBody(allocator: Allocator, options: Options, redact_secret: bool) ![]u8 {
    const secret = nonEmptySecret(options.secret) orelse {
        try eprint("gt github live: --secret-env or --secret-file is required when creating a GitHub webhook subscription\n", .{});
        return CliError.MissingArgument;
    };

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"name\":\"web\",\"active\":true,\"events\":[\"issues\",\"pull_request\",\"issue_comment\",\"push\"],\"config\":{");
    try appendJsonFieldString(&buf, allocator, "url", options.webhook_url.?, true);
    try appendJsonFieldString(&buf, allocator, "content_type", "json", true);
    try appendJsonFieldString(&buf, allocator, "insecure_ssl", "0", true);
    try appendJsonFieldString(&buf, allocator, "secret", if (redact_secret) "[redacted]" else secret, false);
    try buf.appendSlice(allocator, "}}");
    return try buf.toOwnedSlice(allocator);
}

fn webhookUpdateBody(allocator: Allocator, options: Options, redact_secret: bool) ![]u8 {
    const secret = nonEmptySecret(options.secret) orelse {
        try eprint("gt github live: --secret-env or --secret-file is required when updating a GitHub webhook subscription\n", .{});
        return CliError.MissingArgument;
    };

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"active\":true,\"events\":[\"issues\",\"pull_request\",\"issue_comment\",\"push\"],\"config\":{");
    try appendJsonFieldString(&buf, allocator, "url", options.webhook_url.?, true);
    try appendJsonFieldString(&buf, allocator, "content_type", "json", true);
    try appendJsonFieldString(&buf, allocator, "insecure_ssl", "0", true);
    try appendJsonFieldString(&buf, allocator, "secret", if (redact_secret) "[redacted]" else secret, false);
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
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch {
        try eprint("gt github live: live state {s} is not valid JSON\n", .{path});
        return CliError.UserError;
    };
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => {
            try eprint("gt github live: live state {s} must contain a JSON object\n", .{path});
            return CliError.UserError;
        },
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
    var bytes: []u8 = undefined;
    if (state.webhook_id) |hook_id| {
        bytes = try std.fmt.allocPrint(allocator, "{{\"last_export_ordinal\":{d},\"webhook_id\":{d}}}\n", .{ state.last_export_ordinal, hook_id });
    } else {
        bytes = try std.fmt.allocPrint(allocator, "{{\"last_export_ordinal\":{d},\"webhook_id\":null}}\n", .{state.last_export_ordinal});
    }
    defer allocator.free(bytes);
    try writeFileAtomic(allocator, path, bytes);
}

fn writeFileAtomic(allocator: Allocator, path: []const u8, bytes: []const u8) !void {
    const id = try util.newUuidV7(allocator);
    defer allocator.free(id);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{s}", .{ path, id });
    defer allocator.free(tmp_path);
    errdefer std.fs.cwd().deleteFile(tmp_path) catch {};

    var file = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true, .mode = 0o600 });
    var closed = false;
    defer if (!closed) file.close();
    try file.writeAll(bytes);
    try file.sync();
    file.close();
    closed = true;
    try std.fs.cwd().rename(tmp_path, path);
}

fn acquireLiveLock(allocator: Allocator, repo: repo_mod.Repo, slug: RepoSlug) !LiveLock {
    live_mutex.lock();
    errdefer live_mutex.unlock();

    const dir = try githubLiveDir(allocator, repo, slug);
    defer allocator.free(dir);
    try std.fs.cwd().makePath(dir);
    const path = try std.fs.path.join(allocator, &.{ dir, "live.lock" });
    defer allocator.free(path);
    return .{
        .file = try std.fs.cwd().createFile(path, .{
            .read = true,
            .truncate = false,
            .lock = .exclusive,
        }),
    };
}

fn validateWebhookHookId(
    allocator: Allocator,
    stream: std.net.Stream,
    state: LiveState,
    request: zwf.Request,
) !bool {
    const expected = state.webhook_id orelse return true;
    const raw = request.headerValue("x-github-hook-id") orelse {
        try sendPlain(allocator, stream, 403, "Forbidden", "Missing X-GitHub-Hook-ID\n");
        return false;
    };
    const actual = std.fmt.parseInt(i64, raw, 10) catch {
        try sendPlain(allocator, stream, 403, "Forbidden", "Invalid X-GitHub-Hook-ID\n");
        return false;
    };
    if (actual != expected) {
        try sendPlain(allocator, stream, 403, "Forbidden", "Webhook hook id mismatch\n");
        return false;
    }
    return true;
}

fn checkedWebhookDeliveryId(allocator: Allocator, stream: std.net.Stream, request: zwf.Request) !?[]const u8 {
    const delivery_id = request.headerValue("x-github-delivery") orelse {
        try sendPlain(allocator, stream, 400, "Bad Request", "Missing X-GitHub-Delivery\n");
        return null;
    };
    if (!isValidDeliveryId(delivery_id)) {
        try sendPlain(allocator, stream, 400, "Bad Request", "Invalid X-GitHub-Delivery\n");
        return null;
    }
    return delivery_id;
}

fn isValidDeliveryId(delivery_id: []const u8) bool {
    if (delivery_id.len == 0 or delivery_id.len > max_delivery_id_bytes) return false;
    for (delivery_id) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == ':') continue;
        return false;
    }
    return true;
}

fn deliveryAlreadyProcessed(allocator: Allocator, repo: repo_mod.Repo, slug: RepoSlug, delivery_id: []const u8) !bool {
    const path = try deliveryLogPath(allocator, repo, slug);
    defer allocator.free(path);
    const bytes = std.fs.cwd().readFileAlloc(allocator, path, max_delivery_log_bytes) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer allocator.free(bytes);

    var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (std.mem.eql(u8, line, delivery_id)) return true;
    }
    return false;
}

fn recordWebhookDelivery(allocator: Allocator, repo: repo_mod.Repo, slug: RepoSlug, delivery_id: []const u8) !void {
    const path = try deliveryLogPath(allocator, repo, slug);
    defer allocator.free(path);
    if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);
    var file = std.fs.cwd().openFile(path, .{ .mode = .write_only }) catch |err| switch (err) {
        error.FileNotFound => try std.fs.cwd().createFile(path, .{}),
        else => return err,
    };
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll(delivery_id);
    try file.writeAll("\n");
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

fn deliveryLogPath(allocator: Allocator, repo: repo_mod.Repo, slug: RepoSlug) ![]u8 {
    const dir = try githubLiveDir(allocator, repo, slug);
    defer allocator.free(dir);
    return try std.fs.path.join(allocator, &.{ dir, "deliveries.log" });
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
    const owned = try util.trimDup(allocator, result.stdout);
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
        try eprint("{s}: webhook secret must not be empty\n", .{command});
        return CliError.MissingArgument;
    }
    if (subscribe) {
        try eprint("{s}: --secret-env or --secret-file is required when creating a GitHub webhook subscription\n", .{command});
        return CliError.MissingArgument;
    }
    if (!dry_run) {
        try eprint("{s}: --secret-env or --secret-file is required for non-dry-run webhook imports\n", .{command});
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
    }, false);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"secret\":\"s3\"") != null);

    const redacted = try webhookCreateBody(std.testing.allocator, .{
        .repo = slug,
        .webhook_url = "https://example.test/github",
        .secret = "s3",
    }, true);
    defer std.testing.allocator.free(redacted);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "\"secret\":\"[redacted]\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "\"secret\":\"s3\"") == null);

    try std.testing.expectError(CliError.MissingArgument, webhookCreateBody(std.testing.allocator, .{
        .repo = slug,
        .webhook_url = "https://example.test/github",
    }, false));
}

test "github live webhook update body redacts secret" {
    const slug = try common.parseRepoSlug("owner/repo");
    const body = try webhookUpdateBody(std.testing.allocator, .{
        .repo = slug,
        .webhook_url = "https://example.test/github",
        .secret = "s3",
    }, true);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"secret\":\"[redacted]\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"secret\":\"s3\"") == null);
}

test "github live detects stale remote webhook configuration" {
    const slug = try common.parseRepoSlug("owner/repo");
    const options = Options{
        .repo = slug,
        .webhook_url = "https://example.test/github",
        .secret = "s3",
    };

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"id":42,"active":true,"events":["issues","pull_request","issue_comment","push"],"config":{"url":"https://example.test/github","content_type":"json","insecure_ssl":"0"}}
    , .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expect(!remoteWebhookNeedsUpdate(root, options));
    try std.testing.expect(remoteWebhookUrlMatches(root, options));

    var stale = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"id":42,"active":true,"events":["issues"],"config":{"url":"https://example.test/github","content_type":"json","insecure_ssl":"0"}}
    , .{});
    defer stale.deinit();
    try std.testing.expect(remoteWebhookNeedsUpdate(stale.value.object, options));
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

test "github live validates delivery ids before replay tracking" {
    try std.testing.expect(isValidDeliveryId("f3b8b2cc-8a8f-4cc8-a31b-2f611f93df43"));
    try std.testing.expect(isValidDeliveryId("hook:1234_delivery.1"));
    try std.testing.expect(!isValidDeliveryId(""));
    try std.testing.expect(!isValidDeliveryId("bad\nid"));
    try std.testing.expect(!isValidDeliveryId("bad/id"));
}
