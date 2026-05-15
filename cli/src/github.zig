const std = @import("std");
const errors = @import("errors.zig");
const event_mod = @import("event.zig");
const event_writer_mod = @import("event_writer.zig");
const git = @import("git.zig");
const index = @import("index.zig");
const io = @import("io.zig");
const json_writer = @import("json_writer.zig");
const repo_mod = @import("repo.zig");
const util = @import("util.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const EventWriter = event_writer_mod.EventWriter;
const appendJsonFieldBool = json_writer.appendJsonFieldBool;
const appendJsonFieldString = json_writer.appendJsonFieldString;
const appendJsonFieldStringArray = json_writer.appendJsonFieldStringArray;
const appendJsonString = json_writer.appendJsonString;
const out = io.out;
const eprint = io.eprint;

const import_bot_principal = "import-bot";
const import_bot_device = "github";
const github_import_capability = "github.import";
const github_import_scope = "github:*";
const default_api_url = "https://api.github.com";
const max_github_json = 32 * 1024 * 1024;
const gh_current_repo = RepoSlug{
    .owner = "{owner}",
    .name = "{repo}",
    .slug = "{owner}/{repo}",
};

pub fn cmdGithub(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try eprint("gt github: expected subcommand 'import' or 'export'\n", .{});
        return CliError.UserError;
    }

    if (std.mem.eql(u8, args[0], "import")) {
        try cmdImport(allocator, args[1..]);
        return;
    }
    if (std.mem.eql(u8, args[0], "export")) {
        try cmdExport(allocator, args[1..]);
        return;
    }

    try eprint("gt github: expected subcommand 'import' or 'export'\n", .{});
    return CliError.UserError;
}

const RepoSlug = struct {
    owner: []const u8,
    name: []const u8,
    slug: []const u8,
};

fn parseRepoSlug(raw: []const u8) !RepoSlug {
    const slash = std.mem.indexOfScalar(u8, raw, '/') orelse {
        try eprint("gt github: --repo must be OWNER/REPO\n", .{});
        return CliError.InvalidArgument;
    };
    if (slash == 0 or slash + 1 >= raw.len) {
        try eprint("gt github: --repo must be OWNER/REPO\n", .{});
        return CliError.InvalidArgument;
    }
    return .{ .owner = raw[0..slash], .name = raw[slash + 1 ..], .slug = raw };
}

const GitHubClient = struct {
    allocator: Allocator,
    api_url: []const u8,
    repo: RepoSlug,
    token: ?[]const u8,
    use_gh: bool = false,
    dry_run: bool = false,

    fn request(self: GitHubClient, method: []const u8, path: []const u8, body: ?[]const u8) ![]u8 {
        if (self.use_gh) return self.requestGh(method, path, body);

        if (self.dry_run) {
            try out("{s} {s}", .{ method, path });
            if (body) |bytes| try out(" {s}", .{bytes});
            try out("\n", .{});
            return self.allocator.dupe(u8, "{}");
        }

        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.api_url, path });
        defer self.allocator.free(url);
        const auth_header = if (self.token) |token|
            try std.fmt.allocPrint(self.allocator, "Authorization: Bearer {s}", .{token})
        else
            null;
        defer if (auth_header) |value| self.allocator.free(value);

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.allocator);
        try argv.appendSlice(self.allocator, &.{
            "curl",
            "-fsSL",
            "-X",
            method,
            "-H",
            "Accept: application/vnd.github+json",
            "-H",
            "X-GitHub-Api-Version: 2022-11-28",
            "-H",
            "User-Agent: gitomi/0.1.0",
        });
        if (auth_header) |value| {
            try argv.append(self.allocator, "-H");
            try argv.append(self.allocator, value);
        }
        if (body != null) {
            try argv.append(self.allocator, "-H");
            try argv.append(self.allocator, "Content-Type: application/json");
            try argv.append(self.allocator, "--data-binary");
            try argv.append(self.allocator, "@-");
        }
        try argv.append(self.allocator, url);

        var result = try git.runCommand(self.allocator, argv.items, body, max_github_json);
        if (result.exitCode() == 0) {
            const stdout = result.stdout;
            self.allocator.free(result.stderr);
            return stdout;
        }

        defer result.deinit();
        const stderr = std.mem.trim(u8, result.stderr, " \t\r\n");
        if (stderr.len != 0) {
            try eprint("gt github: GitHub API request failed: {s}\n", .{stderr});
        } else {
            try eprint("gt github: GitHub API request failed\n", .{});
        }
        return CliError.UserError;
    }

    fn requestGh(self: GitHubClient, method: []const u8, path: []const u8, body: ?[]const u8) ![]u8 {
        const endpoint = std.mem.trimLeft(u8, path, "/");
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.allocator);
        try argv.appendSlice(self.allocator, &.{
            "gh",
            "api",
            "--method",
            method,
            "-H",
            "Accept: application/vnd.github+json",
            "-H",
            "X-GitHub-Api-Version: 2022-11-28",
        });
        if (body != null) {
            try argv.append(self.allocator, "--input");
            try argv.append(self.allocator, "-");
        }
        try argv.append(self.allocator, endpoint);

        var result = try git.runCommand(self.allocator, argv.items, body, max_github_json);
        if (result.exitCode() == 0) {
            const stdout = result.stdout;
            self.allocator.free(result.stderr);
            return stdout;
        }

        defer result.deinit();
        const stderr = std.mem.trim(u8, result.stderr, " \t\r\n");
        if (stderr.len != 0) {
            try eprint("gt github: gh api request failed: {s}\n", .{stderr});
        } else {
            try eprint("gt github: gh api request failed\n", .{});
        }
        return CliError.UserError;
    }

    fn repoPath(self: GitHubClient, allocator: Allocator, suffix: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "/repos/{s}{s}", .{ self.repo.slug, suffix });
    }
};

const ImportOptions = struct {
    repo: ?RepoSlug = null,
    api_url: []const u8 = default_api_url,
    token_arg: ?[]const u8 = null,
    from_file: ?[]const u8 = null,
    include_comments: bool = true,
    include_projects: bool = true,
    bot_principal: []const u8 = import_bot_principal,
    bot_device: []const u8 = import_bot_device,
    max_pages: usize = 10,
    use_gh: bool = false,
};

fn cmdImport(allocator: Allocator, args: []const []const u8) !void {
    var options = ImportOptions{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--repo")) {
            options.repo = try parseRepoSlug(try util.requireValue(args, &i, "--repo"));
        } else if (std.mem.eql(u8, arg, "--api-url")) {
            options.api_url = try util.requireValue(args, &i, "--api-url");
        } else if (std.mem.eql(u8, arg, "--token")) {
            options.token_arg = try util.requireValue(args, &i, "--token");
        } else if (std.mem.eql(u8, arg, "--from-file")) {
            options.from_file = try util.requireValue(args, &i, "--from-file");
        } else if (std.mem.eql(u8, arg, "--no-comments")) {
            options.include_comments = false;
        } else if (std.mem.eql(u8, arg, "--no-projects")) {
            options.include_projects = false;
        } else if (std.mem.eql(u8, arg, "--import-bot")) {
            options.bot_principal = try util.requireValue(args, &i, "--import-bot");
        } else if (std.mem.eql(u8, arg, "--device")) {
            options.bot_device = try util.requireValue(args, &i, "--device");
        } else if (std.mem.eql(u8, arg, "--max-pages")) {
            options.max_pages = std.fmt.parseUnsigned(usize, try util.requireValue(args, &i, "--max-pages"), 10) catch {
                try eprint("gt github import: --max-pages must be a positive integer\n", .{});
                return CliError.InvalidArgument;
            };
        } else {
            try eprint("gt github import: unknown option '{s}'\n", .{arg});
            return CliError.UserError;
        }
    }

    if (options.repo == null and options.from_file == null) {
        if (options.token_arg == null and std.mem.eql(u8, options.api_url, default_api_url)) {
            options.repo = gh_current_repo;
            options.use_gh = true;
        } else {
            try eprint("gt github import: --repo or --from-file is required\n", .{});
            return CliError.MissingArgument;
        }
    }

    try eprint("gt github import: preparing delegated import actor {s}/{s}\n", .{ options.bot_principal, options.bot_device });
    try ensureImportDelegation(allocator, options.bot_principal, options.bot_device);

    var token_owned: ?[]u8 = null;
    defer if (token_owned) |value| allocator.free(value);
    const token: ?[]const u8 = if (options.use_gh) null else options.token_arg orelse blk: {
        token_owned = githubTokenFromEnv(allocator) catch null;
        break :blk token_owned;
    };

    var stats = ImportStats{};
    if (options.from_file) |path| {
        try eprint("gt github import: reading fixture {s}\n", .{path});
        try importFromFile(allocator, path, options, &stats);
    } else {
        const client = GitHubClient{
            .allocator = allocator,
            .api_url = options.api_url,
            .repo = options.repo.?,
            .token = token,
            .use_gh = options.use_gh,
        };
        if (options.use_gh) {
            try eprint("gt github import: using local gh current-repository context\n", .{});
        } else {
            try eprint("gt github import: using GitHub API repository {s}\n", .{client.repo.slug});
        }
        try importFromApi(allocator, client, options, &stats);
    }

    try out("github import: {d} issue{s}, {d} pull{s}, {d} comment{s}, {d} project card{s}\n", .{
        stats.issues,
        if (stats.issues == 1) "" else "s",
        stats.pulls,
        if (stats.pulls == 1) "" else "s",
        stats.comments,
        if (stats.comments == 1) "" else "s",
        stats.project_cards,
        if (stats.project_cards == 1) "" else "s",
    });
}

const ImportStats = struct {
    issues: usize = 0,
    pulls: usize = 0,
    comments: usize = 0,
    project_cards: usize = 0,
};

const ImportedObject = struct {
    id: []u8,
    is_new: bool,
};

