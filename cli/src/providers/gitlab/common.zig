const std = @import("std");
const errors = @import("../../errors.zig");
const event_mod = @import("../../event.zig");
const git = @import("../../git.zig");
const io = @import("../../io.zig");
const json_writer = @import("../../json_writer.zig");
const util = @import("../../util.zig");
const github_common = @import("../github/common.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const appendJsonFieldBool = json_writer.appendJsonFieldBool;
const appendJsonFieldString = json_writer.appendJsonFieldString;
const appendJsonFieldStringArray = json_writer.appendJsonFieldStringArray;
const appendJsonString = json_writer.appendJsonString;
const out = io.out;
const eprint = io.eprint;

pub const default_api_url = "https://gitlab.com/api/v4";
pub const max_gitlab_json = 32 * 1024 * 1024;
const gitlab_api_retries = 3;
const retry_base_delay_ns = 500 * std.time.ns_per_ms;

pub const ProjectRef = struct {
    path: []const u8,
};

pub fn parseProjectRef(raw: []const u8) !ProjectRef {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) {
        try eprint("gt gitlab: --project must be a GitLab project ID or namespace/project path\n", .{});
        return CliError.InvalidArgument;
    }
    return .{ .path = trimmed };
}

pub const GitLabClient = struct {
    allocator: Allocator,
    api_url: []const u8,
    project: ProjectRef,
    token: ?[]const u8,
    dry_run: bool = false,

    pub fn request(self: GitLabClient, method: []const u8, path: []const u8, body: ?[]const u8) ![]u8 {
        return (try self.requestInternal(method, path, body, .{})).?;
    }

    pub fn requestAllowNotFound(self: GitLabClient, method: []const u8, path: []const u8, body: ?[]const u8) !?[]u8 {
        return try self.requestInternal(method, path, body, .{ .not_found_as_null = true });
    }

    const RequestOptions = struct {
        not_found_as_null: bool = false,
    };

    fn requestInternal(self: GitLabClient, method: []const u8, path: []const u8, body: ?[]const u8, options: RequestOptions) !?[]u8 {
        if (self.dry_run) {
            try out("{s} {s}", .{ method, path });
            if (body) |bytes| try out(" {s}", .{bytes});
            try out("\n", .{});
            return try self.allocator.dupe(u8, "{}");
        }

        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.api_url, path });
        defer self.allocator.free(url);

        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            const config_path = try self.writeCurlConfig(method, url, body != null);
            defer self.allocator.free(config_path);
            defer std.fs.deleteFileAbsolute(config_path) catch {};

            var result = try git.runCommand(self.allocator, &.{
                "curl",
                "-sS",
                "--config",
                config_path,
                "--write-out",
                "\n%{http_code}",
            }, body, max_gitlab_json);

            if (result.exitCode() == 0) {
                if (parseCurlHttpResponse(self.allocator, result.stdout)) |response| {
                    defer self.allocator.free(response.body);
                    if (response.status >= 200 and response.status < 300) {
                        const body_owned = try self.allocator.dupe(u8, response.body);
                        result.deinit();
                        return body_owned;
                    }
                    if (options.not_found_as_null and response.status == 404) {
                        result.deinit();
                        return null;
                    }
                    if (isRetryableHttpStatus(response.status) and attempt + 1 < gitlab_api_retries) {
                        result.deinit();
                        sleepBeforeRetry(attempt);
                        continue;
                    }
                    const response_body = std.mem.trim(u8, response.body, " \t\r\n");
                    if (response_body.len != 0) {
                        try eprint("gt gitlab: GitLab API request failed with HTTP {d}: {s}\n", .{ response.status, response_body });
                    } else {
                        try eprint("gt gitlab: GitLab API request failed with HTTP {d}\n", .{response.status});
                    }
                    result.deinit();
                    return CliError.UserError;
                } else |err| {
                    result.deinit();
                    return err;
                }
            }

            const stderr = std.mem.trim(u8, result.stderr, " \t\r\n");
            if (attempt + 1 < gitlab_api_retries) {
                result.deinit();
                sleepBeforeRetry(attempt);
                continue;
            }
            if (options.not_found_as_null and requestStderrIsNotFound(stderr)) {
                result.deinit();
                return null;
            }
            if (stderr.len != 0) {
                try eprint("gt gitlab: GitLab API request failed: {s}\n", .{stderr});
            } else {
                try eprint("gt gitlab: GitLab API request failed\n", .{});
            }
            result.deinit();
            return CliError.UserError;
        }
    }

    pub fn projectPath(self: GitLabClient, allocator: Allocator, suffix: []const u8) ![]u8 {
        const escaped = try urlPathEscape(allocator, self.project.path);
        defer allocator.free(escaped);
        return std.fmt.allocPrint(allocator, "/projects/{s}{s}", .{ escaped, suffix });
    }

    fn writeCurlConfig(self: GitLabClient, method: []const u8, url: []const u8, has_body: bool) ![]u8 {
        const id = try util.newUuidV7(self.allocator);
        defer self.allocator.free(id);
        const path = try std.fmt.allocPrint(self.allocator, "/tmp/gitomi-gitlab-curl-{s}.cfg", .{id});
        errdefer self.allocator.free(path);

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        try appendCurlConfigOption(&buf, self.allocator, "request", method);
        try appendCurlConfigOption(&buf, self.allocator, "header", "Accept: application/json");
        try appendCurlConfigOption(&buf, self.allocator, "header", "User-Agent: gitomi/0.1.0");
        if (self.token) |token| {
            const auth = try std.fmt.allocPrint(self.allocator, "PRIVATE-TOKEN: {s}", .{token});
            defer self.allocator.free(auth);
            try appendCurlConfigOption(&buf, self.allocator, "header", auth);
        }
        if (has_body) {
            try appendCurlConfigOption(&buf, self.allocator, "header", "Content-Type: application/json");
            try appendCurlConfigOption(&buf, self.allocator, "data-binary", "@-");
        }
        try appendCurlConfigOption(&buf, self.allocator, "url", url);

        var file = try std.fs.createFileAbsolute(path, .{ .mode = 0o600 });
        errdefer std.fs.deleteFileAbsolute(path) catch {};
        defer file.close();
        try file.writeAll(buf.items);
        try file.sync();
        return path;
    }
};

