const std = @import("std");
const errors = @import("../../errors.zig");
const event_mod = @import("../../event.zig");
const EventWriter = @import("../../event_writer.zig").EventWriter;
const git = @import("../../git.zig");
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
const bridge_publish_attempts: usize = 3;

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
    export_enabled: bool = true,
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
    var export_enabled = true;
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
        } else if (std.mem.eql(u8, arg, "--import-only") or std.mem.eql(u8, arg, "--no-export")) {
            export_enabled = false;
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
        .export_enabled = export_enabled,
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
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        runSyncOnceAttempt(allocator, options) catch |err| switch (err) {
            error.RemoteRejected => {
                if (attempt + 1 >= bridge_publish_attempts) {
                    try eprint("gt github sync: remote import bot inbox kept advancing; retry later after `gt sync --pull-only`\n", .{});
                    return CliError.GitFailed;
                }
                try eprint("gt github sync: remote import bot inbox advanced during sync; retrying ({d}/{d})\n", .{ attempt + 2, bridge_publish_attempts });
                continue;
            },
            else => return err,
        };
        return;
    }
}

fn runSyncOnceAttempt(allocator: Allocator, options: Options) !void {
    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();

    if (options.git_sync and !options.dry_run) {
        try sync_mod.syncPull(allocator, options.remote);
    }
    try index.ensureIndex(allocator, repo);

    const map_path = if (options.map_file) |path| try allocator.dupe(u8, path) else try githubMapPath(allocator, repo, options.repo);
    defer allocator.free(map_path);
    var map_snapshot = try MapFileSnapshot.capture(allocator, map_path);
    defer map_snapshot.deinit(allocator);

    const bot_inbox_ref = try importBotInboxRef(allocator, options.bot_principal, options.bot_device);
    defer allocator.free(bot_inbox_ref);
    const bot_base_oid = try git.resolveOptionalRef(allocator, bot_inbox_ref);
    defer if (bot_base_oid) |oid| allocator.free(oid);

    const client = GitHubClient{
        .allocator = allocator,
        .api_url = options.api_url,
        .repo = options.repo,
        .token = options.token,
        .dry_run = options.dry_run,
        .use_gh = options.use_gh,
    };
    if (!options.dry_run) {
        try eprint("gt github sync: preparing delegated import actor {s}/{s}\n", .{ options.bot_principal, options.bot_device });
        try importer.ensureImportDelegation(allocator, options.bot_principal, options.bot_device);
    }
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
    if (options.git_sync and !options.dry_run) {
        try publishGitomiBridgeRefs(allocator, options.remote, bot_inbox_ref, bot_base_oid, map_path, &map_snapshot);
    }

    var export_result = exporter.ExportResult{};
    defer export_result.deinit(allocator);
    if (options.export_enabled) {
        var state = try loadState(allocator, repo, options.repo);
        export_result = try exporter.exportToGithub(allocator, .{
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
            .mode = options.mode,
        });
        if (!options.dry_run and export_result.alias_mappings.items.len != 0) {
            if (options.git_sync) {
                try publishExportAliasMappings(allocator, options, bot_inbox_ref, export_result.alias_mappings.items);
            } else {
                _ = try writeExportAliasEvents(allocator, options, export_result.alias_mappings.items);
            }
        }
        if (export_result.max_ordinal > state.last_export_ordinal) {
            state.last_export_ordinal = export_result.max_ordinal;
            if (!options.dry_run) try saveState(allocator, repo, options.repo, state);
        }
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
}

fn publishGitomiBridgeRefs(
    allocator: Allocator,
    remote: []const u8,
    bot_inbox_ref: []const u8,
    bot_base_oid: ?[]const u8,
    map_path: []const u8,
    map_snapshot: *const MapFileSnapshot,
) !void {
    try sync_mod.syncPush(allocator, remote);
    sync_mod.syncPushInboxRef(allocator, remote, bot_inbox_ref) catch |err| switch (err) {
        error.RemoteRejected => {
            try eprint("gt github sync: abandoning unpublished local {s} after remote fast-forward race\n", .{bot_inbox_ref});
            try map_snapshot.restore(allocator, map_path);
            try resetLocalRefTo(allocator, bot_inbox_ref, bot_base_oid);
            return err;
        },
        else => return err,
    };
}

fn publishExportAliasMappings(
    allocator: Allocator,
    options: Options,
    bot_inbox_ref: []const u8,
    mappings: []const exporter.ExportAliasMapping,
) !void {
    const bot_base_oid = try git.resolveOptionalRef(allocator, bot_inbox_ref);
    defer if (bot_base_oid) |oid| allocator.free(oid);

    const written = try writeExportAliasEvents(allocator, options, mappings);
    if (written == 0) return;

    sync_mod.syncPushInboxRef(allocator, options.remote, bot_inbox_ref) catch |err| switch (err) {
        error.RemoteRejected => {
            try eprint("gt github sync: abandoning unpublished export aliases after remote fast-forward race\n", .{});
            try resetLocalRefTo(allocator, bot_inbox_ref, bot_base_oid);
            return err;
        },
        else => return err,
    };
}

fn writeExportAliasEvents(
    allocator: Allocator,
    options: Options,
    mappings: []const exporter.ExportAliasMapping,
) !usize {
    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();
    try index.ensureIndex(allocator, repo);

    var db = try index.SqliteDb.open(allocator, repo.index_path, index.sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    var writer = try EventWriter.initForActor(allocator, "gt github sync", options.bot_principal, options.bot_device);
    defer writer.deinit();

    var written: usize = 0;
    for (mappings) |mapping| {
        if (mapping.number <= 0) continue;
        const kind = exportAliasKindName(mapping.kind);
        if (try exportAliasExists(&db, kind, mapping.object_id, mapping.number)) continue;

        const number_u64: u64 = @intCast(mapping.number);
        const event_uuid = try util.newUuidV7(allocator);
        defer allocator.free(event_uuid);
        const idem = try util.newUuidV7(allocator);
        defer allocator.free(idem);
        const occurred_at = try util.rfc3339Now(allocator);
        defer allocator.free(occurred_at);

        const body = switch (mapping.kind) {
            .issue => try event_mod.buildIssueLegacyAliasJson(
                allocator,
                writer.cfg,
                writer.nextSeq(),
                mapping.object_id,
                event_uuid,
                idem,
                occurred_at,
                writer.stagedEventParents(),
                .{ .github_issue_number = number_u64 },
            ),
            .pull => try event_mod.buildPullLegacyAliasJson(
                allocator,
                writer.cfg,
                writer.nextSeq(),
                mapping.object_id,
                event_uuid,
                idem,
                occurred_at,
                writer.stagedEventParents(),
                .{ .github_pull_number = number_u64 },
            ),
        };
        defer allocator.free(body);

        var object_ref_buf: [util.short_object_ref_len]u8 = undefined;
        const object_ref = util.shortObjectRef(&object_ref_buf, mapping.object_id);
        const subject = try std.fmt.allocPrint(allocator, "{s}.updated #{s} GitHub #{d} alias", .{ kind, object_ref, mapping.number });
        defer allocator.free(subject);
        const commit = try writer.stage("gt github sync", subject, body);
        allocator.free(commit);
        written += 1;
    }

    try writer.commitStaged();
    return written;
}

fn exportAliasExists(db: *index.SqliteDb, kind: []const u8, object_id: []const u8, number: i64) !bool {
    var stmt = try db.prepare(
        \\SELECT 1
        \\FROM legacy_aliases
        \\WHERE provider = 'github'
        \\  AND object_kind = ?
        \\  AND object_id = ?
        \\  AND number = ?
        \\LIMIT 1
    );
    defer stmt.deinit();
    try stmt.bindText(1, kind);
    try stmt.bindText(2, object_id);
    try stmt.bindInt64(3, number);
    return try stmt.step();
}

fn exportAliasKindName(kind: exporter.ExportAliasKind) []const u8 {
    return switch (kind) {
        .issue => "issue",
        .pull => "pull",
    };
}

fn importBotInboxRef(allocator: Allocator, principal: []const u8, device: []const u8) ![]u8 {
    const checked_principal = try util.checkedRefSegment(allocator, principal, "principal");
    defer allocator.free(checked_principal);
    const checked_device = try util.checkedRefSegment(allocator, device, "device");
    defer allocator.free(checked_device);
    return try std.fmt.allocPrint(allocator, "refs/gitomi/inbox/{s}/{s}", .{ checked_principal, checked_device });
}

fn resetLocalRefTo(allocator: Allocator, ref: []const u8, oid: ?[]const u8) !void {
    if (oid) |value| {
        const updated = try git.gitChecked(allocator, &.{ "update-ref", ref, value });
        allocator.free(updated);
        return;
    }

    const existing = try git.resolveOptionalRef(allocator, ref);
    defer if (existing) |value| allocator.free(value);
    if (existing == null) return;
    const deleted = try git.gitChecked(allocator, &.{ "update-ref", "-d", ref });
    allocator.free(deleted);
}

const MapFileSnapshot = struct {
    bytes: ?[]u8 = null,

    fn capture(allocator: Allocator, path: []const u8) !MapFileSnapshot {
        const bytes = std.fs.cwd().readFileAlloc(allocator, path, 8 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => return .{},
            else => return err,
        };
        return .{ .bytes = bytes };
    }

    fn deinit(self: *MapFileSnapshot, allocator: Allocator) void {
        if (self.bytes) |bytes| allocator.free(bytes);
        self.bytes = null;
    }

    fn restore(self: MapFileSnapshot, allocator: Allocator, path: []const u8) !void {
        if (self.bytes) |bytes| {
            if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);
            try writeFileAtomic(allocator, path, bytes);
            return;
        }
        std.fs.cwd().deleteFile(path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
};

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
