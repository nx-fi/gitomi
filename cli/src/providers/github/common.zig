const std = @import("std");
const errors = @import("../../errors.zig");
const event_model = @import("../../event/model.zig");
const event_json = @import("../../event/json.zig");
const git = @import("../../git.zig");
const io = @import("../../io.zig");
const json_writer = @import("../../json_writer.zig");
const util = @import("../../util.zig");
const provider_common = @import("../common.zig");
const http_client = @import("../http_client.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const appendJsonFieldBool = json_writer.appendJsonFieldBool;
const appendJsonFieldString = json_writer.appendJsonFieldString;
const appendJsonFieldStringArray = json_writer.appendJsonFieldStringArray;
const appendJsonString = json_writer.appendJsonString;
const eprint = io.eprint;
const RequestOptions = http_client.RequestOptions;

pub const default_api_url = "https://api.github.com";
pub const max_github_json = http_client.max_response_json;
pub const jsonArray = event_json.jsonArray;
pub const jsonBool = event_json.jsonBool;
pub const jsonInteger = event_json.jsonInteger;
const github_api_retries = http_client.default_retries;
const github_headers = [_][]const u8{
    "Accept: application/vnd.github+json",
    "X-GitHub-Api-Version: 2022-11-28",
    "User-Agent: gitomi/0.1.0",
};
pub const gh_current_repo = RepoSlug{
    .owner = "OWNER",
    .name = "REPO",
    .slug = "OWNER/REPO",
};

pub const ApiMode = enum {
    rest,
    graphql,
};

pub const RepoSlug = struct {
    owner: []const u8,
    name: []const u8,
    slug: []const u8,
};

pub fn parseRepoSlug(raw: []const u8) !RepoSlug {
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

pub const GitHubClient = struct {
    allocator: Allocator,
    api_url: []const u8,
    repo: RepoSlug,
    token: ?[]const u8,
    use_gh: bool = false,
    dry_run: bool = false,

    pub fn request(self: GitHubClient, method: []const u8, path: []const u8, body: ?[]const u8) ![]u8 {
        return (try self.requestInternal(method, path, body, .{})).?;
    }

    pub fn requestAllowNotFound(self: GitHubClient, method: []const u8, path: []const u8, body: ?[]const u8) !?[]u8 {
        return try self.requestInternal(method, path, body, .{ .not_found_as_null = true });
    }

    pub fn graphqlRequest(self: GitHubClient, body: []const u8) ![]u8 {
        return try self.request("POST", "/graphql", body);
    }

    fn requestInternal(self: GitHubClient, method: []const u8, path: []const u8, body: ?[]const u8, options: RequestOptions) !?[]u8 {
        if (self.dry_run or !self.use_gh) return try self.httpClient().request(method, path, body, options);
        return try self.requestGhInternal(method, path, body, options);
    }

    pub fn requestGh(self: GitHubClient, method: []const u8, path: []const u8, body: ?[]const u8) ![]u8 {
        return (try self.requestGhInternal(method, path, body, .{})).?;
    }

    fn requestGhInternal(self: GitHubClient, method: []const u8, path: []const u8, body: ?[]const u8, options: RequestOptions) !?[]u8 {
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

        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            var result = try git.runCommand(self.allocator, argv.items, body, max_github_json);
            if (result.exitCode() == 0) {
                const stdout = result.stdout;
                self.allocator.free(result.stderr);
                return stdout;
            }

            defer result.deinit();
            const stderr = std.mem.trim(u8, result.stderr, " \t\r\n");
            if (options.not_found_as_null and githubRequestStderrIsNotFound(stderr)) return null;
            if (isRetryableGithubError(stderr) and attempt + 1 < github_api_retries) {
                http_client.sleepBeforeRetry(attempt);
                continue;
            }
            if (stderr.len != 0) {
                try eprint("gt github: gh api request failed: {s}\n", .{stderr});
            } else {
                try eprint("gt github: gh api request failed\n", .{});
            }
            return CliError.UserError;
        }
    }

    pub fn repoPath(self: GitHubClient, allocator: Allocator, suffix: []const u8) ![]u8 {
        if (self.use_gh and std.mem.eql(u8, self.repo.slug, gh_current_repo.slug)) {
            return std.fmt.allocPrint(allocator, "/repos/{{owner}}/{{repo}}{s}", .{suffix});
        }
        return std.fmt.allocPrint(allocator, "/repos/{s}{s}", .{ self.repo.slug, suffix });
    }

    fn httpClient(self: GitHubClient) http_client.HttpApiClient {
        return .{
            .allocator = self.allocator,
            .command_name = "gt github",
            .service_name = "GitHub",
            .api_url = self.api_url,
            .token = self.token,
            .auth_header_style = .bearer,
            .headers = &github_headers,
            .curl_config_prefix = "gitomi-curl",
            .dry_run = self.dry_run,
        };
    }
};

fn isRetryableGithubError(stderr: []const u8) bool {
    return std.mem.indexOf(u8, stderr, "HTTP 429") != null or
        std.mem.indexOf(u8, stderr, "HTTP 5") != null or
        std.ascii.indexOfIgnoreCase(stderr, "rate limit") != null;
}

pub fn githubTokenFromEnv(allocator: Allocator) !?[]u8 {
    return std.process.getEnvVarOwned(allocator, "GITHUB_TOKEN") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => std.process.getEnvVarOwned(allocator, "GH_TOKEN") catch |fallback_err| switch (fallback_err) {
            error.EnvironmentVariableNotFound => null,
            else => return fallback_err,
        },
        else => return err,
    };
}

