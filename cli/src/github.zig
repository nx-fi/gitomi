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
const default_api_url = "https://api.github.com";
const max_github_json = 32 * 1024 * 1024;

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
    dry_run: bool = false,

    fn request(self: GitHubClient, method: []const u8, path: []const u8, body: ?[]const u8) ![]u8 {
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
    bot_principal: []const u8 = import_bot_principal,
    bot_device: []const u8 = import_bot_device,
    max_pages: usize = 10,
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
        try eprint("gt github import: --repo or --from-file is required\n", .{});
        return CliError.MissingArgument;
    }

    try ensureImportBot(allocator, options.bot_principal, options.bot_device);

    var token_owned: ?[]u8 = null;
    defer if (token_owned) |value| allocator.free(value);
    const token = options.token_arg orelse blk: {
        token_owned = githubTokenFromEnv(allocator) catch null;
        break :blk token_owned;
    };

    var stats = ImportStats{};
    if (options.from_file) |path| {
        try importFromFile(allocator, path, options, &stats);
    } else {
        const client = GitHubClient{
            .allocator = allocator,
            .api_url = options.api_url,
            .repo = options.repo.?,
            .token = token,
        };
        try importFromApi(allocator, client, options, &stats);
    }

    try out("github import: {d} issue{s}, {d} pull{s}, {d} comment{s}\n", .{
        stats.issues,
        if (stats.issues == 1) "" else "s",
        stats.pulls,
        if (stats.pulls == 1) "" else "s",
        stats.comments,
        if (stats.comments == 1) "" else "s",
    });
}

