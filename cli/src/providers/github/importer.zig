const std = @import("std");
const event_model = @import("../../event/model.zig");
const event_builders = @import("../../event/builders.zig");
const event_json = @import("../../event/json.zig");
const event_writer_mod = @import("../../event_writer.zig");
const errors = @import("../../errors.zig");
const git = @import("../../git.zig");
const index = @import("../../index.zig");
const io = @import("../../io.zig");
const json_writer = @import("../../json_writer.zig");
const milestone_mod = @import("../../milestone.zig");
const repo_mod = @import("../../repo.zig");
const util = @import("../../util.zig");
const import_bot = @import("../import_bot.zig");
const provider_common = @import("../common.zig");
const common = @import("common.zig");
const exporter = @import("exporter.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const EventWriter = event_writer_mod.EventWriter;
const out = io.out;
const eprint = io.eprint;
const RepoSlug = common.RepoSlug;
const GitHubClient = common.GitHubClient;
const ApiMode = common.ApiMode;
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
const firstJsonValue3 = common.firstJsonValue3;
const githubStateEquals = common.githubStateEquals;
const ensureMilestoneCreatedForTitleStaged = milestone_mod.ensureMilestoneCreatedForTitleStaged;

const github_import_capability = "github.import";
const github_import_scope = "github:*";

const GithubSourceIdentity = struct {
    author: []u8,
    identity: []u8,
    email: []u8,
    avatar_url: []u8,

    fn deinit(self: GithubSourceIdentity, allocator: Allocator) void {
        allocator.free(self.author);
        allocator.free(self.identity);
        allocator.free(self.email);
        allocator.free(self.avatar_url);
    }
};

pub const ImportOptions = struct {
    base: provider_common.BaseImportOptions = .{
        .api_url = default_api_url,
        .bot_device = import_bot.github_device,
    },
    repo: ?RepoSlug = null,
    include_projects: bool = true,
    use_gh: bool = false,
    mode: ApiMode = .graphql,
};

const ImportArgParser = struct {
    pub const command_context = "gt github import";
    pub const token_help = "--token-env, --token-file, GITHUB_TOKEN, or GH_TOKEN";

    pub fn parseProviderArg(_: Allocator, args: []const []const u8, i: *usize, arg: []const u8, options: *ImportOptions) !bool {
        if (std.mem.eql(u8, arg, "--repo")) {
            options.repo = try parseRepoSlug(try util.requireValue(args, i, "--repo"));
        } else if (std.mem.eql(u8, arg, "--no-projects")) {
            options.include_projects = false;
        } else if (std.mem.eql(u8, arg, "--rest")) {
            options.mode = .rest;
        } else if (std.mem.eql(u8, arg, "--graphql")) {
            options.mode = .graphql;
        } else {
            return false;
        }
        return true;
    }
};

pub fn cmdImport(allocator: Allocator, args: []const []const u8) !void {
    var options = ImportOptions{};
    var parsed_args = try provider_common.parseImportArgs(allocator, args, &options, ImportArgParser);
    defer parsed_args.deinit();
    var resolved_repo_owned: ?[]u8 = null;
    defer if (resolved_repo_owned) |value| allocator.free(value);

    if (options.repo == null and options.base.from_file == null) {
        if (options.base.token_arg == null and std.mem.eql(u8, options.base.api_url, default_api_url)) {
            options.use_gh = true;
            if (options.mode == .graphql) {
                resolved_repo_owned = try resolveCurrentRepo(allocator);
                options.repo = try parseRepoSlug(resolved_repo_owned.?);
            } else {
                options.repo = gh_current_repo;
            }
        } else {
            try eprint("gt github import: --repo or --from-file is required\n", .{});
            return CliError.MissingArgument;
        }
    }

    try eprint("gt github import: preparing delegated import actor {s}/{s}\n", .{ options.base.bot_principal, options.base.bot_device });
    try ensureImportDelegation(allocator, options.base.bot_principal, options.base.bot_device);

    var token_owned: ?[]u8 = null;
    defer if (token_owned) |value| allocator.free(value);
    const token: ?[]const u8 = if (options.use_gh) null else options.base.token_arg orelse blk: {
        token_owned = githubTokenFromEnv(allocator) catch null;
        break :blk token_owned;
    };

    var stats = ImportStats{};
    if (options.base.from_file) |path| {
        try eprint("gt github import: reading fixture {s}\n", .{path});
        try importFromFile(allocator, path, options, &stats);
    } else {
        const client = GitHubClient{
            .allocator = allocator,
            .api_url = options.base.api_url,
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

pub const ImportStats = struct {
    issues: usize = 0,
    pulls: usize = 0,
    comments: usize = 0,
    project_cards: usize = 0,
};

pub const WebhookImportOptions = struct {
    bot_principal: []const u8 = import_bot.principal,
    bot_device: []const u8 = import_bot.github_device,
    map_file: ?[]const u8 = null,
};

pub fn importWebhookPayload(allocator: Allocator, event_name: []const u8, payload_bytes: []const u8, options: WebhookImportOptions) !ImportStats {
    try ensureImportDelegation(allocator, options.bot_principal, options.bot_device);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload_bytes, .{}) catch {
        try eprint("gt github live: webhook payload must contain JSON\n", .{});
        return CliError.InvalidArgument;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => {
            try eprint("gt github live: webhook payload must contain a JSON object\n", .{});
            return CliError.InvalidArgument;
        },
    };

    var stats = ImportStats{};
    if (std.mem.eql(u8, event_name, "ping")) return stats;

    if (std.mem.eql(u8, event_name, "issues")) {
        const issue = switch (root.get("issue") orelse return stats) {
            .object => |object| object,
            else => return stats,
        };
        if (issue.get("pull_request") != null) return stats;
        var writer = try EventWriter.initForActor(allocator, "gt github live", options.bot_principal, options.bot_device);
        defer writer.deinit();
        const result = try importIssueObject(allocator, &writer, issue, &.{}, options.map_file, &stats);
        defer if (result) |value| allocator.free(value.id);
        if (result != null) try writer.commitStaged();
        return stats;
    }

    if (std.mem.eql(u8, event_name, "pull_request")) {
        const pull = switch (root.get("pull_request") orelse return stats) {
            .object => |object| object,
            else => return stats,
        };
        var writer = try EventWriter.initForActor(allocator, "gt github live", options.bot_principal, options.bot_device);
        defer writer.deinit();
        const result = try importPullObject(allocator, &writer, pull, options.map_file, &stats);
        defer if (result) |value| allocator.free(value.id);
        if (result != null) try writer.commitStaged();
        return stats;
    }

    if (std.mem.eql(u8, event_name, "issue_comment")) {
        const action = event_json.jsonString(root.get("action")) orelse "";
        const issue = switch (root.get("issue") orelse return stats) {
            .object => |object| object,
            else => return stats,
        };
        const comment = switch (root.get("comment") orelse return stats) {
            .object => |object| object,
            else => return stats,
        };
        if (std.mem.eql(u8, action, "created")) {
            try importWebhookIssueComment(allocator, issue, comment, options, &stats);
        } else if (std.mem.eql(u8, action, "edited")) {
            try importWebhookIssueCommentEdited(allocator, comment, options, &stats);
        } else if (std.mem.eql(u8, action, "deleted")) {
            try importWebhookIssueCommentDeleted(allocator, comment, options, &stats);
        }
        return stats;
    }

    return stats;
}

const ImportedObject = struct {
    id: []u8,
    is_new: bool,
    comment_count: ?u64 = null,
};

const ImportedCommentRef = provider_common.ImportedCommentRef;

pub fn ensureImportDelegation(allocator: Allocator, principal: []const u8, device: []const u8) !void {
    try provider_common.ensureImportDelegation(allocator, principal, device, .{
        .command_context = "gt github import",
        .provider_name = "GitHub",
        .capability = github_import_capability,
        .scope = github_import_scope,
    });
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
            var writer = try EventWriter.initForActor(allocator, "gt github import", options.base.bot_principal, options.base.bot_device);
            defer writer.deinit();
            const issue_result = try importIssueObject(allocator, &writer, item.object, projects, null, stats);
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
            var writer = try EventWriter.initForActor(allocator, "gt github import", options.base.bot_principal, options.base.bot_device);
            defer writer.deinit();
            const pull_result = try importPullObject(allocator, &writer, item.object, null, stats);
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
    if (!options.base.include_comments) return;
    const number = jsonInteger(object.get("number")) orelse return;
    const comments_root = switch (root.get("comments") orelse return) {
        .object => |map| map,
        else => return,
    };
    const key = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ parent_kind, number });
    defer allocator.free(key);
    const comments = jsonArray(comments_root.get(key)) orelse return;
    try eprint("gt github import: importing {d} fixture comment{s} for {s} #{d}\n", .{ comments.items.len, if (comments.items.len == 1) "" else "s", parent_kind, number });
    try importCommentsArray(allocator, writer, parent_kind, parent_id, comments, null, stats);
}

fn resolveCurrentRepo(allocator: Allocator) ![]u8 {
    var result = try git.runCommand(allocator, &.{ "gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner" }, null, 512 * 1024);
    defer result.deinit();
    if (result.exitCode() != 0) {
        const stderr = std.mem.trim(u8, result.stderr, " \t\r\n");
        if (stderr.len != 0) {
            try eprint("gt github import: failed to resolve current GitHub repository with gh: {s}\n", .{stderr});
        } else {
            try eprint("gt github import: failed to resolve current GitHub repository with gh\n", .{});
        }
        return CliError.UserError;
    }
    return try util.trimDup(allocator, result.stdout);
}

pub fn importFromApi(allocator: Allocator, client: GitHubClient, options: ImportOptions, stats: *ImportStats) !void {
    return switch (options.mode) {
        .rest => importFromRestApi(allocator, client, options, stats),
        .graphql => importFromGraphqlApi(allocator, client, options, stats),
    };
}

fn importFromRestApi(allocator: Allocator, client: GitHubClient, options: ImportOptions, stats: *ImportStats) !void {
    var page: usize = 1;
    while (page <= options.base.max_pages) : (page += 1) {
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
            var writer = try EventWriter.initForActor(allocator, "gt github import", options.base.bot_principal, options.base.bot_device);
            defer writer.deinit();
            const issue_result = try importIssueObject(allocator, &writer, item.object, &.{}, options.base.map_file, stats);
            defer if (issue_result) |result| allocator.free(result.id);
            if (issue_result) |result| {
                if (result.is_new and shouldFetchApiComments(result.comment_count)) try importApiComments(allocator, &writer, client, "issue", number, result.id, options, stats);
                try writer.commitStaged();
            }
        }
        if (issues.items.len < 100) break;
    }

    page = 1;
    while (page <= options.base.max_pages) : (page += 1) {
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
            var writer = try EventWriter.initForActor(allocator, "gt github import", options.base.bot_principal, options.base.bot_device);
            defer writer.deinit();
            const pull_result = try importApiPullObject(allocator, &writer, client, item.object, options, stats);
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

const graphql_page_query =
    \\query GitomiGithubSyncPage($owner: String!, $name: String!, $issueCursor: String, $pullCursor: String, $includeIssues: Boolean!, $includePulls: Boolean!, $includeComments: Boolean!) {
    \\  repository(owner: $owner, name: $name) {
    \\    issues(first: 100, after: $issueCursor, states: [OPEN, CLOSED], orderBy: {field: CREATED_AT, direction: ASC}) @include(if: $includeIssues) {
    \\      nodes {
    \\        number
    \\        title
    \\        body
    \\        state
    \\        createdAt
    \\        updatedAt
    \\        closedAt
    \\        author { login avatarUrl(size: 96) }
    \\        milestone { title }
    \\        labels(first: 100) { nodes { name } }
    \\        assignees(first: 100) { nodes { login } }
    \\        comments(first: 100) @include(if: $includeComments) {
    \\          totalCount
    \\          nodes { databaseId body createdAt author { login avatarUrl(size: 96) } }
    \\          pageInfo { hasNextPage endCursor }
    \\        }
    \\      }
    \\      pageInfo { hasNextPage endCursor }
    \\    }
    \\    pullRequests(first: 100, after: $pullCursor, states: [OPEN, CLOSED, MERGED], orderBy: {field: CREATED_AT, direction: ASC}) @include(if: $includePulls) {
    \\      nodes {
    \\        number
    \\        title
    \\        body
    \\        state
    \\        isDraft
    \\        createdAt
    \\        updatedAt
    \\        closedAt
    \\        mergedAt
    \\        mergeCommit { oid }
    \\        baseRefName
    \\        headRefName
    \\        author { login avatarUrl(size: 96) }
    \\        labels(first: 100) { nodes { name } }
    \\        assignees(first: 100) { nodes { login } }
    \\        reviewRequests(first: 100) {
    \\          nodes {
    \\            requestedReviewer {
    \\              ... on User { login }
    \\              ... on Team { slug name }
    \\            }
    \\          }
    \\        }
    \\        comments(first: 100) @include(if: $includeComments) {
    \\          totalCount
    \\          nodes { databaseId body createdAt author { login avatarUrl(size: 96) } }
    \\          pageInfo { hasNextPage endCursor }
    \\        }
    \\        commits { totalCount }
    \\        changedFiles
    \\        additions
    \\        deletions
    \\      }
    \\      pageInfo { hasNextPage endCursor }
    \\    }
    \\  }
    \\}
;

const graphql_comments_query =
    \\query GitomiGithubSyncComments($owner: String!, $name: String!, $number: Int!, $cursor: String, $isPull: Boolean!) {
    \\  repository(owner: $owner, name: $name) {
    \\    issue(number: $number) @skip(if: $isPull) {
    \\      comments(first: 100, after: $cursor) {
    \\        totalCount
    \\        nodes { databaseId body createdAt author { login avatarUrl(size: 96) } }
    \\        pageInfo { hasNextPage endCursor }
    \\      }
    \\    }
    \\    pullRequest(number: $number) @include(if: $isPull) {
    \\      comments(first: 100, after: $cursor) {
    \\        totalCount
    \\        nodes { databaseId body createdAt author { login avatarUrl(size: 96) } }
    \\        pageInfo { hasNextPage endCursor }
    \\      }
    \\    }
    \\  }
    \\}
;

fn importFromGraphqlApi(allocator: Allocator, client: GitHubClient, options: ImportOptions, stats: *ImportStats) !void {
    var issue_cursor: ?[]u8 = null;
    defer if (issue_cursor) |value| allocator.free(value);
    var pull_cursor: ?[]u8 = null;
    defer if (pull_cursor) |value| allocator.free(value);
    var issue_done = false;
    var pull_done = false;

    var page: usize = 1;
    while (page <= options.base.max_pages and (!issue_done or !pull_done)) : (page += 1) {
        try eprint("gt github import: fetching GraphQL batch page {d}\n", .{page});
        const body = try githubGraphqlPageBody(allocator, client.repo, issue_cursor, pull_cursor, !issue_done, !pull_done, options.base.include_comments);
        defer allocator.free(body);
        const raw = try client.graphqlRequest(body);
        defer allocator.free(raw);
        var parsed = try parseGraphqlResponse(allocator, raw, "gt github import");
        defer parsed.deinit();

        const repository = graphqlRepository(parsed.value) orelse break;
        if (!issue_done) {
            if (jsonObject(repository.get("issues"))) |issues| {
                const count = try importGraphqlIssues(allocator, client, options, issues, stats);
                try eprint("gt github import: GraphQL issues page {d}: {d} record{s}\n", .{ page, count, if (count == 1) "" else "s" });
                try replaceOptionalString(allocator, &issue_cursor, connectionEndCursor(issues));
                issue_done = !connectionHasNextPage(issues);
            } else {
                issue_done = true;
            }
        }
        if (!pull_done) {
            if (jsonObject(repository.get("pullRequests"))) |pulls| {
                const count = try importGraphqlPulls(allocator, client, options, pulls, stats);
                try eprint("gt github import: GraphQL pulls page {d}: {d} record{s}\n", .{ page, count, if (count == 1) "" else "s" });
                try replaceOptionalString(allocator, &pull_cursor, connectionEndCursor(pulls));
                pull_done = !connectionHasNextPage(pulls);
            } else {
                pull_done = true;
            }
        }
    }

    if (options.include_projects) {
        importClassicProjects(allocator, client, options, stats) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => try eprint("gt github import: project import skipped: {s}\n", .{@errorName(err)}),
        };
    }
}

fn importGraphqlIssues(
    allocator: Allocator,
    client: GitHubClient,
    options: ImportOptions,
    issues: std.json.ObjectMap,
    stats: *ImportStats,
) !usize {
    const nodes = connectionNodes(issues) orelse return 0;
    for (nodes.items) |item| {
        if (item != .object) continue;
        const number = jsonInteger(item.object.get("number")) orelse continue;
        var writer = try EventWriter.initForActor(allocator, "gt github import", options.base.bot_principal, options.base.bot_device);
        defer writer.deinit();
        const issue_result = try importIssueObject(allocator, &writer, item.object, &.{}, options.base.map_file, stats);
        defer if (issue_result) |result| allocator.free(result.id);
        if (issue_result) |result| {
            if (result.is_new and options.base.include_comments) {
                try importGraphqlComments(allocator, &writer, client, "issue", number, result.id, item.object.get("comments"), options, stats);
            }
            try writer.commitStaged();
        }
    }
    return nodes.items.len;
}

fn importGraphqlPulls(
    allocator: Allocator,
    client: GitHubClient,
    options: ImportOptions,
    pulls: std.json.ObjectMap,
    stats: *ImportStats,
) !usize {
    const nodes = connectionNodes(pulls) orelse return 0;
    for (nodes.items) |item| {
        if (item != .object) continue;
        const number = jsonInteger(item.object.get("number")) orelse continue;
        var writer = try EventWriter.initForActor(allocator, "gt github import", options.base.bot_principal, options.base.bot_device);
        defer writer.deinit();
        const pull_result = try importPullObject(allocator, &writer, item.object, options.base.map_file, stats);
        defer if (pull_result) |result| allocator.free(result.id);
        if (pull_result) |result| {
            if (result.is_new and options.base.include_comments) {
                try importGraphqlComments(allocator, &writer, client, "pull", number, result.id, item.object.get("comments"), options, stats);
            }
            try writer.commitStaged();
        }
    }
    return nodes.items.len;
}

fn importGraphqlComments(
    allocator: Allocator,
    writer: *EventWriter,
    client: GitHubClient,
    parent_kind: []const u8,
    number: i64,
    parent_id: []const u8,
    initial_comments: ?std.json.Value,
    options: ImportOptions,
    stats: *ImportStats,
) !void {
    const first_connection = jsonObject(initial_comments) orelse return;

    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();
    try index.ensureIndex(allocator, repo);
    var db = try index.SqliteDb.open(allocator, repo.index_path, index.sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    var comment_refs = std.AutoHashMap(i64, ImportedCommentRef).init(allocator);
    defer freeImportedCommentRefs(allocator, &comment_refs);

    var total: usize = 0;
    if (connectionNodes(first_connection)) |nodes| {
        total += nodes.items.len;
        try importCommentsArrayWithContext(allocator, &db, &comment_refs, writer, parent_kind, parent_id, nodes, options.base.map_file, stats);
    }

    var cursor: ?[]u8 = null;
    defer if (cursor) |value| allocator.free(value);
    try replaceOptionalString(allocator, &cursor, connectionEndCursor(first_connection));
    var has_next = connectionHasNextPage(first_connection);
    var page: usize = 2;
    while (has_next and page <= options.base.max_pages) : (page += 1) {
        try eprint("gt github import: fetching GraphQL comments for {s} #{d} page {d}\n", .{ parent_kind, number, page });
        const body = try githubGraphqlCommentsBody(allocator, client.repo, parent_kind, number, cursor);
        defer allocator.free(body);
        const raw = try client.graphqlRequest(body);
        defer allocator.free(raw);
        var parsed = try parseGraphqlResponse(allocator, raw, "gt github import");
        defer parsed.deinit();
        const repository = graphqlRepository(parsed.value) orelse break;
        const parent = if (std.mem.eql(u8, parent_kind, "pull"))
            jsonObject(repository.get("pullRequest")) orelse break
        else
            jsonObject(repository.get("issue")) orelse break;
        const comments = jsonObject(parent.get("comments")) orelse break;
        if (connectionNodes(comments)) |nodes| {
            total += nodes.items.len;
            try importCommentsArrayWithContext(allocator, &db, &comment_refs, writer, parent_kind, parent_id, nodes, options.base.map_file, stats);
        }
        try replaceOptionalString(allocator, &cursor, connectionEndCursor(comments));
        has_next = connectionHasNextPage(comments);
    }
    try eprint("gt github import: {s} #{d}: {d} GraphQL comment{s}\n", .{ parent_kind, number, total, if (total == 1) "" else "s" });
}

fn githubGraphqlPageBody(
    allocator: Allocator,
    repo: RepoSlug,
    issue_cursor: ?[]const u8,
    pull_cursor: ?[]const u8,
    include_issues: bool,
    include_pulls: bool,
    include_comments: bool,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '{');
    try json_writer.appendJsonFieldString(&buf, allocator, "query", graphql_page_query, true);
    try buf.appendSlice(allocator, "\"variables\":{");
    try json_writer.appendJsonFieldString(&buf, allocator, "owner", repo.owner, true);
    try json_writer.appendJsonFieldString(&buf, allocator, "name", repo.name, true);
    try appendJsonNullableStringField(&buf, allocator, "issueCursor", issue_cursor, true);
    try appendJsonNullableStringField(&buf, allocator, "pullCursor", pull_cursor, true);
    try json_writer.appendJsonFieldBool(&buf, allocator, "includeIssues", include_issues, true);
    try json_writer.appendJsonFieldBool(&buf, allocator, "includePulls", include_pulls, true);
    try json_writer.appendJsonFieldBool(&buf, allocator, "includeComments", include_comments, false);
    try buf.appendSlice(allocator, "}}");
    return try buf.toOwnedSlice(allocator);
}

fn githubGraphqlCommentsBody(
    allocator: Allocator,
    repo: RepoSlug,
    parent_kind: []const u8,
    number: i64,
    cursor: ?[]const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '{');
    try json_writer.appendJsonFieldString(&buf, allocator, "query", graphql_comments_query, true);
    try buf.appendSlice(allocator, "\"variables\":{");
    try json_writer.appendJsonFieldString(&buf, allocator, "owner", repo.owner, true);
    try json_writer.appendJsonFieldString(&buf, allocator, "name", repo.name, true);
    try json_writer.appendJsonFieldInteger(&buf, allocator, "number", number, true);
    try appendJsonNullableStringField(&buf, allocator, "cursor", cursor, true);
    try json_writer.appendJsonFieldBool(&buf, allocator, "isPull", std.mem.eql(u8, parent_kind, "pull"), false);
    try buf.appendSlice(allocator, "}}");
    return try buf.toOwnedSlice(allocator);
}

