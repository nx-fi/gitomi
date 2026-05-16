const std = @import("std");
const errors = @import("../errors.zig");
const event_mod = @import("../event.zig");
const git = @import("../git.zig");
const io = @import("../io.zig");
const json_writer = @import("../json_writer.zig");
const util = @import("../util.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const appendJsonFieldBool = json_writer.appendJsonFieldBool;
const appendJsonFieldString = json_writer.appendJsonFieldString;
const appendJsonFieldStringArray = json_writer.appendJsonFieldStringArray;
const appendJsonString = json_writer.appendJsonString;
const out = io.out;
const eprint = io.eprint;

pub const default_api_url = "https://api.github.com";
pub const max_github_json = 32 * 1024 * 1024;
pub const gh_current_repo = RepoSlug{
    .owner = "OWNER",
    .name = "REPO",
    .slug = "OWNER/REPO",
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

    pub fn requestGh(self: GitHubClient, method: []const u8, path: []const u8, body: ?[]const u8) ![]u8 {
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

    pub fn repoPath(self: GitHubClient, allocator: Allocator, suffix: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "/repos/{s}{s}", .{ self.repo.slug, suffix });
    }
};

pub fn githubTokenFromEnv(allocator: Allocator) !?[]u8 {
    return std.process.getEnvVarOwned(allocator, "GITHUB_TOKEN") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => std.process.getEnvVarOwned(allocator, "GH_TOKEN") catch |fallback_err| switch (fallback_err) {
            error.EnvironmentVariableNotFound => null,
            else => return fallback_err,
        },
        else => return err,
    };
}

pub fn githubSizedString(allocator: Allocator, value: ?[]const u8, fallback: []const u8, max_bytes: usize) ![]u8 {
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

pub fn githubSubject(allocator: Allocator, prefix: []const u8, title: []const u8) ![]u8 {
    const title_limit = if (prefix.len >= git.max_event_subject_bytes) 0 else git.max_event_subject_bytes - prefix.len;
    const title_part = try githubSizedString(allocator, title, "", title_limit);
    defer allocator.free(title_part);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, title_part });
}

pub fn utf8PrefixLen(value: []const u8, max_bytes: usize) usize {
    var len = @min(value.len, max_bytes);
    while (len > 0 and len < value.len and (value[len] & 0xc0) == 0x80) {
        len -= 1;
    }
    return len;
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
    if (event_mod.jsonString(value)) |timestamp| {
        if (timestamp.len != 0 and timestamp[timestamp.len - 1] == 'Z') {
            return allocator.dupe(u8, timestamp);
        }
    }
    return util.rfc3339Now(allocator);
}

pub fn firstJsonValue(a: ?std.json.Value, b: ?std.json.Value) ?std.json.Value {
    return if (a) |value| value else b;
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
    return list.toOwnedSlice(allocator);
}

pub fn githubNamedArray(allocator: Allocator, value: ?std.json.Value, key: []const u8) ![][]u8 {
    var list: std.ArrayList([]u8) = .empty;
    errdefer git.freeStringList(allocator, list.items);
    try appendGithubNamedArray(allocator, &list, value, key);
    return list.toOwnedSlice(allocator);
}

pub fn appendGithubNamedArray(allocator: Allocator, list: *std.ArrayList([]u8), value: ?std.json.Value, key: []const u8) !void {
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

pub fn githubAuthorLogin(object: std.json.ObjectMap) ?[]const u8 {
    if (event_mod.jsonString(object.get("source_author"))) |value| return value;
    if (event_mod.jsonString(object.get("author_login"))) |value| return value;
    if (event_mod.jsonString(object.get("user_login"))) |value| return value;
    if (nestedString(object, "user", "login")) |value| return value;
    if (nestedString(object, "author", "login")) |value| return value;
    if (event_mod.jsonString(object.get("author"))) |value| return value;
    if (event_mod.jsonString(object.get("user"))) |value| return value;
    return null;
}

pub fn githubOptionalUnsignedField(object: std.json.ObjectMap, keys: []const []const u8) ?u64 {
    for (keys) |key| {
        if (jsonOptionalUnsigned(object.get(key))) |value| return value;
    }
    return null;
}

pub fn githubMilestoneTitle(object: std.json.ObjectMap) ?[]const u8 {
    if (event_mod.jsonString(object.get("milestone"))) |value| return value;
    return nestedString(object, "milestone", "title");
}

pub fn githubFixtureProjects(
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

pub fn appendProjectPlacements(
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

pub fn freeProjectPlacements(allocator: Allocator, projects: []event_mod.IssueProjectPlacement) void {
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
    return event_mod.jsonString(parent.get(child_key));
}

pub fn jsonArray(value: ?std.json.Value) ?std.json.Array {
    if (value) |v| {
        return switch (v) {
            .array => |array| array,
            else => null,
        };
    }
    return null;
}

pub fn jsonBool(value: ?std.json.Value) ?bool {
    if (value) |v| {
        return switch (v) {
            .bool => |b| b,
            else => null,
        };
    }
    return null;
}

pub fn jsonInteger(value: ?std.json.Value) ?i64 {
    if (value) |v| {
        return switch (v) {
            .integer => |i| i,
            else => null,
        };
    }
    return null;
}

pub fn jsonOptionalUnsigned(value: ?std.json.Value) ?u64 {
    const integer = jsonInteger(value) orelse return null;
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
