const std = @import("std");
const errors = @import("../../errors.zig");
const index = @import("../../index.zig");
const io = @import("../../io.zig");
const repo_mod = @import("../../repo.zig");
const sync_mod = @import("../../sync.zig");
const util = @import("../../util.zig");
const common = @import("common.zig");
const exporter = @import("exporter.zig");
const importer = @import("importer.zig");
const live = @import("live.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const ApiMode = common.ApiMode;
const GitHubClient = common.GitHubClient;
const RepoSlug = common.RepoSlug;
const eprint = io.eprint;
const out = io.out;

const default_interval_ms: u64 = 0;

const Options = struct {
    repo: RepoSlug,
    api_url: []const u8 = common.default_api_url,
    token: ?[]const u8 = null,
    remote: []const u8 = "origin",
    dry_run: bool = false,
    git_sync: bool = true,
    interval_ms: u64 = default_interval_ms,
    max_pages: usize = 10,
    bot_principal: []const u8 = "import-bot",
    bot_device: []const u8 = "github",
    map_file: ?[]const u8 = null,
    include_comments: bool = true,
    include_projects: bool = true,
    mode: ApiMode = .graphql,
    use_gh: bool = false,
};

const SyncState = struct {
    last_export_ordinal: i64 = 0,
};

pub fn cmdSync(allocator: Allocator, args: []const []const u8) !void {
    var repo_opt: ?RepoSlug = null;
    var resolved_repo: ?live.ResolvedRepo = null;
    defer if (resolved_repo) |value| value.deinit(allocator);
    var api_url: []const u8 = common.default_api_url;
    var token_arg: ?[]const u8 = null;
    var token_source_owned: ?[]u8 = null;
    defer if (token_source_owned) |value| allocator.free(value);
    var remote: []const u8 = "origin";
    var dry_run = false;
    var git_sync = true;
    var interval_ms: u64 = default_interval_ms;
    var max_pages: usize = 10;
    var bot_principal: []const u8 = "import-bot";
    var bot_device: []const u8 = "github";
    var map_file_arg: ?[]const u8 = null;
    var include_comments = true;
    var include_projects = true;
    var mode: ApiMode = .graphql;
    var use_gh = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--repo")) {
            repo_opt = try common.parseRepoSlug(try util.requireValue(args, &i, "--repo"));
        } else if (std.mem.eql(u8, arg, "--api-url")) {
            api_url = try util.requireValue(args, &i, "--api-url");
        } else if (std.mem.eql(u8, arg, "--token")) {
            _ = try util.requireValue(args, &i, "--token");
            try eprint("gt github sync: --token exposes credentials in process lists; use --token-env, --token-file, GITHUB_TOKEN, GH_TOKEN, or --use-gh\n", .{});
            return CliError.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "--token-env")) {
            const env_name = try util.requireValue(args, &i, "--token-env");
            if (token_source_owned) |value| allocator.free(value);
            token_source_owned = null;
            token_source_owned = try common.secretFromEnv(allocator, "gt github sync", env_name);
            token_arg = token_source_owned;
        } else if (std.mem.eql(u8, arg, "--token-file")) {
            const path = try util.requireValue(args, &i, "--token-file");
            if (token_source_owned) |value| allocator.free(value);
            token_source_owned = null;
            token_source_owned = try common.secretFromFile(allocator, "gt github sync", path);
            token_arg = token_source_owned;
        } else if (std.mem.eql(u8, arg, "--use-gh")) {
            use_gh = true;
        } else if (std.mem.eql(u8, arg, "--remote")) {
            remote = try util.requireValue(args, &i, "--remote");
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "--no-git-sync")) {
            git_sync = false;
        } else if (std.mem.eql(u8, arg, "--interval-ms")) {
            interval_ms = std.fmt.parseUnsigned(u64, try util.requireValue(args, &i, "--interval-ms"), 10) catch {
                try eprint("gt github sync: --interval-ms must be a non-negative integer\n", .{});
                return CliError.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--max-pages")) {
            max_pages = std.fmt.parseUnsigned(usize, try util.requireValue(args, &i, "--max-pages"), 10) catch {
                try eprint("gt github sync: --max-pages must be a positive integer\n", .{});
                return CliError.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--import-bot")) {
            bot_principal = try util.requireValue(args, &i, "--import-bot");
        } else if (std.mem.eql(u8, arg, "--device")) {
            bot_device = try util.requireValue(args, &i, "--device");
        } else if (std.mem.eql(u8, arg, "--map-file")) {
            map_file_arg = try util.requireValue(args, &i, "--map-file");
        } else if (std.mem.eql(u8, arg, "--no-comments")) {
            include_comments = false;
        } else if (std.mem.eql(u8, arg, "--no-projects")) {
            include_projects = false;
        } else if (std.mem.eql(u8, arg, "--rest")) {
            mode = .rest;
        } else if (std.mem.eql(u8, arg, "--graphql")) {
            mode = .graphql;
        } else {
            try eprint("gt github sync: unknown option '{s}'\n", .{arg});
            return CliError.UserError;
        }
    }

    if (repo_opt == null) {
        if (std.mem.eql(u8, api_url, common.default_api_url)) {
            resolved_repo = try live.resolveCurrentRepo(allocator);
            repo_opt = resolved_repo.?.slug;
            use_gh = true;
        } else {
            try eprint("gt github sync: --repo OWNER/REPO is required\n", .{});
            return CliError.MissingArgument;
        }
    }

    var token_owned: ?[]u8 = null;
    defer if (token_owned) |value| allocator.free(value);
    const token = if (use_gh) null else token_arg orelse blk: {
        token_owned = common.githubTokenFromEnv(allocator) catch null;
        break :blk token_owned;
    };
    if (!dry_run and token == null and !use_gh) {
        try eprint("gt github sync: --token-env, --token-file, GITHUB_TOKEN, GH_TOKEN, or --use-gh is required unless --dry-run is used\n", .{});
        return CliError.MissingArgument;
    }

    const options = Options{
        .repo = repo_opt.?,
        .api_url = api_url,
        .token = token,
        .remote = remote,
        .dry_run = dry_run,
        .git_sync = git_sync,
        .interval_ms = interval_ms,
        .max_pages = max_pages,
        .bot_principal = bot_principal,
        .bot_device = bot_device,
        .map_file = map_file_arg,
        .include_comments = include_comments,
        .include_projects = include_projects,
        .mode = mode,
        .use_gh = use_gh,
    };

    if (interval_ms == 0) {
        try runSyncOnce(allocator, options);
        return;
    }

    try out("GitHub sync polling repository {s} every {d}ms using {s}.\n", .{ options.repo.slug, interval_ms, modeName(options.mode) });
    while (true) {
        try runSyncOnce(allocator, options);
        std.Thread.sleep(interval_ms * std.time.ns_per_ms);
    }
}