fn appendJsonNullableStringField(buf: *std.ArrayList(u8), allocator: Allocator, key: []const u8, value: ?[]const u8, comma: bool) !void {
    try json_writer.appendJsonString(buf, allocator, key);
    try buf.append(allocator, ':');
    if (value) |actual| {
        try json_writer.appendJsonString(buf, allocator, actual);
    } else {
        try buf.appendSlice(allocator, "null");
    }
    if (comma) try buf.append(allocator, ',');
}

fn parseGraphqlResponse(allocator: Allocator, raw: []const u8, command: []const u8) !std.json.Parsed(std.json.Value) {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch {
        try eprint("{s}: GraphQL response must contain JSON\n", .{command});
        return CliError.InvalidArgument;
    };
    errdefer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => {
            try eprint("{s}: GraphQL response must contain a JSON object\n", .{command});
            return CliError.InvalidArgument;
        },
    };
    if (jsonArray(root.get("errors"))) |errors_array| {
        if (errors_array.items.len != 0) {
            if (errors_array.items[0] == .object) {
                const message = event_json.jsonString(errors_array.items[0].object.get("message")) orelse "unknown GraphQL error";
                try eprint("{s}: GraphQL request failed: {s}\n", .{ command, message });
            } else {
                try eprint("{s}: GraphQL request failed\n", .{command});
            }
            return CliError.UserError;
        }
    }
    return parsed;
}

