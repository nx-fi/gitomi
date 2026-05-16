const std = @import("std");
const event_mod = @import("../event.zig");
const event_writer_mod = @import("../event_writer.zig");
const errors = @import("../errors.zig");
const git = @import("../git.zig");
const index = @import("../index.zig");
const io = @import("../io.zig");
const repo_mod = @import("../repo.zig");
const util = @import("../util.zig");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const EventWriter = event_writer_mod.EventWriter;
const out = io.out;
const eprint = io.eprint;
const RepoSlug = common.RepoSlug;
const GitHubClient = common.GitHubClient;
const default_api_url = common.default_api_url;
const max_github_json = common.max_github_json;
const gh_current_repo = common.gh_current_repo;
const parseRepoSlug = common.parseRepoSlug;
const githubTokenFromEnv = common.githubTokenFromEnv;
const githubSizedString = common.githubSizedString;
const githubSubject = common.githubSubject;
const githubTimestampOrNow = common.githubTimestampOrNow;
const firstJsonValue = common.firstJsonValue;
const githubIssueLabels = common.githubIssueLabels;
const githubPullReviewers = common.githubPullReviewers;
const githubNamedArray = common.githubNamedArray;
const githubAuthorLogin = common.githubAuthorLogin;
const githubOptionalUnsignedField = common.githubOptionalUnsignedField;
const githubMilestoneTitle = common.githubMilestoneTitle;
const githubFixtureProjects = common.githubFixtureProjects;
const freeProjectPlacements = common.freeProjectPlacements;
const nestedString = common.nestedString;
const jsonArray = common.jsonArray;
const jsonBool = common.jsonBool;
const jsonInteger = common.jsonInteger;

const import_bot_principal = "import-bot";
const import_bot_device = "github";
const github_import_capability = "github.import";
const github_import_scope = "github:*";

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

pub fn cmdImport(allocator: Allocator, args: []const []const u8) !void {
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
    comment_count: ?u64 = null,
};

const ImportedCommentRef = struct {
    id: []u8,
    event_hash: []u8,

    fn deinit(self: ImportedCommentRef, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.event_hash);
    }
};

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
            var writer = try EventWriter.initForActor(allocator, "gt github import", options.bot_principal, options.bot_device);
            defer writer.deinit();
            const issue_result = try importIssueObject(allocator, &writer, item.object, projects, stats);
            defer if (issue_result) |result| allocator.free(result.id);
            if (issue_result) |result| {
                if (result.is_new) try importFixtureComments(allocator, &writer, root, "issue", item.object, result.id, options, stats);
                try writer.commitStaged();
            }
        }
    }
    if (jsonArray(root.get("pulls"))) |pulls| {
        try eprint("gt github import: importing {d} fixture pull record{s}\n", .{ pulls.items.len, if (pulls.items.len == 1) "" else "s" });
        for (pulls.items) |item| {
            if (item != .object) continue;
            var writer = try EventWriter.initForActor(allocator, "gt github import", options.bot_principal, options.bot_device);
            defer writer.deinit();
            const pull_result = try importPullObject(allocator, &writer, item.object, stats);
            defer if (pull_result) |result| allocator.free(result.id);
            if (pull_result) |result| {
                if (result.is_new) try importFixtureComments(allocator, &writer, root, "pull", item.object, result.id, options, stats);
                try writer.commitStaged();
            }
        }
    }
}

