const std = @import("std");
const errors = @import("../../errors.zig");
const event_json = @import("../../event/json.zig");
const git = @import("../../git.zig");
const index = @import("../../index.zig");
const io = @import("../../io.zig");
const json_writer = @import("../../json_writer.zig");
const repo_mod = @import("../../repo.zig");
const util = @import("../../util.zig");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const appendJsonFieldInteger = json_writer.appendJsonFieldInteger;
const appendJsonFieldString = json_writer.appendJsonFieldString;
const appendJsonString = json_writer.appendJsonString;
const out = io.out;
const eprint = io.eprint;
const GitLabClient = common.GitLabClient;
const ProjectRef = common.ProjectRef;
const default_api_url = common.default_api_url;
const parseProjectRef = common.parseProjectRef;
const jsonArray = common.jsonArray;
const jsonInteger = common.jsonInteger;
const appendStringField = common.appendStringField;

pub const ExportOptions = struct {
    project: ProjectRef,
    api_url: []const u8 = default_api_url,
    token_arg: ?[]const u8 = null,
    dry_run: bool = false,
    map_file: ?[]const u8 = null,
    after_ordinal: i64 = 0,
    skip_actor_principal: ?[]const u8 = null,
    skip_actor_device: ?[]const u8 = null,
    max_events: usize = 0,
    quiet: bool = false,
};

pub const ExportResult = struct {
    scanned: usize = 0,
    exported: usize = 0,
    max_ordinal: i64 = 0,
};

pub fn cmdExport(allocator: Allocator, args: []const []const u8) !void {
    var project_opt: ?ProjectRef = null;
    var api_url: []const u8 = default_api_url;
    var token_arg: ?[]const u8 = null;
    var token_source_owned: ?[]u8 = null;
    defer if (token_source_owned) |value| allocator.free(value);
    var dry_run = false;
    var map_file_arg: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--project") or std.mem.eql(u8, arg, "--repo")) {
            project_opt = try parseProjectRef(try util.requireValue(args, &i, arg));
        } else if (std.mem.eql(u8, arg, "--api-url")) {
            api_url = try util.requireValue(args, &i, "--api-url");
        } else if (std.mem.eql(u8, arg, "--token")) {
            _ = try util.requireValue(args, &i, "--token");
            try eprint("gt gitlab export: --token exposes credentials in process lists; use --token-env, --token-file, GITLAB_TOKEN, or GL_TOKEN\n", .{});
            return CliError.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "--token-env")) {
            const env_name = try util.requireValue(args, &i, "--token-env");
            if (token_source_owned) |value| allocator.free(value);
            token_source_owned = null;
            token_source_owned = try common.secretFromEnv(allocator, "gt gitlab export", env_name);
            token_arg = token_source_owned;
        } else if (std.mem.eql(u8, arg, "--token-file")) {
            const path = try util.requireValue(args, &i, "--token-file");
            if (token_source_owned) |value| allocator.free(value);
            token_source_owned = null;
            token_source_owned = try common.secretFromFile(allocator, "gt gitlab export", path);
            token_arg = token_source_owned;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "--map-file")) {
            map_file_arg = try util.requireValue(args, &i, "--map-file");
        } else {
            try eprint("gt gitlab export: unknown option '{s}'\n", .{arg});
            return CliError.UserError;
        }
    }

    if (project_opt == null) {
        try eprint("gt gitlab export: --project GROUP/PROJECT is required\n", .{});
        return CliError.MissingArgument;
    }

    var token_owned: ?[]u8 = null;
    defer if (token_owned) |value| allocator.free(value);
    const token = token_arg orelse blk: {
        token_owned = common.tokenFromEnv(allocator) catch null;
        break :blk token_owned;
    };
    if (!dry_run and token == null) {
        try eprint("gt gitlab export: --token-env, --token-file, GITLAB_TOKEN, or GL_TOKEN is required unless --dry-run is used\n", .{});
        return CliError.MissingArgument;
    }

    _ = try exportToGitlab(allocator, .{
        .project = project_opt.?,
        .api_url = api_url,
        .token_arg = token,
        .dry_run = dry_run,
        .map_file = map_file_arg,
    });
}