fn graphqlRepository(value: std.json.Value) ?std.json.ObjectMap {
    const root = switch (value) {
        .object => |object| object,
        else => return null,
    };
    const data = jsonObject(root.get("data")) orelse return null;
    return jsonObject(data.get("repository"));
}

fn jsonObject(value: ?std.json.Value) ?std.json.ObjectMap {
    return switch (value orelse return null) {
        .object => |object| object,
        else => null,
    };
}

fn connectionNodes(connection: std.json.ObjectMap) ?std.json.Array {
    return jsonArray(connection.get("nodes"));
}

fn connectionHasNextPage(connection: std.json.ObjectMap) bool {
    const page_info = jsonObject(connection.get("pageInfo")) orelse return false;
    return jsonBool(page_info.get("hasNextPage")) orelse false;
}

fn connectionEndCursor(connection: std.json.ObjectMap) ?[]const u8 {
    const page_info = jsonObject(connection.get("pageInfo")) orelse return null;
    return event_json.jsonString(page_info.get("endCursor"));
}

fn replaceOptionalString(allocator: Allocator, target: *?[]u8, value: ?[]const u8) !void {
    if (target.*) |old| allocator.free(old);
    target.* = null;
    if (value) |actual| {
        if (actual.len != 0) target.* = try allocator.dupe(u8, actual);
    }
}