const ImportedCommentRef = struct {
    id: []u8,
    event_hash: []u8,

    fn deinit(self: ImportedCommentRef, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.event_hash);
    }
};

fn githubTokenFromEnv(allocator: Allocator) !?[]u8 {
    return std.process.getEnvVarOwned(allocator, "GITHUB_TOKEN") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => std.process.getEnvVarOwned(allocator, "GH_TOKEN") catch |fallback_err| switch (fallback_err) {
            error.EnvironmentVariableNotFound => null,
            else => return fallback_err,
        },
        else => return err,
    };
}

fn ensureImportDelegation(allocator: Allocator, principal: []const u8, device: []const u8) !void {
    const checked_principal = try util.checkedRefSegment(allocator, principal, "principal");
    defer allocator.free(checked_principal);
    const checked_device = try util.checkedRefSegment(allocator, device, "device");
    defer allocator.free(checked_device);

    var writer = try EventWriter.init(allocator, "gt github import");
    defer writer.deinit();

    const role = try index.roleForPrincipal(allocator, writer.repo, writer.cfg.principal);
    defer if (role) |value| allocator.free(value);
    if (role == null or !roleAtLeastMaintainer(role.?)) {
        try eprint("gt github import: {s} must be maintainer or owner to delegate GitHub import authority\n", .{writer.cfg.principal});
        return CliError.Unauthorized;
    }

    if (!(try index.isIdentityDeviceActive(allocator, writer.repo, writer.cfg.principal, writer.cfg.device))) {
        try eprint("gt github import: configured actor {s}/{s} is not an active device\n", .{ writer.cfg.principal, writer.cfg.device });
        return CliError.Unauthorized;
    }

    var signing_key = try repo_mod.configuredSigningKey(allocator);
    defer signing_key.deinit();
    if (std.mem.trim(u8, signing_key.public_key, " \t\r\n").len == 0) {
        try eprint("gt github import: signing public key is required to delegate import-bot; configure Git signing with user.signingkey\n", .{});
        return CliError.MissingArgument;
    }

    if (try index.hasActiveDelegation(allocator, writer.repo, checked_principal, checked_device, github_import_capability, github_import_scope, signing_key.fingerprint)) {
        return;
    }

    const event_uuid = try util.newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try util.newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try util.rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    const body = try event_mod.buildAclDelegationJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        checked_principal,
        checked_device,
        github_import_capability,
        github_import_scope,
        .{
            .scheme = signing_key.scheme,
            .public_key = signing_key.public_key,
            .fingerprint = signing_key.fingerprint,
        },
        event_uuid,
        idem,
        occurred_at,
        writer.eventParents(),
        true,
    );
    defer allocator.free(body);
    const subject = try std.fmt.allocPrint(allocator, "acl.delegation_granted {s}/{s} {s}", .{ checked_principal, checked_device, github_import_capability });
    defer allocator.free(subject);
    const commit = try writer.write("gt github import", subject, body);
    allocator.free(commit);
    try index.ensureIndex(allocator, writer.repo);
}

fn roleAtLeastMaintainer(role: []const u8) bool {
    return std.mem.eql(u8, role, "maintainer") or std.mem.eql(u8, role, "owner");
}

fn importFromFile(allocator: Allocator, path: []const u8, options: ImportOptions, stats: *ImportStats) !void {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, max_github_json);
    defer allocator.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch {
        try eprint("gt github import: --from-file must contain JSON\n", .{});
        return CliError.InvalidArgument;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => {
            try eprint("gt github import: --from-file must contain a JSON object\n", .{});
            return CliError.InvalidArgument;
        },
    };

    if (jsonArray(root.get("issues"))) |issues| {
        try eprint("gt github import: importing {d} fixture issue record{s}\n", .{ issues.items.len, if (issues.items.len == 1) "" else "s" });
        for (issues.items) |item| {
            if (item != .object) continue;
            if (item.object.get("pull_request") != null) continue;
            const number = jsonInteger(item.object.get("number")) orelse continue;
            const projects = try githubFixtureProjects(allocator, root, "issue", number, item.object);
            defer freeProjectPlacements(allocator, projects);
            const issue_result = try importIssueObject(allocator, item.object, projects, options, stats);
            defer if (issue_result) |result| allocator.free(result.id);
            if (issue_result) |result| {
                if (result.is_new) try importFixtureComments(allocator, root, "issue", item.object, result.id, options, stats);
            }
        }
    }
    if (jsonArray(root.get("pulls"))) |pulls| {
        try eprint("gt github import: importing {d} fixture pull record{s}\n", .{ pulls.items.len, if (pulls.items.len == 1) "" else "s" });
        for (pulls.items) |item| {
            if (item != .object) continue;
            const pull_result = try importPullObject(allocator, item.object, options, stats);
            defer if (pull_result) |result| allocator.free(result.id);
            if (pull_result) |result| {
                if (result.is_new) try importFixtureComments(allocator, root, "pull", item.object, result.id, options, stats);
            }
        }
    }
}

fn importFixtureComments(
    allocator: Allocator,
    root: std.json.ObjectMap,
    parent_kind: []const u8,
    object: std.json.ObjectMap,
    parent_id: []const u8,
    options: ImportOptions,
    stats: *ImportStats,
) !void {
    if (!options.include_comments) return;
    const number = jsonInteger(object.get("number")) orelse return;
    const comments_root = switch (root.get("comments") orelse return) {
        .object => |map| map,
        else => return,
    };
    const key = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ parent_kind, number });
    defer allocator.free(key);
    const comments = jsonArray(comments_root.get(key)) orelse return;
    try eprint("gt github import: importing {d} fixture comment{s} for {s} #{d}\n", .{ comments.items.len, if (comments.items.len == 1) "" else "s", parent_kind, number });
    try importCommentsArray(allocator, parent_kind, parent_id, comments, options, stats);
}

fn importFromApi(allocator: Allocator, client: GitHubClient, options: ImportOptions, stats: *ImportStats) !void {
    var page: usize = 1;
    while (page <= options.max_pages) : (page += 1) {
        try eprint("gt github import: fetching issues page {d}\n", .{page});
        const suffix = try std.fmt.allocPrint(allocator, "/issues?state=all&per_page=100&page={d}", .{page});
        defer allocator.free(suffix);
        const path = try client.repoPath(allocator, suffix);
        defer allocator.free(path);
        const raw = try client.request("GET", path, null);
        defer allocator.free(raw);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
        defer parsed.deinit();
        const issues = switch (parsed.value) {
            .array => |array| array,
            else => break,
        };
        try eprint("gt github import: issues page {d}: {d} record{s}\n", .{ page, issues.items.len, if (issues.items.len == 1) "" else "s" });
        if (issues.items.len == 0) break;
        for (issues.items) |item| {
            if (item != .object) continue;
            if (item.object.get("pull_request") != null) continue;
            const issue_result = try importIssueObject(allocator, item.object, &.{}, options, stats);
            defer if (issue_result) |result| allocator.free(result.id);
            if (issue_result) |result| {
                if (result.is_new) try importApiComments(allocator, client, "issue", jsonInteger(item.object.get("number")) orelse continue, result.id, options, stats);
            }
        }
        if (issues.items.len < 100) break;
    }

    page = 1;
    while (page <= options.max_pages) : (page += 1) {
        try eprint("gt github import: fetching pulls page {d}\n", .{page});
        const suffix = try std.fmt.allocPrint(allocator, "/pulls?state=all&per_page=100&page={d}", .{page});
        defer allocator.free(suffix);
        const path = try client.repoPath(allocator, suffix);
        defer allocator.free(path);
        const raw = try client.request("GET", path, null);
        defer allocator.free(raw);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
        defer parsed.deinit();
        const pulls = switch (parsed.value) {
            .array => |array| array,
            else => break,
        };
        try eprint("gt github import: pulls page {d}: {d} record{s}\n", .{ page, pulls.items.len, if (pulls.items.len == 1) "" else "s" });
        if (pulls.items.len == 0) break;
        for (pulls.items) |item| {
            if (item != .object) continue;
            const pull_result = try importPullObject(allocator, item.object, options, stats);
            defer if (pull_result) |result| allocator.free(result.id);
            if (pull_result) |result| {
                if (result.is_new) try importApiComments(allocator, client, "pull", jsonInteger(item.object.get("number")) orelse continue, result.id, options, stats);
            }
        }
        if (pulls.items.len < 100) break;
    }

    if (options.include_projects) {
        importClassicProjects(allocator, client, options, stats) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => try eprint("gt github import: project import skipped: {s}\n", .{@errorName(err)}),
        };
    }
}