const MappingStore = struct {
    allocator: Allocator,
    path: []u8,
    dry_run: bool,
    lock_file: ?std.Io.File = null,
    next_synthetic: i64 = 1,
    map: std.StringHashMap(i64),

    fn init(allocator: Allocator, repo: repo_mod.Repo, project: ProjectRef, explicit_path: ?[]const u8, dry_run: bool) !MappingStore {
        const path = if (explicit_path) |value|
            try allocator.dupe(u8, value)
        else blk: {
            const project_segment = try util.sanitizeRefSegment(allocator, project.path);
            defer allocator.free(project_segment);
            break :blk try std.fs.path.join(allocator, &.{ repo.gitomi_dir, "gitlab", project_segment, "map.jsonl" });
        };
        errdefer allocator.free(path);

        const lock_file = if (!dry_run) try acquireMapLock(allocator, path) else null;
        errdefer if (lock_file) |file| file.close(@import("compat").io());

        return .{
            .allocator = allocator,
            .path = path,
            .dry_run = dry_run,
            .lock_file = lock_file,
            .map = std.StringHashMap(i64).init(allocator),
        };
    }

    fn deinit(self: *MappingStore) void {
        if (self.lock_file) |file| file.close(@import("compat").io());
        var keys = self.map.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        self.map.deinit();
        self.allocator.free(self.path);
    }

    fn load(self: *MappingStore) !void {
        const bytes = std.Io.Dir.cwd().readFileAlloc(@import("compat").io(), self.path, self.allocator, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(bytes);
        var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
        var line_number: usize = 0;
        while (lines.next()) |line_raw| {
            line_number += 1;
            const line = std.mem.trim(u8, line_raw, " \t\r\n");
            if (line.len == 0) continue;
            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch {
                try eprint("gt gitlab export: map file {s} has an invalid JSON line at {d}; refusing to risk duplicate GitLab creates\n", .{ self.path, line_number });
                return CliError.UserError;
            };
            defer parsed.deinit();
            const root = switch (parsed.value) {
                .object => |object| object,
                else => {
                    try eprint("gt gitlab export: map file {s} line {d} must be a JSON object\n", .{ self.path, line_number });
                    return CliError.UserError;
                },
            };
            const kind = event_json.jsonString(root.get("kind")) orelse return CliError.UserError;
            const id = event_json.jsonString(root.get("id")) orelse return CliError.UserError;
            const number = jsonInteger(root.get("number")) orelse return CliError.UserError;
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
        if (!self.dry_run) try appendMappingLine(self.allocator, self.path, kind, id, number);
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
};

fn mapKey(allocator: Allocator, kind: []const u8, id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}\x1f{s}", .{ kind, id });
}

fn acquireMapLock(allocator: Allocator, map_path: []const u8) !std.Io.File {
    if (std.fs.path.dirname(map_path)) |dir| try std.Io.Dir.cwd().createDirPath(@import("compat").io(), dir);
    const lock_path = try std.fmt.allocPrint(allocator, "{s}.lock", .{map_path});
    defer allocator.free(lock_path);
    return try std.Io.Dir.cwd().createFile(@import("compat").io(), lock_path, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
        .permissions = @enumFromInt(0o600),
    });
}

pub fn lookupMappedObjectId(allocator: Allocator, map_file: []const u8, kind: []const u8, number: i64) !?[]u8 {
    const lock_file = try acquireMapLock(allocator, map_file);
    defer lock_file.close(@import("compat").io());
    return try lookupMappedObjectIdUnlocked(allocator, map_file, kind, number);
}

pub fn recordMappedObjectId(allocator: Allocator, map_file: []const u8, kind: []const u8, id: []const u8, number: i64) !void {
    const lock_file = try acquireMapLock(allocator, map_file);
    defer lock_file.close(@import("compat").io());
    if (try mappingExistsUnlocked(allocator, map_file, kind, id, number)) return;
    try appendMappingLine(allocator, map_file, kind, id, number);
}

fn lookupMappedObjectIdUnlocked(allocator: Allocator, map_file: []const u8, kind: []const u8, number: i64) !?[]u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(@import("compat").io(), map_file, allocator, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(bytes);

    var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return CliError.UserError;
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |object| object,
            else => return CliError.UserError,
        };
        const mapped_kind = event_json.jsonString(root.get("kind")) orelse return CliError.UserError;
        const mapped_number = jsonInteger(root.get("number")) orelse return CliError.UserError;
        const id = event_json.jsonString(root.get("id")) orelse return CliError.UserError;
        if (std.mem.eql(u8, mapped_kind, kind) and mapped_number == number) return try allocator.dupe(u8, id);
    }
    return null;
}

fn mappingExistsUnlocked(allocator: Allocator, map_file: []const u8, kind: []const u8, id: []const u8, number: i64) !bool {
    const bytes = std.Io.Dir.cwd().readFileAlloc(@import("compat").io(), map_file, allocator, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer allocator.free(bytes);

    var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return CliError.UserError;
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |object| object,
            else => return CliError.UserError,
        };
        const mapped_kind = event_json.jsonString(root.get("kind")) orelse return CliError.UserError;
        const mapped_id = event_json.jsonString(root.get("id")) orelse return CliError.UserError;
        const mapped_number = jsonInteger(root.get("number")) orelse return CliError.UserError;
        if (!std.mem.eql(u8, mapped_kind, kind)) continue;
        if (std.mem.eql(u8, mapped_id, id) or mapped_number == number) return true;
    }
    return false;
}