fn runSyncOnce(allocator: Allocator, options: Options) !void {
    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();

    if (options.git_sync and !options.dry_run) {
        try sync_mod.syncPull(allocator, options.remote);
    }
    try index.ensureIndex(allocator, repo);

    const map_path = if (options.map_file) |path| try allocator.dupe(u8, path) else try githubMapPath(allocator, repo, options.repo);
    defer allocator.free(map_path);

    const client = GitHubClient{
        .allocator = allocator,
        .api_url = options.api_url,
        .repo = options.repo,
        .token = options.token,
        .dry_run = options.dry_run,
        .use_gh = options.use_gh,
    };
    var import_stats = importer.ImportStats{};
    try importer.importFromApi(allocator, client, .{
        .repo = options.repo,
        .api_url = options.api_url,
        .token_arg = options.token,
        .include_comments = options.include_comments,
        .include_projects = options.include_projects,
        .bot_principal = options.bot_principal,
        .bot_device = options.bot_device,
        .max_pages = options.max_pages,
        .use_gh = options.use_gh,
        .mode = options.mode,
        .map_file = map_path,
    }, &import_stats);

    try index.ensureIndex(allocator, repo);
    var state = try loadState(allocator, repo, options.repo);
    const export_result = try exporter.exportToGithub(allocator, .{
        .repo = options.repo,
        .api_url = options.api_url,
        .token_arg = options.token,
        .dry_run = options.dry_run,
        .map_file = map_path,
        .reuse_legacy = true,
        .use_gh = options.use_gh,
        .after_ordinal = state.last_export_ordinal,
        .skip_actor_principal = options.bot_principal,
        .skip_actor_device = options.bot_device,
        .max_events = 100,
        .quiet = true,
    });
    if (export_result.max_ordinal > state.last_export_ordinal) {
        state.last_export_ordinal = export_result.max_ordinal;
        if (!options.dry_run) try saveState(allocator, repo, options.repo, state);
    }
    try out("github sync: imported {d} issue{s}, {d} pull{s}, {d} comment{s}, {d} project card{s}; exported {d} event{s} via {s}\n", .{
        import_stats.issues,
        if (import_stats.issues == 1) "" else "s",
        import_stats.pulls,
        if (import_stats.pulls == 1) "" else "s",
        import_stats.comments,
        if (import_stats.comments == 1) "" else "s",
        import_stats.project_cards,
        if (import_stats.project_cards == 1) "" else "s",
        export_result.exported,
        if (export_result.exported == 1) "" else "s",
        modeName(options.mode),
    });

    if (options.git_sync and !options.dry_run) {
        try sync_mod.syncPush(allocator, options.remote);
    }
}