pub const secretFromEnv = provider_common.secretFromEnv;
pub const secretFromFile = provider_common.secretFromFile;

pub fn githubRequestStderrIsNotFound(stderr: []const u8) bool {
    return http_client.requestStderrIsNotFound(stderr);
}

pub fn githubSizedString(allocator: Allocator, value: ?[]const u8, fallback: []const u8, max_bytes: usize) ![]u8 {
    const raw = value orelse fallback;
    return provider_common.sizedStringWithMarker(allocator, raw, max_bytes, "\n\n[truncated by gitomi github import]");
}

pub fn githubSubject(allocator: Allocator, prefix: []const u8, title: []const u8) ![]u8 {
    return provider_common.subjectWithMarker(allocator, prefix, title, " [truncated by gitomi github import]");
}

pub fn singleArrayBody(allocator: Allocator, key: []const u8, value: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '{');
    try appendJsonFieldStringArray(&buf, allocator, key, &.{value}, false);
    try buf.append(allocator, '}');
    return buf.toOwnedSlice(allocator);
}

pub fn appendStringField(buf: *std.ArrayList(u8), allocator: Allocator, first: *bool, key: []const u8, value: []const u8) !void {
    if (!first.*) try buf.append(allocator, ',');
    first.* = false;
    try appendJsonFieldString(buf, allocator, key, value, false);
}

pub fn appendBoolField(buf: *std.ArrayList(u8), allocator: Allocator, first: *bool, key: []const u8, value: bool) !void {
    if (!first.*) try buf.append(allocator, ',');
    first.* = false;
    try appendJsonFieldBool(buf, allocator, key, value, false);
}

pub fn appendStringArrayValueField(buf: *std.ArrayList(u8), allocator: Allocator, first: *bool, key: []const u8, value: ?std.json.Value) !void {
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

pub fn parseResponseNumber(allocator: Allocator, raw: []const u8, key: []const u8) ?i64 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return null;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return null,
    };
    return jsonInteger(root.get(key));
}

pub fn legacyNumber(root: std.json.ObjectMap, key: []const u8) ?i64 {
    const legacy = switch (root.get("legacy") orelse return null) {
        .object => |object| object,
        else => return null,
    };
    return jsonInteger(legacy.get(key));
}