fn appendMappingLine(allocator: Allocator, map_file: []const u8, kind: []const u8, id: []const u8, number: i64) !void {
    if (std.fs.path.dirname(map_file)) |dir| try std.Io.Dir.cwd().createDirPath(@import("compat").io(), dir);
    var file = std.Io.Dir.cwd().openFile(@import("compat").io(), map_file, .{ .mode = .write_only }) catch |err| switch (err) {
        error.FileNotFound => try std.Io.Dir.cwd().createFile(@import("compat").io(), map_file, .{ .permissions = @enumFromInt(0o600) }),
        else => return err,
    };
    defer file.close(@import("compat").io());
    try @import("compat").seekFileToEnd(file);

    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);
    try line.append(allocator, '{');
    try appendJsonFieldString(&line, allocator, "kind", kind, true);
    try appendJsonFieldString(&line, allocator, "id", id, true);
    try appendJsonFieldInteger(&line, allocator, "number", number, false);
    try line.appendSlice(allocator, "}\n");
    try file.writeStreamingAll(@import("compat").io(), line.items);
    try file.sync(@import("compat").io());
}

pub fn exportToGitlab(allocator: Allocator, options: ExportOptions) !ExportResult {
    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();
    try index.ensureIndex(allocator, repo);

    var mappings = try MappingStore.init(allocator, repo, options.project, options.map_file, options.dry_run);
    defer mappings.deinit();
    try mappings.load();

    const client = GitLabClient{
        .allocator = allocator,
        .api_url = options.api_url,
        .project = options.project,
        .token = options.token_arg,
        .dry_run = options.dry_run,
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
                if (options.skip_actor_device == null or std.mem.eql(u8, actor_device, options.skip_actor_device.?)) continue;
            }
        }

        if (try exportEvent(allocator, repo, client, &mappings, event_type, object_kind, object_id, body)) {
            result.exported += 1;
            if (options.max_events != 0 and result.exported >= options.max_events) break;
        }
    }

    if (!options.quiet) {
        try out("gitlab export: replayed {d} event{s}\n", .{ result.exported, if (result.exported == 1) "" else "s" });
    }
    return result;
}

fn exportEvent(
    allocator: Allocator,
    repo: repo_mod.Repo,
    client: GitLabClient,
    mappings: *MappingStore,
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
        return try exportIssueEvent(allocator, client, mappings, event_type, object_id, payload);
    }
    if (std.mem.startsWith(u8, event_type, "pull.")) {
        return try exportPullEvent(allocator, client, mappings, event_type, object_id, payload);
    }
    if (std.mem.startsWith(u8, event_type, "comment.") and std.mem.eql(u8, object_kind, "comment")) {
        return try exportCommentEvent(allocator, repo, client, mappings, event_type, object_id, payload);
    }
    return false;
}

fn exportIssueEvent(
    allocator: Allocator,
    client: GitLabClient,
    mappings: *MappingStore,
    event_type: []const u8,
    issue_id: []const u8,
    payload: std.json.ObjectMap,
) !bool {
    // Remote identity comes from the map file or from objects created by this
    // exporter. Event legacy metadata is collaborator-controlled.
    if (std.mem.eql(u8, event_type, "issue.opened")) {
        if (try mappings.get("issue", issue_id) != null) return false;
        const assignee_ids = try resolveUserIdsFromPayload(allocator, client, payload.get("assignees"));
        defer allocator.free(assignee_ids);
        const request_body = try gitlabIssueCreateBody(allocator, payload, assignee_ids);
        defer allocator.free(request_body);
        const path = try client.projectPath(allocator, "/issues");
        defer allocator.free(path);
        const raw = try client.request("POST", path, request_body);
        defer allocator.free(raw);
        const iid = if (client.dry_run) try mappings.putSynthetic("issue", issue_id) else common.parseResponseNumber(allocator, raw, "iid") orelse return CliError.UserError;
        if (!client.dry_run) try mappings.put("issue", issue_id, iid);
        return true;
    }

    const iid = (try mappings.get("issue", issue_id)) orelse return false;
    if (std.mem.eql(u8, event_type, "issue.updated")) {
        var changed = false;
        if (try gitlabIssuePatchBody(allocator, payload)) |request_body| {
            defer allocator.free(request_body);
            const path = try issuePath(allocator, client, iid);
            defer allocator.free(path);
            const raw = try client.request("PUT", path, request_body);
            allocator.free(raw);
            changed = true;
        }
        try replayLabels(allocator, client, "issue", iid, payload, "labels_added", "labels_removed");
        try replayAssignees(allocator, client, "issue", iid, payload, "assignees_added", "assignees_removed");
        return changed;
    }
    if (std.mem.eql(u8, event_type, "issue.title_set") or std.mem.eql(u8, event_type, "issue.body_set") or std.mem.eql(u8, event_type, "issue.state_set")) {
        const request_body = try gitlabSinglePatchBody(allocator, payload);
        defer allocator.free(request_body);
        const path = try issuePath(allocator, client, iid);
        defer allocator.free(path);
        const raw = try client.request("PUT", path, request_body);
        allocator.free(raw);
        return true;
    }
    if (std.mem.eql(u8, event_type, "issue.label_added")) {
        try replayOneLabel(allocator, client, "issue", iid, event_json.jsonString(payload.get("label")) orelse "", true);
        return true;
    }
    if (std.mem.eql(u8, event_type, "issue.label_removed")) {
        try replayOneLabel(allocator, client, "issue", iid, event_json.jsonString(payload.get("label")) orelse "", false);
        return true;
    }
    if (std.mem.eql(u8, event_type, "issue.assignee_added")) {
        try replayOneAssignee(allocator, client, "issue", iid, event_json.jsonString(payload.get("assignee")) orelse "", true);
        return true;
    }
    if (std.mem.eql(u8, event_type, "issue.assignee_removed")) {
        try replayOneAssignee(allocator, client, "issue", iid, event_json.jsonString(payload.get("assignee")) orelse "", false);
        return true;
    }
    return false;
}