fn importApiComments(
    allocator: Allocator,
    client: GitHubClient,
    parent_kind: []const u8,
    number: i64,
    parent_id: []const u8,
    options: ImportOptions,
    stats: *ImportStats,
) !void {
    if (!options.include_comments) return;
    try eprint("gt github import: fetching comments for {s} #{d}\n", .{ parent_kind, number });
    const suffix = try std.fmt.allocPrint(allocator, "/issues/{d}/comments?per_page=100", .{number});
    defer allocator.free(suffix);
    const path = try client.repoPath(allocator, suffix);
    defer allocator.free(path);
    const raw = try client.request("GET", path, null);
    defer allocator.free(raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const comments = switch (parsed.value) {
        .array => |array| array,
        else => return,
    };
    try eprint("gt github import: {s} #{d}: {d} comment{s}\n", .{ parent_kind, number, comments.items.len, if (comments.items.len == 1) "" else "s" });
    try importCommentsArray(allocator, parent_kind, parent_id, comments, options, stats);
}

fn importClassicProjects(allocator: Allocator, client: GitHubClient, options: ImportOptions, stats: *ImportStats) !void {
    try eprint("gt github import: fetching classic project boards\n", .{});
    const path = try client.repoPath(allocator, "/projects?per_page=100");
    defer allocator.free(path);
    const raw = try client.request("GET", path, null);
    defer allocator.free(raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const projects = switch (parsed.value) {
        .array => |array| array,
        else => return,
    };
    for (projects.items) |project_value| {
        if (project_value != .object) continue;
        const project_id = jsonInteger(project_value.object.get("id")) orelse continue;
        const project_name = event_mod.jsonString(project_value.object.get("name")) orelse
            event_mod.jsonString(project_value.object.get("title")) orelse
            continue;
        try importClassicProjectColumns(allocator, client, options, stats, project_id, project_name);
    }
}

fn importClassicProjectColumns(
    allocator: Allocator,
    client: GitHubClient,
    options: ImportOptions,
    stats: *ImportStats,
    project_id: i64,
    project_name: []const u8,
) !void {
    const path = try std.fmt.allocPrint(allocator, "/projects/{d}/columns?per_page=100", .{project_id});
    defer allocator.free(path);
    const raw = try client.request("GET", path, null);
    defer allocator.free(raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const columns = switch (parsed.value) {
        .array => |array| array,
        else => return,
    };
    for (columns.items) |column_value| {
        if (column_value != .object) continue;
        const column_id = jsonInteger(column_value.object.get("id")) orelse continue;
        const column_name = event_mod.jsonString(column_value.object.get("name")) orelse "";
        try importClassicProjectCards(allocator, client, options, stats, project_name, column_id, column_name);
    }
}

fn importClassicProjectCards(
    allocator: Allocator,
    client: GitHubClient,
    options: ImportOptions,
    stats: *ImportStats,
    project_name: []const u8,
    column_id: i64,
    column_name: []const u8,
) !void {
    const path = try std.fmt.allocPrint(allocator, "/projects/columns/{d}/cards?per_page=100", .{column_id});
    defer allocator.free(path);
    const raw = try client.request("GET", path, null);
    defer allocator.free(raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const cards = switch (parsed.value) {
        .array => |array| array,
        else => return,
    };

    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();
    try index.ensureIndex(allocator, repo);
    var db = try index.SqliteDb.open(allocator, repo.index_path, index.sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    for (cards.items) |card_value| {
        if (card_value != .object) continue;
        const content_url = event_mod.jsonString(card_value.object.get("content_url")) orelse continue;
        const number = issueNumberFromContentUrl(content_url) orelse continue;
        const issue_id = (try index.lookupLegacyGithubObjectId(allocator, repo, "issue", number)) orelse continue;
        defer allocator.free(issue_id);
        if (try importedIssueProjectExists(&db, issue_id, project_name, column_name)) continue;
        const occurred_at = try githubTimestampOrNow(allocator, firstJsonValue(card_value.object.get("created_at"), card_value.object.get("updated_at")));
        defer allocator.free(occurred_at);
        const project = try githubSizedString(allocator, project_name, "", git.max_payload_atom_bytes);
        defer allocator.free(project);
        const column = try githubSizedString(allocator, column_name, "", git.max_payload_atom_bytes);
        defer allocator.free(column);
        try writeImportedIssueProjectAdded(allocator, options, issue_id, occurred_at, project, column);
        stats.project_cards += 1;
    }
}

fn importedIssueProjectExists(db: *index.SqliteDb, issue_id: []const u8, project: []const u8, column: []const u8) !bool {
    var stmt = try db.prepare(
        \\SELECT 1
        \\FROM issue_projects
        \\WHERE issue_id = ?
        \\  AND project = ?
        \\  AND column_name = ?
        \\LIMIT 1
    );
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    try stmt.bindText(2, project);
    try stmt.bindText(3, column);
    return try stmt.step();
}

fn issueNumberFromContentUrl(url: []const u8) ?i64 {
    const marker = "/issues/";
    const idx = std.mem.lastIndexOf(u8, url, marker) orelse return null;
    const raw = url[idx + marker.len ..];
    if (raw.len == 0) return null;
    return std.fmt.parseInt(i64, raw, 10) catch null;
}

fn importIssueObject(
    allocator: Allocator,
    issue: std.json.ObjectMap,
    projects: []const event_mod.IssueProjectPlacement,
    options: ImportOptions,
    stats: *ImportStats,
) !?ImportedObject {
    const number = jsonInteger(issue.get("number")) orelse return null;
    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();
    if (try index.lookupLegacyGithubObjectId(allocator, repo, "issue", number)) |existing| {
        try eprint("gt github import: issue #{d} already imported; skipping\n", .{number});
        return .{ .id = existing, .is_new = false };
    }

    const title = try githubSizedString(allocator, event_mod.jsonString(issue.get("title")), "(untitled)", git.max_payload_title_bytes);
    defer allocator.free(title);
    const body = try githubSizedString(allocator, event_mod.jsonString(issue.get("body")), "", git.max_payload_text_bytes);
    defer allocator.free(body);
    const occurred_at = try githubTimestampOrNow(allocator, issue.get("created_at"));
    defer allocator.free(occurred_at);

    const labels = try githubIssueLabels(allocator, issue);
    defer freeStringList(allocator, labels);
    const assignees = try githubNamedArray(allocator, issue.get("assignees"), "login");
    defer freeStringList(allocator, assignees);
    const source_author = try githubSizedString(allocator, githubAuthorLogin(issue), "", git.max_payload_atom_bytes);
    defer allocator.free(source_author);
    const milestone = try githubSizedString(allocator, githubMilestoneTitle(issue), "", git.max_payload_atom_bytes);
    defer allocator.free(milestone);

    const issue_id = try util.newUuidV7(allocator);
    errdefer allocator.free(issue_id);
    try eprint("gt github import: importing issue #{d}\n", .{number});
    try writeImportedIssueOpened(allocator, options, issue_id, @intCast(number), occurred_at, title, body, labels, assignees, source_author, milestone, projects);
    stats.issues += 1;

    if (event_mod.jsonString(issue.get("state"))) |state| {
        if (std.mem.eql(u8, state, "closed")) {
            const closed_at = try githubTimestampOrNow(allocator, firstJsonValue(issue.get("closed_at"), issue.get("updated_at")));
            defer allocator.free(closed_at);
            try writeImportedStringEvent(allocator, options, "issue", issue_id, "issue.state_set", "state", "closed", closed_at);
        }
    }

    return .{ .id = issue_id, .is_new = true };
}

fn importPullObject(allocator: Allocator, pull: std.json.ObjectMap, options: ImportOptions, stats: *ImportStats) !?ImportedObject {
    const number = jsonInteger(pull.get("number")) orelse return null;
    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();
    if (try index.lookupLegacyGithubObjectId(allocator, repo, "pull", number)) |existing| {
        try eprint("gt github import: pull #{d} already imported; skipping\n", .{number});
        return .{ .id = existing, .is_new = false };
    }

    const title = try githubSizedString(allocator, event_mod.jsonString(pull.get("title")), "(untitled)", git.max_payload_title_bytes);
    defer allocator.free(title);
    const body = try githubSizedString(allocator, event_mod.jsonString(pull.get("body")), "", git.max_payload_text_bytes);
    defer allocator.free(body);
    const base_ref = try githubSizedString(allocator, nestedString(pull, "base", "ref"), "main", git.max_payload_ref_bytes);
    defer allocator.free(base_ref);
    const head_ref = try githubSizedString(allocator, nestedString(pull, "head", "ref"), "unknown", git.max_payload_ref_bytes);
    defer allocator.free(head_ref);
    const draft = jsonBool(pull.get("draft")) orelse false;
    const occurred_at = try githubTimestampOrNow(allocator, pull.get("created_at"));
    defer allocator.free(occurred_at);
    const source_author = try githubSizedString(allocator, githubAuthorLogin(pull), "", git.max_payload_atom_bytes);
    defer allocator.free(source_author);
    const labels = try githubIssueLabels(allocator, pull);
    defer freeStringList(allocator, labels);
    const assignees = try githubNamedArray(allocator, pull.get("assignees"), "login");
    defer freeStringList(allocator, assignees);
    const reviewers = try githubPullReviewers(allocator, pull);
    defer freeStringList(allocator, reviewers);

    const pull_id = try util.newUuidV7(allocator);
    errdefer allocator.free(pull_id);
    try eprint("gt github import: importing pull #{d}\n", .{number});
    try writeImportedPullOpened(
        allocator,
        options,
        pull_id,
        @intCast(number),
        occurred_at,
        title,
        body,
        base_ref,
        head_ref,
        draft,
        .{
            .source_author = if (source_author.len == 0) null else source_author,
            .labels = labels,
            .assignees = assignees,
            .reviewers = reviewers,
            .commit_count = jsonOptionalUnsigned(pull.get("commits")),
            .changed_files = jsonOptionalUnsigned(pull.get("changed_files")),
            .additions = jsonOptionalUnsigned(pull.get("additions")),
            .deletions = jsonOptionalUnsigned(pull.get("deletions")),
        },
    );
    stats.pulls += 1;

    if (event_mod.jsonString(pull.get("state"))) |state| {
        if (std.mem.eql(u8, state, "closed")) {
            if (event_mod.jsonString(pull.get("merged_at"))) |merged_at| {
                if (merged_at.len != 0) {
                    try writeImportedPullMerged(allocator, options, pull_id, merged_at, event_mod.jsonString(pull.get("merge_commit_sha")) orelse "", null);
                    return .{ .id = pull_id, .is_new = true };
                }
            }
            const closed_at = try githubTimestampOrNow(allocator, firstJsonValue(pull.get("closed_at"), pull.get("updated_at")));
            defer allocator.free(closed_at);
            try writeImportedStringEvent(allocator, options, "pull", pull_id, "pull.state_set", "state", "closed", closed_at);
        }
    }

    return .{ .id = pull_id, .is_new = true };
}

fn importCommentsArray(
    allocator: Allocator,
    parent_kind: []const u8,
    parent_id: []const u8,
    comments: std.json.Array,
    options: ImportOptions,
    stats: *ImportStats,
) !void {
    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();
    try index.ensureIndex(allocator, repo);
    var db = try index.SqliteDb.open(allocator, repo.index_path, index.sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    var comment_refs = std.AutoHashMap(i64, ImportedCommentRef).init(allocator);
    defer {
        var values = comment_refs.valueIterator();
        while (values.next()) |value| value.deinit(allocator);
        comment_refs.deinit();
    }

    var imported: usize = 0;
    for (comments.items) |item| {
        if (item != .object) continue;
        const body = try githubSizedString(allocator, event_mod.jsonString(item.object.get("body")), "", git.max_payload_text_bytes);
        defer allocator.free(body);
        if (std.mem.trim(u8, body, " \t\r\n").len == 0) continue;
        const occurred_at = try githubTimestampOrNow(allocator, item.object.get("created_at"));
        defer allocator.free(occurred_at);
        if (try importedCommentExists(&db, parent_kind, parent_id, occurred_at, body)) continue;
        const source_author = try githubSizedString(allocator, githubAuthorLogin(item.object), "", git.max_payload_atom_bytes);
        defer allocator.free(source_author);
        const reply = try importedCommentReply(allocator, item.object, &comment_refs);
        defer if (reply.parent_id) |value| allocator.free(value);
        defer if (reply.parent_hash) |value| allocator.free(value);
        var written = try writeImportedCommentAdded(
            allocator,
            options,
            parent_kind,
            parent_id,
            occurred_at,
            body,
            source_author,
            reply.parent_id orelse "",
            reply.parent_hash orelse "",
        );
        imported += 1;
        if (jsonInteger(item.object.get("id"))) |github_id| {
            const entry = try comment_refs.getOrPut(github_id);
            if (entry.found_existing) {
                entry.value_ptr.deinit(allocator);
            }
            entry.value_ptr.* = written;
        } else {
            written.deinit(allocator);
        }
        if (imported % 10 == 0) {
            var parent_ref_buf: [util.short_object_ref_len]u8 = undefined;
            try eprint("gt github import: imported {d} new comment{s} for {s} #{s}\n", .{ imported, if (imported == 1) "" else "s", parent_kind, util.shortObjectRef(&parent_ref_buf, parent_id) });
        }
        stats.comments += 1;
    }
    if (comments.items.len != 0 and (imported == 0 or imported % 10 != 0)) {
        var parent_ref_buf: [util.short_object_ref_len]u8 = undefined;
        try eprint("gt github import: imported {d} new comment{s} for {s} #{s}\n", .{ imported, if (imported == 1) "" else "s", parent_kind, util.shortObjectRef(&parent_ref_buf, parent_id) });
    }
}

const ImportedCommentReply = struct {
    parent_id: ?[]u8 = null,
    parent_hash: ?[]u8 = null,
};

fn importedCommentReply(allocator: Allocator, comment: std.json.ObjectMap, refs: *std.AutoHashMap(i64, ImportedCommentRef)) !ImportedCommentReply {
    if (event_mod.jsonString(comment.get("parent_hash"))) |hash| {
        if (hash.len != 0) {
            return .{ .parent_hash = try allocator.dupe(u8, hash) };
        }
    }
    const parent_github_id = jsonInteger(comment.get("in_reply_to_id")) orelse
        jsonInteger(comment.get("reply_to_id")) orelse
        jsonInteger(comment.get("parent_id")) orelse
        return .{};
    const parent = refs.get(parent_github_id) orelse return .{};
    return .{
        .parent_id = try allocator.dupe(u8, parent.id),
        .parent_hash = try allocator.dupe(u8, parent.event_hash),
    };
}

fn importedCommentExists(db: *index.SqliteDb, parent_kind: []const u8, parent_id: []const u8, created_at: []const u8, body: []const u8) !bool {
    var stmt = try db.prepare(
        \\SELECT 1
        \\FROM comments
        \\WHERE parent_kind = ?
        \\  AND parent_id = ?
        \\  AND created_at = ?
        \\  AND body = ?
        \\LIMIT 1
    );
    defer stmt.deinit();
    try stmt.bindText(1, parent_kind);
    try stmt.bindText(2, parent_id);
    try stmt.bindText(3, created_at);
    try stmt.bindText(4, body);
    return try stmt.step();
}

fn writeImportedIssueOpened(
    allocator: Allocator,
    options: ImportOptions,
    issue_id: []const u8,
    number: u64,
    occurred_at: []const u8,
    title: []const u8,
    body_text: []const u8,
    labels: []const []const u8,
    assignees: []const []const u8,
    source_author: []const u8,
    milestone: []const u8,
    projects: []const event_mod.IssueProjectPlacement,
) !void {
    var writer = try EventWriter.initForActor(allocator, "gt github import", options.bot_principal, options.bot_device);
    defer writer.deinit();

    const event_uuid = try util.newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try util.newUuidV7(allocator);
    defer allocator.free(idem);
    const body = try event_mod.buildIssueOpenedJsonWithLegacyAndMetadata(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        issue_id,
        event_uuid,
        idem,
        occurred_at,
        writer.eventParents(),
        title,
        body_text,
        labels,
        assignees,
        .{ .github_issue_number = number },
        .{
            .source_author = if (source_author.len == 0) null else source_author,
            .milestone = if (milestone.len == 0) null else milestone,
            .projects = projects,
        },
    );
    defer allocator.free(body);
    var issue_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const issue_ref = util.shortObjectRef(&issue_ref_buf, issue_id);
    const subject_prefix = try std.fmt.allocPrint(allocator, "issue.opened #{s} GitHub #{d} ", .{ issue_ref, number });
    defer allocator.free(subject_prefix);
    const subject = try githubSubject(allocator, subject_prefix, title);
    defer allocator.free(subject);
    const commit = try writer.write("gt github import", subject, body);
    allocator.free(commit);
}

fn writeImportedPullOpened(
    allocator: Allocator,
    options: ImportOptions,
    pull_id: []const u8,
    number: u64,
    occurred_at: []const u8,
    title: []const u8,
    body_text: []const u8,
    base_ref: []const u8,
    head_ref: []const u8,
    draft: bool,
    metadata: event_mod.PullOpenedMetadata,
) !void {
    var writer = try EventWriter.initForActor(allocator, "gt github import", options.bot_principal, options.bot_device);
    defer writer.deinit();

    const event_uuid = try util.newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try util.newUuidV7(allocator);
    defer allocator.free(idem);
    const body = try event_mod.buildPullOpenedJsonWithLegacyAndMetadata(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        pull_id,
        event_uuid,
        idem,
        occurred_at,
        writer.eventParents(),
        title,
        body_text,
        base_ref,
        head_ref,
        draft,
        .{ .github_pull_number = number },
        metadata,
    );
    defer allocator.free(body);
    var pull_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const pull_ref = util.shortObjectRef(&pull_ref_buf, pull_id);
    const subject_prefix = try std.fmt.allocPrint(allocator, "pull.opened #{s} GitHub #{d} ", .{ pull_ref, number });
    defer allocator.free(subject_prefix);
    const subject = try githubSubject(allocator, subject_prefix, title);
    defer allocator.free(subject);
    const commit = try writer.write("gt github import", subject, body);
    allocator.free(commit);
}

fn writeImportedStringEvent(
    allocator: Allocator,
    options: ImportOptions,
    object_kind: []const u8,
    object_id: []const u8,
    event_type: []const u8,
    payload_key: []const u8,
    payload_value: []const u8,
    occurred_at: []const u8,
) !void {
    var writer = try EventWriter.initForActor(allocator, "gt github import", options.bot_principal, options.bot_device);
    defer writer.deinit();

    const event_uuid = try util.newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try util.newUuidV7(allocator);
    defer allocator.free(idem);
    const body = if (std.mem.eql(u8, object_kind, "issue"))
        try event_mod.buildIssueStringPayloadJson(allocator, writer.cfg, writer.nextSeq(), object_id, event_uuid, idem, occurred_at, writer.eventParents(), event_type, payload_key, payload_value)
    else
        try event_mod.buildPullStringPayloadJson(allocator, writer.cfg, writer.nextSeq(), object_id, event_uuid, idem, occurred_at, writer.eventParents(), event_type, payload_key, payload_value);
    defer allocator.free(body);
    var object_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const object_ref = util.shortObjectRef(&object_ref_buf, object_id);
    const subject = try std.fmt.allocPrint(allocator, "{s} #{s}", .{ event_type, object_ref });
    defer allocator.free(subject);
    const commit = try writer.write("gt github import", subject, body);
    allocator.free(commit);
}

fn writeImportedIssueProjectAdded(
    allocator: Allocator,
    options: ImportOptions,
    issue_id: []const u8,
    occurred_at: []const u8,
    project: []const u8,
    column: []const u8,
) !void {
    var writer = try EventWriter.initForActor(allocator, "gt github import", options.bot_principal, options.bot_device);
    defer writer.deinit();

    const event_uuid = try util.newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try util.newUuidV7(allocator);
    defer allocator.free(idem);
    const body = try event_mod.buildIssueProjectEventJson(allocator, writer.cfg, writer.nextSeq(), issue_id, event_uuid, idem, occurred_at, writer.eventParents(), "issue.project_added", project, column);
    defer allocator.free(body);
    var issue_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const issue_ref = util.shortObjectRef(&issue_ref_buf, issue_id);
    const subject = try std.fmt.allocPrint(allocator, "issue.project_added #{s} {s}", .{ issue_ref, project });
    defer allocator.free(subject);
    const commit = try writer.write("gt github import", subject, body);
    allocator.free(commit);
}

fn writeImportedPullMerged(
    allocator: Allocator,
    options: ImportOptions,
    pull_id: []const u8,
    occurred_at: []const u8,
    merge_oid: []const u8,
    target_oid: ?[]const u8,
) !void {
    var writer = try EventWriter.initForActor(allocator, "gt github import", options.bot_principal, options.bot_device);
    defer writer.deinit();

    const event_uuid = try util.newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try util.newUuidV7(allocator);
    defer allocator.free(idem);
    const body = try event_mod.buildPullMergedJson(allocator, writer.cfg, writer.nextSeq(), pull_id, event_uuid, idem, occurred_at, writer.eventParents(), if (merge_oid.len == 0) null else merge_oid, target_oid);
    defer allocator.free(body);
    var pull_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const pull_ref = util.shortObjectRef(&pull_ref_buf, pull_id);
    const subject = try std.fmt.allocPrint(allocator, "pull.merged #{s}", .{pull_ref});
    defer allocator.free(subject);
    const commit = try writer.write("gt github import", subject, body);
    allocator.free(commit);
}

fn writeImportedCommentAdded(
    allocator: Allocator,
    options: ImportOptions,
    parent_kind: []const u8,
    parent_id: []const u8,
    occurred_at: []const u8,
    body_text: []const u8,
    source_author: []const u8,
    reply_parent_id: []const u8,
    reply_parent_hash: []const u8,
) !ImportedCommentRef {
    var writer = try EventWriter.initForActor(allocator, "gt github import", options.bot_principal, options.bot_device);
    defer writer.deinit();

    var comment_id: ?[]u8 = try util.newUuidV7(allocator);
    errdefer if (comment_id) |value| allocator.free(value);
    const event_uuid = try util.newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try util.newUuidV7(allocator);
    defer allocator.free(idem);
    var related: std.ArrayList([]const u8) = .empty;
    defer related.deinit(allocator);
    try related.appendSlice(allocator, writer.related_heads);
    if (reply_parent_hash.len != 0) {
        var seen = false;
        for (related.items) |hash| {
            if (std.mem.eql(u8, hash, reply_parent_hash)) {
                seen = true;
                break;
            }
        }
        if (!seen) try related.append(allocator, reply_parent_hash);
    }
    const parents = event_mod.EventParents{
        .log = writer.prepared_parents.old_head,
        .anchor = writer.prepared_parents.anchor,
        .causal = writer.prepared_parents.causal_heads,
        .related = related.items,
    };
    const body = try event_mod.buildCommentAddedJsonWithMetadata(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        comment_id.?,
        event_uuid,
        idem,
        occurred_at,
        parents,
        parent_kind,
        parent_id,
        body_text,
        .{
            .source_author = if (source_author.len == 0) null else source_author,
            .reply_parent_id = if (reply_parent_id.len == 0) null else reply_parent_id,
            .reply_parent_hash = if (reply_parent_hash.len == 0) null else reply_parent_hash,
        },
    );
    defer allocator.free(body);
    const subject = try std.fmt.allocPrint(allocator, "comment.added #{s}", .{comment_id.?[0..7]});
    defer allocator.free(subject);
    const commit = try writer.write("gt github import", subject, body);
    errdefer allocator.free(commit);
    const result = ImportedCommentRef{
        .id = comment_id.?,
        .event_hash = commit,
    };
    comment_id = null;
    return result;
}

fn githubSizedString(allocator: Allocator, value: ?[]const u8, fallback: []const u8, max_bytes: usize) ![]u8 {
    const raw = value orelse fallback;
    if (raw.len <= max_bytes) return allocator.dupe(u8, raw);

    const marker = "\n\n[truncated by gitomi github import]";
    if (max_bytes <= marker.len) return allocator.dupe(u8, raw[0..utf8PrefixLen(raw, max_bytes)]);

    const prefix_len = utf8PrefixLen(raw, max_bytes - marker.len);
    var out_buf: std.ArrayList(u8) = .empty;
    errdefer out_buf.deinit(allocator);
    try out_buf.appendSlice(allocator, raw[0..prefix_len]);
    try out_buf.appendSlice(allocator, marker);
    return try out_buf.toOwnedSlice(allocator);
}

fn githubSubject(allocator: Allocator, prefix: []const u8, title: []const u8) ![]u8 {
    const title_limit = if (prefix.len >= git.max_event_subject_bytes) 0 else git.max_event_subject_bytes - prefix.len;
    const title_part = try githubSizedString(allocator, title, "", title_limit);
    defer allocator.free(title_part);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, title_part });
}

fn utf8PrefixLen(value: []const u8, max_bytes: usize) usize {
    var len = @min(value.len, max_bytes);
    while (len > 0 and len < value.len and (value[len] & 0xc0) == 0x80) {
        len -= 1;
    }
    return len;
}

const ExportOptions = struct {
    repo: RepoSlug,
    api_url: []const u8 = default_api_url,
    token_arg: ?[]const u8 = null,
    dry_run: bool = false,
    map_file: ?[]const u8 = null,
    reuse_legacy: bool = false,
};

fn cmdExport(allocator: Allocator, args: []const []const u8) !void {
    var repo_opt: ?RepoSlug = null;
    var api_url: []const u8 = default_api_url;
    var token_arg: ?[]const u8 = null;
    var dry_run = false;
    var map_file_arg: ?[]const u8 = null;
    var reuse_legacy = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--repo")) {
            repo_opt = try parseRepoSlug(try util.requireValue(args, &i, "--repo"));
        } else if (std.mem.eql(u8, arg, "--api-url")) {
            api_url = try util.requireValue(args, &i, "--api-url");
        } else if (std.mem.eql(u8, arg, "--token")) {
            token_arg = try util.requireValue(args, &i, "--token");
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "--map-file")) {
            map_file_arg = try util.requireValue(args, &i, "--map-file");
        } else if (std.mem.eql(u8, arg, "--reuse-legacy")) {
            reuse_legacy = true;
        } else {
            try eprint("gt github export: unknown option '{s}'\n", .{arg});
            return CliError.UserError;
        }
    }

    if (repo_opt == null) {
        try eprint("gt github export: --repo OWNER/REPO is required\n", .{});
        return CliError.MissingArgument;
    }

    var token_owned: ?[]u8 = null;
    defer if (token_owned) |value| allocator.free(value);
    const token = token_arg orelse blk: {
        token_owned = githubTokenFromEnv(allocator) catch null;
        break :blk token_owned;
    };
    if (!dry_run and token == null) {
        try eprint("gt github export: --token or GITHUB_TOKEN is required unless --dry-run is used\n", .{});
        return CliError.MissingArgument;
    }

    const options = ExportOptions{
        .repo = repo_opt.?,
        .api_url = api_url,
        .token_arg = token,
        .dry_run = dry_run,
        .map_file = map_file_arg,
        .reuse_legacy = reuse_legacy,
    };
    try exportToGithub(allocator, options);
}

const MappingStore = struct {
    allocator: Allocator,
    path: []u8,
    dry_run: bool,
    next_synthetic: i64 = 1,
    map: std.StringHashMap(i64),

    fn init(allocator: Allocator, repo: repo_mod.Repo, slug: RepoSlug, explicit_path: ?[]const u8, dry_run: bool) !MappingStore {
        const path = if (explicit_path) |value|
            try allocator.dupe(u8, value)
        else blk: {
            const owner = try util.sanitizeRefSegment(allocator, slug.owner);
            defer allocator.free(owner);
            const name = try util.sanitizeRefSegment(allocator, slug.name);
            defer allocator.free(name);
            break :blk try std.fs.path.join(allocator, &.{ repo.gitomi_dir, "github", owner, name, "map.jsonl" });
        };
        return .{
            .allocator = allocator,
            .path = path,
            .dry_run = dry_run,
            .map = std.StringHashMap(i64).init(allocator),
        };
    }

    fn deinit(self: *MappingStore) void {
        var keys = self.map.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        self.map.deinit();
        self.allocator.free(self.path);
    }

    fn load(self: *MappingStore) !void {
        const bytes = std.fs.cwd().readFileAlloc(self.allocator, self.path, 8 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(bytes);
        var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
        while (lines.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r\n");
            if (line.len == 0) continue;
            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch continue;
            defer parsed.deinit();
            const root = switch (parsed.value) {
                .object => |object| object,
                else => continue,
            };
            const kind = event_mod.jsonString(root.get("kind")) orelse continue;
            const id = event_mod.jsonString(root.get("id")) orelse continue;
            const number = jsonInteger(root.get("number")) orelse continue;
            try self.putMemory(kind, id, number);
            if (number >= self.next_synthetic) self.next_synthetic = number + 1;
        }
    }

    fn get(self: *MappingStore, kind: []const u8, id: []const u8) !?i64 {
        const key = try mapKey(self.allocator, kind, id);
        defer self.allocator.free(key);
        return self.map.get(key);
    }

    fn put(self: *MappingStore, kind: []const u8, id: []const u8, number: i64) !void {
        if (try self.get(kind, id) != null) return;
        try self.putMemory(kind, id, number);
        if (!self.dry_run) try self.append(kind, id, number);
        if (number >= self.next_synthetic) self.next_synthetic = number + 1;
    }

    fn putSynthetic(self: *MappingStore, kind: []const u8, id: []const u8) !i64 {
        const number = self.next_synthetic;
        self.next_synthetic += 1;
        try self.putMemory(kind, id, number);
        return number;
    }

    fn putMemory(self: *MappingStore, kind: []const u8, id: []const u8, number: i64) !void {
        const key = try mapKey(self.allocator, kind, id);
        errdefer self.allocator.free(key);
        const entry = try self.map.getOrPut(key);
        if (entry.found_existing) {
            self.allocator.free(key);
        }
        entry.value_ptr.* = number;
    }

    fn append(self: *MappingStore, kind: []const u8, id: []const u8, number: i64) !void {
        if (std.fs.path.dirname(self.path)) |dir| try std.fs.cwd().makePath(dir);
        var file = std.fs.cwd().openFile(self.path, .{ .mode = .write_only }) catch |err| switch (err) {
            error.FileNotFound => try std.fs.cwd().createFile(self.path, .{}),
            else => return err,
        };
        defer file.close();
        try file.seekFromEnd(0);

        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.allocator);
        try line.append(self.allocator, '{');
        try appendJsonFieldString(&line, self.allocator, "kind", kind, true);
        try appendJsonFieldString(&line, self.allocator, "id", id, true);
        try json_writer.appendJsonFieldInteger(&line, self.allocator, "number", number, false);
        try line.appendSlice(self.allocator, "}\n");
        try file.writeAll(line.items);
    }
};

fn mapKey(allocator: Allocator, kind: []const u8, id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}\x1f{s}", .{ kind, id });
}