pub fn githubTimestampOrNow(allocator: Allocator, value: ?std.json.Value) ![]u8 {
    if (event_json.jsonString(value)) |timestamp| {
        if (timestamp.len != 0 and timestamp[timestamp.len - 1] == 'Z') {
            return allocator.dupe(u8, timestamp);
        }
    }
    return util.rfc3339Now(allocator);
}

pub fn firstJsonValue(a: ?std.json.Value, b: ?std.json.Value) ?std.json.Value {
    return if (a) |value| value else b;
}

pub fn firstJsonValue3(a: ?std.json.Value, b: ?std.json.Value, c: ?std.json.Value) ?std.json.Value {
    return firstJsonValue(firstJsonValue(a, b), c);
}

pub fn githubStateEquals(value: ?std.json.Value, expected_lower: []const u8) bool {
    const raw = event_json.jsonString(value) orelse return false;
    return std.ascii.eqlIgnoreCase(raw, expected_lower);
}

pub fn githubIssueLabels(allocator: Allocator, issue: std.json.ObjectMap) ![][]u8 {
    var list: std.ArrayList([]u8) = .empty;
    errdefer git.freeStringList(allocator, list.items);
    try appendGithubNamedArray(allocator, &list, issue.get("labels"), "name");
    try appendGithubNamedArray(allocator, &list, issue.get("tags"), "name");
    return list.toOwnedSlice(allocator);
}

pub fn githubPullReviewers(allocator: Allocator, pull: std.json.ObjectMap) ![][]u8 {
    var list: std.ArrayList([]u8) = .empty;
    errdefer git.freeStringList(allocator, list.items);
    try appendGithubNamedArray(allocator, &list, pull.get("requested_reviewers"), "login");
    try appendGithubNamedArray(allocator, &list, pull.get("reviewers"), "login");
    try appendGithubNamedArray(allocator, &list, pull.get("requestedReviewers"), "login");
    try appendGithubReviewRequests(allocator, &list, pull.get("reviewRequests"));
    return list.toOwnedSlice(allocator);
}

pub fn githubNamedArray(allocator: Allocator, value: ?std.json.Value, key: []const u8) ![][]u8 {
    var list: std.ArrayList([]u8) = .empty;
    errdefer git.freeStringList(allocator, list.items);
    try appendGithubNamedArray(allocator, &list, value, key);
    return list.toOwnedSlice(allocator);
}

pub fn appendGithubNamedArray(allocator: Allocator, list: *std.ArrayList([]u8), value: ?std.json.Value, key: []const u8) !void {
    const actual = value orelse return;
    switch (actual) {
        .array => |array| return appendGithubNamedArrayItems(allocator, list, array, key),
        .object => |object| {
            if (event_json.jsonString(object.get(key))) |name| {
                if (name.len != 0) try list.append(allocator, try githubSizedString(allocator, name, "", git.max_payload_atom_bytes));
            }
            if (jsonArray(object.get("nodes"))) |nodes| try appendGithubNamedArrayItems(allocator, list, nodes, key);
            if (jsonArray(object.get("edges"))) |edges| {
                for (edges.items) |edge| {
                    if (edge != .object) continue;
                    const node = switch (edge.object.get("node") orelse continue) {
                        .object => |node_object| node_object,
                        else => continue,
                    };
                    if (event_json.jsonString(node.get(key))) |name| {
                        if (name.len != 0) try list.append(allocator, try githubSizedString(allocator, name, "", git.max_payload_atom_bytes));
                    }
                }
            }
        },
        .string => |string| if (string.len != 0) try list.append(allocator, try githubSizedString(allocator, string, "", git.max_payload_atom_bytes)),
        else => {},
    }
}

fn appendGithubNamedArrayItems(allocator: Allocator, list: *std.ArrayList([]u8), array: std.json.Array, key: []const u8) !void {
    for (array.items) |item| {
        if (item == .string) {
            try list.append(allocator, try githubSizedString(allocator, item.string, "", git.max_payload_atom_bytes));
        } else if (item == .object) {
            if (event_json.jsonString(item.object.get(key))) |name| {
                if (name.len != 0) try list.append(allocator, try githubSizedString(allocator, name, "", git.max_payload_atom_bytes));
            }
        }
    }
}