fn appendCurlConfigOption(buf: *std.ArrayList(u8), allocator: Allocator, key: []const u8, value: []const u8) !void {
    try buf.appendSlice(allocator, key);
    try buf.appendSlice(allocator, " = \"");
    for (value) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, c),
        }
    }
    try buf.appendSlice(allocator, "\"\n");
}

const HttpResponse = struct {
    body: []u8,
    status: u16,
};

fn parseCurlHttpResponse(allocator: Allocator, stdout: []const u8) !HttpResponse {
    const marker = std.mem.lastIndexOfScalar(u8, stdout, '\n') orelse return CliError.UserError;
    const raw_status = std.mem.trim(u8, stdout[marker + 1 ..], " \t\r\n");
    if (raw_status.len != 3) return CliError.UserError;
    const status = std.fmt.parseUnsigned(u16, raw_status, 10) catch return CliError.UserError;
    const body = try allocator.dupe(u8, stdout[0..marker]);
    return .{ .body = body, .status = status };
}

fn isRetryableHttpStatus(status: u16) bool {
    return status == 429 or (status >= 500 and status <= 599);
}

fn sleepBeforeRetry(attempt: usize) void {
    const multiplier = @as(u64, 1) << @intCast(@min(attempt, 4));
    std.Thread.sleep(retry_base_delay_ns * multiplier);
}

pub fn tokenFromEnv(allocator: Allocator) !?[]u8 {
    return std.process.getEnvVarOwned(allocator, "GITLAB_TOKEN") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => std.process.getEnvVarOwned(allocator, "GL_TOKEN") catch |fallback_err| switch (fallback_err) {
            error.EnvironmentVariableNotFound => null,
            else => return fallback_err,
        },
        else => return err,
    };
}