fn exportToGithub(allocator: Allocator, options: ExportOptions) !void {
    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();
    try index.ensureIndex(allocator, repo);

    var mappings = try MappingStore.init(allocator, repo, options.repo, options.map_file, options.dry_run);
    defer mappings.deinit();
    try mappings.load();

    const client = GitHubClient{
        .allocator = allocator,
        .api_url = options.api_url,
        .repo = options.repo,
        .token = options.token_arg,
        .dry_run = options.dry_run,
    };

    var db = try index.SqliteDb.open(allocator, repo.index_path, index.sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var stmt = try db.prepare(
        \\SELECT event_type, object_kind, object_id, body
        \\FROM events
        \\WHERE domain_status = 'accepted'
        \\  AND (event_type LIKE 'issue.%' OR event_type LIKE 'pull.%' OR event_type LIKE 'comment.%')
        \\ORDER BY ordinal
    );
    defer stmt.deinit();

    var exported: usize = 0;
    while (try stmt.step()) {
        const event_type = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(event_type);
        const object_kind = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(object_kind);
        const object_id = try stmt.columnTextDup(allocator, 2);
        defer allocator.free(object_id);
        const body = try stmt.columnTextDup(allocator, 3);
        defer allocator.free(body);
        if (try exportEvent(allocator, client, &mappings, options, event_type, object_kind, object_id, body)) {
            exported += 1;
        }
    }

    try out("github export: replayed {d} event{s}\n", .{ exported, if (exported == 1) "" else "s" });
}

fn exportEvent(
    allocator: Allocator,
    client: GitHubClient,
    mappings: *MappingStore,
    options: ExportOptions,
    event_type: []const u8,
    object_kind: []const u8,
    object_id: []const u8,
    body: []const u8,
) !bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return false;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return false,
    };
    const payload = switch (root.get("payload") orelse return false) {
        .object => |object| object,
        else => return false,
    };

    if (std.mem.startsWith(u8, event_type, "issue.")) {
        return try exportIssueEvent(allocator, client, mappings, options, event_type, object_id, root, payload);
    }
    if (std.mem.startsWith(u8, event_type, "pull.")) {
        return try exportPullEvent(allocator, client, mappings, options, event_type, object_id, root, payload);
    }
    if (std.mem.startsWith(u8, event_type, "comment.") and std.mem.eql(u8, object_kind, "comment")) {
        return try exportCommentEvent(allocator, client, mappings, event_type, object_id, payload);
    }
    return false;
}

