const std = @import("std");
const errors = @import("../../errors.zig");
const event_json = @import("../../event/json.zig");
const git = @import("../../git.zig");
const io = @import("../../io.zig");
const http_client = @import("../http_client.zig");
const provider_common = @import("../common.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const eprint = io.eprint;
const RequestOptions = http_client.RequestOptions;

pub const default_api_url = "https://gitlab.com/api/v4";
pub const max_gitlab_json = http_client.max_response_json;
const gitlab_headers = [_][]const u8{
    "Accept: application/json",
    "User-Agent: gitomi/0.1.0",
};

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

    fn requestInternal(self: GitLabClient, method: []const u8, path: []const u8, body: ?[]const u8, options: RequestOptions) !?[]u8 {
        return try self.httpClient().request(method, path, body, options);
    }

    pub fn projectPath(self: GitLabClient, allocator: Allocator, suffix: []const u8) ![]u8 {
        const escaped = try urlPathEscape(allocator, self.project.path);
        defer allocator.free(escaped);
        return std.fmt.allocPrint(allocator, "/projects/{s}{s}", .{ escaped, suffix });
    }

    fn httpClient(self: GitLabClient) http_client.HttpApiClient {
        return .{
            .allocator = self.allocator,
            .command_name = "gt gitlab",
            .service_name = "GitLab",
            .api_url = self.api_url,
            .token = self.token,
            .auth_header_style = .{ .token_header = "PRIVATE-TOKEN" },
            .headers = &gitlab_headers,
            .curl_config_prefix = "gitomi-gitlab-curl",
            .dry_run = self.dry_run,
        };
    }
};

pub fn tokenFromEnv(allocator: Allocator) !?[]u8 {
    return std.process.getEnvVarOwned(allocator, "GITLAB_TOKEN") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => std.process.getEnvVarOwned(allocator, "GL_TOKEN") catch |fallback_err| switch (fallback_err) {
            error.EnvironmentVariableNotFound => null,
            else => return fallback_err,
        },
        else => return err,
    };
}

pub const secretFromEnv = provider_common.secretFromEnv;
pub const secretFromFile = provider_common.secretFromFile;
pub const sizedString = provider_common.sizedString;
pub const subject = provider_common.subject;
pub const timestampOrNow = provider_common.timestampOrNow;
pub const firstJsonValue = provider_common.firstJsonValue;
pub const namedArray = provider_common.namedArray;
pub const optionalUnsignedField = provider_common.optionalUnsignedField;
pub const nestedString = provider_common.nestedString;
pub const jsonArray = event_json.jsonArray;
pub const jsonBool = event_json.jsonBool;
pub const jsonInteger = event_json.jsonInteger;
pub const urlPathEscape = provider_common.urlPathEscape;
pub const parseResponseNumber = provider_common.parseResponseNumber;
pub const legacyNumber = provider_common.legacyNumber;
pub const appendStringField = provider_common.appendStringField;
pub const appendBoolField = provider_common.appendBoolField;
pub const singleArrayBody = provider_common.singleArrayBody;

pub fn requestStderrIsNotFound(stderr: []const u8) bool {
    return http_client.requestStderrIsNotFound(stderr);
}

pub fn authorUsername(object: std.json.ObjectMap) ?[]const u8 {
    if (event_json.jsonString(object.get("source_author"))) |value| return value;
    if (event_json.jsonString(object.get("author_username"))) |value| return value;
    if (event_json.jsonString(object.get("user_username"))) |value| return value;
    if (nestedString(object, "author", "username")) |value| return value;
    if (nestedString(object, "user", "username")) |value| return value;
    if (event_json.jsonString(object.get("author"))) |value| return value;
    if (event_json.jsonString(object.get("user"))) |value| return value;
    return null;
}

pub fn milestoneTitle(object: std.json.ObjectMap) ?[]const u8 {
    if (event_json.jsonString(object.get("milestone"))) |value| return value;
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
            if (event_json.jsonString(item.object.get("title")) orelse event_json.jsonString(item.object.get("name"))) |name| {
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
            const username = event_json.jsonString(item.object.get("username")) orelse
                event_json.jsonString(item.object.get("login")) orelse
                event_json.jsonString(item.object.get("name")) orelse
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
