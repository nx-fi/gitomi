const std = @import("std");
const event_model = @import("../../event/model.zig");
const event_json = @import("../../event/json.zig");
const event_writer_mod = @import("../../event_writer.zig");
const errors = @import("../../errors.zig");
const git = @import("../../git.zig");
const index = @import("../../index.zig");
const io = @import("../../io.zig");
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
const ensureMilestoneCreatedForTitleStaged = milestone_mod.ensureMilestoneCreatedForTitleStaged;

const gitlab_import_capability = "gitlab.import";
const gitlab_import_scope = "gitlab:*";

pub const ImportOptions = struct {
    base: provider_common.BaseImportOptions = .{
        .api_url = default_api_url,
        .bot_device = import_bot.gitlab_device,
    },
    project: ?ProjectRef = null,
};

const ImportArgParser = struct {
    pub const command_context = "gt gitlab import";
    pub const token_help = "--token-env, --token-file, GITLAB_TOKEN, or GL_TOKEN";

    pub fn parseProviderArg(_: Allocator, args: []const []const u8, i: *usize, arg: []const u8, options: *ImportOptions) !bool {
        if (std.mem.eql(u8, arg, "--project") or std.mem.eql(u8, arg, "--repo")) {
            options.project = try parseProjectRef(try util.requireValue(args, i, arg));
        } else {
            return false;
        }
        return true;
    }
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

const ImportedCommentRef = provider_common.ImportedCommentRef;

pub fn cmdImport(allocator: Allocator, args: []const []const u8) !void {
    var options = ImportOptions{};
    var parsed_args = try provider_common.parseImportArgs(allocator, args, &options, ImportArgParser);
    defer parsed_args.deinit();

    if (options.project == null and options.base.from_file == null) {
        try eprint("gt gitlab import: --project or --from-file is required\n", .{});
        return CliError.MissingArgument;
    }

    try eprint("gt gitlab import: preparing delegated import actor {s}/{s}\n", .{ options.base.bot_principal, options.base.bot_device });
    try ensureImportDelegation(allocator, options.base.bot_principal, options.base.bot_device);

    var token_owned: ?[]u8 = null;
    defer if (token_owned) |value| allocator.free(value);
    const token = options.base.token_arg orelse blk: {
        token_owned = common.tokenFromEnv(allocator) catch null;
        break :blk token_owned;
    };
    if (options.base.from_file == null and token == null) {
        try eprint("gt gitlab import: --token-env, --token-file, GITLAB_TOKEN, or GL_TOKEN is required for API imports\n", .{});
        return CliError.MissingArgument;
    }

    var stats = ImportStats{};
    if (options.base.from_file) |path| {
        try eprint("gt gitlab import: reading fixture {s}\n", .{path});
        try importFromFile(allocator, path, options, &stats);
    } else {
        const client = GitLabClient{
            .allocator = allocator,
            .api_url = options.base.api_url,
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
    try provider_common.ensureImportDelegation(allocator, principal, device, .{
        .command_context = "gt gitlab import",
        .provider_name = "GitLab",
        .capability = gitlab_import_capability,
        .scope = gitlab_import_scope,
    });
}

fn importFromFile(allocator: Allocator, path: []const u8, options: ImportOptions, stats: *ImportStats) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(@import("compat").io(), path, allocator, .limited(max_gitlab_json));
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
            var writer = try EventWriter.initForActor(allocator, "gt gitlab import", options.base.bot_principal, options.base.bot_device);
            defer writer.deinit();
            const issue_result = try importIssueObject(allocator, &writer, item.object, options.base.map_file, stats);
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
            var writer = try EventWriter.initForActor(allocator, "gt gitlab import", options.base.bot_principal, options.base.bot_device);
            defer writer.deinit();
            const pull_result = try importPullObject(allocator, &writer, item.object, options.base.map_file, stats);
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
    const number = gitlabIid(object) orelse return;
    const comments_root = switch (root.get("notes") orelse root.get("comments") orelse return) {
        .object => |map| map,
        else => return,
    };
    const key = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ parent_kind, number });
    defer allocator.free(key);
    const comments = jsonArray(comments_root.get(key)) orelse return;
    try importCommentsArray(allocator, writer, parent_kind, parent_id, comments, options.base.map_file, stats);
}

