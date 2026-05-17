const std = @import("std");
const event_mod = @import("../../event.zig");
const event_writer_mod = @import("../../event_writer.zig");
const errors = @import("../../errors.zig");
const git = @import("../../git.zig");
const index = @import("../../index.zig");
const io = @import("../../io.zig");
const repo_mod = @import("../../repo.zig");
const util = @import("../../util.zig");
const common = @import("common.zig");
const exporter = @import("exporter.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const EventWriter = event_writer_mod.EventWriter;
const out = io.out;
const eprint = io.eprint;
const GitLabClient = common.GitLabClient;
const ProjectRef = common.ProjectRef;
const default_api_url = common.default_api_url;
const max_gitlab_json = common.max_gitlab_json;
const parseProjectRef = common.parseProjectRef;
const jsonArray = common.jsonArray;
const jsonBool = common.jsonBool;
const jsonInteger = common.jsonInteger;
const firstJsonValue = common.firstJsonValue;
const timestampOrNow = common.timestampOrNow;
const sizedString = common.sizedString;
const subject = common.subject;

const import_bot_principal = "import-bot";
const import_bot_device = "gitlab";
const gitlab_import_capability = "gitlab.import";
const gitlab_import_scope = "gitlab:*";

pub const ImportOptions = struct {
    project: ?ProjectRef = null,
    api_url: []const u8 = default_api_url,
    token_arg: ?[]const u8 = null,
    from_file: ?[]const u8 = null,
    include_comments: bool = true,
    bot_principal: []const u8 = import_bot_principal,
    bot_device: []const u8 = import_bot_device,
    max_pages: usize = 10,
    map_file: ?[]const u8 = null,
};

pub const ImportStats = struct {
    issues: usize = 0,
    pulls: usize = 0,
    comments: usize = 0,
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

pub fn cmdImport(allocator: Allocator, args: []const []const u8) !void {
    var options = ImportOptions{};
    var token_source_owned: ?[]u8 = null;
    defer if (token_source_owned) |value| allocator.free(value);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--project") or std.mem.eql(u8, arg, "--repo")) {
            options.project = try parseProjectRef(try util.requireValue(args, &i, arg));
        } else if (std.mem.eql(u8, arg, "--api-url")) {
            options.api_url = try util.requireValue(args, &i, "--api-url");
        } else if (std.mem.eql(u8, arg, "--token")) {
            _ = try util.requireValue(args, &i, "--token");
            try eprint("gt gitlab import: --token exposes credentials in process lists; use --token-env, --token-file, GITLAB_TOKEN, or GL_TOKEN\n", .{});
            return CliError.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "--token-env")) {
            const env_name = try util.requireValue(args, &i, "--token-env");
            if (token_source_owned) |value| allocator.free(value);
            token_source_owned = null;
            token_source_owned = try common.secretFromEnv(allocator, "gt gitlab import", env_name);
            options.token_arg = token_source_owned;
        } else if (std.mem.eql(u8, arg, "--token-file")) {
            const path = try util.requireValue(args, &i, "--token-file");
            if (token_source_owned) |value| allocator.free(value);
            token_source_owned = null;
            token_source_owned = try common.secretFromFile(allocator, "gt gitlab import", path);
            options.token_arg = token_source_owned;
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
                try eprint("gt gitlab import: --max-pages must be a positive integer\n", .{});
                return CliError.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--map-file")) {
            options.map_file = try util.requireValue(args, &i, "--map-file");
        } else {
            try eprint("gt gitlab import: unknown option '{s}'\n", .{arg});
            return CliError.UserError;
        }
    }

    if (options.project == null and options.from_file == null) {
        try eprint("gt gitlab import: --project or --from-file is required\n", .{});
        return CliError.MissingArgument;
    }

    try eprint("gt gitlab import: preparing delegated import actor {s}/{s}\n", .{ options.bot_principal, options.bot_device });
    try ensureImportDelegation(allocator, options.bot_principal, options.bot_device);

    var token_owned: ?[]u8 = null;
    defer if (token_owned) |value| allocator.free(value);
    const token = options.token_arg orelse blk: {
        token_owned = common.tokenFromEnv(allocator) catch null;
        break :blk token_owned;
    };
    if (options.from_file == null and token == null) {
        try eprint("gt gitlab import: --token-env, --token-file, GITLAB_TOKEN, or GL_TOKEN is required for API imports\n", .{});
        return CliError.MissingArgument;
    }

    var stats = ImportStats{};
    if (options.from_file) |path| {
        try eprint("gt gitlab import: reading fixture {s}\n", .{path});
        try importFromFile(allocator, path, options, &stats);
    } else {
        const client = GitLabClient{
            .allocator = allocator,
            .api_url = options.api_url,
            .project = options.project.?,
            .token = token,
        };
        try eprint("gt gitlab import: using GitLab API project {s}\n", .{client.project.path});
        try importFromApi(allocator, client, options, &stats);
    }

    try out("gitlab import: {d} issue{s}, {d} merge request{s}, {d} comment{s}\n", .{
        stats.issues,
        if (stats.issues == 1) "" else "s",
        stats.pulls,
        if (stats.pulls == 1) "" else "s",
        stats.comments,
        if (stats.comments == 1) "" else "s",
    });
}

