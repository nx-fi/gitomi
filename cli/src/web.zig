const std = @import("std");
const commits_page = @import("web/commits.zig");
const errors = @import("errors.zig");
const events_page = @import("web/events.zig");
const explorer = @import("web/explorer.zig");
const io = @import("io.zig");
const issues_page = @import("web/issues.zig");
const overview_page = @import("web/overview.zig");
const refs_page = @import("web/refs.zig");
const repo_mod = @import("repo.zig");
const shared = @import("web/shared.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const Repo = repo_mod.Repo;
const out = io.out;
const eprint = io.eprint;

const max_http_request = 64 * 1024;
const default_worker_count = 8;
pub const default_host = "127.0.0.1";
pub const default_port = 8080;

pub const Options = struct {
    host: []const u8 = default_host,
    port: u16 = default_port,
    once: bool = false,
    worker_count: usize = default_worker_count,
};

pub const HttpRequest = struct {
    method: []const u8,
    target: []const u8,
    path: []const u8,
    body: []const u8,
};

pub fn serve(allocator: Allocator, repo: Repo, options: Options) !void {
    const bind_host: []const u8 = if (std.mem.eql(u8, options.host, "localhost")) default_host else options.host;
    const address = std.net.Address.parseIp(bind_host, options.port) catch {
        try eprint("gt web: invalid host or port {s}:{d}\n", .{ options.host, options.port });
        return CliError.InvalidArgument;
    };

    var server = try address.listen(.{ .reuse_address = true, .kernel_backlog = 32 });
    defer server.deinit();

    const actual_port = server.listen_address.getPort();
    try out("Gitomi web listening at http://{s}:{d}/\n", .{ options.host, actual_port });
    if (!options.once) {
        try out("Press Ctrl-C to stop.\n", .{});
    }

    if (options.once) {
        const connection = try server.accept();
        defer connection.stream.close();
        try handleWebConnectionLogged(allocator, repo, connection.stream);
        return;
    }

    var pool: std.Thread.Pool = undefined;
    try pool.init(.{
        .allocator = allocator,
        .n_jobs = @max(options.worker_count, 1),
    });
    defer pool.deinit();

    var permits = std.Thread.Semaphore{ .permits = @max(options.worker_count, 1) };
    while (true) {
        permits.wait();
        const connection = server.accept() catch |err| {
            permits.post();
            return err;
        };
        pool.spawn(handleWebConnectionTask, .{ allocator, repo, connection, &permits }) catch |err| {
            connection.stream.close();
            permits.post();
            return err;
        };
    }
}

fn handleWebConnectionTask(allocator: Allocator, repo: Repo, connection: std.net.Server.Connection, permits: *std.Thread.Semaphore) void {
    defer permits.post();
    defer connection.stream.close();
    handleWebConnectionLogged(allocator, repo, connection.stream) catch {};
}

fn handleWebConnectionLogged(allocator: Allocator, repo: Repo, stream: std.net.Stream) !void {
    handleWebConnection(allocator, repo, stream) catch |err| {
        try eprint("gt web: request failed: {s}\n", .{@errorName(err)});
    };
}

pub fn handleWebConnection(allocator: Allocator, repo: Repo, stream: std.net.Stream) !void {
    const raw = readHttpRequest(allocator, stream) catch {
        try shared.sendPlainResponse(allocator, stream, 400, "Bad Request", "Bad request\n");
        return;
    };
    defer allocator.free(raw);

    const request = parseHttpRequest(raw) catch {
        try shared.sendPlainResponse(allocator, stream, 400, "Bad Request", "Bad request\n");
        return;
    };

    if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/style.css")) {
        try shared.sendResponse(allocator, stream, 200, "OK", "text/css", web_css, null);
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/logo.svg")) {
        try shared.sendResponse(allocator, stream, 200, "OK", "image/svg+xml", logo_svg, null);
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/theme.js")) {
        try shared.sendResponse(allocator, stream, 200, "OK", "application/javascript", theme_js, null);
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/tree.js")) {
        try shared.sendResponse(allocator, stream, 200, "OK", "application/javascript", tree_js, null);
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/markdown.js")) {
        try shared.sendResponse(allocator, stream, 200, "OK", "application/javascript", markdown_js, null);
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/highlight.js")) {
        try shared.sendResponse(allocator, stream, 200, "OK", "application/javascript", highlight_js, null);
    } else if (std.mem.eql(u8, request.method, "GET") and (std.mem.eql(u8, request.path, "/") or std.mem.eql(u8, request.path, "/code"))) {
        const body = try explorer.renderCodePage(allocator, repo, request.target);
        defer allocator.free(body);
        try shared.sendResponse(allocator, stream, 200, "OK", "text/html", body, null);
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/commits")) {
        const body = try commits_page.renderCommitsPage(allocator, repo, request.target);
        defer allocator.free(body);
        try shared.sendResponse(allocator, stream, 200, "OK", "text/html", body, null);
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/commit")) {
        const body = try commits_page.renderCommitPage(allocator, repo, request.target);
        defer allocator.free(body);
        try shared.sendResponse(allocator, stream, 200, "OK", "text/html", body, null);
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/overview")) {
        const body = try overview_page.renderHomePage(allocator, repo);
        defer allocator.free(body);
        try shared.sendResponse(allocator, stream, 200, "OK", "text/html", body, null);
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/issues")) {
        const body = try issues_page.renderIssuesPage(allocator, repo);
        defer allocator.free(body);
        try shared.sendResponse(allocator, stream, 200, "OK", "text/html", body, null);
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/events")) {
        const body = try events_page.renderEventsPage(allocator, repo);
        defer allocator.free(body);
        try shared.sendResponse(allocator, stream, 200, "OK", "text/html", body, null);
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/refs")) {
        const body = try refs_page.renderRefsPage(allocator, repo);
        defer allocator.free(body);
        try shared.sendResponse(allocator, stream, 200, "OK", "text/html", body, null);
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/new-issue")) {
        const body = try issues_page.renderIssueForm(allocator, repo, null, "", "", "", "");
        defer allocator.free(body);
        try shared.sendResponse(allocator, stream, 200, "OK", "text/html", body, null);
    } else if (std.mem.eql(u8, request.method, "POST") and std.mem.eql(u8, request.path, "/issues")) {
        try issues_page.handleIssuePost(allocator, repo, stream, request.body);
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/favicon.ico")) {
        try shared.sendResponse(allocator, stream, 204, "No Content", "text/plain", "", null);
    } else {
        const body = try renderNotFoundPage(allocator, repo);
        defer allocator.free(body);
        try shared.sendResponse(allocator, stream, 404, "Not Found", "text/html", body, null);
    }
}