fn exportPullEvent(
    allocator: Allocator,
    client: GitLabClient,
    mappings: *MappingStore,
    event_type: []const u8,
    pull_id: []const u8,
    payload: std.json.ObjectMap,
) !bool {
    // Remote identity comes from the map file or from objects created by this
    // exporter. Event legacy metadata is collaborator-controlled.
    if (std.mem.eql(u8, event_type, "pull.opened")) {
        if (try mappings.get("pull", pull_id) != null) return false;
        const assignee_ids = try resolveUserIdsFromPayload(allocator, client, payload.get("assignees"));
        defer allocator.free(assignee_ids);
        const reviewer_ids = try resolveUserIdsFromPayload(allocator, client, payload.get("reviewers"));
        defer allocator.free(reviewer_ids);
        const request_body = try gitlabMergeRequestCreateBody(allocator, payload, assignee_ids, reviewer_ids);
        defer allocator.free(request_body);
        const path = try client.projectPath(allocator, "/merge_requests");
        defer allocator.free(path);
        const raw = try client.request("POST", path, request_body);
        defer allocator.free(raw);
        const iid = if (client.dry_run) try mappings.putSynthetic("pull", pull_id) else common.parseResponseNumber(allocator, raw, "iid") orelse return CliError.UserError;
        if (!client.dry_run) try mappings.put("pull", pull_id, iid);
        return true;
    }

    const iid = (try mappings.get("pull", pull_id)) orelse return false;
    if (std.mem.eql(u8, event_type, "pull.updated")) {
        var changed = false;
        if (try gitlabMergeRequestPatchBody(allocator, payload)) |request_body| {
            defer allocator.free(request_body);
            const path = try mergeRequestPath(allocator, client, iid);
            defer allocator.free(path);
            const raw = try client.request("PUT", path, request_body);
            allocator.free(raw);
            changed = true;
        }
        try replayLabels(allocator, client, "pull", iid, payload, "labels_added", "labels_removed");
        try replayAssignees(allocator, client, "pull", iid, payload, "assignees_added", "assignees_removed");
        try replayReviewers(allocator, client, iid, payload, "reviewers_added", "reviewers_removed");
        return changed;
    }
    if (std.mem.eql(u8, event_type, "pull.merged")) {
        const path = try mergeRequestSubPath(allocator, client, iid, "/merge");
        defer allocator.free(path);
        const raw = try client.request("PUT", path, "{}");
        allocator.free(raw);
        return true;
    }
    if (std.mem.eql(u8, event_type, "pull.title_set") or std.mem.eql(u8, event_type, "pull.body_set") or std.mem.eql(u8, event_type, "pull.state_set") or std.mem.eql(u8, event_type, "pull.base_set")) {
        const request_body = if (try gitlabMergeRequestPatchBody(allocator, payload)) |body| body else try allocator.dupe(u8, "{}");
        defer allocator.free(request_body);
        const path = try mergeRequestPath(allocator, client, iid);
        defer allocator.free(path);
        const raw = try client.request("PUT", path, request_body);
        allocator.free(raw);
        return true;
    }
    if (std.mem.eql(u8, event_type, "pull.label_added")) {
        try replayOneLabel(allocator, client, "pull", iid, event_json.jsonString(payload.get("label")) orelse "", true);
        return true;
    }
    if (std.mem.eql(u8, event_type, "pull.label_removed")) {
        try replayOneLabel(allocator, client, "pull", iid, event_json.jsonString(payload.get("label")) orelse "", false);
        return true;
    }
    if (std.mem.eql(u8, event_type, "pull.assignee_added")) {
        try replayOneAssignee(allocator, client, "pull", iid, event_json.jsonString(payload.get("assignee")) orelse "", true);
        return true;
    }
    if (std.mem.eql(u8, event_type, "pull.assignee_removed")) {
        try replayOneAssignee(allocator, client, "pull", iid, event_json.jsonString(payload.get("assignee")) orelse "", false);
        return true;
    }
    if (std.mem.eql(u8, event_type, "pull.reviewer_added")) {
        try replayOneReviewer(allocator, client, iid, event_json.jsonString(payload.get("reviewer")) orelse "", true);
        return true;
    }
    if (std.mem.eql(u8, event_type, "pull.reviewer_removed")) {
        try replayOneReviewer(allocator, client, iid, event_json.jsonString(payload.get("reviewer")) orelse "", false);
        return true;
    }
    return false;
}