fn ensureImportDelegation(allocator: Allocator, principal: []const u8, device: []const u8) !void {
    const checked_principal = try util.checkedRefSegment(allocator, principal, "principal");
    defer allocator.free(checked_principal);
    const checked_device = try util.checkedRefSegment(allocator, device, "device");
    defer allocator.free(checked_device);

    var writer = try EventWriter.init(allocator, "gt gitlab import");
    defer writer.deinit();

    const role = try index.roleForPrincipal(allocator, writer.repo, writer.cfg.principal);
    defer if (role) |value| allocator.free(value);
    if (role == null or !roleAtLeastMaintainer(role.?)) {
        try eprint("gt gitlab import: {s} must be maintainer or owner to delegate GitLab import authority\n", .{writer.cfg.principal});
        return CliError.Unauthorized;
    }

    if (!(try index.isIdentityDeviceActive(allocator, writer.repo, writer.cfg.principal, writer.cfg.device))) {
        try eprint("gt gitlab import: configured actor {s}/{s} is not an active device\n", .{ writer.cfg.principal, writer.cfg.device });
        return CliError.Unauthorized;
    }

    var signing_key = try repo_mod.configuredSigningKey(allocator);
    defer signing_key.deinit();
    if (std.mem.trim(u8, signing_key.public_key, " \t\r\n").len == 0) {
        try eprint("gt gitlab import: signing public key is required to delegate import-bot; configure Git signing with user.signingkey\n", .{});
        return CliError.MissingArgument;
    }

    if (try index.hasActiveDelegation(allocator, writer.repo, checked_principal, checked_device, gitlab_import_capability, gitlab_import_scope, signing_key.fingerprint)) {
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
        gitlab_import_capability,
        gitlab_import_scope,
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
    const subject_line = try std.fmt.allocPrint(allocator, "acl.delegation_granted {s}/{s} {s}", .{ checked_principal, checked_device, gitlab_import_capability });
    defer allocator.free(subject_line);
    const commit = try writer.write("gt gitlab import", subject_line, body);
    allocator.free(commit);
    try index.ensureIndex(allocator, writer.repo);
}

fn roleAtLeastMaintainer(role: []const u8) bool {
    return std.mem.eql(u8, role, "maintainer") or std.mem.eql(u8, role, "owner");
}

fn importFromFile(allocator: Allocator, path: []const u8, options: ImportOptions, stats: *ImportStats) !void {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, max_gitlab_json);
    defer allocator.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch {
        try eprint("gt gitlab import: --from-file must contain JSON\n", .{});
        return CliError.InvalidArgument;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => {
            try eprint("gt gitlab import: --from-file must contain a JSON object\n", .{});
            return CliError.InvalidArgument;
        },
    };

    if (jsonArray(root.get("issues"))) |issues| {
        try eprint("gt gitlab import: importing {d} fixture issue record{s}\n", .{ issues.items.len, if (issues.items.len == 1) "" else "s" });
        for (issues.items) |item| {
            if (item != .object) continue;
            var writer = try EventWriter.initForActor(allocator, "gt gitlab import", options.bot_principal, options.bot_device);
            defer writer.deinit();
            const issue_result = try importIssueObject(allocator, &writer, item.object, options.map_file, stats);
            defer if (issue_result) |result| allocator.free(result.id);
            if (issue_result) |result| {
                if (result.is_new) try importFixtureComments(allocator, &writer, root, "issue", item.object, result.id, options, stats);
                try writer.commitStaged();
            }
        }
    }
    const pulls_value = root.get("merge_requests") orelse root.get("pulls");
    if (jsonArray(pulls_value)) |pulls| {
        try eprint("gt gitlab import: importing {d} fixture merge request record{s}\n", .{ pulls.items.len, if (pulls.items.len == 1) "" else "s" });
        for (pulls.items) |item| {
            if (item != .object) continue;
            var writer = try EventWriter.initForActor(allocator, "gt gitlab import", options.bot_principal, options.bot_device);
            defer writer.deinit();
            const pull_result = try importPullObject(allocator, &writer, item.object, options.map_file, stats);
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
    const number = gitlabIid(object) orelse return;
    const comments_root = switch (root.get("notes") orelse root.get("comments") orelse return) {
        .object => |map| map,
        else => return,
    };
    const key = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ parent_kind, number });
    defer allocator.free(key);
    const comments = jsonArray(comments_root.get(key)) orelse return;
    try importCommentsArray(allocator, writer, parent_kind, parent_id, comments, options.map_file, stats);
}