const ImportStats = struct {
    issues: usize = 0,
    pulls: usize = 0,
    comments: usize = 0,
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

fn ensureImportBot(allocator: Allocator, principal: []const u8, device: []const u8) !void {
    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();

    const checked_principal = try util.checkedRefSegment(allocator, principal, "principal");
    defer allocator.free(checked_principal);
    const checked_device = try util.checkedRefSegment(allocator, device, "device");
    defer allocator.free(checked_device);

    if (!(try index.isIdentityDeviceActive(allocator, repo, checked_principal, checked_device))) {
        try writeImportBotIdentity(allocator, checked_principal, checked_device);
        try index.ensureIndex(allocator, repo);
    }

    const role = try index.roleForPrincipal(allocator, repo, checked_principal);
    defer if (role) |value| allocator.free(value);
    if (role == null or !roleAtLeastMaintainer(role.?)) {
        try writeImportBotRole(allocator, checked_principal, checked_device);
        try index.ensureIndex(allocator, repo);
    }
}

fn roleAtLeastMaintainer(role: []const u8) bool {
    return std.mem.eql(u8, role, "maintainer") or std.mem.eql(u8, role, "owner");
}

fn writeImportBotIdentity(allocator: Allocator, principal: []const u8, device: []const u8) !void {
    var writer = try EventWriter.initForInboxRef(allocator, "gt github import", principal, device);
    defer writer.deinit();

    const public_key = try repo_mod.signingPublicKey(allocator);
    defer allocator.free(public_key);
    if (std.mem.trim(u8, public_key, " \t\r\n").len == 0) {
        try eprint("gt github import: signing public key is required to authorize import-bot\n", .{});
        return CliError.MissingArgument;
    }
    const fingerprint = try repo_mod.signingKeyFingerprint(allocator, public_key);
    defer allocator.free(fingerprint);

    const event_uuid = try util.newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try util.newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try util.rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    const body = try event_mod.buildIdentityDeviceAddedJson(allocator, writer.cfg, writer.nextSeq(), principal, device, public_key, fingerprint, "ssh", event_uuid, idem, occurred_at, writer.eventParents());
    defer allocator.free(body);
    const subject = try std.fmt.allocPrint(allocator, "identity.device_added {s}/{s}", .{ principal, device });
    defer allocator.free(subject);
    const commit = try writer.write("gt github import", subject, body);
    allocator.free(commit);
}

fn writeImportBotRole(allocator: Allocator, principal: []const u8, device: []const u8) !void {
    var writer = try EventWriter.initForInboxRef(allocator, "gt github import", principal, device);
    defer writer.deinit();

    const event_uuid = try util.newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try util.newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try util.rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    const body = try event_mod.buildAclRoleJson(allocator, writer.cfg, writer.nextSeq(), principal, "maintainer", event_uuid, idem, occurred_at, writer.eventParents(), true);
    defer allocator.free(body);
    const subject = try std.fmt.allocPrint(allocator, "acl.role_granted {s} maintainer", .{principal});
    defer allocator.free(subject);
    const commit = try writer.write("gt github import", subject, body);
    allocator.free(commit);
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
        for (issues.items) |item| {
            if (item != .object) continue;
            if (item.object.get("pull_request") != null) continue;
            const issue_id = try importIssueObject(allocator, item.object, options, stats);
            defer if (issue_id) |id| allocator.free(id);
            if (issue_id) |id| try importFixtureComments(allocator, root, "issue", item.object, id, options, stats);
        }
    }
    if (jsonArray(root.get("pulls"))) |pulls| {
        for (pulls.items) |item| {
            if (item != .object) continue;
            const pull_id = try importPullObject(allocator, item.object, options, stats);
            defer if (pull_id) |id| allocator.free(id);
            if (pull_id) |id| try importFixtureComments(allocator, root, "pull", item.object, id, options, stats);
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
    try importCommentsArray(allocator, parent_kind, parent_id, comments, options, stats);
}

fn importFromApi(allocator: Allocator, client: GitHubClient, options: ImportOptions, stats: *ImportStats) !void {
    var page: usize = 1;
    while (page <= options.max_pages) : (page += 1) {
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
        if (issues.items.len == 0) break;
        for (issues.items) |item| {
            if (item != .object) continue;
            if (item.object.get("pull_request") != null) continue;
            const issue_id = try importIssueObject(allocator, item.object, options, stats);
            defer if (issue_id) |id| allocator.free(id);
            if (issue_id) |id| try importApiComments(allocator, client, "issue", jsonInteger(item.object.get("number")) orelse continue, id, options, stats);
        }
        if (issues.items.len < 100) break;
    }

    page = 1;
    while (page <= options.max_pages) : (page += 1) {
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
        if (pulls.items.len == 0) break;
        for (pulls.items) |item| {
            if (item != .object) continue;
            const pull_id = try importPullObject(allocator, item.object, options, stats);
            defer if (pull_id) |id| allocator.free(id);
            if (pull_id) |id| try importApiComments(allocator, client, "pull", jsonInteger(item.object.get("number")) orelse continue, id, options, stats);
        }
        if (pulls.items.len < 100) break;
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
    try importCommentsArray(allocator, parent_kind, parent_id, comments, options, stats);
}

fn importIssueObject(allocator: Allocator, issue: std.json.ObjectMap, options: ImportOptions, stats: *ImportStats) !?[]u8 {
    const number = jsonInteger(issue.get("number")) orelse return null;
    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();
    if (try index.lookupLegacyGithubObjectId(allocator, repo, "issue", number)) |existing| return existing;

    const title = event_mod.jsonString(issue.get("title")) orelse "(untitled)";
    const body = event_mod.jsonString(issue.get("body")) orelse "";
    const occurred_at = try githubTimestampOrNow(allocator, issue.get("created_at"));
    defer allocator.free(occurred_at);

    const labels = try githubNamedArray(allocator, issue.get("labels"), "name");
    defer freeStringList(allocator, labels);
    const assignees = try githubNamedArray(allocator, issue.get("assignees"), "login");
    defer freeStringList(allocator, assignees);

    const issue_id = try util.newUuidV7(allocator);
    errdefer allocator.free(issue_id);
    try writeImportedIssueOpened(allocator, options, issue_id, @intCast(number), occurred_at, title, body, labels, assignees);
    stats.issues += 1;

    if (event_mod.jsonString(issue.get("state"))) |state| {
        if (std.mem.eql(u8, state, "closed")) {
            const closed_at = try githubTimestampOrNow(allocator, firstJsonValue(issue.get("closed_at"), issue.get("updated_at")));
            defer allocator.free(closed_at);
            try writeImportedStringEvent(allocator, options, "issue", issue_id, "issue.state_set", "state", "closed", closed_at);
        }
    }

    return issue_id;
}

fn importPullObject(allocator: Allocator, pull: std.json.ObjectMap, options: ImportOptions, stats: *ImportStats) !?[]u8 {
    const number = jsonInteger(pull.get("number")) orelse return null;
    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();
    if (try index.lookupLegacyGithubObjectId(allocator, repo, "pull", number)) |existing| return existing;

    const title = event_mod.jsonString(pull.get("title")) orelse "(untitled)";
    const body = event_mod.jsonString(pull.get("body")) orelse "";
    const base_ref = nestedString(pull, "base", "ref") orelse "main";
    const head_ref = nestedString(pull, "head", "ref") orelse "unknown";
    const draft = jsonBool(pull.get("draft")) orelse false;
    const occurred_at = try githubTimestampOrNow(allocator, pull.get("created_at"));
    defer allocator.free(occurred_at);

    const pull_id = try util.newUuidV7(allocator);
    errdefer allocator.free(pull_id);
    try writeImportedPullOpened(allocator, options, pull_id, @intCast(number), occurred_at, title, body, base_ref, head_ref, draft);
    stats.pulls += 1;

    if (event_mod.jsonString(pull.get("state"))) |state| {
        if (std.mem.eql(u8, state, "closed")) {
            if (event_mod.jsonString(pull.get("merged_at"))) |merged_at| {
                if (merged_at.len != 0) {
                    try writeImportedPullMerged(allocator, options, pull_id, merged_at, event_mod.jsonString(pull.get("merge_commit_sha")) orelse "", null);
                    return pull_id;
                }
            }
            const closed_at = try githubTimestampOrNow(allocator, firstJsonValue(pull.get("closed_at"), pull.get("updated_at")));
            defer allocator.free(closed_at);
            try writeImportedStringEvent(allocator, options, "pull", pull_id, "pull.state_set", "state", "closed", closed_at);
        }
    }

    return pull_id;
}

fn importCommentsArray(
    allocator: Allocator,
    parent_kind: []const u8,
    parent_id: []const u8,
    comments: std.json.Array,
    options: ImportOptions,
    stats: *ImportStats,
) !void {
    for (comments.items) |item| {
        if (item != .object) continue;
        const body = event_mod.jsonString(item.object.get("body")) orelse "";
        if (std.mem.trim(u8, body, " \t\r\n").len == 0) continue;
        const occurred_at = try githubTimestampOrNow(allocator, item.object.get("created_at"));
        defer allocator.free(occurred_at);
        try writeImportedCommentAdded(allocator, options, parent_kind, parent_id, occurred_at, body);
        stats.comments += 1;
    }
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
) !void {
    var writer = try EventWriter.initForActor(allocator, "gt github import", options.bot_principal, options.bot_device);
    defer writer.deinit();

    const event_uuid = try util.newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try util.newUuidV7(allocator);
    defer allocator.free(idem);
    const body = try event_mod.buildIssueOpenedJsonWithLegacy(allocator, writer.cfg, writer.nextSeq(), issue_id, event_uuid, idem, occurred_at, writer.eventParents(), title, body_text, labels, assignees, .{ .github_issue_number = number });
    defer allocator.free(body);
    const subject = try std.fmt.allocPrint(allocator, "issue.opened #{s} GitHub #{d} {s}", .{ issue_id[0..7], number, title });
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
) !void {
    var writer = try EventWriter.initForActor(allocator, "gt github import", options.bot_principal, options.bot_device);
    defer writer.deinit();

    const event_uuid = try util.newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try util.newUuidV7(allocator);
    defer allocator.free(idem);
    const body = try event_mod.buildPullOpenedJsonWithLegacy(allocator, writer.cfg, writer.nextSeq(), pull_id, event_uuid, idem, occurred_at, writer.eventParents(), title, body_text, base_ref, head_ref, draft, .{ .github_pull_number = number });
    defer allocator.free(body);
    const subject = try std.fmt.allocPrint(allocator, "pull.opened #{s} GitHub #{d} {s}", .{ pull_id[0..7], number, title });
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
    const subject = try std.fmt.allocPrint(allocator, "{s} #{s}", .{ event_type, object_id[0..@min(object_id.len, 7)] });
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
    const subject = try std.fmt.allocPrint(allocator, "pull.merged #{s}", .{pull_id[0..@min(pull_id.len, 7)]});
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
) !void {
    var writer = try EventWriter.initForActor(allocator, "gt github import", options.bot_principal, options.bot_device);
    defer writer.deinit();

    const comment_id = try util.newUuidV7(allocator);
    defer allocator.free(comment_id);
    const event_uuid = try util.newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try util.newUuidV7(allocator);
    defer allocator.free(idem);
    const body = try event_mod.buildCommentAddedJson(allocator, writer.cfg, writer.nextSeq(), comment_id, event_uuid, idem, occurred_at, writer.eventParents(), parent_kind, parent_id, body_text);
    defer allocator.free(body);
    const subject = try std.fmt.allocPrint(allocator, "comment.added #{s}", .{comment_id[0..7]});
    defer allocator.free(subject);
    const commit = try writer.write("gt github import", subject, body);
    allocator.free(commit);
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

fn githubNamedArray(allocator: Allocator, value: ?std.json.Value, key: []const u8) ![][]u8 {
    const array = jsonArray(value) orelse return allocator.alloc([]u8, 0);
    var list: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(allocator, list.items);
    for (array.items) |item| {
        if (item == .string) {
            try list.append(allocator, try allocator.dupe(u8, item.string));
        } else if (item == .object) {
            if (event_mod.jsonString(item.object.get(key))) |name| {
                if (name.len != 0) try list.append(allocator, try allocator.dupe(u8, name));
            }
        }
    }
    return list.toOwnedSlice(allocator);
}

fn freeStringList(allocator: Allocator, values: [][]u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
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