fn exportCommentEvent(
    allocator: Allocator,
    repo: repo_mod.Repo,
    client: GitLabClient,
    mappings: *MappingStore,
    event_type: []const u8,
    comment_id: []const u8,
    payload: std.json.ObjectMap,
) !bool {
    if (std.mem.eql(u8, event_type, "comment.added")) {
        if (try mappings.get("comment", comment_id) != null) return false;
        const parent_kind = event_json.jsonString(payload.get("parent_kind")) orelse return false;
        const parent_id = event_json.jsonString(payload.get("parent_id")) orelse return false;
        const parent_iid = (try mappings.get(parent_kind, parent_id)) orelse return false;
        const request_body = try gitlabNoteBody(allocator, event_json.jsonString(payload.get("body")) orelse "");
        defer allocator.free(request_body);
        const path = try noteCollectionPath(allocator, client, parent_kind, parent_iid);
        defer allocator.free(path);
        const raw = try client.request("POST", path, request_body);
        defer allocator.free(raw);
        const note_id = if (client.dry_run) try mappings.putSynthetic("comment", comment_id) else common.parseResponseNumber(allocator, raw, "id") orelse return CliError.UserError;
        if (!client.dry_run) try mappings.put("comment", comment_id, note_id);
        return true;
    }

    const note_id = (try mappings.get("comment", comment_id)) orelse return false;
    var parent_info = index.commentParentInfo(allocator, repo, comment_id) catch return false;
    defer parent_info.deinit();
    const parent_iid = (try mappings.get(parent_info.parent_kind, parent_info.parent_id)) orelse return false;
    const body_text = if (std.mem.eql(u8, event_type, "comment.redacted"))
        "[redacted]"
    else
        event_json.jsonString(payload.get("body")) orelse return false;
    const request_body = try gitlabNoteBody(allocator, body_text);
    defer allocator.free(request_body);
    const path = try notePath(allocator, client, parent_info.parent_kind, parent_iid, note_id);
    defer allocator.free(path);
    const raw = try client.request("PUT", path, request_body);
    allocator.free(raw);
    return true;
}

pub fn gitlabIssueCreateBody(allocator: Allocator, payload: std.json.ObjectMap, assignee_ids: []const i64) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var first = true;
    try buf.append(allocator, '{');
    try appendStringField(&buf, allocator, &first, "title", event_json.jsonString(payload.get("title")) orelse "(untitled)");
    if (event_json.jsonString(payload.get("body"))) |body| try appendStringField(&buf, allocator, &first, "description", body);
    try common.appendStringArrayAsCommaField(&buf, allocator, &first, "labels", payload.get("labels"));
    try appendIntegerArrayField(&buf, allocator, &first, "assignee_ids", assignee_ids);
    try buf.append(allocator, '}');
    return try buf.toOwnedSlice(allocator);
}

pub fn gitlabMergeRequestCreateBody(allocator: Allocator, payload: std.json.ObjectMap, assignee_ids: []const i64, reviewer_ids: []const i64) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var first = true;
    try buf.append(allocator, '{');
    try appendStringField(&buf, allocator, &first, "title", event_json.jsonString(payload.get("title")) orelse "(untitled)");
    if (event_json.jsonString(payload.get("body"))) |body| try appendStringField(&buf, allocator, &first, "description", body);
    try appendStringField(&buf, allocator, &first, "target_branch", event_json.jsonString(payload.get("base_ref")) orelse "main");
    try appendStringField(&buf, allocator, &first, "source_branch", event_json.jsonString(payload.get("head_ref")) orelse "unknown");
    try common.appendStringArrayAsCommaField(&buf, allocator, &first, "labels", payload.get("labels"));
    try appendIntegerArrayField(&buf, allocator, &first, "assignee_ids", assignee_ids);
    try appendIntegerArrayField(&buf, allocator, &first, "reviewer_ids", reviewer_ids);
    try buf.append(allocator, '}');
    return try buf.toOwnedSlice(allocator);
}

