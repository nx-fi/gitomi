const std = @import("std");
const errors = @import("../errors.zig");
const git = @import("../git.zig");
const io = @import("../io.zig");
const util = @import("../util.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const out = io.out;
const eprint = io.eprint;

pub const max_response_json = 32 * 1024 * 1024;
pub const default_retries = 3;
const retry_base_delay_ns = 500 * std.time.ns_per_ms;

pub const AuthHeaderStyle = union(enum) {
    none,
    bearer,
    token_header: []const u8,
};

pub const BaseUrlFormat = enum {
    append_path,
};

pub const RequestOptions = struct {
    not_found_as_null: bool = false,
};

pub const HttpApiClient = struct {
    allocator: Allocator,
    command_name: []const u8,
    service_name: []const u8,
    api_url: []const u8,
    token: ?[]const u8,
    auth_header_style: AuthHeaderStyle,
    headers: []const []const u8,
    curl_config_prefix: []const u8,
    base_url_format: BaseUrlFormat = .append_path,
    max_response_bytes: usize = max_response_json,
    retries: usize = default_retries,
    dry_run: bool = false,

    pub fn request(self: HttpApiClient, method: []const u8, path: []const u8, body: ?[]const u8, options: RequestOptions) !?[]u8 {
        if (self.dry_run) {
            try out("{s} {s}", .{ method, path });
            if (body) |bytes| try out(" {s}", .{bytes});
            try out("\n", .{});
            return try self.allocator.dupe(u8, "{}");
        }

        const url = try self.formatUrl(path);
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
            }, body, self.max_response_bytes);

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
                    if (isRetryableHttpStatus(response.status) and attempt + 1 < self.retries) {
                        result.deinit();
                        sleepBeforeRetry(attempt);
                        continue;
                    }
                    const response_body = std.mem.trim(u8, response.body, " \t\r\n");
                    if (response_body.len != 0) {
                        try eprint("{s}: {s} API request failed with HTTP {d}: {s}\n", .{ self.command_name, self.service_name, response.status, response_body });
                    } else {
                        try eprint("{s}: {s} API request failed with HTTP {d}\n", .{ self.command_name, self.service_name, response.status });
                    }
                    result.deinit();
                    return CliError.UserError;
                } else |err| {
                    result.deinit();
                    return err;
                }
            }

            const stderr = std.mem.trim(u8, result.stderr, " \t\r\n");
            if (attempt + 1 < self.retries) {
                result.deinit();
                sleepBeforeRetry(attempt);
                continue;
            }
            if (options.not_found_as_null and requestStderrIsNotFound(stderr)) {
                result.deinit();
                return null;
            }
            if (stderr.len != 0) {
                try eprint("{s}: {s} API request failed: {s}\n", .{ self.command_name, self.service_name, stderr });
            } else {
                try eprint("{s}: {s} API request failed\n", .{ self.command_name, self.service_name });
            }
            result.deinit();
            return CliError.UserError;
        }
    }

    fn formatUrl(self: HttpApiClient, path: []const u8) ![]u8 {
        return switch (self.base_url_format) {
            .append_path => try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.api_url, path }),
        };
    }

    fn writeCurlConfig(self: HttpApiClient, method: []const u8, url: []const u8, has_body: bool) ![]u8 {
        const id = try util.newUuidV7(self.allocator);
        defer self.allocator.free(id);
        const path = try std.fmt.allocPrint(self.allocator, "/tmp/{s}-{s}.cfg", .{ self.curl_config_prefix, id });
        errdefer self.allocator.free(path);

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        try appendCurlConfigOption(&buf, self.allocator, "request", method);
        for (self.headers) |header| {
            try appendCurlConfigOption(&buf, self.allocator, "header", header);
        }
        try self.appendAuthHeader(&buf);
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

    fn appendAuthHeader(self: HttpApiClient, buf: *std.ArrayList(u8)) !void {
        const token = self.token orelse return;
        switch (self.auth_header_style) {
            .none => {},
            .bearer => {
                const auth = try std.fmt.allocPrint(self.allocator, "Authorization: Bearer {s}", .{token});
                defer self.allocator.free(auth);
                try appendCurlConfigOption(buf, self.allocator, "header", auth);
            },
            .token_header => |name| {
                const auth = try std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ name, token });
                defer self.allocator.free(auth);
                try appendCurlConfigOption(buf, self.allocator, "header", auth);
            },
        }
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

pub fn sleepBeforeRetry(attempt: usize) void {
    const multiplier = @as(u64, 1) << @intCast(@min(attempt, 4));
    std.Thread.sleep(retry_base_delay_ns * multiplier);
}

pub fn requestStderrIsNotFound(stderr: []const u8) bool {
    return std.mem.indexOf(u8, stderr, "HTTP 404") != null or
        std.mem.indexOf(u8, stderr, "returned error: 404") != null or
        std.mem.indexOf(u8, stderr, "error: 404") != null;
}