pub fn importFromApi(allocator: Allocator, client: GitLabClient, options: ImportOptions, stats: *ImportStats) !void {
    var page: usize = 1;
    while (page <= options.base.max_pages) : (page += 1) {
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
            if (event_json.jsonString(item.object.get("issue_type"))) |issue_type| {
                if (!std.mem.eql(u8, issue_type, "issue")) continue;
            }
            var writer = try EventWriter.initForActor(allocator, "gt gitlab import", options.base.bot_principal, options.base.bot_device);
            defer writer.deinit();
            const issue_result = try importIssueObject(allocator, &writer, item.object, options.base.map_file, stats);
            defer if (issue_result) |result| allocator.free(result.id);
            if (issue_result) |result| {
                if (result.is_new and shouldFetchApiComments(result.comment_count)) try importApiComments(allocator, &writer, client, "issue", gitlabIid(item.object).?, result.id, options, stats);
                try writer.commitStaged();
            }
        }
        if (issues.items.len < 100) break;
    }

    page = 1;
    while (page <= options.base.max_pages) : (page += 1) {
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
            var writer = try EventWriter.initForActor(allocator, "gt gitlab import", options.base.bot_principal, options.base.bot_device);
            defer writer.deinit();
            const pull_result = try importPullObject(allocator, &writer, item.object, options.base.map_file, stats);
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
    if (!options.base.include_comments) return;
    var total: usize = 0;
    var page: usize = 1;
    while (page <= options.base.max_pages) : (page += 1) {
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
        try importCommentsArray(allocator, writer, parent_kind, parent_id, notes, options.base.map_file, stats);
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
    const title = try sizedString(allocator, event_json.jsonString(issue.get("title")), "(untitled)", git.max_payload_title_bytes);
    defer allocator.free(title);
    const body = try sizedString(allocator, event_json.jsonString(issue.get("description")) orelse event_json.jsonString(issue.get("body")), "", git.max_payload_text_bytes);
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
    try ensureMilestoneCreatedForTitleStaged(allocator, writer, milestone, "", "", occurred_at, "gt gitlab import");
    try writeImportedIssueOpened(allocator, writer, issue_id, @intCast(number), occurred_at, title, body, labels, assignees, source_author, milestone);
    if (gitlabIssueState(issue)) |state| {
        if (std.mem.eql(u8, state, "closed")) {
            const closed_at = try timestampOrNow(allocator, firstJsonValue(issue.get("closed_at"), issue.get("updated_at")));
            defer allocator.free(closed_at);
            try writeImportedStringEvent(allocator, writer, .issue, issue_id, "issue.state_set", "state", "closed", closed_at);
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
    const title = try sizedString(allocator, event_json.jsonString(pull.get("title")), "(untitled)", git.max_payload_title_bytes);
    defer allocator.free(title);
    const body = try sizedString(allocator, event_json.jsonString(pull.get("description")) orelse event_json.jsonString(pull.get("body")), "", git.max_payload_text_bytes);
    defer allocator.free(body);
    const base_ref = try sizedString(allocator, event_json.jsonString(pull.get("target_branch")) orelse common.nestedString(pull, "base", "ref"), "main", git.max_payload_ref_bytes);
    defer allocator.free(base_ref);
    const head_ref = try sizedString(allocator, event_json.jsonString(pull.get("source_branch")) orelse common.nestedString(pull, "head", "ref"), "unknown", git.max_payload_ref_bytes);
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
            .labels = provider_common.constStringList(labels),
            .assignees = provider_common.constStringList(assignees),
            .reviewers = provider_common.constStringList(reviewers),
            .commit_count = common.optionalUnsignedField(pull, &.{ "commits_count", "commit_count" }),
            .changed_files = common.optionalUnsignedField(pull, &.{ "changes_count", "changed_files", "file_count" }),
        },
    );
    if (gitlabMergeState(pull)) |state| {
        if (std.mem.eql(u8, state, "merged")) {
            const merged_at = try timestampOrNow(allocator, firstJsonValue(pull.get("merged_at"), pull.get("updated_at")));
            defer allocator.free(merged_at);
            try writeImportedPullMerged(allocator, writer, pull_id, merged_at, event_json.jsonString(pull.get("merge_commit_sha")) orelse "", null);
        } else if (std.mem.eql(u8, state, "closed")) {
            const closed_at = try timestampOrNow(allocator, firstJsonValue(pull.get("closed_at"), pull.get("updated_at")));
            defer allocator.free(closed_at);
            try writeImportedStringEvent(allocator, writer, .pull, pull_id, "pull.state_set", "state", "closed", closed_at);
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
    const occurred_at = try timestampOrNow(allocator, firstJsonValue(issue.get("updated_at"), issue.get("created_at")));
    defer allocator.free(occurred_at);
    try ensureMilestoneCreatedForTitleStaged(allocator, writer, desired.milestone, "", "", occurred_at, "gt gitlab import");
    var label_diff = try provider_common.diffStringLists(allocator, desired.labels, current.labels);
    defer label_diff.deinit();
    var assignee_diff = try provider_common.diffStringLists(allocator, desired.assignees, current.assignees);
    defer assignee_diff.deinit();

    var update = event_model.IssueUpdate{
        .title = if (!std.mem.eql(u8, current.title, desired.title)) desired.title else null,
        .body = if (!std.mem.eql(u8, current.body, desired.body)) desired.body else null,
        .state = if (!std.mem.eql(u8, current.state, desired.state)) desired.state else null,
        .milestone = if (!std.mem.eql(u8, current.milestone, desired.milestone)) desired.milestone else null,
        .labels_added = label_diff.added,
        .labels_removed = label_diff.removed,
        .assignees_added = assignee_diff.added,
        .assignees_removed = assignee_diff.removed,
    };
    if (!update.hasChanges()) return;
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
        try writeImportedPullMerged(allocator, writer, pull_id, occurred_at, event_json.jsonString(pull.get("merge_commit_sha")) orelse "", null);
        stats.pulls += 1;
        return;
    }
    var label_diff = try provider_common.diffStringLists(allocator, desired.labels, current.labels);
    defer label_diff.deinit();
    var assignee_diff = try provider_common.diffStringLists(allocator, desired.assignees, current.assignees);
    defer assignee_diff.deinit();
    var reviewer_diff = try provider_common.diffStringLists(allocator, desired.reviewers, current.reviewers);
    defer reviewer_diff.deinit();

    var update = event_model.PullUpdate{
        .title = if (!std.mem.eql(u8, current.title, desired.title)) desired.title else null,
        .body = if (!std.mem.eql(u8, current.body, desired.body)) desired.body else null,
        .state = if (!std.mem.eql(u8, current.state, desired.state)) desired.state else null,
        .base_ref = if (!std.mem.eql(u8, current.base_ref, desired.base_ref)) desired.base_ref else null,
        .head_ref = if (!std.mem.eql(u8, current.head_ref, desired.head_ref)) desired.head_ref else null,
        .labels_added = label_diff.added,
        .labels_removed = label_diff.removed,
        .assignees_added = assignee_diff.added,
        .assignees_removed = assignee_diff.removed,
        .reviewers_added = reviewer_diff.added,
        .reviewers_removed = reviewer_diff.removed,
    };
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
        .labels = try provider_common.queryStringList(allocator, db, "SELECT DISTINCT label FROM issue_labels WHERE issue_id = ? ORDER BY label", issue_id),
        .assignees = try provider_common.queryStringList(allocator, db, "SELECT DISTINCT assignee FROM issue_assignees WHERE issue_id = ? ORDER BY assignee", issue_id),
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
        .labels = try provider_common.queryStringList(allocator, db, "SELECT DISTINCT label FROM pull_labels WHERE pull_id = ? ORDER BY label", pull_id),
        .assignees = try provider_common.queryStringList(allocator, db, "SELECT DISTINCT assignee FROM pull_assignees WHERE pull_id = ? ORDER BY assignee", pull_id),
        .reviewers = try provider_common.queryStringList(allocator, db, "SELECT DISTINCT reviewer FROM pull_reviewers WHERE pull_id = ? ORDER BY reviewer", pull_id),
    };
}

fn desiredIssueState(allocator: Allocator, issue: std.json.ObjectMap) !IssueState {
    const title = try sizedString(allocator, event_json.jsonString(issue.get("title")), "(untitled)", git.max_payload_title_bytes);
    errdefer allocator.free(title);
    const body = try sizedString(allocator, event_json.jsonString(issue.get("description")) orelse event_json.jsonString(issue.get("body")), "", git.max_payload_text_bytes);
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
    const title = try sizedString(allocator, event_json.jsonString(pull.get("title")), "(untitled)", git.max_payload_title_bytes);
    errdefer allocator.free(title);
    const body = try sizedString(allocator, event_json.jsonString(pull.get("description")) orelse event_json.jsonString(pull.get("body")), "", git.max_payload_text_bytes);
    errdefer allocator.free(body);
    const state = try allocator.dupe(u8, gitlabMergeState(pull) orelse "open");
    errdefer allocator.free(state);
    const base_ref = try sizedString(allocator, event_json.jsonString(pull.get("target_branch")) orelse common.nestedString(pull, "base", "ref"), "main", git.max_payload_ref_bytes);
    errdefer allocator.free(base_ref);
    const head_ref = try sizedString(allocator, event_json.jsonString(pull.get("source_branch")) orelse common.nestedString(pull, "head", "ref"), "unknown", git.max_payload_ref_bytes);
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
        const body = try sizedString(allocator, event_json.jsonString(item.object.get("body")), "", git.max_payload_text_bytes);
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
    const state = event_json.jsonString(issue.get("state")) orelse return null;
    if (std.mem.eql(u8, state, "opened")) return "open";
    if (std.mem.eql(u8, state, "open")) return "open";
    if (std.mem.eql(u8, state, "closed")) return "closed";
    return null;
}

fn gitlabMergeState(pull: std.json.ObjectMap) ?[]const u8 {
    const state = event_json.jsonString(pull.get("state")) orelse return null;
    if (std.mem.eql(u8, state, "opened")) return "open";
    if (std.mem.eql(u8, state, "open")) return "open";
    if (std.mem.eql(u8, state, "closed")) return "closed";
    if (std.mem.eql(u8, state, "merged")) return "merged";
    return null;
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
    const subject_prefix = try provider_common.openedSubjectPrefix(allocator, .issue, issue_id, "GitLab", "#", number);
    defer allocator.free(subject_prefix);
    const subject_line = try subject(allocator, subject_prefix, title);
    defer allocator.free(subject_line);
    try provider_common.writeImportedIssueOpened(allocator, writer, .{
        .issue_id = issue_id,
        .occurred_at = occurred_at,
        .title = title,
        .body_text = body_text,
        .labels = provider_common.constStringList(labels),
        .assignees = provider_common.constStringList(assignees),
        .legacy = .{ .gitlab_issue_iid = number },
        .metadata = .{
            .source_author = if (source_author.len == 0) null else source_author,
            .milestone = if (milestone.len == 0) null else milestone,
        },
        .command_context = "gt gitlab import",
        .subject = subject_line,
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
    const subject_prefix = try provider_common.openedSubjectPrefix(allocator, .pull, pull_id, "GitLab", "!", number);
    defer allocator.free(subject_prefix);
    const subject_line = try subject(allocator, subject_prefix, title);
    defer allocator.free(subject_line);
    try provider_common.writeImportedPullOpened(allocator, writer, .{
        .pull_id = pull_id,
        .occurred_at = occurred_at,
        .title = title,
        .body_text = body_text,
        .base_ref = base_ref,
        .head_ref = head_ref,
        .draft = draft,
        .legacy = .{ .gitlab_merge_request_iid = number },
        .metadata = metadata,
        .command_context = "gt gitlab import",
        .subject = subject_line,
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
        .command_context = "gt gitlab import",
        .subject_suffix = " GitLab sync",
    });
}

fn writeImportedIssueUpdated(allocator: Allocator, writer: *EventWriter, issue_id: []const u8, occurred_at: []const u8, update: event_model.IssueUpdate) !void {
    try provider_common.writeImportedIssueUpdated(allocator, writer, .{
        .issue_id = issue_id,
        .occurred_at = occurred_at,
        .update = update,
        .command_context = "gt gitlab import",
        .subject_suffix = " GitLab sync",
    });
}

fn writeImportedPullUpdated(allocator: Allocator, writer: *EventWriter, pull_id: []const u8, occurred_at: []const u8, update: event_model.PullUpdate) !void {
    try provider_common.writeImportedPullUpdated(allocator, writer, .{
        .pull_id = pull_id,
        .occurred_at = occurred_at,
        .update = update,
        .command_context = "gt gitlab import",
        .subject_suffix = " GitLab sync",
    });
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
        .command_context = "gt gitlab import",
        .subject_suffix = " GitLab sync",
    });
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
    return try provider_common.writeImportedCommentAdded(allocator, writer, .{
        .parent_kind = parent_kind,
        .parent_id = parent_id,
        .occurred_at = occurred_at,
        .body_text = body_text,
        .metadata = .{
            .source_author = if (source_author.len == 0) null else source_author,
            .reply_parent_id = if (reply_parent_id.len == 0) null else reply_parent_id,
            .reply_parent_hash = if (reply_parent_hash.len == 0) null else reply_parent_hash,
        },
        .reply_parent_hash = reply_parent_hash,
        .command_context = "gt gitlab import",
        .subject_suffix = " GitLab sync",
    });
}