pub fn gitlabIssuePatchBody(allocator: Allocator, payload: std.json.ObjectMap) !?[]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var first = true;
    try buf.append(allocator, '{');
    if (event_json.jsonString(payload.get("title"))) |value| try appendStringField(&buf, allocator, &first, "title", value);
    if (event_json.jsonString(payload.get("body"))) |value| try appendStringField(&buf, allocator, &first, "description", value);
    if (stateEvent(event_json.jsonString(payload.get("state")))) |value| try appendStringField(&buf, allocator, &first, "state_event", value);
    try buf.append(allocator, '}');
    if (first) {
        buf.deinit(allocator);
        return null;
    }
    return try buf.toOwnedSlice(allocator);
}

pub fn gitlabMergeRequestPatchBody(allocator: Allocator, payload: std.json.ObjectMap) !?[]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var first = true;
    try buf.append(allocator, '{');
    if (event_json.jsonString(payload.get("title"))) |value| try appendStringField(&buf, allocator, &first, "title", value);
    if (event_json.jsonString(payload.get("body"))) |value| try appendStringField(&buf, allocator, &first, "description", value);
    if (event_json.jsonString(payload.get("base_ref"))) |value| try appendStringField(&buf, allocator, &first, "target_branch", value);
    if (stateEvent(event_json.jsonString(payload.get("state")))) |value| try appendStringField(&buf, allocator, &first, "state_event", value);
    try buf.append(allocator, '}');
    if (first) {
        buf.deinit(allocator);
        return null;
    }
    return try buf.toOwnedSlice(allocator);
}

pub fn gitlabSinglePatchBody(allocator: Allocator, payload: std.json.ObjectMap) ![]u8 {
    if (try gitlabIssuePatchBody(allocator, payload)) |body| return body;
    return try allocator.dupe(u8, "{}");
}

pub fn gitlabNoteBody(allocator: Allocator, body_text: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '{');
    try appendJsonFieldString(&buf, allocator, "body", body_text, false);
    try buf.append(allocator, '}');
    return try buf.toOwnedSlice(allocator);
}

fn stateEvent(state: ?[]const u8) ?[]const u8 {
    const value = state orelse return null;
    if (std.mem.eql(u8, value, "closed")) return "close";
    if (std.mem.eql(u8, value, "open") or std.mem.eql(u8, value, "opened")) return "reopen";
    return null;
}

fn replayLabels(allocator: Allocator, client: GitLabClient, kind: []const u8, iid: i64, payload: std.json.ObjectMap, added_key: []const u8, removed_key: []const u8) !void {
    try replayStringArrayLabels(allocator, client, kind, iid, payload.get(added_key), true);
    try replayStringArrayLabels(allocator, client, kind, iid, payload.get(removed_key), false);
}

fn replayStringArrayLabels(allocator: Allocator, client: GitLabClient, kind: []const u8, iid: i64, value: ?std.json.Value, add: bool) !void {
    const array = jsonArray(value) orelse return;
    for (array.items) |item| {
        if (item != .string) continue;
        try replayOneLabel(allocator, client, kind, iid, item.string, add);
    }
}

fn replayOneLabel(allocator: Allocator, client: GitLabClient, kind: []const u8, iid: i64, label: []const u8, add: bool) !void {
    if (label.len == 0) return;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var first = true;
    try buf.append(allocator, '{');
    try appendStringField(&buf, allocator, &first, if (add) "add_labels" else "remove_labels", label);
    try buf.append(allocator, '}');
    const path = try objectPath(allocator, client, kind, iid);
    defer allocator.free(path);
    const raw = try client.request("PUT", path, buf.items);
    allocator.free(raw);
}

fn replayAssignees(allocator: Allocator, client: GitLabClient, kind: []const u8, iid: i64, payload: std.json.ObjectMap, added_key: []const u8, removed_key: []const u8) !void {
    try replayStringArrayAssignees(allocator, client, kind, iid, payload.get(added_key), true);
    try replayStringArrayAssignees(allocator, client, kind, iid, payload.get(removed_key), false);
}

fn replayStringArrayAssignees(allocator: Allocator, client: GitLabClient, kind: []const u8, iid: i64, value: ?std.json.Value, add: bool) !void {
    const array = jsonArray(value) orelse return;
    for (array.items) |item| {
        if (item != .string) continue;
        try replayOneAssignee(allocator, client, kind, iid, item.string, add);
    }
}

fn replayOneAssignee(allocator: Allocator, client: GitLabClient, kind: []const u8, iid: i64, assignee: []const u8, add: bool) !void {
    try replayUserSetMember(allocator, client, kind, iid, "assignees", "assignee_ids", assignee, add);
}