fn exportIssueEvent(
    allocator: Allocator,
    client: GitHubClient,
    mappings: *MappingStore,
    options: ExportOptions,
    event_type: []const u8,
    issue_id: []const u8,
    root: std.json.ObjectMap,
    payload: std.json.ObjectMap,
) !bool {
    if (std.mem.eql(u8, event_type, "issue.opened")) {
        if (try mappings.get("issue", issue_id) != null) return false;
        if (options.reuse_legacy) {
            if (legacyNumber(root, "github_issue_number")) |number| {
                try mappings.put("issue", issue_id, number);
                return false;
            }
        }
        const request_body = try githubIssueCreateBody(allocator, payload);
        defer allocator.free(request_body);
        const path = try client.repoPath(allocator, "/issues");
        defer allocator.free(path);
        const raw = try client.request("POST", path, request_body);
        defer allocator.free(raw);
        const number = if (client.dry_run) try mappings.putSynthetic("issue", issue_id) else parseResponseNumber(allocator, raw, "number") orelse return CliError.UserError;
        if (!client.dry_run) try mappings.put("issue", issue_id, number);
        return true;
    }

    const number = (try mappings.get("issue", issue_id)) orelse return false;
    if (std.mem.eql(u8, event_type, "issue.updated")) {
        var changed = false;
        if (try githubIssuePatchBody(allocator, payload)) |request_body| {
            defer allocator.free(request_body);
            const path = try std.fmt.allocPrint(allocator, "/repos/{s}/issues/{d}", .{ client.repo.slug, number });
            defer allocator.free(path);
            const raw = try client.request("PATCH", path, request_body);
            allocator.free(raw);
            changed = true;
        }
        try replayLabels(allocator, client, number, payload, "labels_added", "labels_removed");
        try replayAssignees(allocator, client, number, payload, "assignees_added", "assignees_removed");
        return changed;
    }
    if (std.mem.eql(u8, event_type, "issue.title_set") or std.mem.eql(u8, event_type, "issue.body_set") or std.mem.eql(u8, event_type, "issue.state_set")) {
        const request_body = try githubSinglePatchBody(allocator, payload);
        defer allocator.free(request_body);
        const path = try std.fmt.allocPrint(allocator, "/repos/{s}/issues/{d}", .{ client.repo.slug, number });
        defer allocator.free(path);
        const raw = try client.request("PATCH", path, request_body);
        allocator.free(raw);
        return true;
    }
    if (std.mem.eql(u8, event_type, "issue.label_added")) {
        try replayOneLabel(allocator, client, number, event_mod.jsonString(payload.get("label")) orelse "", true);
        return true;
    }
    if (std.mem.eql(u8, event_type, "issue.label_removed")) {
        try replayOneLabel(allocator, client, number, event_mod.jsonString(payload.get("label")) orelse "", false);
        return true;
    }
    if (std.mem.eql(u8, event_type, "issue.assignee_added")) {
        try replayOneAssignee(allocator, client, number, event_mod.jsonString(payload.get("assignee")) orelse "", true);
        return true;
    }
    if (std.mem.eql(u8, event_type, "issue.assignee_removed")) {
        try replayOneAssignee(allocator, client, number, event_mod.jsonString(payload.get("assignee")) orelse "", false);
        return true;
    }
    return false;
}

