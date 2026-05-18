const std = @import("std");
const errors = @import("../../errors.zig");
const index = @import("../../index.zig");
const io = @import("../../io.zig");
const repo_mod = @import("../../repo.zig");
const sync_mod = @import("../../sync.zig");
const util = @import("../../util.zig");
const import_bot = @import("../import_bot.zig");
const common = @import("common.zig");
const exporter = @import("exporter.zig");
const importer = @import("importer.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const ProjectRef = common.ProjectRef;
const GitLabClient = common.GitLabClient;
const eprint = io.eprint;
const out = io.out;

const default_interval_ms: u64 = 0;

const Options = struct {
    project: ProjectRef,
    api_url: []const u8 = common.default_api_url,
    token: ?[]const u8 = null,
    remote: []const u8 = "origin",
    dry_run: bool = false,
    git_sync: bool = true,
    interval_ms: u64 = default_interval_ms,
    max_pages: usize = 10,
    bot_principal: []const u8 = import_bot.principal,
    bot_device: []const u8 = import_bot.gitlab_device,
    map_file: ?[]const u8 = null,
};

const SyncState = struct {
    last_export_ordinal: i64 = 0,
};

pub fn cmdSync(allocator: Allocator, args: []const []const u8) !void {
    var project_opt: ?ProjectRef = null;
    var api_url: []const u8 = common.default_api_url;
    var token_arg: ?[]const u8 = null;
    var token_source_owned: ?[]u8 = null;
    defer if (token_source_owned) |value| allocator.free(value);
    var remote: []const u8 = "origin";
    var dry_run = false;
    var git_sync = true;
    var interval_ms: u64 = default_interval_ms;
    var max_pages: usize = 10;
    var bot_principal: []const u8 = import_bot.principal;
    var bot_device: []const u8 = import_bot.gitlab_device;
    var map_file_arg: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--project") or std.mem.eql(u8, arg, "--repo")) {
            project_opt = try common.parseProjectRef(try util.requireValue(args, &i, arg));
        } else if (std.mem.eql(u8, arg, "--api-url")) {
            api_url = try util.requireValue(args, &i, "--api-url");
        } else if (std.mem.eql(u8, arg, "--token")) {
            _ = try util.requireValue(args, &i, "--token");
            try eprint("gt gitlab sync: --token exposes credentials in process lists; use --token-env, --token-file, GITLAB_TOKEN, or GL_TOKEN\n", .{});
            return CliError.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "--token-env")) {
            const env_name = try util.requireValue(args, &i, "--token-env");
            if (token_source_owned) |value| allocator.free(value);
            token_source_owned = null;
            token_source_owned = try common.secretFromEnv(allocator, "gt gitlab sync", env_name);
            token_arg = token_source_owned;
        } else if (std.mem.eql(u8, arg, "--token-file")) {
            const path = try util.requireValue(args, &i, "--token-file");
            if (token_source_owned) |value| allocator.free(value);
            token_source_owned = null;
            token_source_owned = try common.secretFromFile(allocator, "gt gitlab sync", path);
            token_arg = token_source_owned;
        } else if (std.mem.eql(u8, arg, "--remote")) {
            remote = try util.requireValue(args, &i, "--remote");
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "--no-git-sync")) {
            git_sync = false;
        } else if (std.mem.eql(u8, arg, "--interval-ms")) {
            interval_ms = std.fmt.parseUnsigned(u64, try util.requireValue(args, &i, "--interval-ms"), 10) catch {
                try eprint("gt gitlab sync: --interval-ms must be a non-negative integer\n", .{});
                return CliError.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--max-pages")) {
            max_pages = std.fmt.parseUnsigned(usize, try util.requireValue(args, &i, "--max-pages"), 10) catch {
                try eprint("gt gitlab sync: --max-pages must be a positive integer\n", .{});
                return CliError.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--import-bot")) {
            bot_principal = try util.requireValue(args, &i, "--import-bot");
        } else if (std.mem.eql(u8, arg, "--device")) {
            bot_device = try util.requireValue(args, &i, "--device");
        } else if (std.mem.eql(u8, arg, "--map-file")) {
            map_file_arg = try util.requireValue(args, &i, "--map-file");
        } else {
            try eprint("gt gitlab sync: unknown option '{s}'\n", .{arg});
            return CliError.UserError;
        }
    }

    if (project_opt == null) {
        try eprint("gt gitlab sync: --project GROUP/PROJECT is required\n", .{});
        return CliError.MissingArgument;
    }

    var token_owned: ?[]u8 = null;
    defer if (token_owned) |value| allocator.free(value);
    const token = token_arg orelse blk: {
        token_owned = common.tokenFromEnv(allocator) catch null;
        break :blk token_owned;
    };
    if (!dry_run and token == null) {
        try eprint("gt gitlab sync: --token-env, --token-file, GITLAB_TOKEN, or GL_TOKEN is required unless --dry-run is used\n", .{});
        return CliError.MissingArgument;
    }

    const options = Options{
        .project = project_opt.?,
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
    };

    if (interval_ms == 0) {
        try runSyncOnce(allocator, options);
        return;
    }

    try out("GitLab sync polling project {s} every {d}ms.\n", .{ options.project.path, interval_ms });
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

    const map_path = if (options.map_file) |path| try allocator.dupe(u8, path) else try gitlabMapPath(allocator, repo, options.project);
    defer allocator.free(map_path);

    const client = GitLabClient{
        .allocator = allocator,
        .api_url = options.api_url,
        .project = options.project,
        .token = options.token,
        .dry_run = options.dry_run,
    };
    var import_stats = importer.ImportStats{};
    try importer.importFromApi(allocator, client, .{
        .project = options.project,
        .api_url = options.api_url,
        .token_arg = options.token,
        .bot_principal = options.bot_principal,
        .bot_device = options.bot_device,
        .max_pages = options.max_pages,
        .map_file = map_path,
    }, &import_stats);

    try index.ensureIndex(allocator, repo);
    var state = try loadState(allocator, repo, options.project);
    const export_result = try exporter.exportToGitlab(allocator, .{
        .project = options.project,
        .api_url = options.api_url,
        .token_arg = options.token,
        .dry_run = options.dry_run,
        .map_file = map_path,
        .reuse_legacy = true,
        .after_ordinal = state.last_export_ordinal,
        .skip_actor_principal = options.bot_principal,
        .skip_actor_device = options.bot_device,
        .max_events = 100,
        .quiet = true,
    });
    if (export_result.max_ordinal > state.last_export_ordinal) {
        state.last_export_ordinal = export_result.max_ordinal;
        if (!options.dry_run) try saveState(allocator, repo, options.project, state);
    }
    try out("gitlab sync: imported {d} issue{s}, {d} merge request{s}, {d} comment{s}; exported {d} event{s}\n", .{
        import_stats.issues,
        if (import_stats.issues == 1) "" else "s",
        import_stats.pulls,
        if (import_stats.pulls == 1) "" else "s",
        import_stats.comments,
        if (import_stats.comments == 1) "" else "s",
        export_result.exported,
        if (export_result.exported == 1) "" else "s",
    });

    if (options.git_sync and !options.dry_run) {
        try sync_mod.syncPush(allocator, options.remote);
    }
}