fn replayReviewers(allocator: Allocator, client: GitLabClient, pull_iid: i64, payload: std.json.ObjectMap, added_key: []const u8, removed_key: []const u8) !void {
    try replayStringArrayReviewers(allocator, client, pull_iid, payload.get(added_key), true);
    try replayStringArrayReviewers(allocator, client, pull_iid, payload.get(removed_key), false);
}

fn replayStringArrayReviewers(allocator: Allocator, client: GitLabClient, pull_iid: i64, value: ?std.json.Value, add: bool) !void {
    const array = jsonArray(value) orelse return;
    for (array.items) |item| {
        if (item != .string) continue;
        try replayOneReviewer(allocator, client, pull_iid, item.string, add);
    }
}

fn replayOneReviewer(allocator: Allocator, client: GitLabClient, pull_iid: i64, reviewer: []const u8, add: bool) !void {
    try replayUserSetMember(allocator, client, "pull", pull_iid, "reviewers", "reviewer_ids", reviewer, add);
}

fn replayUserSetMember(allocator: Allocator, client: GitLabClient, kind: []const u8, iid: i64, response_key: []const u8, body_key: []const u8, username: []const u8, add: bool) !void {
    if (username.len == 0) return;
    const user_id = (try resolveUserId(allocator, client, username)) orelse return;
    const ids = try currentUserIds(allocator, client, kind, iid, response_key);
    defer allocator.free(ids);
    const next = try editIdSet(allocator, ids, user_id, add);
    defer allocator.free(next);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var first = true;
    try buf.append(allocator, '{');
    try appendIntegerArrayField(&buf, allocator, &first, body_key, next);
    try buf.append(allocator, '}');
    const path = try objectPath(allocator, client, kind, iid);
    defer allocator.free(path);
    const raw = try client.request("PUT", path, buf.items);
    allocator.free(raw);
}

fn resolveUserIdsFromPayload(allocator: Allocator, client: GitLabClient, value: ?std.json.Value) ![]i64 {
    if (client.dry_run) return try allocator.alloc(i64, 0);
    const array = jsonArray(value) orelse return try allocator.alloc(i64, 0);
    var ids: std.ArrayList(i64) = .empty;
    errdefer ids.deinit(allocator);
    for (array.items) |item| {
        const username = event_json.jsonString(item) orelse continue;
        if (try resolveUserId(allocator, client, username)) |id| try appendUniqueId(allocator, &ids, id);
    }
    return try ids.toOwnedSlice(allocator);
}