fn loadState(allocator: Allocator, repo: repo_mod.Repo, slug: RepoSlug) !SyncState {
    const path = try statePath(allocator, repo, slug);
    defer allocator.free(path);
    const bytes = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer allocator.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch {
        try eprint("gt github sync: sync state {s} is not valid JSON\n", .{path});
        return CliError.UserError;
    };
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => {
            try eprint("gt github sync: sync state {s} must contain a JSON object\n", .{path});
            return CliError.UserError;
        },
    };
    return .{ .last_export_ordinal = common.jsonInteger(root.get("last_export_ordinal")) orelse 0 };
}

fn saveState(allocator: Allocator, repo: repo_mod.Repo, slug: RepoSlug, state: SyncState) !void {
    const path = try statePath(allocator, repo, slug);
    defer allocator.free(path);
    if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);
    const bytes = try std.fmt.allocPrint(allocator, "{{\"last_export_ordinal\":{d}}}\n", .{state.last_export_ordinal});
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

pub fn githubMapPath(allocator: Allocator, repo: repo_mod.Repo, slug: RepoSlug) ![]u8 {
    const dir = try githubSyncDir(allocator, repo, slug);
    defer allocator.free(dir);
    return try std.fs.path.join(allocator, &.{ dir, "map.jsonl" });
}

fn statePath(allocator: Allocator, repo: repo_mod.Repo, slug: RepoSlug) ![]u8 {
    const dir = try githubSyncDir(allocator, repo, slug);
    defer allocator.free(dir);
    return try std.fs.path.join(allocator, &.{ dir, "sync-state.json" });
}

fn githubSyncDir(allocator: Allocator, repo: repo_mod.Repo, slug: RepoSlug) ![]u8 {
    const owner = try util.sanitizeRefSegment(allocator, slug.owner);
    defer allocator.free(owner);
    const name = try util.sanitizeRefSegment(allocator, slug.name);
    defer allocator.free(name);
    return try std.fs.path.join(allocator, &.{ repo.gitomi_dir, "github", owner, name });
}

fn modeName(mode: ApiMode) []const u8 {
    return switch (mode) {
        .rest => "REST",
        .graphql => "GraphQL",
    };
}