fn importFixtureComments(
    allocator: Allocator,
    writer: *EventWriter,
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
    try importCommentsArray(allocator, writer, parent_kind, parent_id, comments, stats);
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
            const number = jsonInteger(item.object.get("number")) orelse continue;
            var writer = try EventWriter.initForActor(allocator, "gt github import", options.bot_principal, options.bot_device);
            defer writer.deinit();
            const issue_result = try importIssueObject(allocator, &writer, item.object, &.{}, stats);
            defer if (issue_result) |result| allocator.free(result.id);
            if (issue_result) |result| {
                if (result.is_new and shouldFetchApiComments(result.comment_count)) try importApiComments(allocator, &writer, client, "issue", number, result.id, options, stats);
                try writer.commitStaged();
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
            const number = jsonInteger(item.object.get("number")) orelse continue;
            var writer = try EventWriter.initForActor(allocator, "gt github import", options.bot_principal, options.bot_device);
            defer writer.deinit();
            const pull_result = try importApiPullObject(allocator, &writer, client, item.object, stats);
            defer if (pull_result) |result| allocator.free(result.id);
            if (pull_result) |result| {
                if (result.is_new and shouldFetchApiComments(result.comment_count)) try importApiComments(allocator, &writer, client, "pull", number, result.id, options, stats);
                try writer.commitStaged();
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

fn importApiPullObject(
    allocator: Allocator,
    writer: *EventWriter,
    client: GitHubClient,
    summary: std.json.ObjectMap,
    stats: *ImportStats,
) !?ImportedObject {
    const number = jsonInteger(summary.get("number")) orelse return null;

    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();
    if (try index.lookupLegacyGithubObjectId(allocator, repo, "pull", number)) |existing| {
        try eprint("gt github import: pull #{d} already imported; skipping\n", .{number});
        return .{ .id = existing, .is_new = false };
    }

    try eprint("gt github import: fetching pull #{d} details\n", .{number});
    const suffix = try std.fmt.allocPrint(allocator, "/pulls/{d}", .{number});
    defer allocator.free(suffix);
    const path = try client.repoPath(allocator, suffix);
    defer allocator.free(path);
    const raw = try client.request("GET", path, null);
    defer allocator.free(raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const pull = switch (parsed.value) {
        .object => |object| object,
        else => {
            try eprint("gt github import: pull #{d} detail response must be a JSON object\n", .{number});
            return CliError.InvalidArgument;
        },
    };
    return try importPullObject(allocator, writer, pull, stats);
}

fn importApiComments(
    allocator: Allocator,
    writer: *EventWriter,
    client: GitHubClient,
    parent_kind: []const u8,
    number: i64,
    parent_id: []const u8,
    options: ImportOptions,
    stats: *ImportStats,
) !void {
    if (!options.include_comments) return;

    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();
    try index.ensureIndex(allocator, repo);
    var db = try index.SqliteDb.open(allocator, repo.index_path, index.sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    var comment_refs = std.AutoHashMap(i64, ImportedCommentRef).init(allocator);
    defer freeImportedCommentRefs(allocator, &comment_refs);

    var total: usize = 0;
    var page: usize = 1;
    while (page <= options.max_pages) : (page += 1) {
        try eprint("gt github import: fetching comments for {s} #{d} page {d}\n", .{ parent_kind, number, page });
        const suffix = try std.fmt.allocPrint(allocator, "/issues/{d}/comments?per_page=100&page={d}", .{ number, page });
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
        if (comments.items.len == 0) break;
        total += comments.items.len;
        try importCommentsArrayWithContext(allocator, &db, &comment_refs, writer, parent_kind, parent_id, comments, stats);
        if (comments.items.len < 100) break;
    }
    try eprint("gt github import: {s} #{d}: {d} comment{s}\n", .{ parent_kind, number, total, if (total == 1) "" else "s" });
}

fn importClassicProjects(allocator: Allocator, client: GitHubClient, options: ImportOptions, stats: *ImportStats) !void {
    try eprint("gt github import: fetching classic project boards\n", .{});
    const path = try client.repoPath(allocator, "/projects?per_page=100");
    defer allocator.free(path);
    const raw = (try client.requestAllowNotFound("GET", path, null)) orelse {
        try eprint("gt github import: classic project boards unavailable; skipping\n", .{});
        return;
    };
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
    const raw = (try client.requestAllowNotFound("GET", path, null)) orelse return;
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
    const raw = (try client.requestAllowNotFound("GET", path, null)) orelse return;
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
        var writer = try EventWriter.initForActor(allocator, "gt github import", options.bot_principal, options.bot_device);
        defer writer.deinit();
        try writeImportedIssueProjectAdded(allocator, &writer, issue_id, occurred_at, project, column);
        try writer.commitStaged();
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

pub fn issueNumberFromContentUrl(url: []const u8) ?i64 {
    const marker = "/issues/";
    const idx = std.mem.lastIndexOf(u8, url, marker) orelse return null;
    const raw = url[idx + marker.len ..];
    if (raw.len == 0) return null;
    return std.fmt.parseInt(i64, raw, 10) catch null;
}

fn importIssueObject(
    allocator: Allocator,
    writer: *EventWriter,
    issue: std.json.ObjectMap,
    projects: []const event_mod.IssueProjectPlacement,
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
    defer git.freeStringList(allocator, labels);
    const assignees = try githubNamedArray(allocator, issue.get("assignees"), "login");
    defer git.freeStringList(allocator, assignees);
    const source_author = try githubSizedString(allocator, githubAuthorLogin(issue), "", git.max_payload_atom_bytes);
    defer allocator.free(source_author);
    const milestone = try githubSizedString(allocator, githubMilestoneTitle(issue), "", git.max_payload_atom_bytes);
    defer allocator.free(milestone);
    const comment_count = githubOptionalUnsignedField(issue, &.{ "comments", "comment_count" });

    const issue_id = try util.newUuidV7(allocator);
    errdefer allocator.free(issue_id);
    try eprint("gt github import: importing issue #{d}\n", .{number});
    try writeImportedIssueOpened(allocator, writer, issue_id, @intCast(number), occurred_at, title, body, labels, assignees, source_author, milestone, projects);
    stats.issues += 1;

    if (event_mod.jsonString(issue.get("state"))) |state| {
        if (std.mem.eql(u8, state, "closed")) {
            const closed_at = try githubTimestampOrNow(allocator, firstJsonValue(issue.get("closed_at"), issue.get("updated_at")));
            defer allocator.free(closed_at);
            try writeImportedStringEvent(allocator, writer, "issue", issue_id, "issue.state_set", "state", "closed", closed_at);
        }
    }

    return .{ .id = issue_id, .is_new = true, .comment_count = comment_count };
}

fn importPullObject(allocator: Allocator, writer: *EventWriter, pull: std.json.ObjectMap, stats: *ImportStats) !?ImportedObject {
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
    defer git.freeStringList(allocator, labels);
    const assignees = try githubNamedArray(allocator, pull.get("assignees"), "login");
    defer git.freeStringList(allocator, assignees);
    const reviewers = try githubPullReviewers(allocator, pull);
    defer git.freeStringList(allocator, reviewers);
    const comment_count = githubOptionalUnsignedField(pull, &.{ "comments", "comment_count" });

    const pull_id = try util.newUuidV7(allocator);
    errdefer allocator.free(pull_id);
    try eprint("gt github import: importing pull #{d}\n", .{number});
    try writeImportedPullOpened(
        allocator,
        writer,
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
            .commit_count = githubOptionalUnsignedField(pull, &.{ "commits", "commit_count" }),
            .changed_files = githubOptionalUnsignedField(pull, &.{ "changed_files", "files_changed", "file_count" }),
            .additions = githubOptionalUnsignedField(pull, &.{"additions"}),
            .deletions = githubOptionalUnsignedField(pull, &.{"deletions"}),
        },
    );
    stats.pulls += 1;

    if (event_mod.jsonString(pull.get("state"))) |state| {
        if (std.mem.eql(u8, state, "closed")) {
            if (event_mod.jsonString(pull.get("merged_at"))) |merged_at| {
                if (merged_at.len != 0) {
                    try writeImportedPullMerged(allocator, writer, pull_id, merged_at, event_mod.jsonString(pull.get("merge_commit_sha")) orelse "", null);
                    return .{ .id = pull_id, .is_new = true, .comment_count = comment_count };
                }
            }
            const closed_at = try githubTimestampOrNow(allocator, firstJsonValue(pull.get("closed_at"), pull.get("updated_at")));
            defer allocator.free(closed_at);
            try writeImportedStringEvent(allocator, writer, "pull", pull_id, "pull.state_set", "state", "closed", closed_at);
        }
    }

    return .{ .id = pull_id, .is_new = true, .comment_count = comment_count };
}

fn shouldFetchApiComments(comment_count: ?u64) bool {
    return comment_count == null or comment_count.? != 0;
}

fn importCommentsArray(
    allocator: Allocator,
    writer: *EventWriter,
    parent_kind: []const u8,
    parent_id: []const u8,
    comments: std.json.Array,
    stats: *ImportStats,
) !void {
    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();
    try index.ensureIndex(allocator, repo);
    var db = try index.SqliteDb.open(allocator, repo.index_path, index.sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    var comment_refs = std.AutoHashMap(i64, ImportedCommentRef).init(allocator);
    defer freeImportedCommentRefs(allocator, &comment_refs);

    try importCommentsArrayWithContext(allocator, &db, &comment_refs, writer, parent_kind, parent_id, comments, stats);
}

fn importCommentsArrayWithContext(
    allocator: Allocator,
    db: *index.SqliteDb,
    comment_refs: *std.AutoHashMap(i64, ImportedCommentRef),
    writer: *EventWriter,
    parent_kind: []const u8,
    parent_id: []const u8,
    comments: std.json.Array,
    stats: *ImportStats,
) !void {
    var imported: usize = 0;
    for (comments.items) |item| {
        if (item != .object) continue;
        const body = try githubSizedString(allocator, event_mod.jsonString(item.object.get("body")), "", git.max_payload_text_bytes);
        defer allocator.free(body);
        if (std.mem.trim(u8, body, " \t\r\n").len == 0) continue;
        const occurred_at = try githubTimestampOrNow(allocator, item.object.get("created_at"));
        defer allocator.free(occurred_at);
        if (try importedCommentExists(db, parent_kind, parent_id, occurred_at, body)) continue;
        const source_author = try githubSizedString(allocator, githubAuthorLogin(item.object), "", git.max_payload_atom_bytes);
        defer allocator.free(source_author);
        const reply = try importedCommentReply(allocator, item.object, comment_refs);
        defer if (reply.parent_id) |value| allocator.free(value);
        defer if (reply.parent_hash) |value| allocator.free(value);
        var written = try writeImportedCommentAdded(
            allocator,
            writer,
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

fn freeImportedCommentRefs(allocator: Allocator, comment_refs: *std.AutoHashMap(i64, ImportedCommentRef)) void {
    var values = comment_refs.valueIterator();
    while (values.next()) |value| value.deinit(allocator);
    comment_refs.deinit();
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
    writer: *EventWriter,
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
        writer.stagedEventParents(),
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
    const commit = try writer.stage("gt github import", subject, body);
    allocator.free(commit);
}

fn writeImportedPullOpened(
    allocator: Allocator,
    writer: *EventWriter,
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
        writer.stagedEventParents(),
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
    const commit = try writer.stage("gt github import", subject, body);
    allocator.free(commit);
}

fn writeImportedStringEvent(
    allocator: Allocator,
    writer: *EventWriter,
    object_kind: []const u8,
    object_id: []const u8,
    event_type: []const u8,
    payload_key: []const u8,
    payload_value: []const u8,
    occurred_at: []const u8,
) !void {
    const event_uuid = try util.newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try util.newUuidV7(allocator);
    defer allocator.free(idem);
    const body = if (std.mem.eql(u8, object_kind, "issue"))
        try event_mod.buildIssueStringPayloadJson(allocator, writer.cfg, writer.nextSeq(), object_id, event_uuid, idem, occurred_at, writer.stagedEventParents(), event_type, payload_key, payload_value)
    else
        try event_mod.buildPullStringPayloadJson(allocator, writer.cfg, writer.nextSeq(), object_id, event_uuid, idem, occurred_at, writer.stagedEventParents(), event_type, payload_key, payload_value);
    defer allocator.free(body);
    var object_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const object_ref = util.shortObjectRef(&object_ref_buf, object_id);
    const subject = try std.fmt.allocPrint(allocator, "{s} #{s}", .{ event_type, object_ref });
    defer allocator.free(subject);
    const commit = try writer.stage("gt github import", subject, body);
    allocator.free(commit);
}

fn writeImportedIssueProjectAdded(
    allocator: Allocator,
    writer: *EventWriter,
    issue_id: []const u8,
    occurred_at: []const u8,
    project: []const u8,
    column: []const u8,
) !void {
    const event_uuid = try util.newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try util.newUuidV7(allocator);
    defer allocator.free(idem);
    const body = try event_mod.buildIssueProjectEventJson(allocator, writer.cfg, writer.nextSeq(), issue_id, event_uuid, idem, occurred_at, writer.stagedEventParents(), "issue.project_added", project, column, null, null);
    defer allocator.free(body);
    var issue_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const issue_ref = util.shortObjectRef(&issue_ref_buf, issue_id);
    const subject = try std.fmt.allocPrint(allocator, "issue.project_added #{s} {s}", .{ issue_ref, project });
    defer allocator.free(subject);
    const commit = try writer.stage("gt github import", subject, body);
    allocator.free(commit);
}

fn writeImportedPullMerged(
    allocator: Allocator,
    writer: *EventWriter,
    pull_id: []const u8,
    occurred_at: []const u8,
    merge_oid: []const u8,
    target_oid: ?[]const u8,
) !void {
    const event_uuid = try util.newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try util.newUuidV7(allocator);
    defer allocator.free(idem);
    const body = try event_mod.buildPullMergedJson(allocator, writer.cfg, writer.nextSeq(), pull_id, event_uuid, idem, occurred_at, writer.stagedEventParents(), if (merge_oid.len == 0) null else merge_oid, target_oid);
    defer allocator.free(body);
    var pull_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const pull_ref = util.shortObjectRef(&pull_ref_buf, pull_id);
    const subject = try std.fmt.allocPrint(allocator, "pull.merged #{s}", .{pull_ref});
    defer allocator.free(subject);
    const commit = try writer.stage("gt github import", subject, body);
    allocator.free(commit);
}

fn writeImportedCommentAdded(
    allocator: Allocator,
    writer: *EventWriter,
    parent_kind: []const u8,
    parent_id: []const u8,
    occurred_at: []const u8,
    body_text: []const u8,
    source_author: []const u8,
    reply_parent_id: []const u8,
    reply_parent_hash: []const u8,
) !ImportedCommentRef {
    var comment_id: ?[]u8 = try util.newUuidV7(allocator);
    errdefer if (comment_id) |value| allocator.free(value);
    const event_uuid = try util.newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try util.newUuidV7(allocator);
    defer allocator.free(idem);
    var related: std.ArrayList([]const u8) = .empty;
    defer related.deinit(allocator);
    const base_parents = writer.stagedEventParents();
    try related.appendSlice(allocator, base_parents.related);
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
        .log = base_parents.log,
        .anchor = base_parents.anchor,
        .causal = base_parents.causal,
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
    const commit = try writer.stage("gt github import", subject, body);
    errdefer allocator.free(commit);
    const result = ImportedCommentRef{
        .id = comment_id.?,
        .event_hash = commit,
    };
    comment_id = null;
    return result;
}