fn resolveUserId(allocator: Allocator, client: GitLabClient, username: []const u8) !?i64 {
    if (client.dry_run) return null;
    const escaped = try common.urlPathEscape(allocator, username);
    defer allocator.free(escaped);
    const path = try std.fmt.allocPrint(allocator, "/users?username={s}", .{escaped});
    defer allocator.free(path);
    const raw = try client.request("GET", path, null);
    defer allocator.free(raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const users = switch (parsed.value) {
        .array => |array| array,
        else => return null,
    };
    if (users.items.len == 0 or users.items[0] != .object) return null;
    return jsonInteger(users.items[0].object.get("id"));
}

fn currentUserIds(allocator: Allocator, client: GitLabClient, kind: []const u8, iid: i64, response_key: []const u8) ![]i64 {
    if (client.dry_run) return try allocator.alloc(i64, 0);
    const path = try objectPath(allocator, client, kind, iid);
    defer allocator.free(path);
    const raw = try client.request("GET", path, null);
    defer allocator.free(raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return try allocator.alloc(i64, 0),
    };
    const users = jsonArray(root.get(response_key)) orelse return try allocator.alloc(i64, 0);
    var ids: std.ArrayList(i64) = .empty;
    errdefer ids.deinit(allocator);
    for (users.items) |item| {
        if (item != .object) continue;
        if (jsonInteger(item.object.get("id"))) |id| try appendUniqueId(allocator, &ids, id);
    }
    return try ids.toOwnedSlice(allocator);
}

fn appendUniqueId(allocator: Allocator, ids: *std.ArrayList(i64), id: i64) !void {
    for (ids.items) |existing| if (existing == id) return;
    try ids.append(allocator, id);
}

fn editIdSet(allocator: Allocator, ids: []const i64, id: i64, add: bool) ![]i64 {
    var next: std.ArrayList(i64) = .empty;
    errdefer next.deinit(allocator);
    for (ids) |existing| {
        if (!add and existing == id) continue;
        try appendUniqueId(allocator, &next, existing);
    }
    if (add) try appendUniqueId(allocator, &next, id);
    return try next.toOwnedSlice(allocator);
}

fn appendIntegerArrayField(buf: *std.ArrayList(u8), allocator: Allocator, first: *bool, key: []const u8, values: []const i64) !void {
    if (values.len == 0) return;
    if (!first.*) try buf.append(allocator, ',');
    first.* = false;
    try appendJsonString(buf, allocator, key);
    try buf.appendSlice(allocator, ":[");
    for (values, 0..) |value, idx| {
        if (idx != 0) try buf.append(allocator, ',');
        try @import("compat").appendPrint(allocator, buf, "{d}", .{value});
    }
    try buf.append(allocator, ']');
}

fn issuePath(allocator: Allocator, client: GitLabClient, iid: i64) ![]u8 {
    return try objectPath(allocator, client, "issue", iid);
}

fn mergeRequestPath(allocator: Allocator, client: GitLabClient, iid: i64) ![]u8 {
    return try objectPath(allocator, client, "pull", iid);
}

fn mergeRequestSubPath(allocator: Allocator, client: GitLabClient, iid: i64, suffix: []const u8) ![]u8 {
    const local = try std.fmt.allocPrint(allocator, "/merge_requests/{d}{s}", .{ iid, suffix });
    defer allocator.free(local);
    return try client.projectPath(allocator, local);
}

fn objectPath(allocator: Allocator, client: GitLabClient, kind: []const u8, iid: i64) ![]u8 {
    if (std.mem.eql(u8, kind, "issue")) {
        const local = try std.fmt.allocPrint(allocator, "/issues/{d}", .{iid});
        defer allocator.free(local);
        return try client.projectPath(allocator, local);
    }
    return try mergeRequestSubPath(allocator, client, iid, "");
}

fn noteCollectionPath(allocator: Allocator, client: GitLabClient, parent_kind: []const u8, parent_iid: i64) ![]u8 {
    const local = if (std.mem.eql(u8, parent_kind, "issue"))
        try std.fmt.allocPrint(allocator, "/issues/{d}/notes", .{parent_iid})
    else
        try std.fmt.allocPrint(allocator, "/merge_requests/{d}/notes", .{parent_iid});
    defer allocator.free(local);
    return try client.projectPath(allocator, local);
}

fn notePath(allocator: Allocator, client: GitLabClient, parent_kind: []const u8, parent_iid: i64, note_id: i64) ![]u8 {
    const local = if (std.mem.eql(u8, parent_kind, "issue"))
        try std.fmt.allocPrint(allocator, "/issues/{d}/notes/{d}", .{ parent_iid, note_id })
    else
        try std.fmt.allocPrint(allocator, "/merge_requests/{d}/notes/{d}", .{ parent_iid, note_id });
    defer allocator.free(local);
    return try client.projectPath(allocator, local);
}

test "gitlab export ignores forged legacy IIDs for object mappings" {
    const allocator = std.testing.allocator;
    const project = try parseProjectRef("group/project");
    const client = GitLabClient{
        .allocator = allocator,
        .api_url = default_api_url,
        .project = project,
        .token = null,
        .dry_run = true,
    };
    var mappings = MappingStore{
        .allocator = allocator,
        .path = try allocator.dupe(u8, "gitlab-export-test-map.jsonl"),
        .dry_run = true,
        .map = std.StringHashMap(i64).init(allocator),
    };
    defer mappings.deinit();

    var issue_parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{
        \\  "legacy": {"gitlab_issue_iid": 4242},
        \\  "payload": {"title": "Forged issue", "body": ""}
        \\}
    , .{});
    defer issue_parsed.deinit();
    const issue_root = issue_parsed.value.object;
    const issue_payload = issue_root.get("payload").?.object;
    try std.testing.expect(try exportIssueEvent(allocator, client, &mappings, "issue.opened", "issue-1", issue_payload));
    try std.testing.expectEqual(@as(i64, 1), (try mappings.get("issue", "issue-1")).?);

    var pull_parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{
        \\  "legacy": {"gitlab_merge_request_iid": 77},
        \\  "payload": {"title": "Forged pull", "body": "", "base_ref": "main", "head_ref": "feature"}
        \\}
    , .{});
    defer pull_parsed.deinit();
    const pull_root = pull_parsed.value.object;
    const pull_payload = pull_root.get("payload").?.object;
    try std.testing.expect(try exportPullEvent(allocator, client, &mappings, "pull.opened", "pull-1", pull_payload));
    try std.testing.expectEqual(@as(i64, 2), (try mappings.get("pull", "pull-1")).?);

    try mappings.putMemory("issue", "mapped-issue", 4242);
    try std.testing.expect(!try exportIssueEvent(allocator, client, &mappings, "issue.opened", "mapped-issue", issue_payload));
    try std.testing.expectEqual(@as(i64, 4242), (try mappings.get("issue", "mapped-issue")).?);
}