fn exportPullEvent(
    allocator: Allocator,
    client: GitHubClient,
    mappings: *MappingStore,
    options: ExportOptions,
    event_type: []const u8,
    pull_id: []const u8,
    root: std.json.ObjectMap,
    payload: std.json.ObjectMap,
) !bool {
    if (std.mem.eql(u8, event_type, "pull.opened")) {
        if (try mappings.get("pull", pull_id) != null) return false;
        if (options.reuse_legacy) {
            if (legacyNumber(root, "github_pull_number")) |number| {
                try mappings.put("pull", pull_id, number);
                return false;
            }
        }
        const request_body = try githubPullCreateBody(allocator, payload);
        defer allocator.free(request_body);
        const path = try client.repoPath(allocator, "/pulls");
        defer allocator.free(path);
        const raw = try client.request("POST", path, request_body);
        defer allocator.free(raw);
        const number = if (client.dry_run) try mappings.putSynthetic("pull", pull_id) else parseResponseNumber(allocator, raw, "number") orelse return CliError.UserError;
        if (!client.dry_run) try mappings.put("pull", pull_id, number);
        return true;
    }

    const number = (try mappings.get("pull", pull_id)) orelse return false;
    if (std.mem.eql(u8, event_type, "pull.updated")) {
        var changed = false;
        if (try githubPullPatchBody(allocator, payload)) |request_body| {
            defer allocator.free(request_body);
            const path = try std.fmt.allocPrint(allocator, "/repos/{s}/pulls/{d}", .{ client.repo.slug, number });
            defer allocator.free(path);
            const raw = try client.request("PATCH", path, request_body);
            allocator.free(raw);
            changed = true;
        }
        try replayLabels(allocator, client, number, payload, "labels_added", "labels_removed");
        try replayAssignees(allocator, client, number, payload, "assignees_added", "assignees_removed");
        try replayReviewers(allocator, client, number, payload, "reviewers_added", "reviewers_removed");
        return changed;
    }
    if (std.mem.eql(u8, event_type, "pull.merged")) {
        const path = try std.fmt.allocPrint(allocator, "/repos/{s}/pulls/{d}/merge", .{ client.repo.slug, number });
        defer allocator.free(path);
        const raw = try client.request("PUT", path, "{}");
        allocator.free(raw);
        return true;
    }
    if (std.mem.eql(u8, event_type, "pull.title_set") or std.mem.eql(u8, event_type, "pull.body_set") or std.mem.eql(u8, event_type, "pull.state_set") or std.mem.eql(u8, event_type, "pull.base_set")) {
        const request_body = try githubSinglePatchBody(allocator, payload);
        defer allocator.free(request_body);
        const path = try std.fmt.allocPrint(allocator, "/repos/{s}/pulls/{d}", .{ client.repo.slug, number });
        defer allocator.free(path);
        const raw = try client.request("PATCH", path, request_body);
        allocator.free(raw);
        return true;
    }
    if (std.mem.eql(u8, event_type, "pull.label_added")) {
        try replayOneLabel(allocator, client, number, event_mod.jsonString(payload.get("label")) orelse "", true);
        return true;
    }
    if (std.mem.eql(u8, event_type, "pull.label_removed")) {
        try replayOneLabel(allocator, client, number, event_mod.jsonString(payload.get("label")) orelse "", false);
        return true;
    }
    if (std.mem.eql(u8, event_type, "pull.assignee_added")) {
        try replayOneAssignee(allocator, client, number, event_mod.jsonString(payload.get("assignee")) orelse "", true);
        return true;
    }
    if (std.mem.eql(u8, event_type, "pull.assignee_removed")) {
        try replayOneAssignee(allocator, client, number, event_mod.jsonString(payload.get("assignee")) orelse "", false);
        return true;
    }
    if (std.mem.eql(u8, event_type, "pull.reviewer_added")) {
        try replayOneReviewer(allocator, client, number, event_mod.jsonString(payload.get("reviewer")) orelse "", true);
        return true;
    }
    if (std.mem.eql(u8, event_type, "pull.reviewer_removed")) {
        try replayOneReviewer(allocator, client, number, event_mod.jsonString(payload.get("reviewer")) orelse "", false);
        return true;
    }
    return false;
}