pub fn importFromApi(allocator: Allocator, client: GitLabClient, options: ImportOptions, stats: *ImportStats) !void {
    var page: usize = 1;
    while (page <= options.max_pages) : (page += 1) {
        try eprint("gt gitlab import: fetching issues page {d}\n", .{page});
        const suffix = try std.fmt.allocPrint(allocator, "/issues?state=all&scope=all&per_page=100&page={d}", .{page});
        defer allocator.free(suffix);
        const path = try client.projectPath(allocator, suffix);
        defer allocator.free(path);
        const raw = try client.request("GET", path, null);
        defer allocator.free(raw);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
        defer parsed.deinit();
        const issues = switch (parsed.value) {
            .array => |array| array,
            else => break,
        };
        try eprint("gt gitlab import: issues page {d}: {d} record{s}\n", .{ page, issues.items.len, if (issues.items.len == 1) "" else "s" });
        if (issues.items.len == 0) break;
        for (issues.items) |item| {
            if (item != .object) continue;
            if (event_mod.jsonString(item.object.get("issue_type"))) |issue_type| {
                if (!std.mem.eql(u8, issue_type, "issue")) continue;
            }
            var writer = try EventWriter.initForActor(allocator, "gt gitlab import", options.bot_principal, options.bot_device);
            defer writer.deinit();
            const issue_result = try importIssueObject(allocator, &writer, item.object, options.map_file, stats);
            defer if (issue_result) |result| allocator.free(result.id);
            if (issue_result) |result| {
                if (result.is_new and shouldFetchApiComments(result.comment_count)) try importApiComments(allocator, &writer, client, "issue", gitlabIid(item.object).?, result.id, options, stats);
                try writer.commitStaged();
            }
        }
        if (issues.items.len < 100) break;
    }

    page = 1;
    while (page <= options.max_pages) : (page += 1) {
        try eprint("gt gitlab import: fetching merge requests page {d}\n", .{page});
        const suffix = try std.fmt.allocPrint(allocator, "/merge_requests?state=all&scope=all&per_page=100&page={d}", .{page});
        defer allocator.free(suffix);
        const path = try client.projectPath(allocator, suffix);
        defer allocator.free(path);
        const raw = try client.request("GET", path, null);
        defer allocator.free(raw);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
        defer parsed.deinit();
        const pulls = switch (parsed.value) {
            .array => |array| array,
            else => break,
        };
        try eprint("gt gitlab import: merge requests page {d}: {d} record{s}\n", .{ page, pulls.items.len, if (pulls.items.len == 1) "" else "s" });
        if (pulls.items.len == 0) break;
        for (pulls.items) |item| {
            if (item != .object) continue;
            var writer = try EventWriter.initForActor(allocator, "gt gitlab import", options.bot_principal, options.bot_device);
            defer writer.deinit();
            const pull_result = try importPullObject(allocator, &writer, item.object, options.map_file, stats);
            defer if (pull_result) |result| allocator.free(result.id);
            if (pull_result) |result| {
                if (result.is_new and shouldFetchApiComments(result.comment_count)) try importApiComments(allocator, &writer, client, "pull", gitlabIid(item.object).?, result.id, options, stats);
                try writer.commitStaged();
            }
        }
        if (pulls.items.len < 100) break;
    }
}

fn shouldFetchApiComments(count: ?u64) bool {
    return count == null or count.? != 0;
}

fn importApiComments(
    allocator: Allocator,
    writer: *EventWriter,
    client: GitLabClient,
    parent_kind: []const u8,
    iid: i64,
    parent_id: []const u8,
    options: ImportOptions,
    stats: *ImportStats,
) !void {
    if (!options.include_comments) return;
    var total: usize = 0;
    var page: usize = 1;
    while (page <= options.max_pages) : (page += 1) {
        const collection = if (std.mem.eql(u8, parent_kind, "issue"))
            try std.fmt.allocPrint(allocator, "/issues/{d}/notes?per_page=100&page={d}&sort=asc&order_by=created_at", .{ iid, page })
        else
            try std.fmt.allocPrint(allocator, "/merge_requests/{d}/notes?per_page=100&page={d}&sort=asc&order_by=created_at", .{ iid, page });
        defer allocator.free(collection);
        const path = try client.projectPath(allocator, collection);
        defer allocator.free(path);
        const raw = try client.request("GET", path, null);
        defer allocator.free(raw);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
        defer parsed.deinit();
        const notes = switch (parsed.value) {
            .array => |array| array,
            else => return,
        };
        if (notes.items.len == 0) break;
        total += notes.items.len;
        try importCommentsArray(allocator, writer, parent_kind, parent_id, notes, options.map_file, stats);
        if (notes.items.len < 100) break;
    }
    try eprint("gt gitlab import: {s} !{d}: {d} note{s}\n", .{ parent_kind, iid, total, if (total == 1) "" else "s" });
}