fn importApiPullObject(
    allocator: Allocator,
    writer: *EventWriter,
    client: GitHubClient,
    summary: std.json.ObjectMap,
    options: ImportOptions,
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
    return try importPullObject(allocator, writer, pull, options.base.map_file, stats);
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
    if (!options.base.include_comments) return;

    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();
    try index.ensureIndex(allocator, repo);
    var db = try index.SqliteDb.open(allocator, repo.index_path, index.sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    var comment_refs = std.AutoHashMap(i64, ImportedCommentRef).init(allocator);
    defer freeImportedCommentRefs(allocator, &comment_refs);

    var total: usize = 0;
    var page: usize = 1;
    while (page <= options.base.max_pages) : (page += 1) {
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
        try importCommentsArrayWithContext(allocator, &db, &comment_refs, writer, parent_kind, parent_id, comments, options.base.map_file, stats);
        if (comments.items.len < 100) break;
    }
    try eprint("gt github import: {s} #{d}: {d} comment{s}\n", .{ parent_kind, number, total, if (total == 1) "" else "s" });
}

fn importWebhookIssueComment(
    allocator: Allocator,
    issue: std.json.ObjectMap,
    comment: std.json.ObjectMap,
    options: WebhookImportOptions,
    stats: *ImportStats,
) !void {
    const number = jsonInteger(issue.get("number")) orelse return;
    const parent_kind: []const u8 = if (issue.get("pull_request") == null) "issue" else "pull";
    if (try mappedWebhookObjectId(allocator, options.map_file, "comment", comment)) |existing| {
        allocator.free(existing);
        return;
    }

    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();
    try index.ensureIndex(allocator, repo);

    var parent_id_owned: ?[]u8 = try lookupGithubObjectId(allocator, repo, options.map_file, parent_kind, number);
    defer if (parent_id_owned) |value| allocator.free(value);

    var writer = try EventWriter.initForActor(allocator, "gt github live", options.bot_principal, options.bot_device);
    defer writer.deinit();

    var imported_parent: ?ImportedObject = null;
    defer if (imported_parent) |value| allocator.free(value.id);
    if (parent_id_owned == null and std.mem.eql(u8, parent_kind, "issue")) {
        imported_parent = try importIssueObject(allocator, &writer, issue, &.{}, options.map_file, stats);
        if (imported_parent) |value| parent_id_owned = try allocator.dupe(u8, value.id);
    }

    const parent_id = parent_id_owned orelse return;
    var comments = std.json.Array.init(allocator);
    defer comments.deinit();
    try comments.append(.{ .object = comment });
    try importCommentsArray(allocator, &writer, parent_kind, parent_id, comments, options.map_file, stats);
    try writer.commitStaged();
}

fn importWebhookIssueCommentEdited(
    allocator: Allocator,
    comment: std.json.ObjectMap,
    options: WebhookImportOptions,
    stats: *ImportStats,
) !void {
    const comment_id = (try mappedWebhookObjectId(allocator, options.map_file, "comment", comment)) orelse return;
    defer allocator.free(comment_id);

    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();
    try index.ensureIndex(allocator, repo);
    var db = try index.SqliteDb.open(allocator, repo.index_path, index.sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    const current = (try localCommentState(allocator, &db, comment_id)) orelse return;
    defer current.deinit(allocator);
    if (current.redacted) return;

    const body = try githubSizedString(allocator, event_json.jsonString(comment.get("body")), "", git.max_payload_text_bytes);
    defer allocator.free(body);
    if (std.mem.eql(u8, current.body, body)) return;

    const occurred_at = try githubTimestampOrNow(allocator, firstJsonValue(comment.get("updated_at"), comment.get("created_at")));
    defer allocator.free(occurred_at);

    var writer = try EventWriter.initForActor(allocator, "gt github live", options.bot_principal, options.bot_device);
    defer writer.deinit();
    try writeImportedCommentBodySet(allocator, &writer, comment_id, occurred_at, body);
    try writer.commitStaged();
    stats.comments += 1;
}

fn importWebhookIssueCommentDeleted(
    allocator: Allocator,
    comment: std.json.ObjectMap,
    options: WebhookImportOptions,
    stats: *ImportStats,
) !void {
    const comment_id = (try mappedWebhookObjectId(allocator, options.map_file, "comment", comment)) orelse return;
    defer allocator.free(comment_id);

    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();
    try index.ensureIndex(allocator, repo);
    var db = try index.SqliteDb.open(allocator, repo.index_path, index.sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    const current = (try localCommentState(allocator, &db, comment_id)) orelse return;
    defer current.deinit(allocator);
    if (current.redacted) return;

    const occurred_at = try githubTimestampOrNow(allocator, firstJsonValue(comment.get("updated_at"), comment.get("created_at")));
    defer allocator.free(occurred_at);

    var writer = try EventWriter.initForActor(allocator, "gt github live", options.bot_principal, options.bot_device);
    defer writer.deinit();
    try writeImportedCommentRedacted(allocator, &writer, comment_id, occurred_at, "deleted on GitHub");
    try writer.commitStaged();
    stats.comments += 1;
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
        const project_name = event_json.jsonString(project_value.object.get("name")) orelse
            event_json.jsonString(project_value.object.get("title")) orelse
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
        const column_name = event_json.jsonString(column_value.object.get("name")) orelse "";
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
        const content_url = event_json.jsonString(card_value.object.get("content_url")) orelse continue;
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
        var writer = try EventWriter.initForActor(allocator, "gt github import", options.base.bot_principal, options.base.bot_device);
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

fn lookupGithubObjectId(
    allocator: Allocator,
    repo: repo_mod.Repo,
    map_file: ?[]const u8,
    object_kind: []const u8,
    number: i64,
) !?[]u8 {
    if (map_file) |path| {
        if (try exporter.lookupMappedObjectId(allocator, path, object_kind, number)) |existing| return existing;
    }
    return try index.lookupLegacyGithubObjectId(allocator, repo, object_kind, number);
}

fn mappedWebhookObjectId(allocator: Allocator, map_file: ?[]const u8, object_kind: []const u8, object: std.json.ObjectMap) !?[]u8 {
    const path = map_file orelse return null;
    const number = jsonInteger(object.get("id")) orelse return null;
    return try exporter.lookupMappedObjectId(allocator, path, object_kind, number);
}

pub fn issueNumberFromContentUrl(url: []const u8) ?i64 {
    const marker = "/issues/";
    const idx = std.mem.lastIndexOf(u8, url, marker) orelse return null;
    const raw = url[idx + marker.len ..];
    if (raw.len == 0) return null;
    return std.fmt.parseInt(i64, raw, 10) catch null;
}

fn githubSourceIdentityOwned(allocator: Allocator, object: std.json.ObjectMap) !GithubSourceIdentity {
    const author = try githubSizedString(allocator, githubAuthorLogin(object), "", git.max_payload_atom_bytes);
    errdefer allocator.free(author);
    const email = try githubSizedString(allocator, githubAuthorEmail(object), "", git.max_payload_atom_bytes);
    errdefer allocator.free(email);
    const avatar_url = try githubSizedString(allocator, githubAuthorAvatarUrl(object), "", git.max_payload_ref_bytes);
    errdefer allocator.free(avatar_url);
    const identity = try githubAuthorIdentityOwned(allocator, object, avatar_url);
    errdefer allocator.free(identity);
    return .{
        .author = author,
        .identity = identity,
        .email = email,
        .avatar_url = avatar_url,
    };
}

fn githubAuthorIdentityOwned(allocator: Allocator, object: std.json.ObjectMap, avatar_url: []const u8) ![]u8 {
    if (event_json.jsonString(object.get("source_identity"))) |value| {
        if (value.len != 0) return githubSizedString(allocator, value, "", git.max_payload_ref_bytes);
    }
    if (githubAuthorNumericId(object)) |id| {
        return std.fmt.allocPrint(allocator, "github:{d}", .{id});
    }
    if (githubAvatarNumericId(avatar_url)) |id| {
        return std.fmt.allocPrint(allocator, "github:{s}", .{id});
    }
    if (githubAuthorNodeId(object)) |id| {
        return std.fmt.allocPrint(allocator, "github-node:{s}", .{id});
    }
    return allocator.dupe(u8, "");
}

fn githubAuthorNumericId(object: std.json.ObjectMap) ?i64 {
    if (nestedInteger(object, "user", "id")) |value| if (value > 0) return value;
    if (nestedInteger(object, "author", "databaseId")) |value| if (value > 0) return value;
    if (nestedInteger(object, "author", "id")) |value| if (value > 0) return value;
    if (jsonInteger(object.get("author_id"))) |value| if (value > 0) return value;
    if (jsonInteger(object.get("user_id"))) |value| if (value > 0) return value;
    return null;
}

fn githubAuthorNodeId(object: std.json.ObjectMap) ?[]const u8 {
    if (nestedString(object, "author", "id")) |value| return value;
    if (nestedString(object, "user", "node_id")) |value| return value;
    if (event_json.jsonString(object.get("author_node_id"))) |value| return value;
    if (event_json.jsonString(object.get("user_node_id"))) |value| return value;
    return null;
}

fn githubAuthorAvatarUrl(object: std.json.ObjectMap) ?[]const u8 {
    if (event_json.jsonString(object.get("source_avatar_url"))) |value| return value;
    if (nestedString(object, "user", "avatar_url")) |value| return value;
    if (nestedString(object, "author", "avatarUrl")) |value| return value;
    if (nestedString(object, "author", "avatar_url")) |value| return value;
    if (event_json.jsonString(object.get("author_avatar_url"))) |value| return value;
    if (event_json.jsonString(object.get("user_avatar_url"))) |value| return value;
    return null;
}

fn githubAuthorEmail(object: std.json.ObjectMap) ?[]const u8 {
    if (event_json.jsonString(object.get("source_email"))) |value| return value;
    if (nestedString(object, "user", "email")) |value| return value;
    if (nestedString(object, "author", "email")) |value| return value;
    if (event_json.jsonString(object.get("author_email"))) |value| return value;
    if (event_json.jsonString(object.get("user_email"))) |value| return value;
    return null;
}

fn nestedInteger(object: std.json.ObjectMap, parent_key: []const u8, child_key: []const u8) ?i64 {
    const parent = switch (object.get(parent_key) orelse return null) {
        .object => |map| map,
        else => return null,
    };
    return jsonInteger(parent.get(child_key));
}

fn githubAvatarNumericId(url: []const u8) ?[]const u8 {
    const marker = "avatars.githubusercontent.com/u/";
    const marker_idx = std.mem.indexOf(u8, url, marker) orelse return null;
    const start = marker_idx + marker.len;
    var end = start;
    while (end < url.len and url[end] >= '0' and url[end] <= '9') : (end += 1) {}
    if (end == start) return null;
    return url[start..end];
}

fn importIssueObject(
    allocator: Allocator,
    writer: *EventWriter,
    issue: std.json.ObjectMap,
    projects: []const event_model.IssueProjectPlacement,
    map_file: ?[]const u8,
    stats: *ImportStats,
) !?ImportedObject {
    const number = jsonInteger(issue.get("number")) orelse return null;
    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();
    if (try lookupGithubObjectId(allocator, repo, map_file, "issue", number)) |existing| {
        try eprint("gt github import: issue #{d} already imported; syncing current fields\n", .{number});
        try syncExistingIssueObject(allocator, writer, repo, existing, issue);
        return .{ .id = existing, .is_new = false };
    }

    const title = try githubSizedString(allocator, event_json.jsonString(issue.get("title")), "(untitled)", git.max_payload_title_bytes);
    defer allocator.free(title);
    const body = try githubSizedString(allocator, event_json.jsonString(issue.get("body")), "", git.max_payload_text_bytes);
    defer allocator.free(body);
    const occurred_at = try githubTimestampOrNow(allocator, firstJsonValue(issue.get("created_at"), issue.get("createdAt")));
    defer allocator.free(occurred_at);

    const labels = try githubIssueLabels(allocator, issue);
    defer git.freeStringList(allocator, labels);
    const assignees = try githubNamedArray(allocator, issue.get("assignees"), "login");
    defer git.freeStringList(allocator, assignees);
    const source_identity = try githubSourceIdentityOwned(allocator, issue);
    defer source_identity.deinit(allocator);
    const milestone = try githubSizedString(allocator, githubMilestoneTitle(issue), "", git.max_payload_atom_bytes);
    defer allocator.free(milestone);
    const comment_count = githubOptionalUnsignedField(issue, &.{ "comments", "comment_count", "commentCount" });

    const issue_id = try util.newUuidV7(allocator);
    errdefer allocator.free(issue_id);
    try eprint("gt github import: importing issue #{d}\n", .{number});
    try ensureMilestoneCreatedForTitleStaged(allocator, writer, milestone, "", "", occurred_at, "gt github import");
    try writeImportedIssueOpened(allocator, writer, issue_id, @intCast(number), occurred_at, title, body, labels, assignees, source_identity, milestone, projects);
    stats.issues += 1;

    if (githubStateEquals(issue.get("state"), "closed")) {
        const closed_at = try githubTimestampOrNow(allocator, firstJsonValue3(issue.get("closed_at"), issue.get("closedAt"), firstJsonValue(issue.get("updated_at"), issue.get("updatedAt"))));
        defer allocator.free(closed_at);
        try writeImportedStringEvent(allocator, writer, .issue, issue_id, "issue.state_set", "state", "closed", closed_at);
    }

    return .{ .id = issue_id, .is_new = true, .comment_count = comment_count };
}

fn importPullObject(allocator: Allocator, writer: *EventWriter, pull: std.json.ObjectMap, map_file: ?[]const u8, stats: *ImportStats) !?ImportedObject {
    const number = jsonInteger(pull.get("number")) orelse return null;
    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();
    if (try lookupGithubObjectId(allocator, repo, map_file, "pull", number)) |existing| {
        try eprint("gt github import: pull #{d} already imported; syncing current fields\n", .{number});
        try syncExistingPullObject(allocator, writer, repo, existing, pull);
        return .{ .id = existing, .is_new = false };
    }

    const title = try githubSizedString(allocator, event_json.jsonString(pull.get("title")), "(untitled)", git.max_payload_title_bytes);
    defer allocator.free(title);
    const body = try githubSizedString(allocator, event_json.jsonString(pull.get("body")), "", git.max_payload_text_bytes);
    defer allocator.free(body);
    const base_ref = try githubSizedString(allocator, event_json.jsonString(pull.get("baseRefName")) orelse nestedString(pull, "base", "ref"), "main", git.max_payload_ref_bytes);
    defer allocator.free(base_ref);
    const head_ref = try githubSizedString(allocator, event_json.jsonString(pull.get("headRefName")) orelse nestedString(pull, "head", "ref"), "unknown", git.max_payload_ref_bytes);
    defer allocator.free(head_ref);
    const draft = jsonBool(firstJsonValue(pull.get("draft"), pull.get("isDraft"))) orelse false;
    const occurred_at = try githubTimestampOrNow(allocator, firstJsonValue(pull.get("created_at"), pull.get("createdAt")));
    defer allocator.free(occurred_at);
    const source_identity = try githubSourceIdentityOwned(allocator, pull);
    defer source_identity.deinit(allocator);
    const labels = try githubIssueLabels(allocator, pull);
    defer git.freeStringList(allocator, labels);
    const assignees = try githubNamedArray(allocator, pull.get("assignees"), "login");
    defer git.freeStringList(allocator, assignees);
    const reviewers = try githubPullReviewers(allocator, pull);
    defer git.freeStringList(allocator, reviewers);
    const comment_count = githubOptionalUnsignedField(pull, &.{ "comments", "comment_count", "commentCount" });

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
            .source_author = if (source_identity.author.len == 0) null else source_identity.author,
            .source_identity = if (source_identity.identity.len == 0) null else source_identity.identity,
            .source_email = if (source_identity.email.len == 0) null else source_identity.email,
            .source_avatar_url = if (source_identity.avatar_url.len == 0) null else source_identity.avatar_url,
            .labels = labels,
            .assignees = assignees,
            .reviewers = reviewers,
            .commit_count = githubOptionalUnsignedField(pull, &.{ "commits", "commit_count", "commitCount" }),
            .changed_files = githubOptionalUnsignedField(pull, &.{ "changed_files", "changedFiles", "files_changed", "file_count" }),
            .additions = githubOptionalUnsignedField(pull, &.{"additions"}),
            .deletions = githubOptionalUnsignedField(pull, &.{"deletions"}),
        },
    );
    stats.pulls += 1;

    if (githubStateEquals(pull.get("state"), "closed") or githubStateEquals(pull.get("state"), "merged")) {
        if (event_json.jsonString(firstJsonValue(pull.get("merged_at"), pull.get("mergedAt")))) |merged_at| {
            if (merged_at.len != 0) {
                try writeImportedPullMerged(allocator, writer, pull_id, merged_at, event_json.jsonString(pull.get("merge_commit_sha")) orelse nestedString(pull, "mergeCommit", "oid") orelse "", null);
                return .{ .id = pull_id, .is_new = true, .comment_count = comment_count };
            }
        }
        const closed_at = try githubTimestampOrNow(allocator, firstJsonValue3(pull.get("closed_at"), pull.get("closedAt"), firstJsonValue(pull.get("updated_at"), pull.get("updatedAt"))));
        defer allocator.free(closed_at);
        try writeImportedStringEvent(allocator, writer, .pull, pull_id, "pull.state_set", "state", "closed", closed_at);
    }

    return .{ .id = pull_id, .is_new = true, .comment_count = comment_count };
}

const LocalIssueSnapshot = struct {
    allocator: Allocator,
    title: []u8,
    body: []u8,
    state: []u8,
    milestone: []u8,
    labels: [][]u8,
    assignees: [][]u8,

    fn deinit(self: *LocalIssueSnapshot) void {
        self.allocator.free(self.title);
        self.allocator.free(self.body);
        self.allocator.free(self.state);
        self.allocator.free(self.milestone);
        git.freeStringList(self.allocator, self.labels);
        git.freeStringList(self.allocator, self.assignees);
    }
};

const LocalPullSnapshot = struct {
    allocator: Allocator,
    title: []u8,
    body: []u8,
    state: []u8,
    base_ref: []u8,
    head_ref: []u8,
    merge_oid: []u8,
    labels: [][]u8,
    assignees: [][]u8,
    reviewers: [][]u8,

    fn deinit(self: *LocalPullSnapshot) void {
        self.allocator.free(self.title);
        self.allocator.free(self.body);
        self.allocator.free(self.state);
        self.allocator.free(self.base_ref);
        self.allocator.free(self.head_ref);
        self.allocator.free(self.merge_oid);
        git.freeStringList(self.allocator, self.labels);
        git.freeStringList(self.allocator, self.assignees);
        git.freeStringList(self.allocator, self.reviewers);
    }
};

fn syncExistingIssueObject(
    allocator: Allocator,
    writer: *EventWriter,
    repo: repo_mod.Repo,
    issue_id: []const u8,
    issue: std.json.ObjectMap,
) !void {
    try index.ensureIndex(allocator, repo);
    var db = try index.SqliteDb.open(allocator, repo.index_path, index.sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var current = (try localIssueSnapshot(allocator, &db, issue_id)) orelse return;
    defer current.deinit();

    const title = try githubSizedString(allocator, event_json.jsonString(issue.get("title")), "(untitled)", git.max_payload_title_bytes);
    defer allocator.free(title);
    const body = try githubSizedString(allocator, event_json.jsonString(issue.get("body")), "", git.max_payload_text_bytes);
    defer allocator.free(body);
    const raw_state = event_json.jsonString(issue.get("state")) orelse "open";
    const state = if (std.ascii.eqlIgnoreCase(raw_state, "closed")) "closed" else "open";
    const milestone = try githubSizedString(allocator, githubMilestoneTitle(issue), "", git.max_payload_atom_bytes);
    defer allocator.free(milestone);
    const labels = try githubIssueLabels(allocator, issue);
    defer git.freeStringList(allocator, labels);
    const assignees = try githubNamedArray(allocator, issue.get("assignees"), "login");
    defer git.freeStringList(allocator, assignees);
    var label_diff = try provider_common.diffStringLists(allocator, labels, current.labels);
    defer label_diff.deinit();
    var assignee_diff = try provider_common.diffStringLists(allocator, assignees, current.assignees);
    defer assignee_diff.deinit();
    const occurred_at = try githubTimestampOrNow(allocator, firstJsonValue3(issue.get("updated_at"), issue.get("updatedAt"), firstJsonValue(issue.get("created_at"), issue.get("createdAt"))));
    defer allocator.free(occurred_at);

    try ensureMilestoneCreatedForTitleStaged(allocator, writer, milestone, "", "", occurred_at, "gt github import");

    const update = event_model.IssueUpdate{
        .title = if (!std.mem.eql(u8, title, current.title)) title else null,
        .body = if (!std.mem.eql(u8, body, current.body)) body else null,
        .state = if (!std.mem.eql(u8, state, current.state)) state else null,
        .milestone = if (!std.mem.eql(u8, milestone, current.milestone)) milestone else null,
        .labels_added = label_diff.added,
        .labels_removed = label_diff.removed,
        .assignees_added = assignee_diff.added,
        .assignees_removed = assignee_diff.removed,
    };
    if (!update.hasChanges()) return;

    try writeImportedIssueUpdated(allocator, writer, issue_id, occurred_at, update);
}

fn syncExistingPullObject(
    allocator: Allocator,
    writer: *EventWriter,
    repo: repo_mod.Repo,
    pull_id: []const u8,
    pull: std.json.ObjectMap,
) !void {
    try index.ensureIndex(allocator, repo);
    var db = try index.SqliteDb.open(allocator, repo.index_path, index.sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var current = (try localPullSnapshot(allocator, &db, pull_id)) orelse return;
    defer current.deinit();

    const title = try githubSizedString(allocator, event_json.jsonString(pull.get("title")), "(untitled)", git.max_payload_title_bytes);
    defer allocator.free(title);
    const body = try githubSizedString(allocator, event_json.jsonString(pull.get("body")), "", git.max_payload_text_bytes);
    defer allocator.free(body);
    const base_ref = try githubSizedString(allocator, event_json.jsonString(pull.get("baseRefName")) orelse nestedString(pull, "base", "ref"), "main", git.max_payload_ref_bytes);
    defer allocator.free(base_ref);
    const head_ref = try githubSizedString(allocator, event_json.jsonString(pull.get("headRefName")) orelse nestedString(pull, "head", "ref"), "unknown", git.max_payload_ref_bytes);
    defer allocator.free(head_ref);
    const labels = try githubIssueLabels(allocator, pull);
    defer git.freeStringList(allocator, labels);
    const assignees = try githubNamedArray(allocator, pull.get("assignees"), "login");
    defer git.freeStringList(allocator, assignees);
    const reviewers = try githubPullReviewers(allocator, pull);
    defer git.freeStringList(allocator, reviewers);
    var label_diff = try provider_common.diffStringLists(allocator, labels, current.labels);
    defer label_diff.deinit();
    var assignee_diff = try provider_common.diffStringLists(allocator, assignees, current.assignees);
    defer assignee_diff.deinit();
    var reviewer_diff = try provider_common.diffStringLists(allocator, reviewers, current.reviewers);
    defer reviewer_diff.deinit();

    const raw_github_state = event_json.jsonString(pull.get("state")) orelse "open";
    const github_state: []const u8 = if (std.ascii.eqlIgnoreCase(raw_github_state, "merged"))
        "merged"
    else if (std.ascii.eqlIgnoreCase(raw_github_state, "closed"))
        "closed"
    else
        "open";
    const merged_at = event_json.jsonString(firstJsonValue(pull.get("merged_at"), pull.get("mergedAt"))) orelse "";
    const merge_oid = event_json.jsonString(pull.get("merge_commit_sha")) orelse nestedString(pull, "mergeCommit", "oid") orelse "";
    if ((std.mem.eql(u8, github_state, "closed") or std.mem.eql(u8, github_state, "merged")) and merged_at.len != 0 and
        (!std.mem.eql(u8, current.state, "merged") or (merge_oid.len != 0 and !std.mem.eql(u8, current.merge_oid, merge_oid))))
    {
        try writeImportedPullMerged(allocator, writer, pull_id, merged_at, merge_oid, null);
    }

    const desired_state: ?[]const u8 = if (std.mem.eql(u8, github_state, "closed") and merged_at.len == 0)
        "closed"
    else if (std.mem.eql(u8, github_state, "open"))
        "open"
    else
        null;

    const update = event_model.PullUpdate{
        .title = if (!std.mem.eql(u8, title, current.title)) title else null,
        .body = if (!std.mem.eql(u8, body, current.body)) body else null,
        .state = if (desired_state) |state| if (!std.mem.eql(u8, state, current.state)) state else null else null,
        .base_ref = if (!std.mem.eql(u8, base_ref, current.base_ref)) base_ref else null,
        .head_ref = if (!std.mem.eql(u8, head_ref, current.head_ref)) head_ref else null,
        .labels_added = label_diff.added,
        .labels_removed = label_diff.removed,
        .assignees_added = assignee_diff.added,
        .assignees_removed = assignee_diff.removed,
        .reviewers_added = reviewer_diff.added,
        .reviewers_removed = reviewer_diff.removed,
    };
    if (!update.hasChanges()) return;

    const occurred_at = try githubTimestampOrNow(allocator, firstJsonValue3(pull.get("updated_at"), pull.get("updatedAt"), firstJsonValue(pull.get("created_at"), pull.get("createdAt"))));
    defer allocator.free(occurred_at);
    try writeImportedPullUpdated(allocator, writer, pull_id, occurred_at, update);
}

fn localIssueSnapshot(allocator: Allocator, db: *index.SqliteDb, issue_id: []const u8) !?LocalIssueSnapshot {
    var stmt = try db.prepare(
        \\SELECT i.title, i.body, i.state, COALESCE(m.milestone, '')
        \\FROM issues i
        \\LEFT JOIN issue_metadata m ON m.issue_id = i.id
        \\WHERE i.id = ?
    );
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    if (!(try stmt.step())) return null;
    const title = try stmt.columnTextDup(allocator, 0);
    errdefer allocator.free(title);
    const body = try stmt.columnTextDup(allocator, 1);
    errdefer allocator.free(body);
    const state = try stmt.columnTextDup(allocator, 2);
    errdefer allocator.free(state);
    const milestone = try stmt.columnTextDup(allocator, 3);
    errdefer allocator.free(milestone);
    const labels = try provider_common.queryStringList(allocator, db, "SELECT DISTINCT label FROM issue_labels WHERE issue_id = ? ORDER BY label", issue_id);
    errdefer git.freeStringList(allocator, labels);
    const assignees = try provider_common.queryStringList(allocator, db, "SELECT DISTINCT assignee FROM issue_assignees WHERE issue_id = ? ORDER BY assignee", issue_id);
    errdefer git.freeStringList(allocator, assignees);
    return .{
        .allocator = allocator,
        .title = title,
        .body = body,
        .state = state,
        .milestone = milestone,
        .labels = labels,
        .assignees = assignees,
    };
}

fn localPullSnapshot(allocator: Allocator, db: *index.SqliteDb, pull_id: []const u8) !?LocalPullSnapshot {
    var stmt = try db.prepare(
        \\SELECT title, body, state, base_ref, head_ref, merge_oid
        \\FROM pulls
        \\WHERE id = ?
    );
    defer stmt.deinit();
    try stmt.bindText(1, pull_id);
    if (!(try stmt.step())) return null;
    const title = try stmt.columnTextDup(allocator, 0);
    errdefer allocator.free(title);
    const body = try stmt.columnTextDup(allocator, 1);
    errdefer allocator.free(body);
    const state = try stmt.columnTextDup(allocator, 2);
    errdefer allocator.free(state);
    const base_ref = try stmt.columnTextDup(allocator, 3);
    errdefer allocator.free(base_ref);
    const head_ref = try stmt.columnTextDup(allocator, 4);
    errdefer allocator.free(head_ref);
    const merge_oid = try stmt.columnTextDup(allocator, 5);
    errdefer allocator.free(merge_oid);
    const labels = try provider_common.queryStringList(allocator, db, "SELECT DISTINCT label FROM pull_labels WHERE pull_id = ? ORDER BY label", pull_id);
    errdefer git.freeStringList(allocator, labels);
    const assignees = try provider_common.queryStringList(allocator, db, "SELECT DISTINCT assignee FROM pull_assignees WHERE pull_id = ? ORDER BY assignee", pull_id);
    errdefer git.freeStringList(allocator, assignees);
    const reviewers = try provider_common.queryStringList(allocator, db, "SELECT DISTINCT reviewer FROM pull_reviewers WHERE pull_id = ? ORDER BY reviewer", pull_id);
    errdefer git.freeStringList(allocator, reviewers);
    return .{
        .allocator = allocator,
        .title = title,
        .body = body,
        .state = state,
        .base_ref = base_ref,
        .head_ref = head_ref,
        .merge_oid = merge_oid,
        .labels = labels,
        .assignees = assignees,
        .reviewers = reviewers,
    };
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
    map_file: ?[]const u8,
    stats: *ImportStats,
) !void {
    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();
    try index.ensureIndex(allocator, repo);
    var db = try index.SqliteDb.open(allocator, repo.index_path, index.sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    var comment_refs = std.AutoHashMap(i64, ImportedCommentRef).init(allocator);
    defer freeImportedCommentRefs(allocator, &comment_refs);

    try importCommentsArrayWithContext(allocator, &db, &comment_refs, writer, parent_kind, parent_id, comments, map_file, stats);
}

fn importCommentsArrayWithContext(
    allocator: Allocator,
    db: *index.SqliteDb,
    comment_refs: *std.AutoHashMap(i64, ImportedCommentRef),
    writer: *EventWriter,
    parent_kind: []const u8,
    parent_id: []const u8,
    comments: std.json.Array,
    map_file: ?[]const u8,
    stats: *ImportStats,
) !void {
    var imported: usize = 0;
    for (comments.items) |item| {
        if (item != .object) continue;
        if (try mappedWebhookObjectId(allocator, map_file, "comment", item.object)) |existing| {
            allocator.free(existing);
            continue;
        }
        const body = try githubSizedString(allocator, event_json.jsonString(item.object.get("body")), "", git.max_payload_text_bytes);
        defer allocator.free(body);
        if (std.mem.trim(u8, body, " \t\r\n").len == 0) continue;
        const occurred_at = try githubTimestampOrNow(allocator, firstJsonValue(item.object.get("created_at"), item.object.get("createdAt")));
        defer allocator.free(occurred_at);
        if (try importedCommentExists(db, parent_kind, parent_id, occurred_at, body)) continue;
        const source_identity = try githubSourceIdentityOwned(allocator, item.object);
        defer source_identity.deinit(allocator);
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
            source_identity,
            reply.parent_id orelse "",
            reply.parent_hash orelse "",
        );
        var written_moved = false;
        errdefer if (!written_moved) written.deinit(allocator);
        imported += 1;
        if (jsonInteger(firstJsonValue(item.object.get("databaseId"), item.object.get("id")))) |github_id| {
            if (map_file) |path| try exporter.recordMappedObjectId(allocator, path, "comment", written.id, github_id);
            const entry = try comment_refs.getOrPut(github_id);
            if (entry.found_existing) {
                entry.value_ptr.deinit(allocator);
            }
            entry.value_ptr.* = written;
            written_moved = true;
        } else {
            written.deinit(allocator);
            written_moved = true;
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
    if (event_json.jsonString(comment.get("parent_hash"))) |hash| {
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

const LocalCommentState = struct {
    body: []u8,
    redacted: bool,

    fn deinit(self: LocalCommentState, allocator: Allocator) void {
        allocator.free(self.body);
    }
};

fn localCommentState(allocator: Allocator, db: *index.SqliteDb, comment_id: []const u8) !?LocalCommentState {
    var stmt = try db.prepare("SELECT body, redacted FROM comments WHERE id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, comment_id);
    if (!try stmt.step()) return null;
    return .{
        .body = try stmt.columnTextDup(allocator, 0),
        .redacted = stmt.columnInt64(1) != 0,
    };
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
    source_identity: GithubSourceIdentity,
    milestone: []const u8,
    projects: []const event_model.IssueProjectPlacement,
) !void {
    const subject_prefix = try provider_common.openedSubjectPrefix(allocator, .issue, issue_id, "GitHub", "#", number);
    defer allocator.free(subject_prefix);
    const subject = try githubSubject(allocator, subject_prefix, title);
    defer allocator.free(subject);
    try provider_common.writeImportedIssueOpened(allocator, writer, .{
        .issue_id = issue_id,
        .occurred_at = occurred_at,
        .title = title,
        .body_text = body_text,
        .labels = labels,
        .assignees = assignees,
        .legacy = .{ .github_issue_number = number },
        .metadata = .{
            .source_author = if (source_identity.author.len == 0) null else source_identity.author,
            .source_identity = if (source_identity.identity.len == 0) null else source_identity.identity,
            .source_email = if (source_identity.email.len == 0) null else source_identity.email,
            .source_avatar_url = if (source_identity.avatar_url.len == 0) null else source_identity.avatar_url,
            .milestone = if (milestone.len == 0) null else milestone,
            .projects = projects,
        },
        .command_context = "gt github import",
        .subject = subject,
    });
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
    metadata: event_model.PullOpenedMetadata,
) !void {
    const subject_prefix = try provider_common.openedSubjectPrefix(allocator, .pull, pull_id, "GitHub", "#", number);
    defer allocator.free(subject_prefix);
    const subject = try githubSubject(allocator, subject_prefix, title);
    defer allocator.free(subject);
    try provider_common.writeImportedPullOpened(allocator, writer, .{
        .pull_id = pull_id,
        .occurred_at = occurred_at,
        .title = title,
        .body_text = body_text,
        .base_ref = base_ref,
        .head_ref = head_ref,
        .draft = draft,
        .legacy = .{ .github_pull_number = number },
        .metadata = metadata,
        .command_context = "gt github import",
        .subject = subject,
    });
}

fn writeImportedStringEvent(
    allocator: Allocator,
    writer: *EventWriter,
    object_kind: provider_common.ObjectKind,
    object_id: []const u8,
    event_type: []const u8,
    payload_key: []const u8,
    payload_value: []const u8,
    occurred_at: []const u8,
) !void {
    try provider_common.writeImportedStringEvent(allocator, writer, .{
        .object_kind = object_kind,
        .object_id = object_id,
        .event_type = event_type,
        .payload_key = payload_key,
        .payload_value = payload_value,
        .occurred_at = occurred_at,
        .command_context = "gt github import",
    });
}

fn writeImportedIssueUpdated(
    allocator: Allocator,
    writer: *EventWriter,
    issue_id: []const u8,
    occurred_at: []const u8,
    update: event_model.IssueUpdate,
) !void {
    try provider_common.writeImportedIssueUpdated(allocator, writer, .{
        .issue_id = issue_id,
        .occurred_at = occurred_at,
        .update = update,
        .command_context = "gt github import",
        .subject_suffix = " GitHub sync",
    });
}

fn writeImportedPullUpdated(
    allocator: Allocator,
    writer: *EventWriter,
    pull_id: []const u8,
    occurred_at: []const u8,
    update: event_model.PullUpdate,
) !void {
    try provider_common.writeImportedPullUpdated(allocator, writer, .{
        .pull_id = pull_id,
        .occurred_at = occurred_at,
        .update = update,
        .command_context = "gt github import",
        .subject_suffix = " GitHub sync",
    });
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
    const body = try event_builders.buildIssueProjectEventJson(allocator, writer.cfg, writer.nextSeq(), issue_id, event_uuid, idem, occurred_at, writer.stagedEventParents(), "issue.project_added", project, column, null, null);
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
    try provider_common.writeImportedPullMerged(allocator, writer, .{
        .pull_id = pull_id,
        .occurred_at = occurred_at,
        .merge_oid = merge_oid,
        .target_oid = target_oid,
        .command_context = "gt github import",
    });
}

fn writeImportedCommentAdded(
    allocator: Allocator,
    writer: *EventWriter,
    parent_kind: []const u8,
    parent_id: []const u8,
    occurred_at: []const u8,
    body_text: []const u8,
    source_identity: GithubSourceIdentity,
    reply_parent_id: []const u8,
    reply_parent_hash: []const u8,
) !ImportedCommentRef {
    return try provider_common.writeImportedCommentAdded(allocator, writer, .{
        .parent_kind = parent_kind,
        .parent_id = parent_id,
        .occurred_at = occurred_at,
        .body_text = body_text,
        .metadata = .{
            .source_author = if (source_identity.author.len == 0) null else source_identity.author,
            .source_identity = if (source_identity.identity.len == 0) null else source_identity.identity,
            .source_email = if (source_identity.email.len == 0) null else source_identity.email,
            .source_avatar_url = if (source_identity.avatar_url.len == 0) null else source_identity.avatar_url,
            .reply_parent_id = if (reply_parent_id.len == 0) null else reply_parent_id,
            .reply_parent_hash = if (reply_parent_hash.len == 0) null else reply_parent_hash,
        },
        .reply_parent_hash = reply_parent_hash,
        .command_context = "gt github import",
    });
}

fn writeImportedCommentBodySet(
    allocator: Allocator,
    writer: *EventWriter,
    comment_id: []const u8,
    occurred_at: []const u8,
    body_text: []const u8,
) !void {
    try provider_common.writeImportedCommentBodySet(allocator, writer, .{
        .comment_id = comment_id,
        .occurred_at = occurred_at,
        .body_text = body_text,
        .command_context = "gt github import",
        .subject_suffix = " GitHub sync",
    });
}

fn writeImportedCommentRedacted(
    allocator: Allocator,
    writer: *EventWriter,
    comment_id: []const u8,
    occurred_at: []const u8,
    reason: []const u8,
) !void {
    try provider_common.writeImportedCommentRedacted(allocator, writer, .{
        .comment_id = comment_id,
        .occurred_at = occurred_at,
        .reason = reason,
        .command_context = "gt github import",
        .subject_suffix = " GitHub sync",
    });
}