fn exportCommentEvent(
    allocator: Allocator,
    client: GitHubClient,
    mappings: *MappingStore,
    event_type: []const u8,
    comment_id: []const u8,
    payload: std.json.ObjectMap,
) !bool {
    if (std.mem.eql(u8, event_type, "comment.added")) {
        if (try mappings.get("comment", comment_id) != null) return false;
        const parent_kind = event_mod.jsonString(payload.get("parent_kind")) orelse return false;
        const parent_id = event_mod.jsonString(payload.get("parent_id")) orelse return false;
        const parent_number = (try mappings.get(parent_kind, parent_id)) orelse return false;
        const request_body = try githubCommentBody(allocator, event_mod.jsonString(payload.get("body")) orelse "");
        defer allocator.free(request_body);
        const path = try std.fmt.allocPrint(allocator, "/repos/{s}/issues/{d}/comments", .{ client.repo.slug, parent_number });
        defer allocator.free(path);
        const raw = try client.request("POST", path, request_body);
        defer allocator.free(raw);
        const comment_number = if (client.dry_run) try mappings.putSynthetic("comment", comment_id) else parseResponseNumber(allocator, raw, "id") orelse return CliError.UserError;
        if (!client.dry_run) try mappings.put("comment", comment_id, comment_number);
        return true;
    }

    const github_id = (try mappings.get("comment", comment_id)) orelse return false;
    const body_text = if (std.mem.eql(u8, event_type, "comment.redacted"))
        "[redacted]"
    else
        event_mod.jsonString(payload.get("body")) orelse return false;
    const request_body = try githubCommentBody(allocator, body_text);
    defer allocator.free(request_body);
    const path = try std.fmt.allocPrint(allocator, "/repos/{s}/issues/comments/{d}", .{ client.repo.slug, github_id });
    defer allocator.free(path);
    const raw = try client.request("PATCH", path, request_body);
    allocator.free(raw);
    return true;
}

fn githubIssueCreateBody(allocator: Allocator, payload: std.json.ObjectMap) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var first = true;
    try buf.append(allocator, '{');
    try appendStringField(&buf, allocator, &first, "title", event_mod.jsonString(payload.get("title")) orelse "(untitled)");
    if (event_mod.jsonString(payload.get("body"))) |body| try appendStringField(&buf, allocator, &first, "body", body);
    try appendStringArrayValueField(&buf, allocator, &first, "labels", payload.get("labels"));
    try appendStringArrayValueField(&buf, allocator, &first, "assignees", payload.get("assignees"));
    try buf.append(allocator, '}');
    return try buf.toOwnedSlice(allocator);
}

fn githubPullCreateBody(allocator: Allocator, payload: std.json.ObjectMap) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var first = true;
    try buf.append(allocator, '{');
    try appendStringField(&buf, allocator, &first, "title", event_mod.jsonString(payload.get("title")) orelse "(untitled)");
    if (event_mod.jsonString(payload.get("body"))) |body| try appendStringField(&buf, allocator, &first, "body", body);
    try appendStringField(&buf, allocator, &first, "base", event_mod.jsonString(payload.get("base_ref")) orelse "main");
    try appendStringField(&buf, allocator, &first, "head", event_mod.jsonString(payload.get("head_ref")) orelse "unknown");
    if (jsonBool(payload.get("draft"))) |draft| try appendBoolField(&buf, allocator, &first, "draft", draft);
    try buf.append(allocator, '}');
    return try buf.toOwnedSlice(allocator);
}

fn githubIssuePatchBody(allocator: Allocator, payload: std.json.ObjectMap) !?[]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var first = true;
    try buf.append(allocator, '{');
    if (event_mod.jsonString(payload.get("title"))) |value| try appendStringField(&buf, allocator, &first, "title", value);
    if (event_mod.jsonString(payload.get("body"))) |value| try appendStringField(&buf, allocator, &first, "body", value);
    if (event_mod.jsonString(payload.get("state"))) |value| try appendStringField(&buf, allocator, &first, "state", value);
    if (first) {
        buf.deinit(allocator);
        return null;
    }
    try buf.append(allocator, '}');
    return try buf.toOwnedSlice(allocator);
}

fn githubPullPatchBody(allocator: Allocator, payload: std.json.ObjectMap) !?[]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var first = true;
    try buf.append(allocator, '{');
    if (event_mod.jsonString(payload.get("title"))) |value| try appendStringField(&buf, allocator, &first, "title", value);
    if (event_mod.jsonString(payload.get("body"))) |value| try appendStringField(&buf, allocator, &first, "body", value);
    if (event_mod.jsonString(payload.get("state"))) |value| try appendStringField(&buf, allocator, &first, "state", value);
    if (event_mod.jsonString(payload.get("base_ref"))) |value| try appendStringField(&buf, allocator, &first, "base", value);
    if (first) {
        buf.deinit(allocator);
        return null;
    }
    try buf.append(allocator, '}');
    return try buf.toOwnedSlice(allocator);
}

fn githubSinglePatchBody(allocator: Allocator, payload: std.json.ObjectMap) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var first = true;
    try buf.append(allocator, '{');
    if (event_mod.jsonString(payload.get("title"))) |value| try appendStringField(&buf, allocator, &first, "title", value);
    if (event_mod.jsonString(payload.get("body"))) |value| try appendStringField(&buf, allocator, &first, "body", value);
    if (event_mod.jsonString(payload.get("state"))) |value| try appendStringField(&buf, allocator, &first, "state", value);
    if (event_mod.jsonString(payload.get("base_ref"))) |value| try appendStringField(&buf, allocator, &first, "base", value);
    if (event_mod.jsonString(payload.get("head_ref"))) |value| try appendStringField(&buf, allocator, &first, "head", value);
    try buf.append(allocator, '}');
    return buf.toOwnedSlice(allocator);
}

fn githubCommentBody(allocator: Allocator, body_text: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '{');
    try appendJsonFieldString(&buf, allocator, "body", body_text, false);
    try buf.append(allocator, '}');
    return buf.toOwnedSlice(allocator);
}

fn replayLabels(allocator: Allocator, client: GitHubClient, issue_number: i64, payload: std.json.ObjectMap, added_key: []const u8, removed_key: []const u8) !void {
    try replayStringArrayLabels(allocator, client, issue_number, payload.get(added_key), true);
    try replayStringArrayLabels(allocator, client, issue_number, payload.get(removed_key), false);
}

fn replayStringArrayLabels(allocator: Allocator, client: GitHubClient, issue_number: i64, value: ?std.json.Value, add: bool) !void {
    const array = jsonArray(value) orelse return;
    for (array.items) |item| {
        if (item != .string) continue;
        try replayOneLabel(allocator, client, issue_number, item.string, add);
    }
}

fn replayOneLabel(allocator: Allocator, client: GitHubClient, issue_number: i64, label: []const u8, add: bool) !void {
    if (std.mem.trim(u8, label, " \t\r\n").len == 0) return;
    if (add) {
        const body = try singleArrayBody(allocator, "labels", label);
        defer allocator.free(body);
        const path = try std.fmt.allocPrint(allocator, "/repos/{s}/issues/{d}/labels", .{ client.repo.slug, issue_number });
        defer allocator.free(path);
        const raw = try client.request("POST", path, body);
        allocator.free(raw);
    } else {
        const escaped = try urlPathEscape(allocator, label);
        defer allocator.free(escaped);
        const path = try std.fmt.allocPrint(allocator, "/repos/{s}/issues/{d}/labels/{s}", .{ client.repo.slug, issue_number, escaped });
        defer allocator.free(path);
        const raw = try client.request("DELETE", path, null);
        allocator.free(raw);
    }
}

fn replayAssignees(allocator: Allocator, client: GitHubClient, issue_number: i64, payload: std.json.ObjectMap, added_key: []const u8, removed_key: []const u8) !void {
    try replayStringArrayAssignees(allocator, client, issue_number, payload.get(added_key), true);
    try replayStringArrayAssignees(allocator, client, issue_number, payload.get(removed_key), false);
}

fn replayStringArrayAssignees(allocator: Allocator, client: GitHubClient, issue_number: i64, value: ?std.json.Value, add: bool) !void {
    const array = jsonArray(value) orelse return;
    for (array.items) |item| {
        if (item != .string) continue;
        try replayOneAssignee(allocator, client, issue_number, item.string, add);
    }
}

fn replayOneAssignee(allocator: Allocator, client: GitHubClient, issue_number: i64, assignee: []const u8, add: bool) !void {
    if (std.mem.trim(u8, assignee, " \t\r\n").len == 0) return;
    const body = try singleArrayBody(allocator, "assignees", assignee);
    defer allocator.free(body);
    const path = try std.fmt.allocPrint(allocator, "/repos/{s}/issues/{d}/assignees", .{ client.repo.slug, issue_number });
    defer allocator.free(path);
    const raw = try client.request(if (add) "POST" else "DELETE", path, body);
    allocator.free(raw);
}

fn replayReviewers(allocator: Allocator, client: GitHubClient, pull_number: i64, payload: std.json.ObjectMap, added_key: []const u8, removed_key: []const u8) !void {
    try replayStringArrayReviewers(allocator, client, pull_number, payload.get(added_key), true);
    try replayStringArrayReviewers(allocator, client, pull_number, payload.get(removed_key), false);
}

fn replayStringArrayReviewers(allocator: Allocator, client: GitHubClient, pull_number: i64, value: ?std.json.Value, add: bool) !void {
    const array = jsonArray(value) orelse return;
    for (array.items) |item| {
        if (item != .string) continue;
        try replayOneReviewer(allocator, client, pull_number, item.string, add);
    }
}