fn importIssueObject(allocator: Allocator, writer: *EventWriter, issue: std.json.ObjectMap, map_file: ?[]const u8, stats: *ImportStats) !?ImportedObject {
    const number = gitlabIid(issue) orelse return null;

    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();
    if (try lookupGitlabObjectId(allocator, repo, map_file, "issue", number)) |existing| {
        try eprint("gt gitlab import: issue #{d} already imported; syncing current fields\n", .{number});
        try syncExistingIssue(allocator, writer, existing, issue, stats);
        return .{ .id = existing, .is_new = false };
    }

    const issue_id = try util.newUuidV7(allocator);
    errdefer allocator.free(issue_id);
    const title = try sizedString(allocator, event_mod.jsonString(issue.get("title")), "(untitled)", git.max_payload_title_bytes);
    defer allocator.free(title);
    const body = try sizedString(allocator, event_mod.jsonString(issue.get("description")) orelse event_mod.jsonString(issue.get("body")), "", git.max_payload_text_bytes);
    defer allocator.free(body);
    const occurred_at = try timestampOrNow(allocator, issue.get("created_at"));
    defer allocator.free(occurred_at);
    const labels = try common.labels(allocator, issue);
    defer git.freeStringList(allocator, labels);
    const assignees = try common.userArray(allocator, issue.get("assignees"));
    defer git.freeStringList(allocator, assignees);
    const source_author = try sizedString(allocator, common.authorUsername(issue), "", git.max_payload_atom_bytes);
    defer allocator.free(source_author);
    const milestone = try sizedString(allocator, common.milestoneTitle(issue), "", git.max_payload_atom_bytes);
    defer allocator.free(milestone);
    const comment_count = common.optionalUnsignedField(issue, &.{ "user_notes_count", "comments", "comment_count" });

    try eprint("gt gitlab import: importing issue #{d}\n", .{number});
    try writeImportedIssueOpened(allocator, writer, issue_id, @intCast(number), occurred_at, title, body, labels, assignees, source_author, milestone);
    if (gitlabIssueState(issue)) |state| {
        if (std.mem.eql(u8, state, "closed")) {
            const closed_at = try timestampOrNow(allocator, firstJsonValue(issue.get("closed_at"), issue.get("updated_at")));
            defer allocator.free(closed_at);
            try writeImportedStringEvent(allocator, writer, "issue", issue_id, "issue.state_set", "state", "closed", closed_at);
        }
    }
    if (map_file) |path| try exporter.recordMappedObjectId(allocator, path, "issue", issue_id, number);
    stats.issues += 1;
    return .{ .id = issue_id, .is_new = true, .comment_count = comment_count };
}

fn importPullObject(allocator: Allocator, writer: *EventWriter, pull: std.json.ObjectMap, map_file: ?[]const u8, stats: *ImportStats) !?ImportedObject {
    const number = gitlabIid(pull) orelse return null;

    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();
    if (try lookupGitlabObjectId(allocator, repo, map_file, "pull", number)) |existing| {
        try eprint("gt gitlab import: merge request !{d} already imported; syncing current fields\n", .{number});
        try syncExistingPull(allocator, writer, existing, pull, stats);
        return .{ .id = existing, .is_new = false };
    }

    const pull_id = try util.newUuidV7(allocator);
    errdefer allocator.free(pull_id);
    const title = try sizedString(allocator, event_mod.jsonString(pull.get("title")), "(untitled)", git.max_payload_title_bytes);
    defer allocator.free(title);
    const body = try sizedString(allocator, event_mod.jsonString(pull.get("description")) orelse event_mod.jsonString(pull.get("body")), "", git.max_payload_text_bytes);
    defer allocator.free(body);
    const base_ref = try sizedString(allocator, event_mod.jsonString(pull.get("target_branch")) orelse common.nestedString(pull, "base", "ref"), "main", git.max_payload_ref_bytes);
    defer allocator.free(base_ref);
    const head_ref = try sizedString(allocator, event_mod.jsonString(pull.get("source_branch")) orelse common.nestedString(pull, "head", "ref"), "unknown", git.max_payload_ref_bytes);
    defer allocator.free(head_ref);
    const occurred_at = try timestampOrNow(allocator, pull.get("created_at"));
    defer allocator.free(occurred_at);
    const source_author = try sizedString(allocator, common.authorUsername(pull), "", git.max_payload_atom_bytes);
    defer allocator.free(source_author);
    const labels = try common.labels(allocator, pull);
    defer git.freeStringList(allocator, labels);
    const assignees = try common.userArray(allocator, pull.get("assignees"));
    defer git.freeStringList(allocator, assignees);
    const reviewers = try common.userArray(allocator, pull.get("reviewers"));
    defer git.freeStringList(allocator, reviewers);
    const comment_count = common.optionalUnsignedField(pull, &.{ "user_notes_count", "comments", "comment_count" });

    try eprint("gt gitlab import: importing merge request !{d}\n", .{number});
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
        false,
        .{
            .source_author = if (source_author.len == 0) null else source_author,
            .labels = constStringList(labels),
            .assignees = constStringList(assignees),
            .reviewers = constStringList(reviewers),
            .commit_count = common.optionalUnsignedField(pull, &.{ "commits_count", "commit_count" }),
            .changed_files = common.optionalUnsignedField(pull, &.{ "changes_count", "changed_files", "file_count" }),
        },
    );
    if (gitlabMergeState(pull)) |state| {
        if (std.mem.eql(u8, state, "merged")) {
            const merged_at = try timestampOrNow(allocator, firstJsonValue(pull.get("merged_at"), pull.get("updated_at")));
            defer allocator.free(merged_at);
            try writeImportedPullMerged(allocator, writer, pull_id, merged_at, event_mod.jsonString(pull.get("merge_commit_sha")) orelse "", null);
        } else if (std.mem.eql(u8, state, "closed")) {
            const closed_at = try timestampOrNow(allocator, firstJsonValue(pull.get("closed_at"), pull.get("updated_at")));
            defer allocator.free(closed_at);
            try writeImportedStringEvent(allocator, writer, "pull", pull_id, "pull.state_set", "state", "closed", closed_at);
        }
    }
    if (map_file) |path| try exporter.recordMappedObjectId(allocator, path, "pull", pull_id, number);
    stats.pulls += 1;
    return .{ .id = pull_id, .is_new = true, .comment_count = comment_count };
}