fn appendGithubReviewRequests(allocator: Allocator, list: *std.ArrayList([]u8), value: ?std.json.Value) !void {
    const connection = switch (value orelse return) {
        .object => |object| object,
        else => return,
    };
    const nodes = jsonArray(connection.get("nodes")) orelse return;
    for (nodes.items) |item| {
        const request = switch (item) {
            .object => |object| object,
            else => continue,
        };
        const reviewer = switch (request.get("requestedReviewer") orelse continue) {
            .object => |object| object,
            else => continue,
        };
        const name = event_json.jsonString(reviewer.get("login")) orelse
            event_json.jsonString(reviewer.get("slug")) orelse
            event_json.jsonString(reviewer.get("name")) orelse
            continue;
        if (name.len != 0) try list.append(allocator, try githubSizedString(allocator, name, "", git.max_payload_atom_bytes));
    }
}

pub fn githubAuthorLogin(object: std.json.ObjectMap) ?[]const u8 {
    if (event_json.jsonString(object.get("source_author"))) |value| return value;
    if (event_json.jsonString(object.get("author_login"))) |value| return value;
    if (event_json.jsonString(object.get("user_login"))) |value| return value;
    if (nestedString(object, "user", "login")) |value| return value;
    if (nestedString(object, "author", "login")) |value| return value;
    if (event_json.jsonString(object.get("author"))) |value| return value;
    if (event_json.jsonString(object.get("user"))) |value| return value;
    return null;
}

pub fn githubOptionalUnsignedField(object: std.json.ObjectMap, keys: []const []const u8) ?u64 {
    for (keys) |key| {
        if (jsonOptionalUnsigned(object.get(key))) |value| return value;
    }
    return null;
}

pub fn githubMilestoneTitle(object: std.json.ObjectMap) ?[]const u8 {
    if (event_json.jsonString(object.get("milestone"))) |value| return value;
    return nestedString(object, "milestone", "title");
}

pub fn githubFixtureProjects(
    allocator: Allocator,
    root: std.json.ObjectMap,
    parent_kind: []const u8,
    number: i64,
    object: std.json.ObjectMap,
) ![]event_model.IssueProjectPlacement {
    var list: std.ArrayList(event_model.IssueProjectPlacement) = .empty;
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

pub fn appendProjectPlacements(
    allocator: Allocator,
    list: *std.ArrayList(event_model.IssueProjectPlacement),
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
                project_name = event_json.jsonString(map.get("project")) orelse
                    event_json.jsonString(map.get("name")) orelse
                    event_json.jsonString(map.get("title"));
                column_name = event_json.jsonString(map.get("column")) orelse
                    event_json.jsonString(map.get("column_name")) orelse
                    event_json.jsonString(map.get("status")) orelse
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

pub fn freeProjectPlacements(allocator: Allocator, projects: []event_model.IssueProjectPlacement) void {
    for (projects) |project| {
        allocator.free(project.project);
        allocator.free(project.column);
    }
    allocator.free(projects);
}

pub fn nestedString(object: std.json.ObjectMap, parent_key: []const u8, child_key: []const u8) ?[]const u8 {
    const parent = switch (object.get(parent_key) orelse return null) {
        .object => |map| map,
        else => return null,
    };
    return event_json.jsonString(parent.get(child_key));
}

pub fn jsonOptionalUnsigned(value: ?std.json.Value) ?u64 {
    const actual = value orelse return null;
    const integer = switch (actual) {
        .integer => |i| i,
        .object => |object| return jsonOptionalUnsigned(object.get("totalCount")) orelse jsonOptionalUnsigned(object.get("count")),
        else => return null,
    };
    if (integer < 0) return null;
    return @intCast(integer);
}

pub fn urlPathEscape(allocator: Allocator, value: []const u8) ![]u8 {
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