pub const secretFromEnv = github_common.secretFromEnv;
pub const secretFromFile = github_common.secretFromFile;
pub const sizedString = github_common.githubSizedString;
pub const subject = github_common.githubSubject;
pub const timestampOrNow = github_common.githubTimestampOrNow;
pub const firstJsonValue = github_common.firstJsonValue;
pub const namedArray = github_common.githubNamedArray;
pub const optionalUnsignedField = github_common.githubOptionalUnsignedField;
pub const nestedString = github_common.nestedString;
pub const jsonArray = github_common.jsonArray;
pub const jsonBool = github_common.jsonBool;
pub const jsonInteger = github_common.jsonInteger;
pub const urlPathEscape = github_common.urlPathEscape;
pub const parseResponseNumber = github_common.parseResponseNumber;
pub const legacyNumber = github_common.legacyNumber;
pub const appendStringField = github_common.appendStringField;
pub const appendBoolField = github_common.appendBoolField;
pub const singleArrayBody = github_common.singleArrayBody;

pub fn requestStderrIsNotFound(stderr: []const u8) bool {
    return std.mem.indexOf(u8, stderr, "HTTP 404") != null or
        std.mem.indexOf(u8, stderr, "returned error: 404") != null or
        std.mem.indexOf(u8, stderr, "error: 404") != null;
}

pub fn authorUsername(object: std.json.ObjectMap) ?[]const u8 {
    if (event_mod.jsonString(object.get("source_author"))) |value| return value;
    if (event_mod.jsonString(object.get("author_username"))) |value| return value;
    if (event_mod.jsonString(object.get("user_username"))) |value| return value;
    if (nestedString(object, "author", "username")) |value| return value;
    if (nestedString(object, "user", "username")) |value| return value;
    if (event_mod.jsonString(object.get("author"))) |value| return value;
    if (event_mod.jsonString(object.get("user"))) |value| return value;
    return null;
}

pub fn milestoneTitle(object: std.json.ObjectMap) ?[]const u8 {
    if (event_mod.jsonString(object.get("milestone"))) |value| return value;
    return nestedString(object, "milestone", "title");
}

pub fn labels(allocator: Allocator, object: std.json.ObjectMap) ![][]u8 {
    var list: std.ArrayList([]u8) = .empty;
    errdefer git.freeStringList(allocator, list.items);
    const array = jsonArray(object.get("labels")) orelse return list.toOwnedSlice(allocator);
    for (array.items) |item| {
        if (item == .string and item.string.len != 0) {
            try list.append(allocator, try sizedString(allocator, item.string, "", git.max_payload_atom_bytes));
        } else if (item == .object) {
            if (event_mod.jsonString(item.object.get("title")) orelse event_mod.jsonString(item.object.get("name"))) |name| {
                if (name.len != 0) try list.append(allocator, try sizedString(allocator, name, "", git.max_payload_atom_bytes));
            }
        }
    }
    return list.toOwnedSlice(allocator);
}

pub fn userArray(allocator: Allocator, value: ?std.json.Value) ![][]u8 {
    var list: std.ArrayList([]u8) = .empty;
    errdefer git.freeStringList(allocator, list.items);
    const array = jsonArray(value) orelse return list.toOwnedSlice(allocator);
    for (array.items) |item| {
        if (item == .string) {
            if (item.string.len != 0) try list.append(allocator, try sizedString(allocator, item.string, "", git.max_payload_atom_bytes));
        } else if (item == .object) {
            const username = event_mod.jsonString(item.object.get("username")) orelse
                event_mod.jsonString(item.object.get("login")) orelse
                event_mod.jsonString(item.object.get("name")) orelse
                continue;
            if (username.len != 0) try list.append(allocator, try sizedString(allocator, username, "", git.max_payload_atom_bytes));
        }
    }
    return list.toOwnedSlice(allocator);
}

pub fn commaString(allocator: Allocator, values: []const []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (values, 0..) |value, idx| {
        if (idx != 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, value);
    }
    return try buf.toOwnedSlice(allocator);
}

pub fn appendStringArrayAsCommaField(buf: *std.ArrayList(u8), allocator: Allocator, first: *bool, key: []const u8, value: ?std.json.Value) !void {
    const array = jsonArray(value) orelse return;
    if (array.items.len == 0) return;
    var strings: std.ArrayList([]const u8) = .empty;
    defer strings.deinit(allocator);
    for (array.items) |item| {
        if (item == .string) try strings.append(allocator, item.string);
    }
    if (strings.items.len == 0) return;
    const joined = try commaString(allocator, strings.items);
    defer allocator.free(joined);
    try appendStringField(buf, allocator, first, key, joined);
}