fn lookupGitlabObjectId(allocator: Allocator, repo: repo_mod.Repo, map_file: ?[]const u8, object_kind: []const u8, number: i64) !?[]u8 {
    if (map_file) |path| {
        if (try exporter.lookupMappedObjectId(allocator, path, object_kind, number)) |id| return id;
    }
    return try index.lookupLegacyGitlabObjectId(allocator, repo, object_kind, number);
}

fn syncExistingIssue(allocator: Allocator, writer: *EventWriter, issue_id: []const u8, issue: std.json.ObjectMap, stats: *ImportStats) !void {
    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();
    try index.ensureIndex(allocator, repo);
    var db = try index.SqliteDb.open(allocator, repo.index_path, index.sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    const current = (try localIssueState(allocator, &db, issue_id)) orelse return;
    defer current.deinit(allocator);
    const desired = try desiredIssueState(allocator, issue);
    defer desired.deinit(allocator);
    var update = event_mod.IssueUpdate{
        .title = if (!std.mem.eql(u8, current.title, desired.title)) desired.title else null,
        .body = if (!std.mem.eql(u8, current.body, desired.body)) desired.body else null,
        .state = if (!std.mem.eql(u8, current.state, desired.state)) desired.state else null,
        .milestone = if (!std.mem.eql(u8, current.milestone, desired.milestone)) desired.milestone else null,
        .labels_added = try diffAdded(allocator, desired.labels, current.labels),
        .labels_removed = try diffAdded(allocator, current.labels, desired.labels),
        .assignees_added = try diffAdded(allocator, desired.assignees, current.assignees),
        .assignees_removed = try diffAdded(allocator, current.assignees, desired.assignees),
    };
    defer allocator.free(update.labels_added);
    defer allocator.free(update.labels_removed);
    defer allocator.free(update.assignees_added);
    defer allocator.free(update.assignees_removed);
    if (!update.hasChanges()) return;
    const occurred_at = try timestampOrNow(allocator, firstJsonValue(issue.get("updated_at"), issue.get("created_at")));
    defer allocator.free(occurred_at);
    try writeImportedIssueUpdated(allocator, writer, issue_id, occurred_at, update);
    stats.issues += 1;
}

fn syncExistingPull(allocator: Allocator, writer: *EventWriter, pull_id: []const u8, pull: std.json.ObjectMap, stats: *ImportStats) !void {
    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();
    try index.ensureIndex(allocator, repo);
    var db = try index.SqliteDb.open(allocator, repo.index_path, index.sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    const current = (try localPullState(allocator, &db, pull_id)) orelse return;
    defer current.deinit(allocator);
    const desired = try desiredPullState(allocator, pull);
    defer desired.deinit(allocator);
    const occurred_at = try timestampOrNow(allocator, firstJsonValue(pull.get("updated_at"), pull.get("created_at")));
    defer allocator.free(occurred_at);
    if (std.mem.eql(u8, desired.state, "merged") and !std.mem.eql(u8, current.state, "merged")) {
        try writeImportedPullMerged(allocator, writer, pull_id, occurred_at, event_mod.jsonString(pull.get("merge_commit_sha")) orelse "", null);
        stats.pulls += 1;
        return;
    }
    var update = event_mod.PullUpdate{
        .title = if (!std.mem.eql(u8, current.title, desired.title)) desired.title else null,
        .body = if (!std.mem.eql(u8, current.body, desired.body)) desired.body else null,
        .state = if (!std.mem.eql(u8, current.state, desired.state)) desired.state else null,
        .base_ref = if (!std.mem.eql(u8, current.base_ref, desired.base_ref)) desired.base_ref else null,
        .head_ref = if (!std.mem.eql(u8, current.head_ref, desired.head_ref)) desired.head_ref else null,
        .labels_added = try diffAdded(allocator, desired.labels, current.labels),
        .labels_removed = try diffAdded(allocator, current.labels, desired.labels),
        .assignees_added = try diffAdded(allocator, desired.assignees, current.assignees),
        .assignees_removed = try diffAdded(allocator, current.assignees, desired.assignees),
        .reviewers_added = try diffAdded(allocator, desired.reviewers, current.reviewers),
        .reviewers_removed = try diffAdded(allocator, current.reviewers, desired.reviewers),
    };
    defer allocator.free(update.labels_added);
    defer allocator.free(update.labels_removed);
    defer allocator.free(update.assignees_added);
    defer allocator.free(update.assignees_removed);
    defer allocator.free(update.reviewers_added);
    defer allocator.free(update.reviewers_removed);
    if (!update.hasChanges()) return;
    try writeImportedPullUpdated(allocator, writer, pull_id, occurred_at, update);
    stats.pulls += 1;
}

const IssueState = struct {
    title: []u8,
    body: []u8,
    state: []u8,
    milestone: []u8,
    labels: [][]u8,
    assignees: [][]u8,

    fn deinit(self: IssueState, allocator: Allocator) void {
        allocator.free(self.title);
        allocator.free(self.body);
        allocator.free(self.state);
        allocator.free(self.milestone);
        git.freeStringList(allocator, self.labels);
        git.freeStringList(allocator, self.assignees);
    }
};

const PullState = struct {
    title: []u8,
    body: []u8,
    state: []u8,
    base_ref: []u8,
    head_ref: []u8,
    labels: [][]u8,
    assignees: [][]u8,
    reviewers: [][]u8,

    fn deinit(self: PullState, allocator: Allocator) void {
        allocator.free(self.title);
        allocator.free(self.body);
        allocator.free(self.state);
        allocator.free(self.base_ref);
        allocator.free(self.head_ref);
        git.freeStringList(allocator, self.labels);
        git.freeStringList(allocator, self.assignees);
        git.freeStringList(allocator, self.reviewers);
    }
};

fn localIssueState(allocator: Allocator, db: *index.SqliteDb, issue_id: []const u8) !?IssueState {
    var stmt = try db.prepare(
        \\SELECT i.title, i.body, i.state, COALESCE(m.milestone, '')
        \\FROM issues i
        \\LEFT JOIN issue_metadata m ON m.issue_id = i.id
        \\WHERE i.id = ?
    );
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    if (!(try stmt.step())) return null;
    return .{
        .title = try stmt.columnTextDup(allocator, 0),
        .body = try stmt.columnTextDup(allocator, 1),
        .state = try stmt.columnTextDup(allocator, 2),
        .milestone = try stmt.columnTextDup(allocator, 3),
        .labels = try collectionStrings(allocator, db, "SELECT DISTINCT label FROM issue_labels WHERE issue_id = ? ORDER BY label", issue_id),
        .assignees = try collectionStrings(allocator, db, "SELECT DISTINCT assignee FROM issue_assignees WHERE issue_id = ? ORDER BY assignee", issue_id),
    };
}

fn localPullState(allocator: Allocator, db: *index.SqliteDb, pull_id: []const u8) !?PullState {
    var stmt = try db.prepare("SELECT title, body, state, base_ref, head_ref FROM pulls WHERE id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, pull_id);
    if (!(try stmt.step())) return null;
    return .{
        .title = try stmt.columnTextDup(allocator, 0),
        .body = try stmt.columnTextDup(allocator, 1),
        .state = try stmt.columnTextDup(allocator, 2),
        .base_ref = try stmt.columnTextDup(allocator, 3),
        .head_ref = try stmt.columnTextDup(allocator, 4),
        .labels = try collectionStrings(allocator, db, "SELECT DISTINCT label FROM pull_labels WHERE pull_id = ? ORDER BY label", pull_id),
        .assignees = try collectionStrings(allocator, db, "SELECT DISTINCT assignee FROM pull_assignees WHERE pull_id = ? ORDER BY assignee", pull_id),
        .reviewers = try collectionStrings(allocator, db, "SELECT DISTINCT reviewer FROM pull_reviewers WHERE pull_id = ? ORDER BY reviewer", pull_id),
    };
}

fn collectionStrings(allocator: Allocator, db: *index.SqliteDb, sql: []const u8, object_id: []const u8) ![][]u8 {
    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    try stmt.bindText(1, object_id);
    var list: std.ArrayList([]u8) = .empty;
    errdefer git.freeStringList(allocator, list.items);
    while (try stmt.step()) {
        try list.append(allocator, try stmt.columnTextDup(allocator, 0));
    }
    return try list.toOwnedSlice(allocator);
}

fn desiredIssueState(allocator: Allocator, issue: std.json.ObjectMap) !IssueState {
    const title = try sizedString(allocator, event_mod.jsonString(issue.get("title")), "(untitled)", git.max_payload_title_bytes);
    errdefer allocator.free(title);
    const body = try sizedString(allocator, event_mod.jsonString(issue.get("description")) orelse event_mod.jsonString(issue.get("body")), "", git.max_payload_text_bytes);
    errdefer allocator.free(body);
    const state = try allocator.dupe(u8, gitlabIssueState(issue) orelse "open");
    errdefer allocator.free(state);
    const milestone = try sizedString(allocator, common.milestoneTitle(issue), "", git.max_payload_atom_bytes);
    errdefer allocator.free(milestone);
    const labels = try common.labels(allocator, issue);
    errdefer git.freeStringList(allocator, labels);
    const assignees = try common.userArray(allocator, issue.get("assignees"));
    return .{
        .title = title,
        .body = body,
        .state = state,
        .milestone = milestone,
        .labels = labels,
        .assignees = assignees,
    };
}

fn desiredPullState(allocator: Allocator, pull: std.json.ObjectMap) !PullState {
    const title = try sizedString(allocator, event_mod.jsonString(pull.get("title")), "(untitled)", git.max_payload_title_bytes);
    errdefer allocator.free(title);
    const body = try sizedString(allocator, event_mod.jsonString(pull.get("description")) orelse event_mod.jsonString(pull.get("body")), "", git.max_payload_text_bytes);
    errdefer allocator.free(body);
    const state = try allocator.dupe(u8, gitlabMergeState(pull) orelse "open");
    errdefer allocator.free(state);
    const base_ref = try sizedString(allocator, event_mod.jsonString(pull.get("target_branch")) orelse common.nestedString(pull, "base", "ref"), "main", git.max_payload_ref_bytes);
    errdefer allocator.free(base_ref);
    const head_ref = try sizedString(allocator, event_mod.jsonString(pull.get("source_branch")) orelse common.nestedString(pull, "head", "ref"), "unknown", git.max_payload_ref_bytes);
    errdefer allocator.free(head_ref);
    const labels = try common.labels(allocator, pull);
    errdefer git.freeStringList(allocator, labels);
    const assignees = try common.userArray(allocator, pull.get("assignees"));
    errdefer git.freeStringList(allocator, assignees);
    const reviewers = try common.userArray(allocator, pull.get("reviewers"));
    return .{
        .title = title,
        .body = body,
        .state = state,
        .base_ref = base_ref,
        .head_ref = head_ref,
        .labels = labels,
        .assignees = assignees,
        .reviewers = reviewers,
    };
}

fn diffAdded(allocator: Allocator, desired: []const []const u8, current: []const []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);
    for (desired) |value| {
        if (!containsString(current, value)) try list.append(allocator, value);
    }
    return try list.toOwnedSlice(allocator);
}

fn containsString(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
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
    var imported: usize = 0;
    var comment_refs = std.AutoHashMap(i64, ImportedCommentRef).init(allocator);
    defer freeImportedCommentRefs(allocator, &comment_refs);
    for (comments.items) |item| {
        if (item != .object) continue;
        if (jsonBool(item.object.get("system")) orelse false) continue;
        const note_id = jsonInteger(item.object.get("id")) orelse continue;
        if (map_file) |path| {
            if (try exporter.lookupMappedObjectId(allocator, path, "comment", note_id)) |existing| {
                allocator.free(existing);
                continue;
            }
        }
        const body = try sizedString(allocator, event_mod.jsonString(item.object.get("body")), "", git.max_payload_text_bytes);
        defer allocator.free(body);
        if (body.len == 0) continue;
        const occurred_at = try timestampOrNow(allocator, item.object.get("created_at"));
        defer allocator.free(occurred_at);
        const source_author = try sizedString(allocator, common.authorUsername(item.object), "", git.max_payload_atom_bytes);
        defer allocator.free(source_author);
        const reply = replyContext(&comment_refs, item.object);
        var written = try writeImportedCommentAdded(allocator, writer, parent_kind, parent_id, occurred_at, body, source_author, reply.id, reply.event_hash);
        errdefer written.deinit(allocator);
        if (map_file) |path| try exporter.recordMappedObjectId(allocator, path, "comment", written.id, note_id);
        const entry = try comment_refs.getOrPut(note_id);
        if (entry.found_existing) entry.value_ptr.deinit(allocator);
        entry.value_ptr.* = written;
        imported += 1;
        stats.comments += 1;
    }
    if (imported != 0) {
        var parent_ref_buf: [util.short_object_ref_len]u8 = undefined;
        try eprint("gt gitlab import: imported {d} new note{s} for {s} #{s}\n", .{ imported, if (imported == 1) "" else "s", parent_kind, util.shortObjectRef(&parent_ref_buf, parent_id) });
    }
}

fn freeImportedCommentRefs(allocator: Allocator, refs: *std.AutoHashMap(i64, ImportedCommentRef)) void {
    var iterator = refs.valueIterator();
    while (iterator.next()) |ref| ref.deinit(allocator);
    refs.deinit();
}

const ReplyContext = struct {
    id: []const u8 = "",
    event_hash: []const u8 = "",
};

fn replyContext(refs: *std.AutoHashMap(i64, ImportedCommentRef), comment: std.json.ObjectMap) ReplyContext {
    const parent_id = jsonInteger(comment.get("in_reply_to_id")) orelse return .{};
    const parent = refs.get(parent_id) orelse return .{};
    return .{ .id = parent.id, .event_hash = parent.event_hash };
}

fn gitlabIid(object: std.json.ObjectMap) ?i64 {
    return jsonInteger(object.get("iid")) orelse jsonInteger(object.get("number"));
}

fn gitlabIssueState(issue: std.json.ObjectMap) ?[]const u8 {
    const state = event_mod.jsonString(issue.get("state")) orelse return null;
    if (std.mem.eql(u8, state, "opened")) return "open";
    if (std.mem.eql(u8, state, "open")) return "open";
    if (std.mem.eql(u8, state, "closed")) return "closed";
    return null;
}

fn gitlabMergeState(pull: std.json.ObjectMap) ?[]const u8 {
    const state = event_mod.jsonString(pull.get("state")) orelse return null;
    if (std.mem.eql(u8, state, "opened")) return "open";
    if (std.mem.eql(u8, state, "open")) return "open";
    if (std.mem.eql(u8, state, "closed")) return "closed";
    if (std.mem.eql(u8, state, "merged")) return "merged";
    return null;
}

fn constStringList(values: [][]u8) []const []const u8 {
    return @ptrCast(values);
}

fn writeImportedIssueOpened(
    allocator: Allocator,
    writer: *EventWriter,
    issue_id: []const u8,
    number: u64,
    occurred_at: []const u8,
    title: []const u8,
    body_text: []const u8,
    labels: [][]u8,
    assignees: [][]u8,
    source_author: []const u8,
    milestone: []const u8,
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
        constStringList(labels),
        constStringList(assignees),
        .{ .gitlab_issue_iid = number },
        .{
            .source_author = if (source_author.len == 0) null else source_author,
            .milestone = if (milestone.len == 0) null else milestone,
        },
    );
    defer allocator.free(body);
    var issue_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const issue_ref = util.shortObjectRef(&issue_ref_buf, issue_id);
    const subject_prefix = try std.fmt.allocPrint(allocator, "issue.opened #{s} GitLab #{d} ", .{ issue_ref, number });
    defer allocator.free(subject_prefix);
    const subject_line = try subject(allocator, subject_prefix, title);
    defer allocator.free(subject_line);
    const commit = try writer.stage("gt gitlab import", subject_line, body);
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
        .{ .gitlab_merge_request_iid = number },
        metadata,
    );
    defer allocator.free(body);
    var pull_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const pull_ref = util.shortObjectRef(&pull_ref_buf, pull_id);
    const subject_prefix = try std.fmt.allocPrint(allocator, "pull.opened #{s} GitLab !{d} ", .{ pull_ref, number });
    defer allocator.free(subject_prefix);
    const subject_line = try subject(allocator, subject_prefix, title);
    defer allocator.free(subject_line);
    const commit = try writer.stage("gt gitlab import", subject_line, body);
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
    const subject_line = try std.fmt.allocPrint(allocator, "{s} #{s} GitLab sync", .{ event_type, object_ref });
    defer allocator.free(subject_line);
    const commit = try writer.stage("gt gitlab import", subject_line, body);
    allocator.free(commit);
}

