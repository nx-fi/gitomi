const std = @import("std");
const errors = @import("../errors.zig");
const event_mod = @import("../event.zig");
const git = @import("../git.zig");
const index = @import("../index.zig");
const io = @import("../io.zig");
const json_writer = @import("../json_writer.zig");
const repo_mod = @import("../repo.zig");
const util = @import("../util.zig");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const appendJsonFieldBool = json_writer.appendJsonFieldBool;
const appendJsonFieldString = json_writer.appendJsonFieldString;
const appendJsonString = json_writer.appendJsonString;
const out = io.out;
const eprint = io.eprint;
const RepoSlug = common.RepoSlug;
const GitHubClient = common.GitHubClient;
const default_api_url = common.default_api_url;
const parseRepoSlug = common.parseRepoSlug;
const githubTokenFromEnv = common.githubTokenFromEnv;
const jsonArray = common.jsonArray;
const jsonBool = common.jsonBool;
const jsonInteger = common.jsonInteger;
const urlPathEscape = common.urlPathEscape;
const appendStringField = common.appendStringField;
const appendBoolField = common.appendBoolField;
const appendStringArrayValueField = common.appendStringArrayValueField;
const singleArrayBody = common.singleArrayBody;
const parseResponseNumber = common.parseResponseNumber;
const legacyNumber = common.legacyNumber;

pub const ExportOptions = struct {
    repo: RepoSlug,
    api_url: []const u8 = default_api_url,
    token_arg: ?[]const u8 = null,
    dry_run: bool = false,
    map_file: ?[]const u8 = null,
    reuse_legacy: bool = false,
    use_gh: bool = false,
    after_ordinal: i64 = 0,
    skip_actor_principal: ?[]const u8 = null,
    skip_actor_device: ?[]const u8 = null,
    quiet: bool = false,
};

pub const ExportResult = struct {
    scanned: usize = 0,
    exported: usize = 0,
    max_ordinal: i64 = 0,
};

pub fn cmdExport(allocator: Allocator, args: []const []const u8) !void {
    var repo_opt: ?RepoSlug = null;
    var api_url: []const u8 = default_api_url;
    var token_arg: ?[]const u8 = null;
    var dry_run = false;
    var map_file_arg: ?[]const u8 = null;
    var reuse_legacy = false;
    var use_gh = false;

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
        } else if (std.mem.eql(u8, arg, "--use-gh")) {
            use_gh = true;
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
    if (!dry_run and token == null and !use_gh) {
        try eprint("gt github export: --token, GITHUB_TOKEN, or --use-gh is required unless --dry-run is used\n", .{});
        return CliError.MissingArgument;
    }

    const options = ExportOptions{
        .repo = repo_opt.?,
        .api_url = api_url,
        .token_arg = token,
        .dry_run = dry_run,
        .map_file = map_file_arg,
        .reuse_legacy = reuse_legacy,
        .use_gh = use_gh,
    };
    _ = try exportToGithub(allocator, options);
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

pub fn exportToGithub(allocator: Allocator, options: ExportOptions) !ExportResult {
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
        .use_gh = options.use_gh,
    };

    var db = try index.SqliteDb.open(allocator, repo.index_path, index.sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var stmt = try db.prepare(
        \\SELECT ordinal, event_type, object_kind, object_id, actor_principal, actor_device, body
        \\FROM events
        \\WHERE domain_status = 'accepted'
        \\  AND (event_type LIKE 'issue.%' OR event_type LIKE 'pull.%' OR event_type LIKE 'comment.%')
        \\  AND ordinal > ?
        \\ORDER BY ordinal
    );
    defer stmt.deinit();
    try stmt.bindInt64(1, options.after_ordinal);

    var result = ExportResult{};
    while (try stmt.step()) {
        const ordinal = stmt.columnInt64(0);
        if (ordinal > result.max_ordinal) result.max_ordinal = ordinal;
        result.scanned += 1;

        const event_type = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(event_type);
        const object_kind = try stmt.columnTextDup(allocator, 2);
        defer allocator.free(object_kind);
        const object_id = try stmt.columnTextDup(allocator, 3);
        defer allocator.free(object_id);
        const actor_principal = try stmt.columnTextDup(allocator, 4);
        defer allocator.free(actor_principal);
        const actor_device = try stmt.columnTextDup(allocator, 5);
        defer allocator.free(actor_device);
        const body = try stmt.columnTextDup(allocator, 6);
        defer allocator.free(body);

        if (options.skip_actor_principal) |principal| {
            if (std.mem.eql(u8, actor_principal, principal)) {
                if (options.skip_actor_device == null or std.mem.eql(u8, actor_device, options.skip_actor_device.?)) {
                    continue;
                }
            }
        }

        if (try exportEvent(allocator, client, &mappings, options, event_type, object_kind, object_id, body)) {
            result.exported += 1;
        }
    }

    if (!options.quiet) {
        try out("github export: replayed {d} event{s}\n", .{ result.exported, if (result.exported == 1) "" else "s" });
    }
    return result;
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

pub fn githubIssueCreateBody(allocator: Allocator, payload: std.json.ObjectMap) ![]u8 {
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

pub fn githubPullCreateBody(allocator: Allocator, payload: std.json.ObjectMap) ![]u8 {
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

pub fn githubIssuePatchBody(allocator: Allocator, payload: std.json.ObjectMap) !?[]u8 {
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

pub fn githubPullPatchBody(allocator: Allocator, payload: std.json.ObjectMap) !?[]u8 {
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

pub fn githubSinglePatchBody(allocator: Allocator, payload: std.json.ObjectMap) ![]u8 {
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

pub fn githubCommentBody(allocator: Allocator, body_text: []const u8) ![]u8 {
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