fn replayOneReviewer(allocator: Allocator, client: GitHubClient, pull_number: i64, reviewer: []const u8, add: bool) !void {
    if (std.mem.trim(u8, reviewer, " \t\r\n").len == 0) return;
    const body = try singleArrayBody(allocator, "reviewers", reviewer);
    defer allocator.free(body);
    const path = try std.fmt.allocPrint(allocator, "/repos/{s}/pulls/{d}/requested_reviewers", .{ client.repo.slug, pull_number });
    defer allocator.free(path);
    const raw = try client.request(if (add) "POST" else "DELETE", path, body);
    allocator.free(raw);
}

fn singleArrayBody(allocator: Allocator, key: []const u8, value: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '{');
    try appendJsonFieldStringArray(&buf, allocator, key, &.{value}, false);
    try buf.append(allocator, '}');
    return buf.toOwnedSlice(allocator);
}

fn appendStringField(buf: *std.ArrayList(u8), allocator: Allocator, first: *bool, key: []const u8, value: []const u8) !void {
    if (!first.*) try buf.append(allocator, ',');
    first.* = false;
    try appendJsonFieldString(buf, allocator, key, value, false);
}

fn appendBoolField(buf: *std.ArrayList(u8), allocator: Allocator, first: *bool, key: []const u8, value: bool) !void {
    if (!first.*) try buf.append(allocator, ',');
    first.* = false;
    try appendJsonFieldBool(buf, allocator, key, value, false);
}

fn appendStringArrayValueField(buf: *std.ArrayList(u8), allocator: Allocator, first: *bool, key: []const u8, value: ?std.json.Value) !void {
    const array = jsonArray(value) orelse return;
    if (array.items.len == 0) return;
    if (!first.*) try buf.append(allocator, ',');
    first.* = false;
    try appendJsonString(buf, allocator, key);
    try buf.appendSlice(allocator, ":[");
    var first_item = true;
    for (array.items) |item| {
        if (item != .string) continue;
        if (!first_item) try buf.append(allocator, ',');
        first_item = false;
        try appendJsonString(buf, allocator, item.string);
    }
    try buf.append(allocator, ']');
}

fn parseResponseNumber(allocator: Allocator, raw: []const u8, key: []const u8) ?i64 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return null;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return null,
    };
    return jsonInteger(root.get(key));
}

fn legacyNumber(root: std.json.ObjectMap, key: []const u8) ?i64 {
    const legacy = switch (root.get("legacy") orelse return null) {
        .object => |object| object,
        else => return null,
    };
    return jsonInteger(legacy.get(key));
}

fn githubTimestampOrNow(allocator: Allocator, value: ?std.json.Value) ![]u8 {
    if (event_mod.jsonString(value)) |timestamp| {
        if (timestamp.len != 0 and timestamp[timestamp.len - 1] == 'Z') {
            return allocator.dupe(u8, timestamp);
        }
    }
    return util.rfc3339Now(allocator);
}

fn firstJsonValue(a: ?std.json.Value, b: ?std.json.Value) ?std.json.Value {
    return if (a) |value| value else b;
}

fn githubIssueLabels(allocator: Allocator, issue: std.json.ObjectMap) ![][]u8 {
    var list: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(allocator, list.items);
    try appendGithubNamedArray(allocator, &list, issue.get("labels"), "name");
    try appendGithubNamedArray(allocator, &list, issue.get("tags"), "name");
    return list.toOwnedSlice(allocator);
}

fn githubPullReviewers(allocator: Allocator, pull: std.json.ObjectMap) ![][]u8 {
    var list: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(allocator, list.items);
    try appendGithubNamedArray(allocator, &list, pull.get("requested_reviewers"), "login");
    try appendGithubNamedArray(allocator, &list, pull.get("reviewers"), "login");
    return list.toOwnedSlice(allocator);
}

fn githubNamedArray(allocator: Allocator, value: ?std.json.Value, key: []const u8) ![][]u8 {
    var list: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(allocator, list.items);
    try appendGithubNamedArray(allocator, &list, value, key);
    return list.toOwnedSlice(allocator);
}

fn appendGithubNamedArray(allocator: Allocator, list: *std.ArrayList([]u8), value: ?std.json.Value, key: []const u8) !void {
    const array = jsonArray(value) orelse return;
    for (array.items) |item| {
        if (item == .string) {
            try list.append(allocator, try githubSizedString(allocator, item.string, "", git.max_payload_atom_bytes));
        } else if (item == .object) {
            if (event_mod.jsonString(item.object.get(key))) |name| {
                if (name.len != 0) try list.append(allocator, try githubSizedString(allocator, name, "", git.max_payload_atom_bytes));
            }
        }
    }
}

fn freeStringList(allocator: Allocator, values: [][]u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn githubAuthorLogin(object: std.json.ObjectMap) ?[]const u8 {
    if (nestedString(object, "user", "login")) |value| return value;
    if (nestedString(object, "author", "login")) |value| return value;
    if (event_mod.jsonString(object.get("author"))) |value| return value;
    if (event_mod.jsonString(object.get("user"))) |value| return value;
    return null;
}

fn githubMilestoneTitle(object: std.json.ObjectMap) ?[]const u8 {
    if (event_mod.jsonString(object.get("milestone"))) |value| return value;
    return nestedString(object, "milestone", "title");
}

fn githubFixtureProjects(
    allocator: Allocator,
    root: std.json.ObjectMap,
    parent_kind: []const u8,
    number: i64,
    object: std.json.ObjectMap,
) ![]event_mod.IssueProjectPlacement {
    var list: std.ArrayList(event_mod.IssueProjectPlacement) = .empty;
    errdefer freeProjectPlacements(allocator, list.items);
    try appendProjectPlacements(allocator, &list, object.get("projects"));

    const projects_root = switch (root.get("projects") orelse return list.toOwnedSlice(allocator)) {
        .object => |map| map,
        else => return list.toOwnedSlice(allocator),
    };
    const key = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ parent_kind, number });
    defer allocator.free(key);
    try appendProjectPlacements(allocator, &list, projects_root.get(key));
    return list.toOwnedSlice(allocator);
}

fn appendProjectPlacements(
    allocator: Allocator,
    list: *std.ArrayList(event_mod.IssueProjectPlacement),
    value: ?std.json.Value,
) !void {
    const array = jsonArray(value) orelse return;
    for (array.items) |item| {
        var project_name: ?[]const u8 = null;
        var column_name: []const u8 = "";
        switch (item) {
            .string => |value_string| {
                const slash = std.mem.indexOfScalar(u8, value_string, '/');
                if (slash) |idx| {
                    project_name = std.mem.trim(u8, value_string[0..idx], " \t\r\n");
                    column_name = std.mem.trim(u8, value_string[idx + 1 ..], " \t\r\n");
                } else {
                    project_name = std.mem.trim(u8, value_string, " \t\r\n");
                }
            },
            .object => |map| {
                project_name = event_mod.jsonString(map.get("project")) orelse
                    event_mod.jsonString(map.get("name")) orelse
                    event_mod.jsonString(map.get("title"));
                column_name = event_mod.jsonString(map.get("column")) orelse
                    event_mod.jsonString(map.get("column_name")) orelse
                    event_mod.jsonString(map.get("status")) orelse
                    "";
            },
            else => continue,
        }
        const project = project_name orelse continue;
        if (project.len == 0) continue;
        try list.append(allocator, .{
            .project = try githubSizedString(allocator, project, "", git.max_payload_atom_bytes),
            .column = try githubSizedString(allocator, column_name, "", git.max_payload_atom_bytes),
        });
    }
}

fn freeProjectPlacements(allocator: Allocator, projects: []event_mod.IssueProjectPlacement) void {
    for (projects) |project| {
        allocator.free(project.project);
        allocator.free(project.column);
    }
    allocator.free(projects);
}

fn nestedString(object: std.json.ObjectMap, parent_key: []const u8, child_key: []const u8) ?[]const u8 {
    const parent = switch (object.get(parent_key) orelse return null) {
        .object => |map| map,
        else => return null,
    };
    return event_mod.jsonString(parent.get(child_key));
}

fn jsonArray(value: ?std.json.Value) ?std.json.Array {
    if (value) |v| {
        return switch (v) {
            .array => |array| array,
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

fn jsonInteger(value: ?std.json.Value) ?i64 {
    if (value) |v| {
        return switch (v) {
            .integer => |i| i,
            else => null,
        };
    }
    return null;
}

fn jsonOptionalUnsigned(value: ?std.json.Value) ?u64 {
    const integer = jsonInteger(value) orelse return null;
    if (integer < 0) return null;
    return @intCast(integer);
}

fn urlPathEscape(allocator: Allocator, value: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    const hex = "0123456789ABCDEF";
    for (value) |c| {
        const unreserved = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '-' or c == '_' or c == '.' or c == '~';
        if (unreserved) {
            try buf.append(allocator, c);
        } else {
            try buf.append(allocator, '%');
            try buf.append(allocator, hex[c >> 4]);
            try buf.append(allocator, hex[c & 0x0f]);
        }
    }
    return buf.toOwnedSlice(allocator);
}

test "github import text capping preserves utf8 and limit" {
    const raw = "hello 世界 this text is too long";
    const capped = try githubSizedString(std.testing.allocator, raw, "", 18);
    defer std.testing.allocator.free(capped);
    try std.testing.expect(capped.len <= 18);
    try std.testing.expect(std.unicode.utf8ValidateSlice(capped));
}

test "github import subject stays within event subject limit" {
    const title = try std.testing.allocator.alloc(u8, git.max_event_subject_bytes * 2);
    defer std.testing.allocator.free(title);
    @memset(title, 'a');

    const subject = try githubSubject(std.testing.allocator, "issue.opened #1234567 GitHub #1 ", title);
    defer std.testing.allocator.free(subject);
    try std.testing.expect(subject.len <= git.max_event_subject_bytes);
}