fn writeImportedIssueUpdated(allocator: Allocator, writer: *EventWriter, issue_id: []const u8, occurred_at: []const u8, update: event_mod.IssueUpdate) !void {
    const event_uuid = try util.newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try util.newUuidV7(allocator);
    defer allocator.free(idem);
    const body = try event_mod.buildIssueUpdatedJson(allocator, writer.cfg, writer.nextSeq(), issue_id, event_uuid, idem, occurred_at, writer.stagedEventParents(), update);
    defer allocator.free(body);
    var issue_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const issue_ref = util.shortObjectRef(&issue_ref_buf, issue_id);
    const subject_line = try std.fmt.allocPrint(allocator, "issue.updated #{s} GitLab sync", .{issue_ref});
    defer allocator.free(subject_line);
    const commit = try writer.stage("gt gitlab import", subject_line, body);
    allocator.free(commit);
}

fn writeImportedPullUpdated(allocator: Allocator, writer: *EventWriter, pull_id: []const u8, occurred_at: []const u8, update: event_mod.PullUpdate) !void {
    const event_uuid = try util.newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try util.newUuidV7(allocator);
    defer allocator.free(idem);
    const body = try event_mod.buildPullUpdatedJson(allocator, writer.cfg, writer.nextSeq(), pull_id, event_uuid, idem, occurred_at, writer.stagedEventParents(), update);
    defer allocator.free(body);
    var pull_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const pull_ref = util.shortObjectRef(&pull_ref_buf, pull_id);
    const subject_line = try std.fmt.allocPrint(allocator, "pull.updated #{s} GitLab sync", .{pull_ref});
    defer allocator.free(subject_line);
    const commit = try writer.stage("gt gitlab import", subject_line, body);
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
    const subject_line = try std.fmt.allocPrint(allocator, "pull.merged #{s} GitLab sync", .{pull_ref});
    defer allocator.free(subject_line);
    const commit = try writer.stage("gt gitlab import", subject_line, body);
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
    if (reply_parent_hash.len != 0 and !containsString(related.items, reply_parent_hash)) try related.append(allocator, reply_parent_hash);
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
    const subject_line = try std.fmt.allocPrint(allocator, "comment.added #{s} GitLab sync", .{comment_id.?[0..7]});
    defer allocator.free(subject_line);
    const commit = try writer.stage("gt gitlab import", subject_line, body);
    errdefer allocator.free(commit);
    const result = ImportedCommentRef{
        .id = comment_id.?,
        .event_hash = commit,
    };
    comment_id = null;
    return result;
}