pub fn readHttpRequest(allocator: Allocator, stream: std.net.Stream) ![]u8 {
    var raw: std.ArrayList(u8) = .empty;
    errdefer raw.deinit(allocator);

    var expected_len: ?usize = null;
    while (raw.items.len < max_http_request) {
        var chunk: [4096]u8 = undefined;
        const read_len = try stream.read(&chunk);
        if (read_len == 0) break;
        try raw.appendSlice(allocator, chunk[0..read_len]);

        if (expected_len == null) {
            if (std.mem.indexOf(u8, raw.items, "\r\n\r\n")) |header_end| {
                const content_len = try parseContentLength(raw.items[0..header_end]);
                expected_len = header_end + 4 + content_len;
                if (expected_len.? > max_http_request) return error.RequestTooLarge;
            }
        }

        if (expected_len) |needed| {
            if (raw.items.len >= needed) break;
        }
    }

    if (raw.items.len == 0) return error.BadRequest;
    if (raw.items.len >= max_http_request) return error.RequestTooLarge;
    return raw.toOwnedSlice(allocator);
}

pub fn parseHttpRequest(raw: []const u8) !HttpRequest {
    const header_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.BadRequest;
    const headers = raw[0..header_end];
    const content_len = try parseContentLength(headers);
    const body_start = header_end + 4;
    if (raw.len < body_start + content_len) return error.BadRequest;

    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    const request_line = lines.next() orelse return error.BadRequest;
    var parts = std.mem.tokenizeScalar(u8, request_line, ' ');
    const method = parts.next() orelse return error.BadRequest;
    const target = parts.next() orelse return error.BadRequest;
    _ = parts.next() orelse return error.BadRequest;

    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    return .{
        .method = method,
        .target = target,
        .path = target[0..query_start],
        .body = raw[body_start .. body_start + content_len],
    };
}

pub fn parseContentLength(headers: []const u8) !usize {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "content-length")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        return std.fmt.parseUnsigned(usize, value, 10) catch error.BadRequest;
    }
    return 0;
}

fn renderNotFoundPage(allocator: Allocator, repo: Repo) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try shared.appendShellStart(&buf, allocator, repo, "Not Found", "");
    try shared.appendEmptyState(&buf, allocator, "Page not found.", "The local Gitomi web UI does not have a route for that path.");
    try shared.appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

pub fn isLoopbackHost(host: []const u8) bool {
    return std.mem.eql(u8, host, default_host) or
        std.mem.eql(u8, host, "::1") or
        std.mem.eql(u8, host, "localhost");
}

const web_css = @embedFile("web/style.css");
const logo_svg = @embedFile("web/logo.svg");
const theme_js = @embedFile("web/theme.js");
const tree_js = @embedFile("web/tree.js");
const markdown_js = @embedFile("web/markdown.js");
const highlight_js = @embedFile("web/highlight.js");

test "web request parser separates method path and body" {
    const raw =
        "POST /issues?x=1 HTTP/1.1\r\n" ++
        "Host: 127.0.0.1\r\n" ++
        "Content-Length: 11\r\n" ++
        "\r\n" ++
        "title=Smoke";
    const request = try parseHttpRequest(raw);
    try std.testing.expectEqualStrings("POST", request.method);
    try std.testing.expectEqualStrings("/issues?x=1", request.target);
    try std.testing.expectEqualStrings("/issues", request.path);
    try std.testing.expectEqualStrings("title=Smoke", request.body);
}