fn loadState(allocator: Allocator, repo: repo_mod.Repo, project: ProjectRef) !SyncState {
    const path = try statePath(allocator, repo, project);
    defer allocator.free(path);
    const bytes = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer allocator.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch {
        try eprint("gt gitlab sync: sync state {s} is not valid JSON\n", .{path});
        return CliError.UserError;
    };
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => {
            try eprint("gt gitlab sync: sync state {s} must contain a JSON object\n", .{path});
            return CliError.UserError;
        },
    };
    return .{ .last_export_ordinal = common.jsonInteger(root.get("last_export_ordinal")) orelse 0 };
}

fn saveState(allocator: Allocator, repo: repo_mod.Repo, project: ProjectRef, state: SyncState) !void {
    const path = try statePath(allocator, repo, project);
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

pub fn gitlabMapPath(allocator: Allocator, repo: repo_mod.Repo, project: ProjectRef) ![]u8 {
    const dir = try gitlabSyncDir(allocator, repo, project);
    defer allocator.free(dir);
    return try std.fs.path.join(allocator, &.{ dir, "map.jsonl" });
}

fn statePath(allocator: Allocator, repo: repo_mod.Repo, project: ProjectRef) ![]u8 {
    const dir = try gitlabSyncDir(allocator, repo, project);
    defer allocator.free(dir);
    return try std.fs.path.join(allocator, &.{ dir, "sync-state.json" });
}

fn gitlabSyncDir(allocator: Allocator, repo: repo_mod.Repo, project: ProjectRef) ![]u8 {
    const project_segment = try util.sanitizeRefSegment(allocator, project.path);
    defer allocator.free(project_segment);
    return try std.fs.path.join(allocator, &.{ repo.gitomi_dir, "gitlab", project_segment });
}
